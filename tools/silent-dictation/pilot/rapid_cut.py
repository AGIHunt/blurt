#!/usr/bin/env python3
"""Cut a RapidRecorder take into mouth-crop clips. Local only.

Reads sessions/<take>/{take.mov,marks.jsonl}; writes sessions/<take>/clips/<n>/rois.npy and
clips.json. Voiced segments are checked against the script with local Whisper and mismatches are
dropped; "free" segments take their label from Whisper. Silent segments are dropped if the audio
shows the participant spoke aloud by mistake. Reports light and sharpness so a dim take is caught
the day it is recorded.

Usage: rapid_cut.py <session dir> [--checkout <lipflow>] [--no-asr]
"""
import argparse, difflib, json, subprocess, sys, tempfile, time
from pathlib import Path
import cv2, numpy as np

MARGIN = .12


def segments(path):
    out = []
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r['kind'] == 'segment': out.append(r)
        elif r['kind'] == 'void_last' and out: out.pop()
    return out


def cut(video, start, end, target, audio=None):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{max(start-MARGIN, 0):.3f}', '-to', f'{end+MARGIN:.3f}', '-i', str(video), '-map', '0:v:0', '-an',
                    '-vf', "scale='min(1280,iw)':-2,fps=25,setpts=PTS-STARTPTS,setsar=1", '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '12', str(target)], check=True)
    if audio:
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{max(start-MARGIN, 0):.3f}', '-to', f'{end+MARGIN:.3f}', '-i', str(video), '-map', '0:a:0', '-ac', '1', '-ar', '16000', str(audio)], check=True)


def rois_for(path, tracker_cls, mouth_rois):
    tracker = tracker_cls(); cap = cv2.VideoCapture(str(path)); gray, anchors = [], []
    try:
        while True:
            ok, frame = cap.read()
            if not ok: break
            obs = tracker.detect(frame, len(gray)*40)
            gray.append(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)); anchors.append(None if obs is None else obs.anchors)
    finally: tracker.close(); cap.release()
    if not gray or sum(a is not None for a in anchors)/len(anchors) < .95: return None
    return mouth_rois(gray, anchors)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('session', type=Path)
    p.add_argument('--checkout', type=Path, default=Path.home()/'Library/Application Support/Blurt VSR Pilot/runtime/lipflow')
    p.add_argument('--model', default='mlx-community/whisper-large-v3-mlx')
    p.add_argument('--no-asr', action='store_true')
    p.add_argument('--marks', default='marks.jsonl', help='Marks file inside the session; free_label.py writes marks-reviewed.jsonl')
    p.add_argument('--min-match', type=float, default=.6)
    a = p.parse_args()
    sys.path.insert(0, str(a.checkout))
    from lipflow.face import FaceTracker, mouth_rois
    transcribe = None
    if not a.no_asr:
        import mlx_whisper
        transcribe = lambda wav: mlx_whisper.transcribe(wav, path_or_hf_repo=a.model, language='zh', temperature=0, condition_on_previous_text=False)['text'].strip()
    segs = segments(a.session/a.marks); out = a.session/'clips'; out.mkdir(exist_ok=True)
    video = a.session/'take.mov'; kept = []; dropped = dict(no_face=0, spoke_aloud=0, asr_mismatch=0, empty_speech=0); t0 = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        for n, s in enumerate(segs):
            mp4, wav = f'{tmp}/{n}.mp4', f'{tmp}/{n}.wav'
            cut(video, s['start'], s['end'], mp4, None if a.no_asr else wav)
            text = s.get('text', '')
            if transcribe:
                heard = transcribe(wav)
                if s['mode'] == 'silent':
                    if len(heard) >= 4 and difflib.SequenceMatcher(None, heard, text).ratio() > .4: dropped['spoke_aloud'] += 1; continue
                elif s['mode'] == 'free':
                    if not heard: dropped['empty_speech'] += 1; continue
                    text = heard
                elif difflib.SequenceMatcher(None, heard, text).ratio() < a.min_match: dropped['asr_mismatch'] += 1; continue
            rois = rois_for(mp4, FaceTracker, mouth_rois)
            if rois is None or rois.shape[1:] != (96, 96) or len(rois) < 15: dropped['no_face'] += 1; continue
            folder = out/f'{n:05d}'; folder.mkdir(exist_ok=True); np.save(folder/'rois.npy', rois, allow_pickle=False)
            kept.append(dict(id=f'{a.session.name}/{n:05d}', folder=str(folder), mode=s['mode'], text=text, line=s.get('line', ''), seconds=s['end']-s['start'], frames=len(rois),
                             sharpness=float(np.mean([cv2.Laplacian(f, cv2.CV_64F).var() for f in rois[::5]])), brightness=float(rois.mean())))
            if n % 20 == 0: print(n, len(segs), f'{time.time()-t0:.0f}s', flush=True)
    (a.session/'clips.json').write_text(json.dumps(kept, ensure_ascii=False, indent=1))
    sharp = np.median([c['sharpness'] for c in kept]) if kept else 0
    print(f'kept {len(kept)}/{len(segs)} dropped {dropped} seconds {sum(c["seconds"] for c in kept):.0f} sharpness {sharp:.0f} (train session 190, dim validation 87)')
    if kept and sharp < 120: print('WARNING: this take looks dim or blurry; add light before recording more')


if __name__ == '__main__': main()
