#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# ///
"""Dictation styles for tools outside the app (docs/design/dictation-styles.md §3): the Structured style's list
renderer, the category variants of light and the app → category table — the same rules as
BlurtCore's DictationList.swift / DictationStyle.swift. The shared fixture
tests/fixtures/dictation_lists.jsonl checks both. The Dictation Lab (dictation_lab.py) re-runs a case per style with
these.

  dictation_styles.py render --text "…" [--min 2]      the list (or the text unchanged), as JSON
  dictation_styles.py style --text "…" --style structured [--category chat]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata

STYLES = ("verbatim", "light", "structured", "auto")
CATEGORIES = ("chat", "code", "mail", "notes", "other")
ASKED_MARKERS = 2
AUTO_MARKERS = 3


def list_markers(style: str) -> int | None:
    return {"structured": ASKED_MARKERS, "auto": AUTO_MARKERS}.get(style)


# ------------------------------------------------------------------ units (DictationStitch.units)
def _cjk(c: str) -> bool:
    o = ord(c)
    return 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x3040 <= o <= 0x30FF or 0xAC00 <= o <= 0xD7AF


def units(text: str) -> list[str]:
    """Each CJK character, each digit, each Latin word (an apostrophe inside it kept)."""
    out, i, t = [], 0, text or ""
    while i < len(t):
        c = t[i]
        if _cjk(c) or c.isdigit():
            out.append(c.lower())
            i += 1
        elif c.isalpha():
            j = i + 1
            while j < len(t) and t[j].isalpha() and not _cjk(t[j]):
                j += 1
            if j + 1 < len(t) and t[j] in "'’" and t[j + 1].isalpha() and not _cjk(t[j + 1]):
                j += 1
                while j < len(t) and t[j].isalpha() and not _cjk(t[j]):
                    j += 1
            out.append(t[i:j].lower())
            i = j
        else:
            i += 1
    return out


# ------------------------------------------------------------------ the list renderer (DictationList.swift)
_CN = "一二三四五六七八九十"
_TAIL = r"[，,、：:\s]*"
_EN_ORD = {"first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4,
           "fifth": 5, "fifthly": 5, "finally": 0, "lastly": 0, "last": 0}
_EN_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}


def _cn_number(s: str) -> int | None:
    d = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
    if s == "十":
        return 10
    if len(s) == 2 and s[0] == "十" and s[1] in d:
        return 10 + d[s[1]]
    return d.get(s) if len(s) == 1 else None


def _seq(m):
    w = m.group(1)
    o = 1 if w == "首先" else 2 if w == "其次" else 3 if w == "再次" else 0 if w.startswith("最后") else -1
    return ("seq", o, True)


# (pattern, flags, make(match) → (family, ordinal, zh) | None)
_PATTERNS = [
    (rf"第(十[一二三四五六七八九]|[{_CN}])(?:个|点|条|步|项|件|部分)?(?:是|就是|呢)?(?![次天名年批轮届期章页句位周月季代层排场手眼印时把]){_TAIL}", 0,
     lambda m: ("di", n, True) if (n := _cn_number(m.group(1))) else None),
    (rf"([{_CN}])(是|来){_TAIL}", 0,
     lambda m: ("shi" if m.group(2) == "是" else "lai", n, True) if (n := _cn_number(m.group(1))) else None),
    (rf"其([{_CN}]){_TAIL}", 0, lambda m: ("qi", n, True) if (n := _cn_number(m.group(1))) else None),
    (rf"([{_CN}])[、．.:：，,]\s*", 0, lambda m: ("num", n, True) if (n := _cn_number(m.group(1))) else None),
    (r"([0-9]{1,2})[、．.:：)）](?![0-9])\s*", 0, lambda m: ("digit", int(m.group(1)), False)),
    (rf"(首先|其次|再次|最后(?:一点|一个|一条|就是)?|然后|接着|另外|还有|此外){_TAIL}", 0, _seq),
    (r"(?:and\s+)?(first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?|finally|lastly)(?:\s+of\s+all)?(?![a-z’'])"
     r"(?!\s+(?:time|times|place|day|days|name|class|prize|floor|half|quarter|impression|hand|person|of|and|or|thing)\b)[,:]?\s*",
     re.I, lambda m: ("en_ord", _EN_ORD[m.group(1).lower()], False)),
    (r"(last)[,:]\s*", re.I, lambda m: ("en_ord", 0, False)),
    (r"(then|next|also|and then)\b,?\s*", re.I, lambda m: ("en_ord", -1, False)),
    (r"number\s+(one|two|three|four|five|six|seven|eight|nine|ten)\b[,:]?\s*", re.I,
     lambda m: ("en_num", _EN_NUM[m.group(1).lower()], False)),
    (r"(one|two|three|four|five|six|seven|eight|nine|ten)[,:]\s+", re.I, lambda m: ("en_word", _EN_NUM[m.group(1).lower()], False)),
]
_COMPILED = [(re.compile(p, f), make) for p, f, make in _PATTERNS]
_CLAUSE_ENDS = set("。，,、；;：:！!？?\n.")


def _clause_start(t: str, loc: int) -> bool:
    i = loc - 1
    while i >= 0 and t[i] in " \t":
        i -= 1
    if i < 0:
        return True
    if t[i] == ".":
        return i == 0 or not t[i - 1].isdigit()
    return t[i] in _CLAUSE_ENDS


def _strong_inside(family: str, ordinal: int, zh: bool, phrase: str) -> bool:
    """A later marker where a seam lost its punctuation: 第二… / 其次 / 最后, Second / Finally (a capital), then a
    comma or colon."""
    if not (ordinal >= 2 or ordinal == 0) or family not in ("di", "seq", "en_ord"):
        return False
    p = phrase.strip()
    if not p or p[-1] not in "，,：:":
        return False
    return True if zh else phrase[:1].isupper()


def candidates(text: str) -> list[dict]:
    out = []
    for rx, make in _COMPILED:
        for m in rx.finditer(text):
            mk = make(m)
            if not mk:
                continue
            fam, ordinal, zh = mk
            if not _clause_start(text, m.start()) and not _strong_inside(fam, ordinal, zh, m.group(0)):
                continue
            if not zh and m.start() > 0 and text[m.start() - 1].isalpha():
                continue
            out.append({"family": fam, "ordinal": ordinal, "zh": zh, "start": m.start(), "end": m.end()})
    out.sort(key=lambda x: (x["start"], -(x["end"] - x["start"])))
    kept: list[dict] = []
    for m in out:
        if not kept or kept[-1]["end"] <= m["start"]:
            kept.append(m)
    return kept


def best_run(ms: list[dict]) -> list[dict]:
    best: list[dict] = []
    for i, first in enumerate(ms):
        if first["ordinal"] != 1:
            continue
        run, closed = [first], False
        for m in ms[i + 1:]:
            if m["family"] == first["family"] and m["ordinal"] == run[-1]["ordinal"] + 1 and run[-1]["ordinal"] > 0:
                run.append(m)
                continue
            if m["ordinal"] == 0 and m["zh"] == first["zh"] and run[-1]["ordinal"] > 0:
                run.append(m)
                closed = True
                break
            if m["family"] == first["family"] and m["ordinal"] == 1:
                break
        if closed and len(run) == 2 and first["family"] in ("seq", "en_ord"):
            lo, hi = run[0]["end"], run[1]["start"]
            inner = [m for m in ms if m["ordinal"] == -1 and m["family"] == first["family"] and lo <= m["start"] < hi]
            if inner:
                run = [run[0], *inner, run[1]]
        if len(run) > len(best):
            best = run
    return best


_LEAD = set("，,、：:；;。. \t\n")
_TRAIL = set("，,、：:；;。. \t\n")       # the Swift side trims the leading set at both ends, then these


def _clean_item(s: str) -> str:
    i = 0
    while i < len(s) and s[i] in _LEAD:
        i += 1
    t = s[i:]
    while t and t[-1] in _TRAIL:
        t = t[:-1]
    t = t.replace("\n", " ")
    if t and t[0].isascii() and t[0].islower():
        t = t[0].upper() + t[1:]
    return t


def _last_item_end(t: str, start: int) -> int:
    for i in range(start, len(t)):
        c = t[i]
        if c in "。！？!?\n":
            return i + 1
        if c == "." and (i + 1 >= len(t) or t[i + 1] in " \n"):
            if i == 0 or not t[i - 1].isdigit() or i + 1 >= len(t):
                return i + 1
    return len(t)


def detect(text: str) -> dict | None:
    """{"markers", "intro", "items", "outro", "removed"} for the spoken list in `text`, or None."""
    t = text or ""
    run = best_run(candidates(t))
    if len(run) < ASKED_MARKERS:
        return None
    items = []
    for k, m in enumerate(run):
        start = m["end"]
        end = run[k + 1]["start"] if k + 1 < len(run) else _last_item_end(t, start)
        if end < start:
            return None
        item = _clean_item(t[start:end])
        if len(units(item)) < 2:
            return None
        items.append(item)
    last_end = _last_item_end(t, run[-1]["end"])
    intro = t[:run[0]["start"]].strip()
    while intro and intro[-1] in "，,；;：:。.、":
        intro = intro[:-1]
    if intro and intro[-1] not in "？?！!":
        intro += "：" if any(_cjk(c) for c in intro) else ":"
    return {"markers": len(run), "intro": intro, "items": items, "outro": t[last_end:].strip(),
            "removed": [t[m["start"]:m["end"]].strip(" \t") for m in run]}


def markers(text: str) -> int:
    d = detect(text)
    return d["markers"] if d else 0


def render(text: str, min_markers: int = ASKED_MARKERS) -> str | None:
    d = detect(text)
    if not d or d["markers"] < min_markers:
        return None
    lines = ([d["intro"]] if d["intro"] else []) + [f"{i + 1}. {it}" for i, it in enumerate(d["items"])]
    if d["outro"]:
        lines.append(d["outro"])
    return "\n".join(lines)


_LIST_LINE = re.compile(r"^\s*[0-9]{1,2}\. \S", re.M)


def list_lines(text: str) -> int:
    """The numbered lines in a text ("1. …" at a line start): what Light must never produce."""
    return len(_LIST_LINE.findall(text or ""))


# ------------------------------------------------------------------ the category variants (DictationStyleVariant)
def drop_final_stop(text: str) -> str | None:
    t = (text or "").strip()
    if not t or t[-1] not in "。." or t.endswith("...") or t.endswith("。。"):
        return None
    body = t[:-1]
    for i, c in enumerate(body):
        if c in "。！？!?\n":
            return None
        if c == "." and i + 1 < len(body) and body[i + 1] == " ":
            return None
    return body


def one_line(text: str) -> str:
    out = ""
    for part in [p.strip() for p in (text or "").split("\n") if p.strip()]:
        if out:
            a, b = out[-1], part[0]
            out += "" if _cjk(a) or _cjk(b) or a in "，。！？：；、" else " "
        out += part
    return out


def variant(text: str, category: str, structured: bool) -> tuple[str, list[str]]:
    t, changes = text or "", []
    if category == "chat":
        s = re.sub(r"\n[ \t]*\n[\n \t]*", "\n", t)
        if s != t:
            t = s
            changes.append("blank_lines")
        if not structured and (d := drop_final_stop(t)) is not None:
            t = d
            changes.append("final_stop")
    elif category == "code" and not structured and "\n" in t:
        t = one_line(t)
        changes.append("one_line")
    return t, changes


def apply_style(text: str, style: str, category: str = "other") -> dict:
    """The text in `style` for an app of `category`: the list when the style asks for one and the take has it, then
    the category's variant. → {"text", "rendered", "markers", "variant"}."""
    if style not in STYLES:
        raise ValueError(f"unknown style {style!r}")
    out, rendered = text or "", False
    n = list_markers(style)
    if n and (lst := render(out, n)) is not None:
        out, rendered = lst, True
    out, changes = variant(out, category, rendered)
    return {"text": out, "rendered": rendered, "markers": markers(text or ""), "variant": changes}


# ------------------------------------------------------------------ app → category (DictationAppCategory)
_EXACT = {
    **dict.fromkeys(["com.tencent.xinwechat", "com.tencent.qq", "com.tinyspeck.slackmacgap", "ru.keepcoder.telegram",
                     "com.apple.mobilesms", "com.hnc.discord", "net.whatsapp.whatsapp", "com.alibaba.dingtalkmac",
                     "com.microsoft.teams2", "com.microsoft.teams", "org.whispersystems.signal-desktop", "com.facebook.archon",
                     "com.electron.lark", "com.bytedance.lark", "com.tencent.wework"], "chat"),
    **dict.fromkeys(["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.microsoft.vscode",
                     "com.microsoft.vscodeinsiders", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode",
                     "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper",
                     "dev.zed.zed", "com.exafunction.windsurf", "com.sublimetext.4", "com.github.wez.wezterm",
                     "com.panic.nova", "com.barebones.bbedit"], "code"),
    **dict.fromkeys(["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron",
                     "it.bloop.airmail2", "com.mimestream.mimestream", "com.netease.mailmaster"], "mail"),
    **dict.fromkeys(["com.apple.notes", "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.apple.iwork.pages",
                     "com.microsoft.word", "com.lukilabs.lukiapp", "com.logseq.logseq", "abnerworks.typora",
                     "com.ulyssesapp.mac", "com.apple.textedit", "com.evernote.evernote", "com.youdao.note.youdaonotemac"], "notes"),
}
_PARTS = [
    ("chat", {"wechat", "xinwechat", "feishu", "lark", "dingtalk", "slack", "telegram", "discord", "whatsapp", "signal",
              "teams", "wework", "messenger"}),
    ("code", {"terminal", "iterm2", "warp", "vscode", "jetbrains", "xcode", "ghostty", "kitty", "alacritty", "zed",
              "windsurf", "sublimetext", "wezterm"}),
    ("mail", {"mail", "outlook", "mailmaster", "airmail", "spark", "superhuman"}),
    ("notes", {"notes", "obsidian", "notion", "bear", "logseq", "typora", "ulysses", "evernote", "craft"}),
]


def category(bundle: str | None) -> str:
    b = (bundle or "").lower()
    if not b:
        return "other"
    if b in _EXACT:
        return _EXACT[b]
    parts = set(re.split(r"[.\-_]", b))
    for c, names in _PARTS:
        if parts & names:
            return c
    return "other"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--text", required=True)
    r.add_argument("--min", type=int, default=ASKED_MARKERS)
    s = sub.add_parser("style")
    s.add_argument("--text", required=True)
    s.add_argument("--style", choices=STYLES, required=True)
    s.add_argument("--category", choices=CATEGORIES, default="other")
    a = ap.parse_args()
    text = unicodedata.normalize("NFC", a.text)
    if a.cmd == "render":
        out = render(text, a.min)
        print(json.dumps({"ok": True, "list": out, "markers": markers(text), "text": out or text}, ensure_ascii=False))
    else:
        print(json.dumps({"ok": True, **apply_style(text, a.style, a.category)}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        sys.exit(2)
