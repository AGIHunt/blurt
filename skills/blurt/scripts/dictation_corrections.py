"""Spoken self-corrections, resolved deterministically before polish (docs/design/dictation.md §Polish → Self-corrections).

「把这个，不对，这两个拿到那一边去」 should become 「把这两个拿到那一边去」. Gemma 4 E2B kept 「这个」 on the `say` clip, the
guard's `correction` check rightly refused that, and the transcript — 不对 and all — was typed. Most spoken corrections
have a shape simple enough to resolve without a model: the speaker restates the cancelled phrase, either from a word
it began with (the shared head: 「把这个」 / 「这两个…」 → 这个 is replaced) or as a value of the same kind (a weekday, a
number, a time, a day, a direction, a "this / these" phrase, an English name: "2:30, no wait, 3:30"). This pass does
only those, and only where a marker can't be content:

  • strong markers are only ever corrections: 我是说, 我的意思是, 说错了, 更正, 哦不, 哦不对, 哦不是, 不不, 不是不是,
    no wait, wait no, scratch that, make that, or rather;
  • 不对 / 错了 are corrections after a pause (a mark before them: 「…，不对，…」); with no mark before them
    (「把这个不对，这两个…」) only when the cancelled thing is a value at the very end of an unfinished phrase — the object
    of 把 / 给 / 放到 / 改成 … (never 「这个不对」, 「你写的周三不对，…」, 「我觉得这个不对，那个对」: those are content);
    with no mark on either side only for a time / number / weekday / day (「两点不对三点」);
  • 不是 only between two marks (「周三，不是，周四」; never 「我不是故意的」, 「是不是」, 「三不是四」);
  • 应该是, actually, I mean, sorry only after a mark and only for a value of the same kind.

What is removed is the cancelled span (≤ 8 units, the clause the marker ends), the marker and a lead-in (是, make it);
nothing else. Anything this can't resolve goes to polish as it was said (the model, its few-shot examples and the
guard handle it as before). Pure, < 1 ms; tests/test_polish.py::Corrections.
"""
from __future__ import annotations

import re
import unicodedata

_CJK = r"㐀-䶿一-鿿豈-﫿"
# a number with its separators is one unit here (2:30, 3.5, 1,000): the alignment compares values, not digits
_UNIT = re.compile(rf"[{_CJK}]|[A-Za-z]+(?:['’][A-Za-z]+)?|[0-9]+(?:[:.,][0-9]+)*")
# a pause in the transcript: punctuation (the speech model writes one where the speaker stopped)
_MARK = set("，,、。.;；!！?？:：…—\n")
_ENDS = set("。.!！?？\n")
_FILLER = re.compile(r"(?:\s|嗯+|呃+|额+|啊+|哦+|噢+|诶+|\b(?:um+|uh+|er+m*)\b)+", re.I)
_FILLER_END = re.compile(r"(?:\s|嗯+|呃+|额+|啊+|噢+|诶+|\b(?:um+|uh+|er+m*)\b)+$", re.I)

STRONG = ["我的意思是", "我是说", "说错了", "更正一下", "更正", "哦不对", "哦不是", "哦不", "不是不是", "不不不", "不不",
          "no wait", "wait no", "scratch that", "make that", "or rather"]
WEAK_BU = ["不对", "错了"]          # a correction after a pause; in a predicate's place only for an unfinished phrase
WEAK_BOTH = ["不是"]               # only between two marks
WEAK_SLOT = ["应该是", "actually", "i mean", "sorry"]    # only after a mark, only a value of the same kind
WEAK_LEFT = ["算了"]               # only after a mark (「改成蓝色，算了，还是改成绿色吧」), never as "forget it" alone
_ALL = sorted(STRONG + WEAK_BU + WEAK_BOTH + WEAK_SLOT + WEAK_LEFT, key=len, reverse=True)
_MARKER = re.compile(
    # the speech model writes 「哦不」 as 「哦，不，」 and "no wait" as "No, wait,"
    r"[哦噢][，,]\s*不(?:对|是)?(?=[，,。.\s])|\bno,\s*wait\b|"
    + "|".join(re.escape(m) if re.match(r"[a-z]", m) is None else r"\b" + re.escape(m).replace(r"\ ", r"\s+") + r"\b"
               for m in _ALL), re.I)
# 不对称 / 不对劲 … and 不对的 (an adjective) are words, not "no wait"
_NOT_MARKER_AFTER = {"不对": "称劲外应头付的", "错了": "的"}
# words that lead into the restated version: 不对，是周四 / no wait, make it 3:30
_LEAD = re.compile(r"(?:应该是|改成|换成|改为|改到|还是|就是|是|make it|it's|it is|that's|say|to|at|on|in|the)\s*", re.I)
# what a cancelled value may follow when the marker sits where a predicate could (no mark before it): a coverb or a
# verb + complement that needs more after its object (把这个 / 发给张三 / 放到左边 / 改成三点 …)
_OPEN_BEFORE = ("把", "将", "给", "跟", "和", "同", "与", "对", "从", "往", "向", "朝", "到", "在", "用", "让", "被", "叫",
                "帮", "替", "为", "放", "拿", "发", "交", "改", "换", "成", "订", "约", "定", "买", "选", "要", "是", "于")
_MAX_CANCEL = 8

# ------------------------------------------------------------------ values ("slots") a correction can swap
_N = "零〇一二两三四五六七八九十百千万亿"
_SLOTS = [
    ("weekday", rf"(?:下下|上|下|这|本)?个?(?:周|星期|礼拜)[一二三四五六日天1-7]"),
    ("weekday", r"\b(?:next |this |last )?(?:mon|tues|wednes|thurs|fri|satur|sun)day\b"),
    ("day", r"大后天|后天|明天|今天|昨天|前天|今晚|明晚|明早|\btoday\b|\btomorrow\b|\btonight\b|\byesterday\b"),
    ("period", r"上午|下午|中午|晚上|早上|凌晨|傍晚|\bmorning\b|\bafternoon\b|\bevening\b"),
    ("time", rf"[{_N}\d]{{1,3}}点(?:半|一刻|三刻|[{_N}\d]{{1,3}}分?)?"),
    ("time", r"\b\d{1,2}(?::\d{2})?\s?(?:am|pm|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b"),
    # "two thirty", "three o'clock", "five fifteen pm" (how the speech model writes a time it heard in words)
    ("time", r"\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?:[\s-](?:o'clock|fifteen|thirty|"
             r"forty[\s-]five|oh[\s-]five|ten|twenty|forty|fifty))(?:\s?(?:am|pm))?\b|"
             r"\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s?(?:am|pm)\b"),
    ("date", rf"[{_N}\d]{{1,3}}月(?:[{_N}\d]{{1,3}}[号日])?|[{_N}\d]{{1,3}}号"),
    ("demonstrative", r"(?:这|那)(?:[一两二三四五六七八九十几]+)?(?:个|些|张|份|件|条|台|本|篇|段|种|次|位|样|块|批|组)|这些|那些|这里|那里|这边|那边"),
    ("demonstrative", r"\b(?:this|that|these|those)(?: ones?)?\b"),
    ("direction", r"左手边|右手边|左边|右边|上边|下边|上面|下面|前面|后面|里面|外面|左侧|右侧|东边|西边|南边|北边|\bleft\b|\bright\b|\btop\b|\bbottom\b"),
    ("number", rf"\d+(?:[.,]\d+)?%?|[{_N}点]{{2,}}(?:个|位|张|份|件|条|台|本|块|元|人|次|天|分钟|小时|岁|倍|遍|页)?|[{_N}](?:个|位|张|份|件|条|台|本|块|元|人|次|天|分钟|小时|岁|倍|遍|页)"),
    ("number", r"\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|hundred|thousand)\b"),
    ("name", r"(?<![.!?]\s)(?<=\s)[A-Z][a-z]+\b"),
]
_SLOT_RE = [(k, re.compile(p, re.I if k != "name" else 0)) for k, p in _SLOTS]
_STRICT_KINDS = {"time", "number", "weekday", "day", "date", "period"}   # with no mark on either side


def _units(text: str, a: int = 0, b: int | None = None) -> list[tuple[str, int, int]]:
    b = len(text) if b is None else b
    return [(unicodedata.normalize("NFKC", m.group()).lower(), m.start(), m.end()) for m in _UNIT.finditer(text, a, b)]


def _slots(text: str, a: int, b: int) -> list[tuple[str, int, int]]:
    """(kind, start, end) of the values in text[a:b], longest first where they overlap, in order."""
    found = []
    for kind, rx in _SLOT_RE:
        for m in rx.finditer(text, a, b):
            if m.end() > m.start() and m.group().strip():
                found.append((kind, m.start(), m.end()))
    found.sort(key=lambda s: (s[1], -(s[2] - s[1])))
    out, last = [], -1
    for s in found:
        if s[1] >= last:
            out.append(s)
            last = s[2]
    return out


def _run(slots: list, i: int, text: str) -> tuple[int, int]:
    """Consecutive values from slots[i] (周三下午, 下午两点): (start, end) of the run."""
    start, end = slots[i][1], slots[i][2]
    for k in range(i + 1, len(slots)):
        if text[end:slots[k][1]].strip():
            break
        end = slots[k][2]
    return start, end


def _is_mark(text: str, i: int) -> bool:
    """text[i] is a pause mark — not the : . , inside a number (2:30, 3.5, 1,000)."""
    c = text[i]
    if c not in _MARK:
        return False
    return not (c in ":.," and 0 < i < len(text) - 1 and text[i - 1].isdigit() and text[i + 1].isdigit())


def _skip_seps(text: str, i: int) -> tuple[int, bool]:
    """From i over spaces, marks and fillers → (where the words start, whether a mark was crossed)."""
    mark = False
    while i < len(text):
        m = _FILLER.match(text, i)
        if m and m.end() > i:
            i = m.end()
            continue
        if _is_mark(text, i):
            mark = True
            i += 1
            continue
        break
    return i, mark


def _back_seps(text: str, i: int) -> tuple[int, bool]:
    mark = False
    while i > 0:
        m = _FILLER_END.search(text, 0, i)
        if m and m.end() == i and m.start() < i:
            i = m.start()
            continue
        if _is_mark(text, i - 1):
            mark = True
            i -= 1
            continue
        break
    return i, mark


def _clause_start(text: str, i: int) -> int:
    """Where the sentence holding position i starts (B, the cancelled side, never reaches into the one before)."""
    j = i
    while j > 0 and not (text[j - 1] in _ENDS and _is_mark(text, j - 1)):
        j -= 1
    return j


def _clause_end(text: str, i: int) -> int:
    j = i
    while j < len(text) and not _is_mark(text, j):
        j += 1
    return j


def _cap(prefix: str, s: str, like: str) -> str:
    """A replacement at the start of a sentence keeps the capital the cancelled words had."""
    if (not prefix.strip() or prefix.rstrip()[-1:] in _ENDS) and like[:1].isupper() and s[:1].islower():
        return s[0].upper() + s[1:]
    return s


def _resolve_one(text: str, m: re.Match) -> tuple[str, dict] | None:
    marker = m.group().lower()
    marker = re.sub(r"\s+", " ", marker)
    marker = re.sub(r"^([哦噢])[，,]\s*", r"\1", marker).replace("no,", "no")
    nxt = text[m.end():m.end() + 1]
    if marker in _NOT_MARKER_AFTER and nxt and nxt in _NOT_MARKER_AFTER[marker]:
        return None
    b_end, left = _back_seps(text, m.start())
    a_start, right = _skip_seps(text, m.end())
    if m.start() == 0 or b_end == 0:
        return None
    strong = marker in STRONG
    if marker in WEAK_BOTH and not (left and right):
        return None
    if (marker in WEAK_SLOT or marker in WEAK_LEFT) and not left:
        return None
    if marker in WEAK_BU and not left and not right:
        mode = "strict"          # 两点不对三点: only a time / number … at the end
    elif marker in WEAK_BU and not left:
        mode = "end"             # 把这个不对，这两个…: only a value at the end of an unfinished phrase
    else:
        mode = "any"
    b_start = _clause_start(text, b_end)
    bu = _units(text, b_start, b_end)
    a_end = _clause_end(text, a_start)
    au = _units(text, a_start, a_end)
    if not bu or not au:
        return None
    bv, av = [u for u, _, _ in bu], [u for u, _, _ in au]

    def done(cut: int, keep_from: int, how: str, tail: str = "") -> tuple[str, dict]:
        prefix = text[:cut]
        body = text[keep_from:a_end]
        body = _cap(prefix, body, text[cut:cut + 1])
        if prefix and body and re.search(r"[A-Za-z0-9]$", prefix) and re.match(r"[A-Za-z0-9]", body):
            prefix += " "
        if prefix.endswith(" ") and body[:1] == " ":
            body = body.lstrip()
        out = prefix + body + tail + text[a_end:]
        return out, {"marker": m.group(), "cancelled": text[cut:b_end].strip(), "said": text[keep_from:a_end].strip(),
                     "how": how}

    def frame(i: int, jmin: int, a_from: int, how: str = "frame") -> tuple[str, dict] | None:
        """The restated phrase ends on the unit the cancelled one ended on, and the cancelled clause went on: only that
        part is swapped and the rest stays (「订一张去上海的票，不对，去杭州的」 → 订一张去杭州的票, 「晚上发群里，不对，
        下午就发」 → 下午就发群里)."""
        a_units = _units(text, a_from, a_end)
        if len(a_units) < 2:
            return None
        for j in range(max(jmin, i + 1), len(bv) - 1):
            if bv[j] == a_units[-1][0] and abs((j - i + 1) - len(a_units)) <= 1 and j - i + 1 <= 6:
                cut = bu[i][1]
                out = text[:cut] + text[a_from:a_end] + text[bu[j + 1][1]:b_end].rstrip() + text[a_end:]
                return out, {"marker": m.group(), "cancelled": text[cut:bu[j][2]], "said": text[a_from:a_end], "how": how}
        return None

    # 1. a value of the same kind (weekday, number, time, direction …): 「周三开会，不对，周四」 → 周四开会
    starts = [a_start]          # where the restated words may begin: after each lead-in word (还是 改成 绿色)
    lead = _LEAD.match(text, a_start)
    while lead and lead.end() > starts[-1] and lead.end() < a_end:
        starts.append(lead.end())
        lead = _LEAD.match(text, starts[-1])
    a2 = starts[-1]
    for a_from in starts:
        sa = _slots(text, a_from, a_end)
        if not sa or sa[0][1] != a_from:
            continue
        kind = sa[0][0]
        if mode == "strict" and kind not in _STRICT_KINDS:
            continue
        sb = _slots(text, b_start, b_end)
        cands = [i for i, s in enumerate(sb) if s[0] == kind]
        if not cands:
            continue
        i = cands[-1]
        rs, re_ = _run(sb, i, text)
        ras, rae = _run(sa, 0, text)
        if text[rs:re_].strip().lower() == text[ras:rae].strip().lower():
            continue
        if len(_units(text, rs, b_end)) > _MAX_CANCEL:
            continue
        rest_b = text[re_:b_end]
        if marker in WEAK_SLOT and _units(text, re_, b_end):
            continue             # 应该是 / sorry …: only right after the value (「你写的周三不对，应该是周四」 is content)
        if mode != "any":
            if _units(text, re_, b_end):
                continue         # the value isn't at the end: 「这个颜色不对，…」 is content
            before = text[b_start:rs].rstrip()
            # a time / number / weekday after a short subject that has no verb yet (我们周三不对，周四开会; 我们下午
            # 两点不对，三点…), never a description of one (你写的周三不对 / 答案是三不对)
            short = kind in _STRICT_KINDS and len(bu) <= 6 and not before.endswith(("的", "是"))
            if not before or not (before.endswith(_OPEN_BEFORE) or (kind in _STRICT_KINDS and mode == "strict") or short):
                continue
        only = not _units(text, rae, a_end)
        if only and _units(text, re_, b_end):
            # the restated value alone: the rest of the cancelled clause stays (周三开会，不对，周四 → 周四开会)
            out, rec = done(rs, ras, "slot", tail="")
            # put the clause's remainder right after the new value
            prefix = text[:rs]
            val = _cap(prefix, text[ras:rae], text[rs:rs + 1])
            sep = " " if re.search(r"[A-Za-z0-9]$", prefix) and re.match(r"[A-Za-z0-9]", val) else ""
            out = prefix + sep + val + rest_b.rstrip() + text[rae:a_end] + text[a_end:]
            rec.update(said=text[ras:rae], cancelled=text[rs:re_])
            return out, rec
        bi = next((n for n, u in enumerate(bu) if u[1] >= rs), None)
        if bi is not None and (f := frame(bi, next((n for n, u in enumerate(bu) if u[1] >= re_), len(bu)), ras, "slot")):
            return f
        return done(rs, ras, "slot")
    if mode != "any":
        # an unfinished phrase restated from a word right before the value: 放到左边不对，放到右边
        sb = _slots(text, b_start, b_end)
        if sb and not _units(text, sb[-1][2], b_end):
            s_start = sb[-1][1]
            head = [u for u in bu if u[1] < s_start][-3:]
            for k in range(len(head), 0, -1):
                h = head[-k:]
                if [u for u, _, _ in h] == av[:k] and len(au) > k:
                    sa = _slots(text, au[k][1], a_end)
                    if sa and sa[0][1] == au[k][1] and sa[0][0] == sb[-1][0]:
                        before = text[b_start:h[0][1]].rstrip()
                        if before and len(_units(text, h[0][1], b_end)) <= _MAX_CANCEL:
                            return done(h[0][1], a_start, "head")
        # the same frame said again with one part swapped: 用 Claude 写不对，用 Codex 写… (head 用, tail 写)
        if mode == "end" and len(bv) >= 3:
            for k in range(min(3, len(av) - 2), 0, -1):
                for i in range(len(bv) - k - 1, -1, -1):
                    if bv[i:i + k] != av[:k]:
                        continue
                    x = bv[i + k:-1]
                    tail = next((q for q in range(k + 1, min(len(av), k + 6)) if av[q] == bv[-1]), None)
                    y = av[k:tail] if tail is not None else []
                    # only one part swapped, about as long (Claude → Codex), nothing of it kept: 「你这样写不对，你应该
                    # 这样写」 and 「这个颜色不对，这个要改成红色」 are content
                    if x and y and len(x) <= 4 and abs(len(y) - len(x)) <= 1 and not set(x) & set(y) \
                            and len(bv) - i <= _MAX_CANCEL:
                        return done(bu[i][1], a_start, "head")
        return None
    if marker in WEAK_SLOT:
        return None
    # 2. restated from a word the cancelled phrase began with: 「把这个，不对，这两个…」, 「发给张三，哦不，发给李四」
    # (after a lead-in too: 「改成蓝色，算了，还是改成绿色吧」)
    for a_from in starts:
        aw = [u for u, _, _ in _units(text, a_from, a_end)]
        for k in range(min(len(aw), len(bv)), 0, -1):
            for i in range(len(bv) - k, -1, -1):
                if bv[i:i + k] != aw[:k]:
                    continue
                cancel = bv[i:]
                if aw[:len(cancel)] == cancel:
                    continue     # restated word for word and more: nothing was taken back (这个方案不对，这个方案要改)
                if len(aw) < len(cancel) and (f := frame(i, i + k, a_from)):
                    return f
                if len(cancel) > (4 if k == 1 else _MAX_CANCEL):
                    continue
                return done(bu[i][1], a_from, "head")
    return None


def resolve(text: str) -> tuple[str, list[dict]]:
    """→ (the text with every correction this can resolve applied, what was resolved). Unresolved markers stay."""
    out, done = text or "", []
    start = 0
    for _ in range(6):
        hit = None
        for m in _MARKER.finditer(out, start):
            r = _resolve_one(out, m)
            if r:
                hit = r
                break
        if not hit:
            break
        out, rec = hit
        done.append(rec)
    return out, done


if __name__ == "__main__":
    import sys
    for line in sys.argv[1:]:
        print(resolve(line))
