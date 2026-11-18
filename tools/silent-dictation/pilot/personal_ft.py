#!/usr/bin/env python3
"""Personal fine-tuning on the participant's clips, on the Mac. Nothing leaves this machine.

Modes:
  --hold validation        fit on train-session clips, score validation-session clips
  --hold cv                5-fold leave-family-out across all 80 clips (pooled scores)
Truncated clips train on their ASR-recovered tail when one exists and are skipped otherwise;
they stay in scoring with a 'quality' tag, so clean and all-clip numbers stay comparable.

Usage: personal_ft.py <dataset> --checkpoint X.pth --pinyin vocab.json --output run.json
"""
import argparse, json, random, re, sys, time, unicodedata
from collections import defaultdict
from pathlib import Path
import cv2, numpy as np, sentencepiece as spm, torch, torch.nn.functional as F
sys.path.insert(0, str(Path(__file__).parent))
from language_metrics import score
from eval_personal import load, cc
from pypinyin import lazy_pinyin, Style


def targets(text, profile, tokenizer, vocab, pin):
    text = unicodedata.normalize('NFKC', text)
    text = ''.join(c for c in text if c.isalnum() or c.isspace() or c == "'")
    if profile != 'en':
        pieces = tokenizer.encode(re.sub(r'([㐀-鿿])', r' \1 ', text), out_type=str)
        pieces = pieces[:1]+[v for v in pieces[1:] if v != '▁']
    else: pieces = tokenizer.encode(text, out_type=str)
    ids = [vocab['<en>' if profile == 'en' else '<zh>']]+[vocab.get(v, vocab['<unk>']) for v in pieces]
    py = []
    if pin:
        for p in re.findall(r'[㐀-鿿]+|[A-Za-z]+|[0-9]', text):
            py += lazy_pinyin(p, style=Style.NORMAL, errors='ignore') if re.match(r'[㐀-鿿]', p) else [c.lower() for c in p]
        py = [pin[v] for v in py if v in pin]
    return ids, py


def jitter(a):
    s = random.uniform(.92, 1.1)
    M = np.array([[s, 0, 48*(1-s)+random.uniform(-3, 3)], [0, s, 48*(1-s)+random.uniform(-3, 3)]], dtype=np.float32)
    a = np.stack([cv2.warpAffine(f, M, (96, 96), borderMode=cv2.BORDER_REPLICATE) for f in a])
    i, j = random.randint(0, 8), random.randint(0, 8)
    x = torch.from_numpy(a[:, i:i+88, j:j+88].copy()).float()/255
    x = (x*random.uniform(.8, 1.2)+random.uniform(-.08, .08)).clamp(0, 1)
    return ((x-.421)/.165)[None, :, None]


def align(student, teacher):
    """Monotonic DTW on cosine distance: for each student frame, the matching teacher frame."""
    a = F.normalize(student.detach(), dim=-1); b = F.normalize(teacher, dim=-1)
    cost = (1-a @ b.T).cpu().numpy(); n, m = cost.shape
    d = np.full((n, m), np.inf); d[0, 0] = cost[0, 0]
    for i in range(n):
        for j in range(m):
            if i or j:
                d[i, j] = cost[i, j]+min(d[i-1, j] if i else np.inf, d[i, j-1] if j else np.inf, d[i-1, j-1] if i and j else np.inf)
    match = np.zeros(n, dtype=np.int64); i, j = n-1, m-1
    while True:
        match[i] = j
        if i == 0 and j == 0: return torch.from_numpy(match).to(teacher.device)
        steps = [(d[x, y], x, y) for x, y in ((i-1, j-1), (i-1, j), (i, j-1)) if x >= 0 and y >= 0]
        _, i, j = min(steps)


def fit(model, head, clips, a, device):
    prefixes = {'front': ('encoder.frontend.', 'encoder.embed.', 'encoder.encoders.0.'), 'encoder': ('encoder.',), 'all': ('',)}[a.scope]
    for n, p in model.named_parameters(): p.requires_grad_(n.startswith(prefixes))
    params = [p for p in model.parameters() if p.requires_grad]
    if head is not None: params += list(head.parameters())
    opt = torch.optim.AdamW(params, lr=a.lr, weight_decay=1e-4)
    from espnet.nets.pytorch_backend.transformer.add_sos_eos import add_sos_eos
    from espnet.nets.pytorch_backend.transformer.mask import target_mask
    model.to(device).eval()
    steps = a.epochs*len(clips); step = 0
    voiced = {c['family']: c for c in clips if c['mode'] == 'voiced' and c['family'].startswith('rapid:')}
    for epoch in range(a.epochs):
        random.shuffle(clips); total = 0
        for c in clips:
            for g in opt.param_groups: g['lr'] = a.lr*.5*(1+np.cos(np.pi*step/steps))
            enc, _ = model.encoder(jitter(c['rois']).to(device), None)
            y = torch.tensor([c['ids']], device=device)
            yin, yout = add_sos_eos(y, model.sos, model.eos, -1)
            pred, _ = model.decoder(yin, target_mask(yin, -1), enc, None)
            att = model.criterion(pred[:, 1:].contiguous(), yout[:, 1:].contiguous())
            n = torch.tensor([enc.size(1)])
            ctc = F.ctc_loss(model.ctc.ctc_lo(enc).log_softmax(-1).transpose(0, 1).cpu(), y.cpu(), n, torch.tensor([len(c['ids'])]), blank=0, reduction='sum', zero_infinity=True).to(device)
            loss = .9*att+.1*ctc
            partner = voiced.get(c['family']) if a.pair_weight and c['mode'] == 'silent' else None
            if partner is not None:
                with torch.no_grad(): teacher, _ = model.encoder(jitter(partner['rois']).to(device), None)
                student, teacher = enc[0], teacher[0]
                # Mean cosine distance is about 0-2 per frame; scale by frames to sit beside the summed CTC and attention losses.
                loss = loss+a.pair_weight*student.size(0)*(1-F.cosine_similarity(student, teacher[align(student, teacher)], dim=-1)).mean()
            if head is not None and c['py']:
                loss = loss+a.pin_weight*F.ctc_loss(head(enc).log_softmax(-1).transpose(0, 1).cpu(), torch.tensor([c['py']]), n, torch.tensor([len(c['py'])]), blank=0, reduction='sum', zero_infinity=True).to(device)
            opt.zero_grad(set_to_none=True); loss.backward(); torch.nn.utils.clip_grad_norm_(params, 5); opt.step()
            step += 1; total += float(loss.detach())
        print(f'  epoch {epoch+1}/{a.epochs} loss {total/len(clips):.1f}', flush=True)


def make_beam(model, tokens, a):
    from espnet.nets.batch_beam_search import BatchBeamSearch
    from espnet.nets.scorers.ctc import CTCPrefixScorer
    from espnet.nets.scorers.length_bonus import LengthBonus
    return BatchBeamSearch(beam_size=a.beam, vocab_size=len(tokens), weights={'decoder': .9, 'ctc': .1, 'length_bonus': 0., 'lm': 0.},
        scorers={'decoder': model.decoder, 'ctc': CTCPrefixScorer(model.ctc, model.eos), 'length_bonus': LengthBonus(len(tokens)), 'lm': None},
        sos=model.sos, eos=model.eos, token_list=tokens, pre_beam_score_key='decoder').eval()


def decode(model, head, rev, tokens, clips, a, device):
    model.eval(); rows = []
    # BatchBeamSearch scores on CPU; keep the decoder there after training.
    model.decoder.cpu(); model.ctc.cpu()
    beam = make_beam(model, tokens, a)
    for c in clips:
        x = ((torch.from_numpy(c['rois'][:, 4:92, 4:92].copy()).float()/255-.421)/.165)[None, :, None].to(device)
        with torch.inference_mode():
            enc, _ = model.encoder(x, None)
            seq = head(enc)[0].argmax(-1).tolist() if head is not None else []
            hyps = beam(enc.squeeze(0).cpu(), lang=tokens.index('<en>' if c['profile'] == 'en' else '<zh>'))
        texts = [cc.convert(''.join(tokens[i] for i in h.yseq.tolist()[2:] if i not in (model.eos, model.blank)).replace('▁', ' ').strip()) for h in hyps[:10]]
        hyp = texts[0] if texts else ''
        acc = score(cc.convert(c['reference']), hyp, c['profile'])
        rows.append(dict(id=c['id'], mode=c['mode'], family=c['family'], profile=c['profile'], split=c['split'], quality=c['quality'], reference=c['reference'],
                         hypothesis=hyp, nbest=texts, pinyin=[rev[s] for s, b in zip(seq, [0]+seq) if s != b and s] if head is not None else None, accuracy=acc))
    model.decoder.to(device); model.ctc.to(device)
    return rows


def table(rows):
    g = defaultdict(list)
    for r in rows: g[(r['profile'], r['mode'])].append(r)
    return {f'{k[0]}/{k[1]}': dict(clips=len(v), rate=round(sum(x['accuracy']['errors'] for x in v)/sum(x['accuracy']['reference_units'] for x in v), 3),
                                   exact=sum(x['accuracy']['normalized_exact_match'] for x in v)) for k, v in sorted(g.items())}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--visper', type=Path, default=Path.home()/'Library/Application Support/Blurt VSR Pilot/runtime/visper')
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--pinyin', type=Path)
    p.add_argument('--crops', default='prepared-mediapipe')
    p.add_argument('--hold', choices=['validation', 'cv'], default='validation')
    p.add_argument('--scope', choices=['front', 'encoder', 'all'], default='encoder')
    p.add_argument('--epochs', type=int, default=15)
    p.add_argument('--lr', type=float, default=2e-5)
    p.add_argument('--pin-weight', type=float, default=.3)
    p.add_argument('--beam', type=int, default=10)
    p.add_argument('--device', default='mps')
    p.add_argument('--pair-weight', type=float, default=0, help='Pull silent encoder frames toward the DTW-aligned frames of the same sentence said aloud')
    p.add_argument('--fit-modes', nargs='+', help='Fit only on these capture modes')
    p.add_argument('--fit-limit', type=int, help='Fit on a random subset of this many clips per fold')
    p.add_argument('--score-modes', nargs='+', help='Score only these capture modes')
    p.add_argument('--rapid', type=Path, nargs='+', default=[], help='RapidRecorder sessions; each fold holds out a fifth of their sentences')
    p.add_argument('--no-pilot', action='store_true', help='Fit and score only the rapid sessions')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.output.exists(): raise SystemExit('Choose a new output path')
    random.seed(7); np.random.seed(7); torch.manual_seed(7); torch.set_num_threads(6)
    tokenizer = spm.SentencePieceProcessor(model_file=str(a.visper/'spm/unigram/unigram.model'))
    model, head, rev, tokens = load(a.visper, a.checkpoint, a.pinyin, a.device)
    base = {k: v.cpu().clone() for k, v in model.state_dict().items()}
    head_base = {k: v.cpu().clone() for k, v in head.state_dict().items()} if head is not None else None
    vocab = {w: i for i, w in enumerate(tokens)}; pin = {v: k for k, v in rev.items()} if rev else None
    quality = json.loads((a.root/'runs/clip-quality-v1.json').read_text())['clips']
    clips = []
    for f in sorted((a.root/'clips').glob('v2-*.json')):
        c = json.loads(f.read_text()); q = quality[c['id']]; profile = c.get('language_profile', c['language'])
        item = dict(id=c['id'], mode=c['mode'], family=c['phrase_family'], split=c['split'], profile=profile, quality=q['quality'], reference=c['reference_text'],
                    rois=np.load(a.root/a.crops/c['id']/'rois.npy'))
        text = c['reference_text'] if q['quality'] == 'complete' else q.get('recovered_units')
        if text: item['ids'], item['py'] = targets(text, profile, tokenizer, vocab, pin)
        clips.append(item)
    if a.no_pilot: clips = []
    for session in a.rapid:
        for r in json.loads((session/'clips.json').read_text()):
            profile = 'zh_en_mixed' if re.search('[A-Za-z]', r['text']) else 'zh'
            item = dict(id=r['id'], mode=r['mode'], family='rapid:'+(r['line'] or r['id']), split='rapid', profile=profile, quality='complete', reference=r['text'],
                        rois=np.load(Path(r['folder'])/'rois.npy'))
            item['ids'], item['py'] = targets(r['text'], profile, tokenizer, vocab, pin)
            clips.append(item)
    usable = lambda c: 'ids' in c
    families = sorted({c['family'] for c in clips if not c['family'].startswith('rapid:')})
    random.Random(3).shuffle(families)
    rapid = sorted({c['family'] for c in clips if c['family'].startswith('rapid:')})
    random.Random(3).shuffle(rapid)
    if a.hold == 'validation': folds = [({c['id'] for c in clips if c['split'] == 'validation'})]
    else: folds = [{c['id'] for c in clips if c['family'] in families[i::5]+rapid[i::5]} for i in range(5)]
    rows = []; t0 = time.time()
    for n, held in enumerate(folds):
        model.load_state_dict(base)
        if head is not None: head.load_state_dict(head_base)
        train = [c for c in clips if c['id'] not in held and usable(c)]
        test = [c for c in clips if c['id'] in held and (not a.score_modes or c['mode'] in a.score_modes)]
        if a.fit_modes: train = [c for c in train if c['mode'] in a.fit_modes]
        if a.fit_limit: train = random.Random(n).sample(train, min(a.fit_limit, len(train)))
        print(f'fold {n+1}/{len(folds)}: fit {len(train)} score {len(test)}', flush=True)
        fit(model, head, train, a, a.device)
        rows += decode(model, head, rev, tokens, test, a, a.device)
        result = dict(args={k: str(v) for k, v in vars(a).items()}, seconds=time.time()-t0, all=table(rows), complete_only=table([r for r in rows if r['quality'] == 'complete']), clips=rows)
        a.output.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    print(json.dumps(result['complete_only'], indent=1))


if __name__ == '__main__': main()
