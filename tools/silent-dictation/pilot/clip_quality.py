#!/usr/bin/env python3
"""Audit recorded clips for truncated starts; writes <dataset>/runs/clip-quality-v1.json.

The original recorder added the microphone only after Space, so voiced and whisper takes could
lose the first second or two while the participant was already speaking. Voiced clips are checked
against Whisper; whispered audio defeats ASR, so those use speaking rate. Silent takes never add a
microphone and are not affected by this delay. The audit never edits clips or references.

Usage: clip_quality.py <dataset> [--model mlx-community/whisper-large-v3-mlx]
"""
import argparse, difflib, glob, json, os, re, subprocess, tempfile
from pathlib import Path
import mlx_whisper


def units(text):
    return re.findall(r'[㐀-鿿]|[A-Za-z]+|[0-9]', text.lower())


def syllables(text):
    return sum(1 if re.match(r'[㐀-鿿0-9]', u) else max(1, len(u)//3) for u in units(text))


def tail(reference, heard):
    """Longest reference suffix supported by the heard text; None when nothing aligns."""
    r, h = units(reference), units(heard)
    blocks = [b for b in difflib.SequenceMatcher(None, r, h, autojunk=False).get_matching_blocks() if b.size >= 2]
    matched = sum(b.size for b in blocks)
    return (blocks[0].a if blocks else None), matched/max(len(r), 1), r


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--model', default='mlx-community/whisper-large-v3-mlx')
    a = p.parse_args()
    out = {}
    for f in sorted(glob.glob(str(a.root/'clips/v2-*.json'))):
        c = json.load(open(f)); mode = c['mode']; ref = c['reference_text']
        rate = syllables(ref)/c['duration_seconds']
        row = dict(id=c['id'], mode=mode, split=c['split'], seconds=round(c['duration_seconds'], 2),
                   syllables_per_second=round(rate, 1), reference=ref)
        if mode in ('silent', 'exaggerated_silent'):
            row.update(quality='complete', basis='no microphone in capture path')
        else:
            with tempfile.TemporaryDirectory() as t:
                wav = f'{t}/a.wav'
                subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(a.root/c['video']), '-vn', '-ac', '1', '-ar', '16000', wav], check=True)
                heard = mlx_whisper.transcribe(wav, path_or_hf_repo=a.model, language=c['language'], temperature=0, condition_on_previous_text=False)['text'].strip()
            start, coverage, r = tail(ref, heard)
            row.update(heard=heard, coverage=round(coverage, 2))
            if mode == 'voiced' and coverage >= .75 and start is not None and start <= 1:
                row.update(quality='complete', basis='ASR covers the reference')
            elif mode == 'voiced' and start is not None and coverage >= .3:
                row.update(quality='truncated', basis='ASR covers only a suffix', recovered_units=''.join(
                    (' '+u+' ' if u.isascii() and u.isalpha() else u) for u in r[start:]).strip())
            elif mode == 'whisper' and rate <= 5:
                row.update(quality='complete', basis='speaking rate plausible; whisper ASR unreliable')
            else:
                row.update(quality='truncated', basis='implausible speaking rate or unaligned audio')
        out[c['id']] = row
        print(row['id'].replace('v2-', ''), row['quality'], row.get('recovered_units', ''), flush=True)
    summary = {}
    for r in out.values():
        k = f"{r['split']}/{r['mode']}"; s = summary.setdefault(k, dict(complete=0, truncated=0)); s[r['quality']] += 1
    dest = a.root/'runs/clip-quality-v1.json'
    dest.write_text(json.dumps(dict(summary=summary, clips=out), ensure_ascii=False, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__': main()
