#!/usr/bin/env python3
"""Step 3: the person checks the pieces the labelers were unsure of, in the browser, on a free local port.

Shows the piece's audio, the labeler's text (editable), its note, the three model transcripts and the dictation's
other pieces for context. Enter accepts, Ctrl+D drops the piece, Ctrl+R replays, Ctrl+1/2/3 copies a model's
transcript into the box. Writes <work>/reviewed.jsonl (resumable). Test pieces come first: they decide the score.
Serves only this Mac.

Usage: review.py <work dir> [--test-only] [--no-open]
"""
import http.server, json, subprocess, sys, threading, wave, io
from pathlib import Path
HOME = Path.home()/'.blurt/dictation'; RATE = 16000

PAGE = '''<!doctype html><meta charset=utf-8><title>确认听写</title><style>
body{font:17px -apple-system;max-width:820px;margin:28px auto;padding:0 16px;color:#222;background:#fafafa}
textarea{width:100%;font:22px -apple-system;padding:10px;box-sizing:border-box;border:1px solid #bbb;border-radius:8px;margin-top:10px;height:90px}
.c{color:#555;margin:4px 0}.ctx{color:#999;font-size:14px;margin-top:14px;white-space:pre-wrap}#note{color:#b45309;margin-top:6px}#hint{color:#888;font-size:14px;margin-top:14px}
audio{width:100%;margin-top:8px}</style>
<div id=count></div><audio id=a controls autoplay></audio><textarea id=t></textarea><div id=note></div>
<div class=c id=c1></div><div class=c id=c2></div><div class=c id=c3></div><div class=ctx id=ctx></div>
<div id=hint>Enter 确认　Ctrl+D 丢掉这段　Ctrl+R 再听　Ctrl+1/2/3 用对应版本。按实际说的写，口头禅和重复都保留。</div><script>
let items=[],i=0;const $=x=>document.getElementById(x);
fetch('/items').then(r=>r.json()).then(j=>{items=j;show()});
function show(){if(i>=items.length){document.body.innerHTML='<h2>都确认完了，可以关掉这个页面。</h2>';fetch('/done',{method:'POST'});return}
const r=items[i];$('count').textContent=`第 ${i+1} / ${items.length} 段`+(r.split==='test'?'（测试集）':'');$('t').value=r.said;$('note').textContent=r.note?('拿不准：'+r.note):'';
$('c1').textContent='1 口喷鸡当时：'+r.qwen17;$('c2').textContent='2 Whisper：'+r.whisper;$('c3').textContent='3 Qwen 0.6B：'+r.qwen06;
$('ctx').textContent='这条听写的其他段：\\n'+r.context;$('a').src='/audio/'+i+'.wav';$('t').focus()}
function save(b){fetch('/save',{method:'POST',body:JSON.stringify(Object.assign({k:i},b))});i++;show()}
document.addEventListener('keydown',e=>{const r=items[i];if(!r)return;
if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();save({said:$('t').value.trim()})}
if(e.ctrlKey&&e.key==='d'){e.preventDefault();save({drop:true})}
if(e.ctrlKey&&e.key==='r'){e.preventDefault();$('a').currentTime=0;$('a').play()}
if(e.ctrlKey&&['1','2','3'].includes(e.key)){e.preventDefault();$('t').value=[r.qwen17,r.whisper,r.qwen06][+e.key-1]}})
</script>'''


def main():
    work = Path(sys.argv[1]); out = work/'reviewed.jsonl'
    done = {(x['id'], x['n']) for x in map(json.loads, open(out))} if out.exists() else set()
    items = []
    for r in map(json.loads, open(work/'labels.jsonl')):
        if '--test-only' in sys.argv and r['split'] != 'test': continue
        for p in r['pieces']:
            if not p['sure'] and (r['id'], p['n']) not in done:
                ctx = '\n'.join(('→ ' if q['n'] == p['n'] else '  ')+q['said'] for q in r['pieces'])
                items.append(dict(id=r['id'], n=p['n'], split=r['split'], audio=r['audio'], start=p['start'], end=p['end'], said=p['said'], note=p['note'],
                                  qwen17=p['qwen17'], whisper=p['whisper'], qwen06=p['qwen06'], context=ctx))
    items.sort(key=lambda x: x['split'] != 'test')
    if not items: print('nothing to review'); return

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def send(self, body, kind):
            self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def do_GET(self):
            if self.path == '/': self.send(PAGE.encode(), 'text/html; charset=utf-8')
            elif self.path == '/items': self.send(json.dumps(items, ensure_ascii=False).encode(), 'application/json')
            elif self.path.startswith('/audio/'):
                x = items[int(self.path.split('/')[-1].split('.')[0])]
                with wave.open(str(HOME/x['audio'])) as w: y = w.readframes(w.getnframes())
                buf = io.BytesIO()
                with wave.open(buf, 'wb') as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(y[int(max(x['start']-.2, 0)*RATE)*2:int((x['end']+.2)*RATE)*2])
                self.send(buf.getvalue(), 'audio/wav')
            else: self.send_error(404)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            if self.path == '/save':
                b = json.loads(body); x = items[b['k']]
                with open(out, 'a') as f: f.write(json.dumps(dict(id=x['id'], n=x['n'], said=b.get('said', x['said']), drop=bool(b.get('drop'))), ensure_ascii=False)+'\n')
            self.send(b'ok', 'text/plain')
            if self.path == '/done': threading.Thread(target=server.shutdown).start()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = f'http://127.0.0.1:{server.server_address[1]}'
    print('open', url, len(items), 'pieces', sum(x['split'] == 'test' for x in items), 'of them test', flush=True)
    if '--no-open' not in sys.argv: subprocess.Popen(['open', url])
    server.serve_forever()


if __name__ == '__main__': main()
