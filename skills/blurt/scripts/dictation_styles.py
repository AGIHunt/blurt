#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# ///
"""Dictation styles for tools outside the app (docs/design/dictation-styles.md §3): which text a style types, the
category variants of light and the app → category table — the same rules as BlurtCore's DictationStyle.swift. Whether
and how a take is structured is the polish model's call (polish.py `structure`); this only picks the text and applies
the variant. The Dictation Lab (dictation_lab.py) re-runs a case per style with these.

  dictation_styles.py style --text "…" --style structured [--category chat] [--structured "…"]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata

STYLES = ("verbatim", "light", "structured", "auto")
CATEGORIES = ("chat", "code", "mail", "notes", "other")
_LIST_LINE = re.compile(r"^[ \t]*(?:[0-9]{1,2}(?:[.)）](?![0-9])|、)|[-•*](?=[ \t]))[ \t]*\S", re.M)


def _cjk(c: str) -> bool:
    o = ord(c)
    return 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0x3040 <= o <= 0x30FF or 0xAC00 <= o <= 0xD7AF


def list_lines(text: str) -> int:
    """The numbered or bulleted lines in a text ("1. …", "- …" at a line start): what Light must never produce, and
    what tells a structured text that is a list from one that stayed a paragraph."""
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


def apply_style(text: str, style: str, category: str = "other", structured: str | None = None) -> dict:
    """The text in `style` for an app of `category`. `structured`: the structuring pass's text for this take (the
    polish model's: polish.py `structure`) — Structured types it; Auto only when it is a list (≥ 2 list lines), else
    Light's text. Then the category's variant. → {"text", "rendered" (a list was typed), "variant"}."""
    if style not in STYLES:
        raise ValueError(f"unknown style {style!r}")
    out, rendered = text or "", False
    if style in ("structured", "auto") and structured is not None and structured.strip():
        if style == "structured" or list_lines(structured) >= 2:
            out = structured.strip()
            rendered = list_lines(out) >= 2
    out, changes = variant(out, category, rendered)
    return {"text": out, "rendered": rendered, "variant": changes}


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


_TERMINALS = {"com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
              "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm"}
_TERMINAL_PARTS = {"terminal", "iterm2", "warp", "ghostty", "kitty", "alacritty", "wezterm"}


def is_terminal(bundle: str | None) -> bool:
    """A terminal (DictationAppCategory.isTerminal): polish's "terminal" variant — a command said there stays a command."""
    b = (bundle or "").lower()
    return bool(b) and (b in _TERMINALS or bool(set(re.split(r"[.\-_]", b)) & _TERMINAL_PARTS))


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
    s = sub.add_parser("style")
    s.add_argument("--text", required=True)
    s.add_argument("--style", choices=STYLES, required=True)
    s.add_argument("--category", choices=CATEGORIES, default="other")
    s.add_argument("--structured", help="the structuring pass's text (polish.py run --style structured)")
    a = ap.parse_args()
    text = unicodedata.normalize("NFC", a.text)
    print(json.dumps({"ok": True, **apply_style(text, a.style, a.category, a.structured)}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        print(json.dumps({"ok": False, "error": str(e)}), file=sys.stderr)
        sys.exit(2)
