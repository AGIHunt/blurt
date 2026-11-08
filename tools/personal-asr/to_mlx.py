#!/usr/bin/env python3
"""Step 7: turn a merged Hugging Face-format Qwen3-ASR folder (merge_lora.py) into the app's MLX format, the same
layout as mlx-community/Qwen3-ASR-1.7B-8bit: text decoder 8-bit (group 64), audio encoder float16, tied LM head
left out, config and tokenizer files from the stock MLX folder.

Usage (on the Mac): uv run --with mlx-qwen3-asr==0.4.4 python to_mlx.py <merged dir> <stock mlx dir> <out dir>
"""
import json, shutil, sys
from pathlib import Path
import mlx.core as mx
from mlx.utils import tree_flatten
from mlx_qwen3_asr.convert import quantize_model
from mlx_qwen3_asr.load_models import _load_model_with_resolved_path


def main():
    merged, stock, out = (Path(p) for p in sys.argv[1:4])
    model, config, _ = _load_model_with_resolved_path(str(merged), mx.float16)
    quantize_model(model, bits=8, group_size=64, encoder_bits=16)
    weights = dict(tree_flatten(model.parameters()))
    ref = mx.load(str(stock/'model.safetensors'))
    weights = {k: v for k, v in weights.items() if k in ref}           # same tensors as the stock build (tied head out)
    missing = sorted(set(ref)-set(weights)); bad = [k for k in weights if weights[k].shape != ref[k].shape or weights[k].dtype != ref[k].dtype]
    assert not missing and not bad, (missing[:5], bad[:5])
    out.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(out/'model.safetensors'), weights, metadata={'format': 'mlx'})
    for f in stock.iterdir():
        if f.is_file() and f.name not in ('model.safetensors', '.blurt-manifest.json'): shutil.copy(f, out/f.name)
    (out/'.blurt-manifest.json').write_text(json.dumps([{'path': f.name, 'size': f.stat().st_size} for f in sorted(out.iterdir())
                                                        if f.is_file() and f.name != '.blurt-manifest.json']))
    print('wrote', out, len(weights), 'tensors', round((out/'model.safetensors').stat().st_size/1e9, 2), 'GB')


if __name__ == '__main__': main()
