#!/usr/bin/env python3
"""Step 6: fold a trained LoRA into the Qwen3-ASR weights (CUDA or CPU), so inference costs exactly what the stock
model costs. Writes a Hugging Face-format model folder: the merged weights plus the base folder's other files.

Usage: merge_lora.py --model <base dir> --lora <lora.pt> --out <dir> [--rank 16 --audio-lora]
Then on the Mac: to_mlx.py <out dir> <mlx dir> quantizes it to 8-bit MLX for the app.
"""
import argparse, json, shutil
from pathlib import Path
import torch, torch.nn as nn

ap = argparse.ArgumentParser()
ap.add_argument('--model', required=True); ap.add_argument('--lora', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--rank', type=int, default=16); ap.add_argument('--audio-lora', action='store_true')
a = ap.parse_args()
TEXT = ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj')
AUDIO = ('q_proj', 'k_proj', 'v_proj', 'out_proj', 'fc1', 'fc2')
SCALE = 2.   # train_lora.py's LoRA scale


def targets(root, names):
    """The LoRA'd linears in the order train_lora.py saved them: module registration order (a parent's own
    attribute order, e.g. k_proj before q_proj in the audio encoder), not the order of `names`."""
    return [(None, name, m) for name, m in root.named_modules() if isinstance(m, nn.Linear) and name.rsplit('.', 1)[-1] in names]


def main():
    from qwen_asr import Qwen3ASRModel
    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.bfloat16, device_map=dev)
    th = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    sites = targets(th.model, TEXT)+(targets(th.audio_tower, AUDIO) if a.audio_lora else [])
    w = torch.load(a.lora, map_location='cpu')
    assert len(w) == 2*len(sites), (len(w), len(sites))
    with torch.no_grad():
        for k, (_, _, lin) in enumerate(sites):
            A, B = w[2*k].float(), w[2*k+1].float()
            assert A.shape == (a.rank, lin.in_features) and B.shape == (lin.out_features, a.rank), (A.shape, B.shape, lin)
            lin.weight.copy_((lin.weight.float()+SCALE*(B@A).to(lin.weight.device)).to(lin.weight.dtype))
    # Write the same tensors, names and shards as the base folder (save_pretrained trips over the stock generation
    # config), and copy every other file as is.
    from safetensors.torch import save_file
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True); base = Path(a.model)
    index = json.load(open(base/'model.safetensors.index.json')); state = asr.model.state_dict()
    for shard in sorted(set(index['weight_map'].values())):
        keys = [k for k, f in index['weight_map'].items() if f == shard]
        save_file({k: state[k].detach().to('cpu').contiguous().clone() for k in keys}, str(out/shard), metadata={'format': 'pt'})
    for f in base.iterdir():
        if f.is_file() and not f.name.endswith('.safetensors'): shutil.copy(f, out/f.name)
    print('merged', len(sites), 'layers into', out)


if __name__ == '__main__': main()
