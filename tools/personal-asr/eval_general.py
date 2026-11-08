#!/usr/bin/env python3
"""Overfitting check: does a personal LoRA hurt other people's speech?

Transcribes clips from another corpus (a CSV with ID and TEXT columns and <ID>.wav files at 16 kHz mono) with the
stock model and with the LoRA, no context, and prints both CERs. Usage:
eval_general.py --model <dir> --lora <lora.pt> --wavs <dir> --meta <csv> [--clips 300] [--audio-lora]
"""
import argparse, csv, random, re, sys, wave
from pathlib import Path
import numpy as np, torch, torch.nn as nn
ap = argparse.ArgumentParser()
ap.add_argument('--model', required=True); ap.add_argument('--lora', required=True); ap.add_argument('--wavs', required=True); ap.add_argument('--meta', required=True)
ap.add_argument('--clips', type=int, default=300); ap.add_argument('--rank', type=int, default=16); ap.add_argument('--audio-lora', action='store_true')
ap.add_argument('--show', action='store_true')
a = ap.parse_args()
sys.path.insert(0, str(Path(__file__).parent)); sys.path.insert(0, str(Path(__file__).parents[1]/'silent-dictation/pilot'))
from language_metrics import score


class LoRA(nn.Module):
    def __init__(self, base, r):
        super().__init__(); self.base = base; self.scale = 2.; self.on = True
        self.a = nn.Linear(base.in_features, r, bias=False).to(base.weight.device); self.b = nn.Linear(r, base.out_features, bias=False).to(base.weight.device)
    def forward(self, x):
        y = self.base(x)
        return y+self.b(self.a(x.to(self.a.weight.dtype))).to(x.dtype)*self.scale if self.on else y


def add(root, names):
    for m in list(root.modules()):
        for n in names:
            if isinstance(getattr(m, n, None), nn.Linear): setattr(m, n, LoRA(getattr(m, n), a.rank))


def main():
    from qwen_asr import Qwen3ASRModel
    asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.bfloat16, device_map='cuda', max_new_tokens=256)
    th = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    add(th.model, ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'))
    if a.audio_lora: add(th.audio_tower, ('q_proj', 'k_proj', 'v_proj', 'out_proj', 'fc1', 'fc2'))
    # Same order as train_lora.py saved them: text decoder first, then the audio encoder.
    mods = [m for m in th.model.modules() if isinstance(m, LoRA)]+([m for m in th.audio_tower.modules() if isinstance(m, LoRA)] if a.audio_lora else [])
    for p, w in zip([p for m in mods for p in (*m.a.parameters(), *m.b.parameters())], torch.load(a.lora, map_location='cpu')): p.data.copy_(w.to(p.device))
    rows = [r for r in csv.DictReader(open(a.meta, encoding='utf8')) if (Path(a.wavs)/f"{r['ID']}.wav").exists()]
    rows = random.Random(1).sample(rows, min(a.clips, len(rows)))
    def load(r):
        with wave.open(str(Path(a.wavs)/f"{r['ID']}.wav")) as w: return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768
    hyps = {}
    for on in (False, True):
        for m in mods: m.on = on
        e = u = 0; hyps[on] = []
        for k in range(0, len(rows), 16):
            xs = rows[k:k+16]
            with torch.no_grad(): outs = asr.transcribe(audio=[(load(r), 16000) for r in xs])
            for r, o in zip(xs, outs):
                q = score(r['TEXT'], o.text, 'zh_en_mixed' if re.search('[A-Za-z]', r['TEXT']) else 'zh'); e += q['errors']; u += q['reference_units']; hyps[on].append(o.text)
        print('LoRA' if on else 'stock', 'CER', round(e/u, 4), 'clips', len(rows), flush=True)
    import json
    Path('general-hyps.json').write_text(json.dumps([dict(ref=r['TEXT'], stock=x, lora=y) for r, x, y in zip(rows, hyps[False], hyps[True])], ensure_ascii=False))
    if '--show' in sys.argv:
        for r, x, y in zip(rows, hyps[False], hyps[True]):
            if x != y: print('REF', r['TEXT'], '\n  stock', x, '\n  LoRA ', y)


if __name__ == '__main__': main()
