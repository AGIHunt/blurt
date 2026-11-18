#!/usr/bin/env python3
"""Audit downloaded public metadata, without media downloads or model training.

Input: pinned HF API snapshots plus Chinese-LiPS split CSVs. Optional MultiVSR
CSVs are summarized independently; partial downloads are never a full-corpus claim.
No source transcripts, demographic attributes, or participant media are exported.
"""
import argparse
import collections
import csv
import hashlib
import itertools
import json
from pathlib import Path
import re
import unicodedata


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(text):
    return ''.join(c.lower() for c in unicodedata.normalize('NFKC', text) if c.isalnum())


def audit(root):
    result = {'scope': __doc__, 'sources': {}, 'chinese_lips': {}, 'multivsr': {}}
    for path in sorted(root.glob('*-api.json')):
        source = json.loads(path.read_text())
        result['sources'][source['id']] = {
            'revision': source['sha'], 'card_license': source.get('cardData', {}).get('license'),
            'languages': source.get('cardData', {}).get('language'),
        }
    sets = {}
    for split in ('train', 'valid', 'test'):
        path = root / f'meta_{split}.csv'
        rows = list(csv.DictReader(path.open(encoding='utf-8-sig', newline='')))
        ids = [r['ID'] for r in rows]
        speakers = {i.split('_')[0] for i in ids}
        texts = [normalized(r['TEXT']) for r in rows]
        terms = collections.Counter(w.lower() for r in rows for w in re.findall(r'[A-Za-z]+', r['TEXT']))
        sets[split] = {'clip_ids': set(ids), 'speaker_ids': speakers, 'normalized_texts': set(texts)}
        result['chinese_lips'][split] = {
            'file_sha256': digest(path), 'rows': len(rows), 'speaker_id_prefixes': len(speakers),
            'duplicate_clip_ids': len(ids)-len(set(ids)), 'empty_texts': sum(not t for t in texts),
            'duplicate_normalized_text_rows': len(texts)-len(set(texts)),
            'latin_letter_rows': sum(bool(re.search('[A-Za-z]', r['TEXT'])) for r in rows),
            'han_and_latin_rows': sum(bool(re.search('[A-Za-z]', r['TEXT'])) and bool(re.search('[\u3400-\u9fff]', r['TEXT'])) for r in rows),
            'topic_counts': dict(collections.Counter(r['TOPIC'] for r in rows)),
            'top_latin_token_occurrences': terms.most_common(20),
        }
    result['chinese_lips']['split_intersections'] = {
        a+'__'+b: {key: len(sets[a][key] & sets[b][key]) for key in sets[a]}
        for a, b in itertools.combinations(sets, 2)
    }
    for path in sorted(root.glob('multivsr-*.csv')):
        rows = list(csv.DictReader(path.open(encoding='utf-8-sig', newline='')))
        language_counts = collections.Counter(r['language'] for r in rows)
        zh = [r for r in rows if r['language'] == 'zh']
        result['multivsr'][path.name] = {
            'file_sha256': digest(path), 'rows': len(rows), 'language_counts': dict(language_counts),
            'zh_rows': len(zh),
            'zh_latin_letter_rows': sum(bool(re.search('[A-Za-z]', r['transcript'])) for r in zh),
            'zh_source_video_ids': len({r['file_path'].split('/')[0] for r in zh}),
        }
    result['limitations'] = [
        'Metadata inspection only: no audiovisual alignment, speaker identity, or transcript accuracy verified.',
        'Latin letters include acronyms, named entities and single-letter symbols; not a count of verified code-switching.',
        'Chinese-LiPS speaker IDs follow documented ID prefixes; no biometric identity inference.',
        'Exact normalized text overlap is not semantic near-duplicate detection.',
        'Repository license tags do not establish rights to referenced source videos or model weights.',
        'No personal dataset was read; its final test remains untouched.',
    ]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(audit(args.root), ensure_ascii=False, indent=2)+'\n')
    print(args.output)


if __name__ == '__main__':
    main()
