#!/usr/bin/env python3
"""Keyboard review of uncertain sentences in the browser, on a free local port. Enter accepts, Tab swaps in the other
transcription, Ctrl+D drops, Ctrl+R replays. Serves only this Mac. Label what was actually said.

Usage: free_review.py <session>
"""
import http.server, json, subprocess, sys, tempfile, threading
from pathlib import Path

PAGE = '''<!doctype html><meta charset=utf-8><title>确认句子</title><style>
body{font:18px -apple-system;max-width:760px;margin:32px auto;padding:0 16px;color:#222;background:#fafafa}
video{width:100%;border-radius:8px;background:#000;max-height:360px}textarea{width:100%;font:24px -apple-system;padding:10px;box-sizing:border-box;border:1px solid #bbb;border-radius:8px;margin-top:12px;height:96px}
#alt{color:#666;margin:8px 0}#hint{color:#888;font-size:15px;margin-top:16px}</style>
<div id=count></div><video id=v controls autoplay></video><textarea id=t></textarea><div id=alt></div>
<div id=hint>Enter 确认　Tab 换成另一个版本　Ctrl+D 丢掉　Ctrl+R 再听一遍。按实际说的内容写，说错了也照写。</div><script>
let items=[],i=0;const $=x=>document.getElementById(x);
fetch('/items').then(r=>r.json()).then(j=>{items=j;show()});
function show(){if(i>=items.length){document.body.innerHTML='<h2>都确认完了，可以关掉这个页面。</h2>';fetch('/done',{method:'POST'});return}
const r=items[i];$('count').textContent=`第 ${i+1} / ${items.length} 条`;$('t').value=r.text;$('alt').textContent='另一个版本：'+r.alt;$('v').src='/clip/'+r.n+'.mp4';$('t').focus()}
function save(b){fetch('/save',{method:'POST',body:JSON.stringify(b)});i++;show()}
document.addEventListener('keydown',e=>{const r=items[i];if(!r)return;
if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();save({n:r.n,text:$('t').value.trim(),status:'confirmed'})}
if(e.key==='Tab'){e.preventDefault();const a=$('t').value;$('t').value=r.alt;r.alt=a;$('alt').textContent='另一个版本：'+a}
if(e.ctrlKey&&e.key==='d'){e.preventDefault();save({n:r.n,status:'dropped'})}
if(e.ctrlKey&&e.key==='r'){e.preventDefault();$('v').currentTime=0;$('v').play()}})
</script>'''


def main():
    session = Path(sys.argv[1]); rows = json.loads((session/'segments.json').read_text()); path = session/'segments.json'
    todo = [r for r in rows if r['status'] == 'review']
    if not todo: print('nothing to review'); return
    tmp = tempfile.TemporaryDirectory()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def send(self, body, kind):
            self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def do_GET(self):
            if self.path == '/': self.send(PAGE.encode(), 'text/html; charset=utf-8')
            elif self.path == '/items': self.send(json.dumps(todo, ensure_ascii=False).encode(), 'application/json')
            elif self.path.startswith('/clip/'):
                r = rows[int(self.path.split('/')[-1].split('.')[0])]; out = Path(tmp.name)/f"{r['n']}.mp4"
                if not out.exists(): subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(r['start']), '-to', str(r['end']), '-i', str(session/'take.mov'), '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', '-movflags', '+faststart', str(out)], check=True)
                self.send(out.read_bytes(), 'video/mp4')
            else: self.send_error(404)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            if self.path == '/save':
                b = json.loads(body); r = rows[b['n']]; r['status'] = b['status']
                if 'text' in b: r['text'] = b['text']
                path.write_text(json.dumps(rows, ensure_ascii=False, indent=1))
            self.send(b'ok', 'text/plain')
            if self.path == '/done': threading.Thread(target=server.shutdown).start()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = f'http://127.0.0.1:{server.server_address[1]}'
    print('open', url, len(todo), 'sentences', flush=True)
    if '--no-open' not in sys.argv: subprocess.Popen(['open', url])
    server.serve_forever()


if __name__ == '__main__': main()
