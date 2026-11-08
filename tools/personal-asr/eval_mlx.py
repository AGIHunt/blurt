#!/usr/bin/env python3
"""Step 8: score MLX builds on the held-out pieces through the app's own decoder (transcribe.py Qwen3Mlx: word list,
field text, text so far, language-tag handling), each dictation in order with the model's own earlier output as
the text so far. Compares the stock 8-bit build with the personal one before deploying.

Usage (Mac): uv run --with mlx-qwen3-asr==0.4.4 --with soundfile python eval_mlx.py <export dir> <mlx dir>...
"""
import json, re, sys, wave
from pathlib import Path
from types import SimpleNamespace
import numpy as np
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'skills/blurt/scripts')); sys.path.insert(0, str(ROOT/'tools/silent-dictation/pilot'))
import transcribe as T
from language_metrics import score


def main():
    data = Path(sys.argv[1]); test = [json.loads(l) for l in open(data/'test.jsonl')]
    takes = {}
    for x in test: takes.setdefault(x['id'].rsplit('-', 1)[0], []).append(x)
    terms = [t for t in json.load(open(Path.home()/'.blurt/dictation/vocabulary.json'))['terms'] if t.get('state') == 'active']
    for model in sys.argv[2:]:
        b = T.Qwen3Mlx(SimpleNamespace(model=model, prompt='', language=None))
        b.set_vocab(terms); e = u = 0; rows = []
        for xs in takes.values():
            heard = ''
            for x in sorted(xs, key=lambda x: x['id']):
                with wave.open(str(data/x['wav'])) as w: y = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)/32768
                b.set_field(x['field']); b.set_prior(heard)
                text = ''.join(seg[2] for seg in b.transcribe(y)).strip(); heard += text
                q = score(x['text'], text, 'zh_en_mixed' if re.search('[A-Za-z]', x['text']) else 'zh'); e += q['errors']; u += q['reference_units']
                rows.append(dict(ref=x['text'], hyp=text))
        b.close()
        print(model, 'CER', round(e/u, 4), 'pieces', len(rows), flush=True)
        (data/f"mlx-{Path(model).name}.json").write_text(json.dumps(rows, ensure_ascii=False))


if __name__ == '__main__': main()
