#!/usr/bin/env python3
"""Train a visual encoder to speak to a frozen Qwen3-ASR decoder.

Student: ViSpeR ResNet+Conformer encoder (from the Chinese-LiPS v2 checkpoint), a bridge resampling its
25 fps output to the audio encoder's frame count, and a small Transformer. Targets: the Qwen3-ASR audio
encoder's features for the same clip (from pack.py). Losses: cosine and MSE to those features, plus
cross-entropy of the transcript through the frozen decoder, so the student learns what the decoder needs.
Evaluation decodes predicted features with the stock Qwen3-ASR generation path.

Research use only (Chinese-LiPS is CC BY-NC-SA).
"""
import argparse, json, math, random, re, sys, time, zlib
from pathlib import Path
from types import SimpleNamespace
import cv2, numpy as np, torch, torch.nn as nn, torch.nn.functional as F, yaml

ap = argparse.ArgumentParser()
ap.add_argument('--root', default=str(Path.home()/'silent-dictation'))
ap.add_argument('--init', default='lips-v2/epoch03-cer0.484.pth')
ap.add_argument('--train', nargs='+', default=['data/pack/train'])
ap.add_argument('--val', default='data/pack/val')
ap.add_argument('--out', required=True)
ap.add_argument('--epochs', type=int, default=6)
ap.add_argument('--lr', type=float, default=3e-4)
ap.add_argument('--encoder-lr', type=float, default=1e-4)
ap.add_argument('--frames', type=int, default=3000, help='Video frames per batch')
ap.add_argument('--feat-weight', type=float, default=1.)
ap.add_argument('--dec-weight', type=float, default=1.)
ap.add_argument('--freeze-encoder', action='store_true')
ap.add_argument('--val-clips', type=int, default=200)
ap.add_argument('--eval-every', type=int, default=0, help='Also evaluate every N steps')
ap.add_argument('--max-steps', type=int, default=0)
ap.add_argument('--workers', type=int, default=10)
ap.add_argument('--baseline', action='store_true', help='Only score teacher features, mean features and v2 on the eval clips')
ap.add_argument('--seed', type=int, default=7)
ap.add_argument('--lora', type=int, default=0, help='LoRA rank on the decoder attention and MLP projections (0: decoder frozen)')
ap.add_argument('--lora-lr', type=float, default=2e-4)
ap.add_argument('--student', help='Start encoder and bridge from a v2a checkpoint')
ap.add_argument('--personal', help='Fine-tune on this personal pack (pilot/personal_pack.py) with leave-sentence-out folds')
ap.add_argument('--fold', type=int, default=0); ap.add_argument('--folds', type=int, default=5)
ap.add_argument('--no-save', action='store_true')
a = ap.parse_args()
ROOT = Path(a.root); sys.path.insert(0, str(ROOT/'visper')); sys.path.insert(0, str(ROOT/'code'))
from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
from espnet.nets.pytorch_backend.nets_utils import make_non_pad_mask
from language_metrics import score
from v2a_model import Bridge, add_lora
MEAN, STD = .421, .165


class Pack:
    def __init__(self, prefix, keep=None):
        prefix = str(ROOT/prefix); j = json.load(open(prefix+'.json')); self.clips, self.dim = j['clips'], j['dim']
        if keep: self.clips = [c for c in self.clips if keep(c)]
        self.fpath, self.xpath = prefix+'.frames.bin', prefix+'.feats.bin'; self.fm = self.xm = None
    def frames(self, i):
        if self.fm is None: self.fm = np.memmap(self.fpath, np.uint8, 'r')
        c = self.clips[i]; return np.array(self.fm[c['foff']:c['foff']+c['frames']*9216]).reshape(-1, 96, 96)
    def feats(self, i):
        if self.xm is None: self.xm = np.memmap(self.xpath, np.float16, 'r')
        c = self.clips[i]
        if c['xoff'] < 0: return None   # Silent clip: no audio, only its frame count.
        return np.array(self.xm[c['xoff']:c['xoff']+c['feats']*self.dim]).reshape(-1, self.dim)


def augment(x):
    T = len(x); s = random.uniform(.85, 1.2)
    if s != 1:
        M = np.array([[s, 0, 48*(1-s)+random.uniform(-3, 3)], [0, s, 48*(1-s)+random.uniform(-3, 3)]], np.float32)
        x = np.stack([cv2.warpAffine(f, M, (96, 96), borderMode=cv2.BORDER_REPLICATE) for f in x])
    if random.random() < .35:
        k = random.choice([3, 5]); x = np.stack([cv2.GaussianBlur(f, (k, k), 0) for f in x])
    if random.random() < .5: x = x[:, :, ::-1]
    i, j = random.randint(0, 8), random.randint(0, 8)
    x = torch.from_numpy(x[:, i:i+88, j:j+88].copy()).float()/255
    x = ((x*random.uniform(.7, 1.3)+random.uniform(-.12, .12)).clamp(0, 1)-MEAN)/STD
    for _ in range(max(T//25, 1)):
        w = random.randint(0, min(10, T-1)); s0 = random.randint(0, T-w)
        if w: x[s0:s0+w] = x.mean()
    return x


def plain(x): return ((torch.from_numpy(x[:, 4:92, 4:92].copy()).float()/255)-MEAN)/STD


class Clips(torch.utils.data.Dataset):
    def __init__(self, packs, train): self.packs, self.train = packs, train
    def __getitem__(self, key):
        p, i = key; pk = self.packs[p]; c = pk.clips[i]; f = pk.frames(i); x = pk.feats(i)
        return (augment(f) if self.train else plain(f)), None if x is None else torch.from_numpy(x.astype(np.float32)), c['text'], c['samples'], c['feats']


def batches(packs, budget, seed):
    items = [(p, i, c['frames']) for p, pk in enumerate(packs) for i, c in enumerate(pk.clips)]
    rng = random.Random(seed); rng.shuffle(items); out = []
    for k in range(0, len(items), 2000):
        b, longest = [], 0
        for t in sorted(items[k:k+2000], key=lambda t: t[2]):
            longest = max(longest, t[2])
            if b and longest*(len(b)+1) > budget: out.append(b); b, longest = [], t[2]
            b.append(t[:2])
        if b: out.append(b)
    rng.shuffle(out); return out


def collate(batch):
    n = torch.tensor([len(x) for x, *_ in batch]); v = torch.zeros(len(batch), int(n.max()), 1, 88, 88)
    for k, (x, *_) in enumerate(batch): v[k, :len(x), 0] = x
    return v, n, [b[1] for b in batch], [b[2] for b in batch], [b[3] for b in batch], [b[4] for b in batch]


def main():
    random.seed(a.seed); np.random.seed(a.seed); torch.manual_seed(a.seed)
    out = ROOT/a.out; out.mkdir(parents=True, exist_ok=True)
    from qwen_asr import Qwen3ASRModel
    asr = Qwen3ASRModel.from_pretrained(str(ROOT/'qwen3-asr-0.6b'), dtype=torch.bfloat16, device_map='cuda', max_new_tokens=160)
    thinker = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    for p in asr.model.parameters(): p.requires_grad_(False)
    asr.model.eval(); tok = asr.processor.tokenizer; pad_id = thinker.config.audio_token_id
    prompt_ids = tok(asr._build_text_prompt(context='', force_language='Chinese'), add_special_tokens=False)['input_ids']
    cut = prompt_ids.index(pad_id); pre, post = prompt_ids[:cut], prompt_ids[cut+1:]
    end_id = tok.convert_tokens_to_ids('<|im_end|>'); embed = thinker.get_input_embeddings()
    lm_head = thinker.lm_head

    val = Pack(a.val); packs = [] if a.baseline else [Pack(p) for p in a.train]
    stats = np.concatenate([val.feats(i) for i in range(0, len(val.clips), 4)]).astype(np.float32)
    fmean, fstd = torch.tensor(stats.mean(0)).cuda(), torch.tensor(stats.std(0)+1e-3).cuda()
    eval_ids = random.Random(1).sample(range(len(val.clips)), min(a.val_clips, len(val.clips)))
    if a.personal:   # Sentences (and their voiced/silent pairs) stay on one side of the split.
        held = lambda c: zlib.crc32(c['line'].encode()) % a.folds == a.fold
        packs = [Pack(a.personal, lambda c: not held(c))]; val = Pack(a.personal, held); eval_ids = list(range(len(val.clips)))
        print('fold', a.fold, 'train', len(packs[0].clips), 'held out', len(val.clips), flush=True)

    cfg = yaml.safe_load(open(ROOT/'visper/conf/model/visual_backbone/resnet_conformer.yaml')); cfg.update(ddim=cfg['adim'], dheads=cfg['aheads'])
    tokens = ['<blank>']+[l.split()[0] for l in open(ROOT/'visper/spm/unigram/unigram_units.txt', encoding='utf8').read().splitlines()]+['<eos>']
    vsr = E2E(len(tokens), SimpleNamespace(**cfg))
    st = torch.load(ROOT/a.init, map_location='cpu', weights_only=True)
    if 'state_dict' in st: st = {k.removeprefix('model.'): v for k, v in st['state_dict'].items() if 'beam_search' not in k}
    vsr.load_state_dict({k: v for k, v in st.items() if not k.startswith('pin_head.')}, strict=True)
    encoder = vsr.encoder.cuda(); bridge = Bridge(cfg['adim']).cuda()
    if a.student:
        c = torch.load(ROOT/a.student, map_location='cpu', weights_only=False); encoder.load_state_dict(c['encoder']); bridge.load_state_dict(c['bridge'])
        fmean, fstd = c['fmean'].cuda(), c['fstd'].cuda()
    lora = add_lora(thinker.model, a.lora) if a.lora else []
    if a.student and 'lora' in c and lora: [p.data.copy_(q) for p, q in zip(lora, c['lora'])]

    # Decode with the stock generation path; the audio tower's output is swapped for ours.
    swap = dict(feats=None); original = thinker.get_audio_features
    def patched(*args, **kw):
        out = original(*args, **kw)
        if swap['feats'] is None: return out
        # transcribe() may pad a clip by a sample or two, so match each clip's frame count exactly.
        from qwen_asr.core.transformers_backend.modeling_qwen3_asr import _get_feat_extract_output_lengths
        mask = kw.get('feature_attention_mask', args[1] if len(args) > 1 else None)
        want = _get_feat_extract_output_lengths(mask.sum(1)).tolist()
        fit = [f if len(f) == w else F.interpolate(f.T[None].float(), size=w, mode='linear')[0].T for f, w in zip(swap['feats'], want)]
        f = torch.cat(fit).to(out.dtype)
        assert f.shape == out.shape, (f.shape, out.shape)
        return f
    thinker.get_audio_features = patched

    def decode(feats, samples):
        swap['feats'] = feats
        try: return [r.text for r in asr.transcribe(audio=[(np.zeros(s, np.float32), 16000) for s in samples], language='Chinese')]
        finally: swap['feats'] = None

    def cer(refs, hyps):
        e = u = 0
        for r, h in zip(refs, hyps):
            q = score(r, h, 'zh_en_mixed' if re.search('[A-Za-z]', r) else 'zh'); e += q['errors']; u += q['reference_units']
        return e/u

    def predict(v, n, counts):
        mask = make_non_pad_mask(n).to(v.device).unsqueeze(-2)
        with torch.autocast('cuda', dtype=torch.bfloat16):
            enc, _ = encoder(v, mask)
            pred, pad = bridge(enc, n, counts)
        return pred.float(), pad

    def evaluate(tag):
        encoder.eval(); bridge.eval(); ds = Clips([val], False)
        refs, hyps, cos = [], [], []
        with torch.no_grad():
            for k in range(0, len(eval_ids), 16):
                items = [ds[(0, i)] for i in eval_ids[k:k+16]]; v, n, feats, texts, samples, counts = collate(items)
                pred, pad = predict(v.cuda(), n.cuda(), counts)
                outs = [pred[j, :m]*fstd+fmean for j, m in enumerate(counts)]
                cos += [float(F.cosine_similarity(o, f.cuda(), -1).mean()) for o, f in zip(outs, feats) if f is not None]
                hyps += decode(outs, samples); refs += texts
        encoder.train(); bridge.train()
        if a.freeze_encoder: encoder.eval()
        r = dict(tag=tag, cer=round(cer(refs, hyps), 4), cos=round(float(np.mean(cos)), 4) if cos else None, clips=len(refs))
        modes = [val.clips[i].get('mode') for i in eval_ids]
        for m in sorted({x for x in modes if x}):
            sel = [j for j, x in enumerate(modes) if x == m]; r[m] = round(cer([refs[j] for j in sel], [hyps[j] for j in sel]), 4); r[m+'_n'] = len(sel)
        if a.personal: (out/f'hyps-{tag}.json').write_text(json.dumps([dict(id=val.clips[i]['id'], mode=m, ref=x, hyp=h) for i, m, x, h in zip(eval_ids, modes, refs, hyps)], ensure_ascii=False))
        print('VAL', r, '|', hyps[0][:40], '|', refs[0][:40], flush=True)
        with open(out/'log.jsonl', 'a') as f: f.write(json.dumps(r, ensure_ascii=False)+'\n')
        return r

    if a.baseline:
        ds = Clips([val], False); items = [ds[(0, i)] for i in eval_ids]
        refs = [b[2] for b in items]; samples = [b[3] for b in items]
        for name, fn in [('teacher', lambda f: f.cuda()), ('mean frame', lambda f: fmean.expand(len(f), -1).clone())]:
            hyps = []
            for k in range(0, len(items), 16):
                hyps += decode([fn(b[1]) for b in items[k:k+16]], samples[k:k+16])
            print('BASELINE', name, round(cer(refs, hyps), 4), '|', hyps[0][:40], flush=True)
        return

    params = [dict(params=bridge.parameters(), lr=a.lr)]
    if a.freeze_encoder:
        for p in encoder.parameters(): p.requires_grad_(False)
        encoder.eval()
    else: params.append(dict(params=encoder.parameters(), lr=a.encoder_lr))
    if lora:
        for p in lora: p.requires_grad_(True)
        params.append(dict(params=lora, lr=a.lora_lr, weight_decay=0.))
        print('LoRA rank', a.lora, 'parameters', sum(p.numel() for p in lora), flush=True)
    opt = torch.optim.AdamW(params, weight_decay=.05, betas=(.9, .98))
    per_epoch = len(batches(packs, a.frames, a.seed)); total = per_epoch*a.epochs; warm = max(min(1000, total//10), 1)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min((s+1)/warm, .5*(1+math.cos(math.pi*min(s, total)/total))))
    step = 0; evaluate('start')
    for epoch in range(a.epochs):
        loader = torch.utils.data.DataLoader(Clips(packs, True), batch_sampler=batches(packs, a.frames, a.seed+epoch),
                                             num_workers=a.workers, collate_fn=collate, pin_memory=True, prefetch_factor=4)
        t0 = time.time(); seen = 0; sm = {}
        for it, (v, n, feats, texts, samples, counts) in enumerate(loader):
            v, n = v.cuda(non_blocking=True), n.cuda()
            pred, pad = predict(v, n, counts)
            tgt = torch.zeros_like(pred); has = torch.zeros(pred.shape[:2], dtype=torch.bool, device='cuda')
            for k, f in enumerate(feats):
                if f is not None: tgt[k, :len(f)] = f.cuda(); has[k, :len(f)] = True
            keep = ~pad & has
            if keep.any():
                z = (tgt-fmean)/fstd
                l_cos = (1-F.cosine_similarity(pred*fstd+fmean, tgt, -1))[keep].mean(); l_mse = F.mse_loss(pred[keep], z[keep])
            else: l_cos = l_mse = pred.sum()*0
            # Through the frozen decoder: prompt, predicted audio frames, then the transcript.
            seqs, spans = [], []
            for k, (m, t) in enumerate(zip(counts, texts)):
                ids = tok(t, add_special_tokens=False)['input_ids'][:120]+[end_id]
                s = pre+[pad_id]*m+post; spans.append((len(s), len(ids))); seqs.append(s+ids)
            L = max(map(len, seqs)); ids = torch.full((len(seqs), L), end_id, device='cuda'); att = torch.zeros_like(ids)
            for k, s in enumerate(seqs): ids[k, :len(s)] = torch.tensor(s); att[k, :len(s)] = 1
            emb = embed(ids).clone(); audio = (pred*fstd+fmean).to(emb.dtype)
            for k, m in enumerate(counts):
                emb[k, len(pre):len(pre)+m] = audio[k, :m]
            pos, _ = thinker.get_rope_index(att)
            with torch.autocast('cuda', dtype=torch.bfloat16):
                hid = thinker.model(inputs_embeds=emb, attention_mask=att, position_ids=pos)[0]
                rows = torch.cat([hid[k, s-1:s-1+m] for k, (s, m) in enumerate(spans)])
                logits = lm_head(rows).float()
            gold = torch.cat([ids[k, s:s+m] for k, (s, m) in enumerate(spans)])
            l_dec = F.cross_entropy(logits, gold)
            loss = a.feat_weight*(l_cos+l_mse)+a.dec_weight*l_dec
            if not torch.isfinite(loss): opt.zero_grad(set_to_none=True); print('nonfinite skipped', flush=True); continue
            loss.backward()
            torch.nn.utils.clip_grad_norm_(list(bridge.parameters())+list(encoder.parameters())+lora, 5.)
            opt.step(); opt.zero_grad(set_to_none=True); sched.step(); step += 1; seen += int(n.sum())
            for k, x in dict(cos=l_cos, mse=l_mse, dec=l_dec).items(): sm[k] = float(x) if k not in sm else .98*sm[k]+.02*float(x)
            if it % 100 == 0:
                print(f'e{epoch} {it}/{per_epoch} cos {sm["cos"]:.3f} mse {sm["mse"]:.3f} dec {sm["dec"]:.3f} lr {sched.get_last_lr()[0]:.2e} {seen/(time.time()-t0):.0f} fps mem {torch.cuda.max_memory_allocated()/1e9:.1f}G', flush=True)
            if a.eval_every and step % a.eval_every == 0: evaluate(f'step{step}')
            if a.max_steps and step >= a.max_steps: break
        if a.personal and epoch < a.epochs-1 and (epoch+1) % 5: continue
        r = evaluate(f'epoch{epoch}')
        if not a.no_save: torch.save(dict(encoder=encoder.state_dict(), bridge=bridge.state_dict(), lora=[p.detach().cpu() for p in lora], fmean=fmean.cpu(), fstd=fstd.cpu(), args=vars(a), val=r), out/f'epoch{epoch:02d}-cer{r["cer"]:.3f}.pt')
        if a.max_steps and step >= a.max_steps: break


if __name__ == '__main__': main()
