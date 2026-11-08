#!/usr/bin/env python3
"""Compare Lipflow's MediaPipe FaceLandmarker preprocessing with native Vision crops.

Writes a separate crop tree, never replaces recordings or existing preparation.
Reads normalized video only. This is upstream Lipflow parity, not RetinaFace parity.
"""
import argparse
import json
from pathlib import Path
import sys
import time
import cv2
import numpy as np
from dataset import load_clips, sha256, write_json


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--checkout', type=Path, required=True)
    p.add_argument('--profiles', nargs='+', default=['zh', 'zh_en_mixed', 'en'])
    p.add_argument('--folder', default='prepared-mediapipe')
    args = p.parse_args()
    sys.path.insert(0, str(args.checkout))
    from lipflow.face import FaceTracker, mouth_rois
    _, clips = load_clips(args.root)
    for c in clips:
        if c.get('language_profile', c['language']) not in args.profiles: continue
        source = args.root / 'prepared' / c['id']
        folder = args.root / args.folder / c['id']; folder.mkdir(parents=True, exist_ok=True)
        native = json.loads((source / 'status.json').read_text())
        signature = dict(source_sha256=sha256(args.root / c['video']),
                         normalized_video_sha256=sha256(source / 'video.mp4'),
                         crop_script_sha256=sha256(__file__),
                         upstream_crop_sha256=sha256(args.checkout / 'lipflow/face.py'),
                         landmark_model_sha256=sha256(args.checkout / 'models/face_landmarker.task'))
        status = folder / 'status.json'
        if status.exists():
            old = json.loads(status.read_text())
            if old.get('signature') == signature and old.get('status') == 'ready' and sha256(folder/'rois.npy') == old['rois_sha256']:
                print('cached', c['id'], flush=True); continue
        result = dict(id=c['id'], signature=signature, method='Upstream Lipflow MediaPipe FaceLandmarker + mouth_rois')
        t = time.perf_counter(); tracker = FaceTracker(); cap = cv2.VideoCapture(str(source/'video.mp4'))
        try:
            if native['signature']['source_sha256'] != signature['source_sha256']: raise ValueError('Stale normalized video')
            if abs(cap.get(cv2.CAP_PROP_FPS)-25) > .01: raise ValueError('Expected 25 fps')
            gray, anchors = [], []
            while True:
                ok, frame = cap.read()
                if not ok: break
                obs = tracker.detect(frame, len(gray)*40)
                gray.append(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY))
                anchors.append(None if obs is None else obs.anchors)
            fraction = sum(a is not None for a in anchors)/len(anchors)
            if fraction < .95: raise ValueError('Fewer than 95% tracked frames')
            rois = mouth_rois(gray, anchors)
            if rois is None or rois.shape[1:] != (96,96): raise ValueError('Invalid crops')
            np.save(folder/'rois.npy', rois, allow_pickle=False)
            result.update(status='ready', frames=len(rois), rois_sha256=sha256(folder/'rois.npy'), usable_anchor_fraction=fraction)
        except Exception as e:
            result.update(status='failed', error=str(e))
        finally: tracker.close(); cap.release()
        result['seconds'] = time.perf_counter()-t
        write_json(status, result)
        print(result['status'],c['id'],flush=True)


if __name__ == '__main__': main()
