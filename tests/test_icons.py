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
    for brand in ("chicken", "blurt", "egg", "hatch", "hatched", "peck", "bug", "spark", "document",
                  "checkbox", "mic", "waveform", "snap", "agent", "agent-run", "mcp"):
        assert brand in names


KIND_ICONS = {"issue": "bug", "idea": "lightbulb", "note": "document", "task": "checkbox"}   # a custom lens: "tag"


def test_kind_icons_are_one_family():
    """docs/design/system.md §2.6: the four kinds and the lens tag are one family of our own — brand group, no SF Symbol
    on macOS, one footprint inside the 24 grid (2.5…21.5, at least 14 × 16) — and mac and web map the kinds the same."""
    import json
    names = set(KIND_ICONS.values()) | {"tag"}
    sf = json.loads((ROOT / "assets/icons/sf-symbols.json").read_text())
    assert not names & set(sf["generic"]), "kind icons never fall back to SF Symbols"
    icons = {i.name: i for i in iconlib.load_all()}
    for n in names:
        ic = icons[n]
        assert ic.group == "brand", n
        x0, y0, x1, y1 = iconlib.bbox(ic)
        assert 2.5 <= x0 and 2.5 <= y0 and x1 <= 21.5 and y1 <= 21.5, (n, x0, y0, x1, y1)
        w, h = x1 - x0, y1 - y0
        assert min(w, h) >= 14 and max(w, h) >= 16.5, (n, w, h)
        assert all(L.opacity == 1 for L in ic.layers), n          # no duotone or tiles: plain line glyphs
    assert "checklist" not in icons and sf["aliases"]["checklist"] == "checkbox"
    kind = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Icons/KindStyle.swift").read_text()
    assert "systemSymbolName" not in kind and "sfSymbols" not in kind
    swift_case = {"bug": "bug", "lightbulb": "lightbulb", "document": "document", "checkbox": "checkbox"}
    for k, n in KIND_ICONS.items():
        assert f'case "{k}": return .{swift_case[n]}' in kind, k
    ts = (ROOT / "web/packages/ui/src/kinds.ts").read_text()
    assert ", ".join(f'{k}: "{n}"' for k, n in KIND_ICONS.items()) in ts
    assert ': "tag")' in ts and "default: return .tag" in kind


def test_path_parser_expands_everything_to_absolute_cubics():
    segs = iconlib.parse_d("M2 2h4v4H2zM10 10a2 2 0 1 0 4 0q1 2 2 0t2 0s1 1 2 0")
    assert {c for c, _ in segs} <= {"M", "L", "C", "Z"}
    assert segs[1] == ("L", (6.0, 2.0)) and segs[2] == ("L", (6.0, 6.0))
    m = iconlib.parse_transform("translate(10 0) scale(2)")
    assert iconlib.transform_segs([("M", (1.0, 1.0))], m) == [("M", (12.0, 2.0))]


def test_menu_bar_is_peeps_template_glyph():
    """The macOS status item shows Peep: the release package's menu-bar glyph frames (18 pt template images, @1x and
    @2x, Resources/Peep/glyph-*.png), at rest and moving with what Blurt does — talking while you dictate (the beak with
    the voice level), listening to a voice note or the countdown, thinking while transcribing or organising, done,
    error, an idle blink — and still with Reduce Motion. No colour option (the v0.8 colour hen is gone). The Tauri tray
    (Windows / Linux) still shows the `blurt` line glyph until it gets Peep."""
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    mac = (app / "App/AppDelegate.swift").read_text()
    assert "MenuGlyph.shared.frame(.idle, 0)" in mac and "MenuIconTemplate" not in mac
    assert "MenuGlyph.shared.sync()" in mac
    assert not (app / "Icons/MenuHen.swift").exists() and not (app / "App/MenuGlyphGeometry.swift").exists()
    src = "\n".join(p.read_text() for p in app.rglob("*.swift"))
    assert "MenuHen" not in src and "settings.general.menu_color" not in src
    glyph = (app / "App/MenuGlyph.swift").read_text()
    assert "reduceMotion" in glyph and "isTemplate = template" in glyph and "Dictation.shared.levels" in glyph
    assert "PeepPlayback.talkingFrame" in glyph and "glyphBlink" in glyph
    # the new wiring: dictation, the countdown and organising reach the menu bar, not only the voice note
    assert "PeepGlyphMode.from(dictating:" in glyph and "countdown" in glyph and "island.organizing" in glyph
    assert "MenuGlyph.shared.countdown = true" in mac
    assert "MenuGlyph.shared.error()" in (app / "System/JobNotifier.swift").read_text()
    assert "MenuGlyph.shared.done()" in (app / "Capture/Island/Island.swift").read_text()
    for strings in app.glob("Resources/*.lproj/Settings.strings"):
        assert "menu_color" not in strings.read_text(), strings
    assert not list((ROOT / "skills/blurt/assets").glob("MenuIconTemplate*.png"))
    build = (ROOT / "assets/icons/tools/build.py").read_text()
    assert 'TRAY_ICON = "blurt"' in build


def test_blurt_line_glyph_is_a_bold_silhouette():
    """The `blurt` line glyph (the Tauri tray's mark; the mac menu bar is Peep now): one filled silhouette, the face
    knocked out, at least 16 pt of its 18 pt box, foot on a whole point."""
    icon = next(i for i in iconlib.load_all() if i.name == "blurt")
    assert [L.mode for L in icon.layers] == ["fill"]
    x0, y0, x1, y1 = iconlib.extent(icon)
    assert 0.5 <= x0 and 0.5 <= y0 and x1 <= 23.5 and y1 <= 23.5
    assert (y1 - y0) * 0.75 >= 16 and (x1 - x0) * 0.75 >= 15, (x0, y0, x1, y1)
    assert abs(y1 * 0.75 - round(y1 * 0.75)) < 0.01                 # the foot on a whole point
    assert icon.layers[0].d.count("M") >= 4                        # outline + two eye holes + the beak hole


PEEP = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Peep"
STATES = ("idle", "hello", "listening", "talking", "thinking", "done", "error")


def test_peep_is_imported_from_its_release_package():
    """Peep has one source, the Blender model, and reaches the repo only through assets/brand/import_peep.py from the
    release package: the app's sprite sheets and glyph frames with peep.json, the app icon (.icns, the macOS 26 .icon,
    the 1024 tiles), the brand SVGs, the README pictures and the review page's drawing. The 4A chick's generator and
    the older logos are kept in assets/brand/legacy/ and drive nothing."""
    import json
    brand = ROOT / "assets/brand"
    assert (brand / "import_peep.py").exists()
    for gone in ("chick.swift", "build.py", "glyph.svg", "logo.svg", "app-icon.svg"):
        assert not (brand / gone).exists() and (brand / "legacy" / gone).exists(), gone
    for old in ("logo-1.png", "logo-v0.8a.png", "logo-v0.9-4a.png"):
        assert (brand / "legacy" / old).stat().st_size > 0, old
    m = json.loads((PEEP / "peep.json").read_text())
    assert set(m["sets"]["dark"]["clips"]) == set(STATES), "the notch plays every state"
    assert {"idle", "hello", "done"} <= set(m["sets"]["paper"]["clips"])
    assert set(m["glyph"]["clips"]) == set(STATES)
    for name, st in m["sets"].items():
        for clip in st["clips"]:
            assert (PEEP / f"{name}-{clip}.webp").stat().st_size > 0, (name, clip)
    for clip in STATES:
        assert (PEEP / f"glyph-{clip}.png").exists() and (PEEP / f"glyph-{clip}@1x.png").exists(), clip
    assert len(m["sets"]["dark"]["clips"]["talking"]["open"]) == m["sets"]["dark"]["clips"]["talking"]["frames"]
    assert sum(p.stat().st_size for p in PEEP.iterdir()) < 4.5 * 1024 * 1024, "the app's frames stay small"
    for rel in ("skills/blurt/assets/AppIcon.icns", "skills/blurt/assets/icon.png", "skills/blurt/assets/icon-16.png",
                "skills/blurt/assets/icon-32.png", "assets/logo.png", "assets/peep-readme.png", "assets/peep-readme-dark.png",
                "assets/brand/app-icon-paper.png", "assets/brand/app-icon-dark.png", "assets/brand/peep/peep-vector.svg",
                "assets/brand/peep/peep-flat.svg", "assets/brand/peep/peep-glyph.svg",
                "web/packages/ui/src/assets/app-icon.png", "web/packages/review/src/assets/peep-vector.svg",
                "web/packages/review/src/assets/peep-thinking.png", "apps/desktop/src-tauri/icons/icon.icns"):
        assert (ROOT / rel).stat().st_size > 0, rel
    record = (ROOT / "skills/blurt/scripts/record.py").read_text()
    assert '"Resources" / "Peep"' in record and "APP_ICNS" in record
    for readme in ("README.md", "README.zh-CN.md"):
        head = (ROOT / readme).read_text().splitlines()[0]
        assert "assets/peep-readme-dark.png" in head and "assets/peep-readme.png" in head, readme


def test_app_icon_has_a_dark_appearance_for_macos_26():
    """The app icon is the paper tile, with the dark tile as the dark appearance: an Icon Composer .icon compiled into
    Assets.car (Info.plist CFBundleIconName) for macOS 26, where the system draws the shape and the margin, so it fills
    the Dock's grid like every other icon; the .icns (CFBundleIconFile) for macOS 13–15."""
    import json
    ic = json.loads((ROOT / "assets/brand/AppIcon.icon/icon.json").read_text())
    layer = ic["groups"][0]["layers"][0]
    names = {s.get("appearance", "light"): s["value"] for s in layer["image-name-specializations"]}
    assert set(names) == {"light", "dark"}
    for n in names.values():
        assert (ROOT / "assets/brand/AppIcon.icon/Assets" / n).stat().st_size > 0, n
    assert any(s.get("appearance") == "dark" for s in ic["fill-specializations"])
    plist = (ROOT / "skills/blurt/recorder/macos/Info.plist").read_text()
    assert re.search(r"<key>CFBundleIconName</key>\s*<string>AppIcon</string>", plist)
    assert re.search(r"<key>CFBundleIconFile</key>\s*<string>AppIcon</string>", plist)
    car = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Assets.car"
    if subprocess.run(["which", "assetutil"], capture_output=True).returncode == 0:
        info = json.loads(subprocess.run(["assetutil", "--info", str(car)], capture_output=True, text=True).stdout)
        looks = {e.get("Appearance") for e in info if e.get("Name") == "AppIcon" and e.get("AssetType") == "IconImageStack"}
        assert {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"} <= looks, looks


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


def test_brand_effects_stay_restrained():
    """docs/design/system.md §9: no rotating or multi-colour rims on rows or banners, no completion bloom, no
    decorative underlines. The spectrum appears only in the onboarding hero; gradient text only in the onboarding
    title; the field only in the onboarding hero (and the app icon). "AI is working" is the 1 pt `WorkingOutline` /
    `.aiWorking` / `.ai-working` hairline."""
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    banned = re.compile(r"AIGlow|aiGlow|Celebration|\.celebrate\(|HearingRule|\.conic\b|AngularGradient|BrandArtTile|EmptyArtTile")
    only = {  # pattern → the files that may use it
        re.compile(r"spectrumStops"): {"App/BrandMoments.swift"},
        re.compile(r"AngularGradient"): {"App/BrandMoments.swift"},
        re.compile(r"brandGradientText\(\)|GradientLabel\("): {"Onboarding/Onboarding.swift", "Icons/BrandViews.swift"},
        re.compile(r"BrandField\(|FieldView\("): {"Onboarding/Onboarding.swift", "Icons/BrandViews.swift"},
        re.compile(r"SpectrumGlow\("): {"Onboarding/Onboarding.swift"},
    }
    hits = []
    for p in app.rglob("*.swift"):
        rel = p.relative_to(app).as_posix()
        if rel == "Icons/BrandColor.swift":
            continue
        for i, line in enumerate(p.read_text().splitlines(), 1):
            code = line.split("//", 1)[0]
            if banned.search(code) and not (rel == "App/BrandMoments.swift" and "AngularGradient" in code):
                hits.append(f"{rel}:{i}: {line.strip()}")
            for pat, ok in only.items():
                if pat.search(code) and rel not in ok:
                    hits.append(f"{rel}:{i}: {line.strip()}")
    web = ROOT / "web"
    web_banned = re.compile(r"ai-glow|conic-gradient|--brand-spectrum|--brand-wash|className=\{?[^>]*\bg-(text|field)\b")
    for p in [*web.glob("packages/*/src/**/*"), *web.glob("apps/*/src/**/*")]:
        if p.suffix not in (".ts", ".tsx", ".css") or p.name in ("tokens.css", "theme.css") or p.name.endswith(".test.ts") \
                or "node_modules" in p.parts:
            continue
        for i, line in enumerate(p.read_text().splitlines(), 1):
            if web_banned.search(line):
                hits.append(f"{p.relative_to(ROOT)}:{i}: {line.strip()}")
    assert hits == []
    import json
    t = json.loads((ROOT / "assets/color/tokens.json").read_text())
    assert "aiGlow" not in t["gradient"] and "wash" not in t["gradient"] and "glow" not in t["brand"]
    assert t["brand"]["working"]["width"] == 1


def test_cards_have_one_look():
    """docs/design/system.md §3.2 (v1.0.7, BA-62): every set of cards is the Cards panel — Current and History are one
    grid of the same tiles (OverviewTile, the picture 148 × 100) with the cards' one action cluster ([eye][···][Copy],
    CardChrome.CardActions — no gradient button on a tile) and one preview (CardPreview). The old Recently Dragged Out
    rows (56 × 40 CaptureThumb tiles, TakenRow) are gone; done toasts carry the ok check."""
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    overview = (app / "Capture/Island/CardsOverview.swift").read_text()
    taken = (app / "Capture/TakenPanel.swift").read_text()
    assert "CardActions(" in overview and "preview:" in overview and "BrandButton(" not in overview
    assert "OverviewTile($0, overview: self, used: used)" in overview
    assert "class TakenRow" not in taken and "class TakenThumb" not in taken and "CaptureThumb" not in taken
    assert not (app / "Capture/CaptureThumb.swift").exists()
    assert (app / "Capture/Island/CardPreview.swift").exists()
    assert "BrandColor.Island.ok" in (app / "Capture/Island/IslandContent.swift").read_text()
    assert "t.icon = icon" in (app / "App/AppDelegate.swift").read_text()


def test_web_mascot_outputs_are_copied_from_assets_mascot():
    """The web still plays the 1A chick's frame strips (assets/mascot): they reach the web package unchanged and stay
    small. The mac app no longer carries them."""
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
    assert not (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Mascot").exists()
    assert '"Mascot"' not in (ROOT / "skills/blurt/scripts/record.py").read_text()


def test_mac_mascot_is_peep_frames():
    """One character: the mac mascot is Peep, played from the release package's clay renders (Resources/Peep sprite
    sheets: the paper set on light, the dark-notch set on black) — nothing drawn in code any more — with every state
    the founder mapped: dictation talks (the beak with the level), the countdown and voice notes listen, transcribing
    and organising think (the egg is retired), done / sent / saved / sorted peep and hop, failures shake and droop, the
    launch says hello. No sound arcs anywhere."""
    icons = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Icons"
    assert not (icons / "MascotArt.swift").exists() and not (icons / "MascotGeometry.swift").exists()
    player = (icons / "Mascot.swift").read_text()
    assert "CGImageSourceCreateWithURL" in player and "webp" in player and "reduceMotion" in player
    assert "typealias MascotClip = PeepState" in player
    core = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/Peep.swift").read_text()
    for st in STATES:
        assert f"case {st}" in core, st
    app = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"
    src = "\n".join(p.read_text() for p in app.rglob("*.swift"))
    for gone in (".hatching", ".wobble", "MascotArt", "GlyphMotion", "mascotDrawBug", "mascot.quiet", "arcAlphas",
                 "case egg(", "case cracking("):
        assert gone not in src, gone
    ears = (app / "Capture/Island/Ears.swift").read_text()
    assert "case peepLevel(PeepState, [Float])" in ears and "case thinking(n: Int)" in ears
    island = (app / "Capture/Island/Island.swift").read_text()
    assert ".peepLevel(.talking, Dictation.shared.levels)" in island and ".peepLevel(.listening" in island
    assert "playChick(ok ? .done : .error)" in ears
    assert "MascotView(size: 26, backdrop: .dark)" in (app / "Capture/Chrome.swift").read_text()
    assert ".done : .hello, then: .idle" in (app / "Onboarding/Onboarding.swift").read_text()
    for gone in ("ChickenArt", "HenView", "HenMood", "drawEgg", "eggImage", "BLURT_MASCOT_DIR"):
        assert gone not in src, gone
