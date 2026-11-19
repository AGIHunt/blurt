#!/usr/bin/env python3
"""Print every user-facing string this branch adds or changes, and fail on words docs/design/copy.md bans.

    python3 tools/copy-check.py [base]      # base defaults to origin/main

Read every printed line in both languages before sending a change (docs/design/copy.md).
"""
import re
import subprocess
import sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
FILES = ["*.strings", "*/locales/*.json", "*strings.xml", "README*.md", "site/*.html"]
# words that never belong in Blurt's UI (docs/design/copy.md); matched in added lines only
BANNED = ["牵线", "一键", "赋能", "丝滑", "随手", "递给", "就出字", "这台 Mac", "这台Mac",
          "seamless", "supercharge", "unleash", "magic", "go-between", "Go-between"]
# product name inside a status or error line: allowed in names like 欢迎使用口喷鸡, so only flagged next to these words
PRODUCT_IN_STATUS = re.compile(r"(未经|已被|无法|不能|正在)[^\"<]{0,6}(口喷鸡|Blurt)")

diff = subprocess.run(["git", "diff", "-U0", BASE, "--", *FILES], capture_output=True, text=True, check=True).stdout
current, bad, shown = None, [], 0
for line in diff.splitlines():
    if line.startswith("+++ "):
        current = line[6:]
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    text = line[1:].strip()
    if not text or text.startswith(("//", "/*", "<!--", "#")):
        continue
    if current and current.endswith("strings.xml") and "<string" not in text:
        continue
    print(f"{current}: {text}")
    shown += 1
    hits = [w for w in BANNED if w in text] + (["product name in status"] if PRODUCT_IN_STATUS.search(text) else [])
    if hits:
        bad.append(f"{current}: {text}  ← {', '.join(hits)}")

print(f"\n{shown} added or changed lines against {BASE}. Read each one (docs/design/copy.md).")
if bad:
    print("\nBanned words:\n" + "\n".join(bad))
    sys.exit(1)
