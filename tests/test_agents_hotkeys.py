"""Agent order / login detection / failure classification (agents.py — the macOS app mirrors these rules in
Agents.swift), the hotkey config grammar shared with the app (_common.py ↔ Hotkeys.swift), and review.py's
open-in-app plumbing.

  python -m unittest discover -s tests
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import _common  # noqa: E402
import agents  # noqa: E402


def cfg(**rec):
    return {"record": rec}


class Order(unittest.TestCase):
    def test_default_is_the_registry_order(self):
        self.assertEqual(agents.agent_order(cfg())[:2], ["claude", "codex"])
        self.assertEqual(agents.agent_order(cfg()), [d["id"] for d in agents.registry()["agents"]
                                                     if d.get("headless", True) is not False])  # not zcode

    def test_legacy_process_goes_first(self):
        self.assertEqual(agents.agent_order(cfg(process="codex"))[:2], ["codex", "claude"])
        self.assertEqual(agents.agent_order(cfg(process="off"))[0], "claude")

    def test_configured_list_is_exclusive_and_cleaned(self):
        self.assertEqual(agents.agent_order(cfg(agents=["codex", "nope", "codex", "kimi"])), ["codex", "kimi"])
        self.assertEqual(agents.agent_order(cfg(agents="opencode, claude")), ["opencode", "claude"])
        # nothing valid listed → the default, not an empty chain
        self.assertEqual(agents.agent_order(cfg(agents=["nope"]))[0], "claude")
        # record.agents wins over the legacy key
        self.assertEqual(agents.agent_order(cfg(agents=["claude"], process="codex")), ["claude"])

    def test_custom_agent_def(self):
        c = cfg(agents=["mine", "claude"], agent_defs={"mine": {"name": "Mine", "run": ["go", "{prompt}"]}})
        self.assertEqual(agents.agent_order(c), ["mine", "claude"])
        self.assertEqual(agents.definitions(c)["mine"]["bins"], ["mine"])
        # overriding a known one keeps its other fields
        c = cfg(agent_defs={"codex": {"run": ["exec", "{prompt}"]}})
        d = agents.definitions(c)["codex"]
        self.assertEqual(d["run"], ["exec", "{prompt}"])
        self.assertEqual(d["status"]["args"], ["login", "status"])

    def test_live_drafts_follow_the_same_order(self):
        import live
        with mock.patch.object(live.shutil, "which", side_effect=lambda n: f"/bin/{n}"):
            self.assertEqual([a for a, _ in live.Drafter._agents({"agents": ["codex", "kimi", "claude"]})], ["codex", "claude"])
            self.assertEqual([a for a, _ in live.Drafter._agents({"agents": ["codex"], "live_drafts_agent": "claude"})],
                             ["claude", "codex"])
            self.assertEqual([a for a, _ in live.Drafter._agents({})], ["claude", "codex"])


class Login(unittest.TestCase):
    def setUp(self):
        self.defs = agents.definitions(cfg())
        self.home = Path(tempfile.mkdtemp())

    def st(self, aid, code, text, env=None):
        return agents.parse_status(self.defs[aid], code, text, env or {}, self.home)

    def test_claude(self):
        self.assertEqual(self.st("claude", 0, '{"loggedIn": true, "authMethod": "claude.ai"}'), "ready")
        self.assertEqual(self.st("claude", 1, '{\n  "loggedIn": false,\n  "authMethod": "none"\n}'), "logged_out")
        self.assertEqual(self.st("claude", 1, "Not logged in · Please run /login"), "logged_out")
        self.assertEqual(self.st("claude", 1, "error: unknown command 'auth'"), "unknown")
        self.assertEqual(self.st("claude", None, ""), "unknown")      # timed out: just try it

    def test_codex(self):
        self.assertEqual(self.st("codex", 0, "Logged in using ChatGPT"), "ready")
        self.assertEqual(self.st("codex", 1, "Not logged in"), "logged_out")
        self.assertEqual(self.st("codex", 1, "weird", {"OPENAI_API_KEY": "sk-x"}), "configured")

    def test_kimi(self):
        listed = "managed:kimi-code  type=kimi  models=4  source=oauth\n\nDefault model: kimi-code/k3"
        self.assertEqual(self.st("kimi", 0, listed), "configured")
        self.assertEqual(self.st("kimi", 0, ""), "logged_out")
        creds = self.home / ".kimi-code" / "credentials"
        creds.mkdir(parents=True)
        (creds / "kimi-code.json").write_text(json.dumps({"access_token": "", "refresh_token": "", "scope": "x"}))
        self.assertEqual(self.st("kimi", 0, listed), "logged_out")   # provider listed, tokens empty
        (creds / "kimi-code.json").write_text(json.dumps({"access_token": "", "refresh_token": "r"}))
        self.assertEqual(self.st("kimi", 0, listed), "configured")

    def test_opencode_and_gemini(self):
        self.assertEqual(self.st("opencode", 0, "┌  Credentials ~/.local/share/opencode/auth.json\n│\n└  3 credentials"), "configured")
        self.assertEqual(self.st("opencode", 0, "└  0 credentials"), "logged_out")
        self.assertEqual(self.st("opencode", 0, "└  0 credentials", {"ANTHROPIC_API_KEY": "x"}), "configured")
        self.assertEqual(self.st("gemini", None, ""), "logged_out")
        self.assertEqual(self.st("gemini", None, "", {"GEMINI_API_KEY": "x"}), "configured")
        (self.home / ".gemini").mkdir()
        (self.home / ".gemini" / "oauth_creds.json").write_text("{}")
        self.assertEqual(self.st("gemini", None, ""), "configured")

    def test_check_not_installed(self):
        r = agents.check(self.defs["gemini"], env={"PATH": str(self.home)}, lang="zh")
        self.assertEqual((r["state"], r["why"]), ("not_installed", "没安装"))
        self.assertIn("npm", r["fix"])
        self.assertFalse(agents.usable("logged_out"))
        self.assertTrue(agents.usable("configured"))


class Failures(unittest.TestCase):
    def test_classes(self):
        c = agents.classify
        self.assertEqual(c("error: failed to run prompt: internal: The provided authorization grant is invalid"), "auth")
        self.assertEqual(c('API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has expired."}}'), "auth")
        self.assertEqual(c("Not logged in · Please run /login"), "auth")
        self.assertEqual(c("error: provider managed:kimi-code has no credential configured"), "auth")
        self.assertEqual(c("ERROR: stream error: 429 Too Many Requests: You've hit your usage limit."), "quota")
        self.assertEqual(c("Claude AI usage limit reached|1761062400"), "quota")
        self.assertEqual(c("TypeError: fetch failed\n  cause: Error: getaddrinfo ENOTFOUND api.anthropic.com"), "network")
        self.assertEqual(c("\x1b[0m\n> build · claude-sonnet-4-5\n\x1b[91mError: \x1b[0mNot Found\n"), "model")
        self.assertEqual(c("Error: The model `gpt-9` does not exist or you do not have access to it."), "model")
        self.assertEqual(c("Unknown skill: blurt"), "skill")
        self.assertIsNone(c("Wrote 5 items: 2 issues, 1 idea.\nDone."))
        self.assertIsNone(c(""))

    def test_only_the_tail_and_errors_first(self):
        # a codex log echoes tool output: an old "quota" line far up doesn't make it a quota failure
        log = "exec grep -rn quota src/\nsrc/billing/quota.py:12 def quota():\n" + "ok\n" * 200 + "ERROR: stream disconnected before completion"
        self.assertEqual(agents.classify(log), "network")

    def test_reason(self):
        self.assertEqual(agents.failure_reason("auth", "Codex", "run `codex login`", "en"), "Codex's login has expired: run `codex login`")
        self.assertIn("限流", agents.failure_reason("quota", "Codex", lang="zh"))
        self.assertEqual(agents.failure_reason(None, "Kimi Code", lang="en", code=3), "Kimi Code didn't finish (exit 3)")


class Hotkeys(unittest.TestCase):
    def test_parse(self):
        p = _common.parse_hotkey
        self.assertEqual(p("opt+shift+R"), (("opt", "shift"), "R"))
        self.assertEqual(p("⌥⇧a"), (("opt", "shift"), "A"))
        self.assertEqual(p("Alt+Shift+r"), (("opt", "shift"), "R"))
        self.assertEqual(p("shift+cmd+ctrl+opt+space"), (("ctrl", "opt", "shift", "cmd"), "Space"))
        self.assertEqual(p("ctrl+F5"), (("ctrl",), "F5"))
        self.assertEqual(p("F13"), ((), "F13"))                  # F-keys may stand alone
        self.assertEqual(p("opt+shift+/"), (("opt", "shift"), "/"))
        for bad in ("R", "shift+R", "opt+shift+RR", "opt+shift+R+S", "off", "", None, 3, "ctrl+F99", "opt+é"):
            self.assertIsNone(p(bad), bad)

    def test_spec_and_label(self):
        h = _common.parse_hotkey("⌃⌥⇧⌘p")
        self.assertEqual(_common.hotkey_spec(h), "ctrl+opt+shift+cmd+P")
        self.assertEqual(_common.hotkey_label(h, mac=True), "⌃⌥⇧⌘P")
        self.assertEqual(_common.hotkey_label(h, mac=False), "Ctrl+Alt+Shift+Win+P")
        self.assertEqual(_common.hotkey_label(None), "")
        self.assertEqual(_common.hotkey_spec(None), "off")

    def test_config(self):
        with mock.patch.dict(os.environ, {"BLURT_HOTKEY_MODS": ""}):
            h = _common.hotkeys_from_config(cfg(hotkeys={"record": "ctrl+opt+R", "menu": "off", "snap": False, "pause": "garbage"}))
        self.assertEqual(h["record"], (("ctrl", "opt"), "R"))
        self.assertIsNone(h["menu"])
        self.assertIsNone(h["snap"])
        self.assertEqual(h["pause"], (("opt", "shift"), "P"))     # unreadable → default
        self.assertEqual(h["stop"], (("opt", "shift"), "S"))
        self.assertEqual(set(h), set(_common.HOTKEY_ACTIONS))
        with mock.patch.dict(os.environ, {"BLURT_HOTKEY_MODS": "ctrl+opt+shift+cmd"}):
            h = _common.hotkeys_from_config(cfg())
        self.assertEqual(h["snap"], (("ctrl", "opt", "shift", "cmd"), "A"))

    def test_windows_registration(self):
        import tk_recorder
        self.assertEqual(tk_recorder.win_hotkey(_common.parse_hotkey("alt+shift+P")), (0x1 | 0x4, ord("P")))
        self.assertEqual(tk_recorder.win_hotkey(_common.parse_hotkey("ctrl+F5")), (0x2, 0x74))
        self.assertEqual(tk_recorder.win_hotkey(_common.parse_hotkey("ctrl+alt+/")), (0x3, 0xBF))
        self.assertIsNone(tk_recorder.win_hotkey(None))


class ReviewOpen(unittest.TestCase):
    def test_open_mode(self):
        import review
        with mock.patch.object(review, "IS_MAC", True):
            self.assertEqual(review.open_mode(None, {}), "app")
            self.assertEqual(review.open_mode(None, {"review": {"open_in": "browser"}}), "browser")
            self.assertEqual(review.open_mode("none", {"review": {"open_in": "app"}}), "none")
        with mock.patch.object(review, "IS_MAC", False):
            self.assertEqual(review.open_mode(None, {}), "browser")
            self.assertEqual(review.open_mode(None, {"review": {"open_in": "app"}}), "browser")   # no app off macOS

    def test_app_seen_and_download(self):
        import review
        tmp = Path(tempfile.mkdtemp())
        (tmp / "frames").mkdir()
        (tmp / "frames" / "a.jpg").write_bytes(b"jpeg")
        (tmp / "items.json").write_text('{"items": []}')
        done, seen = threading.Event(), threading.Event()
        srv = ThreadingHTTPServer(("127.0.0.1", 0), review.make_handler(tmp, done, seen))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        urllib.request.urlopen(base + "/").read()
        self.assertFalse(seen.is_set())                          # a browser
        urllib.request.urlopen(base + "/?in=app").read()
        self.assertTrue(seen.is_set())                           # the Blurt window
        r = urllib.request.urlopen(base + "/files/frames/a.jpg?download=1")
        self.assertIn("attachment", r.headers["Content-Disposition"])
        self.assertIn(tmp.name, r.headers["Content-Disposition"])
        self.assertEqual(r.read(), b"jpeg")
        self.assertIsNone(urllib.request.urlopen(base + "/files/frames/a.jpg").headers["Content-Disposition"])


if __name__ == "__main__":
    unittest.main()
