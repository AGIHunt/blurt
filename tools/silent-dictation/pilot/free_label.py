#!/usr/bin/env python3
"""Turn a free-talk take into training sentences with almost no human work. Everything stays on this Mac.

Finds sentences at pauses, transcribes each with Qwen3-ASR and Whisper, and marks the ones where they
disagree for review in free_review.py. --finish writes marks-reviewed.jsonl for rapid_cut.py and
shadow.json, the sentences to mouth afterwards. --check scores a scripted take against its script.

Usage: free_label.py <session> [--check] | free_label.py <session> --finish
Run with runtime/asr-venv.
"""
import argparse, hashlib, json, random, re, subprocess, sys, tempfile, wave
from pathlib import Path
import numpy as np, torch
from pypinyin import lazy_pinyin
from rapidfuzz.distance import Levenshtein
sys.path.insert(0, str(Path(__file__).parent))
from language_metrics import score

RATE = 16000; HOP = 480; MARGIN = .15


def read_audio(session):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)/'a.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(session/'take.mov'), '-map', '0:a:0', '-ac', '1', '-ar', str(RATE), '-c:a', 'pcm_s16le', str(path)], check=True)
        with wave.open(str(path)) as w: return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)/32768


def chunks(audio, gap=.6, shortest=1., longest=12.):
    n = len(audio)//HOP
    db = 20*np.log10(np.sqrt((audio[:n*HOP].reshape(n, HOP)**2).mean(1))+1e-9)
    loud = db > np.percentile(db, 10)+10
    runs = []; on = None
    for i, v in enumerate(loud):
        if v and on is None: on = i
        if not v and on is not None: runs.append([on, i]); on = None
    if on is not None: runs.append([on, n])
    frames = int(gap*RATE/HOP); merged = []
    for r in runs:
        if merged and r[0]-merged[-1][1] < frames: merged[-1][1] = r[1]
        else: merged.append(r)
    out = []
    def add(a, b):
        if (b-a)*HOP/RATE > longest:
            middle = (a+b)//2; span = (b-a)//3
            cut = middle-span+int(np.argmin(db[middle-span:middle+span]))
            add(a, cut); add(cut, b)
        elif (b-a)*HOP/RATE >= shortest: out.append((a*HOP/RATE, b*HOP/RATE))
    for a, b in merged: add(a, b)
    return out


def similar(a, b):
    x, y = (lazy_pinyin(re.sub(r'[^\w]', '', t).lower()) for t in (a, b))
    return 1-Levenshtein.distance(x, y)/max(len(x), len(y), 1)


def clean(text): return re.sub(r'\s+', ' ', text).strip()


def label(a):
    from qwen_asr import Qwen3ASRModel
    import mlx_whisper
    audio = read_audio(a.session); spans = chunks(audio)
    print('sentences', len(spans), 'speech seconds', round(sum(e-s for s, e in spans)), 'of', round(len(audio)/RATE), flush=True)
    asr = Qwen3ASRModel.from_pretrained(a.model, dtype=torch.float16, device_map='mps', max_new_tokens=128)
    rows, before = [], ''
    for n, (s, e) in enumerate(spans):
        y = audio[max(int((s-MARGIN)*RATE), 0):int((e+MARGIN)*RATE)]
        hint = f'{a.words}\n{before}'.strip()  # Names the speaker uses, and what was just said.
        first = clean(asr.transcribe(audio=(y, RATE), context=hint, language='Chinese')[0].text)
        second = clean(mlx_whisper.transcribe(y, path_or_hf_repo=a.whisper, language='zh', temperature=0, condition_on_previous_text=False, initial_prompt=a.words)['text'])
        before = first
        agree = similar(first, second)
        rows.append(dict(n=n, start=round(s-MARGIN, 3), end=round(e+MARGIN, 3), text=first, alt=second, agree=round(agree, 3), status='review' if agree < a.agree or not first else 'auto'))
        if n % 25 == 0: print(n, len(spans), flush=True)
    (a.session/'segments.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    print('auto', sum(r['status'] == 'auto' for r in rows), 'to review', sum(r['status'] == 'review' for r in rows))
    return rows


def check(a, rows):
    marks = [m for m in map(json.loads, open(a.session/'marks.jsonl')) if m.get('kind') == 'segment' and m.get('mode') == 'voiced']
    scored = []
    for m in marks:
        hit = [r for r in rows if min(r['end'], m['end'])-max(r['start'], m['start']) > .5]
        if hit: scored.append((min(r['agree'] for r in hit), score(m['text'], ''.join(r['text'] for r in hit), 'zh_en_mixed' if re.search('[A-Za-z]', m['text']) else 'zh')))
    for t in (0, .6, .7, .75, .8, .85):
        keep = [q for agree, q in scored if agree >= t]
        print('review below', t, 'flagged', len(scored)-len(keep), 'of', len(scored), 'CER of the rest', round(sum(q['errors'] for q in keep)/max(sum(q['reference_units'] for q in keep), 1), 4))


def finish(a):
    rows = json.loads((a.session/'segments.json').read_text())
    kept = [r for r in rows if r['status'] in ('auto', 'confirmed') and len(re.sub(r'\W', '', r['text'])) >= 4]
    with open(a.session/'marks-reviewed.jsonl', 'w') as f:
        for r in kept:
            r['line'] = hashlib.sha1(r['text'].encode()).hexdigest()[:12]
            f.write(json.dumps(dict(kind='segment', start=r['start'], end=r['end'], line=r['line'], text=r['text'], spoken=True, mode='voiced'), ensure_ascii=False)+'\n')
    usable = [r for r in kept if 6 <= len(re.sub(r'\W', '', r['text'])) <= 40]
    pick = random.Random(0).sample(usable, int(len(usable)*a.shadow))
    (a.session/'shadow.json').write_text(json.dumps([dict(id=r['line'], text=r['text'], app=None) for r in pick], ensure_ascii=False, indent=1))
    print('kept', len(kept), 'seconds', round(sum(r['end']-r['start'] for r in kept)), 'of', len(rows), 'to mouth', len(pick), 'dropped', sum(r['status'] == 'dropped' for r in rows), 'unreviewed', sum(r['status'] == 'review' for r in rows))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('session', type=Path)
    p.add_argument('--model', default=str(next((Path.home()/'.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots').iterdir())))
    p.add_argument('--whisper', default='mlx-community/whisper-large-v3-mlx')
    p.add_argument('--agree', type=float, default=.85, help='Below this Pinyin agreement between the two ASRs, a sentence goes to review')
    p.add_argument('--shadow', type=float, default=.4, help='Share of sentences to mouth afterwards')
    p.add_argument('--words', default='口喷鸡（Blurt）、Claude Code、Codex、computer use、Anthropic、Gemini、Qwen、Whisper、Wispr Flow、Typeless、SaaS、token、唇语、无声听写', help='Names and terms the speaker uses, given to both ASRs')
    p.add_argument('--check', action='store_true')
    p.add_argument('--finish', action='store_true')
    a = p.parse_args()
    if a.finish: finish(a); return
    rows = label(a)
    if a.check: check(a, rows)


if __name__ == '__main__': main()
