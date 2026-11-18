#!/usr/bin/env python3
"""Known-command retrieval diagnostic. NOT open-vocabulary speech recognition.

One voiced template per phrase; query silent/whisper/exaggerated modes separately.
Only video enters the encoder. Same-session prompted results need a later fresh test.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import sys
import time
import numpy as np
import torch
from dataset import load_clips, sha256, write_json


def normalized_sequence(features, size=32):
    positions = np.linspace(0, len(features)-1, size)
    resampled = np.stack([np.interp(positions, np.arange(len(features)), features[:,j]) for j in range(features.shape[1])], axis=1)
    return resampled / np.maximum(np.linalg.norm(resampled,axis=1,keepdims=True),1e-8)


def distance(a,b):
    cost=1-a@b.T
    path=np.full((len(a)+1,len(b)+1),np.inf);path[0,0]=0
    for i in range(1,len(a)+1):
        for j in range(max(1,i-8),min(len(b),i+8)+1):
            path[i,j]=cost[i-1,j-1]+min(path[i-1,j],path[i,j-1],path[i-1,j-1])
    return float(path[-1,-1]/(len(a)+len(b)))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path);p.add_argument('--checkout',type=Path,required=True)
    p.add_argument('--crop-folder',default='prepared');p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.output.exists():raise ValueError('Choose a new output filename')
    sys.path.insert(0,str(a.checkout))
    from lipflow.vsr import LipReader
    torch.set_num_threads(4)
    _,clips=load_clips(a.root);clips=[c for c in clips if c['split']=='train']
    reader=LipReader(device='mps',beam_size=1,use_lm=False,personal=False)
    templates=[c for c in clips if c['mode']=='voiced']
    if len(templates)!=len({c['phrase_family'] for c in templates}):raise ValueError('Expected one template per phrase')
    arrays={};times={}
    for c in clips:
        folder=a.root/a.crop_folder/c['id'];meta=json.loads((folder/'status.json').read_text())
        if meta['status']!='ready' or meta['signature']['source_sha256']!=sha256(a.root/c['video']):raise ValueError('Unready/stale crops')
        if meta['rois_sha256']!=sha256(folder/'rois.npy'):raise ValueError('Crop hash changed')
        rois=np.load(folder/'rois.npy',allow_pickle=False);t=time.perf_counter()
        with torch.inference_mode():features=reader.encode(rois).detach().cpu().numpy()
        arrays[c['id']]=normalized_sequence(features);times[c['id']]=time.perf_counter()-t
        print('encoded',c['id'],flush=True)
    rows=[]
    for c in clips:
        if c['mode']=='voiced':continue
        ranked=sorted([(distance(arrays[c['id']],arrays[t['id']]),t) for t in templates],key=lambda x:x[0])
        duration_pick=min(templates,key=lambda t:abs(c['duration_seconds']-t['duration_seconds']))
        rows.append(dict(id=c['id'],mode=c['mode'],reference_family=c['phrase_family'],reference_text=c['reference_text'],
            predicted_family=ranked[0][1]['phrase_family'],hypothesis=ranked[0][1]['reference_text'],
            correct=ranked[0][1]['phrase_family']==c['phrase_family'],distance=ranked[0][0],margin=ranked[1][0]-ranked[0][0],
            duration_baseline_correct=duration_pick['phrase_family']==c['phrase_family'],
            encoder_seconds=times[c['id']],top3=[dict(phrase=t['phrase_family'],distance=d) for d,t in ranked[:3]]))
    groups=defaultdict(list)
    for r in rows:groups[r['mode']].append(r)
    summary=[dict(mode=m,queries=len(g),correct=sum(r['correct'] for r in g),duration_baseline_correct=sum(r['duration_baseline_correct'] for r in g)) for m,g in groups.items()]
    result=dict(scope='Same-session known-command retrieval with one voiced video template per phrase; NOT free-form dictation or independent validation',
        audio_used=False,templates=[dict(id=t['id'],phrase=t['phrase_family'],text=t['reference_text']) for t in templates],
        checkpoint_sha256=sha256(a.checkout/'models/vsr/model.pth'),crop_folder=a.crop_folder,
        algorithm='Cosine DTW on 32-frame-resampled VSR encoder features, band 8; no fitted threshold',summary=summary,clips=rows)
    write_json(a.output,result);print(json.dumps(summary,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
