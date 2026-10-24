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
        with self.assertRaises(json.JSONDecodeError):
            _common.update_global_config({"lang": "en"})
        self.assertEqual(p.read_text(), '{"record": {,, }')

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


if __name__ == "__main__":
    unittest.main()
