"""Fails on emoji or text-glyph icons in UI source (Swift, TS/TSX/CSS/HTML, Rust tray, the Tk recorder).

Icons come from the blurt icon family (assets/icons → BlurtIcon / @blurt/icons / Tk PNGs) or SF Symbols — never 🐔 📸 ✓ ✗
● ▶ ⏸ ✎ ⚠ … typed into a string. Key legends (⌘ ⌥ ⇧ ⌃ ⏎ ↩ ⌫ ⇥ ⎋ arrows), typography (· … – — “ ” ×) and comments are
fine. A line that really needs a glyph as text can end with the marker comment `glyph-ok` (with a reason).

    python3 assets/icons/tools/check_glyphs.py            # list offending lines, exit 1 if any
    python3 assets/icons/tools/check_glyphs.py --symbols  # every non-ASCII symbol in scope, for review
"""
from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]

# Where UI strings live. WP5's in-flight folders are listed too: their entries are in assets/icons/REPLACEMENTS.md.
SCOPE = [
    ("skills/blurt/recorder/macos/Sources", (".swift",)),
    ("web/apps", (".ts", ".tsx", ".css", ".html")),
    ("web/packages", (".ts", ".tsx", ".css", ".html")),
    ("apps/desktop/src-tauri/src", (".rs",)),
    ("crates", (".rs",)),
    ("skills/blurt/scripts/tk_recorder.py", (".py",)),
]
SKIP_DIRS = {"node_modules", "dist", "target", ".build", "test", "tests", "e2e", "generated"}

# Emoji / pictographs + the dingbats and geometric shapes that get used as icons.
BAD = re.compile(
    "[\U0001F000-\U0001FAFF"      # emoji & pictographs
    "☀-➿"               # misc symbols + dingbats (☆ ★ ♥ ⚠ ✓ ✔ ✕ ✖ ✗ ✘ ✎ ✏ ❌ ❚ …)
    "⬀-⯿"               # misc symbols and arrows (⭐ ⬆ …)
    "■-◿"               # geometric shapes (■ □ ● ○ ◉ ▶ ◀ ▲ ▼ …)
    "⏩-⏺"               # media controls (⏩ ⏸ ⏹ ⏺ …)
    "↺↻⟲⟳"    # ↺ ↻ ⟲ ⟳
    "⧉"                      # ⧉
    "︎️]"               # text / emoji presentation selectors (⚠︎, ✔️ …)
)
ALLOWED = set("←↑→↓↔↕⇄⇆↩↪⏎⇧⌘⌥⌃⌫⌦⇥⇤⎋·…–—‘’“”×÷±≈≠≤≥°′″")


def files():
    for rel, exts in SCOPE:
        p = REPO / rel
        if p.is_file():
            yield p
            continue
        if not p.exists():
            continue
        for f in sorted(p.rglob("*")):
            if f.is_file() and f.suffix in exts and not (SKIP_DIRS & set(f.relative_to(REPO).parts)):
                yield f


def strip_comments(line: str, suffix: str) -> str:
    if suffix == ".py":
        return re.sub(r"(^|\s)#.*$", "", line)
    s = re.sub(r"/\*.*?\*/|<!--.*?-->", "", line)
    s = re.sub(r"(^|[^:])//.*$", r"\1", s)        # keep "https://"
    if s.lstrip().startswith(("*", "/*")):
        return ""
    return s


def scan():
    hits = []
    for f in files():
        in_doc = False
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if "glyph-ok" in line:
                continue
            st = line.strip()
            if f.suffix == ".py":       # docstrings: skip triple-quoted blocks at a line start
                if st.startswith(('"""', "'''")):
                    if not (st.count('"""') + st.count("'''") >= 2 and len(st) > 3):
                        in_doc = not in_doc
                    continue
                if in_doc:
                    continue
            code = strip_comments(line, f.suffix)
            bad = [c for c in BAD.findall(code) if c not in ALLOWED]
            if bad:
                hits.append(f"{f.relative_to(REPO)}:{n}: {''.join(dict.fromkeys(bad))}  {st[:140]}")
    return hits


def symbols():
    seen: dict[str, list[str]] = {}
    for f in files():
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for ch in strip_comments(line, f.suffix):
                if ord(ch) > 127 and unicodedata.category(ch) in ("So", "Sm", "Sk", "Mn") and ch not in ALLOWED:
                    seen.setdefault(ch, []).append(f"{f.relative_to(REPO)}:{n}")
    for ch, where in sorted(seen.items()):
        print(f"{ch!r} U+{ord(ch):04X} {unicodedata.name(ch, '?')}: {len(where)}  {', '.join(where[:4])}")


if __name__ == "__main__":
    if "--symbols" in sys.argv:
        symbols()
        sys.exit(0)
    h = scan()
    print("\n".join(h) if h else "no emoji / glyph icons in UI source")
    sys.exit(1 if h else 0)
