#!/usr/bin/env python3
"""Experimental Vision anchors → mouth crops. Requires numpy and OpenCV.

This approximates the reference alignment; it is NOT preprocessing parity.
Input video must be normalized to 25 fps and match vision_probe --anchors exactly.
"""
import argparse
import json
import subprocess
import cv2
import numpy as np

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--video', required=True)
p.add_argument('--anchors', required=True)
p.add_argument('--mean-face', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
data = json.load(open(a.anchors))
anchors = data['anchors_image_xy']
valid = [i for i, value in enumerate(anchors) if value is not None]
if not valid:
    raise RuntimeError('No valid face anchors')
raw = np.array([anchors[i] for i in valid])
lms = np.empty((len(anchors), 4, 2))
for j in range(4):
    for k in range(2):
        lms[:, j, k] = np.interp(np.arange(len(anchors)), valid, raw[:, j, k])
mean = np.load(a.mean_face, allow_pickle=False)
reference = np.vstack([mean[36:42].mean(0), mean[42:48].mean(0), mean[31:36].mean(0), mean[48:68].mean(0)])
metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=avg_frame_rate', '-of', 'json', a.video]))
numerator, denominator = map(float, metadata['streams'][0]['avg_frame_rate'].split('/'))
if abs(numerator / denominator - 25) > 0.01:
    raise ValueError('Normalize input to 25 fps first')
pixels = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', a.video, '-an', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'])
frames = np.frombuffer(pixels, dtype=np.uint8).reshape(-1, data['height'], data['width'])
if len(frames) != len(anchors):
    raise ValueError('Video frame count differs from anchor sequence')
rois = []
for i, landmarks in enumerate(lms):
    margin = min(6, i, len(lms) - 1 - i)
    smoothed = lms[i-margin:i+margin+1].mean(0)
    smoothed += landmarks.mean(0) - smoothed.mean(0)
    transform, _ = cv2.estimateAffinePartial2D(smoothed.astype(np.float32), reference.astype(np.float32), method=cv2.LMEDS)
    if transform is None:
        raise RuntimeError('Alignment failed')
    center = smoothed[3] @ transform[:, :2].T + transform[:, 2]
    cx, cy = np.rint(np.clip(center, 48, 208)).astype(int)
    aligned = cv2.warpAffine(frames[i], transform, (256, 256))
    rois.append(aligned[cy-48:cy+48, cx-48:cx+48])
np.save(a.output, np.stack(rois), allow_pickle=False)
print(json.dumps({'frames': len(rois), 'preprocessing': 'experimental Apple Vision anchors', 'output': a.output}))
