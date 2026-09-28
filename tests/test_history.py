import importlib.util,json,os,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
src=Path(__file__).parents[1]/'skills/blurt/scripts/history.py'
spec=importlib.util.spec_from_file_location('history',src); h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class Workflow(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=Path(self.tmp.name);h.write(self.p/'meta.json',{'workspace':str(self.p)});(self.p/'recording.mp4').touch()
 def tearDown(self):self.tmp.cleanup()
 def reviewed(self):h.write(self.p/'items.json',{'reviewed':True,'items':[{'kind':'idea','title':'test','status':'confirmed'}]})
 def test_states(self):
  self.assertEqual(h.describe(self.p)['status'],'saved');h.write(self.p/'processing.json',{'status':'running','pid':os.getpid()});self.assertEqual(h.describe(self.p)['status'],'processing')
  h.write(self.p/'processing.json',{'status':'failed'});self.reviewed();self.assertEqual(h.describe(self.p)['status'],'failed')
  h.write(self.p/'processing.json',{'status':'completed'});self.assertEqual(h.describe(self.p)['status'],'reviewed')
 def test_running_job_takes_priority(self):
  self.reviewed()
  h.write(self.p/'jobs'/'test'/'state.json',{'status':'running','pid':os.getpid()})
  for processing in ('completed','failed','running'):
   h.write(self.p/'processing.json',{'status':processing,'pid':os.getpid()})
   h.write(self.p/'review-state.json',{'status':'reviewing','heartbeat':time.time()})
   h.write(self.p/'items.json',{'reviewed':False,'items':[]})
   self.assertEqual(h.describe(self.p)['status'],'running')
 def test_unreviewed_rejected(self):
  with self.assertRaises(ValueError):h.execute(self.p,{'project':str(self.p),'task':'test'})
 def test_execution_and_duplicate(self):
  self.reviewed();fake=self.p/'fake-codex';fake.write_text('#!/usr/bin/env python3\nimport sys,time\nfrom pathlib import Path\ntime.sleep(.3)\nPath(sys.argv[sys.argv.index("-o")+1]).write_text("Completed")\nprint("worked")\n');fake.chmod(0o755)
  with patch.object(h.shutil,'which',return_value=str(fake)):
   state=h.execute(self.p,{'project':str(self.p),'task':'test'})
   with self.assertRaises(ValueError):h.execute(self.p,{'project':str(self.p),'task':'duplicate'})
   for _ in range(50):
    if h.describe(self.p)['status']!='running':break
    time.sleep(.05)
  self.assertEqual(h.describe(self.p,True)['jobs'][-1]['result'],'Completed');self.assertEqual(h.describe(self.p)['status'],'completed')
 def test_failed_and_interrupted(self):
  self.reviewed();fake=self.p/'fake';fake.write_text('#!/bin/sh\nexit 7\n');fake.chmod(0o755)
  with patch.object(h.shutil,'which',return_value=str(fake)):h.execute(self.p,{'project':str(self.p),'task':'test'})
  time.sleep(.2);self.assertEqual(h.describe(self.p)['status'],'failed')
  f=next((self.p/'jobs').glob('*/state.json'));h.write(f,{'status':'running','pid':999999999});self.assertEqual(h.describe(self.p)['status'],'interrupted')
if __name__=='__main__':unittest.main()
