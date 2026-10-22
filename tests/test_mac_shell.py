"""macOS app shell (WP4): the SwiftPM package layout, the Info.plist contract (C7), and — opt-in, BLURT_E2E=1 on a
Mac — a real `record.py build` into a scratch BLURT_HOME followed by the app's `--selftest` (ScriptRunner, ShellEnv,
KeyCombo, Config; no GUI, no screen or mic).

  uv run --with pytest pytest tests/test_mac_shell.py -q
  BLURT_E2E=1 uv run --with pytest pytest tests/test_mac_shell.py -q        # + build (≈1 min) and selftest
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "skills" / "blurt" / "recorder" / "macos"
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"


class Layout(unittest.TestCase):
    def test_package_and_modules(self):
        self.assertTrue((MAC / "Package.swift").exists())
        for rel in ["Sources/BlurtApp/main.swift", "Sources/BlurtApp/App/AppEnvironment.swift",
                    "Sources/BlurtCore/Paths.swift", "Sources/BlurtCore/Config.swift", "Sources/BlurtCore/Script.swift",
                    "Sources/BlurtCore/Hotkeys.swift"]:
            self.assertTrue((MAC / rel).exists(), rel)
        self.assertEqual([f.name for f in MAC.glob("*.swift") if f.name != "Package.swift"], [], "Swift sources belong under Sources/")

    def test_info_plist_contract(self):
        p = plistlib.loads((MAC / "Info.plist").read_bytes())
        self.assertEqual(p["CFBundleIdentifier"], "dev.blurt.recorder")      # never changes: keeps TCC grants
        self.assertEqual(p["CFBundleExecutable"], "blurt-recorder")
        schemes = {s for t in p["CFBundleURLTypes"] for s in t["CFBundleURLSchemes"]}
        self.assertEqual(schemes, {"blurt", "blurt-app"})
        self.assertEqual(p["NSServices"][0]["NSMessage"], "addToBlurt")
        self.assertTrue(p["SUFeedURL"].startswith("https://"))
        self.assertIn("SUPublicEDKey", p)
        self.assertTrue(p["CFBundleVersion"])

    def test_hanging_cards_are_accessible(self):
        # The hanging cards (K7) are drawn in CALayers: without these overrides VoiceOver / the AX tree would see an
        # empty window (live check: the `axcards` test command).
        src = (MAC / "Sources/BlurtApp/Capture/Island/HangingCards.swift").read_text()
        for needle in ["override func accessibilityChildren()", "final class LayerAXElement: NSAccessibilityElement",
                       '"capture.card.ax_shot_n"', "setAccessibilityCustomActions", "override func accessibilityPerformPress()"]:
            self.assertIn(needle, src)

    def test_dispatch_panel_never_defaults_to_a_logged_out_agent(self):
        # e2e v0.7: with Claude Code installed but logged out, the panel picked it (the quick detect can't see logins)
        # and the session stopped at its login page. K5 order: project default → global → detect's pick (with login).
        src = (MAC / "Sources/BlurtApp/Terminal/DispatchPanel.swift").read_text()
        for needle in ["detect(login: true)", "defaultAgent", '"record.default_agent"', '"dispatch.agent.logged_out"',
                       "agentTouched"]:
            self.assertIn(needle, src)

    def test_finish_panel_can_end_the_session_before_merging(self):
        # e2e v0.7: after a finished turn Codex still sits in its window, so Merge was refused ("running") with only
        # Close / Try Again, and Try Again just reloaded the diff
        src = (MAC / "Sources/BlurtApp/Terminal/FinishPanel.swift").read_text()
        self.assertIn('failedCode == "running"', src)
        self.assertIn("func endSessionThen(", src)
        self.assertIn("AgentSessions.shared.stop(job: job, kill: false)", src)

    def test_open_pull_request_says_when_it_only_pushed(self):
        # e2e v0.7: with a remote gh doesn't know, sessions.py pushed and returned pr: null, compare: null — the panel
        # still said "Pull request opened." and the session row "Pull request opened"
        src = (MAC / "Sources/BlurtApp/Terminal/FinishPanel.swift").read_text()
        self.assertIn('phase = .done(prURL == nil ? "pushed" : "compare")', src)
        self.assertIn('"finish.state.pushed"', (MAC / "Sources/BlurtApp/Terminal/SessionsViews.swift").read_text())

    def test_no_review_window_and_nothing_opens_by_itself(self):
        # v0.7 K4 / K7: reviewing happens in the main window; finishing a job never opens a window, a page or a browser
        src = MAC / "Sources" / "BlurtApp"
        self.assertFalse((src / "App" / "ReviewWindow.swift").exists())
        # v0.6 leftovers stay gone: the rope / perch, the per-kind eggs, the chicken-foot claws (threads replaced them)
        for gone in ["Capture/Rope.swift", "Capture/Perch.swift", "Capture/HUDLive.swift", "Capture/Island/Claws.swift",
                     "Capture/Island/ClawArt.swift"]:
            self.assertFalse((src / gone).exists(), gone)
        code = {f: f.read_text() for f in src.rglob("*.swift")}
        for f, t in code.items():
            self.assertNotIn("ReviewHub", t, f.name)
            self.assertNotIn("openReview(", t, f.name)
        for name in ["App/AgentHub.swift", "System/JobNotifier.swift"]:
            t = (src / name).read_text()
            for opener in [".show()", "showInbox()", "reveal(session:", "NSWorkspace.shared.open("]:
                # only inside a closure the user triggers (the island line's action, a notification click)
                for line in t.splitlines():
                    if opener in line:
                        self.assertTrue("{" in line or "action" in line or "didReceive" in line, f"{name}: {line.strip()}")

    def test_build_inputs(self):
        sys.path.insert(0, str(SCRIPTS))
        import record
        files = {str(f.relative_to(MAC)) for f in record.swift_sources()}
        self.assertIn("Package.swift", files)
        self.assertIn("Info.plist", files)
        self.assertIn("Sources/BlurtCore/Hotkeys.swift", files)
        self.assertFalse(any(f.startswith(".build") for f in files))


@unittest.skipUnless(os.environ.get("BLURT_E2E") == "1" and sys.platform == "darwin" and shutil.which("swift"),
                     "opt-in: BLURT_E2E=1 on macOS with swift")
class BuildAndSelftest(unittest.TestCase):
    def test_build_then_selftest(self):
        home = Path(tempfile.mkdtemp(prefix="blurt-shell-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        (home / "config.json").write_text(json.dumps({"record": {"install_app": False}}))
        env = {k: v for k, v in os.environ.items() if k != "BLURT_UNIVERSAL"}
        env.update(BLURT_HOME=str(home), BLURT_WORKSPACE=str(home / "ws"))
        uv = shutil.which("uv") or "uv"
        installed = Path.home() / "Applications" / "Blurt.app" / "Contents" / "MacOS" / "blurt-recorder"
        before = installed.stat().st_mtime if installed.exists() else None
        b = subprocess.run([uv, "run", "-q", str(SCRIPTS / "record.py"), "build"], env=env, capture_output=True, text=True)
        self.assertIn('"native": "', b.stdout, b.stderr[-2000:])
        app = home / "Blurt.app"
        self.assertTrue((app / "Contents" / "Info.plist").exists())
        self.assertEqual(installed.stat().st_mtime if installed.exists() else None, before, "a test build must not install")
        size = sum(f.stat().st_size for f in app.rglob("*") if f.is_file())
        self.assertLess(size, 6 * 1024 * 1024, f"Blurt.app is {size / 1e6:.1f} MB")
        fx = home / "fx"
        shutil.copytree(ROOT / "tests" / "fixtures" / "sessions", fx)
        env["CODEX_HOME"] = str(home / "codex")
        env["CLAUDECODE"] = "1"
        r = subprocess.run([str(app / "Contents" / "MacOS" / "blurt-recorder"), "--selftest", str(fx / "20261021-101500")],
                           env=env, capture_output=True, text=True, timeout=300)
        out = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertTrue(out["ok"], json.dumps(out["checks"], indent=1))
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
