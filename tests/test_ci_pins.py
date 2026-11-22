"""The versions CI tests with are the scripts' own. check.yml's `tests` job installs each package at the version the
scripts pin for themselves (PEP 723 `# /// script`), so the suite is tried on what a user's `uv run` gets. A pin bumped
in a header and not in the workflow would leave CI green on a version nobody runs."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "check.yml"
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"


def by_package(specs):
    """name → the versions pinned for it, markers left out: {"numpy": {"2.3.4", "2.2.6"}}"""
    found = {}
    for spec in specs:
        pinned = spec.split(";")[0].strip()
        if "==" in pinned:
            name, version = pinned.split("==")
            found.setdefault(name.strip().lower().split("[")[0], set()).add(version.strip())
    return found


def scripts_pins():
    specs = []
    for script in sorted(SCRIPTS.glob("*.py")):
        lines = script.read_text(encoding="utf-8").splitlines()
        if lines[:1] != ["# /// script"]:
            continue
        for line in lines[1:]:
            if line == "# ///":
                break
            if line.startswith("# dependencies"):
                specs += re.findall(r'"([^"]+)"', line)
    return by_package(specs)


def test_ci_pins_the_versions_the_scripts_pin():
    ci = by_package(re.findall(r'--with "([^"]+)"', WORKFLOW.read_text(encoding="utf-8")))
    assert ci, "check.yml pins no version any more"
    scripts = scripts_pins()
    for name, pinned in sorted(ci.items()):
        assert pinned == scripts.get(name, set()), (
            f"check.yml's tests job pins {name} as {sorted(pinned)}; the scripts' headers pin {sorted(scripts.get(name, []))}. "
            "Move the workflow with the header.")
