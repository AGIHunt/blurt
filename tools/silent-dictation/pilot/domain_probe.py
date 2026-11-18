#!/usr/bin/env python3
"""Local diagnostic: does the public-data encoder see the participant's crops well?

Reports toneless Pinyin error rate of the CTC head by mode at several crop zooms, so a geometry
mismatch between Chinese-LiPS crops and ours shows up as a better score at a zoom other than 1.

Usage: domain_probe.py <dataset> --checkpoint X.pth --pinyin vocab.json [--split validation]
"""
import argparse, json, re, sys
from collections import defaultdict
from pathlib import Path
import cv2, numpy as np, torch
sys.path.insert(0, str(Path(__file__).parent))
from eval_personal import load
from pypinyin import lazy_pinyin, Style


def edit(a, b):
    d = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            p, d[j] = d[j], min(d[j]+1, d[j-1]+1, p+(x != y))
    return d[-1]


def ref_pinyin(text):
    out = []
    for p in re.findall(r'[㐀-鿿]+|[A-Za-z]+|[0-9]', text):
        out += lazy_pinyin(p, style=Style.NORMAL, errors='ignore') if re.match(r'[㐀-鿿]', p) else [c.lower() for c in p]
    return out


def zoom(a, s):
    if s == 1: return a
    M = np.array([[s, 0, 48*(1-s)], [0, s, 48*(1-s)]], dtype=np.float32)
    return np.stack([cv2.warpAffine(f, M, (96, 96), borderMode=cv2.BORDER_REPLICATE) for f in a])


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('--visper', type=Path, default=Path.home()/'Library/Application Support/Blurt VSR Pilot/runtime/visper')
p.add_argument('--checkpoint', type=Path, required=True)
p.add_argument('--pinyin', type=Path, required=True)
p.add_argument('--crops', default='prepared-mediapipe')
p.add_argument('--split', default='validation')
p.add_argument('--zooms', type=float, nargs='+', default=[.75, .85, 1, 1.15, 1.3])
p.add_argument('--device', default='mps')
p.add_argument('--adabn', action='store_true', help='Recompute BatchNorm statistics on the train-session clips first')
p.add_argument('--sharpen', type=float, default=0, help='Unsharp-mask amount applied to every frame')
a = p.parse_args()
model, head, rev, _ = load(a.visper, a.checkpoint, a.pinyin, a.device)
model.encoder.to(a.device)


def tensor(rois):
    if a.sharpen:
        rois = np.stack([cv2.addWeighted(f, 1+a.sharpen, cv2.GaussianBlur(f, (0, 0), 2), -a.sharpen, 0) for f in rois])
    return ((torch.from_numpy(rois[:, 4:92, 4:92].copy()).float()/255-.421)/.165)[None, :, None].to(a.device)


if a.adabn:
    bns = [m for m in model.encoder.modules() if isinstance(m, torch.nn.modules.batchnorm._BatchNorm)]
    for m in bns: m.reset_running_stats(); m.momentum = None; m.train()
    for f in sorted((a.root/'clips').glob('v2-train-*.json')):
        c = json.loads(f.read_text())
        with torch.inference_mode(): model.encoder(tensor(np.load(a.root/a.crops/c['id']/'rois.npy')), None)
    for m in bns: m.eval()
    print('recalibrated', len(bns), 'BatchNorm layers')
clips = [c for c in (json.loads(f.read_text()) for f in sorted((a.root/'clips').glob('v2-*.json'))) if c['split'] == a.split and c.get('language_profile', c['language']) != 'en']
quality = json.loads((a.root/'runs/clip-quality-v1.json').read_text())['clips']
for s in a.zooms:
    tot = defaultdict(lambda: [0, 0])
    for c in clips:
        if quality[c['id']]['quality'] != 'complete': continue
        rois = zoom(np.load(a.root/a.crops/c['id']/'rois.npy'), s)
        x = tensor(rois)
        with torch.inference_mode():
            enc, _ = model.encoder(x, None)
            seq = head(enc)[0].argmax(-1).tolist()
        hyp = [rev[i] for i, b in zip(seq, [0]+seq) if i != b and i]
        ref = ref_pinyin(c['reference_text'])
        for k in (c['mode'], 'ALL'):
            tot[k][0] += edit(ref, hyp); tot[k][1] += len(ref)
    print(f'zoom {s:.2f} ' + '  '.join(f'{k} {v[0]/v[1]:.3f}' for k, v in sorted(tot.items())), flush=True)
