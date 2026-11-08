#!/usr/bin/env python3
"""Rescore lip-reading n-best output with a language model; scores raw and rescored side by side.

Only decoded text and Pinyin are sent. The reference, audio and video are never sent; the reference
is read locally to score the answer. Rewrites are reported beside raw output so a fluent wrong
sentence cannot hide. GEMINI_API_KEY comes from the environment. --ollama stays on this Mac; use it for
rapid sessions, whose sentences come from the user's own messages.

Usage: llm_rescore.py <eval.json> --output out.json [--model gemini-4-argon | --ollama qwen3.5:4b] [--glossary a,b,c] [--modes silent]
"""
import argparse, concurrent.futures as cf, json, os, sys, time, urllib.error, urllib.request
from collections import defaultdict
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from language_metrics import score

PROMPT = """You are helping decode silent speech. A person mouthed one sentence at a laptop camera with no sound, and a lip-reading model produced the noisy guesses below. Lip reading cannot see tone or voicing, and it confuses sounds that look alike (b/p/m, d/t/n/l, g/k/h, z/c/s, zh/ch/sh, j/q/x, in/ing, an/ang). Character guesses are usually wrong, but their sounds, rhythm and length often survive.

The person is a software developer who dictates mostly in Mandarin with some English technical terms, or sometimes in English. The sentence may be a work instruction or an everyday request.
{glossary}
Candidates, most likely first:
{candidates}
{pinyin}
Write the single most likely sentence the person actually mouthed, in the language they used. Stay close to the sounds and length of the evidence. Do not add ideas that have no support in it. Reply with the sentence only."""


def ask(model, prompt, key, thinking=None):
    body = dict(contents=[dict(role='user', parts=[dict(text=prompt)])], generationConfig=dict(temperature=.2))
    req = urllib.request.Request(f'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent',
        data=json.dumps(body).encode(), headers={'x-goog-api-key': key, 'content-type': 'application/json'})
    for attempt in range(5):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=120))
            return ''.join(p.get('text', '') for p in r['candidates'][0]['content']['parts']).strip()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors='replace')[:300]
            if e.code == 400 or attempt == 4: raise RuntimeError(f'{e.code}: {detail}')
            time.sleep(2*(attempt+1))
        except Exception as e:
            if attempt == 4: raise
            time.sleep(2*(attempt+1))


def ask_ollama(model, prompt):
    body = dict(model=model, prompt=prompt, stream=False, think=False, options=dict(temperature=.2, num_predict=200))
    req = urllib.request.Request('http://localhost:11434/api/generate', data=json.dumps(body).encode(), headers={'content-type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, timeout=300))
    return r['response'].strip(), r['total_duration']/1e9


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('run', type=Path)
    p.add_argument('--model', default='gemini-4-argon')
    p.add_argument('--ollama', help='Local Ollama model; nothing leaves this Mac')
    p.add_argument('--modes', nargs='+', help='Rescore only these capture modes')
    p.add_argument('--glossary', default='')
    p.add_argument('--no-pinyin', action='store_true')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    key = None if a.ollama else os.environ['GEMINI_API_KEY']
    run = json.loads(a.run.read_text()); clips = [c for c in run['clips'] if not a.modes or c['mode'] in a.modes]
    seconds = []
    glossary = f'Words this person often uses: {a.glossary}\n' if a.glossary else ''
    def one(c):
        cands = [n['text'] if isinstance(n, dict) else n for n in c['nbest']]
        cands = '\n'.join(f'{i+1}. {t}' for i, t in enumerate(dict.fromkeys(cands)))
        py = '' if a.no_pinyin or not c.get('pinyin') else 'Sound-only guess (toneless Pinyin): ' + ' '.join(c['pinyin']) + '\n'
        try:
            prompt = PROMPT.format(glossary=glossary, candidates=cands, pinyin=py)
            if not a.ollama: return ask(a.model, prompt, key)
            answer, took = ask_ollama(a.ollama, prompt); seconds.append(took); return answer
        except Exception as e:
            print('FAILED', c['id'], str(e)[:200], 'prompt chars', len(cands)+len(py), flush=True)
            return c['hypothesis']
    with cf.ThreadPoolExecutor(1 if a.ollama else 8) as pool: answers = list(pool.map(one, clips))
    if seconds: print('seconds per clip, median', round(sorted(seconds)[len(seconds)//2], 2))
    groups = defaultdict(lambda: [0, 0, 0, 0, 0])
    for c, ans in zip(clips, answers):
        c['rescored'] = ans
        raw = score(c['reference'], c['hypothesis'], c['profile']); new = score(c['reference'], ans, c['profile'])
        c['rescored_accuracy'] = new
        for key_ in ((c['profile'], c['mode'], 'all'),)+(((c['profile'], c['mode'], 'clean'),) if c['quality'] == 'complete' else ()):
            g = groups[key_]; g[0] += raw['errors']; g[1] += new['errors']; g[2] += raw['reference_units']; g[3] += new['normalized_exact_match']; g[4] += 1
    table = {'/'.join(k): dict(clips=g[4], raw=round(g[0]/g[2], 3), rescored=round(g[1]/g[2], 3), exact=g[3]) for k, g in sorted(groups.items())}
    a.output.write_text(json.dumps(dict(model=a.ollama or a.model, source=str(a.run), glossary=a.glossary, table=table, clips=clips), ensure_ascii=False, indent=1))
    for k, v in table.items(): print(k.ljust(38), v)


if __name__ == '__main__': main()
