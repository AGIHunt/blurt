#!/usr/bin/env python3
"""Small warm offline ViSpeR latency probe; excludes capture, cropping and insertion."""
import argparse
import json
from pathlib import Path
import resource
import statistics
import time
import numpy as np
import torch
from dataset import load_clips, sha256, write_json
from multilingual_probe import setup, decode


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path)
    p.add_argument('--checkout',type=Path,required=True)
    p.add_argument('--checkpoint',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args(); a.backend='visper'; a.device='mps'; a.beam=10
    if a.output.exists(): raise ValueError('Choose new output path')
    torch.set_num_threads(4)
    _,clips=load_clips(a.root)
    clips=[c for c in clips if c['split']=='train' and c['mode']=='silent']
    chosen=[max((c for c in clips if c.get('language_profile',c['language'])==profile),
                key=lambda c:c['duration_seconds']) for profile in ['zh','zh_en_mixed','en']]
    start=time.perf_counter();model,beam,tokens=setup(a);load=time.perf_counter()-start
    rows=[]
    for c in chosen:
        folder=a.root/'prepared-mediapipe'/c['id'];meta=json.loads((folder/'status.json').read_text())
        if meta['status']!='ready' or meta['signature']['source_sha256']!=sha256(a.root/c['video']): raise ValueError('Stale media')
        if meta['rois_sha256']!=sha256(folder/'rois.npy'):raise ValueError('Stale crops')
        rois=np.load(folder/'rois.npy',allow_pickle=False);profile=c.get('language_profile',c['language'])
        times=[]; outputs=[]
        for repeat in range(4):
            torch.mps.synchronize();start=time.perf_counter()
            outputs.append(decode(model,beam,tokens,rois,profile,a))
            torch.mps.synchronize();times.append(time.perf_counter()-start)
        rows.append(dict(id=c['id'],language_profile=profile,input_seconds=len(rois)/25,
                         first_seconds=times[0],warm_seconds=times[1:],warm_median_seconds=statistics.median(times[1:]),
                         warm_output_consistent=len(set(outputs[1:]))==1,
                         source_sha256=meta['signature']['source_sha256']))
        print(rows[-1],flush=True)
    write_json(a.output,dict(scope=__doc__,checkpoint_sha256=sha256(a.checkpoint),model_load_seconds=load,
        threads=4,beam=10,repeats=3,selection='Longest recorded natural-silent training clip per language profile',
        peak_process_rss_bytes_macos=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        final_mps_allocated_bytes=torch.mps.current_allocated_memory(),
        final_mps_driver_bytes_including_cache=torch.mps.driver_allocated_memory(),clips=rows))


if __name__=='__main__':main()
