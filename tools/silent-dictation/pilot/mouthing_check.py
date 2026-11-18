"""Voiced sentences vs their silent takes: lip-gap range, jaw range, duration, sealed-lip frames. Args: voiced session, silent session (pairs of names), run where the landmark .npz files are. No sentence text printed."""
import json, sys, numpy as np
from pathlib import Path
from scipy.stats import wilcoxon
S = Path.home()/'Library/Application Support/Blurt VSR Pilot/rapid/sessions'

def spans(session, name, mode):
    out = []
    for line in open(S/session/name):
        m = json.loads(line)
        if m.get('kind') == 'void_last':
            if out: out.pop()
        elif m.get('kind', 'segment') == 'segment' and m.get('mode', mode) == mode: out.append(m)
    return {m['line']: (m['start'], m['end']) for m in out}

def gap(npz):
    z = np.load(npz); lm = z['lm']; t = z['t']/1000
    iod = np.linalg.norm(lm[:, 263, :2]-lm[:, 33, :2], axis=1)
    pair = lambda a, b: np.linalg.norm(lm[:, a, :2]-lm[:, b, :2], axis=1)
    ap = (pair(82, 87)+pair(13, 14)+pair(312, 317))/3/np.nanmedian(iod)
    jaw = pair(13, 152)/np.nanmedian(iod)
    return t, ap, jaw

def active(ap):
    """Trim idle frames at both ends: keep from first to last frame where the lips move."""
    v = np.abs(np.diff(np.nan_to_num(ap), prepend=ap[0])); v = np.convolve(v, np.ones(7)/7, 'same')
    on = np.where(v > .4*np.percentile(v, 90))[0]
    return ap[on[0]:on[-1]+1] if len(on) > 10 else ap

def feats(t, ap, jaw, a, b):
    i = (t >= a) & (t < b); x = ap[i]; x = x[~np.isnan(x)]
    if len(x) < 15: return None
    y = active(x); j = jaw[i]; j = j[~np.isnan(j)]
    return dict(range=np.percentile(y, 95)-np.percentile(y, 5), sealed=float((y < .01).mean()),
                jaw=np.percentile(j, 95)-np.percentile(j, 5), dur=len(y)/30)

rows = []
for VOICED, SILENT in zip(sys.argv[1::2], sys.argv[2::2]):
  vname = 'marks-reviewed.jsonl' if (S/VOICED/'marks-reviewed.jsonl').exists() else 'marks.jsonl'
  v, s = spans(VOICED, vname, 'voiced'), spans(SILENT, 'marks.jsonl', 'silent')
  TV = gap(f'{VOICED}.npz'); TS = TV if SILENT == VOICED else gap(f'{SILENT}.npz')
  for line in s:
    if line not in v: continue
    fv, fs = feats(*TV, *v[line]), feats(*TS, *s[line])
    if fv and fs: rows.append((fv, fs))
print('pairs', len(rows))
for k in ('range', 'jaw', 'dur'):
    r = np.array([b[k]/a[k] for a, b in rows if a[k] > 0])
    print(f'{k:6s} silent/voiced median {np.median(r):.2f}  IQR {np.percentile(r,25):.2f}-{np.percentile(r,75):.2f}  p {wilcoxon(np.log(r)).pvalue:.3g}')
sv, ss = np.array([a['sealed'] for a, b in rows]), np.array([b['sealed'] for a, b in rows])
print(f'sealed frames voiced {100*sv.mean():.0f}%  silent {100*ss.mean():.0f}%  diff {100*(ss-sv).mean():+.0f} points')
