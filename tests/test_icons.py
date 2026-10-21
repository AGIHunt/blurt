"""The blurt icon family: assets/icons/*.svg is the source; Swift / web / Tk outputs are generated and must be in sync,
and the UI files that already moved off emoji must stay off them."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assets/icons/tools"))
import iconlib  # noqa: E402

# Emoji / pictographs and the glyphs that used to stand in for icons (✓ ✗ ✎ ● ▶ ⏸ ■ ↺ …). Arrows and key legends
# (→ ⌘ ⇧ ⏎) are text and stay.
BAD = re.compile("[\U0001F000-\U0001FAFF☀-➿⭐⭕⏩-⏺■-◿↺↻✕✖]")


def test_outputs_are_generated_from_the_svgs():
    r = subprocess.run([sys.executable, str(ROOT / "assets/icons/tools/build.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_icons_follow_the_grid():
    icons = iconlib.load_all()
    assert len(icons) >= 60
    assert [e for ic in icons for e in iconlib.lint(ic)] == []
    names = {i.name for i in icons}
    for brand in ("chicken", "blurt", "egg", "hatch", "hatched", "nest", "perch", "claw", "peck", "bug", "spark", "note",
                  "task", "mic", "waveform", "snap", "snap-to-perch", "agent", "agent-run", "mcp"):
        assert brand in names


def test_path_parser_expands_everything_to_absolute_cubics():
    segs = iconlib.parse_d("M2 2h4v4H2zM10 10a2 2 0 1 0 4 0q1 2 2 0t2 0s1 1 2 0")
    assert {c for c, _ in segs} <= {"M", "L", "C", "Z"}
    assert segs[1] == ("L", (6.0, 2.0)) and segs[2] == ("L", (6.0, 6.0))
    m = iconlib.parse_transform("translate(10 0) scale(2)")
    assert iconlib.transform_segs([("M", (1.0, 1.0))], m) == [("M", (12.0, 2.0))]


def test_tk_recorder_uses_png_icons_not_emoji():
    src = (ROOT / "skills/blurt/scripts/tk_recorder.py").read_text()
    assert not BAD.findall(src)
    used = set(re.findall(r'tk_icon\([^,]+, "([a-z0-9-]+)"\)', src)) | set(re.findall(r'"((?:pause|play|stop)-fill|snap|restart)"', src))
    assert used
    for n in used:
        for sfx in ("", "@1.5x", "@2x"):
            assert (ROOT / f"skills/blurt/assets/icons/{n}{sfx}.png").exists(), n + sfx


def test_overlays_have_no_glyph_icons():
    hits = []
    for f in sorted((ROOT / "web/apps/overlays").rglob("*")):
        if "node_modules" in f.parts or "dist" in f.parts or f.suffix not in (".ts", ".html", ".css"):
            continue
        for n, line in enumerate(f.read_text().splitlines(), 1):
            code = re.sub(r"//.*$|/\*.*?\*/", "", line)
            if BAD.search(code):
                hits.append(f"{f.relative_to(ROOT)}:{n}: {line.strip()}")
    assert hits == []
