#!/usr/bin/env python3
"""Save a train_lora.py LoRA (a bare list of tensors) as named safetensors: "<MLX module path>.lora_a/.lora_b"
(text decoder "model.layers.N…", audio encoder "audio_tower.layers.N…"), float16. Small (about 50 MB for rank 16),
portable, and what to_mlx_lora.py applies on the Mac. Needs the base model only for the layer names and order.

Usage: lora_export.py --model <base dir> --lora <lora.pt> --out <file.safetensors> [--audio-lora]
"""
import argparse, json
import torch, torch.nn as nn
from safetensors.torch import save_file
ap = argparse.ArgumentParser()
ap.add_argument('--model', required=True); ap.add_argument('--lora', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--audio-lora', action='store_true'); ap.add_argument('--rank', type=int, default=16)
a = ap.parse_args()
TEXT = ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj')
AUDIO = ('q_proj', 'k_proj', 'v_proj', 'out_proj', 'fc1', 'fc2')

from qwen_asr import Qwen3ASRModel
asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.bfloat16, device_map='cpu')
th = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
names = [('model.'+n, m) for n, m in th.model.named_modules() if isinstance(m, nn.Linear) and n.rsplit('.', 1)[-1] in TEXT]
if a.audio_lora: names += [('audio_tower.'+n, m) for n, m in th.audio_tower.named_modules() if isinstance(m, nn.Linear) and n.rsplit('.', 1)[-1] in AUDIO]
w = torch.load(a.lora, map_location='cpu'); assert len(w) == 2*len(names), (len(w), len(names))
out = {}
for k, (n, m) in enumerate(names):
    A, B = w[2*k], w[2*k+1]
    assert A.shape == (a.rank, m.in_features) and B.shape == (m.out_features, a.rank), (n, A.shape, B.shape)
    out[n+'.lora_a'] = A.to(torch.float16).contiguous(); out[n+'.lora_b'] = B.to(torch.float16).contiguous()
save_file(out, a.out, metadata={'scale': '2.0', 'rank': str(a.rank), 'base': 'Qwen/Qwen3-ASR-1.7B'})
print('saved', len(names), 'layers to', a.out)
