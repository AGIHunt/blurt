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
    for brand in ("bug", "spark", "document", "checkbox", "mic", "waveform", "snap", "agent", "agent-run", "mcp"):
        assert brand in names
    for gone in ("chicken", "blurt", "egg", "egg-fill", "hatch", "hatched", "peck"):   # the old chick's line glyphs
        assert gone not in names, gone


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
    (Windows / Linux) shows Peep's flat mark (import_peep.py), no longer the `blurt` line glyph."""
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
    assert "TRAY_ICON" not in build and "def tray(" not in build
    assert "tray-white.png" in (ROOT / "assets/brand/import_peep.py").read_text()


PEEP = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Peep"
STATES = ("idle", "hello", "listening", "talking", "thinking", "done", "error")


def test_peep_is_imported_from_its_release_package():
    """Peep has one source, the Blender model, and reaches the repo only through assets/brand/import_peep.py from the
    release package: the app's sprite sheets and glyph frames with peep.json, the app icon (.icns, the macOS 26 .icon,
    the 1024 tiles), the brand SVGs, the README pictures and the review page's drawing. The old chicks (the 4A line
    chick, the 1A round chick, the earlier logos) are gone from the repo; git history keeps them."""
    import json
    brand = ROOT / "assets/brand"
    assert (brand / "import_peep.py").exists()
    for gone in ("chick.swift", "build.py", "glyph.svg", "logo.svg", "app-icon.svg", "legacy"):
        assert not (brand / gone).exists(), gone
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
            # the onboarding title is the one place gradient text is allowed, as on the Mac (Onboarding.swift)
            if web_banned.search(line) and not (p.name == "Welcome.tsx" and "wl-h1 g-text" in line):
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


def test_web_mascot_is_peep():
    """Windows / Linux show Peep as the Mac does: @blurt/icons/mascot plays the release package's clay sheets (the notch
    set without the contact shadow, cut per tier by import_peep.py — `s` for the island, `l` for the app window), each
    app importing only its tier; the island's ear talks with the voice while you dictate, listens to a voice note and
    thinks while captures are organised; the welcome says hello, the empty states idle. The Tauri app's icons and tray
    are Peep's tiles and flat mark. The 1A chick's strips are gone."""
    import json
    web = ROOT / "web/packages/icons"
    m = json.loads((web / "peep/peep.json").read_text())
    assert "import_peep.py" in m["_"]
    assert {"idle", "listening", "talking", "thinking", "done", "error"} <= set(m["tiers"]["s"]["clips"])
    assert {"idle", "hello", "done"} <= set(m["tiers"]["l"]["clips"])
    sheets = list((web / "peep").glob("*.webp"))
    assert sheets and sum(p.stat().st_size for p in sheets) < 800 * 1024
    assert not (web / "mascot").exists() and not (ROOT / "assets/mascot").exists()
    assert not (ROOT / "assets/brand/legacy").exists()
    island = (ROOT / "web/apps/overlays/src/island.ts").read_text()
    assert "import '@blurt/icons/peep-s'" in island and "setMascotLevel(" in island
    assert "mascotHtml('talking', { size: 24, level: true })" in island and "mascotHtml('listening'" in island
    for gone in ("'wobble'", "'hatching'", "'happy'", "ic('chicken'"):
        assert gone not in island, gone
    desk = ROOT / "web/apps/desktop/src"
    assert "import '@blurt/icons/peep-l'" in (desk / "main.tsx").read_text()
    assert "clip={last ? 'done' : 'hello'} then=\"idle\"" in (desk / "components/Welcome.tsx").read_text()
    empty = (desk / "components/EmptyState.tsx").read_text()
    assert "<Mascot clip={busy ? 'thinking' : 'idle'} size={80}" in empty  # idle at rest, thinking while a place loads
    icons = ROOT / "apps/desktop/src-tauri/icons"
    for n in ("icon.ico", "icon.png", "32x32.png", "64x64.png", "128x128.png", "128x128@2x.png", "icon.icns",
              "tray-black.png", "tray-white.png"):
        assert (icons / n).stat().st_size > 0, n
    assert not (icons / "tray.svg").exists()
    ico = (icons / "icon.ico").read_bytes()
    assert ico[:4] == b"\0\0\1\0" and int.from_bytes(ico[4:6], "little") == 6, "16 24 32 48 64 256"


def test_tray_marks_fit_each_size_and_share_one_shape():
    """The Windows tray: Peep drawn for each notification-area size (16 / 20 / 24 / 32 px; tray.rs picks one by
    SM_CXSMICON), black and white from one alpha so the eye is a hole on both taskbars (the package's white mark had it
    filled in), the eye at least 3 px clear at 16; the take's dot and pause bars on whole pixels at every size."""
    from PIL import Image
    icons = ROOT / "apps/desktop/src-tauri/icons"
    for n in (16, 20, 24, 32):
        black = Image.open(icons / f"tray-black-{n}.png").convert("RGBA")
        white = Image.open(icons / f"tray-white-{n}.png").convert("RGBA")
        assert black.size == white.size == (n, n)
        assert black.getchannel("A").tobytes() == white.getchannel("A").tobytes(), n
        # the eye: a hole inside the body (mostly clear, alpha under half, surrounded by ink; its anti-aliased rim counts)
        a = black.getchannel("A").load()
        holes = [(x, y) for y in range(n) for x in range(n) if a[x, y] < 128 and 0 < x < n - 1
                 and any(a[x - d, y] == 255 for d in range(1, x + 1)) and any(a[x + d, y] == 255 for d in range(1, n - x))
                 and any(a[x, y - d] == 255 for d in range(1, y + 1)) and any(a[x, y + d] == 255 for d in range(1, n - y))]
        assert len(holes) >= 9, (n, len(holes))
        for take in ("rec-light", "rec-dark", "paused-light", "paused-dark"):
            assert Image.open(icons / f"tray-{take}-{n}.png").size == (n, n)
    big_b = Image.open(icons / "tray-black.png").getchannel("A").tobytes()
    assert big_b == Image.open(icons / "tray-white.png").getchannel("A").tobytes()
    tray = (ROOT / "apps/desktop/src-tauri/src/tray.rs").read_text()
    assert "SM_CXSMICON" in tray and 'sized!("tray-white")' in tray


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


def _sf(icon: str) -> list[str]:
    """The SF Symbols a family glyph stands for (sf-symbols.json, through its aliases)."""
    import json

    m = json.loads((ROOT / "assets/icons/sf-symbols.json").read_text())
    name = m["aliases"].get(icon, icon)
    return m["generic"].get(name, []) + m["nearest"].get(name, [])


# the SF Symbols that are one metaphor with another name ("terminal" and "apple.terminal" are both a prompt in a window)
SAME = {"terminal": "apple.terminal"}
# one pane under two ids: the Mac's Remote is Windows / Linux's Phone (Blurt Remote reaches every host since v1.0.15)
WIN_ID = {"remote": "phone"}


def test_windows_settings_panes_use_the_macs_metaphors():
    """Each Settings pane on Windows / Linux shows the glyph drawn for the SF Symbol the Mac's sidebar shows
    (SettingsCatalog.panes; SettingsWindow overrides Agents with a terminal) — docs/design/windows-parity/icons.md."""
    cat = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/SettingsCatalog.swift").read_text()
    mac = {WIN_ID.get(k, k): v for k, v in re.findall(r'pane\("(\w+)", "[^"]+", "\w+", "([\w.]+)"', cat)}
    win_src = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Settings/SettingsWindow.swift").read_text()
    if 'self == .agents ? "terminal"' in win_src:
        mac["agents"] = "terminal"
    ts = (ROOT / "web/apps/desktop/src/settings/catalog.ts").read_text()
    win = dict(re.findall(r"\{ id: '(\w+)', title: '[^']+', icon: '([\w-]+)'", ts))
    assert set(win) == set(mac), (set(win) ^ set(mac))
    for pane, sym in mac.items():
        assert SAME.get(sym, sym) in _sf(win[pane]), (pane, sym, win[pane], _sf(win[pane]))


def test_windows_main_sidebar_uses_the_macs_metaphors():
    """The main window's places: tray, half circle, the dashed ring, the list in a box, the character at the cursor
    (SidebarController) — never the Windows build's own stand-ins."""
    side = (ROOT / "web/apps/desktop/src/components/Sidebar.tsx").read_text()
    glyphs = (ROOT / "web/apps/desktop/src/components/glyphs.tsx").read_text()
    mac = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/MainWindow/SidebarController.swift").read_text()
    for place, sym in [("inbox", "tray"), ("all", "list.bullet.rectangle"), ("dictation", "character.cursor.ibeam")]:
        assert f'"{sym}"' in mac, sym
        icon = re.search(rf"row\('{place}', [^<]+<Icon name=\"([\w-]+)\"", side).group(1)
        assert sym in _sf(icon), (place, icon)
    assert "circle.righthalf.filled" in mac and "<ProgressGlyph" in side and "name=\"progress\"" in glyphs
    assert "circle.righthalf.filled" in _sf("progress") and "circle.dashed" in _sf("unassigned")
    # the window's marks are the family's glyphs, not a second hand-drawn set
    assert "<path" not in glyphs.replace("<path d={FOLDER}", "")
