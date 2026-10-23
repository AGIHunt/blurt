"""Dictation's custom words (docs/design/dictation.md §Custom words). The app owns the file
($BLURT_HOME/dictation/vocabulary.json: it adds, removes, learns and seeds); this module only reads it and uses it:

  • ranked()        which terms matter for this utterance (sounds-like heard, in the context, used often), capped
  • ASR biasing     whisper_prompt() (initial_prompt), qwen_context() (Qwen3-ASR `context`), hotwords() (sherpa-onnx
                    Qwen3-ASR per-stream hotwords: "; "-joined, an ASCII comma is split and re-joined with spaces)
  • apply()         the cheap deterministic pass, also when polish is off: an exact sounds-like match becomes the term,
                    and a case / spacing variant of a term gets the term's spelling ("sense voice" → "SenseVoice")
  • allowed_units() what polish may add without the content-loss guard calling it new (terms + the context)

A term: {"term", "sounds_like": [...], "source": manual|learned|project, "state": active|suggested|rejected|removed,
"added", "hits", "seen"}. Only active terms are used. Requests may also pass the terms inline (a list of strings or
dicts), which wins over the file.
"""
from __future__ import annotations

import json
import os
import re
import unicodedata
from pathlib import Path

_CJK = r"㐀-䶿一-鿿豈-﫿"
_CJK_RE = re.compile(rf"[{_CJK}]")
_WORD = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)?")
MAX_TERMS = 40           # in an ASR prompt or the polish prompt (Whisper's prompt is ~224 tokens)


def vocab_file() -> Path:
    home = Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")
    return home / "dictation" / "vocabulary.json"


def normalize(v) -> list[dict]:
    """Terms from the file's document, a request's list of strings / dicts, or None → [{"term","sounds_like","hits",
    "source"}], active ones only, deduplicated by spelling."""
    if isinstance(v, dict):
        v = v.get("terms")
    out, seen = [], set()
    for t in v or []:
        if isinstance(t, str):
            t = {"term": t}
        if not isinstance(t, dict) or t.get("state", "active") != "active":
            continue
        term = str(t.get("term") or "").strip()
        if not term or term in seen:
            continue
        seen.add(term)
        sl = [s.strip() for s in t.get("sounds_like") or [] if isinstance(s, str) and s.strip()]
        out.append({"term": term, "sounds_like": sl, "hits": int(t.get("hits") or 0), "source": t.get("source") or "manual"})
    return out


def load(path: Path | None = None) -> list[dict]:
    try:
        return normalize(json.loads((path or vocab_file()).read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return []


# ------------------------------------------------------------------ helpers
_DICT: set[str] | None = None


def common_word(w: str) -> bool:
    """An ordinary English word (macOS's /usr/share/dict/words, lower-case entries): a sounds-like or a case fix on it
    would change real words ("cloud", "swift"), so the deterministic pass leaves those to polish, which sees context."""
    global _DICT
    if _DICT is None:
        _DICT = set()
        try:
            with open("/usr/share/dict/words", encoding="utf-8", errors="ignore") as f:
                _DICT = {ln.strip() for ln in f if ln.strip() and ln[0].islower()}
        except OSError:
            pass
        _DICT |= {"a", "an", "the", "and", "or", "of", "to", "in", "on", "it", "is", "be", "code", "cloud", "blur", "option"}
    return w.lower() in _DICT


def _key(s: str) -> str:
    """Spelling-insensitive key: lower case, no spaces / hyphens / dots."""
    return re.sub(r"[\s\-_.·]+", "", unicodedata.normalize("NFKC", s or "").lower())


def _lev(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def similar(a: str, b: str) -> bool:
    """Close in spelling (Latin): normalised edit distance ≤ 40 %, or the same consonant skeleton."""
    a, b = _key(a), _key(b)
    if not a or not b:
        return False
    if a == b:
        return True
    if 1 - _lev(a, b) / max(len(a), len(b)) >= 0.6:
        return True
    sk = lambda s: re.sub(r"[aeiouyhw]", "", s)  # noqa: E731
    return len(a) >= 3 and len(b) >= 3 and sk(a) == sk(b) and len(sk(a)) >= 2


# ------------------------------------------------------------------ which terms matter now
def ranked(terms: list[dict], raw: str = "", context: str = "", limit: int = MAX_TERMS) -> list[dict]:
    """Relevant first: a sounds-like heard in `raw`, a term (or something spelled like it) in `raw` or the context,
    then manual before learned before project, then by hits. At most `limit`."""
    low_raw = unicodedata.normalize("NFKC", raw or "").lower()
    low_ctx = unicodedata.normalize("NFKC", context or "").lower()
    words = [w.lower() for w in _WORD.findall(low_raw)]

    def score(t: dict) -> tuple:
        s = 0
        if any(sl.lower() in low_raw for sl in t["sounds_like"]):
            s += 8
        k = t["term"].lower()
        if k in low_raw:
            s += 4
        elif not _CJK_RE.search(k) and any(similar(w, k) for w in words):
            s += 3
        if k in low_ctx:
            s += 2
        src = {"manual": 2, "learned": 1}.get(t.get("source"), 0)
        return (-s, -src, -t.get("hits", 0))

    return sorted(terms, key=score)[:limit]


def whisper_prompt(terms: list[dict]) -> str:
    """mlx-whisper initial_prompt: a plain comma list (asr eval: no insertions, no loops)."""
    return ", ".join(t["term"] for t in terms[:MAX_TERMS])


def qwen_context(terms: list[dict]) -> str:
    """Qwen3-ASR (MLX) context: an English sentence naming the terms (asr eval: 93 % of terms vs 74 % without)."""
    names = [t["term"] for t in terms[:MAX_TERMS]]
    if not names:
        return ""
    return "Notes about " + (", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else names[0]) + "."


def hotwords(terms: list[dict]) -> str:
    """sherpa-onnx Qwen3-ASR hotwords: "; "-joined (it splits on ASCII commas and re-joins with spaces)."""
    return "; ".join(t["term"].replace(",", " ") for t in terms[:MAX_TERMS])


# ------------------------------------------------------------------ the deterministic pass
def _latin_pattern(phrase: str) -> re.Pattern:
    parts = [re.escape(p) for p in re.split(r"\s+", phrase.strip()) if p]
    return re.compile(r"(?<![A-Za-z0-9])" + r"\s+".join(parts) + r"(?![A-Za-z0-9])", re.I)


def apply(text: str, terms: list[dict]) -> tuple[str, list[str]]:
    """→ (text, the terms it wrote). Exact sounds-like matches become the term (not a lone ordinary English word, not
    a single CJK character); a variant of a term that differs only in case, spaces or hyphens gets the term's spelling
    (not when the term is one ordinary English word: "swift" stays)."""
    out, applied = text or "", []
    if not out or not terms:
        return out, applied
    for t in sorted(terms, key=lambda t: -len(t["term"])):
        term = t["term"]
        hit = False
        for sl in sorted(t["sounds_like"], key=len, reverse=True):
            if _key(sl) == _key(term) and sl != term:
                continue  # a spelling variant: the case / spacing pass below handles it
            if _CJK_RE.search(sl):
                if len(sl) < 2 or sl not in out:
                    continue
                out = out.replace(sl, term)
                hit = True
            else:
                if " " not in sl.strip() and (common_word(sl) or len(sl) < 2):
                    continue
                new = _latin_pattern(sl).sub(term, out)
                if new != out:
                    out, hit = new, True
        if not _CJK_RE.search(term):
            out, fixed = _respell(out, term)
            hit = hit or fixed
        if hit and term not in applied:
            applied.append(term)
    return out, applied


def _respell(text: str, term: str) -> tuple[str, bool]:
    """Windows of 1–3 words (joined by single spaces / hyphens) whose spelling key equals the term's → the term."""
    key = _key(term)
    if len(key) < 2:
        return text, False
    single_common = " " not in term and "-" not in term and common_word(term)
    words = list(_WORD.finditer(text))
    out, last, changed = [], 0, False
    i = 0
    while i < len(words):
        done = False
        for n in (3, 2, 1):
            if i + n > len(words):
                continue
            span = words[i:i + n]
            if any(re.fullmatch(r"[ \-]", text[a.end():b.start()]) is None for a, b in zip(span, span[1:])):
                continue
            s, e = span[0].start(), span[-1].end()
            seg = text[s:e]
            if _key(seg) != key:
                continue
            if seg != term and not (n == 1 and single_common):
                out.append(text[last:s])
                out.append(term)
                last = e
                changed = True
            i += n
            done = True
            break
        if not done:
            i += 1
    out.append(text[last:])
    return "".join(out), changed


# ------------------------------------------------------------------ the guard's allowance
def allowed_units(terms: list[dict], context: str = "") -> set[str]:
    """Units (as polish.units counts them) that polish may write although they weren't spoken: the terms' own, and the
    context's (a name spelled the way the document around the cursor spells it)."""
    t = " ".join(x["term"] for x in terms) + " " + (context or "")
    t = unicodedata.normalize("NFKC", t).lower()
    return set(re.findall(rf"[{_CJK}]|[a-z]+(?:['’][a-z]+)?|[0-9]", t))
