#!/usr/bin/env python3
"""Step 5: LoRA fine-tune Qwen3-ASR on one person's labeled pieces (CUDA).

Input per piece, as the app sends it: system prompt = word list, field text and the dictation's text so far (each part
dropped at random during training so the model also works without it); the piece's audio; target
"language Chinese<asr_text>" + the labeled text. LoRA on the text decoder, and with --audio-lora on the audio encoder
too. Scores held-out pieces before and after with the stock generation path, against the labels and against what
the app typed at the time.

Usage: train_lora.py --model <Qwen3-ASR dir> --data <export dir> --out <dir> [--rank 16 --epochs 3 --audio-lora]
"""
import argparse, json, math, random, re, sys, time, wave
from pathlib import Path
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F

ap = argparse.ArgumentParser()
ap.add_argument('--model', required=True); ap.add_argument('--data', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--rank', type=int, default=16); ap.add_argument('--audio-lora', action='store_true')
ap.add_argument('--epochs', type=int, default=3); ap.add_argument('--lr', type=float, default=1e-4)
ap.add_argument('--accum', type=int, default=8); ap.add_argument('--context-drop', type=float, default=.3)
ap.add_argument('--eval-only', action='store_true'); ap.add_argument('--lora-init')
ap.add_argument('--seed', type=int, default=7)
a = ap.parse_args()
sys.path.insert(0, str(Path(__file__).parent)); sys.path.insert(0, str(Path(__file__).parents[1]/"silent-dictation/pilot"))
from language_metrics import score
RATE = 16000


class LoRA(nn.Module):
    def __init__(self, base, r):
        super().__init__(); self.base = base; self.scale = 2.
        self.a = nn.Linear(base.in_features, r, bias=False).to(base.weight.device); self.b = nn.Linear(r, base.out_features, bias=False).to(base.weight.device)
        nn.init.kaiming_uniform_(self.a.weight, a=5**.5); nn.init.zeros_(self.b.weight)
    def forward(self, x): return self.base(x)+self.b(self.a(x.to(self.a.weight.dtype))).to(x.dtype)*self.scale


def add_lora(root, r, names):
    for m in list(root.modules()):
        for n in names:
            if isinstance(getattr(m, n, None), nn.Linear): setattr(m, n, LoRA(getattr(m, n), r))
    return [p for m in root.modules() if isinstance(m, LoRA) for p in (*m.a.parameters(), *m.b.parameters())]


def load(path):
    with wave.open(str(path)) as w: return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768


def context(x, drop):
    parts = [x['words'], x['field'], x['prior'][-300:]]
    return '\n'.join(p for p in parts if p and random.random() >= drop).strip()


def cer(pairs):
    e = u = 0
    for ref, hyp in pairs:
        q = score(ref, hyp, 'zh_en_mixed' if re.search('[A-Za-z]', ref) else 'zh'); e += q['errors']; u += q['reference_units']
    return e/max(u, 1)


def main():
    random.seed(a.seed); torch.manual_seed(a.seed); out = Path(a.out); out.mkdir(parents=True, exist_ok=True); data = Path(a.data)
    from qwen_asr import Qwen3ASRModel
    asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.bfloat16, device_map='cuda', max_new_tokens=256)
    thinker = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    for p in asr.model.parameters(): p.requires_grad_(False)
    lora = add_lora(thinker.model, a.rank, ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'))
    if a.audio_lora: lora += add_lora(thinker.audio_tower, a.rank, ('q_proj', 'k_proj', 'v_proj', 'out_proj', 'fc1', 'fc2'))
    if a.lora_init:
        for p, w in zip(lora, torch.load(a.lora_init, map_location='cpu')): p.data.copy_(w.to(p.device))
    print('LoRA parameters', sum(p.numel() for p in lora), flush=True)
    train = [json.loads(l) for l in open(data/'train.jsonl')]; test = [json.loads(l) for l in open(data/'test.jsonl')]
    proc = asr.processor; tok = proc.tokenizer; end = '<|im_end|>'

    def prompt(ctx):
        msgs = [{'role': 'system', 'content': ctx}, {'role': 'user', 'content': [{'type': 'audio', 'audio': ''}]}]
        return proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)

    # As in the app: each dictation's pieces in order, the text so far being the model's own earlier output.
    takes = {}
    for x in test: takes.setdefault(x['id'].rsplit('-', 1)[0], []).append(x)
    takes = [sorted(v, key=lambda x: x['id']) for v in takes.values()]

    def evaluate(tag):
        asr.model.eval(); pairs, app = [], []; heard = {i: '' for i in range(len(takes))}
        with torch.no_grad():
            for k in range(max(map(len, takes))):
                live = [(i, t[k]) for i, t in enumerate(takes) if k < len(t)]
                for j in range(0, len(live), 16):
                    chunk = live[j:j+16]
                    ctx = [context(dict(x, prior=heard[i]), 0) for i, x in chunk]
                    outs = asr.transcribe(audio=[(load(data/x['wav']), RATE) for _, x in chunk], context=ctx)
                    for (i, x), o in zip(chunk, outs):
                        heard[i] += o.text; pairs.append((x['text'], o.text)); app.append((x['text'], x['app_heard']))
        r = dict(tag=tag, cer=round(cer(pairs), 4), app_at_the_time=round(cer(app), 4), pieces=len(pairs))
        print('TEST', r, flush=True)
        (out/f'test-{tag}.json').write_text(json.dumps(dict(r, pieces=[dict(ref=p[0], hyp=p[1]) for p in pairs]), ensure_ascii=False, indent=0))
        with open(out/'log.jsonl', 'a') as f: f.write(json.dumps(r)+'\n')
        return r

    evaluate('start' if not a.lora_init else 'loaded')
    if a.eval_only: return
    for p in lora: p.requires_grad_(True)
    opt = torch.optim.AdamW(lora, lr=a.lr, weight_decay=0.)
    total = len(train)*a.epochs//a.accum; warm = max(total//20, 1)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min((s+1)/warm, .5*(1+math.cos(math.pi*min(s, total)/total))))
    step = 0
    for epoch in range(a.epochs):
        random.shuffle(train); thinker.train(); t0 = time.time(); sm = None
        for i, x in enumerate(train):
            pr = prompt(context(x, a.context_drop)); target = 'language Chinese<asr_text>'+x['text']+end
            wav = load(data/x['wav'])
            head = proc(text=[pr], audio=[wav], return_tensors='pt'); full = proc(text=[pr+target], audio=[wav], return_tensors='pt')
            n0 = head['input_ids'].shape[1]; full = full.to('cuda')
            with torch.autocast('cuda', dtype=torch.bfloat16):
                o = thinker(input_ids=full['input_ids'], attention_mask=full['attention_mask'], input_features=full['input_features'].to(torch.bfloat16),
                            feature_attention_mask=full['feature_attention_mask'])
            logits = o.logits[0, n0-1:-1].float(); gold = full['input_ids'][0, n0:]
            loss = F.cross_entropy(logits, gold)
            (loss/a.accum).backward(); sm = float(loss) if sm is None else .98*sm+.02*float(loss)
            if (i+1) % a.accum == 0:
                torch.nn.utils.clip_grad_norm_(lora, 1.); opt.step(); opt.zero_grad(set_to_none=True); sched.step(); step += 1
            if i % 200 == 0: print(f'e{epoch} {i}/{len(train)} loss {sm:.3f} lr {sched.get_last_lr()[0]:.2e} {(i+1)/(time.time()-t0):.1f} pieces/s mem {torch.cuda.max_memory_allocated()/1e9:.1f}G', flush=True)
        torch.save([p.detach().cpu() for p in lora], out/f'lora-e{epoch}.pt')
        evaluate(f'epoch{epoch}')


if __name__ == '__main__': main()
