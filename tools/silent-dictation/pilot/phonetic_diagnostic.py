#!/usr/bin/env python3
"""Text-derived toneless-Pinyin error/coverage diagnostic, not phonetic ground truth."""
import argparse
from collections import defaultdict
import importlib.metadata
import json
from pathlib import Path
from opencc import OpenCC
from pypinyin import lazy_pinyin
from dataset import load_clips, sha256, write_json
from language_metrics import score


def pinyin(text):
    return lazy_pinyin(''.join(c for c in text if c.isalnum()),errors=lambda s:list(s))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path);p.add_argument('--run',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.output.exists():raise ValueError('Choose a new output path')
    cc=OpenCC('t2s');_,clips=load_clips(a.root)
    d=json.loads(a.run.read_text());groups=defaultdict(list)
    for r in d['clips']:
        if r['language_profile']!='zh':continue
        ref,hyp=cc.convert(r['reference_text']),cc.convert(r['hypothesis'])
        cs=score(ref,hyp,'zh');ps=score(' '.join(pinyin(ref)),' '.join(pinyin(hyp)),'en')
        groups[r['mode']].append(dict(id=r['id'],character_errors=cs['errors'],characters=cs['reference_units'],
                                      pinyin_errors=ps['errors'],syllables=ps['reference_units']))
    summary=[dict(mode=m,clips=len(rs),character_error_rate=sum(r['character_errors'] for r in rs)/sum(r['characters'] for r in rs),
                  toneless_pinyin_error_rate=sum(r['pinyin_errors'] for r in rs)/sum(r['syllables'] for r in rs)) for m,rs in sorted(groups.items())]
    syllables={};bigrams={};families={}
    for split in ['train','validation']:
        texts={c['phrase_family']:cc.convert(c['reference_text']) for c in clips if c['split']==split and c.get('language_profile',c['language'])!='en'}
        families[split]=len(texts);seqs=[pinyin(''.join(c for c in t if '\u3400'<=c<='\u9fff')) for t in texts.values()]
        syllables[split]={s for seq in seqs for s in seq};bigrams[split]={tuple(seq[i:i+2]) for seq in seqs for i in range(len(seq)-1)}
    coverage=dict(chinese_dominant_families=families,training_unique_syllables=len(syllables['train']),
        validation_unique_syllables=len(syllables['validation']),validation_syllables_seen_in_training=len(syllables['validation'] & syllables['train']),
        validation_unique_bigrams=len(bigrams['validation']),validation_bigrams_seen_in_training=len(bigrams['validation'] & bigrams['train']))
    result=dict(scope=__doc__,limitations='Pinyin is inferred from decoded text and references, not predicted directly from video or independently annotated. '
        'Tone is removed and dictionary polyphone choices can be wrong. This does not isolate encoder versus decoder error.',
        source_sha256=sha256(a.run),pypinyin_version=importlib.metadata.version('pypinyin'),summary=summary,coverage=coverage)
    write_json(a.output,result);print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
