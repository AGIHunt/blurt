"""Benchmark for "Only my voice" (issue #26, docs/design/voiceprint.md) on real speech: the user's own kept dictation
audio as "me", real other speakers (AISHELL-1, ASCEND, LibriSpeech, Common Voice) as "others", mixed with the user's
own room tone and level-matched like a colleague nearby. Every number is measured here; nothing is synthesized.

  uv run --with numpy==2.3.4 --with sherpa-onnx==1.13.8 --with truststore==0.10.5 \\
      --with opencc-python-reimplemented --with mlx-qwen3-asr==0.4.4 --with psutil python tests/bench_voiceprint.py

  --me DIR        the user's takes (default ~/.blurt/dictation/audio; "Keep audio" on in Settings → Dictation)
  --others DIR    folders of other speakers' wavs (default ~/blurt-eval-2026-10-31/data)
  --enroll S      seconds of the user's speech read as the enrollment take (default 20; from the earliest takes)
  --e2e N         pieces per end-to-end case through the real speech model (default 30; 0 = gate only)
  --exclude ID    a take that isn't the user (played audio …); may repeat
  --json PATH     write the results

The takes are split by time: the earliest give the enrollment take, the rest are tested in order, so learning only
ever sees takes before the one being judged. The gate runs as the app runs it: pieces cut like DictationSegmenter cuts
them, Voiceprint.gate per piece, NoteEngine.note for the end-to-end cases (gate off vs on, same piece).
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import random
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REAL_HOME = Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")
HOME = Path(tempfile.mkdtemp(prefix="blurt-vp-bench-"))
os.environ["BLURT_HOME"] = str(HOME)      # before transcribe is imported: a scratch profile, the real models
(HOME / "models").symlink_to(REAL_HOME / "models")
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))

import transcribe as T  # noqa: E402

SR = T.SR


def pieces(x: np.ndarray) -> list[tuple[float, float]]:
    """DictationSegmenter, roughly: a cut in the middle of a ≥ 0.5 s pause once the piece is ≥ 3 s; 20 s at most."""
    segs = T.vad_segments(x)
    if not segs:
        return []
    out, start = [], 0.0
    for a, b in zip(segs, segs[1:]):
        mid = (a[1] + b[0]) / 2
        if b[0] - a[1] >= 0.5 and mid - start >= 3.0:
            out.append((start, mid))
            start = mid
        while mid - start > 20:
            out.append((start, start + 20))
            start += 20
    out.append((start, len(x) / SR))
    return out


def speech(x: np.ndarray) -> float:
    return sum(e - s for s, e in T.vad_segments(x))


def db(x: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt((x ** 2).mean()) + 1e-9))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--me", default=str(REAL_HOME / "dictation" / "audio"))
    ap.add_argument("--others", default=str(Path.home() / "blurt-eval-2026-10-31" / "data"))
    ap.add_argument("--enroll", type=float, default=20.0)
    ap.add_argument("--e2e", type=int, default=30)
    ap.add_argument("--exclude", action="append", default=[])
    ap.add_argument("--threshold", type=float, help="record.dictation.voiceprint_threshold for this run")
    ap.add_argument("--margin", type=float, help="Voiceprint's VP_MARGIN for this run (9: off)")
    ap.add_argument("--pause", type=float, default=0.7, help="the pause around the other speaker in mixed pieces (s)")
    ap.add_argument("--json")
    a = ap.parse_args()
    rng = random.Random(7)
    T.save_json(HOME / "config.json", {"record": {"dictation": {"only_my_voice": True}}})
    takes = sorted(Path(a.me).glob("*.wav"))
    takes = [p for p in takes if p.stem not in a.exclude]
    me = {p.stem: T.read_wav(p) for p in takes}
    # enrollment: the earliest takes' speech, ~a.enroll s, as one wav (a passage read once)
    parts, got, used = [], 0.0, set()
    for k in sorted(me):
        if got >= a.enroll:
            break
        for s, e in T.vad_segments(me[k]):
            e = min(e, s + a.enroll - got)
            if e <= s:
                break
            parts.append(me[k][int(s * SR):int(e * SR)])
            got += e - s
        used.add(k)
    enroll = HOME / "enroll.wav"
    _write(enroll, np.concatenate(parts))
    t0 = time.perf_counter()
    T.Voiceprint.prepare()
    r = T.Voiceprint.enroll(enroll)
    print(f"enrolled from {len(used)} takes, {got:.0f} s of speech: {r.get('ok')} ({(time.perf_counter() - t0) * 1000:.0f} ms)")
    test = [k for k in sorted(me) if k not in used]
    # the user's room tone and level: the others are heard as a colleague nearby, through the same microphone
    tone = np.concatenate([me[k][int(b[1] * SR):int(c[0] * SR)] for k in test[:40]
                           for b, c in zip(T.vad_segments(me[k]), T.vad_segments(me[k])[1:]) if c[0] - b[1] > 0.3])
    level = np.median([db(me[k][int(s * SR):int(e * SR)]) for k in test[:40] for s, e in T.vad_segments(me[k])])
    others = {}
    for f in sorted(Path(a.others).glob("*/*.wav")):
        x = T.read_wav(f)
        x = x * 10 ** ((level - 6 + rng.uniform(-6, 3) - db(x)) / 20)
        off = rng.randrange(0, max(1, len(tone) - len(x)))
        others[f"{f.parent.name}/{f.stem}"] = np.clip(x + np.resize(tone[off:off + len(x)], len(x)), -1, 1).astype(np.float32)
    th = a.threshold if a.threshold is not None else T.voiceprint_settings(None)[1]
    if a.margin is not None:
        T.VP_MARGIN = a.margin
    # learning runs at most once per VP_LEARN_EVERY s of wall time; here the takes go by far faster than they were
    # said, so every sure cut may teach it (the profile keeps the latest VP_LEARNED_MAX either way)
    T.VP_LEARN_EVERY = 0.0

    # ---- the gate alone, piece by piece, in time order (learning as it goes). What counts is what recognition would
    # hear: the speech energy left in the gate's audio (a piece answered blank keeps none), over the speech the VAD
    # found in that speaker's part
    def left(x, y, sp, spans):
        """(speech energy in `spans` of the input, of it left in the gate's output) — none left when nothing matched."""
        e_in = sum(float((x[int(s * SR):int(e * SR)] ** 2).sum()) for s, e in spans)
        e_out = 0.0 if not sp["match"] else sum(float((y[int(s * SR):int(e * SR)] ** 2).sum()) for s, e in spans)
        return e_in, min(e_out, e_in)

    my_in = my_out = 0.0
    hit, my_pieces, ms = 0, [], []
    for k in test:
        x = me[k]
        dropped = False
        for s, e in pieces(x):
            p = x[int(s * SR):int(e * SR)]
            t0 = time.perf_counter()
            sp, y = T.Voiceprint.gate(p, th)
            ms.append(((e - s), (time.perf_counter() - t0) * 1000))
            i, o = left(p, y, sp, T.vad_segments(p))
            my_in += i
            my_out += o
            dropped |= o < 0.98 * i
            my_pieces.append(p)
        hit += dropped
    o_in = o_out = 0.0
    o_whole = 0
    for k, x in others.items():
        sp, y = T.Voiceprint.gate(x, th)
        i, o = left(x, y, sp, T.vad_segments(x))
        o_in += i
        o_out += o
        o_whole += bool(sp["match"])
    mixed, mo_in, mo_out, mm_in, mm_out = [], 0.0, 0.0, 0.0, 0.0
    okeys = list(others)
    for k in test:
        ps = pieces(me[k])
        if len(ps) < 2:
            continue
        A = me[k][int(ps[0][0] * SR):int(ps[0][1] * SR)]
        B = me[k][int(ps[1][0] * SR):int(ps[1][1] * SR)]
        O = others[rng.choice(okeys)]
        n = int(a.pause * SR)
        off = rng.randrange(0, max(1, len(tone) - n))
        gap = np.resize(tone[off:off + n], n).astype(np.float32)        # a pause in the room
        x = np.concatenate([A, gap, O, gap, B])
        o0, o1 = (len(A) + len(gap)) / SR, (len(A) + len(gap) + len(O)) / SR
        sp, y = T.Voiceprint.gate(x, th)
        mine = [(s, e) for s, e in T.vad_segments(A)] + [(s + o1 + a.pause, e + o1 + a.pause) for s, e in T.vad_segments(B)]
        theirs = [(s + o0, e + o0) for s, e in T.vad_segments(O)]
        i, o = left(x, y, sp, theirs)
        mo_in += i
        mo_out += o
        i, o = left(x, y, sp, mine)
        mm_in += i
        mm_out += o
        mixed.append((A, gap, O, B))
    ms_per_s = np.median([m / max(L, 0.1) for L, m in ms])
    res = {"threshold": th, "model": T.VP_FILE, "enroll_s": round(got, 1), "test_takes": len(test),
           "my_speech_dropped": round(1 - my_out / my_in, 4), "my_takes_touched": round(hit / len(test), 4),
           "others_speech_passed": round(o_out / o_in, 4), "others_pieces_typed": round(o_whole / len(others), 4),
           "mixed_others_passed": round(mo_out / mo_in, 4), "mixed_my_dropped": round(1 - mm_out / mm_in, 4),
           "gate_ms_per_audio_s": round(float(ms_per_s), 2),
           "learned": T.Voiceprint.status()["learned"], "others": len(others), "my_pieces": len(my_pieces)}
    print(json.dumps(res, indent=1))

    # ---- end to end: the real speech model, gate off vs on, the same pieces
    if a.e2e:
        eng = T.NoteEngine()
        model = T.dictation_models()["selected"]
        tmp = HOME / "piece.wav"

        def note(x, on):
            _write(tmp, x)
            t0 = time.perf_counter()
            r = eng.note(tmp, purpose="dictation", model_id=model, voiceprint=on)
            return r.get("text", ""), (time.perf_counter() - t0) * 1000
        note(my_pieces[0], False)       # load
        note(my_pieces[0], True)
        same, d_ms, off_ms = 0, [], []
        sample = rng.sample(my_pieces, min(a.e2e, len(my_pieces)))
        for p in sample:
            t_off, m_off = note(p, False)
            t_on, m_on = note(p, True)
            same += t_off == t_on
            d_ms.append(m_on - m_off)
            off_ms.append(m_off)
        o_empty, o_ms_on, o_ms_off = 0, [], []
        for k in rng.sample(okeys, min(a.e2e, len(okeys))):
            t_on, m_on = note(others[k], True)
            _, m_off = note(others[k], False)
            o_empty += not t_on.strip()
            o_ms_on.append(m_on)
            o_ms_off.append(m_off)
        sim_on, sim_off = [], []
        for A, gap, O, B in rng.sample(mixed, min(a.e2e, len(mixed))):
            mine, _ = note(np.concatenate([A, gap, gap, B]), False)
            t_on, _ = note(np.concatenate([A, gap, O, gap, B]), True)
            t_off, _ = note(np.concatenate([A, gap, O, gap, B]), False)
            sim_on.append(difflib.SequenceMatcher(None, mine, t_on).ratio())
            sim_off.append(difflib.SequenceMatcher(None, mine, t_off).ratio())
        e2e = {"asr": model, "my_pieces": len(sample), "my_text_identical": round(same / len(sample), 4),
               "my_added_ms_median": round(float(np.median(d_ms)), 1), "my_added_ms_p95": round(float(np.percentile(d_ms, 95)), 1),
               "my_off_ms_median": round(float(np.median(off_ms)), 1),
               "others_blank": round(o_empty / len(o_ms_on), 4), "others_ms_on_median": round(float(np.median(o_ms_on)), 1),
               "others_ms_off_median": round(float(np.median(o_ms_off)), 1),
               "mixed_match_my_words_on": round(float(np.mean(sim_on)), 3),
               "mixed_match_my_words_off": round(float(np.mean(sim_off)), 3)}
        res["e2e"] = e2e
        print(json.dumps(e2e, indent=1))
    if a.json:
        Path(a.json).write_text(json.dumps(res, indent=1))


def _write(path: Path, x: np.ndarray) -> None:
    import wave
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


if __name__ == "__main__":
    main()
