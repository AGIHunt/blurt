"""BlurtCore's DictationStitch and DictationStream's polish windows, ported (docs/design/dictation.md §Streaming), so
the Dictation Lab can replay a take the way the app polishes it while the user talks (`mode=windows`): each piece
polished in a window with the clause carried from the window before, what polish wrote up to its last comma or
sentence end committed, the dictation's text so far sent along as context, and the joined result checked once more
against the joined transcript. The same rules as the Swift code (DictationStitchTests; tests/test_dictation_stitch.py
holds the shared cases): keep the two in step.
"""
from __future__ import annotations

import re
import unicodedata

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


_SC_FILLERS = ["嗯", "呃", "啊", "额", "哦", "噢", "um", "uh", "er"]
_SC_ZH = ["不对", "不是不是", "哦不是", "我是说", "我的意思是", "更正", "算了", "说错了", "应该是"]
_SC_EN = ["no wait", "wait no", "i mean", "sorry", "actually", "scratch that", "make that", "rather"]
_SC_WORDS = ["不对称", "不对劲", "不对外", "不对应", "不对头", "不对付", "不是很", "不是所有", "不是每"]


def starts_with_correction(text: str) -> bool:
    t = (text or "").strip().lower()
    while t and not (t[0].isalpha() or t[0].isdigit()):
        t = t[1:]
    for f in _SC_FILLERS:
        if t.startswith(f):
            t = t[len(f):]
            while t and not (t[0].isalpha() or t[0].isdigit()):
                t = t[1:]
    if any(t.startswith(w) for w in _SC_WORDS):
        return False
    if any(t.startswith(z) for z in _SC_ZH):
        return True
    return any(t.startswith(e) and (len(t) == len(e) or not t[len(e)].isalpha()) for e in _SC_EN)


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


def last_sentence(core: str) -> str:
    idx = max((i for i, c in enumerate(core) if c in _TERMINATORS), default=-1)
    return core[idx + 1:]


OPEN_ENDS_ZH = ["的时候", "时候", "以后", "之后", "之前", "的话", "因为", "所以", "但是", "可是", "然后", "而且", "如果", "还是",
                "或者", "就是", "还有", "以及", "比如", "不过", "那么", "这个", "那个", "一个", "我们", "你们", "他们", "也", "都",
                "就", "还", "又", "再", "才", "把", "被", "给", "从", "向", "往", "在", "是", "和", "跟", "与", "或", "而", "但",
                "且", "让", "将", "比", "为", "若", "嗯", "呃", "额"]
OPEN_STARTS_ZH = ["但是", "可是", "所以", "因为", "然后", "而且", "如果", "不过", "那么", "就是"]
OPEN_ENDS_EN = {"and", "or", "but", "so", "because", "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from",
                "that", "which", "who", "whose", "if", "when", "while", "where", "is", "are", "was", "were", "be", "been",
                "am", "i", "we", "you", "they", "he", "she", "my", "your", "our", "their", "his", "her", "its", "this",
                "these", "those", "than", "as", "by", "about", "into", "then", "also", "just", "like", "um", "uh", "er",
                "very", "really", "not", "until", "since", "although", "though", "whether", "both", "either", "neither",
                "some", "any"}
OPEN_STARTS_EN = {"but", "so", "and", "because", "then", "or", "if", "when"}
# a fall-back's seam: no comma after a word that binds to what follows (把 / 的 / to / the …)
BINDING_ZH = ["把", "被", "给", "从", "向", "往", "在", "是", "和", "跟", "与", "或", "让", "将", "比", "为", "对", "的", "这个",
              "那个", "一个", "我们", "你们", "他们", "也", "都", "就", "还", "又", "再", "才", "嗯", "呃", "额"]


def plausibly_final(core: str, end: str) -> bool:
    if not any(c in _TERMINATORS for c in end):
        return False
    sentence = last_sentence(core).strip()
    u = units(sentence)
    if not u:
        return False
    if ends_cjk(sentence):
        if len(u) < 4 or any(sentence.endswith(w) for w in OPEN_ENDS_ZH):
            return False
        if len(u) <= 5 and any(sentence.startswith(w) for w in OPEN_STARTS_ZH):
            return False
    else:
        if len(u) < 3 or u[-1] in OPEN_ENDS_EN:
            return False
        if len(u) <= 4 and u[0] in OPEN_STARTS_EN:
            return False
    return True


ORDINARY = set("""the a an and or but so because then also just that this these those there here it its it's we we're
we'll you you're they they're he she me us them my your our their his her what which who when where why how if is are
was were be been am do does did don't doesn't didn't have has had will would can could should may might must won't
can't not no yes to of in on at for with from by about as than like into after before while until since all some any
each every more most much many very really maybe still even only well now later today tomorrow make made take get got
go going see look let send add use try want need know think say said tell ask give keep put set run move check fix
write read start finish open close show find work please thanks thank okay ok one two three first next last other
another same both either neither whether though although once again too already always never sometimes something
anything everything nothing someone everyone anyone otherwise instead actually probably definitely especially myself
second third fourth fifth finally lastly firstly secondly
yourself itself ourselves themselves don’t it’s we’re you’re they’re being""".split())


def decapitalize(text: str, names: set[str] | None = None) -> str:
    if not text or not text[0].isupper() or not _word_char(text[0]):
        return text
    end = 0
    while end < len(text) and (text[end].isalpha() or text[end] in "'’"):
        end += 1
    word = text[:end]
    if word == "I" or word.startswith(("I'", "I’")) or word in (names or set()) or any(c.isupper() for c in word[1:]) \
            or word.lower() not in ORDINARY:
        return text
    return word.lower() + text[end:]


def seam(previous: str, nxt: str, pause: float | None, names: set[str] | None = None) -> tuple[str, str]:
    core, end = split_trailing(previous)
    if not core:
        return previous, nxt
    if pause is not None and pause >= LONG_PAUSE:
        if plausibly_final(core, end):
            return core + terminator(end, core), nxt
        if end:
            return core + ("，" if ends_cjk(core) else ","), decapitalize(nxt, names)
    return core, decapitalize(nxt, names)


def binds(text: str) -> bool:
    """The text ends on a word that needs what comes next (把, 的, to, the …): no comma after it."""
    t = (text or "").rstrip()
    if ends_cjk(t):
        return any(t.endswith(w) for w in BINDING_ZH)
    u = units(t)
    return bool(u) and u[-1] in OPEN_ENDS_EN


def fallback_seam(previous: str, nxt: str, pause: float | None, heard_end: str, names: set[str] | None = None) -> str:
    """Where a polish window fell back to the transcript: the seam still gets its punctuation — a long pause the seam
    rule's, and a short one a comma where the speech model heard a boundary (it ended the piece with a mark), unless
    the text before binds to the next words. Without it the take read 「…跑完第二，…」."""
    core, end = split_trailing(previous)
    if not core:
        return join(previous, nxt)
    if pause is not None and pause >= LONG_PAUSE:
        a, b = seam(core + (end or heard_end), nxt, pause, names)
        return join(a, b)
    if (end or heard_end) and not binds(core):
        return core + ("，" if ends_cjk(core) else ",") + (" " if not ends_cjk(core) else "") + decapitalize(nxt, names).lstrip()
    return join(core, decapitalize(nxt, names))


def join_pieces(texts: list[str], pauses: list[float | None], names: set[str] | None = None,
                fallback: bool = False) -> str:
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
            acc = fallback_seam(acc, t, after, after_end, names)
        else:
            a, b = seam(acc, t, after, names)
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


_EC_ZH = ["不对", "不是不是", "哦不是", "哦不", "我是说", "我的意思是", "更正", "说错了", "算了"]
_EC_EN = ["no wait", "wait no", "no, wait", "i mean", "scratch that", "make that", "or rather", "sorry"]


def ends_with_correction(text: str) -> bool:
    """The piece ends on a self-correction marker: its restatement is in the next piece (the window is carried whole)."""
    t = (text or "").strip().lower()
    while t and not (t[-1].isalpha() or t[-1].isdigit()):
        t = t[:-1]
    for f in ("嗯", "呃", "啊", "额"):
        if t.endswith(f):
            t = t[:-len(f)]
    while t and not (t[-1].isalpha() or t[-1].isdigit()):
        t = t[:-1]
    if any(t.endswith(z) for z in _EC_ZH):
        return True
    return any(t.endswith(e) and (len(t) == len(e) or not t[-len(e) - 1].isalpha()) for e in _EC_EN)


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


def comma_join(a: str, b: str) -> str:
    """Two parts with a pause between them that ended nothing: a comma unless `a` already ends in punctuation."""
    a = (a or "").strip()
    if not a:
        return (b or "").strip()
    if a[-1] in _TRAILING:
        return join(a, b)
    return a + ("，" if ends_cjk(a) else ", ") + (b or "").strip()


# ------------------------------------------------------------------ DictationStream's polish windows
def stream(pieces: list[dict], pauses: list[float | None], polish, guard=None, context: dict | None = None,
           names: set[str] | None = None, legacy: bool = False) -> dict:
    """Replay the app's windows. pieces: [{"raw"}] (the transcript of each piece, in order; the last one is where the
    dictation ended); polish(text, context) → polish.py's answer; guard(raw, output, fallback) → the stitch guard's.
    `legacy`: the windows as they were before v0.8.x (the text so far appended to the field's "before", no seam
    punctuation for a fall-back, no comma at a merged correction, the model's capital kept): the lab's "before".
    → {"text", "raw", "pieces": [{"polish_in", "text", "fell_back", "reason", "ms", "echo"}], "fell_back", "reason",
    "stitch"}."""
    names = names or set()
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
        inp, prefix, merged = carry, "", None
        prev = out_pieces[idx - 1] if idx > 0 else None
        g_prev = pauses[idx - 1] if idx > 0 and idx - 1 < len(pauses) else None
        if prev is not None and starts_with_correction(raw) and not (not prev["text"] and not carry):
            inp = join(prev["text"], carry)
            merged = prev
        elif carry and g_prev is not None and g_prev >= LONG_PAUSE and \
                plausibly_final(join_all([q["text"] for q in out_pieces[:idx]] + [carry]), carry_end or "。"):
            prefix = carry + terminator(carry_end, carry)
            inp = ""
        carry_in = inp
        carry = carry_end = ""
        if not legacy and (merged is not None or ends_with_correction(carry_in)):
            inp = comma_join(inp, core)          # the pause around 不对 is a mark: the corrections pass needs it
        else:
            inp = join(inp, decapitalize(core, names) if inp else core)
        up_to = merged["index"] if merged is not None else idx
        done = [q["text"] for q in out_pieces[:up_to]] + [prefix]
        ctx = dict(context or {})
        so = join_all(done)
        if so:
            if legacy:
                ctx["before"] = join(ctx.get("before") or "", so)
            else:
                ctx["dictated"] = so
        rec["polish_in"] = inp
        if not legacy and not last and merged is None and ends_with_correction(inp):
            # 「…晚上发群里，不对。」 + a pause: the restatement is in the next piece — carried whole, polished with it
            rec.update(text=prefix, deferred=True)
            carry, carry_end = inp, ""
            continue
        r = polish(inp, ctx or None) or {}
        rec.update(fell_back=bool(r.get("fell_back")), reason=r.get("reason") if r.get("fell_back") else None,
                   ms=int(r.get("ms") or 0), echo=r.get("echo"), polished=r.get("polished"),
                   corrections=r.get("corrections"))
        out = (r.get("text") or "").strip() or inp
        if not legacy:
            if rec["fell_back"] and carry_in and merged is None and out.startswith(carry_in):
                # the window fell back: its seam (the pause before this piece) still gets its punctuation
                heard = split_trailing(pieces[idx - 1].get("raw") or "")[1] if idx > 0 else ""
                out = fallback_seam(carry_in, out[len(carry_in):], g_prev, heard, names)
            if mid_sentence(so) and not rec["fell_back"]:
                out = decapitalize(keep_case(inp, out), names)   # the model capitalised a window that continues one
        if merged is not None:
            merged["text"] = ""
        if last:
            rec["text"] = join(prefix, out)
        else:
            commit, carry, carry_end = commit_split(out)
            rec["text"] = join(prefix, commit)
    raw_all = join_pieces([p.get("raw") or "" for p in pieces], pauses, names)
    text = join_all([q["text"] for q in out_pieces] + [carry + carry_end])
    fell = [q for q in out_pieces if q["fell_back"]]
    res = {"text": text or raw_all, "raw": raw_all, "pieces": out_pieces, "fell_back": bool(fell),
           "reason": fell[0]["reason"] if fell else None, "stitch": None}
    if guard is not None and len(pieces) > 1 and any(q["polish_in"] for q in out_pieces) and text != raw_all:
        fb = None if legacy else join_pieces([p.get("raw") or "" for p in pieces], pauses, names, fallback=True)
        g = guard(raw_all, text, fb) or {}
        if g.get("pass") is False:
            res.update(text=(g.get("fallback_text") or fb or raw_all) if not legacy else raw_all, fell_back=True,
                       reason="stitch_" + str(g.get("reason") or "guard"), stitch=g.get("reason") or "guard")
    return res
