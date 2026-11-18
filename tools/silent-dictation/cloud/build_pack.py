#!/usr/bin/env python3
"""Pack Chinese-LiPS 96x96 mouth clips into one uint8 frame file plus a JSON index.

Usage: build_pack.py <split> <clip_dir> <meta_csv> <out_prefix>
Text targets: ViSpeR SentencePiece ids and toneless Pinyin ids for the auxiliary CTC head.
"""
import csv, json, multiprocessing as mp, re, sys, unicodedata
from pathlib import Path
import cv2, numpy as np, sentencepiece as spm
from pypinyin import lazy_pinyin, Style

VISPER = '/data/visper'
MAX_FRAMES = 600


def decode(path):
    cap = cv2.VideoCapture(path); out = []
    while True:
        ok, x = cap.read()
        if not ok: break
        out.append(cv2.cvtColor(x, cv2.COLOR_BGR2GRAY))
    return np.stack(out) if out else None


def work(row):
    f = row['path']
    if not Path(f).exists(): return None
    a = decode(f)
    if a is None or a.shape[1:] != (96, 96) or len(a) > MAX_FRAMES or len(a) < 10: return None
    return row['ID'], a


def pinyin_tokens(text):
    out = []
    for piece in re.findall(r'[㐀-鿿]+|[A-Za-z]+|[0-9]', text):
        if re.match(r'[㐀-鿿]', piece):
            out += lazy_pinyin(piece, style=Style.NORMAL, errors='ignore')
        else: out += [c.lower() for c in piece]
    return out


def main():
    split, clips, meta, prefix = sys.argv[1:5]
    tokens = ['<blank>'] + [l.split()[0] for l in open(f'{VISPER}/spm/unigram/unigram_units.txt', encoding='utf8').read().splitlines()] + ['<eos>']
    vocab = {w: i for i, w in enumerate(tokens)}
    sp = spm.SentencePieceProcessor(model_file=f'{VISPER}/spm/unigram/unigram.model')
    pin_path = Path('/data/pack/pinyin_vocab.json')
    pin = json.loads(pin_path.read_text()) if pin_path.exists() else None
    rows = list(csv.DictReader(open(meta, encoding='utf8')))
    for r in rows: r['path'] = f"{clips}/{r['ID']}.mp4"
    text = {r['ID']: r['TEXT'] for r in rows}; topic = {r['ID']: r['TOPIC'] for r in rows}
    if pin is None:
        seen = sorted({t for r in rows for t in pinyin_tokens(unicodedata.normalize('NFKC', r['TEXT']))})
        pin = {t: i+1 for i, t in enumerate(seen)}   # 0 is the CTC blank
        pin_path.parent.mkdir(exist_ok=True); pin_path.write_text(json.dumps(pin, ensure_ascii=False))
    index = []; offset = 0; dropped = unk = 0
    with open(prefix + '.bin', 'wb') as out, mp.Pool(15) as pool:
        for n, item in enumerate(pool.imap(work, rows, chunksize=16)):
            if item is None: dropped += 1; continue
            key, a = item
            t = unicodedata.normalize('NFKC', text[key])
            t = ''.join(ch for ch in t if ch.isalnum() or ch.isspace() or ch == "'")
            pieces = sp.encode(re.sub(r'([㐀-鿿])', r' \1 ', t), out_type=str)
            pieces = pieces[:1] + [v for v in pieces[1:] if v != '▁']
            ids = [vocab['<zh>']] + [vocab.get(v, vocab['<unk>']) for v in pieces]
            unk += sum(v not in vocab for v in pieces)
            py = [pin[v] for v in pinyin_tokens(t) if v in pin]
            if len(ids) >= len(a) or len(py) >= len(a): dropped += 1; continue
            out.write(a.tobytes())
            index.append(dict(id=key, offset=offset, frames=len(a), text=t, ids=ids, py=py, topic=topic[key]))
            offset += a.size
            if n % 2000 == 0: print(split, n, len(index), offset/1e9, flush=True)
    json.dump(index, open(prefix + '.json', 'w'), ensure_ascii=False)
    print('done', split, len(index), 'frames', offset//(96*96), 'dropped', dropped, 'unk pieces', unk)


if __name__ == '__main__': main()
