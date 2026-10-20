#!/usr/bin/env python3
"""Loopback-only UI/API for an independent Daikin LAN controller."""
import argparse
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
import json
from pathlib import Path
import secrets
import sys
import urllib.request
import webbrowser
from controller import LanController,ControlError

ROOT=Path(__file__).resolve().parent
APP='daikin-local'
MAX_BODY=8192

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*a,**kw):super().__init__(*a,directory=str(ROOT),**kw)
    def log_message(self,*a):pass
    def allowed_host(self):
        return self.headers.get('Host') in {f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'}
    def end_headers(self):
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Cache-Control','no-store')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
        super().end_headers()
    def reply(self,value,status=200):
        body=json.dumps(value,ensure_ascii=False,allow_nan=False).encode('utf-8')
        self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_GET(self):
        if not self.allowed_host():return self.reply({'error':'Adresse de serveur refusée.','code':'invalid_host'},403)
        try:
            if self.path=='/api/session':return self.reply({'app':APP,'version':'1.0','csrfToken':self.server.csrf_token,'writesEnabled':True,'model':'FTXA20A2V1BW','mode':'test' if self.server.controller.fixture is not None else 'live'})
            if self.path=='/api/devices':return self.reply(self.server.controller.devices())
            if self.path=='/health.json':return self.reply({'app':APP,'version':'1.0','mode':'test' if self.server.controller.fixture is not None else 'live'})
            if self.path.startswith('/api/'):return self.reply({'error':'Route inconnue.','code':'not_found'},404)
            path=Path(self.translate_path(self.path)).resolve()
            if not path.is_relative_to(ROOT) or any(part.startswith('.') for part in path.relative_to(ROOT).parts) or path.suffix in ('.py','.command') or path.name in ('known-devices.json',):
                return self.reply({'error':'Fichier non servi.','code':'forbidden'},403)
            if path.is_dir()and self.path!='/':return self.reply({'error':'Répertoire non servi.','code':'forbidden'},403)
            return super().do_GET()
        except ControlError as error:return self.reply({'error':error.message,'code':error.code},error.status)
        except (BrokenPipeError,ConnectionResetError):return
        except Exception:return self.reply({'error':'La lecture a échoué. Réessayez.','code':'internal_error'},500)
    def do_POST(self):
        origins={f'http://127.0.0.1:{self.server.server_port}',f'http://localhost:{self.server.server_port}'}
        if not self.allowed_host()or self.headers.get('Origin')not in origins or not secrets.compare_digest(self.headers.get('X-CSRF-Token',''),self.server.csrf_token):
            return self.reply({'error':'Ouvrez la commande depuis l’application locale.','code':'invalid_session'},403)
        if self.headers.get('Content-Type','').split(';')[0]!='application/json':return self.reply({'error':'Format de requête refusé.','code':'invalid_content_type'},415)
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=MAX_BODY:raise ControlError('Requête trop volumineuse ou vide.','invalid_body',413)
            data=json.loads(self.rfile.read(length))
            if not isinstance(data,dict):raise ControlError('Requête invalide.','invalid_body')
            if self.path=='/api/discover':return self.reply(self.server.controller.discover())
            if self.path=='/api/connect':return self.reply(self.server.controller.connect(data.get('host')))
            parts=self.path.split('/')
            if len(parts)==5 and parts[1:3]==['api','devices'] and parts[4]=='control':return self.reply(self.server.controller.control(parts[3],data.get('changes')))
            return self.reply({'error':'Route inconnue.','code':'not_found'},404)
        except (json.JSONDecodeError,ValueError):return self.reply({'error':'Requête JSON invalide.','code':'invalid_body'},400)
        except ControlError as error:return self.reply({'error':error.message,'code':error.code},error.status)
        except (BrokenPipeError,ConnectionResetError):return
        except Exception:return self.reply({'error':'La commande a échoué. Actualisez pour vérifier l’état avant de réessayer.','code':'internal_error'},500)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8770);parser.add_argument('--open',action='store_true');parser.add_argument('--test-fixture',type=Path)
    args=parser.parse_args()
    fixture=json.loads(args.test_fixture.read_text()) if args.test_fixture else None
    config=ROOT/'known-devices.json'
    hosts=json.loads(config.read_text()).get('hosts',[]) if config.exists()else[]
    controller=LanController(hosts,fixture)
    url=f'http://127.0.0.1:{args.port}/'
    try:server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    except OSError:
        try:
            with urllib.request.urlopen(url+'health.json',timeout=1)as response:identity=json.load(response)
        except Exception:identity={}
        if identity.get('app')==APP and identity.get('mode')==('test'if fixture is not None else'live'):
            print('Daikin local fonctionne déjà : '+url)
            if args.open:webbrowser.open(url)
            return
        print('Port occupé : choisissez un autre port avec --port.',file=sys.stderr);raise SystemExit(1)
    server.controller=controller;server.csrf_token=secrets.token_urlsafe(32)
    print('Daikin local : '+url+'\nMode '+('TEST SANS MATÉRIEL'if fixture is not None else'RÉSEAU LOCAL — commandes uniquement après action utilisateur')+'\nCtrl+C pour arrêter.',flush=True)
    if args.open:webbrowser.open(url)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close()
if __name__=='__main__':main()
