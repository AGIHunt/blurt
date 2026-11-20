"""Copy Text from Screen (⌥⇧C) end to end in the real app (opt-in GUI test: BLURT_GUI_TESTS=1 on macOS): an isolated copy
of the app gets `screentext x,y,w,h PNG` (a fixture crop stands in for the screen, so nothing is captured), reads it
with Vision + BlurtCore ScreenText, and puts the text on a private pasteboard (BLURT_TEST_PASTEBOARD: the user's
clipboard is never touched). Checks: the event's text and the pasteboard's agree, the text matches the fixture's
expectation (tests/fixtures/screen_text), and the whole thing — still, Vision, layout — is quick.

  BLURT_GUI_TESTS=1 uv run pytest tests/test_screen_text_app.py -q -s
  BLURT_GUI_APP=/path/Blurt.app   use an app you already built
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_gui_layout as gui  # noqa: E402

FIX = gui.ROOT / "tests" / "fixtures" / "screen_text"
CASES = [json.loads(l) for l in (FIX / "cases.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
PASTEBOARD = f"dev.blurt.test.screentext.{os.getpid()}"

pytestmark = pytest.mark.skipif(sys.platform != "darwin" or os.environ.get("BLURT_GUI_TESTS") != "1",
                                reason="GUI test: BLURT_GUI_TESTS=1 on macOS")


def content(s: str) -> str:
    import unicodedata
    return "".join(unicodedata.normalize("NFKC", s).split())


def distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def read_pasteboard(name: str) -> str:
    js = ('function run(a){ObjC.import("AppKit");var p=$.NSPasteboard.pasteboardWithName(a[0]);'
          'var s=p.stringForType($.NSPasteboardTypeString);return JSON.stringify(s.isNil()?"":s.js)}')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js, name], capture_output=True, text=True, timeout=15).stdout
    return json.loads(out)        # JSON: osascript's own output turns tabs into spaces


def test_screen_text_end_to_end():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t).resolve()     # /var → /private/var: the app's pid is found by its real path
        app_path = Path(os.environ["BLURT_GUI_APP"]) if os.environ.get("BLURT_GUI_APP") else gui.build_app(tmp)
        app_path = gui.isolated_copy(app_path, tmp)
        home, ws = gui.make_world(tmp)
        # the second pass on this Mac's model when it is installed (screen_text.py models): its merge is checked too
        refine = os.environ.get("BLURT_SCREEN_TEXT_REFINE") == "1"
        if refine:
            cfg = home / "config.json"
            c = json.loads(cfg.read_text()) if cfg.exists() else {}
            c.setdefault("record", {})["screen_text"] = {"refine": "local"}
            cfg.write_text(json.dumps(c))
        app = gui.App(app_path, home, ws, "en", tmp / "app.log")
        app.extra_env = {"BLURT_TEST_PASTEBOARD": PASTEBOARD}
        app.start()
        try:
            # the test channel is listened to a moment after the app says it is ready: knock until it answers
            for _ in range(20):
                app.mark()
                app.post("hello", "shell")
                try:
                    app.wait("test_command", timeout=0.5)
                    break
                except TimeoutError:
                    pass
            worst, slow = 0.0, []
            for c in CASES:
                png = FIX / f"{c['name']}.png"
                app.mark()
                app.post(f"screentext 100,100,400,200 {png}", "shell")
                e = app.wait("screen_text", timeout=20)
                got, exp = e.get("text", ""), c["expected"]
                err = distance(content(got), content(exp)) / max(1, len(content(exp)))
                worst = max(worst, err)
                assert err <= 0.06, f"{c['name']}: {got!r}"
                if not refine:      # (with the second pass on, the clipboard may already hold its merge)
                    assert read_pasteboard(PASTEBOARD) == got, c["name"]
                if e["ms"] > 1500:
                    slow.append((c["name"], e["ms"]))
                line = f"{c['name']:16s} {e['ms']:4d} ms (vision {e['vision_ms']}) err {err:.3f}"
                if refine:
                    r = app.wait("screen_text_refine", timeout=60)
                    final = read_pasteboard(PASTEBOARD)
                    rerr = distance(content(final), content(exp)) / max(1, len(content(exp)))
                    assert rerr <= err + 1e-9, f"{c['name']}: the second pass made it worse: {final!r}"
                    line += f" → refined err {rerr:.3f} ({r.get('model_ms')} ms, load {r.get('load_ms')})"
                print(line)
            assert not slow, slow
            # ⌥⇧T: the same text, translated (the local polish model, or the cloud one when it is set up)
            app.mark()
            app.post(f"screentranslate 100,100,400,200 {FIX / 'bottom_halfcut.png'}", "shell")
            t = app.wait("screen_translate", timeout=90)
            assert t["ok"] and t["text"].strip(), t
            assert "temporary" in t["text"].lower() or "repo" in t["text"].lower(), t["text"]
            print(f"translate {t['ms']} ms ({t.get('model')}): {t['text'][:120]!r}")
            assert read_pasteboard(PASTEBOARD) == t["text"]
        finally:
            app.stop()


def test_translation_card_takes_esc_only_under_the_pointer():
    """⌥T's card (ScreenTextCard): Esc is a system-wide hotkey only while the pointer is over the card — an Esc for the
    app in front (interrupting Claude Code) is never swallowed; otherwise the card goes on its 10 s timer."""
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t).resolve()
        app_path = Path(os.environ["BLURT_GUI_APP"]) if os.environ.get("BLURT_GUI_APP") else gui.build_app(tmp)
        app_path = gui.isolated_copy(app_path, tmp)
        home, ws = gui.make_world(tmp)
        app = gui.App(app_path, home, ws, "en", tmp / "app.log")
        app.extra_env = {"BLURT_TEST_PASTEBOARD": PASTEBOARD}
        app.start()
        try:
            for _ in range(20):
                app.mark()
                app.post("hello", "shell")
                try:
                    app.wait("test_command", timeout=0.5)
                    break
                except TimeoutError:
                    pass

            def card(cmd: str) -> dict:
                app.mark()
                app.post(f"textcard {cmd}", "shell")
                return app.wait("text_card_state", timeout=5)

            s = card("The replica is billed by the hour.")
            assert s["shown"] and not s["esc"], s                 # shown, Esc left to the app in front
            s = card("esc")
            assert s["shown"], "an Esc with the pointer elsewhere closed the card"
            assert card("hover on")["esc"]                         # the pointer on it: Esc is the card's
            assert not card("hover off")["esc"]                    # gone again when it leaves
            card("hover on")
            s = card("esc")
            assert not s["shown"] and not s["esc"], s              # Esc closed it and let the key go
            s = card("Another one")
            assert s["shown"] and not s["esc"], s
            assert not card("close")["esc"]
        finally:
            app.stop()


def _started(tmp: Path) -> "gui.App":
    """An isolated copy, started, its test channel answering. A fixture stands in for the screen (BLURT_TEST_STILL)."""
    app_path = Path(os.environ["BLURT_GUI_APP"]) if os.environ.get("BLURT_GUI_APP") else gui.build_app(tmp)
    app_path = gui.isolated_copy(app_path, tmp)
    home, ws = gui.make_world(tmp)
    app = gui.App(app_path, home, ws, "en", tmp / "app.log")
    app.extra_env = {"BLURT_TEST_PASTEBOARD": PASTEBOARD, "BLURT_TEST_STILL": FIX / f"{CASES[0]['name']}.png"}
    if os.environ.get("CFFIXED_USER_HOME"):     # a runner's own home for the app (its caches, its hotkey registry)
        app.extra_env["CFFIXED_USER_HOME"] = os.environ["CFFIXED_USER_HOME"]
    app.start()
    for _ in range(20):
        app.mark()
        app.post("hello", "shell")
        try:
            app.wait("test_command", timeout=0.5)
            break
        except TimeoutError:
            pass
    return app


def test_one_screen_picker_at_a_time():
    """⌥C's crosshair is up: ⌥A and ⌥R are refused, as ⌥C is while their area picker is up. Two pickers stacked left
    the crosshair on screen when the other one ended, its system-wide Esc gone with the other's (they share it)."""
    with tempfile.TemporaryDirectory() as t:
        app = _started(Path(t).resolve())
        try:
            def pickers() -> dict:
                app.mark()
                app.post("pickers", "shell")
                return app.wait("pickers", timeout=5)

            def until(f, what: str) -> dict:
                for _ in range(25):
                    p = pickers()
                    if f(p):
                        return p
                    time.sleep(0.2)
                raise AssertionError(f"{what}: {p}")

            app.post("screentext", "shell")                                  # ⌥C: the crosshair
            until(lambda p: p["text"] and p["esc"], "the crosshair didn't come up")
            for cmd, refused in (("snap", "snap_refused"), ("record", "record_refused")):
                app.mark()
                app.post(cmd, "shell")                                      # ⌥A / ⌥R over it
                assert app.wait(refused, timeout=5)["why"] == "text_picker"
                p = pickers()
                assert p["text"] and not p["area"] and p["esc"], p
            app.post("pickesc", "shell")                                     # Esc: the crosshair goes, and its Esc
            until(lambda p: not p["text"] and not p["esc"], "Esc left the crosshair")
            app.mark()
            app.post("snap", "shell")                                        # ⌥A alone still opens its picker
            app.wait("snap_pick", timeout=5)
            p = until(lambda p: p["area"], "the snap picker didn't come up")
            assert p["esc"] and not p["text"], p
            app.post("pickercancel", "shell")
            until(lambda p: not p["area"] and not p["esc"], "cancelling left the snap picker's Esc")
        finally:
            app.stop()


def test_live_words_never_come_back_after_the_take():
    """The words under the island: once a take's panel has gone, its late words (a voice note's last piece, transcribed
    after the note went to Unassigned) don't bring it back, where it stayed for good and closed every ⌥C / ⌥T card."""
    with tempfile.TemporaryDirectory() as t:
        app = _started(Path(t).resolve())
        try:
            def live(cmd: str) -> dict:
                app.mark()
                app.post(f"live {cmd}", "shell")
                return app.wait("live_state", timeout=5)

            assert live("show Three things. First, the sign-up page")["shown"]
            s = live("late Three things. First, the sign-up page loads slowly.")
            assert not s["shown"], s
            time.sleep(0.5)
            app.mark()
            app.post("textcard The replica is billed by the hour.", "shell")
            assert app.wait("text_card_state", timeout=5)["shown"]           # a text card isn't closed by a stale panel
            assert not live("caret -")["shown"]
        finally:
            app.stop()
