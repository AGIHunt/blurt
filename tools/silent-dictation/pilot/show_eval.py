#!/usr/bin/env python3
"""Print one or more eval_personal.py results side by side."""
import json, sys
runs = [(p.rsplit('/', 1)[-1], json.load(open(p))) for p in sys.argv[1:]]
keys = sorted({k for _, r in runs for k in r['all']})
for name, _ in runs: print('#', name)
for k in keys:
    cells = []
    for _, r in runs:
        a, c = r['all'].get(k), r['complete_only'].get(k)
        cells.append(f"{a['rate']*100:5.1f}% ({a['clips']})" + (f" clean {c['rate']*100:5.1f}% ({c['clips']})" if c else ' clean   -  '))
    print(k.ljust(30), ' | '.join(cells))
