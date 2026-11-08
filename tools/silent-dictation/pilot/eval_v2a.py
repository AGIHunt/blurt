#!/usr/bin/env python3
"""Score a v2a checkpoint (video into the frozen Qwen3-ASR decoder, gpu/v2a_train.py) on the participant's clips.

Runs on this Mac only; personal video never leaves it. Reads rapid/free sessions (clips.json + rois.npy, 25 fps)
and prints CER per mode. Usage: eval_v2a.py <checkpoint.pt> <session dir>... [--output out.json] [--context text]
"""
import argparse, json, re, sys
from pathlib import Path
from types import SimpleNamespace
import numpy as np, torch, torch.nn.functional as F, yaml
HERE = Path(__file__).parent; sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent/'gpu'))
RUNTIME = Path.home()/'Library/Application Support/Blurt VSR Pilot/runtime'
from language_metrics import score


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('checkpoint'); p.add_argument('sessions', type=Path, nargs='+')
    p.add_argument('--output', type=Path); p.add_argument('--context', default='')
    p.add_argument('--qwen', default=str(next((Path.home()/'.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots').iterdir())))
    a = p.parse_args()
    if a.output and a.output.exists(): raise SystemExit('Choose a new output path')
    sys.path.insert(0, str(RUNTIME/'visper'))
    from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
    import v2a_model as V
    from qwen_asr import Qwen3ASRModel
    from qwen_asr.core.transformers_backend.modeling_qwen3_asr import _get_feat_extract_output_lengths
    dev = 'mps'; c = torch.load(a.checkpoint, map_location='cpu', weights_only=False)
    cfg = yaml.safe_load(open(RUNTIME/'visper/conf/model/visual_backbone/resnet_conformer.yaml')); cfg.update(ddim=cfg['adim'], dheads=cfg['aheads'])
    tokens = open(RUNTIME/'visper/spm/unigram/unigram_units.txt', encoding='utf8').read().splitlines()
    encoder = E2E(len(tokens)+2, SimpleNamespace(**cfg)).encoder; encoder.load_state_dict(c['encoder']); encoder.to(dev).eval()
    bridge = V.Bridge(cfg['adim']); bridge.load_state_dict(c['bridge']); bridge.to(dev).eval()
    fmean, fstd = c['fmean'].to(dev), c['fstd'].to(dev)
    asr = Qwen3ASRModel.from_pretrained(a.qwen, dtype=torch.float16, device_map=dev, max_new_tokens=160)
    thinker = next(m for m in asr.model.modules() if hasattr(m, 'get_audio_features'))
    if c.get('lora'):
        lora = V.add_lora(thinker.model, c['args']['lora'])
        for q, w in zip(lora, c['lora']): q.data.copy_(w.to(q.device))
    swap = dict(feats=None); original = thinker.get_audio_features
    def patched(*args, **kw):
        out = original(*args, **kw)
        mask = kw.get('feature_attention_mask', args[1] if len(args) > 1 else None)
        want = _get_feat_extract_output_lengths(mask.sum(1)).tolist()
        fit = [f if len(f) == w else F.interpolate(f.T[None].float(), size=w, mode='linear')[0].T for f, w in zip(swap['feats'], want)]
        return torch.cat(fit).to(out.dtype)
    thinker.get_audio_features = patched
    rows = []; totals = {}
    for s in a.sessions:
        for clip in json.loads((s/'clips.json').read_text()):
            x = np.load(Path(clip['folder'])/'rois.npy')[:, 4:92, 4:92]
            v = ((torch.from_numpy(x.copy()).float()/255-.421)/.165)[None, :, None].to(dev)
            samples = int(len(x)/25*16000)
            T = int(_get_feat_extract_output_lengths(torch.tensor([samples//160]))[0])  # 100 mel frames a second
            with torch.no_grad():
                enc, _ = encoder(v, None)
                pred, _ = bridge(enc.float(), torch.tensor([len(x)]), [T])
            swap['feats'] = [pred[0]*fstd+fmean]
            hyp = asr.transcribe(audio=(np.zeros(samples, np.float32), 16000), context=a.context, language='Chinese')[0].text
            q = score(clip['text'], hyp, 'zh_en_mixed' if re.search('[A-Za-z]', clip['text']) else 'zh')
            t = totals.setdefault(clip['mode'], [0, 0]); t[0] += q['errors']; t[1] += q['reference_units']
            rows.append(dict(id=clip['id'], mode=clip['mode'], reference=clip['text'], hypothesis=hyp, cer=round(q['errors']/max(q['reference_units'], 1), 3)))
    for m, (e, u) in sorted(totals.items()): print(f'{m:8s} CER {e/u:.3f}  clips {sum(r["mode"] == m for r in rows)}')
    if a.output: a.output.write_text(json.dumps(dict(checkpoint=a.checkpoint, totals={m: e/u for m, (e, u) in totals.items()}, clips=rows), ensure_ascii=False, indent=1))


if __name__ == '__main__': main()
