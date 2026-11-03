# /// script
# requires-python = ">=3.10"
# ///
"""Dictation Lab (测试台; docs/design/dictation.md §Lab): saved dictation takes ("cases") — the audio, what every
stage made of it, the user's ground truth and marks — and the tools to score them, re-run them through other
configurations and run them all again after a change (a regression run). Everything stays on this Mac.

  dictation_lab.py list                               → {"ok", "cases": [summary…]} newest first
  dictation_lab.py show ID                            → {"ok", "case": {...}, "runs": [...]}
  dictation_lab.py add --wav FILE [--reference T] [--corrected T] [--tags a,b] [--note T] [--source import]
                                                      an audio file as a case (converted to 16 kHz mono)
  dictation_lab.py from-history ID [--corrected T] [--note T] [--tags a,b]
                                                      a dictation history entry as a case (its audio and streamed
                                                      pieces when they were kept, else text only: a reference-only
                                                      case); --corrected sets the ground truth
  dictation_lab.py import-feedback DIR [--report ID]  an unpacked feedback report (docs/design/feedback.md: report.json,
                                                      history.jsonl, audio/) as cases: source "feedback", tagged
                                                      feedback, "report <id>" in the note, the sender's device and
                                                      app version; a take already imported is skipped (ID: the
                                                      folder's name unless given)
  dictation_lab.py review [--since ISO] [--last N] [--config SPEC]
                                                      the takes whose audio was kept (record.dictation.keep_audio):
                                                      each heard again in one pass (default mode=whole,polish=off)
                                                      beside what was typed, with flags (fell_back, heard_differently,
                                                      seam_marks, spelled_letters, numeral_format) for a reviewer
  dictation_lab.py delete ID…                         remove cases (their folder: audio, case.json, runs)
  dictation_lab.py score --ref T --hyp T [--terms A,B]   metrics + the diff (CJK by character, Latin by word)
  dictation_lab.py configs                            the ASR / polish models there are, and the presets
  dictation_lab.py rerun ID [--config SPEC]… [--save]    one case through other configurations
  dictation_lab.py run [--config SPEC] [--cases A,B] [--json] [--no-save] [--fail-on-regression]
                                                      every case with audio through the pipeline: before / after
  dictation_lab.py export [--out FILE.zip] [--cases A,B] [--include-context]
                                                      a dataset: manifest.jsonl + audio/<id>.wav (+ dataset.json)
  dictation_lab.py learn --raw R --corrected C        the vocabulary learns from a correction
                                                      (dictation_vocab.learn, when it exists) → the changes made
  dictation_lab.py packs                              the reading scripts (built-in lab_packs/ + $BLURT_HOME/dictation/
                                                      lab/packs/) with how far the user got in each
  dictation_lab.py pack ID                            one pack + its progress (the takes per prompt)
  dictation_lab.py import-pack FILE                   a pack (JSON, schema below) into $BLURT_HOME/dictation/lab/packs/
  dictation_lab.py generate --pack ID [--n 10] [--engine auto|agent|local] [--focus TEXT]
                                                      more prompts in the pack's style: the configured processing
                                                      agent (agents.py), else the local polish model

SPEC: "current" (the app's settings) or comma-separated overrides on it: asr=MODEL_ID, polish=on|off|MODEL_ID,
vocab=on|off, context=on|off, cloud=on|off (polish by the cloud model of record.dictation.cloud_polish, the key from
BLURT_POLISH_API_KEY — docs/design/dictation.md §Cloud polish; off by default; with it macOS's recogniser hears each
window too, its text goes along as "Also heard" and polish runs once over the whole take, as in the app — second=off
leaves it out and polishes window by window), mode=pieces|windows|whole, rehear=on|off (pieces / windows: the pieces heard again in
windows of the model's length — asr_models.json rehear_window_s, 10 s by default — as the app does since v1.0.4;
docs/design/dictation.md §Hearing again; default record.dictation.rehear, on), language=auto|zh|en…, style=verbatim|light|structured|auto (the
dictation styles, docs/design/dictation-styles.md: Structured and Auto run polish.py's structuring pass on Light's
stitched text, as the app does at key-up, then the app category's variant of light from dictation_styles.py), category=chat|code|mail|notes|other (default: the case's app)
e.g. --config asr=qwen3-asr-0.6b-mlx,polish=off   rerun ID --config style=light --config style=structured
Every run checks that light (the default) never typed a list: a row whose output has more numbered lines than its
truth is `listed`, counted in overall.listed, and --fail-on-regression fails on it too.

The pipeline is the app's own entry points: the warm servers of transcribe.py (`note`, purpose dictation, the custom
words, `prior` = the text so far, `before` = the field's text before the cursor with context=on) and polish.py (`polish`: the guard and the repair), started here when they are not
running. "pieces" replays the cuts the take made (each piece transcribed with the text so far as context, joined, the
seam's punctuation dropped after a short pause), then polishes the joined text once; "windows" replays the cuts and
polishes them the way the app does while the user talks (DictationStream's sliding windows, ported in
dictation_stitch.py: the carried clause, the text so far as context, the stitch guard); "whole" transcribes the whole
take. The fit at the cursor is not replayed: compare re-runs with re-runs.

Storage: $BLURT_HOME/dictation/lab/cases/<id>/ {audio.wav, case.json, runs.jsonl}.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
import wave
import zipfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import blurt_home, global_config  # noqa: E402
import dictation_stitch as stitch  # noqa: E402
import dictation_styles as styles  # noqa: E402

HERE = Path(__file__).parent
SCHEMA = 1
SR = 16000
LONG_PAUSE = 1.2            # DictationStitch.longPause: a seam after a shorter pause is not a sentence end
ERROR_TAGS = ["term", "code_switch", "punctuation", "filler", "dropped", "made_up", "segmentation", "clipped", "slow"]


class Fail(Exception):
    def __init__(self, message: str, code: str = "error"):
        super().__init__(message)
        self.code = code


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def lab_dir() -> Path:
    return blurt_home() / "dictation" / "lab"


def cases_dir() -> Path:
    return lab_dir() / "cases"


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def new_id(t: datetime | None = None) -> str:
    t = t or datetime.now()
    return t.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]


# ------------------------------------------------------------------ metrics (BlurtCore/DictationLab.swift: the same)
# Units: each CJK character (and kana / hangul), each Latin word or number (letters and digits; ' inside a word);
# punctuation marks are tokens of their own for the diff, never units. Case and full-width forms are ignored (NFKC,
# lower case). The two implementations are checked against tests/fixtures/lab_metrics.jsonl.

def is_cjk(c: str) -> bool:
    o = ord(c)
    return 0x3040 <= o <= 0x30FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xAC00 <= o <= 0xD7AF \
        or 0xF900 <= o <= 0xFAFF


def _wordy(c: str) -> bool:
    return c.isalnum() and not is_cjk(c)


_PUNCT_END = set("。.!！?？…")
_PUNCT_PAUSE = set("，,、;；:：")


def punct_class(c: str) -> str:
    return "<end>" if c in _PUNCT_END else "<pause>" if c in _PUNCT_PAUSE else c


def tokens(text: str) -> list[dict]:
    """[{"t": text, "k": compare key, "kind": cjk|word|punct, "sp": space before}]"""
    out: list[dict] = []
    word, key, sp, pending_space = "", "", False, False
    for orig in text or "":
        c = unicodedata.normalize("NFKC", orig)          # the key goes by the compatibility form; the text stays
        c1 = c[:1]
        if word and c1 and (_wordy(c1) or c1 in "'’"):
            word, key = word + orig, key + c.lower()
            continue
        if word:
            out.append({"t": word, "k": key, "kind": "word", "sp": sp})
            word = key = ""
        if not c1 or c1.isspace():
            pending_space = pending_space or bool(c1)
            continue
        sp, pending_space = pending_space and bool(out), False
        if is_cjk(c1):
            out.append({"t": orig, "k": c, "kind": "cjk", "sp": sp})
        elif _wordy(c1):
            word, key = orig, c.lower()
        else:
            out.append({"t": orig, "k": punct_class(c1), "kind": "punct", "sp": sp})
    if word:
        out.append({"t": word, "k": key, "kind": "word", "sp": sp})
    return out


def units(text: str) -> list[str]:
    return [t["k"] for t in tokens(text) if t["kind"] != "punct"]


def lev(a: list, b: list) -> int:
    if not a:
        return len(b)
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


def align(a: list[str], b: list[str]) -> list[tuple[str, int, int]]:
    """Minimal edit script: [(op, i, j)] with op equal|sub|del|ins (i into a, j into b). Ties: diagonal, then delete,
    then insert — the Swift one breaks them the same way."""
    n, m = len(a), len(b)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
    ops = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (a[i - 1] != b[j - 1]):
            ops.append(("equal" if a[i - 1] == b[j - 1] else "sub", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", i - 1, -1))
            i -= 1
        else:
            ops.append(("ins", -1, j - 1))
            j -= 1
    return ops[::-1]


def _join(ts: list[dict], first: bool) -> str:
    return "".join((" " if t["sp"] and not (first and k == 0) else "") + t["t"] for k, t in enumerate(ts))


def diff(ref: str, hyp: str) -> list[dict]:
    """Chunks over all tokens (punctuation too): {"op": equal|replace|delete|insert, "ref": text, "hyp": text}.
    Joining every chunk's "hyp" (or "ref") gives the text back, spacing included."""
    rt, ht = tokens(ref), tokens(hyp)
    chunks: list[dict] = []
    for op, i, j in align([t["k"] for t in rt], [t["k"] for t in ht]):
        kind = "equal" if op == "equal" else "change"
        if not chunks or chunks[-1]["_k"] != kind:
            chunks.append({"_k": kind, "r": [], "h": []})
        if i >= 0:
            chunks[-1]["r"].append(i)
        if j >= 0:
            chunks[-1]["h"].append(j)
    out = []
    for c in chunks:
        r, h = c["r"], c["h"]
        op = "equal" if c["_k"] == "equal" else "insert" if not r else "delete" if not h else "replace"
        out.append({"op": op, "ref": _join([rt[i] for i in r], r[:1] == [0]), "hyp": _join([ht[j] for j in h], h[:1] == [0])})
    return out


def find_units(needle: list[str], hay: list[str]) -> int:
    """Where the unit run `needle` starts in `hay` (-1: nowhere). A term is spelled right when its units are there in
    a row: "T mux" is not tmux, "ClaudeCode" is not Claude Code; case doesn't matter."""
    if not needle:
        return -1
    for i in range(len(hay) - len(needle) + 1):
        if hay[i:i + len(needle)] == needle:
            return i
    return -1


def term_hits(terms: list[str], hyp: str) -> tuple[list[str], list[str]]:
    h = units(hyp)
    hit = [t for t in terms if find_units(units(t), h) >= 0]
    return hit, [t for t in terms if t not in hit]


def expected_terms(truth: str, vocab_terms: list[str]) -> list[str]:
    """The custom words the ground truth contains, in order (one inside a longer one found there isn't counted)."""
    k = units(truth)
    found: list[tuple[int, int, str]] = []
    for t in sorted({x for x in vocab_terms if units(x)}, key=lambda x: (-len(units(x)), x)):
        u = units(t)
        for i in range(len(k) - len(u) + 1):
            if k[i:i + len(u)] == u and not any(s <= i and i + len(u) <= e for s, e, _ in found):
                found.append((i, i + len(u), t))
                break
    return [t for _, _, t in sorted(found)]


def round4(x: float) -> float:
    """Half up (Swift's .rounded()), not Python's half to even: 5/32 is 0.1563 in both."""
    import math
    return math.floor(x * 10000 + 0.5) / 10000


def score(ref: str, hyp: str, terms: list[str] | None = None) -> dict:
    """wer: edit distance over units (a CJK character counts as a word) / reference units; cer: over the characters
    of the units; punct: punctuation marks in changed chunks / the reference's marks; terms: the expected custom words
    the output has. None when there is no reference."""
    ru, hu = units(ref), units(hyp)
    if not ru:
        return {"wer": None, "cer": None, "punct": None, "exact": None, "ref_units": 0, "hyp_units": len(hu),
                "terms": None}
    rc, hc = list("".join(ru)), list("".join(hu))
    rt, ht = tokens(ref), tokens(hyp)
    ops = align([t["k"] for t in rt], [t["k"] for t in ht])
    p_err = sum(1 for op, i, j in ops if op != "equal" and ((i >= 0 and rt[i]["kind"] == "punct") or (j >= 0 and ht[j]["kind"] == "punct")))
    p_ref = sum(1 for t in rt if t["kind"] == "punct")
    out = {"wer": round4(lev(ru, hu) / len(ru)), "cer": round4(lev(rc, hc) / max(1, len(rc))),
           "punct": round4(min(1.0, p_err / max(1, p_ref))), "exact": ru == hu, "ref_units": len(ru), "hyp_units": len(hu),
           "terms": None}
    if terms:
        hit, miss = term_hits(terms, hyp)
        out["terms"] = {"expected": len(terms), "hit": len(hit), "missed": miss, "accuracy": round4(len(hit) / len(terms))}
    return out


# ------------------------------------------------------------------ cases
def case_path(cid: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", cid or "") or cid.startswith("."):
        raise Fail(f"bad case id {cid!r}", "usage")
    return cases_dir() / cid


def blank_case(cid: str, source: str) -> dict:
    """case.json, schema 1 (docs/design/dictation.md §Lab)."""
    t = now_iso()
    return {"schema": SCHEMA, "id": cid, "created": t, "updated": t, "source": source, "audio": None, "duration": None,
            "reference": None, "corrected": None, "scenario": {}, "errors": [], "rating": {"stars": None, "good": None},
            "note": "", "app": {"bundle": None}, "context": {"included": False}, "config": {}, "take": None,
            "expected_terms": [], "metrics": None, "learned": [], "app_version": None, "history_id": None,
            "prompt": None}


def validate(c: dict) -> list[str]:
    """What is wrong with a case.json (empty: fine). Unknown keys are allowed (newer apps may add some)."""
    errs = []
    if c.get("schema") != SCHEMA:
        errs.append("schema")
    for k, typ in (("id", str), ("created", str), ("source", str), ("errors", list), ("scenario", dict),
                   ("rating", dict), ("context", dict), ("config", dict), ("app", dict)):
        if not isinstance(c.get(k), typ):
            errs.append(k)
    for k in ("reference", "corrected", "audio", "note"):
        if c.get(k) is not None and not isinstance(c.get(k), str):
            errs.append(k)
    if isinstance(c.get("errors"), list) and any(e not in ERROR_TAGS for e in c["errors"]):
        errs.append("errors: unknown tag")
    stars = (c.get("rating") or {}).get("stars")
    if stars is not None and (not isinstance(stars, int) or not 1 <= stars <= 5):
        errs.append("rating.stars")
    ctx = c.get("context") or {}
    if not ctx.get("included") and any(ctx.get(k) for k in ("before", "after", "selection", "title")):
        errs.append("context: text kept without consent")
    if c.get("take") is not None and not isinstance(c.get("take"), dict):
        errs.append("take")
    if c.get("prompt") is not None and not (isinstance(c["prompt"], dict) and c["prompt"].get("pack") and c["prompt"].get("id")):
        errs.append("prompt")
    return errs


def truth(c: dict) -> str | None:
    """What the user meant: the corrected text, else the reference."""
    for k in ("corrected", "reference"):
        v = (c.get(k) or "").strip()
        if v:
            return v
    return None


def load_case(cid: str) -> dict:
    p = case_path(cid) / "case.json"
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Fail(f"no case {cid}", "not_found") from None


def save_case(c: dict) -> Path:
    d = case_path(c["id"])
    d.mkdir(parents=True, exist_ok=True)
    c["updated"] = now_iso()
    tmp = d / "case.json.tmp"
    tmp.write_text(json.dumps(c, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, d / "case.json")
    return d


def all_cases() -> list[dict]:
    out = []
    for p in sorted(cases_dir().glob("*/case.json")):
        try:
            out.append(json.loads(p.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            continue
    return sorted(out, key=lambda c: str(c.get("created") or ""), reverse=True)


def audio_of(c: dict) -> Path | None:
    if not c.get("audio"):
        return None
    p = case_path(c["id"]) / c["audio"]
    return p if p.exists() else None


def runs_of(cid: str) -> list[dict]:
    try:
        lines = (case_path(cid) / "runs.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for ln in lines:
        try:
            out.append(json.loads(ln))
        except ValueError:
            pass
    return out


def add_run(cid: str, run: dict) -> None:
    with open(case_path(cid) / "runs.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(run, ensure_ascii=False) + "\n")


def summary(c: dict) -> dict:
    m = c.get("metrics") or {}
    take = c.get("take") or {}
    return {"id": c.get("id"), "created": c.get("created"), "source": c.get("source"), "audio": bool(c.get("audio")),
            "duration": c.get("duration"), "truth": truth(c), "text": take.get("text") or take.get("fitted"),
            "errors": c.get("errors") or [], "rating": c.get("rating") or {}, "wer": m.get("wer"),
            "scenario": c.get("scenario") or {}}


def vocab_terms() -> list[str]:
    try:
        import dictation_vocab
        return [t["term"] for t in dictation_vocab.load()]
    except Exception:  # noqa: BLE001
        return []


def refresh_metrics(c: dict) -> dict:
    """The take's metrics against the case's truth (and the expected custom words)."""
    t = truth(c)
    if t and not c.get("expected_terms"):
        c["expected_terms"] = expected_terms(t, vocab_terms())
    hyp = (c.get("take") or {}).get("fitted") or (c.get("take") or {}).get("text")
    c["metrics"] = score(t, hyp, c.get("expected_terms")) if t and hyp is not None else None
    return c


# ------------------------------------------------------------------ audio
def read_samples(p: Path) -> list[int]:
    with wave.open(str(p)) as w:
        if w.getframerate() != SR or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise Fail(f"{p.name} is not 16 kHz mono 16-bit", "audio")
        import array
        a = array.array("h")
        a.frombytes(w.readframes(w.getnframes()))
        return list(a)


def write_samples(p: Path, x: list[int]) -> None:
    import array
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(array.array("h", x).tobytes())


def to_16k_mono(src: Path, dst: Path) -> float:
    """Any audio file → dst (16 kHz mono 16-bit): copied when it already is, else afconvert (macOS) or ffmpeg."""
    try:
        with wave.open(str(src)) as w:
            if w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2:
                shutil.copyfile(src, dst)
                return round(w.getnframes() / SR, 2)
    except (wave.Error, EOFError, OSError):
        pass
    if shutil.which("afconvert"):
        r = subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1", str(src), str(dst)], capture_output=True)
    else:
        r = subprocess.run([shutil.which("ffmpeg") or "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(src),
                            "-ac", "1", "-ar", str(SR), "-sample_fmt", "s16", str(dst)], capture_output=True)
    if r.returncode != 0 or not dst.exists():
        raise Fail(f"could not convert {src.name}", "audio")
    with wave.open(str(dst)) as w:
        return round(w.getnframes() / w.getframerate(), 2)


# ------------------------------------------------------------------ configurations
def settings() -> dict:
    d = (global_config().get("record") or {}).get("dictation") or {}
    return d if isinstance(d, dict) else {}


def parse_spec(spec: str | dict | None) -> dict:
    """SPEC → {"label", "asr", "polish" (bool), "polish_model", "vocab", "context", "mode", "language"}; None values
    mean "as the app is set" (resolved by the servers: dictation's model, the selected polish model)."""
    if isinstance(spec, dict):
        raw = dict(spec)
        label = raw.pop("label", None)
    else:
        spec = (spec or "current").strip()
        if spec.startswith("{"):
            raw = json.loads(spec)
            label = raw.pop("label", None)
        else:
            raw, label = {}, None
            for part in spec.split(","):
                part = part.strip()
                if not part or part == "current":
                    continue
                k, _, v = part.partition("=")
                raw[k.strip()] = v.strip()
    s = settings()
    cfg = {"asr": None, "polish": s.get("polish", "light") != "off", "polish_model": None, "vocab": True,
           "context": s.get("context", True) is not False, "mode": "pieces", "language": None, "style": None,
           "category": None, "rehear": s.get("rehear", True) is not False,
           # "current" polishes as the app does: in the cloud when it is on and the key came along (--key-stdin)
           "cloud": bool((s.get("cloud_polish") or {}).get("on")) and bool(os.environ.get("BLURT_POLISH_API_KEY")),
           # cloud polish gets macOS's transcript of the same audio as "Also heard" (the app: wherever macOS's
           # recogniser runs, docs/design/dictation.md §Second transcript); second=off replays it without
           "second": True}
    onoff = lambda v: v if isinstance(v, bool) else str(v).lower() in ("on", "1", "true", "yes")  # noqa: E731
    for k, v in raw.items():
        if k in ("asr", "asr_model"):
            cfg["asr"] = v or None
        elif k == "polish":
            if isinstance(v, bool) or str(v).lower() in ("on", "off", "true", "false", "1", "0", "yes", "no"):
                cfg["polish"] = onoff(v)
            else:
                cfg["polish"], cfg["polish_model"] = True, v
        elif k == "polish_model":
            cfg["polish_model"] = v or None
        elif k in ("vocab", "context", "rehear", "cloud"):
            cfg[k] = onoff(v)
        elif k == "second":
            cfg["second"] = str(v).lower() in ("apple", "on", "1", "true", "yes") if not isinstance(v, bool) else v
        elif k == "mode":
            if v not in ("pieces", "windows", "whole"):
                raise Fail(f"mode must be pieces, windows or whole, not {v}", "usage")
            cfg["mode"] = v
        elif k == "language":
            cfg["language"] = None if v in ("", "auto", None) else v
        elif k == "style":
            if v not in styles.STYLES:
                raise Fail(f"style must be one of {', '.join(styles.STYLES)}, not {v}", "usage")
            cfg["style"] = v
        elif k in ("category", "app"):
            if v not in styles.CATEGORIES:
                raise Fail(f"category must be one of {', '.join(styles.CATEGORIES)}, not {v}", "usage")
            cfg["category"] = v
        else:
            raise Fail(f"unknown config key {k!r}", "usage")
    cfg["key"] = config_key(cfg)
    cfg["label"] = label or (spec if isinstance(spec, str) and not spec.startswith("{") else cfg["key"])
    return cfg


def config_key(cfg: dict) -> str:
    """The same configuration always gets the same key (runs are compared by it)."""
    parts = [f"asr={cfg.get('asr') or 'current'}",
             "polish=" + ("off" if not cfg.get("polish") else cfg.get("polish_model") or "current"),
             f"vocab={'on' if cfg.get('vocab') else 'off'}", f"context={'on' if cfg.get('context') else 'off'}",
             f"mode={cfg.get('mode') or 'pieces'}"]
    if cfg.get("language"):
        parts.append(f"language={cfg['language']}")
    if cfg.get("cloud") and cfg.get("polish"):
        # with macOS's transcript as a second opinion (runs from before it keep "cloud=on": they had none)
        parts.append("cloud=on" + (",second=apple" if cfg.get("second", True) else ""))
    # only when on: the runs from before hearing again keep their keys
    if cfg.get("rehear") and (cfg.get("mode") or "pieces") != "whole":
        parts.append("rehear=on")
    # a style only when one was asked for: runs from before the styles keep their keys (light = the default)
    if cfg.get("style") and cfg["style"] != "light":
        parts.append(f"style={cfg['style']}")
    if cfg.get("category"):
        parts.append(f"category={cfg['category']}")
    return ",".join(parts)


def _script_json(script: str, args: list[str], timeout: float = 120) -> dict:
    uv = shutil.which("uv") or str(blurt_home() / "bin" / "uv")
    try:
        r = subprocess.run([uv, "run", "-q", str(HERE / script), *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    for ln in reversed(r.stdout.splitlines()):
        try:
            o = json.loads(ln)
            if isinstance(o, dict):
                return o
        except ValueError:
            continue
    return {}


def cmd_configs(_a) -> None:
    asr = _script_json("transcribe.py", ["dictation-models"])
    pol = _script_json("polish.py", ["models"])
    presets = [
        {"label": "current", "spec": "current"},
        {"label": "polish off", "spec": "polish=off"},
        {"label": "no custom words", "spec": "vocab=off"},
        {"label": "no context", "spec": "context=off"},
        {"label": "whole take", "spec": "mode=whole"},
    ]
    # cloud polish set up (record.dictation.cloud_polish): the two side by side — this Mac's model and the cloud's
    if (settings().get("cloud_polish") or {}).get("on") and os.environ.get("BLURT_POLISH_API_KEY"):
        presets[1:1] = [{"label": "cloud polish", "spec": "cloud=on"}, {"label": "local polish", "spec": "cloud=off"}]
    emit({"ok": True, "asr": {"selected": asr.get("selected"), "models": [m for m in asr.get("models") or [] if m.get("installed")]},
          "polish": {"selected": pol.get("selected"), "models": [m for m in pol.get("models") or [] if m.get("installed")]},
          "presets": presets})


# ------------------------------------------------------------------ the pipeline (the warm servers)
class Servers:
    """transcribe.py serve / polish.py serve, as the app talks to them ($BLURT_HOME/run/<name>.json: port + token);
    started here (offline first, like the app's WarmSpawn) when they aren't running."""

    def __init__(self, wait: float = 90):
        self.wait = wait
        self.started: dict[str, subprocess.Popen] = {}

    @staticmethod
    def call(name: str, req: dict, timeout: float) -> dict | None:
        try:
            info = json.loads((blurt_home() / "run" / f"{name}.json").read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(info, dict) or not info.get("port"):
            return None
        try:
            with socket.create_connection(("127.0.0.1", int(info["port"])), timeout=0.5) as s:
                s.settimeout(timeout)
                s.sendall((json.dumps({**req, "token": info.get("token")}, ensure_ascii=False) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
            return json.loads(buf) if buf else None
        except (OSError, ValueError):
            return None

    def ensure(self, name: str, script: str, args: list[str]) -> bool:
        if (r := self.call(name, {"cmd": "ping"}, 3)) and r.get("ok"):
            return True
        uv = shutil.which("uv") or str(blurt_home() / "bin" / "uv")
        for offline in (True, False):
            env = {**os.environ, **({"UV_OFFLINE": "1"} if offline else {})}
            p = subprocess.Popen([uv, "run", "-q", str(HERE / script), *args], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
            self.started[name] = p
            until = time.time() + self.wait
            while time.time() < until:
                if (r := self.call(name, {"cmd": "ping"}, 3)) and r.get("ok"):
                    return True
                if p.poll() is not None:
                    break
                time.sleep(0.3)
        return False

    def asr(self, wav: Path, model: str | None, vocab: bool, prior: str, language: str | None, hint: str = "",
            before: str = "") -> dict:
        """The app's request: the file's words (the server ranks them as it ranks the app's payload — the same terms
        in the same order), the text so far, and the window title / text around the cursor when the case kept them
        (`before`: the field's text before the cursor, which a model that takes it hears as context)."""
        if not self.ensure("asr-serve", "transcribe.py", ["serve", "--purpose", "dictation", "--idle", "300", "--exit-after", "900"]):
            raise Fail("the speech model server did not start", "asr_unavailable")
        req = {"cmd": "note", "wav": str(wav), "language": language or "auto", "purpose": "dictation",
               "vocab": True if vocab else []}
        if model:
            req["model_id"] = model
        if prior:
            req["prior"] = prior
        if hint:
            req["hint"] = hint
        if before:
            req["before"] = before
        r = self.call("asr-serve", req, 180)
        for _ in range(2):
            # a fresh server re-runs itself under `uv run --with <the backend's package>` on its first request: that
            # request gets no answer, the server comes back on a new port
            if r is not None:
                break
            time.sleep(1)
            if self.ensure("asr-serve", "transcribe.py", ["serve", "--purpose", "dictation", "--idle", "300", "--exit-after", "900"]):
                r = self.call("asr-serve", req, 180)
        if not r or not r.get("ok"):
            raise Fail((r or {}).get("error") or "speech model failed", (r or {}).get("code") or "asr_failed")
        return r

    cloud: dict | None = None      # run_case sets it for cloud=on (cloud_settings)

    @staticmethod
    def second(wav: Path, language: str | None) -> str:
        """macOS's recogniser on the same audio (the Blurt executable's `--speech`, as transcribe.py's apple backend
        runs it), with the custom words: what the app sends cloud polish as "Also heard" (DictationStream: the
        second transcript). "" where it can't run (before macOS 26, no Blurt app, a language it doesn't speak)."""
        try:
            import transcribe as T  # noqa: PLC0415 — numpy: only for this
            import dictation_vocab  # noqa: PLC0415
        except Exception:  # noqa: BLE001
            return ""
        loc = T.apple_locale(language)
        if not T.apple_speech_ok() or not loc:
            return ""
        words = [t["term"] for t in dictation_vocab.load() if t.get("term")][:100]
        cmd = [str(T.apple_speech_helper()), "--speech", str(wav), "--locale", loc]
        if words:
            cmd += ["--words", "\n".join(words)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            line = next((ln for ln in reversed(r.stdout.splitlines()) if ln.startswith("{")), "{}")
            d = json.loads(line)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return ""
        return (d.get("text") or "").strip() if d.get("ok") else ""

    def structure(self, text: str, model: str | None, vocab: bool, timeout: float | None = None) -> dict:
        """polish.py serve's structuring pass (Structured, Auto), as the app calls it at key-up."""
        if not self.ensure("polish-serve", "polish.py", ["serve", "--idle", "300", "--exit-after", "900"]):
            return {"ok": True, "text": text, "fell_back": True, "reason": "unavailable"}
        req = {"cmd": "structure", "text": text, "vocab": None if vocab else []}
        if self.cloud:
            req["cloud"] = self.cloud
        if timeout:
            req["timeout"] = timeout
        if model:
            req["model"] = model
        r = self.call("polish-serve", req, (timeout or 10) + 120)
        if not r or not r.get("ok"):
            return {"ok": True, "text": text, "fell_back": True, "reason": (r or {}).get("code") or "timeout"}
        return r

    def polish(self, text: str, model: str | None, vocab: bool, context: dict | None, timeout: float,
               variant: str | None = None) -> dict:
        if not self.ensure("polish-serve", "polish.py", ["serve", "--idle", "300", "--exit-after", "900"]):
            return {"ok": True, "text": text, "fell_back": True, "reason": "unavailable"}
        req = {"cmd": "polish", "text": text, "timeout": timeout, "vocab": None if vocab else [], "context": context}
        if self.cloud:
            req["cloud"] = self.cloud
        if variant:
            req["variant"] = variant
        if model:
            req["model"] = model
        r = self.call("polish-serve", req, timeout + 120)
        if r is None:
            time.sleep(1)
            if self.ensure("polish-serve", "polish.py", ["serve", "--idle", "300", "--exit-after", "900"]):
                r = self.call("polish-serve", req, timeout + 120)
        if not r:
            return {"ok": True, "text": text, "fell_back": True, "reason": "timeout"}
        if not r.get("ok"):
            return {"ok": True, "text": text, "fell_back": True, "reason": r.get("code") or "error", "error": r.get("error")}
        return r

    def guard(self, raw: str, output: str, fallback: str | None, vocab: bool, context: dict | None) -> dict | None:
        """polish.py serve's stitch guard (the joined pieces against the joined transcript), as the app calls it."""
        req = {"cmd": "guard", "raw": raw, "output": output, "vocab": self.vocab_terms() if vocab else [], "cloud": bool(self.cloud),
               "context": context}
        if fallback is not None:
            req["fallback"] = fallback
        r = self.call("polish-serve", req, 10)
        return r if r and r.get("ok") else None

    @staticmethod
    def vocab_terms() -> list[dict]:
        try:
            import dictation_vocab  # noqa: PLC0415
            return dictation_vocab.load()
        except Exception:  # noqa: BLE001
            return []


_SEAM_TRAIL = re.compile(r"[。.!！?？，,、]+$")
_LATIN_END = re.compile(r"[A-Za-z0-9]$")
_LATIN_START = re.compile(r"^[A-Za-z0-9]")


def join_text(a: str, b: str) -> str:
    """DictationStitch.join: a space only between Latin words."""
    a, b = a.strip(), b.strip()
    if not a or not b:
        return a or b
    return a + (" " if _LATIN_END.search(a) and _LATIN_START.search(b) else "") + b


def join_pieces(texts: list[str], pauses: list[float | None]) -> str:
    """The pieces joined; a piece's trailing 。，. after a pause shorter than LONG_PAUSE goes (a breath, not a sentence
    end) — the simple form of the app's seam rule."""
    out = ""
    for i, t in enumerate(texts):
        t = (t or "").strip()
        if i < len(texts) - 1:
            g = pauses[i] if i < len(pauses) else None
            if g is None or g < LONG_PAUSE:
                t = _SEAM_TRAIL.sub("", t)
        out = join_text(out, t)
    return out


def context_payload(c: dict) -> dict | None:
    ctx = c.get("context") or {}
    if not ctx.get("included"):
        return None
    p = {k: ctx[k] for k in ("before", "after", "selection", "title", "app") if ctx.get(k)}
    return p or None


def asr_hint(ctx: dict | None) -> str:
    """The speech request's hint, as the app builds it (DictationContext.hint): the title and 300 characters each side
    of the cursor — only which custom words appear in it is used."""
    if not ctx:
        return ""
    parts = [ctx.get("title") or "", (ctx.get("before") or "")[-300:], ctx.get("selection") or "",
             (ctx.get("after") or "")[:300]]
    return "\n".join(p for p in parts if p)


FIELD_CHARS = 300


def asr_before(ctx: dict | None) -> str:
    """The field's text before the cursor as the app sends it to the speech model (DictationContext.asrBefore: the last
    FIELD_CHARS characters); the server uses it only for a model that takes it (asr_models.json field_context_chars)."""
    return ((ctx or {}).get("before") or "")[-FIELD_CHARS:].strip()


def tag_summary(tags: list[dict]) -> dict:
    """The pieces' language tags → the closest call: its margin to the threshold and whether it is fragile (a tag
    that close could flip with a slightly different take — the v0.9 translated sentence sat 0.0006 over the line: +0.1
    in log-odds, dictation_vocab.tag_margin)."""
    import dictation_vocab  # noqa: PLC0415
    margins = [t["margin"] for t in tags if isinstance(t, dict) and isinstance(t.get("margin"), (int, float))]
    if not margins:
        return {"tag_margin": None, "fragile_tag": False}
    m = min(margins, key=abs)
    return {"tag_margin": m, "fragile_tag": abs(m) < dictation_vocab.FRAGILE_MARGIN}


def cloud_settings() -> dict:
    """The cloud model the app is set to (record.dictation.cloud_polish), the key from BLURT_POLISH_API_KEY (the app
    keeps its own in the Keychain)."""
    c = dict(settings().get("cloud_polish") or {})
    key = os.environ.get("BLURT_POLISH_API_KEY") or ""
    if not key:
        raise Fail("cloud=on needs BLURT_POLISH_API_KEY", "usage")
    return {"provider": os.environ.get("BLURT_POLISH_PROVIDER") or c.get("provider") or "deepseek",
            "base_url": os.environ.get("BLURT_POLISH_BASE_URL") or c.get("base_url") or "",
            "model": os.environ.get("BLURT_POLISH_MODEL") or c.get("model") or "",
            "protocol": c.get("protocol") or "", "key": key}


def run_case(c: dict, cfg: dict, backend, wav: Path | None = None) -> dict:
    """One case through one configuration → {"outputs", "metrics", "config"}. `backend` has .asr / .polish (Servers,
    or a fake in tests). `wav`: the recording when it isn't the case's own (a history take under review)."""
    wav = wav or audio_of(c)
    if not wav:
        raise Fail(f"case {c.get('id')} has no audio", "no_audio")
    if hasattr(backend, "cloud"):
        backend.cloud = cloud_settings() if cfg.get("cloud") and cfg.get("polish") else None
    x = read_samples(wav)
    segs = (c.get("take") or {}).get("segments") or []
    cuts = []
    if cfg.get("mode", "pieces") in ("pieces", "windows") and len(segs) > 1:
        for s in segs:
            a, b = int(float(s.get("start", 0)) * SR), int(float(s.get("end", 0)) * SR)
            if b > a:
                cuts.append((max(0, a), min(len(x), b), s.get("pause_after"), bool(s.get("hard"))))
    if not cuts:
        cuts = [(0, len(x), None, False)]
    t0 = time.perf_counter()
    pieces, asr_ms, load_ms = [], 0, 0
    model = language = None
    terms: list[str] = []
    hint = asr_hint(context_payload(c)) if cfg.get("context") else ""
    before = asr_before(context_payload(c)) if cfg.get("context") else ""
    extra = {**({"hint": hint} if hint else {}), **({"before": before} if before else {})}
    with tempfile.TemporaryDirectory(prefix="blurt-lab-") as td:
        for i, (a, b, pause, hard) in enumerate(cuts):
            p = Path(td) / f"p{i}.wav"
            write_samples(p, x[a:b])
            prior = join_pieces([q["raw"] for q in pieces], [q["pause_after"] for q in pieces])[-200:] if pieces else ""
            t1 = time.perf_counter()
            r = backend.asr(p, cfg.get("asr"), bool(cfg.get("vocab")), prior, cfg.get("language"),
                            **extra)
            ms = int((time.perf_counter() - t1) * 1000)
            asr_ms += ms
            load_ms += int(r.get("load_ms") or 0)
            model = model or r.get("model")
            language = language or r.get("language")
            terms += [t for t in r.get("terms") or [] if t not in terms]
            pieces.append({"index": i, "start": round(a / SR, 2), "end": round(b / SR, 2), "pause_after": pause,
                           "hard": hard, "a": a, "b": b,
                           "raw": (r.get("text") or "").strip(), "asr_text": (r.get("asr_text") or r.get("text") or "").strip(),
                           "asr_ms": ms, "tag": r.get("tag")})
        # hearing again (DictationStream: the pieces once more in windows of the model's length, the windows' text so far
        # as context);
        # polish then works window by window, as in the app
        windows: list[dict] = []
        if cfg.get("rehear") and len(pieces) > 1:
            # the window of the model that heard the pieces (asr_models.json rehear_window_s), as the app picks it
            window = stitch.rehear_window(cfg.get("asr") or model, settings().get("rehear_window_s"))
            for g in stitch.rehear_groups(pieces, window):
                ms_ = [pieces[i] for i in g]
                said = join_pieces([q["raw"] for q in ms_], [q["pause_after"] for q in ms_])
                said_heard = join_pieces([q["asr_text"] for q in ms_], [q["pause_after"] for q in ms_])
                w = {"pieces": g, "start": ms_[0]["start"], "end": ms_[-1]["end"], "pause_after": ms_[-1]["pause_after"],
                     "pieces_text": said, "raw": said, "asr_text": said_heard, "asr_ms": 0, "tag": ms_[0].get("tag")}
                if len(g) > 1:
                    p = Path(td) / f"w{len(windows)}.wav"
                    write_samples(p, x[ms_[0]["a"]:ms_[-1]["b"]])
                    prior = join_pieces([q["raw"] for q in windows], [q["pause_after"] for q in windows])[-200:]
                    t1 = time.perf_counter()
                    try:
                        r = backend.asr(p, cfg.get("asr"), bool(cfg.get("vocab")), prior, cfg.get("language"),
                                        **extra)
                        if (r.get("text") or "").strip():
                            w.update(raw=r["text"].strip(), asr_text=(r.get("asr_text") or r["text"]).strip(), tag=r.get("tag"))
                    except Fail:
                        pass        # the pieces' own transcripts, as the app keeps them
                    w["asr_ms"] = int((time.perf_counter() - t1) * 1000)
                    asr_ms += w["asr_ms"]
                windows.append(w)
        # cloud polish's second opinion (the app: DictationStream's second transcript): macOS's recogniser on each
        # window's audio (each piece's without hearing again); on a take sent whole (a cloud recogniser at key-up), on
        # the take's own pieces, joined — they were the live text while talking
        seconds: list[str] = []
        want_second = bool(cfg.get("cloud") and cfg.get("polish") and cfg.get("second", True)
                           and hasattr(backend, "second"))
        if want_second:
            spans = [(ms_[0]["a"], ms_[-1]["b"]) for ms_ in ([pieces[i] for i in w["pieces"]] for w in windows)] if windows \
                else [(q["a"], q["b"]) for q in pieces]
            if cfg.get("mode") == "whole" and len(segs) > 1:
                spans = [(int(float(g_.get("start", 0)) * SR), int(float(g_.get("end", 0)) * SR)) for g_ in segs]
            for k, (a, b) in enumerate(spans):
                p = Path(td) / f"s{k}.wav"
                write_samples(p, x[max(0, a):min(len(x), b)])
                seconds.append(backend.second(p, cfg.get("language")))
            if cfg.get("mode") == "whole" and len(spans) > 1:
                seconds = [join_pieces(seconds, [g_.get("pause_after") for g_ in segs])]
    for q in pieces:
        q.pop("a", None); q.pop("b", None)
    units = windows or pieces
    if want_second and len(seconds) == len(units):
        for q, sec in zip(units, seconds):
            q["second"] = sec
    raw = join_pieces([q["raw"] for q in units], [q["pause_after"] for q in units])
    heard = join_pieces([q["asr_text"] for q in units], [q["pause_after"] for q in units])
    tags = [q["tag"] for q in units if q.get("tag")]
    out = {"segments": pieces, "raw": raw, "asr_text": heard, "polished": None, "text": raw, "fell_back": False,
           "second": join_pieces([q.get("second") or "" for q in units], [q["pause_after"] for q in units]) or None,
           "reason": None, "repaired": [], "terms_applied": terms, "asr_model": model, "polish_model": None,
           "language": language, "tags": tags, **tag_summary(tags)}
    if windows:
        out["rehear"] = windows
    # what is left at key-up of the speech model's work: the last piece, or the open window heard again
    last_asr_ms = units[-1]["asr_ms"] if units and units[-1]["asr_ms"] else pieces[-1]["asr_ms"]
    polish_ms = structure_ms = 0
    style = cfg.get("style") or "light"
    cat = cfg.get("category") or styles.category((c.get("app") or {}).get("bundle"))
    ctx = context_payload(c) if cfg.get("context") else None
    timeout = max(0.5, float(settings().get("polish_timeout_ms") or 3000) / 1000)
    # the app's polish variant: chat keeps tone words; a terminal keeps a command a command
    extra = {"variant": "chat"} if cat == "chat" else \
        {"variant": "terminal"} if styles.is_terminal((c.get("app") or {}).get("bundle")) else {}
    answers: list[dict] = []
    structured: dict | None = None
    can_structure = hasattr(backend, "structure")

    def one(text: str, wctx: dict | None) -> dict:
        r = backend.polish(text, cfg.get("polish_model"), bool(cfg.get("vocab")), wctx, timeout, **extra)
        answers.append(r)
        return r

    def structure(text: str) -> dict:
        # Structured / Auto: the polish model's structuring pass over the whole take (polish.py `structure`)
        nonlocal structure_ms
        t1 = time.perf_counter()
        r = backend.structure(text, cfg.get("polish_model"), bool(cfg.get("vocab")))
        structure_ms = int((time.perf_counter() - t1) * 1000)
        return r
    # cloud polish with the second transcript runs once over the whole take at key-up, as in the app
    # (DictationStream.polishAtKeyUp): window by window it made the founder's takes worse (docs/design/dictation.md
    # §Second transcript)
    at_keyup = want_second and any(seconds)
    if cfg.get("polish") and raw.strip() and style != "verbatim" and cfg.get("mode") == "windows" and not at_keyup and \
            (len(units) > 1 or (style == "structured" and can_structure)):
        t1 = time.perf_counter()
        guard = getattr(backend, "guard", None)
        w = stitch.stream([{"raw": q["raw"]} for q in units], [q["pause_after"] for q in units], one,
                          (lambda r_, o_, f_: guard(r_, o_, f_, bool(cfg.get("vocab")), ctx)) if guard else None, ctx,
                          structure=structure if style == "structured" and can_structure else None)
        polish_ms = int((time.perf_counter() - t1) * 1000) - structure_ms
        structured = w.get("structured")
        load_ms += sum(int(a.get("load_ms") or 0) for a in answers)
        for q, wp in zip(units, w["pieces"]):
            q.update(polish_in=wp["polish_in"], text=wp["text"], fell_back=wp["fell_back"], reason=wp["reason"],
                     polish_ms=wp["ms"], echo=wp.get("echo"))
        out.update(text=w["text"] or raw, light=w.get("light"), fell_back=w["fell_back"], reason=w["reason"],
                   stitch=w["stitch"], polished=stitch.join_all([a.get("polished") or "" for a in answers]),
                   repaired=[x for a in answers for x in a.get("repaired") or []],
                   polish_model=next((a.get("model") for a in answers if a.get("model")), None),
                   windows_fell_back=sum(1 for wp in w["pieces"] if wp["fell_back"]),
                   windows=sum(1 for wp in w["pieces"] if wp["polish_in"]),
                   last_polish_ms=next((wp["ms"] for wp in reversed(w["pieces"]) if wp["polish_in"]), 0))
        out["terms_applied"] += [t for a in answers for t in a.get("terms") or [] if t not in out["terms_applied"]]
    elif cfg.get("polish") and raw.strip() and style != "verbatim":
        t1 = time.perf_counter()
        sec = join_pieces([q.get("second") or "" for q in units], [q["pause_after"] for q in units])
        r = one(raw, {**(ctx or {}), "second": sec} if sec else ctx)
        polish_ms = int((time.perf_counter() - t1) * 1000)
        load_ms += int(r.get("load_ms") or 0)
        out.update(polished=r.get("polished"), text=(r.get("text") or raw), fell_back=bool(r.get("fell_back")),
                   reason=r.get("reason") if r.get("fell_back") else None, repaired=r.get("repaired") or [],
                   polish_model=r.get("model"), context_used=bool(r.get("context")), last_polish_ms=polish_ms)
        out["terms_applied"] += [t for t in r.get("terms") or [] if t not in out["terms_applied"]]
    if style in ("structured", "auto") and structured is None and can_structure and (out["text"] or "").strip():
        # Auto (and a take that wasn't streamed): Light's text, then the structuring pass on it
        s_ = structure(out["text"])
        structured = {**s_, "input": out["text"]}
    if structured is not None:
        out["structured"] = {k: structured.get(k) for k in ("text", "structured", "list", "fell_back", "reason", "ms",
                                                              "input")}
    # the style: the structured text (Structured; Auto only when it is a list) and the app category's variant of light
    t2 = time.perf_counter()
    light_text = out.get("light") or out["text"]
    s_text = structured.get("text") if structured and not structured.get("fell_back") else None
    st = styles.apply_style(light_text if s_text is not None else out["text"], style, cat, s_text)
    out.update(text=st["text"], style={"style": style, "category": cat, "rendered": st["rendered"], "variant": st["variant"]})
    out["timings"] = {"asr_ms": asr_ms, "polish_ms": polish_ms, "structure_ms": structure_ms, "load_ms": load_ms,
                      "style_ms": int((time.perf_counter() - t2) * 1000),
                      "last_polish_ms": out.get("last_polish_ms", 0), "last_asr_ms": last_asr_ms,
                      "windows": len(windows),
                      "after_keyup_ms": out.get("last_polish_ms", 0) + structure_ms,
                      "total_ms": int((time.perf_counter() - t0) * 1000), "segments": len(pieces)}
    t = truth(c)
    # light never makes a list (the check the styles promise): more numbered lines than the truth has
    out["listed"] = style in ("light", "verbatim") and styles.list_lines(out["text"]) > styles.list_lines(t or "")
    exp = c.get("expected_terms") or (expected_terms(t, vocab_terms()) if t else [])
    return {"config": {k: v for k, v in cfg.items()}, "outputs": out,
            "metrics": score(t, out["text"], exp) if t else None}


def compare(before: dict | None, after: dict | None) -> str:
    """better | worse | same | new | n/a — by the word error rate, then term accuracy."""
    if not after or after.get("wer") is None:
        return "n/a"
    if not before or before.get("wer") is None:
        return "new"
    d = after["wer"] - before["wer"]
    if abs(d) > 0.005:
        return "better" if d < 0 else "worse"
    ta, tb = (after.get("terms") or {}).get("accuracy"), (before.get("terms") or {}).get("accuracy")
    if ta is not None and tb is not None and abs(ta - tb) > 0.005:
        return "better" if ta > tb else "worse"
    return "same"


def overall(rows: list[dict]) -> dict:
    scored = [r for r in rows if (r.get("after") or {}).get("wer") is not None]
    wers = [r["after"]["wer"] for r in scored]
    cers = [r["after"]["cer"] for r in scored]
    exp = sum(((r["after"].get("terms") or {}).get("expected") or 0) for r in scored)
    hit = sum(((r["after"].get("terms") or {}).get("hit") or 0) for r in scored)
    mean = round(sum(wers) / len(wers), 4) if wers else None
    count = lambda s: sum(1 for r in rows if r.get("change") == s)  # noqa: E731
    return {"cases": len(rows), "scored": len(scored), "wer": mean,
            "cer": round(sum(cers) / len(cers), 4) if cers else None,
            "term_accuracy": round(hit / exp, 4) if exp else None,
            "score": round(max(0.0, 100 * (1 - mean)), 1) if mean is not None else None,
            "better": count("better"), "worse": count("worse"), "same": count("same"), "new": count("new"),
            "errors": count("error"), "fell_back": sum(1 for r in rows if r.get("fell_back")),
            "listed": sum(1 for r in rows if r.get("listed")),
            "fragile_tags": sum(1 for r in rows if r.get("fragile_tag"))}


def regression(cfg: dict, backend, ids: list[str] | None = None, save: bool = True, progress=None) -> dict:
    """Every case with audio through `cfg`; each row's "before" is the case's last run with the same configuration."""
    rows = []
    cases = [c for c in all_cases() if c.get("audio") and (not ids or c.get("id") in ids)]
    for n, c in enumerate(cases):
        prev = next((r for r in reversed(runs_of(c["id"])) if r.get("key") == cfg["key"]), None)
        row = {"id": c["id"], "truth": truth(c), "before": (prev or {}).get("metrics"),
               "before_text": ((prev or {}).get("outputs") or {}).get("text"), "before_at": (prev or {}).get("at")}
        try:
            r = run_case(c, cfg, backend)
            row.update(after=r["metrics"], text=r["outputs"]["text"], raw=r["outputs"]["raw"],
                       fell_back=r["outputs"]["fell_back"], reason=r["outputs"]["reason"],
                       timings=r["outputs"]["timings"], change=compare(row["before"], r["metrics"]),
                       listed=r["outputs"].get("listed", False), style=r["outputs"].get("style"),
                       language=r["outputs"].get("language"), tag_margin=r["outputs"].get("tag_margin"),
                       fragile_tag=r["outputs"].get("fragile_tag", False))
            if r["outputs"].get("structured"):
                st = r["outputs"]["structured"]
                row["structured"] = {k: st.get(k) for k in ("list", "fell_back", "reason", "ms")}
            row["changed_text"] = row["before_text"] is not None and row["before_text"] != row["text"]
            if save:
                add_run(c["id"], {"at": now_iso(), "key": cfg["key"], "label": cfg.get("label"), **r})
        except Fail as e:
            row.update(after=None, change="error", error=str(e), code=e.code)
        row["tags"] = case_tags(c)
        rows.append(row)
        if progress:
            progress(n + 1, len(cases), row)
    return {"ok": True, "config": cfg, "rows": rows, "overall": overall(rows), "by_tag": by_tag(rows), "at": now_iso()}


def case_tags(c: dict) -> list[str]:
    """The dimensions a case can be sliced by: its own tags ("feedback"), its script prompt's tags ("length:short",
    "feature:numbers" …), the pack, and its scenario."""
    out = [t for t in c.get("tags") or [] if isinstance(t, str) and t]
    p = c.get("prompt") or {}
    if p.get("pack"):
        out.append(f"pack:{p['pack']}")
    for k, v in (p.get("tags") or {}).items():
        for x in v if isinstance(v, list) else [v]:
            if x:
                out.append(f"{'feature' if k == 'features' else k}:{x}")
    for k, v in (c.get("scenario") or {}).items():
        if v:
            out.append(f"scenario.{k}:{v}")
    return out


def by_tag(rows: list[dict]) -> dict:
    """{tag: {"cases", "wer", "worse"}} over the rows that were scored."""
    acc: dict[str, list[dict]] = {}
    for r in rows:
        for t in r.get("tags") or []:
            acc.setdefault(t, []).append(r)
    out = {}
    for t, rs in sorted(acc.items()):
        w = [r["after"]["wer"] for r in rs if (r.get("after") or {}).get("wer") is not None]
        out[t] = {"cases": len(rs), "wer": round4(sum(w) / len(w)) if w else None,
                  "worse": sum(1 for r in rs if r.get("change") == "worse")}
    return out


# ------------------------------------------------------------------ reading scripts (packs)
# A pack: {"schema": 1, "id", "name", "name_zh"?, "description"?, "source": builtin|typeless-history|blurt-history|
# generated|…, "created", "prompts": [{"id", "read": what to say aloud, "expected": what the dictation should type
# (default: read — fillers and the corrected-away words left out), "tags": {"length": short|medium|long|xlong,
# "scenario": chat|coding|email|notes|meeting, "languages": zh|zh-terms|en, "features": [names, numbers, correction,
# fillers, enumeration, question, run_on]}, "origin": seed|variant|generated, "note"?}]}.
# Built-in packs: lab_packs/*.json next to this script; the user's: $BLURT_HOME/dictation/lab/packs/*.json (a user
# pack with a built-in's id wins). A case recorded from a prompt carries {"prompt": {"pack", "id", "tags"}}.
PACK_TAGS = {"length": ["short", "medium", "long", "xlong"], "scenario": ["chat", "coding", "email", "notes", "meeting"],
             "languages": ["zh", "zh-terms", "en"],
             "features": ["names", "numbers", "correction", "fillers", "enumeration", "question", "run_on"]}


def packs_dir() -> Path:
    return lab_dir() / "packs"


def builtin_packs_dir() -> Path:
    return HERE / "lab_packs"


def validate_pack(p: dict) -> list[str]:
    errs = []
    if not isinstance(p, dict) or p.get("schema") != SCHEMA:
        return ["schema"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", str(p.get("id") or "")):
        errs.append("id")
    if not isinstance(p.get("name"), str) or not p["name"].strip():
        errs.append("name")
    prompts = p.get("prompts")
    if not isinstance(prompts, list) or not prompts:
        return errs + ["prompts"]
    seen = set()
    for i, q in enumerate(prompts):
        if not isinstance(q, dict) or not str(q.get("read") or "").strip():
            errs.append(f"prompts[{i}].read")
            continue
        if not q.get("id") or q["id"] in seen:
            errs.append(f"prompts[{i}].id")
        seen.add(q.get("id"))
        for k, v in (q.get("tags") or {}).items():
            allowed = PACK_TAGS.get(k)
            vals = v if isinstance(v, list) else [v]
            if allowed is None or any(x not in allowed for x in vals):
                errs.append(f"prompts[{i}].tags.{k}")
    return errs


def read_pack(path: Path) -> dict | None:
    try:
        p = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return p if not validate_pack(p) else None


def all_packs() -> dict[str, tuple[dict, Path, bool]]:
    out: dict[str, tuple[dict, Path, bool]] = {}
    for d, builtin in ((builtin_packs_dir(), True), (packs_dir(), False)):
        for f in sorted(d.glob("*.json")):
            if (p := read_pack(f)) is not None:
                out[p["id"]] = (p, f, builtin)
    return out


def load_pack(pid: str) -> dict:
    hit = all_packs().get(pid)
    if not hit:
        raise Fail(f"no pack {pid}", "not_found")
    return hit[0]


def save_pack(p: dict) -> Path:
    errs = validate_pack(p)
    if errs:
        raise Fail("not a reading pack: " + ", ".join(errs[:5]), "bad_pack")
    packs_dir().mkdir(parents=True, exist_ok=True)
    out = packs_dir() / f"{p['id']}.json"
    tmp = out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(p, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, out)
    return out


def pack_progress(p: dict, cases: list[dict] | None = None) -> dict:
    """prompt id → its takes (case ids, newest first, with the take's WER)."""
    takes: dict[str, list[dict]] = {}
    for c in cases if cases is not None else all_cases():
        q = c.get("prompt") or {}
        if q.get("pack") == p["id"] and q.get("id"):
            takes.setdefault(q["id"], []).append({"case": c["id"], "wer": (c.get("metrics") or {}).get("wer")})
    done = sum(1 for q in p["prompts"] if takes.get(q["id"]))
    return {"done": done, "total": len(p["prompts"]), "takes": takes}


def cmd_packs(_a) -> None:
    cases = all_cases()
    rows = []
    for pid, (p, path, builtin) in all_packs().items():
        pr = pack_progress(p, cases)
        rows.append({"id": pid, "name": p["name"], "name_zh": p.get("name_zh"), "source": p.get("source"),
                     "description": p.get("description"), "prompts": len(p["prompts"]), "done": pr["done"],
                     "path": str(path), "builtin": builtin})
    emit({"ok": True, "packs": rows, "dir": str(packs_dir())})


def cmd_pack(a) -> None:
    p = load_pack(a.id)
    emit({"ok": True, "pack": p, "progress": pack_progress(p)})


def cmd_import_pack(a) -> None:
    src = Path(a.file).expanduser()
    try:
        p = json.loads(src.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Fail(f"{src.name} is not JSON", "bad_pack") from None
    out = save_pack(p)
    emit({"ok": True, "id": p["id"], "path": str(out), "prompts": len(p["prompts"])})


GEN_PROMPT = """You write reading scripts for testing a dictation (speech-to-text) app. The user reads each script
aloud; the app must type what they meant. Write {n} NEW scripts in the same voice as the examples below (the user's
own style: {lang_hint}), varied across these dimensions, and tag each one:
- length: short (a few words) | medium (one or two sentences) | long (~20 s) | xlong (~60 s, a run-on with pauses)
- scenario: chat | coding | email | notes | meeting
- languages: zh | zh-terms (Chinese with English names / terms) | en
- features (any of): names (AI products, people), numbers (dates, money, versions), correction (a spoken
  self-correction like 「把这个，不对，这两个拿过去」), fillers (嗯, 那个, um), enumeration (一二三 / 首先其次 said as
  prose — it must NOT become a list), question, run_on
For a script with fillers or a self-correction, "read" is what is said and "expected" is what should be typed (fillers
and the corrected-away words gone); otherwise leave "expected" out. Spoken text only: no Markdown, no lists, no emoji.
Answer with a JSON array only, each item {{"read": "...", "expected": "...", "tags": {{"length": "...",
"scenario": "...", "languages": "...", "features": [...]}}}}.
{focus}
Examples:
{examples}
"""


def parse_generated(text: str) -> list[dict]:
    """The JSON array a model answered with (code fences and chatter around it ignored), cleaned: items without a
    "read" dropped, tags outside the known values dropped."""
    m = re.search(r"\[.*\]", text or "", re.S)
    if not m:
        return []
    try:
        items = json.loads(m.group(0))
    except ValueError:
        return []
    out = []
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict) or not str(it.get("read") or "").strip():
            continue
        tags = {}
        for k, allowed in PACK_TAGS.items():
            v = (it.get("tags") or {}).get(k)
            if k == "features":
                vals = [x for x in (v if isinstance(v, list) else [v]) if x in allowed]
                if vals:
                    tags[k] = vals
            elif v in allowed:
                tags[k] = v
        q = {"read": str(it["read"]).strip(), "tags": tags, "origin": "generated"}
        exp = str(it.get("expected") or "").strip()
        if exp and exp != q["read"]:
            q["expected"] = exp
        out.append(q)
    return out


def add_prompts(p: dict, new: list[dict]) -> int:
    """Appends the new prompts (not already in the pack) with fresh ids → how many went in."""
    have = {q["read"] for q in p["prompts"]}
    n = 0
    base = len(p["prompts"])
    for q in new:
        if q["read"] in have:
            continue
        have.add(q["read"])
        n += 1
        p["prompts"].append({"id": f"g{base + n:03d}-{uuid.uuid4().hex[:4]}", **q})
    return n


def _generate_with_agent(prompt: str) -> str | None:
    """The configured processing agent (agents.py: the first one that works), headless, its whole output."""
    try:
        import agents  # noqa: PLC0415
        det = agents.detect(login=True, version=False)
        pick = det.get("pick")
        if not pick:
            return None
        with tempfile.TemporaryDirectory(prefix="blurt-lab-gen-") as td:
            spec = agents.command(pick, "headless", prompt, td, events=False, mcp=False, processing_run=True)
            env = {**agents.clean_env(), **(spec.get("env") or {})}
            r = subprocess.run(spec["argv"], cwd=spec.get("cwd") or td, env=env, capture_output=True, text=True, timeout=600)
            # a CLI that reports JSON (its usage) carries the answer as a string inside it
            for ln in reversed(r.stdout.splitlines()):
                try:
                    o = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(o, dict) and isinstance(o.get("result"), str):
                    return o["result"]
            return r.stdout
    except Exception:  # noqa: BLE001 — no agent: the local model
        return None


def _generate_with_polish_model(prompt: str) -> str | None:
    """The local polish model (MLX), loaded here for one generation."""
    import polish  # noqa: PLC0415 — its public helpers: the selected model and where it is
    mid = polish.selected()
    m = polish.entry(mid) if mid else None
    path = polish.model_path(m) if m else None
    if not path:
        return None
    polish.ensure_mlx()          # re-runs this command under `uv run --with mlx-lm` when needed
    from mlx_lm import generate, load  # noqa: PLC0415
    model, tok = load(str(path))
    msgs = [{"role": "user", "content": prompt}]
    try:
        text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    except TypeError:
        text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    return generate(model, tok, text, max_tokens=3000)


def generate(p: dict, n: int, engine: str = "auto", focus: str = "", runner=None) -> dict:
    """n more prompts for the pack, in the style of its own: the configured processing agent, else the local polish
    model (engine auto | agent | local; `runner` stands in for both in tests)."""
    import random
    seeds = random.Random(len(p["prompts"])).sample(p["prompts"], min(12, len(p["prompts"])))
    zh = sum(1 for q in p["prompts"] if re.search(r"[一-鿿]", q["read"])) > len(p["prompts"]) / 2
    prompt = GEN_PROMPT.format(n=n, lang_hint="mostly Chinese, with English product names and dev terms" if zh else "English",
                               focus=f"Focus on: {focus}" if focus else "",
                               examples="\n".join(json.dumps({k: q[k] for k in ("read", "expected", "tags") if k in q},
                                                             ensure_ascii=False) for q in seeds))
    used = None
    text = None
    if runner:
        text, used = runner(prompt), "test"
    else:
        if engine in ("auto", "agent"):
            text, used = _generate_with_agent(prompt), "agent"
        if not parse_generated(text or "") and engine in ("auto", "local"):
            text, used = _generate_with_polish_model(prompt), "local"
    new = parse_generated(text or "")
    if not new:
        raise Fail("the model wrote no usable scripts", "generate_failed")
    added = add_prompts(p, new[:n])
    p["updated"] = now_iso()
    return {"added": added, "engine": used}


def cmd_generate(a) -> None:
    p = load_pack(a.pack)
    r = generate(p, a.n, a.engine, a.focus or "")
    out = save_pack(p)
    emit({"ok": True, "pack": p["id"], "path": str(out), **r, "prompts": len(p["prompts"])})


# ------------------------------------------------------------------ commands
def cmd_list(_a) -> None:
    emit({"ok": True, "dir": str(cases_dir()), "cases": [summary(c) for c in all_cases()]})


def cmd_show(a) -> None:
    emit({"ok": True, "case": load_case(a.id), "runs": runs_of(a.id)})


def cmd_add(a) -> None:
    src = Path(a.wav).expanduser()
    if not src.exists():
        raise Fail(f"{src} not found", "not_found")
    c = blank_case(a.id or new_id(), a.source)
    d = case_path(c["id"])
    if d.exists():
        raise Fail(f"case {c['id']} exists", "exists")
    d.mkdir(parents=True)
    try:
        c["duration"] = to_16k_mono(src, d / "audio.wav")
    except Fail:
        shutil.rmtree(d, ignore_errors=True)
        raise
    c["audio"] = "audio.wav"
    c["reference"], c["corrected"], c["note"] = a.reference, a.corrected, a.note or ""
    c["errors"] = [t for t in (a.tags or "").split(",") if t in ERROR_TAGS]
    c["app_version"] = a.app_version
    refresh_metrics(c)
    save_case(c)
    emit({"ok": True, "case": c})


def history_entry(hid: str) -> dict | None:
    try:
        import dictation  # noqa: PLC0415 — the history's own reader (edit lines applied)
        return next((e for e in dictation.load(blurt_home() / "dictation" / "history.jsonl") if e.get("id") == hid), None)
    except Exception:  # noqa: BLE001
        return None


def case_from_history(e: dict, cid: str) -> tuple[dict, Path | None]:
    """A history entry as a case (not saved) and its kept recording (None: the audio is gone)."""
    c = blank_case(cid, "history")
    c["history_id"] = e.get("id")
    wav = blurt_home() / "dictation" / (e.get("audio") or "")
    has_audio = bool(e.get("audio")) and wav.is_file()
    c["duration"] = e.get("duration")
    c["app"] = {"bundle": e.get("bundle")}
    c["config"] = {"asr_model": e.get("asr_model"), "polish": e.get("polished") is not None or bool(e.get("fell_back")),
                   "polish_model": e.get("model"), "language": e.get("language")}
    # the streamed pieces (kept with the audio since v1.0.2): the windows replay cuts the take where the app did
    segs = [{"index": i, **{k: p.get(k) for k in ("start", "end", "pause_after", "asr_text", "raw", "polish_in", "text",
                                                    "polished", "fell_back", "reason")}}
            for i, p in enumerate(e.get("pieces") or [])]
    c["take"] = {"segments": segs, "raw": e.get("raw") or "", "asr_text": e.get("raw") or "", "polished": e.get("polished"),
                 "text": e.get("text") or "", "fitted": e.get("text") or "", "fit": e.get("fitted") or [],
                 "terms_applied": e.get("terms_applied") or [], "fell_back": bool(e.get("fell_back")),
                 "reason": e.get("reason"), "repaired": e.get("repaired") or [],
                 "timings": {k: e[k] for k in ("asr_ms", "polish_ms", "load_ms", "total_ms", "segments") if k in e},
                 "language": e.get("language"), "asr_model": e.get("asr_model"), "polish_model": e.get("model"),
                 "tags": e.get("asr_tags") or [], **tag_summary(e.get("asr_tags") or [])}
    c["reference"] = e.get("corrected") or e.get("text") or None    # a starting point for the ground truth
    return c, wav if has_audio else None


def cmd_from_history(a) -> None:
    e = history_entry(a.id)
    if not e:
        raise Fail(f"no dictation {a.id}", "not_found")
    existing = next((c for c in all_cases() if c.get("history_id") == a.id), None)
    if existing:
        return emit({"ok": True, "case": existing, "existed": True})
    c, wav = case_from_history(e, new_id())
    d = case_path(c["id"])
    d.mkdir(parents=True)
    if wav:
        c["duration"] = to_16k_mono(wav, d / "audio.wav")
        c["audio"] = "audio.wav"
    if a.corrected:
        c["corrected"] = a.corrected
    if a.note:
        c["note"] = a.note
    if a.tags:
        c["errors"] = [t for t in a.tags.split(",") if t]
    c["app_version"] = a.app_version
    refresh_metrics(c)
    save_case(c)
    emit({"ok": True, "case": c})


def _context_from_debug(s: str) -> dict:
    """A history line's "context" (DictationContext.debugText: "title — before|[selection]after") back into its parts,
    as near as the one string allows; the string itself is kept as `text`."""
    title, sep, rest = s.partition(" — ")
    if not sep:
        title, rest = "", s
    before, _, after = rest.partition("|")
    selection = ""
    if after.startswith("[") and "]" in after:
        selection, _, after = after[1:].partition("]")
    return {"title": title, "before": before, "selection": selection, "after": after, "text": s}


def _feedback_audio(d: Path, rel) -> Path | None:
    """A take's recording inside the report folder (the name comes from the report: nothing outside it)."""
    if not isinstance(rel, str) or not rel:
        return None
    base = d.resolve()
    p = (base / rel).resolve()
    return p if p.is_relative_to(base) and p.is_file() else None


def import_feedback(d: Path, rid: str | None = None) -> dict:
    """An unpacked feedback report → Lab cases, one per take; a take already imported from this report is skipped."""
    import dictation  # noqa: PLC0415 — the history's own reader (edit lines applied)
    try:
        report = json.loads((d / "report.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Fail(f"no report.json in {d}", "not_found") from None
    if not isinstance(report, dict) or not isinstance(report.get("takes"), list):
        raise Fail("report.json has no takes", "bad_report")
    rid = rid or d.name
    by_id = {e["id"]: e for e in dictation.load(d / "history.jsonl")}
    done = {((c.get("feedback") or {}).get("report"), c.get("history_id")) for c in all_cases() if c.get("source") == "feedback"}
    app = report.get("app") or {}
    version = "+".join(str(app[k]) for k in ("version", "build") if app.get(k) not in (None, "", "unknown")) or None  # "1.0.3+42", as the app writes it
    imported, skipped = [], []
    for t in report["takes"]:
        hid = (t or {}).get("id")
        e = by_id.get(hid)
        if not e:
            skipped.append({"id": hid, "why": "not_in_history"})
            continue
        if (rid, hid) in done:
            skipped.append({"id": hid, "why": "imported"})
            continue
        cid = new_id()
        while case_path(cid).exists():
            cid = new_id()
        c, _ = case_from_history(e, cid)
        c["source"], c["tags"], c["note"] = "feedback", ["feedback"], f"report {rid}"
        c["device"], c["app_version"] = report.get("device") or {}, version
        c["feedback"] = {"report": rid, "platform": report.get("platform"), "created": report.get("created"),
                         "context_included": bool(report.get("context_included")), "models": report.get("models")}
        if report.get("context_included") and isinstance(e.get("context"), str) and e["context"]:
            c["context"] = {"included": True, **_context_from_debug(e["context"])}
        cd = case_path(cid)
        cd.mkdir(parents=True)
        wav = _feedback_audio(d, t.get("audio"))
        if wav:
            try:
                c["duration"] = to_16k_mono(wav, cd / "audio.wav")
                c["audio"] = "audio.wav"
            except Fail:
                pass                                            # a recording that won't convert: text only
        refresh_metrics(c)
        save_case(c)
        imported.append({"case": cid, "history_id": hid, "audio": bool(c["audio"])})
    return {"report": rid, "imported": imported, "skipped": skipped}


def cmd_import_feedback(a) -> None:
    d = Path(a.dir).expanduser()
    if not d.is_dir():
        raise Fail(f"{d} is not a folder", "not_found")
    emit({"ok": True, **import_feedback(d, a.report)})


_SPELLED = re.compile(r"(?<![A-Za-z])[A-Za-z](?: [A-Za-z])+(?![A-Za-z])")
_CN_NUM_LATIN = re.compile(r"[零〇一二两三四五六七八九十]+ ?[A-Za-z]|[A-Za-z] ?[零〇一二两三四五六七八九十]+")
_MARKS = "，。？！、；：,.?!;:"


def review_take(e: dict, be, cfg: dict) -> dict:
    """One kept take for review: what was typed beside the whole take heard again in one pass (no cuts, no prior —
    the seams can't shape it), and what looks off. A reviewer (the user, or an agent reading this) decides."""
    c, wav = case_from_history(e, "review-" + str(e.get("id")))
    r = run_case(c, cfg, be, wav=wav)
    heard_once = r["outputs"]["raw"]
    typed = e.get("corrected") or e.get("text") or ""
    flags = []
    if e.get("fell_back"):
        flags.append(f"fell_back:{e.get('reason')}")
    words = [d for d in diff(heard_once, e.get("raw") or "") if d["op"] != "equal" and re.search(r"\w", d["ref"] + d["hyp"])]
    if words:
        flags.append("heard_differently")
    seams = [p for p in e.get("pieces") or [] if p.get("pause_after")]
    # a mark typed at a seam that the one-pass transcript doesn't have there: the pause may have put it in
    count = lambda t: sum(ch in _MARKS for ch in t)  # noqa: E731
    marks = [d for d in diff(heard_once, typed) if d["op"] != "equal" and count(d["hyp"]) > count(d["ref"])]
    if marks and seams:
        flags.append("seam_marks")
    if _SPELLED.search(typed):
        flags.append("spelled_letters")
    if _CN_NUM_LATIN.search(typed):
        flags.append("numeral_format")
    return {"id": e.get("id"), "t": e.get("t"), "app": e.get("app"), "duration": e.get("duration"),
            "audio": str(wav) if wav else None, "typed": typed, "raw": e.get("raw"), "polished": e.get("polished"),
            "heard_once": heard_once, "asr_model": r["outputs"].get("asr_model"), "flags": flags,
            "heard_diff": [{"once": d["ref"], "streamed": d["hyp"]} for d in words],
            "pieces": [{k: p.get(k) for k in ("raw", "pause_after", "polish_in", "text")} for p in e.get("pieces") or []]}


def cmd_review(a) -> None:
    """The kept takes since --since (or the last --last ones) for review; takes without audio are counted, not shown."""
    import dictation  # noqa: PLC0415
    entries = [e for e in dictation.load(blurt_home() / "dictation" / "history.jsonl") if e.get("raw")]
    entries.sort(key=lambda e: e.get("t") or "")
    if a.since:
        entries = [e for e in entries if (e.get("t") or "") >= a.since]
    if a.last:
        entries = entries[-a.last:]
    kept = [e for e in entries if e.get("audio") and (blurt_home() / "dictation" / e["audio"]).is_file()]
    cfg = parse_spec(a.config or "mode=whole,polish=off,vocab=on")
    be = Servers()
    out = []
    for n, e in enumerate(kept, 1):
        try:
            out.append(review_take(e, be, cfg))
        except Fail as x:
            out.append({"id": e.get("id"), "t": e.get("t"), "error": str(x), "code": x.code})
        print(json.dumps({"event": "review_progress", "n": n, "total": len(kept)}), file=sys.stderr, flush=True)
    flagged = [t for t in out if t.get("flags")]
    emit({"ok": True, "takes": out, "flagged": len(flagged), "no_audio": len(entries) - len(kept), "config": cfg["key"]})


def cmd_delete(a) -> None:
    gone = []
    for cid in a.ids:
        d = case_path(cid)
        if d.is_dir():
            shutil.rmtree(d)
            gone.append(cid)
    emit({"ok": True, "deleted": gone})


def cmd_score(a) -> None:
    terms = [t.strip() for t in (a.terms or "").split(",") if t.strip()]
    emit({"ok": True, **score(a.ref, a.hyp, terms or None), "diff": diff(a.ref, a.hyp)})


def cmd_rerun(a) -> None:
    c = load_case(a.id)
    be = Servers()
    results = []
    for spec in a.config or ["current"]:
        cfg = parse_spec(spec)
        try:
            r = run_case(c, cfg, be)
            if a.save:
                add_run(c["id"], {"at": now_iso(), "key": cfg["key"], "label": cfg.get("label"), **r})
            t = truth(c)
            results.append({"label": cfg["label"], "key": cfg["key"], **r, "diff": diff(t, r["outputs"]["text"]) if t else None})
        except Fail as e:
            results.append({"label": cfg["label"], "key": cfg["key"], "error": str(e), "code": e.code})
    emit({"ok": True, "id": c["id"], "results": results})


def _fmt(v, pct=True) -> str:
    return "—" if v is None else f"{v * 100:.1f}%" if pct else str(v)


def cmd_run(a) -> None:
    cfg = parse_spec(a.config)
    ids = [x for x in (a.cases or "").split(",") if x] or None

    def progress(n, total, row):
        if not a.json:
            print(f"[{n}/{total}] {row['id']}  {row.get('change')}", file=sys.stderr, flush=True)
        else:
            print(json.dumps({"event": "lab_progress", "n": n, "total": total, "id": row["id"]}), file=sys.stderr, flush=True)

    res = regression(cfg, Servers(), ids, save=not a.no_save, progress=progress)
    if a.json:
        emit(res)
    else:
        print(f"config: {cfg['key']}")
        print(f"{'case':<24} {'before WER':>10} {'after WER':>10} {'terms':>7} {'lang':>5} {'tag ±':>7}  change")
        for r in res["rows"]:
            b, af = r.get("before") or {}, r.get("after") or {}
            ta = (af.get("terms") or {}).get("accuracy")
            m = r.get("tag_margin")
            print(f"{r['id']:<24} {_fmt(b.get('wer')):>10} {_fmt(af.get('wer')):>10} {_fmt(ta):>7} "
                  f"{r.get('language') or '—':>5} {'—' if m is None else f'{m:+.2f}':>7}  "
                  f"{r.get('change')}{' (text changed)' if r.get('changed_text') else ''}"
                  f"{'  fragile language tag' if r.get('fragile_tag') else ''}{'  ' + r['error'] if r.get('error') else ''}")
        o = res["overall"]
        print(f"overall: score {_fmt(o['score'], False)}  WER {_fmt(o['wer'])}  CER {_fmt(o['cer'])}  terms "
              f"{_fmt(o['term_accuracy'])}  better {o['better']}  worse {o['worse']}  same {o['same']}  new {o['new']}"
              f"  errors {o['errors']}  fell back {o['fell_back']}  light made a list {o['listed']}"
              f"  fragile language tags {o['fragile_tags']}")
        if res.get("by_tag"):
            print("by tag:")
            for t, v in res["by_tag"].items():
                print(f"  {t:<28} {v['cases']:>3} cases  WER {_fmt(v['wer'])}{'  worse ' + str(v['worse']) if v['worse'] else ''}")
    if a.fail_on_regression and (res["overall"]["worse"] or res["overall"]["listed"]):
        sys.exit(1)


def manifest_row(c: dict, include_context: bool) -> dict:
    take = c.get("take") or {}
    cfg = c.get("config") or {}
    row = {"schema": SCHEMA, "id": c["id"], "audio": f"audio/{c['id']}.wav" if audio_of(c) else None,
           "duration": c.get("duration"), "text": truth(c), "reference": c.get("reference"), "corrected": c.get("corrected"),
           "asr_raw": take.get("raw"), "asr_text": take.get("asr_text"), "polished": take.get("polished"),
           "final": take.get("fitted") or take.get("text"), "language": take.get("language") or cfg.get("language"),
           "segments": [{"start": s.get("start"), "end": s.get("end"), "text": s.get("asr_text") or s.get("raw")}
                        for s in take.get("segments") or []],
           "errors": c.get("errors") or [], "scenario": c.get("scenario") or {}, "rating": c.get("rating") or {},
           "note": c.get("note") or "", "terms": c.get("expected_terms") or [], "app_bundle": (c.get("app") or {}).get("bundle"),
           "asr_model": take.get("asr_model") or cfg.get("asr_model"), "polish_model": take.get("polish_model") or cfg.get("polish_model"),
           "source": c.get("source"), "created": c.get("created"), "app_version": c.get("app_version"),
           "prompt": c.get("prompt"), "tags": case_tags(c)}
    ctx = context_payload(c)
    if include_context and ctx:
        row["context"] = ctx
    return row


def cmd_export(a) -> None:
    ids = [x for x in (a.cases or "").split(",") if x] or None
    cases = [c for c in all_cases() if not ids or c.get("id") in ids]
    out = Path(a.out).expanduser() if a.out else lab_dir() / "exports" / f"blurt-dictation-lab-{datetime.now():%Y%m%d-%H%M%S}.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for c in cases:
            row = manifest_row(c, a.include_context)
            if (w := audio_of(c)) and row["audio"]:
                z.write(w, row["audio"])
            rows.append(row)
        z.writestr("manifest.jsonl", "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
        z.writestr("dataset.json", json.dumps({"name": "blurt-dictation-lab", "schema": SCHEMA, "created": now_iso(),
                                               "cases": len(rows), "with_audio": sum(1 for r in rows if r["audio"]),
                                               "sample_rate": SR, "channels": 1, "manifest": "manifest.jsonl",
                                               "docs": "docs/design/dictation.md §Lab"}, ensure_ascii=False, indent=2))
    emit({"ok": True, "path": str(out), "cases": len(rows), "with_audio": sum(1 for r in rows if r["audio"])})


def _vocab_snapshot() -> dict[str, dict]:
    try:
        import dictation_vocab
        doc = json.loads(dictation_vocab.vocab_file().read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}
    return {t["term"]: t for t in doc.get("terms") or [] if isinstance(t, dict) and t.get("term")}


def vocab_changes(before: dict[str, dict], after: dict[str, dict]) -> list[dict]:
    """What a learn step changed, term by term: {"term", "before": term dict | None, "after": term dict | None}
    (the app's Undo puts "before" back while the term still looks like "after")."""
    out = []
    for term in list(after) + [t for t in before if t not in after]:
        b, a = before.get(term), after.get(term)
        if b != a:
            out.append({"term": term, "before": b, "after": a})
    return out


def _jsonable(v):
    try:
        json.dumps(v, ensure_ascii=False)
        return v
    except (TypeError, ValueError):
        return str(v)


def learn(raw: str, corrected: str) -> dict:
    """dictation_vocab.learn(raw, corrected) when the module has it (feature-detected: it may not exist yet)."""
    try:
        import dictation_vocab
    except Exception:  # noqa: BLE001
        return {"ok": True, "available": False}
    fn = getattr(dictation_vocab, "learn", None)
    if not callable(fn):
        return {"ok": True, "available": False}
    before = _vocab_snapshot()
    try:
        r = fn(raw, corrected)
    except Exception as e:  # noqa: BLE001 — a learner error never loses the case
        return {"ok": True, "available": True, "error": f"{type(e).__name__}: {e}"[:300], "changes": []}
    return {"ok": True, "available": True, "result": _jsonable(r), "changes": vocab_changes(before, _vocab_snapshot())}


def cmd_learn(a) -> None:
    emit(learn(a.raw, a.corrected))


def main() -> None:
    # the app's cloud polish key (the Keychain's) comes on stdin, never on the command line
    if "--key-stdin" in sys.argv:
        sys.argv.remove("--key-stdin")
        k = sys.stdin.readline().strip()
        if k:
            os.environ["BLURT_POLISH_API_KEY"] = k
    p = argparse.ArgumentParser(prog="dictation_lab.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    s = sub.add_parser("show")
    s.add_argument("id")
    ad = sub.add_parser("add")
    ad.add_argument("--wav", required=True)
    ad.add_argument("--id")
    ad.add_argument("--reference")
    ad.add_argument("--corrected")
    ad.add_argument("--tags")
    ad.add_argument("--note")
    ad.add_argument("--source", default="import")
    ad.add_argument("--app-version")
    fh = sub.add_parser("from-history")
    fh.add_argument("id")
    fh.add_argument("--app-version")
    fh.add_argument("--corrected")
    fh.add_argument("--note")
    fh.add_argument("--tags")
    imf = sub.add_parser("import-feedback")
    imf.add_argument("dir")
    imf.add_argument("--report", help="the report's id (default: the folder's name)")
    rv = sub.add_parser("review")
    rv.add_argument("--since")
    rv.add_argument("--last", type=int)
    rv.add_argument("--config")
    de = sub.add_parser("delete")
    de.add_argument("ids", nargs="+")
    sc = sub.add_parser("score")
    sc.add_argument("--ref", required=True)
    sc.add_argument("--hyp", required=True)
    sc.add_argument("--terms")
    sub.add_parser("configs")
    rr = sub.add_parser("rerun")
    rr.add_argument("id")
    rr.add_argument("--config", action="append")
    rr.add_argument("--save", action="store_true")
    ru = sub.add_parser("run")
    ru.add_argument("--config", default="current")
    ru.add_argument("--cases")
    ru.add_argument("--json", action="store_true")
    ru.add_argument("--no-save", action="store_true")
    ru.add_argument("--fail-on-regression", action="store_true")
    ex = sub.add_parser("export")
    ex.add_argument("--out")
    ex.add_argument("--cases")
    ex.add_argument("--include-context", action="store_true")
    le = sub.add_parser("learn")
    le.add_argument("--raw", required=True)
    le.add_argument("--corrected", required=True)
    sub.add_parser("packs")
    pk = sub.add_parser("pack")
    pk.add_argument("id")
    ip = sub.add_parser("import-pack")
    ip.add_argument("file")
    ge = sub.add_parser("generate")
    ge.add_argument("--pack", required=True)
    ge.add_argument("--n", type=int, default=10)
    ge.add_argument("--engine", choices=["auto", "agent", "local"], default="auto")
    ge.add_argument("--focus", help="a dimension to stress, e.g. 'self-corrections with numbers'")
    a = p.parse_args()
    try:
        {"list": cmd_list, "show": cmd_show, "add": cmd_add, "from-history": cmd_from_history,
         "import-feedback": cmd_import_feedback, "review": cmd_review, "delete": cmd_delete,
         "score": cmd_score, "configs": cmd_configs, "rerun": cmd_rerun, "run": cmd_run, "export": cmd_export,
         "learn": cmd_learn, "packs": cmd_packs, "pack": cmd_pack, "import-pack": cmd_import_pack,
         "generate": cmd_generate}[a.cmd](a)
    except Fail as e:
        emit({"ok": False, "error": str(e), "code": e.code})
        sys.exit(1)


if __name__ == "__main__":
    main()
