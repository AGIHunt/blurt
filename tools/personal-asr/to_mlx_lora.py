#!/usr/bin/env python3
"""Step 7 (Mac): build the app's model with the LoRA folded in, from the stock MLX build the app already has:
each LoRA'd 8-bit decoder weight is dequantized, gets scale·B·A added, and is requantized with the same bits and
group size; the float16 audio-encoder weights get the delta added directly. Same tensors, names and files as the
stock folder, so the app loads it as before and inference costs the same. Only the small LoRA file has to travel.

Usage: uv run --with mlx-qwen3-asr==0.4.4 python to_mlx_lora.py <lora.safetensors> <stock mlx dir> <out dir>
"""
import json, shutil, sys
from pathlib import Path
import mlx.core as mx


def main():
    lora_path, stock, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    lora, meta = mx.load(str(lora_path), return_metadata=True); scale = float(meta.get('scale', 2.0))
    cfg = json.load(open(stock/'config.json'))['quantization']; bits, group = int(cfg['bits']), int(cfg['group_size'])
    w = mx.load(str(stock/'model.safetensors')); done = 0
    for name in sorted({k.rsplit('.', 1)[0] for k in lora}):
        delta = scale*(lora[name+'.lora_b'].astype(mx.float32)@lora[name+'.lora_a'].astype(mx.float32))
        if name+'.scales' in w:
            W = mx.dequantize(w[name+'.weight'], w[name+'.scales'], w[name+'.biases'], group_size=group, bits=bits).astype(mx.float32)
            q, s, b = mx.quantize((W+delta).astype(mx.float16), group_size=group, bits=bits)
            assert q.shape == w[name+'.weight'].shape and s.shape == w[name+'.scales'].shape, name
            w[name+'.weight'], w[name+'.scales'], w[name+'.biases'] = q, s.astype(w[name+'.scales'].dtype), b.astype(w[name+'.biases'].dtype)
        else:
            W = w[name+'.weight']; assert W.shape == delta.shape, (name, W.shape, delta.shape)
            w[name+'.weight'] = (W.astype(mx.float32)+delta).astype(W.dtype)
        done += 1
    out.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(out/'model.safetensors'), w, metadata={'format': 'mlx'})
    for f in stock.iterdir():
        if f.is_file() and f.name not in ('model.safetensors', '.blurt-manifest.json'): shutil.copy(f, out/f.name)
    (out/'.blurt-manifest.json').write_text(json.dumps([{'path': f.name, 'size': f.stat().st_size} for f in sorted(out.iterdir())
                                                        if f.is_file() and f.name != '.blurt-manifest.json']))
    print('folded', done, 'layers into', out, round((out/'model.safetensors').stat().st_size/1e9, 2), 'GB')


if __name__ == '__main__': main()
