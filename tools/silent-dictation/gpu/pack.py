#!/usr/bin/env python3
"""Pack Chinese-LiPS clips for video-to-speech-feature training.

For each clip: 96x96 gray mouth frames (uint8, 25 fps) and the Qwen3-ASR audio encoder's output for its
audio (float16, 1024-d, about 13 frames a second): the target a visual encoder learns to predict, so a
frozen Qwen3-ASR decoder can read video. Writes <out>.frames.bin, <out>.feats.bin and <out>.json.

Usage: pack.py <clip dir> <meta csv> <out prefix> --qwen <snapshot dir>
Research use only (Chinese-LiPS is CC BY-NC-SA, no redistribution).
"""
import argparse, csv, json, multiprocessing as mp, unicodedata, wave
from pathlib import Path
import cv2, numpy as np, torch


def frames(path):
    cap = cv2.VideoCapture(str(path)); out = []
    while True:
        ok, x = cap.read()
        if not ok: break
        out.append(cv2.cvtColor(x, cv2.COLOR_BGR2GRAY))
    return np.stack(out) if out else None


def load(row):
    v = frames(row['mp4'])
    if v is None or v.shape[1:] != (96, 96) or not 10 <= len(v) <= 750: return None
    with wave.open(str(row['wav'])) as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1: return None
        a = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768
    return row, v, a


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('clips', type=Path); p.add_argument('meta'); p.add_argument('out')
    p.add_argument('--qwen', required=True); p.add_argument('--batch', type=int, default=16)
    a = p.parse_args()
    from qwen_asr import Qwen3ASRModel
    asr = Qwen3ASRModel.from_pretrained(a.qwen, dtype=torch.bfloat16, device_map='cuda')
    thinker = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    prompt = asr._build_text_prompt(context='', force_language='Chinese')
    rows = [dict(id=r['ID'], text=unicodedata.normalize('NFKC', r['TEXT']).strip(), topic=r['TOPIC'],
                 mp4=a.clips/f"{r['ID']}.mp4", wav=a.clips/f"{r['ID']}.wav") for r in csv.DictReader(open(a.meta, encoding='utf8'))]
    rows = [r for r in rows if r['mp4'].exists() and r['wav'].exists()]
    index, fo, xo, dropped = [], 0, 0, 0
    with open(a.out+'.frames.bin', 'wb') as F, open(a.out+'.feats.bin', 'wb') as X, mp.Pool(12) as pool:
        batch = []
        def flush():
            nonlocal fo, xo
            inp = asr.processor(text=[prompt]*len(batch), audio=[b[2] for b in batch], return_tensors='pt', padding=True).to('cuda')
            with torch.inference_mode():
                feats = thinker.get_audio_features(inp['input_features'].to(torch.bfloat16), feature_attention_mask=inp['feature_attention_mask'])
            counts = (inp['input_ids'] == thinker.config.audio_token_id).sum(1).tolist()
            for (r, v, au), f in zip(batch, torch.split(feats, counts)):
                F.write(v.tobytes()); X.write(f.float().cpu().numpy().astype(np.float16).tobytes())
                index.append(dict(id=r['id'], text=r['text'], topic=r['topic'], frames=len(v), foff=fo, feats=len(f), xoff=xo, samples=len(au)))
                fo += v.size; xo += f.numel()
            batch.clear()
        for start in range(0, len(rows), 512):  # Bounded: imap over everything outruns the GPU and fills RAM.
            for item in pool.map(load, rows[start:start+512], chunksize=8):
                if item is None: dropped += 1; continue
                batch.append(item)
                if len(batch) == a.batch: flush()
            print(start+512, len(rows), len(index), flush=True)
        if batch: flush()
    json.dump(dict(dim=1024, clips=index), open(a.out+'.json', 'w'), ensure_ascii=False)
    print('done', len(index), 'dropped', dropped, 'video frames', fo//9216, 'feature frames', xo//1024)


if __name__ == '__main__': main()
