#!/usr/bin/env python3
"""Installer sizes for the desktop app against the §1.5 targets (Windows NSIS ≤ 25 MB, .deb ≤ 20 MB, AppImage ≤ 90 MB).

  python3 apps/desktop/scripts/size_report.py [BUNDLE_DIR] [--json OUT.json] [--md OUT.md] [--enforce]

BUNDLE_DIR defaults to apps/desktop/src-tauri/target/release/bundle. Prints a Markdown table; --enforce exits 1 when
an installer with a target is over it (MSI, rpm and macOS bundles are reported without a target).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT = HERE.parent / "src-tauri" / "target" / "release" / "bundle"
MB = 1024 * 1024
# kind → (glob under the bundle dir, target MB or None)
KINDS = {
    "nsis": ("nsis/*.exe", 25),
    "msi": ("msi/*.msi", None),
    "deb": ("deb/*.deb", 20),
    "rpm": ("rpm/*.rpm", None),
    "appimage": ("appimage/*.AppImage", 90),
    "dmg": ("dmg/*.dmg", None),
    "app": ("macos/*.app", None),
}


def size(p: Path) -> int:
    if p.is_dir():
        return sum(f.stat().st_size for f in p.rglob("*") if f.is_file() and not f.is_symlink())
    return p.stat().st_size


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle", nargs="?", default=str(DEFAULT))
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--enforce", action="store_true")
    a = ap.parse_args()
    root = Path(a.bundle)
    rows = []
    for kind, (pattern, target) in KINDS.items():
        for f in sorted(root.glob(pattern)):
            b = size(f)
            rows.append({"kind": kind, "file": f.name, "bytes": b, "mb": round(b / MB, 2), "target_mb": target,
                         "ok": target is None or b <= target * MB})
    lines = ["| installer | file | size | target | |", "|---|---|---|---|---|"]
    for r in rows:
        tgt = f"≤ {r['target_mb']} MB" if r["target_mb"] else "–"
        lines.append(f"| {r['kind']} | {r['file']} | {r['mb']:.2f} MB | {tgt} | {'✅' if r['ok'] else '❌ over'} |")
    if not rows:
        lines.append(f"| – | no installers under {root} | | | |")
    md = "\n".join(lines)
    print(md)
    if a.json:
        Path(a.json).write_text(json.dumps({"bundle_dir": str(root), "installers": rows}, indent=2), encoding="utf-8")
    if a.md:
        Path(a.md).write_text(md + "\n", encoding="utf-8")
    if a.enforce and (not rows or not all(r["ok"] for r in rows)):
        sys.exit(1)


if __name__ == "__main__":
    main()
