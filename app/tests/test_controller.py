"""All writes in these tests use an in-memory fake, never a physical AC."""
import copy
import json
from pathlib import Path
import secrets
import sys
import threading
import unittest
from urllib.request import Request,urlopen
from urllib.error import HTTPError
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from controller import LanController,ControlError,prepare_control,private_host
from server import Handler,ThreadingHTTPServer
HOST='192.168.1.101'
FIXTURE={HOST:{
 '/common/basic_info':{'ret':'OK','type':'aircon','name':'Pièce de test','ver':'test'},
 '/aircon/get_model_info':{'ret':'OK','model':'TEST','temp':'1','en_frate':'1','en_fdir':'1'},
 '/aircon/get_sensor_info':{'ret':'OK','htemp':'20.0','otemp':'14.0','err':'0'},
 '/aircon/get_control_info':{'ret':'OK','pow':'1','mode':'3','stemp':'21.5','shum':'0','f_rate':'5','f_dir':'3','dt2':'M','dh2':'50','dfr2':'5','dt4':'25.0','dh4':'0','dfr4':'6','dfr6':'5'}
}}
CAPS={'temperature':True,'fan':True,'swing':True}

class ProtocolTests(unittest.TestCase):
 def setUp(self):self.raw=copy.deepcopy(FIXTURE[HOST]['/aircon/get_control_info'])
 def test_read_does_not_write(self):
  c=LanController(fixture=copy.deepcopy(FIXTURE));self.assertEqual(c.devices()['devices'][0]['target'],21.5);self.assertEqual(c.write_count,0)
 def test_power_preserves_other_fields(self):
  p=prepare_control(self.raw,{'power':False},CAPS);self.assertEqual(p['pow'],'0')
  for key in ['mode','stemp','shum','f_rate','f_dir']:self.assertEqual(p[key],self.raw[key])
 def test_dry_restores_mode_memory(self):
  p=prepare_control(self.raw,{'mode':'dry'},CAPS);self.assertEqual((p['stemp'],p['shum'],p['f_rate']),('M','50','5'))
 def test_fan_without_temperature_memory_preserves_fields(self):
  p=prepare_control(self.raw,{'mode':'fan'},CAPS);self.assertEqual((p['stemp'],p['shum'],p['f_dir']),('21.5','0','3'))
 def test_mode_selection_does_not_turn_on_unit(self):
  self.raw['pow']='0';self.assertEqual(prepare_control(self.raw,{'mode':'heat'},CAPS)['pow'],'0')
 def test_ranges_and_types(self):
  for value in [9,31,20.25,float('nan'),True,'20']:
   with self.subTest(value=value),self.assertRaises(ControlError):prepare_control(self.raw,{'mode':'heat','target':value},CAPS)
 def test_dry_temperature_rejected(self):
  with self.assertRaises(ControlError):prepare_control(self.raw,{'mode':'dry','target':20},CAPS)
 def test_unknown_commands_rejected(self):
  for changes in [{'firmware':'x'},{'mode':[]},{'fan':[]},{'swing':[]}]:
   with self.subTest(changes=changes),self.assertRaises(ControlError):prepare_control(self.raw,changes,CAPS)
 def test_private_host_boundary(self):
  for host in ['127.0.0.1','169.254.169.254','8.8.8.8','localhost','https://192.168.1.10','192.168.1.1:80']:
   with self.subTest(host=host),self.assertRaises(ControlError):private_host(host)
 def test_mock_write_and_readback(self):
  c=LanController(fixture=copy.deepcopy(FIXTURE));r=c.control(HOST,{'target':22,'fan':'quiet','swing':'vertical'});self.assertTrue(r['verified']);self.assertEqual(r['device']['target'],22);self.assertEqual(r['device']['fan'],'quiet');self.assertEqual(c.write_count,1)

class HttpTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.http=ThreadingHTTPServer(('127.0.0.1',0),Handler);cls.http.controller=LanController(fixture=copy.deepcopy(FIXTURE));cls.http.csrf_token=secrets.token_urlsafe(32)
  cls.url=f'http://127.0.0.1:{cls.http.server_port}';cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True);cls.thread.start()
 @classmethod
 def tearDownClass(cls):cls.http.shutdown();cls.http.server_close();cls.thread.join()
 def request(self,path,data=None,token=True,origin=True):
  headers={}
  if data is not None:
   headers['Content-Type']='application/json'
   if token:headers['X-CSRF-Token']=self.http.csrf_token
   headers['Origin']=self.url if origin else 'https://unrelated.example'
  req=Request(self.url+path,data=json.dumps(data).encode()if data is not None else None,headers=headers)
  try:
   with urlopen(req)as response:return response.status,json.load(response)
  except HTTPError as error:return error.code,json.load(error)
 def test_health_is_test_only(self):self.assertEqual(self.request('/health.json')[1]['mode'],'test')
 def test_csrf_and_origin(self):
  for token,origin in [(False,True),(True,False)]:self.assertEqual(self.request('/api/devices/'+HOST+'/control',{'changes':{'power':False}},token=token,origin=origin)[0],403)
 def test_invalid_command_does_not_write(self):
  before=self.http.controller.write_count;status,_=self.request('/api/devices/'+HOST+'/control',{'changes':{'target':999}});self.assertEqual(status,400);self.assertEqual(self.http.controller.write_count,before)
 def test_source_files_not_served(self):self.assertEqual(self.request('/controller.py')[0],403)
 def test_valid_command_reaches_fake_only(self):
  status,result=self.request('/api/devices/'+HOST+'/control',{'changes':{'target':23}});self.assertEqual(status,200);self.assertTrue(result['verified']);self.assertEqual(result['device']['target'],23)

if __name__=='__main__':unittest.main()
