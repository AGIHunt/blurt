#!/usr/bin/env python3
"""Build a reading script from the participant's own Blurt history. Local only; nothing is uploaded.

The newest 15% of dictations go to script-test.json and are never shown while recording training
takes, so a later test session reads sentences the model has not seen.

Usage: rapid_script.py [--history ~/.blurt/dictation/history.jsonl] [--out <rapid dir>]
"""
import argparse, hashlib, json, random, re, unicodedata
from pathlib import Path

CUT = re.compile(r'(?<=[。！？!?；;\n])')
BLOCK = re.compile(r'https?://|www\.|@|\d{5,}|[/\\]\w+[/\\]')


def units(s): return sum(1 for c in s if c.isalnum())


def sentences(text):
    out = []; buffer = ''
    for part in CUT.split(text):
        part = part.strip()
        if not part: continue
        buffer += part
        if units(buffer) >= 6: out.append(buffer); buffer = ''
    if buffer and out and units(out[-1])+units(buffer) <= 40: out[-1] += buffer
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--history', type=Path, default=Path.home()/'.blurt/dictation/history.jsonl')
    p.add_argument('--out', type=Path, default=Path.home()/'Library/Application Support/Blurt VSR Pilot/rapid')
    p.add_argument('--max-units', type=int, default=40)
    a = p.parse_args()
    rows = [json.loads(l) for l in a.history.open() if l.strip()]
    cut = int(len(rows)*.85); seen = set(); train = []; test = []
    for i, r in enumerate(rows):
        for s in sentences(unicodedata.normalize('NFKC', r.get('text') or '')):
            key = ''.join(c for c in s.casefold() if c.isalnum())
            if key in seen or BLOCK.search(s) or not 6 <= units(s) <= a.max_units: continue
            seen.add(key)
            (train if i < cut else test).append(dict(id=hashlib.sha1(key.encode()).hexdigest()[:12], text=s, app=r.get('app')))
    random.Random(11).shuffle(train)
    a.out.mkdir(parents=True, exist_ok=True)
    for name, data in (('script.json', train), ('script-test.json', test)):
        (a.out/name).write_text(json.dumps(data, ensure_ascii=False, indent=1))
    n = sum(units(x['text']) for x in train)
    print(f'history {len(rows)} -> train {len(train)} sentences, {n} units; test {len(test)} sentences')
    print(f'read aloud at 4 units/s: about {n/4/60:.0f} min one pass, {n/2/60:.0f} min as voiced+silent pairs')


if __name__ == '__main__': main()
