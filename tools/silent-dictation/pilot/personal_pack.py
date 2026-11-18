#!/usr/bin/env python3
"""Pack the participant's rapid and free-talk clips in gpu/pack.py's format, for v2a fine-tuning.

Frames come from each clip's rois.npy (96x96 gray, 25 fps). Voiced clips also get the Qwen3-ASR audio-encoder
output for their own audio, cut from take.mov over the same span as the video; silent clips get none, only
their frame count. Mouth crops and transcripts only: no face video. Runs on this Mac.
Usage: personal_pack.py <out prefix> <session dir>...
"""
import json, subprocess, sys, tempfile, wave
from pathlib import Path
import numpy as np, torch
MARGIN, RATE = .12, 16000


def take_audio(session):
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp)/'a.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(session/'take.mov'), '-map', '0:a:0', '-ac', '1', '-ar', str(RATE), '-c:a', 'pcm_s16le', str(p)], check=True)
        with wave.open(str(p)) as w: return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768


def marks(session):
    name = 'marks-reviewed.jsonl' if (session/'marks-reviewed.jsonl').exists() else 'marks.jsonl'
    out = []
    for m in map(json.loads, open(session/name)):
        if m.get('kind') == 'void_last' and out: out.pop()
        elif m.get('kind', 'segment') == 'segment': out.append(m)
    return {(m.get('line'), m.get('mode', 'voiced')): m for m in out}


def main():
    out, sessions = sys.argv[1], [Path(s) for s in sys.argv[2:]]
    from qwen_asr import Qwen3ASRModel
    from qwen_asr.core.transformers_backend.modeling_qwen3_asr import _get_feat_extract_output_lengths
    snap = next((Path.home()/'.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots').iterdir())
    asr = Qwen3ASRModel.from_pretrained(str(snap), dtype=torch.float16, device_map='mps')
    thinker = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    prompt = asr._build_text_prompt(context='', force_language='Chinese')
    index, fo, xo = [], 0, 0
    with open(out+'.frames.bin', 'wb') as F, open(out+'.feats.bin', 'wb') as X:
        for s in sessions:
            audio, mk = take_audio(s), marks(s)
            for c in json.loads((s/'clips.json').read_text()):
                v = np.load(Path(c['folder'])/'rois.npy'); m = mk.get((c['line'], c['mode']))
                row = dict(id=c['id'], text=c['text'], mode=c['mode'], line=c['line'], session=s.name, frames=len(v), foff=fo)
                if c['mode'] == 'voiced' and m:
                    a = audio[max(int((m['start']-MARGIN)*RATE), 0):int((m['end']+MARGIN)*RATE)]
                    inp = asr.processor(text=[prompt], audio=[a], return_tensors='pt').to('mps')
                    with torch.inference_mode():
                        f = thinker.get_audio_features(inp['input_features'].to(torch.float16), feature_attention_mask=inp['feature_attention_mask'])
                    X.write(f.float().cpu().numpy().astype(np.float16).tobytes())
                    row.update(feats=len(f), xoff=xo, samples=len(a), audio=True); xo += f.numel()
                else:
                    samples = int(len(v)/25*RATE)
                    row.update(feats=int(_get_feat_extract_output_lengths(torch.tensor([samples//160]))[0]), xoff=-1, samples=samples, audio=False)
                F.write(v.tobytes()); fo += v.size; index.append(row)
    json.dump(dict(dim=1024, clips=index), open(out+'.json', 'w'), ensure_ascii=False)
    print('clips', len(index), 'voiced with audio', sum(r['audio'] for r in index), 'silent', sum(r['mode'] == 'silent' for r in index))


if __name__ == '__main__': main()
