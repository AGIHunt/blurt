"""The web apps never use the browser's own dialogs: in WebView2 (Windows) window.confirm / alert / prompt show nothing
and confirm answers yes, so a "Clear History…" behind one wiped the history with no question asked. Ask with an
in-app sheet (role="alertdialog") instead."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_no_browser_dialogs():
    bad = re.compile(r"\bwindow\.(confirm|alert|prompt)\s*\(|(?<![\w.])(alert|prompt)\s*\(")
    hits = []
    for p in [*ROOT.glob("web/apps/*/src/**/*"), *ROOT.glob("web/packages/*/src/**/*")]:
        if p.suffix not in (".ts", ".tsx") or p.name.endswith(".test.ts") or p.name.endswith(".test.tsx"):
            continue
        for i, line in enumerate(p.read_text().splitlines(), 1):
            if bad.search(line.split("//", 1)[0]):
                hits.append(f"{p.relative_to(ROOT)}:{i}: {line.strip()}")
    assert hits == []
