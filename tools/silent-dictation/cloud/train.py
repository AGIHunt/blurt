#!/usr/bin/env python3
"""Fine-tune the ViSpeR conformer on packed Mandarin mouth clips, with a Pinyin CTC head.

Research only. Bucketed by length, frame-budget batches, bf16 autocast, resumable.
"""
import argparse, json, math, random, re, sys, time
from pathlib import Path
from types import SimpleNamespace
import numpy as np, torch, torch.nn.functional as F, yaml

ap = argparse.ArgumentParser()
ap.add_argument('--visper', default='/data/visper')
ap.add_argument('--weights', default='/data/weights/visper_vsr_base.pth')
ap.add_argument('--train', nargs='+', default=['/data/pack/train'])
ap.add_argument('--val', default='/data/pack/val')
ap.add_argument('--out', default='/data/runs/lips-v1')
ap.add_argument('--epochs', type=int, default=12)
ap.add_argument('--lr', type=float, default=2e-4)
ap.add_argument('--frames', type=int, default=2200)
ap.add_argument('--accum', type=int, default=1)
ap.add_argument('--pin-weight', type=float, default=.3)
ap.add_argument('--freeze-decoder', action='store_true', help='Keep the upstream language prior; train only the visual encoder')
ap.add_argument('--pin-init', help='Checkpoint supplying a trained Pinyin head')
ap.add_argument('--workers', type=int, default=10)
ap.add_argument('--val-clips', type=int, default=120)
ap.add_argument('--max-steps', type=int, default=0)
ap.add_argument('--seed', type=int, default=7)
a = ap.parse_args()
sys.path.insert(0, a.visper)
from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
from espnet.nets.pytorch_backend.nets_utils import make_non_pad_mask
from espnet.nets.pytorch_backend.transformer.add_sos_eos import add_sos_eos
from espnet.nets.pytorch_backend.transformer.mask import target_mask
from espnet.nets.batch_beam_search import BatchBeamSearch
from espnet.nets.scorers.ctc import CTCPrefixScorer
from espnet.nets.scorers.length_bonus import LengthBonus
import cv2

MEAN, STD = .421, .165


class Pack:
    def __init__(self, prefix):
        self.bin = prefix + '.bin'; self.index = json.load(open(prefix + '.json')); self.mm = None
    def frames(self, i):
        if self.mm is None: self.mm = np.memmap(self.bin, dtype=np.uint8, mode='r')
        r = self.index[i]
        return np.array(self.mm[r['offset']:r['offset']+r['frames']*96*96]).reshape(-1, 96, 96)


def augment(x):
    """Appearance and geometry jitter covering a laptop webcam: scale, shift, light, blur."""
    T = len(x)
    s = random.uniform(.85, 1.2)
    if s != 1:
        M = np.array([[s, 0, 48*(1-s)+random.uniform(-3, 3)], [0, s, 48*(1-s)+random.uniform(-3, 3)]], dtype=np.float32)
        x = np.stack([cv2.warpAffine(f, M, (96, 96), borderMode=cv2.BORDER_REPLICATE) for f in x])
    if random.random() < .35:
        k = random.choice([3, 5]); x = np.stack([cv2.GaussianBlur(f, (k, k), 0) for f in x])
    if random.random() < .5: x = x[:, :, ::-1]
    i, j = random.randint(0, 8), random.randint(0, 8)
    x = torch.from_numpy(x[:, i:i+88, j:j+88].copy()).float()/255
    x = (x*random.uniform(.7, 1.3)+random.uniform(-.12, .12)).clamp(0, 1)
    x = (x-MEAN)/STD
    n = max(int(T/25), 1)            # adaptive time masking, as upstream
    for _ in range(n):
        w = random.randint(0, min(10, T-1)); s0 = random.randint(0, T-w)
        if w: x[s0:s0+w] = x.mean()
    return x


class Clips(torch.utils.data.Dataset):
    def __init__(self, packs): self.packs = packs
    def __getitem__(self, key):
        p, i = key
        r = self.packs[p].index[i]
        return augment(self.packs[p].frames(i)), r['ids'], r['py']


class Sampler(torch.utils.data.Sampler):
    def __init__(self, packs, budget, seed):
        self.items = [(p, i, r['frames']) for p, pack in enumerate(packs) for i, r in enumerate(pack.index)]
        self.budget, self.seed, self.epoch = budget, seed, 0
        self.batches = self.make()
    def make(self):
        rng = random.Random(self.seed+self.epoch)
        items = self.items[:]; rng.shuffle(items)
        chunks = [sorted(items[k:k+2000], key=lambda t: t[2]) for k in range(0, len(items), 2000)]
        out = []
        for c in chunks:
            b = []; longest = 0
            for t in c:
                longest = max(longest, t[2])
                if b and longest*(len(b)+1) > self.budget:
                    out.append(b); b = []; longest = t[2]
                b.append(t[:2])
            if b: out.append(b)
        rng.shuffle(out); return out
    def __iter__(self): return iter(self.batches)
    def __len__(self): return len(self.batches)


def collate(batch):
    n = [len(x) for x, _, _ in batch]; T = max(n)
    v = torch.zeros(len(batch), T, 1, 88, 88)
    for k, (x, _, _) in enumerate(batch): v[k, :len(x), 0] = x
    y = torch.nn.utils.rnn.pad_sequence([torch.tensor(t) for _, t, _ in batch], batch_first=True, padding_value=-1)
    py = torch.cat([torch.tensor(t) for _, _, t in batch]); pl = torch.tensor([len(t) for _, _, t in batch])
    return v, torch.tensor(n), y, py, pl


def lev(s, t):
    p = list(range(len(t)+1))
    for i, x in enumerate(s, 1):
        c = [i]
        for j, y in enumerate(t, 1): c.append(min(p[j]+1, c[-1]+1, p[j-1]+(x != y)))
        p = c
    return p[-1]


def main():
    random.seed(a.seed); np.random.seed(a.seed); torch.manual_seed(a.seed)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    cfg = yaml.safe_load(open(f'{a.visper}/conf/model/visual_backbone/resnet_conformer.yaml'))
    cfg.update(ddim=cfg['adim'], dheads=cfg['aheads'])
    tokens = ['<blank>']+[l.split()[0] for l in open(f'{a.visper}/spm/unigram/unigram_units.txt', encoding='utf8').read().splitlines()]+['<eos>']
    model = E2E(len(tokens), SimpleNamespace(**cfg))
    st = torch.load(a.weights, map_location='cpu', weights_only=True)
    if 'state_dict' in st: st = {k.removeprefix('model.'): v for k, v in st['state_dict'].items() if 'beam_search' not in k}
    pin_vocab = json.load(open('/data/pack/pinyin_vocab.json'))
    pin_head = torch.nn.Linear(cfg['adim'], len(pin_vocab)+1)
    pin_state = {k[9:]: v for k, v in st.items() if k.startswith('pin_head.')}
    model.load_state_dict({k: v for k, v in st.items() if not k.startswith('pin_head.')}, strict=True)
    if pin_state: pin_head.load_state_dict(pin_state)
    if a.pin_init:
        p0 = torch.load(a.pin_init, map_location='cpu', weights_only=True)
        pin_head.load_state_dict({k[9:]: v for k, v in p0.items() if k.startswith('pin_head.')})
    model.cuda(); pin_head.cuda()
    if a.freeze_decoder:
        for p in list(model.decoder.parameters()): p.requires_grad_(False)
    params = [p for p in list(model.parameters())+list(pin_head.parameters()) if p.requires_grad]
    opt = torch.optim.AdamW(params, lr=a.lr, weight_decay=.05, betas=(.9, .98))
    packs = [Pack(p) for p in a.train]
    val = Pack(a.val); val_rng = random.Random(1); val_ids = val_rng.sample(range(len(val.index)), min(a.val_clips, len(val.index)))
    sampler = Sampler(packs, a.frames, a.seed)
    steps_per_epoch = len(sampler); total = steps_per_epoch*a.epochs//a.accum; warm = min(1000, total//10)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min((s+1)/warm, .5*(1+math.cos(math.pi*min(s, total)/total))))
    step = 0; start_epoch = 0
    resume = out/'last.pt'
    if resume.exists():
        c = torch.load(resume, map_location='cpu', weights_only=False)
        model.load_state_dict(c['model']); pin_head.load_state_dict(c['pin']); opt.load_state_dict(c['opt']); sched.load_state_dict(c['sched'])
        step, start_epoch = c['step'], c['epoch']+1; print('resumed', start_epoch, step, flush=True)
    scaler_free = torch.amp.autocast('cuda', dtype=torch.bfloat16)

    def evaluate(epoch):
        model.eval()
        beam = BatchBeamSearch(beam_size=5, vocab_size=len(tokens), weights={'decoder': .9, 'ctc': .1, 'length_bonus': 0., 'lm': 0.},
            scorers={'decoder': model.decoder, 'ctc': CTCPrefixScorer(model.ctc, model.eos), 'length_bonus': LengthBonus(len(tokens)), 'lm': None},
            sos=model.sos, eos=model.eos, token_list=tokens, pre_beam_score_key='decoder').eval().cuda()
        E = N = PE = PN = 0; rev = {v: k for k, v in pin_vocab.items()}
        with torch.inference_mode():
            for i in val_ids:
                r = val.index[i]; f = val.frames(i)[:, 4:92, 4:92]
                x = ((torch.from_numpy(f.copy()).float()/255-MEAN)/STD)[None, :, None].cuda()
                with torch.amp.autocast('cuda', dtype=torch.bfloat16):
                    enc, _ = model.encoder(x, None)
                enc = enc.float()
                h = beam(enc.squeeze(0), lang=tokens.index('<zh>'))
                hyp = ''.join(tokens[t] for t in h[0].yseq.tolist()[2:] if t not in (model.eos, model.blank)).replace('▁', '')
                ref = re.sub(r'\s', '', r['text']); hyp = re.sub(r'\s', '', hyp)
                E += lev(ref, hyp); N += len(ref)
                seq = pin_head(enc)[0].argmax(-1).tolist(); pyh = [s for s, b in zip(seq, [0]+seq) if s != b and s]
                PE += lev(r['py'], pyh); PN += len(r['py'])
        model.train(); pin_head.train()
        if a.freeze_decoder: model.decoder.eval()
        print(f'VAL epoch {epoch} CER {E/N:.4f} PinyinER {PE/PN:.4f} clips {len(val_ids)}', flush=True)
        return E/N, PE/PN

    if start_epoch == 0 and a.val_clips: evaluate(-1)
    for epoch in range(start_epoch, a.epochs):
        sampler.epoch = epoch; sampler.batches = sampler.make()
        ds = Clips(packs)
        loader = torch.utils.data.DataLoader(ds, batch_sampler=sampler, num_workers=a.workers, collate_fn=collate, pin_memory=True, prefetch_factor=4, persistent_workers=False)
        model.train(); pin_head.train()
        if a.freeze_decoder: model.decoder.eval()
        t0 = time.time(); seen = 0; smooth = None
        for it, (v, n, y, py, pl) in enumerate(loader):
            v, n, y, py, pl = v.cuda(non_blocking=True), n.cuda(), y.cuda(), py.cuda(), pl.cuda()
            with scaler_free:
                enc, _ = model.encoder(v, make_non_pad_mask(n).to(v.device).unsqueeze(-2))
                yin, yout = add_sos_eos(y, model.sos, model.eos, -1)
                pred, _ = model.decoder(yin, target_mask(yin, -1), enc, make_non_pad_mask(n).to(v.device).unsqueeze(-2))
            att = model.criterion(pred[:, 1:].float().contiguous(), yout[:, 1:].contiguous())
            enc = enc.float()
            ylen = (y != -1).sum(1)
            logp = model.ctc.ctc_lo(F.dropout(enc, .1, model.training)).log_softmax(-1).transpose(0, 1)
            ctc = F.ctc_loss(logp, y.masked_fill(y == -1, 0), n, ylen, blank=0, reduction='sum', zero_infinity=True)/len(v)
            plog = pin_head(F.dropout(enc, .1, model.training)).log_softmax(-1).transpose(0, 1)
            pctc = F.ctc_loss(plog, py, n, pl, blank=0, reduction='sum', zero_infinity=True)/len(v)
            loss = .9*att+.1*ctc+a.pin_weight*pctc
            if not torch.isfinite(loss): print('nonfinite skipped', flush=True); opt.zero_grad(set_to_none=True); continue
            (loss/a.accum).backward()
            if (it+1) % a.accum == 0:
                torch.nn.utils.clip_grad_norm_(params, 5.)
                opt.step(); opt.zero_grad(set_to_none=True); sched.step(); step += 1
            seen += int(n.sum()); l = float(loss.detach()); smooth = l if smooth is None else .98*smooth+.02*l
            if it % 100 == 0:
                print(f'e{epoch} {it}/{steps_per_epoch} loss {smooth:.2f} att {float(att):.2f} ctc {float(ctc):.1f} pin {float(pctc):.1f} lr {sched.get_last_lr()[0]:.2e} {seen/(time.time()-t0):.0f} fps mem {torch.cuda.max_memory_allocated()/1e9:.1f}G', flush=True)
            if a.max_steps and it >= a.max_steps: return
        cer, per = evaluate(epoch)
        torch.save(dict(model=model.state_dict(), pin=pin_head.state_dict(), opt=opt.state_dict(), sched=sched.state_dict(), step=step, epoch=epoch), out/'tmp.pt')
        (out/'tmp.pt').rename(out/'last.pt')
        state = dict(model.state_dict()); state.update({f'pin_head.{k}': v for k, v in pin_head.state_dict().items()})
        torch.save(state, out/f'epoch{epoch:02d}-cer{cer:.3f}.pth')
        with open(out/'log.jsonl', 'a') as f: f.write(json.dumps(dict(epoch=epoch, cer=cer, per=per, seconds=time.time()-t0))+'\n')


if __name__ == '__main__': main()
