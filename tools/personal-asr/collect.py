#!/usr/bin/env python3
"""Step 1 of personal ASR fine-tuning: gather second opinions on every kept dictation.

Reads Blurt's history (~/.blurt/dictation/history.jsonl and audio/), cuts each dictation into the pieces the app
already found at pauses, and transcribes each piece with two local models besides the shipped Qwen3-ASR 1.7B:
Whisper large-v3 (MLX) and Qwen3-ASR 0.6B, both given the user's word list. Nothing leaves this Mac.
Writes <work>/candidates.jsonl, one dictation per line. Resumable: finished dictations are skipped.

Usage: collect.py <work dir> [--limit N]
"""
import argparse, json, re, wave
from pathlib import Path
import numpy as np
HOME = Path.home()/'.blurt/dictation'; RATE = 16000


def audio(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('work', type=Path); p.add_argument('--limit', type=int, default=0)
    p.add_argument('--whisper', default='mlx-community/whisper-large-v3-mlx')
    a = p.parse_args(); a.work.mkdir(parents=True, exist_ok=True)
    out = a.work/'candidates.jsonl'
    done = {json.loads(l)['id'] for l in open(out)} if out.exists() else set()
    rows = [json.loads(l) for l in open(HOME/'history.jsonl') if l.strip()]
    rows = [r for r in rows if r.get('audio') and r.get('pieces') and (HOME/r['audio']).exists() and r['id'] not in done]
    if a.limit: rows = rows[:a.limit]
    terms = [t['term'] for t in json.load(open(HOME/'vocabulary.json'))['terms'] if t.get('state') == 'active']
    words = '、'.join(terms)
    import torch, mlx_whisper
    from qwen_asr import Qwen3ASRModel
    snap = next((Path.home()/'.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots').iterdir())
    small = Qwen3ASRModel.from_pretrained(str(snap), dtype=torch.float16, device_map='mps', max_new_tokens=160)
    print('dictations to do', len(rows), 'terms', len(terms), flush=True)
    with open(out, 'a') as f:
        for k, r in enumerate(rows):
            y = audio(HOME/r['audio']); pieces = []
            for n, pc in enumerate(r['pieces']):
                seg = y[int(pc['start']*RATE):int(pc['end']*RATE)]
                if len(seg) < RATE*.3: continue
                w = mlx_whisper.transcribe(seg, path_or_hf_repo=a.whisper, language='zh', temperature=0, condition_on_previous_text=False, initial_prompt=words)['text'].strip()
                q = small.transcribe(audio=(seg, RATE), context=words, language='Chinese')[0].text.strip()
                pieces.append(dict(n=n, start=pc['start'], end=pc['end'], qwen17=pc.get('asr_text') or pc.get('raw') or '', whisper=w, qwen06=q))
            ctx = re.sub(r'[​\s]+', ' ', str(r.get('context') or ''))[:400]
            f.write(json.dumps(dict(id=r['id'], t=r['t'], app=r.get('app'), field=ctx, typed=r.get('text') or '', audio=r['audio'], duration=r.get('duration'), pieces=pieces), ensure_ascii=False)+'\n'); f.flush()
            if k % 25 == 0: print(k, len(rows), flush=True)


if __name__ == '__main__': main()
