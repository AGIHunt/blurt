#!/usr/bin/env python3
"""Step 2: split candidates into labeling batches, and later check and merge the labels.

  batches.py split <work> --size 105     writes <work>/batches/batch-NN.json (input for one labeling agent each)
  batches.py merge <work>                checks <work>/labels/batch-NN.jsonl against the input, writes <work>/labels.jsonl
The newest 15% of dictations (by time) are marked as the held-out test set in labels.jsonl.
"""
import json, sys
from pathlib import Path
HOME = Path.home()/'.blurt/dictation'


def split(work, size):
    rows = [json.loads(l) for l in open(work/'candidates.jsonl')]
    terms = [t['term'] for t in json.load(open(HOME/'vocabulary.json'))['terms'] if t.get('state') == 'active']
    (work/'batches').mkdir(exist_ok=True); (work/'labels').mkdir(exist_ok=True)
    for k in range(0, len(rows), size):
        items = [dict(id=r['id'], app=r['app'], field=r['field'], typed=r['typed'],
                      pieces=[dict(n=p['n'], qwen17=p['qwen17'], whisper=p['whisper'], qwen06=p['qwen06']) for p in r['pieces']]) for r in rows[k:k+size]]
        (work/'batches'/f'batch-{k//size:02d}.json').write_text(json.dumps(dict(terms=terms, dictations=items), ensure_ascii=False, indent=0))
    print('batches', (len(rows)+size-1)//size, 'dictations', len(rows), 'pieces', sum(len(r['pieces']) for r in rows))


def merge(work):
    rows = {json.loads(l)['id']: json.loads(l) for l in open(work/'candidates.jsonl')}
    order = sorted(rows, key=lambda i: rows[i]['t']); test = set(order[int(len(order)*.85):])
    out, problems = [], []
    for b in sorted((work/'batches').glob('batch-*.json')):
        want = json.loads(b.read_text())['dictations']; got = {}
        lf = work/'labels'/(b.stem+'.jsonl')
        if not lf.exists(): problems.append(f'{b.stem}: no labels'); continue
        for n, line in enumerate(open(lf)):
            if not line.strip(): continue
            try: x = json.loads(line); got[x['id']] = x
            except Exception as e: problems.append(f'{b.stem} line {n}: {e}')
        for d in want:
            x = got.get(d['id'])
            if not x: problems.append(f"{b.stem}: missing {d['id']}"); continue
            ps = {p['n']: p for p in x.get('pieces', [])}
            if set(ps) != {p['n'] for p in d['pieces']}: problems.append(f"{b.stem}: {d['id']} pieces differ"); continue
            r = rows[d['id']]
            out.append(dict(id=d['id'], t=r['t'], audio=r['audio'], split='test' if d['id'] in test else 'train', intended=x.get('intended', ''),
                            pieces=[dict(p, said=ps[p['n']]['said'], sure=bool(ps[p['n']].get('sure')), note=ps[p['n']].get('note', '')) for p in r['pieces']]))
    with open(work/'labels.jsonl', 'w') as f:
        for r in out: f.write(json.dumps(r, ensure_ascii=False)+'\n')
    P = [p for r in out for p in r['pieces']]
    print('merged', len(out), 'dictations', len(P), 'pieces, unsure', sum(not p['sure'] for p in P),
          'changed from 1.7B', sum(p['said'] != p['qwen17'] for p in P), 'test dictations', sum(r['split'] == 'test' for r in out))
    for p in problems[:30]: print('PROBLEM', p)


if __name__ == '__main__':
    work = Path(sys.argv[2])
    if sys.argv[1] == 'split': split(work, int(sys.argv[sys.argv.index('--size')+1]) if '--size' in sys.argv else 105)
    else: merge(work)
