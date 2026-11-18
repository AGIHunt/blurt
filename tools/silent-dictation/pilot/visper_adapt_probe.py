#!/usr/bin/env python3
"""Bounded research-only personalization diagnostic using phrase-held-out train data.

This does not relabel dataset splits or consume validation/test recordings.
The small, same-session development holdout cannot establish generalization.
"""
import argparse
import json
from pathlib import Path
import random
import re
import time
import unicodedata
import numpy as np
import sentencepiece as spm
import torch
from dataset import load_clips, sha256, write_json, split_audit
from language_metrics import score
from multilingual_probe import setup, input_tensor, decode, summarize


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--checkout', type=Path, required=True)
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--crop-folder', default='prepared-mediapipe')
    p.add_argument('--device', default='mps', choices=['cpu', 'mps'])
    p.add_argument('--beam', type=int, default=10)
    p.add_argument('--epochs', type=int, default=3)
    p.add_argument('--max-seconds', type=int, default=600)
    p.add_argument('--holdout-families', nargs='+', default=['document_summary', 'umbrella'])
    p.add_argument('--development-split', choices=['within-train', 'validation'], default='within-train')
    p.add_argument('--train-modes', nargs='+', choices=['silent', 'exaggerated_silent', 'whisper', 'voiced'],
                   default=['silent', 'exaggerated_silent', 'whisper', 'voiced'])
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args(); a.backend = 'visper'
    if a.output.exists() or a.output.with_suffix('.pth').exists(): raise ValueError('Choose new output paths')
    if not 1 <= a.epochs <= 10 or not 1 <= a.max_seconds <= 1800: raise ValueError('Budget out of bounds')
    torch.set_num_threads(4); torch.manual_seed(7); random.seed(7)
    plan, clips = load_clips(a.root)
    audit = split_audit(a.root, clips)
    wanted = {'train', 'validation'} if a.development_split == 'validation' else {'train'}
    clips = [c for c in clips if c['split'] in wanted]
    if a.development_split == 'validation':
        if {c['id'] for c in clips} != {c['id'] for c in plan['takes'] if c['split'] in wanted}:
            raise ValueError('Complete train and validation recordings required')
    if len({c['speaker_id'] for c in clips}) != 1: raise ValueError('One speaker required')
    held = set(a.holdout_families) if a.development_split == 'within-train' else set()
    if a.development_split == 'within-train' and not held < {c['phrase_family'] for c in clips}:
        raise ValueError('Invalid family holdout')
    model, beam, tokens = setup(a)
    from espnet.nets.pytorch_backend.transformer.add_sos_eos import add_sos_eos
    from espnet.nets.pytorch_backend.transformer.mask import target_mask
    tokenizer = spm.SentencePieceProcessor(model_file=str(a.checkout/'spm/unigram/unigram.model'))
    vocab = {word: i for i, word in enumerate(tokens)}
    sets = {'fit': [], 'development': []}
    for c in clips:
        folder = a.root/a.crop_folder/c['id']; meta = json.loads((folder/'status.json').read_text())
        if meta['status'] != 'ready' or meta['signature']['source_sha256'] != sha256(a.root/c['video']): raise ValueError('Unready/stale crops')
        if meta['rois_sha256'] != sha256(folder/'rois.npy'): raise ValueError('Crop checksum mismatch')
        text = unicodedata.normalize('NFKC', c['reference_text'])
        text = ''.join(ch for ch in text if ch.isalnum() or ch.isspace() or ch == "'")
        profile = c.get('language_profile', c['language'])
        if profile != 'en':
            # Upstream appends Han characters to its multilingual dictionary;
            # its SentencePiece model alone groups adjacent Han as one unknown.
            # Split Han while preserving English words/acronyms in mixed speech.
            segmented = re.sub(r'([\u3400-\u9fff])', r' \1 ', text)
            pieces = tokenizer.encode(segmented, out_type=str)
            pieces = pieces[:1] + [v for v in pieces[1:] if v != '▁']
        else: pieces = tokenizer.encode(text, out_type=str)
        unknown = [v for v in pieces if v not in vocab or v == '<unk>']
        if unknown: raise ValueError(f"Unsupported targets in {c['id']}: {unknown}")
        ids = [vocab['<en>' if profile == 'en' else '<zh>']] + [vocab[v] for v in pieces]
        rois = np.load(folder/'rois.npy', allow_pickle=False)
        if len(ids) >= len(rois): raise ValueError('Not enough frames for target sequence')
        if c['split'] == 'validation' or c['phrase_family'] in held: sets['development'].append((c, rois, ids))
        elif c['mode'] in a.train_modes: sets['fit'].append((c, rois, ids))
    if not all(sets.values()): raise ValueError('Empty fit/development set')
    if a.development_split == 'validation':
        for field in ('phrase_family', 'session_id'):
            if {c[field] for c,_,_ in sets['fit']} & {c[field] for c,_,_ in sets['development']}:
                raise ValueError('Fit/development overlap')
    fit_hashes = {sha256(a.root/c['video']) for c,_,_ in sets['fit']}
    if fit_hashes & {sha256(a.root/c['video']) for c,_,_ in sets['development']}: raise ValueError('Duplicate media across holdout')
    prefixes = ('encoder.frontend.', 'encoder.embed.', 'encoder.encoders.0.')
    for name, param in model.named_parameters(): param.requires_grad_(name.startswith(prefixes))
    model.to(a.device).eval() # Keep BatchNorm statistics and dropout fixed for this small probe.
    optimizer = torch.optim.AdamW([v for v in model.parameters() if v.requires_grad], lr=1e-5, weight_decay=1e-4)
    def loss_for(rois, ids):
        x = input_tensor(rois, 'visper', a.device)
        features, _ = model.encoder(x, None)
        target = torch.tensor([ids], device=a.device)
        yin, yout = add_sos_eos(target, model.sos, model.eos, -1)
        pred, _ = model.decoder(yin, target_mask(yin, -1), features, None)
        attention = model.criterion(pred[:, 1:].contiguous(), yout[:, 1:].contiguous())
        # CTCLoss runs on CPU; copies preserve the gradient back to the MPS encoder.
        logp = model.ctc.ctc_lo(features).log_softmax(-1).transpose(0,1).cpu()
        ctc = torch.nn.functional.ctc_loss(logp, target.cpu(), torch.tensor([len(rois)]),
            torch.tensor([len(ids)]), blank=0, reduction='sum', zero_infinity=False)
        return .9*attention + .1*ctc.to(a.device)
    start = time.perf_counter(); deadline = start+a.max_seconds
    def check_time():
        if time.perf_counter() > deadline: raise TimeoutError('Bounded diagnostic budget reached')
    def validate():
        losses=[]
        with torch.no_grad():
            for _,rois,ids in sets['development']:
                check_time(); loss=loss_for(rois,ids)
                if not torch.isfinite(loss): raise ValueError('Nonfinite development loss')
                losses.append(float(loss.cpu()))
        return sum(losses)/len(losses)
    def snapshot(): return {k:v.detach().cpu().clone() for k,v in model.state_dict().items() if k.startswith(prefixes)}
    baseline=validate(); best=baseline; best_epoch=0; best_state=snapshot()
    history=[dict(epoch=0,development_loss=baseline)]; stop='epochs_complete'
    print('Baseline development loss',baseline,flush=True)
    try:
        for epoch in range(1,a.epochs+1):
            items=list(sets['fit']);random.shuffle(items); losses=[]
            for c,rois,ids in items:
                check_time();optimizer.zero_grad(set_to_none=True);loss=loss_for(rois,ids)
                if not torch.isfinite(loss):raise ValueError('Nonfinite training loss')
                loss.backward();torch.nn.utils.clip_grad_norm_([v for v in model.parameters() if v.requires_grad],5);optimizer.step()
                losses.append(float(loss.detach().cpu()))
            dev=validate();history.append(dict(epoch=epoch,fit_loss=sum(losses)/len(losses),development_loss=dev))
            if dev<best:best=dev;best_epoch=epoch;best_state=snapshot()
            print(history[-1],flush=True)
    except TimeoutError as e:stop=str(e)
    model.load_state_dict(best_state,strict=False)
    adapter=a.output.with_suffix('.pth');adapter.parent.mkdir(parents=True,exist_ok=True);torch.save(best_state,adapter)
    scope = ('Research-only same-session phrase-held-out diagnostic, NOT independent validation/test'
             if a.development_split == 'within-train' else
             'Train-only gradient updates; separate-session validation selects epoch. NOT an untouched test result')
    result=dict(scope=scope,development_split=a.development_split,split_audit=audit,
        checkpoint_sha256=sha256(a.checkpoint),adapter_sha256=sha256(adapter),selected_epoch=best_epoch,
        speaker_id=clips[0]['speaker_id'],crop_folder=a.crop_folder,train_modes=a.train_modes,
        adapted_prefixes=list(prefixes),learning_rate=1e-5,seed=7,beam=a.beam,
        source_sha256={c['id']:sha256(a.root/c['video']) for group in sets.values() for c,_,_ in group},
        script_sha256=sha256(Path(__file__)),tokenizer_sha256=sha256(a.checkout/'spm/unigram/unigram.model'),
        history=history,stop_reason=stop,training_seconds=time.perf_counter()-start,
        fit_ids=[c['id'] for c,_,_ in sets['fit']],development_ids=[c['id'] for c,_,_ in sets['development']],
        holdout_families=sorted(held),trainable_parameters=sum(v.numel() for v in model.parameters() if v.requires_grad),clips=[])
    write_json(a.output,result)
    # Move decoder and CTC back to CPU; preserve the efficient encoder path.
    model.cpu();model.encoder.to(a.device);model.eval()
    for c,rois,_ in sets['development']:
        profile=c.get('language_profile',c['language']); t=time.perf_counter()
        hypothesis=decode(model,beam,tokens,rois,profile,a)
        row=dict(id=c['id'],mode=c['mode'],language_profile=profile,reference_text=c['reference_text'],
                 hypothesis=hypothesis,status='ok',inference_seconds=time.perf_counter()-t,
                 accuracy=score(c['reference_text'],hypothesis,profile))
        result['clips'].append(row);result['summary']=summarize(result['clips']);write_json(a.output,result)
        print(c['id'],hypothesis,flush=True)


if __name__=='__main__':main()
