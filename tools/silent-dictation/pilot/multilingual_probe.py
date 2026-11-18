#!/usr/bin/env python3
"""Isolated visual-only Mandarin/multilingual diagnostic; never uses reference at decode.

Upstream research-only weights are kept outside the product. All selected failures
count as empty hypotheses. Training-set results are diagnostics, not test accuracy.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import sys
import time
from types import SimpleNamespace

import numpy as np
import torch
from dataset import load_clips, sha256, write_json, split_audit
from language_metrics import score


def setup(args):
    sys.path.insert(0, str(args.checkout))
    from espnet.nets.batch_beam_search import BatchBeamSearch
    from espnet.nets.scorers.ctc import CTCPrefixScorer
    from espnet.nets.scorers.length_bonus import LengthBonus
    if args.backend == 'visper':
        from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
        import yaml
        config = yaml.safe_load((args.checkout / 'conf/model/visual_backbone/resnet_conformer.yaml').read_text())
        config.update(ddim=config['adim'], dheads=config['aheads'])
        tokens = ['<blank>'] + [line.split()[0] for line in
            (args.checkout / 'spm/unigram/unigram_units.txt').read_text().splitlines()] + ['<eos>']
    elif args.backend == 'cnvsrc':
        from espnet.nets.pytorch_backend.e2e_asr_transformer import E2E
        import yaml
        config = yaml.safe_load((args.checkout/'conf/test_cnvsrc-multi.yaml').read_text())['model']['visual_backbone']
        rows = [line.split() for line in (args.checkout/'datamodule/char_units.txt').read_text().splitlines()]
        if any(int(row[-1]) != i+1 for i,row in enumerate(rows)): raise ValueError('Noncontiguous character IDs')
        tokens = ['<blank>'] + [row[0] for row in rows] + ['<eos>']
    else:
        from espnet.nets.pytorch_backend.e2e_asr_transformer import E2E
        config = json.loads(args.config.read_text())
        if isinstance(config, list): config = config[2]
        tokens = config['char_list']
    model = E2E(len(tokens), SimpleNamespace(**config))
    state = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    if 'state_dict' in state:
        state = {k.removeprefix('model.'): v for k, v in state['state_dict'].items() if 'beam_search' not in k}
    model.load_state_dict(state, strict=True)
    if getattr(args, 'adapter', None):
        metadata = json.loads(args.adapter.with_suffix('.json').read_text())
        if metadata['checkpoint_sha256'] != sha256(args.checkpoint): raise ValueError('Adapter base mismatch')
        if metadata['adapter_sha256'] != sha256(args.adapter): raise ValueError('Adapter checksum mismatch')
        if metadata['crop_folder'] != args.crop_folder: raise ValueError('Adapter preprocessing mismatch')
        adapted = torch.load(args.adapter, map_location='cpu', weights_only=True)
        prefixes = ('encoder.frontend.', 'encoder.embed.', 'encoder.encoders.0.')
        expected = {k for k in model.state_dict() if k.startswith(prefixes)}
        if set(adapted) != expected: raise ValueError('Unexpected adapter tensors')
        model.load_state_dict(adapted, strict=False)
    model.eval()
    ctc_weight = getattr(args, 'ctc_weight', .1)
    beam = BatchBeamSearch(beam_size=args.beam, vocab_size=len(tokens),
        weights={'decoder': 1-ctc_weight, 'ctc': ctc_weight, 'length_bonus': 0.0, 'lm': 0.0},
        scorers={'decoder': model.decoder, 'ctc': CTCPrefixScorer(model.ctc, model.eos),
                 'length_bonus': LengthBonus(len(tokens)), 'lm': None},
        sos=model.sos, eos=model.eos, token_list=tokens, pre_beam_score_key='decoder')
    beam.eval()
    if getattr(args, 'lm', None):
        if args.backend != 'cmlr': raise ValueError('External Mandarin LM is only supported for CMLR')
        from pipelines.model import get_beam_search_decoder
        beam = get_beam_search_decoder(model, tokens, str(args.lm), str(args.lm_config),
                                       penalty=.3, ctc_weight=.1, lm_weight=.3, beam_size=args.beam)
        beam.eval()
    model.encoder.to(args.device)
    return model, beam, tokens


def input_tensor(rois, backend, device):
    if rois.dtype != np.uint8 or rois.ndim != 3 or rois.shape[1:] != (96, 96):
        raise ValueError('Expected uint8 T×96×96 mouth crops')
    x = (torch.from_numpy(rois[:, 4:92, 4:92].copy()).float() / 255 - .421) / .165
    return (x[:, None] if backend in ('visper', 'cnvsrc') else x[None]).unsqueeze(0).to(device)


def decode(model, beam, tokens, rois, profile, args):
    with torch.inference_mode():
        x = input_tensor(rois, args.backend, args.device)
        encoded, _ = model.encoder(x, None)
        encoded = encoded.squeeze(0).cpu()
        if args.backend == 'visper':
            language = getattr(args, 'force_language', None) or ('en' if profile == 'en' else 'zh')
            lang = tokens.index(f'<{language}>')
            hyps = beam(encoded, lang=lang)
            ids = hyps[0].yseq.tolist()[2:]
        else:
            hyps = beam(encoded)
            ids = hyps[0].yseq.tolist()[1:]
        return ''.join(tokens[i] for i in ids if i not in (model.eos, model.blank)).replace('▁', ' ').replace('<space>', ' ').strip()


def summarize(rows):
    groups = defaultdict(list)
    for row in rows: groups[(row['language_profile'], row['mode'])].append(row)
    return [dict(language_profile=profile, mode=mode, clips=len(items),
                 metric=items[0]['accuracy']['metric'],
                 error_rate=sum(r['accuracy']['errors'] for r in items) / sum(r['accuracy']['reference_units'] for r in items),
                 exact_matches=sum(r['accuracy']['normalized_exact_match'] for r in items),
                 failures=sum(r['status'] != 'ok' for r in items))
            for (profile, mode), items in sorted(groups.items())]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--backend', choices=['cmlr', 'visper', 'cnvsrc'], required=True)
    p.add_argument('--checkout', type=Path, required=True)
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--config', type=Path)
    p.add_argument('--lm', type=Path)
    p.add_argument('--lm-config', type=Path)
    p.add_argument('--device', default='mps', choices=['cpu', 'mps'])
    p.add_argument('--beam', type=int, default=10)
    p.add_argument('--ctc-weight', type=float, default=.1)
    p.add_argument('--force-language', choices=['en', 'zh'], help='Explicit ViSpeR language-tag ablation; scoring language stays unchanged')
    p.add_argument('--crop-folder', default='prepared')
    p.add_argument('--split', choices=['train', 'validation', 'test'], default='train')
    p.add_argument('--profiles', nargs='+', default=['zh', 'zh_en_mixed', 'en'])
    p.add_argument('--families', nargs='+')
    p.add_argument('--adapter', type=Path, help='ViSpeR adapter with matching sibling JSON provenance')
    p.add_argument('--limit', type=int)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if not 0 <= args.ctc_weight < 1: raise ValueError('CTC weight must be in [0,1)')
    if args.force_language and args.backend != 'visper': raise ValueError('Language-tag override requires ViSpeR')
    if args.output.exists(): raise ValueError('Choose a new output path')
    torch.set_num_threads(4)
    _, clips = load_clips(args.root)
    audit = split_audit(args.root, clips)
    clips = [c for c in clips if c['split'] == args.split and c.get('language_profile', c['language']) in args.profiles]
    if args.families: clips = [c for c in clips if c['phrase_family'] in args.families]
    if args.limit: clips = clips[:args.limit]
    if not clips: raise ValueError('No matching verified clips')
    if args.adapter:
        if args.backend != 'visper': raise ValueError('Adapter path currently supports ViSpeR only')
        metadata = json.loads(args.adapter.with_suffix('.json').read_text())
        fit_hashes = {metadata['source_sha256'][key] for key in metadata['fit_ids']}
        for c in clips:
            if c['speaker_id'] != metadata['speaker_id']: raise ValueError('Wrong speaker adapter')
            if c['id'] in metadata['fit_ids'] or sha256(args.root/c['video']) in fit_hashes:
                raise ValueError('Evaluation media was used for gradient updates')
    started = time.perf_counter()
    model, beam, tokens = setup(args)
    result = dict(backend=args.backend, checkpoint_sha256=sha256(args.checkpoint),
        scope='Visual-only diagnostic; no audio, prompt hints or LLM cleanup; independence requires protocol review',
        split=args.split, is_independent_test=False, split_audit=audit, beam=args.beam,
        adapter_sha256=sha256(args.adapter) if args.adapter else None,
        ctc_weight=args.ctc_weight,
        force_language=args.force_language,
        crop_folder=args.crop_folder, load_seconds=time.perf_counter()-started,
        vocabulary_size=len(tokens), language_models=bool(args.lm),
        lm_sha256=sha256(args.lm) if args.lm else None, clips=[])
    for c in clips:
        row = {k: c[k] for k in ['id', 'mode', 'reference_text', 'phrase_family', 'split']}
        row['language_profile'] = c.get('language_profile', c['language'])
        try:
            folder = args.root / args.crop_folder / c['id']
            status = json.loads((folder / 'status.json').read_text())
            if status['status'] != 'ready': raise ValueError(status.get('error', 'Preparation not ready'))
            if status['signature']['source_sha256'] != sha256(args.root / c['video']): raise ValueError('Stale crops')
            if status['rois_sha256'] != sha256(folder / 'rois.npy'): raise ValueError('Crop checksum mismatch')
            rois = np.load(folder / 'rois.npy', allow_pickle=False)
            t = time.perf_counter()
            hypothesis = decode(model, beam, tokens, rois, row['language_profile'], args)
            row.update(status='ok', hypothesis=hypothesis, inference_seconds=time.perf_counter()-t,
                       frames=len(rois), source_sha256=status['signature']['source_sha256'])
        except (ValueError, OSError, RuntimeError, KeyError) as e:
            row.update(status='failed', hypothesis='', error=str(e))
        row['accuracy'] = score(row['reference_text'], row['hypothesis'], row['language_profile'])
        result['clips'].append(row)
        result['summary'] = summarize(result['clips'])
        write_json(args.output, result)
        print(f"{row['status']} {row['id']}: {row['hypothesis']}", flush=True)
    print(json.dumps(result['summary'], ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
