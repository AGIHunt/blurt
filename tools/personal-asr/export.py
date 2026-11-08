#!/usr/bin/env python3
"""Step 4: turn labels into training pieces, the way the app decodes them.

The app transcribes each piece on its own, with a system prompt of the word list, the field's text and the
dictation's text so far (skills/blurt/scripts/transcribe.py, decode). Each exported piece carries that same context,
built from the labels, so the fine-tuned model sees at training what it sees in use.
Train pieces the labeler was unsure of are left out unless the user confirmed them (review.py). Test pieces must all
be sure or confirmed.

Number-format fixes from a later labeling pass (numbers/out-*.jsonl) replace the text of those pieces.

Usage: export.py <work dir>     writes <work>/export/{wav/*.wav, train.jsonl, test.jsonl}
"""
import json, sys, wave
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'skills/blurt/scripts'))
import dictation_vocab
HOME = Path.home()/'.blurt/dictation'; RATE = 16000


def main():
    work = Path(sys.argv[1]); out = work/'export'; (out/'wav').mkdir(parents=True, exist_ok=True)
    cands = {json.loads(l)['id']: json.loads(l) for l in open(work/'candidates.jsonl')}
    reviewed = {}
    if (work/'reviewed.jsonl').exists():
        for l in open(work/'reviewed.jsonl'): x = json.loads(l); reviewed[(x['id'], x['n'])] = x
    fixes = {}   # later passes over the labels (numbers/out-*.jsonl: number formatting), text only
    for f in sorted((work/'numbers').glob('out-*.jsonl')) if (work/'numbers').exists() else []:
        if '.first' in f.name: continue
        for l in open(f):
            if l.strip(): x = json.loads(l); fixes[(x['id'], x['n'])] = x['said']
    terms = [t for t in json.load(open(HOME/'vocabulary.json'))['terms'] if t.get('state') == 'active']
    words = dictation_vocab.qwen_context(terms)
    files = {s: open(out/f'{s}.jsonl', 'w') for s in ('train', 'test')}; counts = {'train': 0, 'test': 0, 'skipped': 0, 'unconfirmed_test': 0}
    for line in open(work/'labels.jsonl'):
        r = json.loads(line); field = cands[r['id']]['field']
        with wave.open(str(HOME/r['audio'])) as w: y = np.frombuffer(w.readframes(w.getnframes()), np.int16)
        prior = []
        for p in r['pieces']:
            said, sure = p['said'], p['sure']
            if (r['id'], p['n']) in reviewed:
                x = reviewed[(r['id'], p['n'])]; said, sure = x['said'], not x.get('drop')
            if sure and (r['id'], p['n']) in fixes: said = fixes[(r['id'], p['n'])]
            if sure and said.strip():
                path = out/'wav'/f"{r['id']}-{p['n']:02d}.wav"
                with wave.open(str(path), 'wb') as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(y[int(p['start']*RATE):int(p['end']*RATE)].tobytes())
                files[r['split']].write(json.dumps(dict(id=f"{r['id']}-{p['n']:02d}", wav=f'wav/{path.name}', text=said, words=words, field=field,
                                                        prior=''.join(prior), app_heard=p['qwen17'], seconds=round(p['end']-p['start'], 2)), ensure_ascii=False)+'\n')
                counts[r['split']] += 1
            else:
                counts['skipped' if r['split'] == 'train' else 'unconfirmed_test'] += 1
            if said.strip(): prior.append(said)
    print(counts)


if __name__ == '__main__': main()
