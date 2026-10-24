"""BlurtCore's DictationStitch and DictationStream's polish windows, ported (docs/design/dictation.md §Streaming), so
the Dictation Lab can replay a take the way the app polishes it while the user talks (`mode=windows`): each piece
polished in a window with the clause carried from the window before, what polish wrote up to its last comma or
sentence end committed, the dictation's text so far sent along as context, and the joined result checked once more
against the joined transcript — and, for Structured, the one structuring pass at key-up. The same rules as the Swift
code (DictationStitchTests; tests/test_dictation_stitch.py holds the shared cases): keep the two in step.

Mechanical only (§Rules vs model): pauses, punctuation marks, scripts and units. Whether a sentence is complete,
whether a word is a name, whether a piece corrects the one before — that is the polish model's call, made over a
window that spans the seam.
"""
from __future__ import annotations

import re

LONG_PAUSE = 1.2
_TRAILING = set("。.!?！？，,、；;…")
_TERMINATORS = set("。.!?！？")
_CLOSERS = set("”’\"'」』）)")
_CLAUSE = set("，；、：,;:")


def _is_cjk(c: str) -> bool:
    o = ord(c)
    return 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x3040 <= o <= 0x30FF \
        or 0xAC00 <= o <= 0xD7AF


def _word_char(c: str) -> bool:
    return not _is_cjk(c) and (c.isalpha() or c.isdigit()) and not c.isspace()


def units(text: str) -> list[str]:
    """Each CJK character, each Latin word (lower case, an apostrophe inside), each digit."""
    out, i, t = [], 0, text or ""
    while i < len(t):
        c = t[i]
        if _is_cjk(c) or c.isdigit():
            out.append(c.lower())
            i += 1
        elif c.isalpha():
            j = i + 1
            while j < len(t) and t[j].isalpha() and not _is_cjk(t[j]):
                j += 1
            if j < len(t) - 1 and t[j] in "'’" and t[j + 1].isalpha() and not _is_cjk(t[j + 1]):
                j += 1
                while j < len(t) and t[j].isalpha() and not _is_cjk(t[j]):
                    j += 1
            out.append(t[i:j].lower())
            i = j
        else:
            i += 1
    return out


def join(a: str, b: str) -> str:
    """A space only where two Latin words (or numbers) meet."""
    a, b = (a or "").strip(), (b or "").strip()
    if not a:
        return b
    if not b:
        return a
    latin_end = _word_char(a[-1]) or a[-1] in ".,;:!?)”\""
    return a + (" " if latin_end and _word_char(b[0]) else "") + b


def join_all(parts: list[str]) -> str:
    out = ""
    for p in parts:
        out = join(out, p)
    return out


def split_trailing(text: str) -> tuple[str, str]:
    core, end = (text or "").strip(), ""
    while core and (core[-1] in _TRAILING or core[-1].isspace()):
        if not core[-1].isspace():
            end = core[-1] + end
        core = core[:-1]
    return core, end


def ends_cjk(text: str) -> bool:
    for c in reversed(text or ""):
        if c.isalpha() or c.isdigit():
            return _is_cjk(c)
    return False


def terminator(end: str, after: str) -> str:
    c = next((x for x in end if x in _TERMINATORS), ".")
    cjk = ends_cjk(after)
    if c in "!！":
        return "！" if cjk else "!"
    if c in "?？":
        return "？" if cjk else "?"
    return "。" if cjk else "."


def mark(end: str, after: str) -> str:
    """The one mark a pause leaves: the sentence end in `end` (in the text's script), else its comma / semicolon."""
    if any(c in _TERMINATORS for c in end):
        return terminator(end, after)
    if not end:
        return ""
    if any(c in "；;" for c in end):
        return "；" if ends_cjk(after) else ";"
    return "，" if ends_cjk(after) else ","


def seam(previous: str, nxt: str, pause: float | None) -> tuple[str, str]:
    """A pause between two pieces: after a long one (≥ LONG_PAUSE) the speech model's own mark stays; after a breath
    (or one not known) it goes — a cut is not a sentence end. Case and words are left as they are."""
    core, end = split_trailing(previous)
    if not core:
        return previous, nxt
    if pause is not None and pause >= LONG_PAUSE and end:
        return core + mark(end, core), nxt
    return core, nxt


def fallback_seam(previous: str, nxt: str, pause: float | None, heard_end: str) -> str:
    """Where a polish window fell back to the transcript: the seam still gets its punctuation — a long pause the seam
    rule's, and a short one a comma where the speech model heard a boundary (it ended the piece with a mark). Without
    it the take read 「…跑完第二，…」."""
    core, end = split_trailing(previous)
    if not core:
        return join(previous, nxt)
    if pause is not None and pause >= LONG_PAUSE:
        a, b = seam(core + (end or heard_end), nxt, pause)
        return join(a, b)
    if end or heard_end:
        return core + ("，" if ends_cjk(core) else ", ") + (nxt or "").lstrip()
    return join(core, nxt)


def join_pieces(texts: list[str], pauses: list[float | None], fallback: bool = False) -> str:
    """The pieces' texts with the seam rule; `fallback`: with fallback_seam (a comma where a boundary was heard)."""
    acc, after, after_end = "", None, ""
    for i, t in enumerate(texts):
        pause = pauses[i] if i < len(pauses) else None
        t = (t or "").strip()
        if not t:
            if after is not None and pause is not None:
                after += pause
            continue
        if not acc:
            acc = t
        elif fallback:
            acc = fallback_seam(acc, t, after, after_end)
        else:
            a, b = seam(acc, t, after)
            acc = join(a, b)
        after, after_end = pause, split_trailing(t)[1]
    return acc


def commit_split(text: str, at_clauses: bool = True) -> tuple[str, str, str]:
    core, end = split_trailing(text)
    clause = _CLAUSE if at_clauses else set()
    cut, i = None, 0
    while i < len(core):
        c = core[i]
        j = i + 1
        if c in _TERMINATORS or c in clause:
            while j < len(core) and core[j] in _CLOSERS:
                j += 1
            latin = c.isascii()
            if not latin or j == len(core) or core[j].isspace() or _is_cjk(core[j]):
                cut = j
        i = j
    ce = cut if cut is not None else 0
    return core[:ce].strip(), core[ce:].strip(), end


def keep_case(inp: str, out: str) -> str:
    """The output with the case its first word had in the input (polish capitalises a window that continues a
    sentence: "update the docs" → "Update the docs")."""
    i, o = (inp or "").strip(), (out or "").strip()
    if not i or not o or not i[0].islower() or not o[0].isupper() or not _word_char(o[0]):
        return out
    wi = re.match(r"[^\W\d_'’]+(?:['’][^\W\d_]+)*", i)
    wo = re.match(r"[^\W\d_'’]+(?:['’][^\W\d_]+)*", o)
    if not wi or not wo or len(wi.group()) != len(wo.group()) or wi.group()[1:] != wo.group()[1:] \
            or wi.group().lower() != wo.group().lower():
        return out
    return wi.group() + o[len(wo.group()):]


def mid_sentence(text: str) -> bool:
    t = (text or "").rstrip()
    return bool(t) and t[-1] not in _TERMINATORS and t[-1] not in "\n"


# ------------------------------------------------------------------ DictationStream's polish windows
def stream(pieces: list[dict], pauses: list[float | None], polish, guard=None, context: dict | None = None,
           structure=None) -> dict:
    """Replay the app's windows. pieces: [{"raw"}] (the transcript of each piece, in order; the last one is where the
    dictation ended); polish(text, context) → polish.py's answer; guard(raw, output, fallback) → the stitch guard's.
    `structure(text)` (Structured): at key-up, Light's stitched text goes through the structuring pass once; a refusal
    types Light's text. → {"text", "raw", "light", "pieces": [{"polish_in", "text", "fell_back", "reason", "ms",
    "echo"}], "fell_back", "reason", "stitch", "structured": None | {…, "input"}}."""
    carry = carry_end = ""
    out_pieces: list[dict] = []
    n = len(pieces)
    for idx, p in enumerate(pieces):
        raw = (p.get("raw") or "").strip()
        rec = {"index": idx, "raw": raw, "text": "", "polish_in": "", "fell_back": False, "reason": None, "ms": 0}
        out_pieces.append(rec)
        if not raw:
            continue
        last = idx == n - 1
        core = raw if last else split_trailing(raw)[0]
        g_prev = pauses[idx - 1] if idx > 0 and idx - 1 < len(pauses) else None
        # the carried clause goes into this window; after a long pause with the mark it ended in (the pause may have
        # ended a sentence: the model decides, seeing both sides)
        carry_in = carry + (mark(carry_end, carry) if carry and g_prev is not None and g_prev >= LONG_PAUSE else "")
        carry = carry_end = ""
        inp = join(carry_in, core)
        so = join_all([q["text"] for q in out_pieces[:idx]])
        ctx = dict(context or {})
        if so:
            ctx["dictated"] = so
        rec["polish_in"] = inp
        r = polish(inp, ctx or None) or {}
        rec.update(fell_back=bool(r.get("fell_back")), reason=r.get("reason") if r.get("fell_back") else None,
                   ms=int(r.get("ms") or 0), echo=r.get("echo"), polished=r.get("polished"))
        out = (r.get("text") or "").strip() or inp
        if rec["fell_back"] and carry_in and out.startswith(carry_in):
            # the window fell back: its seam (the pause before this piece) still gets its punctuation
            heard = split_trailing(pieces[idx - 1].get("raw") or "")[1] if idx > 0 else ""
            out = fallback_seam(carry_in, out[len(carry_in):], g_prev, heard)
        if mid_sentence(so) and not rec["fell_back"]:
            out = keep_case(inp, out)          # the model capitalised a window that continues a sentence
        if last:
            rec["text"] = out
        else:
            commit, carry, carry_end = commit_split(out)
            rec["text"] = commit
    raw_all = join_pieces([p.get("raw") or "" for p in pieces], pauses)
    text = join_all([q["text"] for q in out_pieces] + [carry + carry_end])
    fell = [q for q in out_pieces if q["fell_back"]]
    res = {"text": text or raw_all, "raw": raw_all, "pieces": out_pieces, "fell_back": bool(fell),
           "reason": fell[0]["reason"] if fell else None, "stitch": None, "structured": None}
    if guard is not None and len(pieces) > 1 and any(q["polish_in"] for q in out_pieces) and text != raw_all:
        fb = join_pieces([p.get("raw") or "" for p in pieces], pauses, fallback=True)
        g = guard(raw_all, text, fb) or {}
        if g.get("pass") is False:
            res.update(text=g.get("fallback_text") or fb or raw_all, fell_back=True,
                       reason="stitch_" + str(g.get("reason") or "guard"), stitch=g.get("reason") or "guard")
    res["light"] = res["text"]
    if structure is not None and res["text"].strip():
        s = structure(res["text"]) or {}
        res["structured"] = {**s, "input": res["text"]}
        if not s.get("fell_back") and (s.get("text") or "").strip():
            res["text"] = s["text"].strip()
    return res
