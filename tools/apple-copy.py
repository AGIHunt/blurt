#!/usr/bin/env python3
"""How macOS itself words something, in Chinese and English: the strings in the apps and settings on this Mac.

    python3 tools/apple-copy.py 前往 麦克风        # strings that hold every word (either language)
    python3 tools/apple-copy.py --panes 自动       # System Settings only

For reading, not for copying into the repository (docs/design/copy.md). The first run reads every table and takes about a
minute; after that it answers from a cache in the temporary folder.
"""
import json
import plistlib
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOTS = ["/System/Library/ExtensionKit/Extensions", "/System/Applications", "/System/Library/CoreServices",
         "/System/Library/PreferencePanes"]
CACHE = Path(tempfile.gettempdir()) / "blurt-apple-copy.json"


def table(path: Path) -> list:
    try:
        raw = path.read_bytes()
        d = plistlib.loads(raw)
    except Exception:
        out = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(path)], capture_output=True)
        try:
            d = plistlib.loads(out.stdout)
        except Exception:
            return []
    zh, en = d.get("zh_CN") or {}, d.get("en") or {}
    where = next((p for p in path.parts if p.endswith((".appex", ".app", ".prefPane", ".bundle"))), path.stem)
    return [(zh[k], en.get(k) if isinstance(en.get(k), str) else "", where) for k in zh if isinstance(zh[k], str)]


def load() -> list:
    if CACHE.is_file():
        return json.loads(CACHE.read_text())
    files = [p for r in ROOTS for p in Path(r).rglob("*.loctable")]
    with ThreadPoolExecutor(8) as pool:
        rows = sorted({tuple(x) for part in pool.map(table, files) for x in part})
    CACHE.write_text(json.dumps(rows, ensure_ascii=False))
    return rows


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--panes"]
    if not args:
        sys.exit(__doc__)
    seen = set()
    for zh, en, where in load():
        if "--panes" in sys.argv and not where.endswith((".appex", ".prefPane")):
            continue
        text = f"{zh}\n{en}".lower()
        if (zh, en) not in seen and all(a.lower() in text for a in args):
            seen.add((zh, en))
            print(f"{zh}\n    {en}   [{where}]".replace("\n\n", " "))
            if len(seen) == 60:
                print("… (more; add a word)")
                break


if __name__ == "__main__":
    main()
