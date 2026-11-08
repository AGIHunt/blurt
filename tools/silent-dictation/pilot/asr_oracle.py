#!/usr/bin/env python3
"""How good must a video model's output be for a frozen Qwen3-ASR decoder to read it?

Decodes real voiced takes through Qwen3-ASR, replacing the audio encoder's output with degraded copies:
per-frame noise at a target cosine similarity, and temporal blur. Scores against the known script.
A visual encoder trained to predict these features would feed the same decoder, whose system prompt
takes app and text context natively. Everything runs on this Mac.

Usage: asr_oracle.py <session dir>... --output out.json [--model <snapshot dir>]
"""
import argparse, json, re, subprocess, sys, tempfile, time, wave
from pathlib import Path
import numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, str(Path(__file__).parent))
from language_metrics import score
from qwen_asr import Qwen3ASRModel

MARGIN = .12


def voiced_wavs(session, rate=16000):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)/'a.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(session/'take.mov'), '-map', '0:a:0', '-ac', '1', '-ar', str(rate), '-c:a', 'pcm_s16le', str(path)], check=True)
        with wave.open(str(path)) as w: audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)/32768
    marks = {(m.get('line'), m.get('mode')): m for m in map(json.loads, open(session/'marks.jsonl')) if m.get('kind') == 'segment'}
    for c in json.loads((session/'clips.json').read_text()):
        m = marks.get((c['line'], c['mode']))
        if c['mode'] == 'voiced' and m: yield dict(id=c['id'], text=c['text'], audio=audio[max(int((m['start']-MARGIN)*rate), 0):int((m['end']+MARGIN)*rate)])


def degrade(f, kind, value):
    if kind == 'clean': return f
    if kind == 'blur':
        n = int(value); k = torch.ones(1, 1, n, device=f.device, dtype=f.dtype)/n
        return F.conv1d(f.T[:, None], k, padding='same')[:, 0].T
    noise = torch.randn_like(f)
    unit = F.normalize(f, dim=-1); noise = F.normalize(noise-(noise*unit).sum(-1, keepdim=True)*unit, dim=-1)
    return f.norm(dim=-1, keepdim=True)*(value*unit+(1-value**2)**.5*noise)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('sessions', type=Path, nargs='+')
    p.add_argument('--model', default=str(next((Path.home()/'.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots').iterdir())))
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.output.exists(): raise SystemExit('Choose a new output path')
    torch.manual_seed(7)
    asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.float16, device_map='mps', max_new_tokens=128)
    owner = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    original = owner.get_audio_features; state = dict(kind='clean', value=0, frames=[])
    def patched(*args, **kw):
        out = original(*args, **kw); state['frames'].append(out.shape[0])
        return degrade(out.float(), state['kind'], state['value']).to(out.dtype)
    owner.get_audio_features = patched
    clips = [c for s in a.sessions for c in voiced_wavs(s)]
    print('clips', len(clips), 'audio seconds', round(sum(len(c['audio']) for c in clips)/16000), flush=True)
    conditions = [('clean', 0)]+[('cos', v) for v in (.95, .9, .8, .7, .6, .5, .4)]+[('blur', v) for v in (3, 5, 9)]
    results = {}; rows = []
    for kind, value in conditions:
        state.update(kind=kind, value=value); errors = units = 0; t0 = time.time()
        for c in clips:
            text = asr.transcribe(audio=(c['audio'], 16000), language='Chinese')[0].text
            q = score(c['text'], text, 'zh_en_mixed' if re.search('[A-Za-z]', c['text']) else 'zh')
            errors += q['errors']; units += q['reference_units']
            rows.append(dict(id=c['id'], kind=kind, value=value, hypothesis=text, reference=c['text'], accuracy=q))
        results[f'{kind}:{value}'] = dict(cer=round(errors/units, 4), seconds=round(time.time()-t0, 1))
        print(kind, value, results[f'{kind}:{value}'], flush=True)
        a.output.write_text(json.dumps(dict(results=results, frames_per_second=sum(state['frames'])/max(sum(len(c['audio']) for c in clips)/16000*len(results), 1), clips=rows), ensure_ascii=False, indent=1))


if __name__ == '__main__': main()
