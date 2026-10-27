"""Layout lint, unattended (opt-in GUI test: BLURT_GUI_TESTS=1 on macOS). Opens every screen the test hooks can reach in an
isolated copy of the app and asks its `layoutcheck` hook (BlurtApp/System/LayoutCheck.swift) whether any control or text
lies outside its window, under the traffic lights, on top of another control, or truncated — in English and Chinese, and
at each resizable window's minimum size. Any problem fails the test, with the screen, window and element named.

Settings panes are also held to one grid (`settingsgrid`, SettingsKit's SettingsGrid; system.md §3.4): every box shares
one left and one right edge, every row's text starts at the box's inset (or at one icon gutter after it), headings, lead
lines and footnotes start at that same text column, every trailing control, value, size and keycap ends at the box's
inset on the right, and every pane's first thing starts at the same height.

Why: the setup assistant shipped with its Back / Done buttons cut off at the bottom of the window (the SwiftUI layout kept
out of the title bar's safe area, the window was sized without it). Screenshots and reviews missed it; this measures it.

  BLURT_GUI_TESTS=1 uv run pytest tests/test_gui_layout.py -q -s          the whole run (builds the app, ~3-5 min)
  python3 tests/test_gui_layout.py [--app PATH] [--lang en,zh-Hans] [--only onboarding,settings] [--json OUT]
                                                                           the same as a script: a report, exit 1 on problems
  BLURT_GUI_APP=/path/Blurt.app   use an app you already built (`record.py build` with a scratch BLURT_HOME) instead

Isolation: its own BLURT_HOME / BLURT_WORKSPACE under a temp dir (a small fixture world from make_fixture.py), a copy of
the app re-signed as dev.blurt.recorder.layouttest, launched in the background through LaunchServices with test
commands on a private channel; no microphone, no clipboard, no events into other apps, and it is quit at the end. Its
windows do appear on screen while it runs (the accessibility tree is only built for windows that are shown). When
several GUI tests share the machine, run it under their lock: `python3 gui_lock.py -- python3 tests/test_gui_layout.py`.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
MACOS = ROOT / "skills" / "blurt" / "recorder" / "macos"
BUNDLE_ID = "dev.blurt.recorder.layouttest"
SETTINGS_PANES = ["general", "projects", "dictation", "speech", "shortcuts", "agents", "privacy", "storage"]
ONBOARDING_STEPS = 4
MAIN_SCOPES = ["inbox", "progress", "unassigned", "all", "dictation"]
EMPTY_STATES = ["first", "inbox_zero", "project", "no_results", "no_index", "failed", "missing", "scanning", "discarded"]


# ---- the app ---------------------------------------------------------------------------------------------------------

def build_app(tmp: Path) -> Path:
    """`record.py build` into a scratch BLURT_HOME, then a copy re-signed with the test's own bundle id."""
    home = tmp / "build-home"
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.json").write_text(json.dumps({"record": {"install_app": False}}))
    env = dict(os.environ, BLURT_HOME=str(home), BLURT_WORKSPACE=str(tmp / "build-ws"))
    r = subprocess.run(["uv", "run", "-q", str(SCRIPTS / "record.py"), "build"], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=1800)
    built = home / "Blurt.app"
    if not (built / "Contents" / "MacOS" / "blurt-recorder").exists():
        raise RuntimeError("build failed:\n" + r.stdout[-2000:] + r.stderr[-2000:])
    return built


def isolated_copy(app: Path, tmp: Path) -> Path:
    dest = tmp / "Blurt.app"
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(app, dest, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE_ID}", str(dest / "Contents" / "Info.plist")],
                   check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID, str(dest)], capture_output=True, check=True)
    return dest


def make_world(tmp: Path) -> tuple[Path, Path]:
    home, ws = tmp / "home", tmp / "ws"
    home.mkdir(parents=True, exist_ok=True)
    ws.mkdir(parents=True, exist_ok=True)
    (home / "config.json").write_text(json.dumps({"record": {"install_app": False}, "app": {"onboarded": True}}))
    env = dict(os.environ, BLURT_HOME=str(home), BLURT_WORKSPACE=str(ws))
    subprocess.run([sys.executable, str(MACOS / "Tests" / "make_fixture.py"), "--items", "120", "--per-session", "20"],
                   env=env, capture_output=True, text=True, timeout=600)
    return home, ws


class App:
    """One launch of the isolated app; commands over its private test channel, answers from its stdout."""

    def __init__(self, app: Path, home: Path, ws: Path, lang: str, log: Path):
        self.app, self.home, self.ws, self.lang, self.log = app, home, ws, lang, log
        self.channel = f"layout{os.getpid()}"
        self.pid: int | None = None
        self.pos = 0

    def start(self) -> None:
        self.log.write_text("")
        # a voice note listens to this file, never the microphone (6 s of silence)
        quiet = self.home / "quiet.wav"
        if not quiet.exists():
            with wave.open(str(quiet), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(48000)
                w.writeframes(b"\0\0" * 48000 * 6)
        envs = {"BLURT_HOME": self.home, "BLURT_WORKSPACE": self.ws, "BLURT_TMUX_SOCKET": f"blurt-test-{self.channel}",
                "BLURT_TEST_MIC_WAV": quiet,
                "BLURT_NO_NOTIFICATIONS": 1, "BLURT_NO_ONBOARDING": 1, "BLURT_TEST_COMMANDS": 1,
                "BLURT_TEST_CHANNEL": self.channel, "BLURT_SPOTLIGHT_DOMAIN": f"dev.blurt.test.{self.channel}",
                "BLURT_ALLOW_MULTI": 1, "BLURT_DEBUG_CHROME": 1, "PATH": os.environ.get("PATH", ""),
                "HOME": os.environ.get("HOME", "")}
        cmd = ["open", "-n", "-g"]
        for k, v in envs.items():
            cmd += ["--env", f"{k}={v}"]
        cmd += ["--stdout", str(self.log), "--stderr", str(self.log), str(self.app), "--args", "--background",
                "--lang", self.lang, "-AppleLanguages", f"({self.lang})"]
        subprocess.run(cmd, check=True)
        for _ in range(60):
            pids = self.pids()
            if pids:
                self.pid = pids[0]
                break
            time.sleep(0.3)
        if not self.pid:
            raise RuntimeError("the app did not start")
        self.wait("wp6_ready", timeout=30, since=0)

    def pids(self) -> list[int]:
        """This copy's processes (LaunchServices starts it, not us: found by its executable's path)."""
        exe = str(self.app / "Contents" / "MacOS" / "blurt-recorder")
        ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        return [int(l.split(None, 1)[0]) for l in ps.splitlines() if len(l.split(None, 1)) == 2 and l.split(None, 1)[1].startswith(exe)]

    def stop(self) -> None:
        for pid in set(self.pids() + ([self.pid] if self.pid else [])):
            try:
                os.kill(pid, signal.SIGTERM)
                for _ in range(30):
                    time.sleep(0.2)
                    os.kill(pid, 0)
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.pid = None

    def post(self, cmd: str, kind: str = "wp6") -> None:
        name = {"wp6": "dev.blurt.recorder.wp6", "shell": "dev.blurt.recorder.command",
                "terminal": "dev.blurt.recorder.terminal"}[kind] + "." + self.channel
        js = ('function run(a){ObjC.import("Foundation");'
              '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('
              'a[0],$(),$.NSDictionary.dictionaryWithObjectForKey(a[1],"cmd"),true);return "ok"}')
        subprocess.run(["osascript", "-l", "JavaScript", "-e", js, name, cmd], capture_output=True, check=True, timeout=15)

    def events(self, since: int | None = None) -> list[dict]:
        data = self.log.read_bytes()
        out = []
        for line in data[self.pos if since is None else since:].decode("utf-8", "replace").splitlines():
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    def wait(self, event: str, timeout: float = 15, since: int | None = None, **match) -> dict:
        start = self.pos if since is None else since
        t0 = time.time()
        while time.time() - t0 < timeout:
            for e in self.events(start):
                if e.get("event") == event and all(e.get(k) == v for k, v in match.items()):
                    return e
            time.sleep(0.2)
        raise TimeoutError(f"no {event} event within {timeout}s")

    def mark(self) -> None:
        self.pos = self.log.stat().st_size

    def do(self, cmd: str, kind: str = "wp6", settle: float = 1.0) -> None:
        self.post(cmd, kind)
        time.sleep(settle)

    def layoutcheck(self, arg: str = "") -> list[dict]:
        self.mark()
        self.post(f"layoutcheck {arg}".strip())
        return self.wait("layoutcheck", timeout=20)["windows"]


# ---- the screens -----------------------------------------------------------------------------------------------------

def screens(app: App) -> list[tuple[str, str, list[tuple[str, str]]]]:
    """(group, screen, [(channel, command)…]): every screen the hooks can open, in an order that leaves earlier windows
    out of the way (each check reports every visible window; a problem is counted once per window)."""
    s: list[tuple[str, str, list[tuple[str, str]]]] = []
    for n in range(ONBOARDING_STEPS):
        s.append(("onboarding", f"onboarding step {n}", [("wp6", f"onboarding {n}")]))
    s.append(("onboarding", "onboarding closed", [("wp6", "onboardingdone")]))
    for p in SETTINGS_PANES:
        s.append(("settings", f"settings {p}", [("wp6", f"settings {p}")]))
        s.append(("settings", f"settings {p} (bottom)", [("wp6", "settingsscroll bottom")]))
    s.append(("settings", "settings search", [("wp6", "settingssearch dictation")]))
    s.append(("settings", "settings search cleared", [("wp6", "settingssearch")]))
    for sc in MAIN_SCOPES:
        s.append(("main", f"main {sc}", [("wp6", f"main {sc}")]))
    s.append(("main", "main selection", [("wp6", "main all"), ("wp6", "mainsel 0")]))
    s.append(("main", "main job", [("wp6", "main inbox"), ("wp6", "mainfakejob process")]))
    s.append(("main", "main job done", [("wp6", "mainfakejob clear")]))
    for e in EMPTY_STATES:
        s.append(("main", f"main empty {e}", [("wp6", "main inbox"), ("wp6", f"mainempty {e}")]))
    s.append(("main", "main back", [("wp6", "main inbox")]))
    s.append(("panels", "shortcuts panel", [("wp6", "mainshortcuts")]))
    s.append(("panels", "command palette", [("wp6", "mainpalette")]))
    s.append(("panels", "command palette closed", [("wp6", "mainpalette close")]))
    s.append(("panels", "move popover", [("wp6", "main all"), ("wp6", "mainsel 0"), ("wp6", "mainmovepop open")]))
    s.append(("panels", "move popover closed", [("wp6", "mainmovepop close")]))
    s.append(("panels", "dispatch panel", [("wp6", "main all"), ("wp6", "mainsel 0"), ("terminal", "dispatch @selected")]))
    s.append(("panels", "sessions window", [("terminal", "window")]))
    s.append(("panels", "toast", [("wp6", "toastdone")]))
    s.append(("panels", "island", [("shell", "island open")]))
    s.append(("panels", "island switcher", [("shell", "island switcher")]))
    s.append(("panels", "island closed", [("shell", "island close")]))
    # a voice note (from the silent test file: no microphone) — plain, then Structured (its chip, the ear's list mark)
    s.append(("panels", "voice note", [("shell", "voice tap")]))
    s.append(("panels", "voice note structured", [("shell", "voice structure")]))
    s.append(("panels", "voice note cancelled", [("shell", "voice esc")]))
    # the recording's countdown alone over an area (no take: nothing is captured)
    s.append(("panels", "countdown", [("shell", "countdown 3 300,200,700,460 hold")]))
    s.append(("panels", "countdown closed", [("shell", "countdown close")]))
    s.append(("panels", "recently taken", [("shell", "taken show")]))
    s.append(("panels", "recently taken hidden", [("shell", "taken hide")]))
    # a snap (a PNG stands in for the screen: nothing is captured) → its note bubble, then the hanging cards
    still = ROOT / "assets" / "brand" / "legacy" / "logo-1.png"
    s.append(("panels", "snap note bubble", [("shell", f"snapregion 200,200,480,320 {still}")]))
    s.append(("panels", "snap note saved", [("shell", "commit")]))
    s.append(("panels", "hanging cards", [("shell", "cards show")]))
    s.append(("panels", "cards overview", [("shell", "cards older")]))
    s.append(("panels", "cards dismissed", [("shell", "cards dismiss")]))
    return s


# SettingsKit's grid (SettingsMetrics): the box inset, the icon gutter (slot + gap) and the first thing's height
GRID_INSET, GRID_ICON, GRID_FIRST, GRID_TOL = 12.0, 28.0, 26.0, 1.5


def grid_problems(app: "App", pane: str) -> list[dict]:
    """The showing pane against the one grid: a problem per mark off its edge."""
    app.mark()
    app.post("settingsgrid")
    marks = app.wait("wp6", cmd="settingsgrid").get("marks") or []
    boxes = [m for m in marks if m["kind"] == "box"]
    out: list[dict] = []
    def bad(m: dict, what: str) -> None:
        out.append({"kind": "grid", "role": m["kind"], "label": f"{m.get('label', '')}: {what}",
                    "frame": [round(m["x"], 1), round(m["y"], 1), round(m["w"], 1)], "bounds": pane})
    if not boxes:
        return [{"kind": "grid", "role": "page", "label": "no boxes reported", "frame": [], "bounds": pane}]
    left = min(b["x"] for b in boxes)
    right = max(b["max_x"] for b in boxes)
    for m in marks:
        k, x, mx = m["kind"], m["x"], m["max_x"]
        if k == "box" and (abs(x - left) > GRID_TOL or abs(mx - right) > GRID_TOL):
            bad(m, f"box edges {x:.1f}…{mx:.1f}, page's {left:.1f}…{right:.1f}")
        elif k in ("text", "head") and abs(x - (left + GRID_INSET)) > GRID_TOL:
            bad(m, f"starts at {x - left:.1f}, not the text column ({GRID_INSET:g})")
        elif k == "icon_text" and abs(x - (left + GRID_INSET + GRID_ICON)) > GRID_TOL:
            bad(m, f"starts at {x - left:.1f}, not the icon gutter's text ({GRID_INSET + GRID_ICON:g})")
        elif k == "trailing" and abs(mx - (right - GRID_INSET)) > GRID_TOL:
            bad(m, f"ends at {mx - right:.1f} from the box's edge, not at the trailing edge (-{GRID_INSET:g})")
    tops = [m["y"] for m in marks if m["kind"] in ("box", "head")]
    if tops and abs(min(tops) - GRID_FIRST) > GRID_TOL:
        out.append({"kind": "grid", "role": "page", "label": f"first thing at y {min(tops):.1f}, not {GRID_FIRST:g}",
                    "frame": [], "bounds": pane})
    return out


MIN_SIZE_SCREENS = {"settings general", "settings dictation", "settings speech", "settings shortcuts", "settings agents",
                    "settings privacy", "settings storage", "main inbox", "main all", "main dictation", "main selection",
                    "main empty first", "sessions window"}


def run_lint(app: App, only: set[str] | None = None, verbose: bool = True) -> list[dict]:
    """Every screen, then each resizable window at its minimum size; the problems found, each once per window."""
    found: dict[tuple, dict] = {}
    looked = 0
    for group, name, cmds in screens(app):
        if only and group not in only:
            continue
        for kind, cmd in cmds:
            if cmd.endswith("@selected"):          # a command that needs the selected item's uid
                app.mark()
                app.post("mainsel 0")
                uids = app.wait("wp6", cmd="mainsel").get("selected") or []
                cmd = cmd.replace("@selected", ",".join(uids[:1]))
            app.do(cmd, kind, settle=1.2)
        if group == "settings" and name.startswith("settings ") and name.split(" ")[1] in SETTINGS_PANES and len(name.split(" ")) == 2:
            time.sleep(1.0)                        # the page's late lines (sign-in checks, model lists) settle
            for p in grid_problems(app, name.split(" ")[1]):
                key = ("grid", name, p["label"])
                if key not in found:
                    found[key] = {"screen": name, "lang": app.lang, "window": "Settings", "size": "", **p}
            looked += 1
        variants = [""] + (["min", "restore"] if name in MIN_SIZE_SCREENS else [])
        for v in variants:
            windows = app.layoutcheck(v)
            looked += 1
            for w in windows:
                for p in w["problems"]:
                    key = (w["title"], p["kind"], p["role"], p["label"], v == "min")
                    if key not in found:
                        found[key] = {"screen": name + (" at minimum size" if v == "min" else ""), "lang": app.lang,
                                      "window": w["title"], "size": w["size"], **p}
            if verbose:
                n = sum(len(w["problems"]) for w in windows)
                print(f"  [{app.lang}] {name}{' (min)' if v == 'min' else ''}: "
                      + ", ".join(f"{w['title']}={w.get('elements', 0)}" for w in windows) + (f"  -> {n} problem(s)" if n else ""),
                      flush=True)
    if looked == 0:
        raise RuntimeError("no screen checked")
    return list(found.values())


def describe(p: dict) -> str:
    extra = f" over {p['other']}" if p.get("other") else ""
    return (f"[{p['lang']}] {p['screen']} / {p['window']} {p['size']}: {p['kind']} {p['role']} \"{p['label']}\"{extra} "
            f"frame={p['frame']} bounds={p['bounds']}")


def lint(app_path: Path | None, langs: list[str], only: set[str] | None, keep: bool = False) -> list[dict]:
    tmp = Path(tempfile.mkdtemp(prefix="blurt-layout-")).resolve()
    try:
        built = app_path or build_app(tmp)
        app_copy = isolated_copy(built, tmp)
        home, ws = make_world(tmp)
        problems: list[dict] = []
        for lang in langs:
            a = App(app_copy, home, ws, lang, tmp / f"app-{lang}.log")
            try:
                a.start()
                time.sleep(2)
                problems += run_lint(a, only)
            finally:
                a.stop()
        return problems
    finally:
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


# ---- pytest ----------------------------------------------------------------------------------------------------------

try:
    import pytest
except ImportError:  # the script needs no pytest
    pytest = None

if pytest:
    @pytest.mark.gui
    @pytest.mark.skipif(os.environ.get("BLURT_GUI_TESTS") != "1" or sys.platform != "darwin",
                        reason="GUI test: BLURT_GUI_TESTS=1 on macOS")
    def test_no_layout_problems_on_any_screen():
        app = os.environ.get("BLURT_GUI_APP")
        problems = lint(Path(app) if app else None, ["en", "zh-Hans"], None)
        assert not problems, f"{len(problems)} layout problem(s):\n" + "\n".join(describe(p) for p in problems)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--app", type=Path, help="an already built Blurt.app (default: build this checkout)")
    ap.add_argument("--lang", default="en,zh-Hans")
    ap.add_argument("--only", help="groups: onboarding,settings,main,panels")
    ap.add_argument("--json", type=Path, help="write the problems here")
    ap.add_argument("--keep", action="store_true", help="keep the temp dir (logs, world)")
    a = ap.parse_args()
    found = lint(a.app, a.lang.split(","), set(a.only.split(",")) if a.only else None, a.keep)
    if a.json:
        a.json.write_text(json.dumps(found, ensure_ascii=False, indent=1))
    print(f"\n{len(found)} layout problem(s)")
    for p in found:
        print("  " + describe(p))
    sys.exit(1 if found else 0)
