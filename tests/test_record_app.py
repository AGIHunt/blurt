"""record.py app: a take in the Blurt app, waited on until the app has organized it. Temp BLURT_HOME / BLURT_WORKSPACE
only; the app is played by writing what it writes (the take's folder, meta.json, a process job).

  uv run --with numpy python -m unittest tests.test_record_app -v
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import jobs  # noqa: E402
import record  # noqa: E402


def take(sessions: Path, t: float | None = None) -> Path:
    d = sessions / time.strftime("%Y%m%d-%H%M%S", time.localtime(time.time() if t is None else t))
    d.mkdir()
    return d


def meta(d: Path, **kw) -> None:
    (d / "meta.json").write_text(json.dumps({"engine": "native-app", "duration": 12.5, **kw}), encoding="utf-8")


class AppTake(unittest.TestCase):
    def setUp(self):
        tmp = Path(tempfile.mkdtemp())
        home, ws = tmp / "home", tmp / "ws"
        home.mkdir()
        env = mock.patch.dict(os.environ, {"BLURT_HOME": str(home), "BLURT_WORKSPACE": str(ws)})
        env.start()
        self.addCleanup(env.stop)
        self.sessions = ws / "inbox" / "sessions"
        self.sessions.mkdir(parents=True)

    def run_app(self, *args) -> subprocess.Popen:
        return subprocess.Popen([sys.executable, str(SCRIPTS / "record.py"), "app", "--interval", "0.1", *args],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                env=os.environ.copy())

    def test_takes_since_and_order(self):
        old = take(self.sessions, time.time() - 600)
        new = take(self.sessions)
        (self.sessions / "20261108-101010-shots").mkdir()          # a snap batch, not a take
        self.assertEqual(record.app_takes(time.time() - 60), [new])
        self.assertEqual(record.app_takes(time.time() - 3600), [old, new])

    def test_states(self):
        d = take(self.sessions)
        now = time.time()
        self.assertEqual(record.take_state(d, None, now)["state"], "recording")
        meta(d)
        self.assertEqual(record.take_state(d, now, now)["state"], "ended")      # not organizing yet
        late = record.take_state(d, now - record.ORGANIZE_GRACE - 1, now)
        self.assertEqual((late["state"], late["why"]), ("saved", "not_organized"))   # record.process "off"
        j = jobs.create("process", session=str(d), owner="app")
        jobs.step(j["id"], "write", "running")
        st = record.take_state(d, now, now)
        self.assertEqual((st["state"], st["step"], st["job"]), ("organizing", "write", j["id"]))
        jobs.append(j["id"], {"event": "items", "items": ["u1", "u2"]})
        jobs.finish_event(j["id"], "done")
        self.assertEqual(record.take_state(d, now, now),
                         {"session": str(d), "duration": 12.5, "job": j["id"], "state": "organized", "items": 2})

    def test_video_only_failed_cancelled_and_organize_failed(self):
        now = time.time()
        v = take(self.sessions, now - 5)
        meta(v, video_only=True)
        self.assertEqual(record.take_state(v, now, now)["state"], "saved")
        f = take(self.sessions, now - 4)
        meta(f, state="failed", error="disk full", partial=True)
        st = record.take_state(f, now, now)
        self.assertEqual((st["state"], st["partial"], st["error"]), ("failed", True, "disk full"))
        self.assertEqual(record.take_state(self.sessions / "20200101-000000", None, now)["state"], "cancelled")
        g = take(self.sessions, now - 3)
        meta(g)
        j = jobs.create("process", session=str(g), owner="app")
        jobs.finish_event(j["id"], "failed", {"code": "auth", "message": "Not logged in"})
        st = record.take_state(g, now, now)
        self.assertEqual((st["state"], st["error"]["code"]), ("organize_failed", "auth"))

    def test_cli_waits_until_organized(self):
        p = self.run_app("--no-open")
        time.sleep(0.6)
        d = take(self.sessions)
        time.sleep(0.5)
        meta(d)
        time.sleep(0.5)
        j = jobs.create("process", session=str(d), owner="app")
        time.sleep(0.5)
        jobs.append(j["id"], {"event": "items", "items": ["u1"]})
        jobs.finish_event(j["id"], "done")
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 0, err)
        lines = [json.loads(x) for x in out.splitlines()]
        states = [x["state"] for x in lines]
        self.assertEqual((states[0], states[-1]), ("recording", "organized"), states)
        self.assertIn("organizing", states)
        self.assertEqual((lines[-1]["items"], lines[-1]["session"]), (1, str(d)))

    def test_cli_timeout_then_cancelled(self):
        d = take(self.sessions)
        p = self.run_app("--session", str(d), "--timeout", "1")
        out, _ = p.communicate(timeout=30)
        last = json.loads(out.splitlines()[-1])
        self.assertEqual((p.returncode, last["state"]), (3, "waiting"))
        self.assertTrue(last["again"].endswith(str(d)))
        p = self.run_app("--session", str(d))
        time.sleep(0.5)
        d.rmdir()
        out, _ = p.communicate(timeout=30)
        self.assertEqual((p.returncode, json.loads(out.splitlines()[-1])["state"]), (2, "cancelled"))

    def test_cli_saved_when_nothing_organizes_it(self):
        d = take(self.sessions)
        meta(d)
        with mock.patch.object(record, "ORGANIZE_GRACE", 0.3), \
                mock.patch.object(sys, "argv", ["record.py", "app", "--session", str(d), "--interval", "0.1"]), \
                mock.patch("builtins.print") as out:
            with self.assertRaises(SystemExit) as e:
                record.main()
        self.assertEqual(e.exception.code, 0)
        self.assertEqual(json.loads(out.call_args_list[-1].args[0])["state"], "saved")


if __name__ == "__main__":
    unittest.main()
