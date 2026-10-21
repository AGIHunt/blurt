"""The blurt icon family: assets/icons/*.svg is the source; Swift / web / Tk outputs are generated and must be in sync,
and no UI source uses emoji or text glyphs as icons (assets/icons/tools/check_glyphs.py)."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assets/icons/tools"))
import iconlib  # noqa: E402

from check_glyphs import ALLOWED, BAD  # noqa: E402  (emoji / glyph icons; key legends and arrows are fine)


def test_outputs_are_generated_from_the_svgs():
    r = subprocess.run([sys.executable, str(ROOT / "assets/icons/tools/build.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_icons_follow_the_grid():
    icons = iconlib.load_all()
    assert len(icons) >= 60
    assert [e for ic in icons for e in iconlib.lint(ic)] == []
    names = {i.name for i in icons}
    for brand in ("chicken", "blurt", "egg", "hatch", "hatched", "nest", "perch", "claw", "peck", "bug", "spark", "document",
                  "checklist", "mic", "waveform", "snap", "snap-to-perch", "agent", "agent-run", "mcp"):
        assert brand in names


def test_path_parser_expands_everything_to_absolute_cubics():
    segs = iconlib.parse_d("M2 2h4v4H2zM10 10a2 2 0 1 0 4 0q1 2 2 0t2 0s1 1 2 0")
    assert {c for c, _ in segs} <= {"M", "L", "C", "Z"}
    assert segs[1] == ("L", (6.0, 2.0)) and segs[2] == ("L", (6.0, 6.0))
    m = iconlib.parse_transform("translate(10 0) scale(2)")
    assert iconlib.transform_segs([("M", (1.0, 1.0))], m) == [("M", (12.0, 2.0))]


def test_menu_bar_icons_are_the_blurt_glyph():
    """macOS status item and Tauri tray show the same mark: the `blurt` glyph (no stale hand-made template PNGs)."""
    mac = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/App/AppDelegate.swift").read_text()
    assert "BlurtIcon.blurt.image(size: 18)" in mac and "MenuIconTemplate" not in mac
    assert not list((ROOT / "skills/blurt/assets").glob("MenuIconTemplate*.png"))
    build = (ROOT / "assets/icons/tools/build.py").read_text()
    assert 'TRAY_ICON = "blurt"' in build


def test_tk_recorder_uses_png_icons_not_emoji():
    src = (ROOT / "skills/blurt/scripts/tk_recorder.py").read_text()
    assert not [c for c in BAD.findall(src) if c not in ALLOWED]
    used = set(re.findall(r'tk_icon\([^,]+, "([a-z0-9-]+)"\)', src)) | set(re.findall(r'"((?:pause|play|stop)-fill|snap|restart)"', src))
    assert used
    for n in used:
        for sfx in ("", "@1.5x", "@2x"):
            assert (ROOT / f"skills/blurt/assets/icons/{n}{sfx}.png").exists(), n + sfx


def test_no_emoji_or_glyph_icons_in_ui_source():
    """Swift (mac app), TS/TSX/CSS/HTML (web), Rust (tray), Tk: icons come from the family or SF Symbols, never 🐔 ✓ ● ▶."""
    import check_glyphs
    assert check_glyphs.scan() == []


def test_glyph_check_catches_what_it_should():
    import check_glyphs
    for bad in ("🐔 整理", "✓ Saved", "● 00:12", "❚❚", "▶", "⚠︎ conflict", "📸 3", "✎", "🐣", "✗ failed", "↺"):
        assert [c for c in check_glyphs.BAD.findall(bad) if c not in check_glyphs.ALLOWED], bad
    for ok in ("⌘K", "⏎ save · Esc skip", "← →", "1280 × 720", "整理中…", "“quote”", "⇧⌥A"):
        assert not [c for c in check_glyphs.BAD.findall(ok) if c not in check_glyphs.ALLOWED], ok
    assert check_glyphs.strip_comments('let x = 1  // 🐔 is fine in a comment', ".swift").strip() == "let x = 1"
    assert "https://x" in check_glyphs.strip_comments('let u = "https://x"', ".swift")


def test_kind_and_ring_colours_match_between_web_and_swift():
    """K8: KindStyle.swift / StatusRing.swift use the same light / dark values as web/packages/ui/src/tokens.css."""
    css = (ROOT / "web/packages/ui/src/tokens.css").read_text()
    light, dark = css.split('[data-theme="dark"] {', 1)

    def tok(block, name):
        return re.search(rf"{name}:\s*#([0-9a-f]{{6}})", block, re.I).group(1).upper()

    icons = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Icons"
    kinds = (icons / "KindStyle.swift").read_text()
    for k in ("issue", "idea", "note", "task"):
        assert f'"{k}": (0x{tok(light, "--kind-" + k)}, 0x{tok(dark, "--kind-" + k)})' in kinds, k
    ring = (icons / "StatusRing.swift").read_text()
    for swift, token in (("accent", "--accent"), ("attention", "--warn"), ("keep", "--keep")):
        assert f"static let {swift} = KindStyle.dynamic(KindStyle.rgb(0x{tok(light, token)}), KindStyle.rgb(0x{tok(dark, token)}))" in ring, swift
