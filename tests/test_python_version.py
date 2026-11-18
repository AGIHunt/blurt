"""scripts/.python-version: the Python uv runs the skill's scripts on, so uv never picks one on its own (the newest
release, which the pinned packages may ship no wheels for yet — BLU-1, #47). It must fit every script's
requires-python and ship with each app.

  uv run --with pytest pytest tests/test_python_version.py -q
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"


def pinned() -> tuple[int, int]:
    lines = [l.strip() for l in (SCRIPTS / ".python-version").read_text().splitlines()]
    v = [l for l in lines if l and not l.startswith("#")]
    assert len(v) == 1 and re.fullmatch(r"3\.\d+", v[0]), v
    major, minor = v[0].split(".")
    return int(major), int(minor)


def version(s: str) -> tuple[int, int]:
    major, minor = s.split(".")[:2]
    return int(major), int(minor)


def test_fits_every_script():
    v = pinned()
    for f in sorted(SCRIPTS.glob("*.py")):
        m = re.search(r'^# requires-python = "([^"]+)"', f.read_text(), re.M)
        if not m:
            continue
        for spec in m.group(1).split(","):
            op, ver = re.fullmatch(r"\s*(>=|<|<=|>|==)\s*([\d.]+)\s*", spec).groups()
            ok = {">=": v >= version(ver), ">": v > version(ver), "<": v < version(ver),
                  "<=": v <= version(ver), "==": v == version(ver)}[op]
            assert ok, f"{f.name}: requires-python {m.group(1)!r} excludes {v}"


def test_ships_with_the_desktop_app():
    conf = json.loads((ROOT / "apps" / "desktop" / "src-tauri" / "tauri.conf.json").read_text())
    res = conf["bundle"]["resources"]
    assert res.get("../../../skills/blurt/scripts/.python-version") == "scripts/.python-version"
