"""Model pieces shared by v2a_train.py (4090) and pilot/eval_v2a.py (Mac)."""
import torch, torch.nn as nn, torch.nn.functional as F


def pad_mask(lengths):
    return torch.arange(int(lengths.max()), device=lengths.device)[None] >= lengths[:, None]


class LoRA(nn.Module):
    def __init__(self, base, r):
        super().__init__(); self.base = base; self.a = nn.Linear(base.in_features, r, bias=False); self.b = nn.Linear(r, base.out_features, bias=False)
        nn.init.kaiming_uniform_(self.a.weight, a=5**.5); nn.init.zeros_(self.b.weight); self.scale = 2.
        self.a.to(base.weight.device); self.b.to(base.weight.device)
    def forward(self, x): return self.base(x)+self.b(self.a(x.to(self.a.weight.dtype))).to(x.dtype)*self.scale


def add_lora(decoder, r):
    names = ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj')
    for m in list(decoder.modules()):
        for n in names:
            if isinstance(getattr(m, n, None), nn.Linear): setattr(m, n, LoRA(getattr(m, n), r))
    return [p for m in decoder.modules() if isinstance(m, LoRA) for p in (*m.a.parameters(), *m.b.parameters())]


class Bridge(nn.Module):
    """Encoder frames (25 fps, 768-d) to Qwen3-ASR audio-feature frames (about 13 fps, 1024-d)."""
    def __init__(self, din=768, d=1024, layers=2):
        super().__init__()
        self.inp = nn.Sequential(nn.Linear(din, d), nn.GELU(), nn.Linear(d, d))
        self.body = nn.TransformerEncoder(nn.TransformerEncoderLayer(d, 16, 4*d, .1, batch_first=True, norm_first=True), layers)
        self.out = nn.Sequential(nn.LayerNorm(d), nn.Linear(d, d))
    def forward(self, enc, n, targets):
        h = self.inp(enc); seq = []
        for k, t in enumerate(targets):
            seq.append(F.interpolate(h[k, :n[k]].T[None], size=t, mode='linear', align_corners=False)[0].T)
        pad = pad_mask(torch.tensor(targets, device=enc.device))
        h = nn.utils.rnn.pad_sequence(seq, batch_first=True)
        return self.out(self.body(h, src_key_padding_mask=pad)), pad
