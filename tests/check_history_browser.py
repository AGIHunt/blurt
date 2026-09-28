# coding: utf-8
import os,sys,json,time,tempfile,subprocess
from pathlib import Path
from urllib.request import urlopen,Request
from playwright.sync_api import sync_playwright
root=Path(__file__).parents[1];script=root/'skills/blurt/scripts/history.py'
with tempfile.TemporaryDirectory() as tmp:
 home=Path(tmp).resolve();project=home/'project';session=project/'.blurt/sessions/test-recording';session.mkdir(parents=True);(session/'recording.mp4').touch()
 (session/'meta.json').write_text(json.dumps({'workspace':str(project),'duration':166,'started_at':'2026-09-28T06:03:26Z'}))
 (home/'config.json').write_text(json.dumps({'record':{'workspaces':[str(project)]}}))
 (session/'processing.json').write_text(json.dumps({'status':'running','pid':os.getpid()}))
 env=dict(os.environ,BLURT_HOME=str(home),HOME=str(home));server=subprocess.Popen([sys.executable,str(script),'--serve'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 try:
  for _ in range(40):
   if (home/'history-server.json').exists():break
   time.sleep(.1)
  base=json.loads((home/'history-server.json').read_text())['url']
  with sync_playwright() as p:
   browser=p.chromium.launch(headless=True);page=browser.new_page(viewport={'width':1440,'height':1000});errors=[];page.on('pageerror',lambda e:(errors.append(str(e)),print('JS ERROR',e,flush=True)))
   page.goto(base+'#'+str(session));page.wait_for_load_state('networkidle');page.get_by_role('heading',name='正在把录屏整理成条目').wait_for();assert page.locator('#autoReview').is_checked()
   items={'session':'test-recording','title':'示例页面评审','language':'zh','reviewed':False,'items':[{'id':'1','kind':'idea','title':'简化设置入口','summary':'让用户从首页进入设置。','status':'draft','frames':[]},{'id':'2','kind':'note','title':'保留取消操作','summary':'操作应能单独取消。','status':'draft','frames':[]}]}
   (session/'items.json').write_text(json.dumps(items));(session/'processing.json').write_text(json.dumps({'status':'completed'}))
   page.wait_for_url('**/review/**',timeout=15000);page.locator('#finishBtn').wait_for();assert len(browser.contexts[0].pages)==1
   page.get_by_role('button',name='← 处理记录').click();page.wait_for_url(base+'**');page.get_by_role('heading',name='整理好了，轮到你确认').wait_for()
   page.get_by_role('button',name='开始 / 继续审核 →').click();page.wait_for_url('**/review/**');page.locator('#finishBtn').click();page.locator('#mOk').click();page.wait_for_url(base+'**',timeout=10000)
   page.get_by_role('heading',name='审核已完成，尚未在本页启动任务').wait_for();assert len(browser.contexts[0].pages)==1;assert json.loads((session/'items.json').read_text())['reviewed'];assert len(list((session/'reviews').glob('*.json')))==1
   assert '简化设置入口' in page.locator('#task').input_value()
   assert page.locator('.step.now').count()==0
   page.locator('#task').fill('根据审核结果制作页面');page.reload();page.locator('#task').wait_for();assert page.locator('#task').input_value()=='根据审核结果制作页面'
   page.locator('#themeBtn').click();theme=page.locator('html').get_attribute('data-theme');page.get_by_role('button',name='重新审核 ↗').click();page.wait_for_url('**/review/**');page.locator('#finishBtn').wait_for();assert page.locator('html').get_attribute('data-theme')==theme
   page.get_by_role('button',name='← 处理记录').click();page.wait_for_url(base+'**');page.get_by_role('heading',name='审核已完成，尚未在本页启动任务').wait_for()
   page.set_viewport_size({'width':390,'height':844});assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
   assert not errors,errors
   browser.close()
  print('PASS: auto processing → same-tab review → save → return; pause/resume; no duplicate tabs; reviewed preservation; shared theme; draft reload; mobile; no JS errors')
 finally:server.terminate();server.wait(timeout=5)
