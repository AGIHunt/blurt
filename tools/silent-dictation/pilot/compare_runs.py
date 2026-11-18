#!/usr/bin/env python3
"""Paired CER/MER table across runs on the same clips. Each argument is name=path[:rescored]."""
import json, sys
from collections import defaultdict


def table(path, key):
    g = defaultdict(lambda: [0, 0]); clips = []
    for p in path.split('+'): clips += json.load(open(p))['clips']
    for c in clips:
        if c['profile'] == 'en': continue
        for k in ((c['profile'], c['mode']), ('ALL', c['mode'])):
            g[k][0] += c[key]['errors']; g[k][1] += c[key]['reference_units']
    return {k: v[0]/v[1] for k, v in g.items()}


cols = []
for arg in sys.argv[1:]:
    name, path = arg.split('=', 1)
    key = 'accuracy'
    if path.endswith(':rescored'): path, key = path[:-9], 'rescored_accuracy'
    cols.append((name, table(path, key)))
print(' '*32+''.join(f'{n:>13}' for n, _ in cols))
for k in sorted(cols[0][1]): print(f'{k[0]+"/"+k[1]:32}'+''.join(f'{t[k]*100:12.1f}%' for _, t in cols))
