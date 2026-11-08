#!/usr/bin/env python3
"""Decode the participant's clips with a retrained checkpoint, locally. Nothing is uploaded.

Scores OpenCC-normalized CER/MER by mode, on all clips and on clips that passed clip_quality.py.
Saves n-best text and Pinyin CTC output for later rescoring.

Usage: eval_personal.py <dataset> --checkpoint X.pth --pinyin vocab.json --output run.json [--split validation]
"""
import argparse, json, re, sys, time
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace
import numpy as np, torch, yaml, opencc
sys.path.insert(0, str(Path(__file__).parent))
from language_metrics import score

cc = opencc.OpenCC('t2s')


def load(visper, checkpoint, pinyin, device):
    sys.path.insert(0, str(visper))
    from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
    cfg = yaml.safe_load((visper/'conf/model/visual_backbone/resnet_conformer.yaml').read_text())
    cfg.update(ddim=cfg['adim'], dheads=cfg['aheads'])
    tokens = ['<blank>']+[l.split()[0] for l in (visper/'spm/unigram/unigram_units.txt').read_text().splitlines()]+['<eos>']
    model = E2E(len(tokens), SimpleNamespace(**cfg))
    st = torch.load(checkpoint, map_location='cpu', weights_only=True)
    if 'state_dict' in st: st = {k.removeprefix('model.'): v for k, v in st['state_dict'].items() if 'beam_search' not in k}
    head = None; rev = None
    if 'pin_head.weight' in st:
        vocab = json.load(open(pinyin)); rev = {v: k for k, v in vocab.items()}
        head = torch.nn.Linear(cfg['adim'], len(vocab)+1)
        head.load_state_dict({k[9:]: v for k, v in st.items() if k.startswith('pin_head.')}); head.eval().to(device)
    model.load_state_dict({k: v for k, v in st.items() if not k.startswith('pin_head.')}, strict=True)
    return model.eval(), head, rev, tokens


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--visper', type=Path, default=Path.home()/'Library/Application Support/Blurt VSR Pilot/runtime/visper')
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--pinyin', type=Path)
    p.add_argument('--crops', default='prepared-mediapipe')
    p.add_argument('--split', default='validation')
    p.add_argument('--beam', type=int, default=20)
    p.add_argument('--nbest', type=int, default=10)
    p.add_argument('--ctc-weight', type=float, default=.1)
    p.add_argument('--device', default='mps')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    model, head, rev, tokens = load(a.visper, a.checkpoint, a.pinyin, a.device)
    from espnet.nets.batch_beam_search import BatchBeamSearch
    from espnet.nets.scorers.ctc import CTCPrefixScorer
    from espnet.nets.scorers.length_bonus import LengthBonus
    beam = BatchBeamSearch(beam_size=a.beam, vocab_size=len(tokens), weights={'decoder': 1-a.ctc_weight, 'ctc': a.ctc_weight, 'length_bonus': 0., 'lm': 0.},
        scorers={'decoder': model.decoder, 'ctc': CTCPrefixScorer(model.ctc, model.eos), 'length_bonus': LengthBonus(len(tokens)), 'lm': None},
        sos=model.sos, eos=model.eos, token_list=tokens, pre_beam_score_key='decoder').eval()
    model.encoder.to(a.device)
    quality = json.loads((a.root/'runs/clip-quality-v1.json').read_text())['clips']
    rows = []
    for f in sorted((a.root/'clips').glob('v2-*.json')):
        c = json.loads(f.read_text())
        if c['split'] != a.split: continue
        rois = np.load(a.root/a.crops/c['id']/'rois.npy')
        x = ((torch.from_numpy(rois[:, 4:92, 4:92].copy()).float()/255-.421)/.165)[None, :, None].to(a.device)
        profile = c.get('language_profile', c['language'])
        t = time.perf_counter()
        with torch.inference_mode():
            enc, _ = model.encoder(x, None)
            pinyin = None
            if head is not None:
                seq = head(enc)[0].argmax(-1).tolist()
                pinyin = [rev[s] for s, b in zip(seq, [0]+seq) if s != b and s]
            hyps = beam(enc.squeeze(0).cpu(), lang=tokens.index('<en>' if profile == 'en' else '<zh>'))
        texts = []
        for h in hyps[:a.nbest]:
            text = ''.join(tokens[i] for i in h.yseq.tolist()[2:] if i not in (model.eos, model.blank)).replace('▁', ' ').strip()
            texts.append(dict(text=cc.convert(text), score=float(h.score)))
        hyp = texts[0]['text'] if texts else ''
        acc = score(cc.convert(c['reference_text']), hyp, profile)
        rows.append(dict(id=c['id'], mode=c['mode'], family=c['phrase_family'], profile=profile, reference=c['reference_text'],
                         hypothesis=hyp, nbest=texts, pinyin=pinyin, quality=quality[c['id']]['quality'], accuracy=acc, seconds=time.perf_counter()-t))
        print(c['mode'][:6], acc['errors'], '/', acc['reference_units'], '|', hyp, flush=True)
    def table(items):
        g = defaultdict(list)
        for r in items: g[(r['profile'], r['mode'])].append(r)
        return {f'{k[0]}/{k[1]}': dict(clips=len(v), rate=round(sum(x['accuracy']['errors'] for x in v)/sum(x['accuracy']['reference_units'] for x in v), 3),
                                       exact=sum(x['accuracy']['normalized_exact_match'] for x in v)) for k, v in sorted(g.items())}
    result = dict(checkpoint=str(a.checkpoint), split=a.split, crops=a.crops, beam=a.beam, all=table(rows),
                  complete_only=table([r for r in rows if r['quality'] == 'complete']), clips=rows)
    a.output.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    print(json.dumps(dict(all=result['all'], complete_only=result['complete_only']), indent=1))


if __name__ == '__main__': main()
