"""Independent Daikin legacy LAN protocol client. No automatic state-changing calls."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import ipaddress
import math
import socket
import threading
import time
from urllib.parse import urlencode, unquote
from urllib.request import build_opener, ProxyHandler, HTTPRedirectHandler, Request

MODES = {'auto':'0', 'dry':'2', 'cool':'3', 'heat':'4', 'fan':'6'}
MODE_NAMES = {'0':'auto','1':'auto','7':'auto','2':'dry','3':'cool','4':'heat','6':'fan'}
FANS = {'auto':'A','quiet':'B',**{str(i):str(i+2) for i in range(1,6)}}
SWINGS = {'off':'0','vertical':'1','horizontal':'2','both':'3'}
LIMITS = {'auto':(18,30),'cool':(18,32),'heat':(10,30)}

class ControlError(Exception):
    def __init__(self, message, code='device_error', status=400):
        self.message, self.code, self.status = message, code, status
        super().__init__(message)

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ControlError('L’appareil a demandé une redirection non prise en charge.', 'redirect_rejected',502)

def private_host(host):
    try:
        if not isinstance(host,str): raise ValueError()
        address=ipaddress.IPv4Address(host)
        allowed=any(address in ipaddress.IPv4Network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16'))
        if not allowed: raise ValueError()
        return str(address)
    except (ValueError,TypeError):
        raise ControlError('Saisissez l’adresse IPv4 privée de votre climatisation.', 'invalid_host')

def parse_fields(text):
    return {key:unquote(value) for part in text.strip().split(',') if '=' in part for key,_,value in [part.partition('=')]}

def number(value):
    try:
        value=float(value)
        return value if math.isfinite(value) and -60<=value<=100 else None
    except (TypeError,ValueError): return None

def prepare_control(current, changes, capabilities):
    """Pure read/merge/validate step; does not contact a device."""
    if not isinstance(changes,dict) or not changes:
        raise ControlError('Aucun changement à appliquer.','empty_changes')
    if set(changes)-{'power','mode','target','fan','swing'}:
        raise ControlError('Réglage non pris en charge.','invalid_changes')
    required={'pow','mode','stemp','shum'}
    if not required.issubset(current):
        raise ControlError('État de commande incomplet : aucune commande envoyée.','incomplete_state',502)
    result={k:current[k] for k in ('pow','mode','stemp','shum','f_rate','f_dir') if k in current}
    mode_name=changes.get('mode',MODE_NAMES.get(current['mode']))
    if not isinstance(mode_name,str) or mode_name not in MODES:
        raise ControlError('Mode non pris en charge.','invalid_mode')
    # Preserve the exact existing auto variant for a power/fan/temperature-only change.
    mode=MODES[mode_name] if 'mode' in changes else current['mode']
    result['mode']=mode
    if 'mode' in changes and mode != current['mode']:
        for field,prefix in [('stemp','dt'),('shum','dh'),('f_rate','dfr')]:
            if field in result and prefix+mode in current:
                result[field]=current[prefix+mode]
    if 'power' in changes:
        if type(changes['power']) is not bool:
            raise ControlError('La commande marche/arrêt doit être un booléen.','invalid_power')
        result['pow']='1' if changes['power'] else '0'
    # Selecting a mode never implicitly turns on an appliance that is off.
    if 'target' in changes:
        if not capabilities.get('temperature') or mode_name not in LIMITS:
            raise ControlError('La température ne se règle pas dans ce mode.','unsupported_temperature')
        target=changes['target']
        if type(target) not in (int,float) or not math.isfinite(target):
            raise ControlError('Consigne de température invalide.','invalid_temperature')
        low,high=LIMITS[mode_name]
        if not low<=target<=high or abs(target*2-round(target*2))>1e-8:
            raise ControlError(f'Choisissez une consigne entre {low} et {high} °C, par pas de 0,5 °C.','invalid_temperature')
        result['stemp']=f'{target:.1f}'
    if 'fan' in changes:
        if not capabilities.get('fan') or not isinstance(changes['fan'],str) or changes['fan'] not in FANS:
            raise ControlError('Vitesse de ventilation non prise en charge.','invalid_fan')
        result['f_rate']=FANS[changes['fan']]
    if 'swing' in changes:
        if not capabilities.get('swing') or not isinstance(changes['swing'],str) or changes['swing'] not in SWINGS:
            raise ControlError('Orientation non prise en charge.','invalid_swing')
        result['f_dir']=SWINGS[changes['swing']]
    return result

class LanController:
    def __init__(self, hosts=(), fixture=None):
        self.hosts={private_host(host) for host in hosts}
        self.fixture=fixture
        if fixture is not None: self.hosts=set(fixture)
        self.opener=build_opener(ProxyHandler({}),NoRedirect())
        self.guard=threading.Lock()
        self.locks={}
        self.last={}
        self.write_count=0
        self.discovery_lock=threading.Lock()

    def _lock(self,host):
        with self.guard: return self.locks.setdefault(host,threading.RLock())

    def _get(self,host,path,params=None):
        # The only mutating endpoint permitted by this client is used in control().
        if self.fixture is not None:
            record=self.fixture[host]
            if path=='/aircon/set_control_info':
                record['/aircon/get_control_info'].update(params)
                return {'ret':'OK'}
            return dict(record[path])
        url='http://'+private_host(host)+path
        if params: url+='?'+urlencode(params)
        try:
            with self.opener.open(Request(url,headers={'User-Agent':'Daikin-local/1.0','Accept':'text/plain'}),timeout=3) as response:
                data=response.read(65537)
                if len(data)>65536: raise ControlError('Réponse trop volumineuse.','invalid_response',502)
            values=parse_fields(data.decode('utf-8','replace'))
        except ControlError: raise
        except Exception as error:
            raise ControlError('La climatisation ne répond pas sur le réseau local.','unreachable',502) from error
        if values.get('ret')!='OK':
            raise ControlError('La climatisation a refusé cette requête.','device_refused',502)
        return values

    def snapshot(self,host):
        host=private_host(host)
        with self._lock(host):
            basic=self._get(host,'/common/basic_info')
            if basic.get('type')!='aircon':
                raise ControlError('Cette adresse ne correspond pas à une climatisation Daikin compatible.','not_daikin',400)
            model=self._get(host,'/aircon/get_model_info')
            control=self._get(host,'/aircon/get_control_info')
            sensors=self._get(host,'/aircon/get_sensor_info')
            mode=MODE_NAMES.get(control.get('mode'),'unknown')
            low,high=LIMITS.get(mode,(18,30))
            capabilities={'temperature':model.get('temp')=='1','fan':'f_rate' in control and model.get('en_frate','1')!='0','swing':'f_dir' in control and model.get('en_fdir','1')!='0'}
            item={'id':host,'name':basic.get('name') or 'Climatisation Daikin','online':True,'power':control.get('pow')=='1','mode':mode,'target':number(control.get('stemp')) if mode in LIMITS else None,'roomTemperature':number(sensors.get('htemp')),'outdoorTemperature':number(sensors.get('otemp')),'fan':{v:k for k,v in FANS.items()}.get(control.get('f_rate')),'swing':{v:k for k,v in SWINGS.items()}.get(control.get('f_dir')),'firmware':basic.get('ver'),'modelCode':model.get('model'),'errorCode':sensors.get('err'),'capabilities':capabilities,'limits':{'min':low,'max':high,'step':.5},'observedAt':datetime.now(timezone.utc).isoformat(),'error':None}
            self.last[host]=item
            return item

    def _safe_snapshot(self,host):
        try: return self.snapshot(host)
        except ControlError as e:
            return {**self.last.get(host,{'id':host,'name':'Climatisation Daikin','power':False,'mode':'unknown','target':None,'roomTemperature':None,'outdoorTemperature':None,'fan':None,'swing':None,'capabilities':{},'limits':{'min':18,'max':30,'step':.5},'observedAt':None}),'online':False,'error':e.message}

    def devices(self):
        with self.guard: hosts=sorted(self.hosts)
        with ThreadPoolExecutor(max_workers=4) as pool: devices=list(pool.map(self._safe_snapshot,hosts))
        return {'devices':sorted(devices,key=lambda d:d['name'].casefold()),'readOnlyDiscovery':True,'mode':'test' if self.fixture is not None else 'live'}

    def connect(self,host):
        host=private_host(host)
        self.snapshot(host)
        with self.guard: self.hosts.add(host)
        return self.devices()

    def discover(self):
        if self.fixture is not None:return self.devices()
        with self.discovery_lock:
            sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
            sock.settimeout(.25)
            try:
                sock.bind(('',30000))
                sock.sendto(b'DAIKIN_UDP/common/basic_info',('255.255.255.255',30050))
                deadline=time.monotonic()+2
                while time.monotonic()<deadline:
                    try: raw,address=sock.recvfrom(8192)
                    except socket.timeout:continue
                    fields=parse_fields(raw.decode('utf-8','replace'))
                    if fields.get('ret')=='OK' and fields.get('type')=='aircon':
                        try:host=private_host(address[0])
                        except ControlError:continue
                        with self.guard:self.hosts.add(host)
            except OSError as error:
                raise ControlError('La détection réseau n’est pas disponible. Vous pouvez saisir l’adresse IP de la clim.','discovery_failed',503) from error
            finally:sock.close()
        return self.devices()

    def control(self,host,changes):
        host=private_host(host)
        with self.guard: registered=host in self.hosts
        if not registered:raise ControlError('Choisissez d’abord une unité détectée.','unknown_device',404)
        with self._lock(host):
            before=self.snapshot(host)
            current=self._get(host,'/aircon/get_control_info')
            params=prepare_control(current,changes,before['capabilities'])
            # Exactly one user-initiated write; no automatic retries or maintenance calls.
            self._get(host,'/aircon/set_control_info',params)
            self.write_count+=1
            expected={'power':params['pow']=='1','mode':MODE_NAMES.get(params['mode']),'fan':{v:k for k,v in FANS.items()}.get(params.get('f_rate')),'swing':{v:k for k,v in SWINGS.items()}.get(params.get('f_dir')),'target':number(params.get('stemp'))}
            after=None
            try:
                for delay in (0,.25,.5):
                    if delay:time.sleep(delay)
                    after=self.snapshot(host)
                    keys=[key for key in changes if key!='target' or expected['mode'] in LIMITS]
                    if all(after.get(key)==expected.get(key) for key in keys):
                        return {'device':after,'verified':True,'message':'Réglages confirmés par la climatisation.'}
            except ControlError:
                pass
            return {'device':after or {**before,'online':False,'error':'La lecture après commande a échoué.'},'verified':False,'message':'Commande acceptée, mais confirmation de l’état non obtenue. Actualisez avant de réessayer.'}
