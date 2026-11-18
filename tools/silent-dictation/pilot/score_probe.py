#!/usr/bin/env python3
"""Paired research scoring; retain strict scores and disclose post-hoc script normalization."""
import argparse
import copy
import importlib.metadata
import json
from pathlib import Path
from opencc import OpenCC
from dataset import sha256, write_json
from language_metrics import score
from multilingual_probe import summarize


def summaries(rows, converter=None):
    rows = copy.deepcopy(rows)
    for row in rows:
        reference, hypothesis = row['reference_text'], row['hypothesis']
        if converter:
            reference, hypothesis = converter.convert(reference), converter.convert(hypothesis)
        row['accuracy'] = score(reference, hypothesis, row['language_profile'])
    return summarize(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline', type=Path, required=True)
    p.add_argument('--adapted', type=Path)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.output.exists(): raise ValueError('Choose a new output path')
    base = json.loads(a.baseline.read_text())
    datasets = {'baseline': base['clips']}
    if a.adapted:
        adapted = json.loads(a.adapted.read_text())
        if base['checkpoint_sha256'] != adapted['checkpoint_sha256']: raise ValueError('Different base weights')
        if adapted.get('crop_folder', base['crop_folder']) != base['crop_folder']: raise ValueError('Different preprocessing')
        expected = set(adapted.get('development_ids', [r['id'] for r in adapted['clips']]))
        if set(r['id'] for r in adapted['clips']) != expected: raise ValueError('Incomplete adapted holdout')
        if 'development_ids' not in adapted and base.get('split') != adapted.get('split'):
            raise ValueError('Different evaluation splits')
        if 'development_ids' not in adapted and {r['id'] for r in base['clips']} != expected:
            raise ValueError('Different evaluation coverage')
        datasets['baseline'] = [r for r in base['clips'] if r['id'] in expected]
        if len(datasets['baseline']) != len(expected): raise ValueError('Incomplete baseline holdout')
        by_id = {r['id']: r for r in datasets['baseline']}
        for r in adapted['clips']:
            b = by_id[r['id']]
            expected_hash = r.get('source_sha256', adapted.get('source_sha256', {}).get(r['id']))
            if expected_hash and b.get('source_sha256') != expected_hash: raise ValueError('Different source footage')
            for field in ('reference_text', 'mode', 'language_profile'):
                if b[field] != r[field]: raise ValueError('Unmatched comparison')
        datasets['adapted'] = adapted['clips']
    cc = OpenCC('t2s')
    result = dict(
        scope='Descriptive development comparison, NOT independent test accuracy',
        normalization='Strict existing metric AND OpenCC t2s on both reference and hypothesis. '
                      'Script normalization was added after observing baseline traditional output; '
                      'no semantic, acronym, number, or LLM correction.',
        opencc_version=importlib.metadata.version('opencc-python-reimplemented'),
        baseline_sha256=sha256(a.baseline), adapted_sha256=sha256(a.adapted) if a.adapted else None,
        scores={name:dict(strict=summaries(rows),script_normalized=summaries(rows,cc))
                for name,rows in datasets.items()})
    write_json(a.output,result)
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__ == '__main__': main()
