"""The blurt icon family: assets/icons/*.svg is the source; Swift / web / Tk outputs are generated and must be in sync,
and no UI source uses emoji or text glyphs as icons (assets/icons/tools/check_glyphs.py)."""
from __future__ import annotations

import dataclasses
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
    for brand in ("chicken", "blurt", "egg", "hatch", "hatched", "peck", "bug", "spark", "document",
                  "checklist", "mic", "waveform", "snap", "agent", "agent-run", "mcp"):
        assert brand in names


def test_path_parser_expands_everything_to_absolute_cubics():
    segs = iconlib.parse_d("M2 2h4v4H2zM10 10a2 2 0 1 0 4 0q1 2 2 0t2 0s1 1 2 0")
    assert {c for c, _ in segs} <= {"M", "L", "C", "Z"}
    assert segs[1] == ("L", (6.0, 2.0)) and segs[2] == ("L", (6.0, 6.0))
    m = iconlib.parse_transform("translate(10 0) scale(2)")
    assert iconlib.transform_segs([("M", (1.0, 1.0))], m) == [("M", (12.0, 2.0))]


def test_menu_bar_icons_are_the_blurt_glyph():
    """Tauri tray and the macOS status item show the same mark: the `blurt` glyph (the 4A line chick) as a template
    image — no stale hand-made template PNGs, and no colour option any more (the v0.8 colour hen is gone)."""
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    mac = (app / "App/AppDelegate.swift").read_text()
    assert "BlurtIcon.blurt.image(size: 18)" in mac and "MenuIconTemplate" not in mac
    assert not (app / "Icons/MenuHen.swift").exists()
    src = "\n".join(p.read_text() for p in app.rglob("*.swift"))
    assert "MenuHen" not in src and "settings.general.menu_color" not in src
    glyph = (app / "App/MenuGlyph.swift").read_text()
    assert "BlurtIcon.blurt.layers" in glyph and "reduceMotion" in glyph
    for strings in app.glob("Resources/*.lproj/Settings.strings"):
        assert "menu_color" not in strings.read_text(), strings
    assert (ROOT / "assets/brand/glyph.svg").read_text() == (ROOT / "assets/icons/blurt.svg").read_text()
    assert not list((ROOT / "skills/blurt/assets").glob("MenuIconTemplate*.png"))
    build = (ROOT / "assets/icons/tools/build.py").read_text()
    assert 'TRAY_ICON = "blurt"' in build


def test_blurt_glyph_is_the_chick_with_two_arc_layers():
    """MenuGlyph pulses the sound arcs by drawing the glyph layer by layer: [chick, inner arc, outer arc], all fills
    (the glyph carries its own 1.5 pt line as outlines), inside the 24 grid."""
    icon = next(i for i in iconlib.load_all() if i.name == "blurt")
    assert [L.mode for L in icon.layers] == ["fill", "fill", "fill"]
    x0, y0, x1, y1 = iconlib.bbox(icon)
    assert 0.5 <= x0 and 0.5 <= y0 and x1 <= 23.5 and y1 <= 23.5
    inner, outer = (iconlib.bbox(dataclasses.replace(icon, layers=[L])) for L in icon.layers[1:])
    assert inner[2] < outer[2] and inner[1] > outer[1]          # the outer arc reaches further right and higher


def test_brand_sources_are_generated_and_rendered():
    """assets/brand/*.svg come from chick.swift; the bitmaps build.py writes exist."""
    brand = ROOT / "assets/brand"
    for f in ("app-icon.svg", "app-icon-small.svg", "app-icon-16.svg", "app-icon-dark.svg", "logo.svg", "chick-line.svg",
              "chick-filled.svg"):
        assert "chick.swift" in (brand / f).read_text(), f
    assert '<g id="tile">' in (brand / "app-icon.svg").read_text()
    for rel in ("skills/blurt/assets/icon.png", "skills/blurt/assets/icon-16.png", "skills/blurt/assets/icon-32.png",
                "assets/logo.png", "assets/logo-v0.8a.png", "apps/desktop/src-tauri/icons/icon.icns"):
        assert (ROOT / rel).stat().st_size > 0, rel


def test_app_icon_tile_is_the_token_gradient():
    """The icon tile's colours come from assets/color/tokens.json (§6): gradient.field (+ grain) on the master,
    gradient.deep on the dark variant, plain gradient.linear (no radial layers, no grain) at 32 / 16 px."""
    import json
    g = json.loads((ROOT / "assets/color/tokens.json").read_text())["gradient"]
    brand = ROOT / "assets/brand"
    for f, field in (("app-icon.svg", "field"), ("app-icon-dark.svg", "deep")):
        s = (brand / f).read_text().lower()
        assert 'id="tile-field"' in s and 'id="tile-grain"' in s and "mix-blend-mode:overlay" in s, f
        assert f'basefrequency="{g["grain"]["iconFrequency"]:g}"' in s, f
        assert f'intercept="{g["grain"]["icon"]:g}"' in s, f
        assert s.count("<radialgradient") == sum(l["type"] == "radial" for l in g[field]["layers"]), f
        for layer in g[field]["layers"]:
            for colour, *_ in layer["stops"]:
                assert colour.lower() in s, (f, colour)
    for f in ("app-icon-small.svg", "app-icon-16.svg"):
        s = (brand / f).read_text().lower()
        assert "<radialgradient" not in s and "tile-grain" not in s, f
        for name, _ in g["linear"]["stops"]:
            assert g["stops"][name].lower() in s, (f, name)


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


def test_colour_outputs_are_generated_from_tokens():
    """assets/color/tokens.json is the one source of colour: BrandColor.swift, the CSS blocks in tokens.css /
    theme.css and the AccentColor asset are generated from it and up to date, and every contrast floor holds
    (build.py --check). The Swift kinds and state rings read the generated values."""
    r = subprocess.run([sys.executable, str(ROOT / "assets/color/build.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    icons = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Icons"
    assert "BrandColor.Kind.palette" in (icons / "KindStyle.swift").read_text()
    ring = (icons / "StatusRing.swift").read_text()
    assert "BrandColor.ink" in ring and "BrandColor.ok" in ring and "BrandColor.attn" in ring
    plist = (ROOT / "skills/blurt/recorder/macos/Info.plist").read_text()
    assert "<key>NSAccentColorName</key>" in plist
    assert "Assets.car" in (ROOT / "skills/blurt/scripts/record.py").read_text()


def test_no_hard_coded_colours_outside_the_tokens():
    """The coral `accent` / `amber` globals are gone, and app code takes brand colours from BrandColor, not from
    calibrated RGB or the system accent (native controls follow the AccentColor asset by themselves). The one
    exception: WebHostController.accentHex hands the system focus colour to the web canvas (--sys-accent)."""
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    bad = re.compile(r"calibratedRed|\bcontrolAccentColor\b|Color\.accentColor|\.accentColor\b|"
                     r"(?<![\w.])(accent|amber)(?=[\s.,)\]])")
    hits = []
    for p in app.rglob("*.swift"):
        if p.name in ("BrandColor.swift", "BlurtIconPaths.swift"):
            continue
        for i, line in enumerate(p.read_text().splitlines(), 1):
            code = line.split("//", 1)[0]
            if bad.search(code) and not ("accentHex" in p.read_text() and "controlAccentColor.usingColorSpace" in code):
                hits.append(f"{p.relative_to(app)}:{i}: {line.strip()}")
    assert hits == []


def test_mascot_outputs_are_copied_from_assets_mascot():
    """The 1A chick's frame strips (assets/mascot) reach the mac app and the web package unchanged, and stay small."""
    import json
    r = subprocess.run([sys.executable, str(ROOT / "assets/mascot/tools/build.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    m = json.loads((ROOT / "assets/mascot/mascot.json").read_text())
    sheets = {c["sheet"] for c in m["clips"].values()}
    assert {"idle", "listening", "thinking", "wobble", "hatching", "happy", "peck"} <= set(m["clips"])
    assert sum((ROOT / f"assets/mascot/{s}.webp").stat().st_size for s in sheets) < 2.5 * 1024 * 1024
    for name, c in m["clips"].items():
        assert 8 <= c["frames"] <= 16, name
        assert all(0 <= f < c["frames"] and t > 0 for f, t in c["timeline"]), name
    # record.py puts them into Blurt.app; the old drawn hen and egg are gone
    assert '"Mascot"' in (ROOT / "skills/blurt/scripts/record.py").read_text()
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    src = "\n".join(p.read_text() for p in app.rglob("*.swift"))
    for gone in ("ChickenArt", "HenView", "HenMood", "drawEgg", "eggImage"):
        assert gone not in src, gone
