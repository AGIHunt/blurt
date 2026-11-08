#!/usr/bin/env python3
"""Download Chinese-LiPS files with parallel ranged requests (the 4090's mirror tops out per connection).

Usage: fetch.py <out dir> <file>...   Resumable: finished chunks are recorded in <file>.parts.
Research use only (CC BY-NC-SA, no redistribution).
"""
import os, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
BASE = os.environ.get('HF_BASE', 'https://huggingface.co')  + '/' + os.environ.get('HF_REPO', 'datasets/BAAI/Chinese-LiPS') + '/resolve/main/'
CHUNK, WORKERS = 64 << 20, 8


UA = {'User-Agent': 'curl/7.81.0'}  # The mirror's CDN refuses Python's default agent.


def size(name):
    req = urllib.request.Request(BASE+name, headers={**UA, 'Range': 'bytes=0-0'})
    with urllib.request.urlopen(req, timeout=30) as r:  # Small git files come back whole, without a range.
        return int(r.headers['Content-Range'].split('/')[1]) if r.headers['Content-Range'] else int(r.headers['Content-Length'])


def fetch(name, out):
    path, done_path = os.path.join(out, name), os.path.join(out, name+'.parts')
    total = size(name)
    if os.path.exists(path) and not os.path.exists(done_path) and os.path.getsize(path) == total: return print(name, 'already here')
    done = set(map(int, open(done_path).read().split())) if os.path.exists(done_path) else set()
    with open(path, 'ab') as f: f.truncate(total)
    lock, t0, got = threading.Lock(), time.time(), [0]
    def one(start):
        end = min(start+CHUNK, total)-1
        for attempt in range(8):
            try:
                req = urllib.request.Request(BASE+name, headers={**UA, 'Range': f'bytes={start}-{end}'})
                with urllib.request.urlopen(req, timeout=60) as r: data = r.read()
                if len(data) != end-start+1: raise IOError('short read')
                with lock:
                    with open(path, 'r+b') as f: f.seek(start); f.write(data)
                    with open(done_path, 'a') as d: d.write(f'{start}\n')
                    got[0] += len(data)
                return
            except Exception as e:
                time.sleep(2+attempt*3); err = e
        raise RuntimeError(f'{name} {start}: {err}')
    todo = [s for s in range(0, total, CHUNK) if s not in done]
    with ThreadPoolExecutor(WORKERS) as pool:
        for i, _ in enumerate(pool.map(one, todo)):
            if i % 16 == 15: print(name, f'{100*(len(done)+i+1)/(len(done)+len(todo)):.0f}%', f'{got[0]/(time.time()-t0)/1e6:.1f} MB/s', flush=True)
    os.remove(done_path); print(name, 'done', f'{total/1e9:.1f} GB', flush=True)


if __name__ == '__main__':
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    for name in sys.argv[2:]: fetch(name, out)
