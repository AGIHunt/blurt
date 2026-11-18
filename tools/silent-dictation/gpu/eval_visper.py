#!/usr/bin/env python3
"""Score a ViSpeR checkpoint (beam 5, CTC 0.1, as in cloud/train.py) on the same validation clips v2a_train.py uses."""
import argparse, json, random, re, sys
from pathlib import Path
from types import SimpleNamespace
import numpy as np, torch, yaml

ap = argparse.ArgumentParser()
ap.add_argument('--root', default=str(Path.home()/'silent-dictation'))
ap.add_argument('--weights', default='lips-v2/epoch03-cer0.484.pth')
ap.add_argument('--val', default='data/pack/val'); ap.add_argument('--val-clips', type=int, default=200)
a = ap.parse_args(); ROOT = Path(a.root)
sys.path.insert(0, str(ROOT/'visper')); sys.path.insert(0, str(ROOT/'code'))
from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
from espnet.nets.batch_beam_search import BatchBeamSearch
from espnet.nets.scorers.ctc import CTCPrefixScorer
from espnet.nets.scorers.length_bonus import LengthBonus
from language_metrics import score

j = json.load(open(ROOT/(a.val+'.json'))); clips = j['clips']; fm = np.memmap(ROOT/(a.val+'.frames.bin'), np.uint8, 'r')
ids = random.Random(1).sample(range(len(clips)), min(a.val_clips, len(clips)))
cfg = yaml.safe_load(open(ROOT/'visper/conf/model/visual_backbone/resnet_conformer.yaml')); cfg.update(ddim=cfg['adim'], dheads=cfg['aheads'])
tokens = ['<blank>']+[l.split()[0] for l in open(ROOT/'visper/spm/unigram/unigram_units.txt', encoding='utf8').read().splitlines()]+['<eos>']
model = E2E(len(tokens), SimpleNamespace(**cfg)); st = torch.load(ROOT/a.weights, map_location='cpu', weights_only=True)
if 'state_dict' in st: st = {k.removeprefix('model.'): v for k, v in st['state_dict'].items() if 'beam_search' not in k}
model.load_state_dict({k: v for k, v in st.items() if not k.startswith('pin_head.')}); model.cuda().eval()
beam = BatchBeamSearch(beam_size=5, vocab_size=len(tokens), weights={'decoder': .9, 'ctc': .1, 'length_bonus': 0., 'lm': 0.},
    scorers={'decoder': model.decoder, 'ctc': CTCPrefixScorer(model.ctc, model.eos), 'length_bonus': LengthBonus(len(tokens)), 'lm': None},
    sos=model.sos, eos=model.eos, token_list=tokens, pre_beam_score_key='decoder').eval().cuda()
E = U = 0
with torch.inference_mode():
    for i in ids:
        c = clips[i]; f = np.array(fm[c['foff']:c['foff']+c['frames']*9216]).reshape(-1, 96, 96)[:, 4:92, 4:92]
        x = ((torch.from_numpy(f.copy()).float()/255-.421)/.165)[None, :, None].cuda()
        with torch.autocast('cuda', dtype=torch.bfloat16): enc, _ = model.encoder(x, None)
        h = beam(enc.float().squeeze(0), lang=tokens.index('<zh>'))
        hyp = ''.join(tokens[t] for t in h[0].yseq.tolist()[2:] if t not in (model.eos, model.blank)).replace('▁', '')
        q = score(c['text'], hyp, 'zh_en_mixed' if re.search('[A-Za-z]', c['text']) else 'zh'); E += q['errors']; U += q['reference_units']
print('VISPER', a.weights, 'CER', round(E/U, 4), 'clips', len(ids))
