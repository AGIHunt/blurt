#!/usr/bin/env python3
"""ViSpeR author crop functions with MediaPipe-derived five-point observations.

This tests the crop geometry, not full original detector parity. The original
detector's metadata is unavailable for participant clips. No recording is opened
for capture, and audio is neither read nor supplied to the recognizer.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time
import cv2
import numpy as np
from dataset import load_clips, sha256, write_json


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path);p.add_argument('--visper',type=Path,required=True)
    p.add_argument('--lipflow',type=Path,required=True)
    p.add_argument('--split',choices=['train','validation'],default='validation')
    a=p.parse_args();sys.path.insert(0,str(a.lipflow))
    from lipflow.face import FaceTracker
    spec=importlib.util.spec_from_file_location('visper_crop_utils',a.visper/'data_prepare/utils.py')
    upstream=importlib.util.module_from_spec(spec);spec.loader.exec_module(upstream)
    _,clips=load_clips(a.root)
    for c in clips:
        if c['split']!=a.split:continue
        source=a.root/'prepared'/c['id'];folder=a.root/'prepared-visper5'/c['id']
        status=folder/'status.json'
        if status.exists():raise ValueError('Refuse to replace an existing experiment')
        native=json.loads((source/'status.json').read_text());digest=sha256(a.root/c['video'])
        if native['status']!='ready' or native['signature']['source_sha256']!=digest:raise ValueError('Unready/stale input')
        signature=dict(source_sha256=digest,normalized_video_sha256=sha256(source/'video.mp4'),
                       crop_script_sha256=sha256(__file__),upstream_crop_sha256=sha256(a.visper/'data_prepare/utils.py'),
                       reference_sha256=sha256(a.visper/'data_prepare/20words_mean_face.npy'),
                       tracker_sha256=sha256(a.lipflow/'lipflow/face.py'),landmark_model_sha256=sha256(a.lipflow/'models/face_landmarker.task'))
        result=dict(id=c['id'],signature=signature,method='Author ViSpeR face crop + five-point alignment; MediaPipe eye centers, nose base, lip corners and mesh bounding box')
        start=time.perf_counter();cap=cv2.VideoCapture(str(source/'video.mp4'));tracker=FaceTracker()
        try:
            w,h=cap.get(cv2.CAP_PROP_FRAME_WIDTH),cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
            if abs(cap.get(cv2.CAP_PROP_FPS)-25)>.01:raise ValueError('Expected 25 fps')
            observations=[]
            while True:
                ok,frame=cap.read()
                if not ok:break
                obs=tracker.detect(frame,len(observations)*40)
                observations.append(obs)
            if any(o is None for o in observations):raise ValueError('Five-point probe requires all frames tracked')
            points=[];boxes=[]
            for obs in observations:
                points.append((np.vstack([obs.anchors[:2],obs.pts[2],obs.pts[61],obs.pts[291]])/[w,h]).tolist())
                boxes.append((np.r_[obs.pts.min(0),obs.pts.max(0)]/[w,h,w,h]).tolist())
            metadata=dict(start=0,end=len(points)/25,landmarks=points,bboxs=boxes)
            faces,landmarks=upstream.crop_video(str(source/'video.mp4'),metadata)
            color=upstream.crop_face(faces,landmarks)
            rois=np.stack([cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY) for frame in color])
            if rois.shape!=(len(points),96,96) or rois.dtype!=np.uint8:raise ValueError('Invalid crop output')
            folder.mkdir(parents=True,exist_ok=True);np.save(folder/'rois.npy',rois,allow_pickle=False)
            result.update(status='ready',frames=len(rois),rois_sha256=sha256(folder/'rois.npy'),usable_anchor_fraction=1.0)
        except Exception as e:result.update(status='failed',error=str(e))
        finally:cap.release();tracker.close()
        result['seconds']=time.perf_counter()-start;write_json(status,result)
        print(result['status'],c['id'],result.get('error',''),flush=True)


if __name__=='__main__':main()
