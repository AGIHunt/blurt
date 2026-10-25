"""Dictation's custom words (docs/design/dictation.md §Custom words). The app owns the file
($BLURT_HOME/dictation/vocabulary.json: it adds, removes, learns and seeds); this module only reads it and uses it:

  • ranked()        which terms matter for this utterance (sounds-like heard, in the context, used often), capped
  • ASR biasing     whisper_prompt() (initial_prompt), qwen_context() (Qwen3-ASR `context`), hotwords() (sherpa-onnx
                    Qwen3-ASR per-stream hotwords: "; "-joined, an ASCII comma is split and re-joined with spaces)
  • no rewriting   nothing here changes what was said: not a sounds-like ("cloud code" may be just that), not a term
                    written in pieces or in another case ("claude-code" in a path, "ba 12"). Only the sentence says
                    which, so the words are the models' hints (the speech model is told them, polish lists them)
  • allowed_units() what polish may add without the content-loss guard calling it new (terms + the context)

A term: {"term", "sounds_like": [...], "source": manual|learned|project|default, "state": active|suggested|rejected|
removed, "added", "hits", "seen"}. Only active terms are used; a sounds-like (what a speech model wrote instead, learned
from the user's fixes) only ranks a term as relevant. Requests may also pass the terms inline (a list of strings or
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
QWEN_MAX_TERMS = 64      # Qwen3-ASR's context: ~2 tokens a word, prefilled with the audio (+64 words ≈ +6 ms)
SCHEMA = 2               # the file's format (BlurtCore DictationVocabulary.schema; the app migrates older files)


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


def _lexicon() -> set[str]:
    """macOS's own lexicon, /usr/share/dict/words: its lower-case entries (data, not a list of ours). Empty where the
    system has none (Windows, many Linux installs)."""
    global _DICT
    if _DICT is None:
        _DICT = set()
        try:
            with open("/usr/share/dict/words", encoding="utf-8", errors="ignore") as f:
                _DICT = {ln.strip() for ln in f if ln.strip() and ln[0].islower()}
        except OSError:
            pass
    return _DICT


def common_word(w: str) -> bool:
    """An ordinary English word (the lexicon): a fix to one is usually grammar, not a name to learn (fixes())."""
    return w.lower() in _lexicon()


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
    then manual before learned before project; the most used of those when there are more than `limit`. Within the
    same relevance and source, by name: the order never depends on the hit counts."""
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

    # which terms make the cut: relevance, then whose, then use; their order in the prompt: the same without the hit
    # counts (a name order), so the request doesn't change every time a word is used — the app and the Dictation Lab
    # send the same terms in the same order (v0.9 dogfood: the order alone moved the language tag)
    chosen = sorted(terms, key=score)[:limit]
    return sorted(chosen, key=lambda t: (score(t)[:2], t["term"].casefold(), t["term"]))


def relevant(terms: list[dict], raw: str = "", context: str = "") -> list[dict]:
    """The terms this text may need: a sounds-like heard, the term itself (any case), a Latin word spelled like it,
    or the term in the context. What polish lists (ranked() orders them)."""
    low = unicodedata.normalize("NFKC", raw or "").lower()
    ctx = unicodedata.normalize("NFKC", context or "").lower()
    words = [w.lower() for w in _WORD.findall(low)]
    out = []
    for t in terms:
        k = t["term"].lower()
        if k in low or k in ctx or any(s.lower() in low for s in t["sounds_like"]) \
                or (not _CJK_RE.search(k) and any(similar(w, k) for w in words)):
            out.append(t)
    return out


def whisper_prompt(terms: list[dict]) -> str:
    """mlx-whisper initial_prompt: a plain comma list (asr eval: no insertions, no loops)."""
    return ", ".join(t["term"] for t in terms[:MAX_TERMS])


def qwen_context(terms: list[dict]) -> str:
    """Qwen3-ASR (MLX) context: an English sentence naming the terms (asr eval: 93 % of terms vs 74 % without)."""
    names = [t["term"] for t in terms[:QWEN_MAX_TERMS]]
    if not names:
        return ""
    return "Notes about " + (", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else names[0]) + "."


def hotwords(terms: list[dict]) -> str:
    """sherpa-onnx Qwen3-ASR hotwords: "; "-joined (it splits on ASCII commas and re-joins with spaces)."""
    return "; ".join(t["term"].replace(",", " ") for t in terms[:MAX_TERMS])


# ------------------------------------------------------------------ code-switching (docs/design/dictation.md)
# The tag goes to English only when the model is this sure: English speech measured ≥ 0.9985, the mixed pieces it
# translated 0.95–1.0 (names-in-Chinese eval, promo/cases/v0.8-dictation-names/).
EN_TAG_THRESHOLD = 0.995
_LATIN_WORD = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:['’][A-Za-z]+)?")


def cjk_share(text: str) -> float:
    """CJK characters / (CJK characters + Latin words): 0 for English, 1 for Chinese without English in it."""
    c = len(_CJK_RE.findall(text or ""))
    w = len(_LATIN_WORD.findall(text or ""))
    return c / (c + w) if c + w else 0.0


def choose_tag(p_en: float, p_pref: float, prefer: str, threshold: float = EN_TAG_THRESHOLD) -> str:
    """Qwen3-ASR's language tag for a user who mixes English into `prefer` (e.g. "Chinese"): English only when the
    model puts nearly all of the two tags' probability on it. The probabilities come from a prompt without the Words
    (transcribe.py Qwen3Mlx._decode_tagged): the threshold was measured that way."""
    total = p_en + p_pref
    return "English" if total > 0 and p_en / total > threshold else prefer


FRAGILE_MARGIN = 0.02       # a tag this close to the threshold could flip with a slightly different take


def tag_margin(p_en: float, p_pref: float, threshold: float = EN_TAG_THRESHOLD) -> float:
    """How far the English share (p_en / (p_en + p_pref)) is from the threshold: > 0 tagged English, < 0 the user's
    language. The history and the Dictation Lab show it; within FRAGILE_MARGIN the tag is fragile."""
    total = p_en + p_pref
    return round((p_en / total if total > 0 else 0.0) - threshold, 4)


def translated_glue(text: str, names=()) -> bool:
    """An English answer that still has Chinese characters in it ("open AI and Musk's Grok, and…CEO是Dario的…"): the
    model switched languages mid-sentence, so the piece is decoded once more under the user's language. The script
    alone decides (no list of English function words): an all-English answer is the speech model's own call."""
    return bool(text and _CJK_RE.search(text))


_SEP = re.compile(r"[\s,，、;；/|·]*")


def context_dump(text: str, names, run: int = 4) -> bool:
    """The speech model wrote its word list out: ≥ `run` of the listed names one after another, in the list's order,
    with only separators between them ("Claude Code、Codex、blurt、口喷鸡…"). Nobody dictates four names in exactly
    that order."""
    if not text or not names:
        return False
    order = {}
    for i, n in enumerate(names):
        order.setdefault(n.lower(), i)
    pats = sorted(order, key=len, reverse=True)
    low = text.lower()
    hits, i = [], 0
    while i < len(low):
        for p in pats:
            if low.startswith(p, i) and (not p[-1].isalnum() or i + len(p) >= len(low) or not low[i + len(p)].isascii()
                                         or not low[i + len(p)].isalnum()):
                hits.append((i, i + len(p), order[p]))
                i += len(p)
                break
        else:
            i += 1
    best = cur = 1 if hits else 0
    for (s0, e0, k0), (s1, e1, k1) in zip(hits, hits[1:]):
        gap = text[e0:s1]
        cur = cur + 1 if k1 > k0 and len(gap) <= 3 and _SEP.fullmatch(gap) else 1
        best = max(best, cur)
    return best >= run


# ------------------------------------------------------------------ the guard's allowance
def allowed_units(terms: list[dict], context: str = "") -> set[str]:
    """Units (as polish.units counts them) that polish may write although they weren't spoken: the terms' own, and the
    context's (a name spelled the way the document around the cursor spells it)."""
    t = " ".join(x["term"] for x in terms) + " " + (context or "")
    t = unicodedata.normalize("NFKC", t).lower()
    return set(re.findall(rf"[{_CJK}]|[a-z]+(?:['’][a-z]+)?|[0-9]", t))


# ------------------------------------------------------------------ learning from a correction (the lab, the page)
# A Python port of BlurtCore's DictationLearn.fixes + DictationVocabulary.learn (Swift; the same rules, the same
# file), for tools that see a dictation and the user's corrected version of it — the Dictation Lab — where the app's
# after-typing watch can't (WeChat's input box has no readable text). docs/design/dictation.md §Learning from
# corrections.
_FN = {"a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "is", "are",
       "was", "were", "be", "been", "am", "it", "its", "it's", "this", "that", "these", "those", "there", "their",
       "they're", "they", "them", "he", "she", "we", "you", "your", "you're", "i", "my", "our", "his", "her", "not", "no",
       "do", "does", "did", "have", "has", "had", "can", "could", "will", "would", "should", "may", "might", "so", "if",
       "then", "than", "too", "two", "who", "whose", "what", "which", "where", "when", "how", "here", "hear", "we're",
       "lets", "let's"}
MAX_WORDS, MAX_CJK, MAX_FIXED_WORDS, MAX_FIXED_CJK, MAX_FIXES = 3, 4, 4, 6, 3


def _tokens(s: str) -> list[tuple[str, int, int, bool]]:
    """(text, start, end, cjk): a word / number, or one CJK character."""
    out, i, n = [], 0, len(s)

    def isw(c: str) -> bool:
        return c.isalnum() and not _CJK_RE.match(c)

    while i < n:
        c = s[i]
        if _CJK_RE.match(c):
            out.append((c, i, i + 1, True))
            i += 1
        elif isw(c):
            j = i + 1
            while j < n:
                if isw(s[j]):
                    j += 1
                elif s[j] in "'’-" and j + 1 < n and isw(s[j + 1]):
                    j += 2
                else:
                    break
            out.append((s[i:j], i, j, False))
            i = j
        else:
            i += 1
    return out


def _lcs(a, b) -> list[tuple[int, int]]:
    n, m = len(a), len(b)
    if not n or not m:
        return []
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            dp[i][j] = dp[i + 1][j + 1] + 1 if a[i][0] == b[j][0] else max(dp[i + 1][j], dp[i][j + 1])
    out, i, j = [], 0, 0
    while i < n and j < m:
        if a[i][0] == b[j][0]:
            out.append((i, j))
            i += 1
            j += 1
        elif dp[i + 1][j] >= dp[i][j + 1]:
            i += 1
        else:
            j += 1
    return out


_PINYIN_CF = None


def pinyin(s: str) -> str:
    """Mandarin → toneless pinyin, no spaces ("口喷鸡" → "koupenji"), Latin kept in lower case: macOS's own transform
    (CFStringTransform, what the app uses), else pypinyin when installed, else the text unchanged."""
    global _PINYIN_CF
    if not _CJK_RE.search(s or ""):
        return "".join(c for c in _key(s) if c.isalnum())
    if _PINYIN_CF is None:
        _PINYIN_CF = False
        try:
            import ctypes
            import ctypes.util
            cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation") or "CoreFoundation")
            cf.CFStringCreateMutable.restype = ctypes.c_void_p
            cf.CFStringCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long]
            cf.CFStringAppendCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
            cf.CFStringTransform.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool]
            cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
            cf.CFRelease.argtypes = [ctypes.c_void_p]
            latin = ctypes.c_void_p.in_dll(cf, "kCFStringTransformMandarinLatin")
            strip = ctypes.c_void_p.in_dll(cf, "kCFStringTransformStripDiacritics")
            _PINYIN_CF = (ctypes, cf, latin, strip)
        except (OSError, AttributeError, ValueError, TypeError):
            pass
    out = None
    if _PINYIN_CF:
        ctypes, cf, latin, strip = _PINYIN_CF
        utf8 = 0x08000100
        ms = cf.CFStringCreateMutable(None, 0)
        try:
            cf.CFStringAppendCString(ms, s.encode("utf-8"), utf8)
            cf.CFStringTransform(ms, None, latin, False)
            cf.CFStringTransform(ms, None, strip, False)
            buf = ctypes.create_string_buffer(len(s.encode("utf-8")) * 8 + 16)
            if cf.CFStringGetCString(ms, buf, len(buf), utf8):
                out = buf.value.decode("utf-8")
        finally:
            cf.CFRelease(ms)
    if out is None:
        try:
            from pypinyin import lazy_pinyin  # type: ignore
            out = "".join(lazy_pinyin(s))
        except ImportError:
            out = s
    return "".join(c for c in _key(out) if c.isalnum())


def fix_kind(heard: str, fixed: str) -> str | None:
    """How `heard` and `fixed` are alike ("case" | "spelling" | "sound"), or None when it isn't a recognition fix
    (DictationLearn.similarity)."""
    h, f = _key(heard), _key(fixed)
    if not h or not f or heard == fixed:
        return None
    if h == f:
        return "case"

    def sk(s: str) -> str:
        return re.sub(r"[aeiouyhw]", "", s)

    def ratio(x: str, y: str) -> float:
        return 1 - _lev(x, y) / max(len(x), len(y), 1)

    if not _CJK_RE.search(heard) and not _CJK_RE.search(fixed):
        if ratio(h, f) >= 0.5:
            return "spelling"
        if len(h) >= 2 and f.startswith(h):
            return "spelling"
        if len(sk(h)) >= 2 and sk(h) == sk(f):
            return "sound"
        return None
    p, q = pinyin(heard).replace("c", "k"), pinyin(fixed).replace("c", "k")
    if not p or not q:
        return None
    if p == q or ratio(p, q) >= 0.6:
        return "sound"
    if len(sk(p)) >= 2 and sk(p) == sk(q):
        return "sound"
    return None


SENTENCE_PUNCT = "，。、；：！？,;:!?…"


def has_sentence_punctuation(s: str) -> bool:
    """A term never has sentence or clause punctuation in it — it would be two words run together ("会话，BA-3")
    (DictationVocabulary.hasSentencePunctuation). Hyphens, apostrophes and dots in a name are fine."""
    return any(c in SENTENCE_PUNCT for c in s)


def _boundary(l, r, s: str) -> bool:
    """Between two neighbouring tokens: punctuation (anything but spaces), or Chinese next to Latin."""
    return l[3] != r[3] or bool(s[l[2]:r[1]].strip(" "))


def _split(xs: list, ys: list, typed: str, edited: str) -> list[tuple[list, list]]:
    """A replaced run cut at the edited side's boundaries, the typed tokens shared out so each part pairs with what
    sounds most like it (DictationLearn.split). One part: the run itself; [] when it can't be shared out."""
    cuts = [k for k in range(1, len(ys)) if _boundary(ys[k - 1], ys[k], edited)]
    if not cuts:
        return [(xs, ys)]
    bounds = [0] + cuts + [len(ys)]
    parts = [ys[bounds[i]:bounds[i + 1]] for i in range(len(bounds) - 1)]
    n, m = len(xs), len(parts)
    if n < m:
        return []

    def text(ts, s):
        return s[ts[0][1]:ts[-1][2]]

    def score(a, b) -> float:
        h, f = text(a, typed), text(b, edited)
        if not fix_kind(h, f):
            return 0.0
        ph, pf = pinyin(h) or _key(h), pinyin(f) or _key(f)
        return 1 + 1 - _lev(ph, pf) / max(len(ph), len(pf), 1)

    best = [[-1.0] * (n + 1) for _ in range(m + 1)]
    frm = [[0] * (n + 1) for _ in range(m + 1)]
    best[0][0] = 0.0
    for k in range(1, m + 1):
        for j in range(k, n + 1):
            if n - j < m - k:
                continue
            for i in range(k - 1, j):
                if best[k - 1][i] < 0:
                    continue
                v = best[k - 1][i] + score(xs[i:j], parts[k - 1])
                if v > best[k][j]:
                    best[k][j], frm[k][j] = v, i
    out, j = [], n
    for k in range(m, 0, -1):
        i = frm[k][j]
        out.append((xs[i:j], parts[k - 1]))
        j = i
    return out[::-1]


def fixes(typed: str, edited: str) -> list[dict]:
    """What the user fixed in `typed` to get `edited`: [{"heard", "fixed", "kind"}], the app's rules
    (DictationLearn.fixes): small replaced spans that sound or look alike; nothing when it is a rewrite. Two fixes
    side by side ("绘画 BA 三" → "会话，BA-3") are two, never one term with a comma in it."""
    a, b = _tokens(typed or ""), _tokens(edited or "")
    if not a or not b or [t[0] for t in a] == [t[0] for t in b]:
        return []
    pairs = _lcs(a, b)
    if len(pairs) / len(a) < 0.5:
        return []
    reps, pi, pj = [], 0, 0
    for i, j in pairs + [(len(a), len(b))]:
        if i > pi and j > pj:
            reps.append((pi, i, pj, j))
        pi, pj = i + 1, j + 1
    if not reps or len(reps) > MAX_FIXES:
        return []

    def text(ts, s: str) -> str:
        return s[ts[0][1]:ts[-1][2]] if ts else ""

    def neigh(t) -> bool:
        return not t[3] and t[0].lower() not in _FN

    subs = []
    for xi, xe, yi, ye in reps:
        for xs_, ys_ in _split(a[xi:xe], b[yi:ye], typed, edited):
            i0, j0 = a.index(xs_[0]), b.index(ys_[0])
            subs.append((i0, i0 + len(xs_), j0, j0 + len(ys_)))
    out = []
    for xi, xe, yi, ye in subs:
        xs, ys = a[xi:xe], b[yi:ye]
        cjk = all(t[3] for t in xs) and all(t[3] for t in ys)
        words, chars = sum(not t[3] for t in xs), sum(t[3] for t in xs)
        fwords, fchars = sum(not t[3] for t in ys), sum(t[3] for t in ys)
        if words > MAX_WORDS or chars > MAX_CJK or fwords > MAX_FIXED_WORDS or fchars > MAX_FIXED_CJK:
            continue
        if cjk and len(ys) < 2:     # one character means nothing alone: take the unchanged ones before it
            lo, lj = xi, yi
            while lo > 0 and lj > 0 and len(xs) < 3 and a[lo - 1][3] and b[lj - 1][3] and a[lo - 1][0] == b[lj - 1][0] \
                    and a[lo - 1][2] == xs[0][1]:
                lo, lj = lo - 1, lj - 1
                xs, ys = a[lo:xe], b[lj:ye]
            if len(ys) < 2:
                continue
        heard, fixed = text(xs, typed), text(ys, edited)
        kind = fix_kind(heard, fixed)
        if not kind:
            continue
        plain = fixed == fixed.lower() and " " not in fixed and not _CJK_RE.search(fixed) and not re.search(r"\d", fixed)
        if plain and common_word(fixed) and not _key(fixed).startswith(_key(heard)):
            # an ordinary word: grammar is not vocabulary; a misheard word in a phrase is (pool request → pull request)
            if fixed in _FN or heard.lower() in _FN or len(xs) != 1 or len(ys) != 1:
                continue
            if xe < len(a) and ye < len(b) and a[xe][0] == b[ye][0] and neigh(a[xe]) and xs[-1][2] + 1 == a[xe][1] \
                    and ys[-1][2] + 1 == b[ye][1]:
                xs, ys = a[xi:xe + 1], b[yi:ye + 1]
            elif xi > 0 and yi > 0 and a[xi - 1][0] == b[yi - 1][0] and neigh(a[xi - 1]) and a[xi - 1][2] + 1 == xs[0][1] \
                    and b[yi - 1][2] + 1 == ys[0][1]:
                xs, ys = a[xi - 1:xe], b[yi - 1:ye]
            else:
                continue
            heard, fixed = text(xs, typed), text(ys, edited)
        if has_sentence_punctuation(fixed):
            continue
        out.append({"heard": heard, "fixed": fixed, "kind": kind})
    return out[:MAX_FIXES]


def _now() -> str:
    from datetime import datetime
    return datetime.now().astimezone().replace(microsecond=0).isoformat()


def _write_doc(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


def learn_fix(doc: dict, heard: str, fixed: str, explicit: bool = True) -> str | None:
    """DictationVocabulary.learn on the file's document: a known word gains `heard` as a sounds-like; a new one is
    used at once when the correction is explicit (the user saved it) or only case / spacing, else it is a suggestion
    (used the second time). → "learned" | "suggested" | "known" | None (a word the user rejected or removed)."""
    h, f = (heard or "").strip(), (fixed or "").strip()
    if not h or not f or h == f or has_sentence_punctuation(f):
        return None
    spelling = _key(h) == _key(f)
    terms = doc.setdefault("terms", [])
    for t in terms:
        if t.get("term") != f:
            continue
        st = t.get("state", "active")
        if st in ("rejected", "removed"):
            return None
        sl = t.setdefault("sounds_like", [])
        if not spelling and h not in sl:
            sl.append(h)
        if st == "active":
            t["hits"] = int(t.get("hits") or 0) + 1
            return "known"
        t["seen"] = int(t.get("seen") or 0) + 1
        if explicit or t["seen"] >= 2:
            t["state"] = "active"
            return "learned"
        return "suggested"
    active = explicit or spelling
    terms.append({"term": f, "sounds_like": [] if spelling else [h], "source": "learned",
                  "state": "active" if active else "suggested", "added": _now(), "hits": 0, "seen": 1})
    return "learned" if active else "suggested"


def learn(raw: str, corrected: str, explicit: bool = True, path: Path | None = None, dry_run: bool = False) -> dict:
    """The user corrected a dictation (`raw`: what was typed — or heard —; `corrected`: their version). The fixes found
    (fixes()) go into the vocabulary file the app reads: a misheard name becomes a word, with what was heard as its
    sounds-like, so the next dictation that sounds like it tells the models about the word (a word, never a
    replacement rule).
    explicit (default): the user saved this correction, so a new word is used at once; False = a suggestion, as the
    after-typing watch makes. → {"ok", "fixes": [{"heard", "fixed", "kind", "result"}], "path", "written"}."""
    path = Path(path) if path else vocab_file()
    found = fixes(raw, corrected)
    if not found or dry_run:
        return {"ok": True, "fixes": found, "path": str(path), "written": False}
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            doc = {}
    except (OSError, ValueError):
        doc = {}
    doc.setdefault("schema", SCHEMA)
    for fx in found:
        fx["result"] = learn_fix(doc, fx["heard"], fx["fixed"], explicit)
    written = any(fx["result"] for fx in found)
    if written:
        _write_doc(path, doc)
    return {"ok": True, "fixes": found, "path": str(path), "written": written}


def main(argv=None) -> int:
    """dictation_vocab.py learn --raw TEXT --corrected TEXT [--suggest] [--dry-run] [--file PATH]
    dictation_vocab.py fixes --raw TEXT --corrected TEXT          what would be learned; writes nothing"""
    import argparse
    ap = argparse.ArgumentParser(prog="dictation_vocab.py", description=main.__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("learn", "fixes"):
        p = sub.add_parser(name)
        p.add_argument("--raw", required=True, help="what was typed (or heard)")
        p.add_argument("--corrected", required=True, help="the user's corrected text")
        p.add_argument("--file", help="vocabulary.json (default $BLURT_HOME/dictation/vocabulary.json)")
        if name == "learn":
            p.add_argument("--suggest", action="store_true", help="a new word only as a suggestion (as the watch does)")
            p.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    path = Path(a.file) if a.file else None
    out = learn(a.raw, a.corrected, explicit=not getattr(a, "suggest", False), path=path,
                dry_run=a.cmd == "fixes" or getattr(a, "dry_run", False))
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
