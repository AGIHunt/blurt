"""The app shell's side of _common.py: config.json written under the lock the Mac app's Config.set shares, an
unreadable config never overwritten, files under $BLURT_HOME only this account can read (0600 / 0700), and the
CONTRACT the app checks the skill against (BlurtCore/SkillContract.swift)."""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import _common  # noqa: E402


class ConfigAndPrivacy(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="blurt-cfg-"))
        self.old = os.environ.get("BLURT_HOME")
        os.environ["BLURT_HOME"] = str(self.home)

    def tearDown(self):
        os.environ["BLURT_HOME"] = self.old or ""

    def test_update_keeps_other_keys(self):
        _common.update_global_config({"record": {"countdown": 5}, "lang": "en"})
        _common.update_global_config({"record": {"system_audio": True}})
        cfg = json.loads((self.home / "config.json").read_text())
        self.assertEqual(cfg, {"record": {"countdown": 5, "system_audio": True}, "lang": "en"})

    def test_unreadable_config_is_left_alone(self):
        p = self.home / "config.json"
        p.write_text('{"record": {,, }')
        import contextlib
        import io
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(_common.ConfigUnreadable) as e:
                _common.update_global_config({"lang": "en"})
            self.assertEqual(e.exception.code, "config_unreadable")       # a clean JSON error for the CLIs, no traceback
            # a write that is only a convenience (hardware fingerprint, last region, skill_dir, a model to use): skipped
            self.assertFalse(_common.save_config_if_readable({"lang": "en"}))
        self.assertEqual(p.read_text(), '{"record": {,, }')
        # record.py's bookkeeping (where the skill is) goes the same way: a CLI recording isn't stopped by it
        import record
        with contextlib.redirect_stderr(io.StringIO()):
            record.remember_skill_dir()
        self.assertEqual(p.read_text(), '{"record": {,, }')
        p.write_text('{}')
        self.assertTrue(_common.save_config_if_readable({"lang": "en"}))

    def test_a_trailing_comma_reads_like_the_app_reads_it(self):
        # a hand edit's most common slip: the app (Swift) reads it, so the scripts must too — dictation, voice notes
        # and processing went down on it before
        p = self.home / "config.json"
        p.write_text('{"record": {"engine": "sck", "dictation": {"asr_model": "x",},},\n"lang": "en",\n}\n')
        self.assertEqual(_common.global_config(), {"record": {"engine": "sck", "dictation": {"asr_model": "x"}}, "lang": "en"})
        self.assertEqual(_common.read_global_config()[1], True)
        # a comma inside a string is the user's, untouched; one before ] goes too
        self.assertEqual(_common.parse_config_text('{"a": "x,}", "b": [1, 2, ], "c": "\\",]"}'),
                         {"a": "x,}", "b": [1, 2], "c": '",]'})
        self.assertIsNone(_common.parse_config_text('{"a": 1 "b": 2}'))
        self.assertIsNone(_common.parse_config_text('[1, 2]'))
        # the same list as ShellDataTests.testATrailingCommaReadsAsTheScriptsReadIt: what one side reads, the other does
        for t in ['{"a": 1,}', '{"a": [1,],}', '{"a": 1,, }', '{"a": {"b": 2,},\n}']:
            self.assertIsNotNone(_common.parse_config_text(t), t)
        # NaN / Infinity: Python's json takes them, the app's JSONSerialization doesn't — so neither does
        for t in ['{"a": 1 "b": 2}', '{"a": ', '{"a": 1,,"b": 2}', '[1]', '', '{"a": NaN}', '{"a": Infinity}',
                  '{"a": -Infinity}']:
            self.assertIsNone(_common.parse_config_text(t), t)
        # a write normalises it (and keeps everything)
        _common.update_global_config({"lang": "zh"})
        self.assertEqual(json.loads(p.read_text())["record"]["engine"], "sck")

    def test_a_cli_never_tracebacks_on_an_unreadable_config(self):
        # the app runs `transcribe.py auto --apply` at every launch: a hand-edit slip must not turn it into a traceback
        import subprocess
        (self.home / "config.json").write_text('{"asr": {"auto": true}, "record": {')
        p = subprocess.run([sys.executable, str(ROOT / "skills/blurt/scripts/transcribe.py"), "auto", "--apply"],
                           capture_output=True, text=True, timeout=120, env={**os.environ, "BLURT_HOME": str(self.home)})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        out = json.loads(p.stdout.strip().splitlines()[-1])
        self.assertEqual((out["ok"], out.get("applied"), out.get("saved")), (True, False, False))
        self.assertIn('"config_unreadable"', p.stderr)
        self.assertEqual((self.home / "config.json").read_text(), '{"asr": {"auto": true}, "record": {')

    def test_progress_is_one_line_and_one_count_for_every_download(self):
        import polish
        import transcribe
        self.assertIs(transcribe.progress_line, _common.progress_line)
        self.assertIs(polish.progress_line, _common.progress_line)
        self.assertEqual(_common.progress_line(812 * 2**20, 2468 * 2**20), "  812.0/2468.0 MB")
        # a blob set to its full length up front has landed nothing yet
        d = self.home / "blob-dir"
        d.mkdir()
        with open(d / "x.incomplete", "wb") as f:
            f.truncate(64 * 2**20)
        (d / "y").write_bytes(b"z" * 8192)
        self.assertLess(_common.landed_in(d), 2**20)
        self.assertGreaterEqual(_common.landed_in(d), 8192)

    def test_unreadable_config_reads_as_defaults_and_says_so_once(self):
        import contextlib
        import io
        p = self.home / "config.json"
        p.write_text('{"record": {"engine": ')
        _common._CONFIG_WARNED.discard(str(p))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(_common.global_config(), {})       # never raises: every setting at its default
            self.assertEqual(_common.read_global_config(), ({}, False))
        lines = [json.loads(x) for x in err.getvalue().splitlines() if x.strip()]
        self.assertEqual([x["event"] for x in lines], ["config_unreadable"])      # once per process
        bak = Path(lines[0]["backup"])
        self.assertTrue(bak.name.startswith("config.json.bad-"))
        self.assertEqual(bak.read_text(), p.read_text())
        # the same bytes are not copied again (the app makes the same copy: BlurtCore Config.refuse)
        _common._CONFIG_WARNED.discard(str(p))
        with contextlib.redirect_stderr(io.StringIO()):
            _common.global_config()
        self.assertEqual(len(list(self.home.glob("config.json.bad-*"))), 1)
        self.assertEqual(p.read_text(), '{"record": {"engine": ')      # the file itself is the user's to fix

    def test_swift_reads_config_by_the_same_rule(self):
        swift = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/Config.swift").read_text()
        self.assertIn("ConfigText.parse", swift)
        self.assertIn("dropTrailingCommas", swift)

    def test_update_waits_for_the_apps_lock(self):
        lock = self.home / ".config.lock"
        done = []
        with _common.file_lock(lock):           # stands in for the app's Config.set holding it
            t = threading.Thread(target=lambda: done.append(_common.update_global_config({"lang": "en"})))
            t.start()
            time.sleep(0.2)
            self.assertEqual(done, [])
            self.assertFalse((self.home / "config.json").exists())
        t.join(5)
        self.assertEqual(done[0]["lang"], "en")

    @unittest.skipIf(_common.IS_WIN, "POSIX modes")
    def test_files_under_home_are_private(self):
        _common.save_json(self.home / "run" / "asr-serve.json", {"token": "t"})
        self.assertEqual((self.home / "run" / "asr-serve.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.home / "run").stat().st_mode & 0o777, 0o700)
        _common.update_global_config({"lang": "en"})
        self.assertEqual((self.home / "config.json").stat().st_mode & 0o777, 0o600)
        d = _common.private_dir(self.home / "dictation")
        self.assertEqual(d.stat().st_mode & 0o777, 0o700)

    @unittest.skipIf(_common.IS_WIN, "POSIX modes")
    def test_files_elsewhere_keep_the_defaults(self):
        other = Path(tempfile.mkdtemp(prefix="blurt-repo-")) / ".blurt" / "config.json"
        _common.save_json(other, {"export": {}})
        self.assertNotEqual(other.stat().st_mode & 0o777, 0o600, "a project's files stay readable like the repo")


class Contract(unittest.TestCase):
    def test_contract_is_the_apps(self):
        self.assertIsInstance(_common.CONTRACT, int)
        swift = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/SkillContract.swift").read_text()
        self.assertIn(f"public static let expected = {_common.CONTRACT}\n", swift,
                      "bump SkillContract.expected together with _common.CONTRACT")
        # the app reads the constant from the start of a line in _common.py, without running Python
        src = (ROOT / "skills/blurt/scripts/_common.py").read_text()
        self.assertIn(f"\nCONTRACT = {_common.CONTRACT}\n", src)


class ShellRules(unittest.TestCase):
    """Rules of the Mac app shell that are easy to undo by accident (read from the sources)."""
    APP = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp"

    def test_record_and_snap_from_a_link_ask_first(self):
        src = (self.APP / "App/AppDelegate.swift").read_text()
        body = src[src.index("func application(_ application: NSApplication, open urls: [URL])"):]
        body = body[:body.index("\n    }\n")]
        self.assertIn('confirmFromURL("record")', body)
        self.assertIn('confirmFromURL("snap")', body)
        self.assertNotIn("startRecording(useLast: false) }\n", body.replace("$0.startRecording", ""))

    def test_one_toast_system_and_one_launch_message(self):
        src = (self.APP / "App/AppDelegate.swift").read_text()
        toast = src[src.index("    func toast(_ text: String"):]
        self.assertIn("island.toast(t)", toast[:toast.index("hudToast(text")])
        house = (self.APP / "App/Housekeeping.swift").read_text()
        self.assertNotIn("island?.toast(", house, "launch messages go through LaunchMessages")
        self.assertNotIn("island.ask(", house, "launch messages go through LaunchMessages")

    def test_open_at_login_has_one_switch_with_the_test_guard(self):
        # Settings → General went straight to SMAppService: a scratch build toggling it landed in the user's Login Items
        general = (self.APP / "Settings/GeneralPane.swift").read_text()
        self.assertNotIn("SMAppService.mainApp.register", general)
        self.assertIn('LoginItem.set(on, via: "settings")', general)
        onboarding = (self.APP / "Onboarding/Onboarding.swift").read_text()
        self.assertIn("if SystemAccess.testMode { testState = on; return nil }", onboarding)

    def test_one_spinner_everywhere(self):
        # system.md §3.3: the brand arc (BrandSpinnerView), never the grey system spokes — the Lab's record button
        # (white on ink, developer-only) is the one exception
        bare = []
        for f in self.APP.rglob("*.swift"):
            for i, line in enumerate(f.read_text().splitlines(), 1):
                if "ProgressView()" in line and "BrandViews.swift" not in str(f) and ".tint(" not in line:
                    bare.append(f"{f.relative_to(self.APP)}:{i}")
        self.assertEqual(bare, [])

    def test_the_menu_advertises_only_working_keys(self):
        src = (self.APP / "App/Hotkeys.swift").read_text()
        body = src[src.index("func showHotkey"):]
        self.assertLess(body.index("worksInMenu"), body.index("keyEquivalent = k"))

    def test_the_task_kind_is_daiban_wherever_a_kind_is_meant(self):
        zh = (self.APP / "Resources/zh-Hans.lproj/Main.strings").read_text()
        self.assertIn('"main.keys.kind" = "种类：问题、想法、笔记、待办";', zh)
        self.assertIn('"main.misc.task" = "待办";', zh)

    def test_agent_states_have_one_wording(self):
        # 未安装 / 未登录 on every surface (the app's strings and agents.py's), never 没安装 / 没登录 beside them
        res = self.APP / "Resources/zh-Hans.lproj"
        texts = [p.read_text() for p in res.glob("*.strings")] + [(ROOT / "skills/blurt/scripts/agents.py").read_text()]
        import re
        for t in texts:      # a state's label (a whole string), not prose such as "没登录或额度用完时…"
            self.assertEqual(re.findall(r'"\s*没(?:安装|登录)"', t), [])

    def test_each_setting_in_one_pane(self):
        general = (self.APP / "Settings/GeneralPane.swift").read_text()
        privacy = (self.APP / "Settings/PrivacyStoragePanes.swift").read_text()
        self.assertNotIn("spotlight", general.lower().replace("spotlight is in privacy", ""))
        self.assertIn("setSpotlight", privacy)


class VideoRemoved(unittest.TestCase):
    """Settings → Storage deletes an organized recording's video and stamps meta.json (VideoRetention.stamp); with
    snaps taken while recording (shots.jsonl) the session must still read as a recording, not a snap batch."""

    def session(self, meta: dict) -> Path:
        d = Path(tempfile.mkdtemp(prefix="blurt-vid-")) / "2026-01-01_10-00-00"
        d.mkdir()
        (d / "shots.jsonl").write_text('{"n": 1}\n')
        (d / "meta.json").write_text(json.dumps(meta))
        return d

    def test_index_and_items_keep_it_a_recording(self):
        import index
        import items
        meta = {"video": "recording.mp4", "duration": 42.0, "mode": "video", "video_removed": "2026-02-01T00:00:00Z"}
        d = self.session(meta)
        self.assertEqual(index._mode(d, meta), "video")
        self.assertEqual(items._source_type(d, meta), "recording")
        # without the stamp, the same folder is taken for snaps — what the stamp is for
        self.assertEqual(index._mode(d, {}), "shots")


if __name__ == "__main__":
    unittest.main()
