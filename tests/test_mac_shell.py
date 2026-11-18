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
        # a source build says its version once in About ("Version 1.0.4", not "1.0.4 (0.5.0)"); the release script
        # stamps the real build number (the commit count) into the bundle it ships
        self.assertEqual(p["CFBundleVersion"], p["CFBundleShortVersionString"])

    def test_hanging_cards_are_accessible(self):
        # The hanging cards (K7) are drawn in CALayers: without these overrides VoiceOver / the AX tree would see an
        # empty window (live check: the `axcards` test command).
        src = (MAC / "Sources/BlurtApp/Capture/Island/HangingCards.swift").read_text()
        for needle in ["override func accessibilityChildren()", "final class LayerAXElement: NSAccessibilityElement",
                       "s.plainName", "setAccessibilityCustomActions", "override func accessibilityPerformPress()"]:
            self.assertIn(needle, src)

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

    def test_no_agent_sessions(self):
        # the in-app agent sessions (terminal, dispatch, finish / merge, Claude desktop) were removed
        self.assertFalse((MAC / "Sources/BlurtApp/Terminal/DispatchPanel.swift").exists())
        self.assertFalse((MAC / "Sources/BlurtApp/Terminal/FinishPanel.swift").exists())
        self.assertFalse((MAC / "Sources/BlurtCore/Sessions/AgentSessions.swift").exists())
        self.assertFalse((SCRIPTS / "sessions.py").exists())

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
        self.assertLess(size, 30 * 1024 * 1024, f"Blurt.app is {size / 1e6:.1f} MB")
        fx = home / "fx"
        shutil.copytree(ROOT / "tests" / "fixtures" / "sessions", fx)
        env["CODEX_HOME"] = str(home / "codex")
        env["CLAUDECODE"] = "1"
        r = subprocess.run([str(app / "Contents" / "MacOS" / "blurt-recorder"), "--selftest", str(fx / "20261021-101500")],
                           env=env, capture_output=True, text=True, timeout=300)
        out = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertTrue(out["ok"], json.dumps(out["checks"], indent=1))
        self.assertEqual(r.returncode, 0)


class AppWiring(unittest.TestCase):
    """App-side rules the BlurtCore tests can't reach."""

    def src(self, rel):
        return (MAC / "Sources/BlurtApp" / rel).read_text()

    def test_organisers_stop_with_the_app_and_one_per_recording(self):
        app = self.src("App/AppDelegate.swift")
        self.assertIn("func applicationShouldTerminate(", app)
        self.assertIn("stopOrganisers()", app)
        hub = self.src("App/AgentHub.swift")
        self.assertIn("try shellGroup(", hub)
        self.assertIn('job.set("agent_pgid"', hub)
        self.assertIn("process_already_running", hub)
        hk = self.src("App/Housekeeping.swift")
        self.assertIn("ProcessGroup.stop(g)", hk)
        # review: a recorded group is stopped only while it is still that run's (its leader's start time)
        self.assertIn('ProcessGroup.isOurs(g, started: (raw?["agent_pgid_start"]', hk)
        self.assertEqual(hub.count('job.set("agent_pgid_start"'), 2)
        # no modal on logout / restart / shutdown, and the Mac's words for the button
        self.assertIn("!Self.quitBySystem", app)
        self.assertIn("kAEQuitReason", app)

    def test_review_of_fix_2_raw_text_and_list_marks(self):
        # raw-id #14: the install sheet says each change in words only; the script's error goes to the log, the argv
        # and paths only to Details (mono there and nowhere else), and the one default is accent-filled
        pane = self.src("Settings/AgentsPane.swift")
        sheet = pane[pane.index("struct InstallSheet"):pane.index("extension InstallChange {")]
        body = sheet[sheet.index("var body: some View"):]
        self.assertNotIn("c.error", body)
        self.assertNotIn("c.output", body)
        self.assertNotIn("c.argv", sheet)
        self.assertEqual(sheet.count("design: .monospaced"), 1)
        self.assertIn("InstallDetailsWell(lines: technical)", body)
        self.assertRegex(body, r'Button\([TA]L\("install\.confirm"\)\) \{ Task \{ await m\.apply\(\) \} \}\n\s+'
                               r'\.buttonStyle\(\.borderedProminent\)\.tint\(Color\.settingsDefault\)\.keyboardShortcut\(\.defaultAction\)')
        zh = "\n".join(f.read_text() for f in (MAC / "Sources/BlurtApp/Resources/zh-Hans.lproj").glob("*.strings"))
        for line in zh.splitlines():
            if line.startswith('"install.'):
                self.assertNotIn("skill", line.split("=", 1)[1].lower(), line)   # 技能, not untranslated jargon
        # an unreadable item is marked in the list, not only once it is selected
        ilc = self.src("MainWindow/ItemListController.swift")
        self.assertIn("unreadable: it.unreadable)", ilc)
        self.assertIn('c.toolTip = it.unreadable ? T("main.unreadable.fix_first")', ilc)
        # the fallback notes only remember running jobs
        hub = self.src("App/AgentHub.swift")
        self.assertIn("JobStore.shared.job($0.key)?.isActive == true", hub)

    def test_primaries_use_the_brand_style(self):
        ilc = self.src("MainWindow/ItemListController.swift")
        # the brand arc (BrandSpinner, or TrackedSpinner: the same arc on its faint track), sized for the empty state
        self.assertRegex(ilc, r"let spinner = (BrandSpinner|TrackedSpinner)\(")
        self.assertNotIn("NSProgressIndicator()", ilc)



if __name__ == "__main__":
    unittest.main()
