"""record.py's ffmpeg engine with --status-jsonl (docs/design/desktop-app.md §5 C8): the status line sequence, pause /
resume segments, in-recording snaps → shots/NNN.png + shots.jsonl, discard, and the error line.

The screen is ffmpeg's lavfi test source (BLURT_FAKE_SCREEN=1) unless BLURT_CAPTURE_REAL=1 (CI under xvfb: x11grab).
No microphone is opened (--no-mic).

  uv run -q --with numpy --with pillow python -m unittest tests.test_capture_ffmpeg -v
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import queue
import tempfile
import threading
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
HAVE = shutil.which("ffmpeg") and shutil.which("ffprobe")
REAL = os.environ.get("BLURT_CAPTURE_REAL") == "1"


@unittest.skipUnless(HAVE, "needs ffmpeg + ffprobe")
class FfmpegStatusJsonl(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        home = self.tmp / "home"
        home.mkdir()
        (home / "config.json").write_text(json.dumps({"record": {"install_app": False, "live": False}}))
        self.env = dict(os.environ, BLURT_HOME=str(home), PYTHONIOENCODING="utf-8")
        if not REAL:
            self.env["BLURT_FAKE_SCREEN"] = "1"
        self.session = self.tmp / "session"

    def start(self, *extra):
        cmd = [sys.executable, str(SCRIPTS / "record.py"), "start", "--engine", "ffmpeg", "--session", str(self.session),
               "--no-mic", "--status-jsonl", *extra]
        self.p = subprocess.Popen(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  encoding="utf-8")
        self.addCleanup(lambda: self.p.poll() is None and self.p.kill())
        self.lines: list[dict] = []
        self.q: queue.Queue = queue.Queue()
        self.err: list[str] = []
        threading.Thread(target=lambda: [self.q.put(l) for l in self.p.stdout] + [self.q.put("")], daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(l) for l in self.p.stderr], daemon=True).start()
        return self.p

    def next_line(self, timeout=40) -> dict:
        try:
            line = self.q.get(timeout=timeout)    # status lines are flushed one by one
        except queue.Empty:
            self.fail(f"no status line in {timeout} s after {self.lines}; stderr: {''.join(self.err)[-1500:]}")
        self.assertTrue(line, f"stdout closed after {self.lines}; stderr: {''.join(self.err)[-1500:]}")
        e = json.loads(line)                      # stdout is JSON lines only
        self.lines.append(e)
        return e

    def until(self, ev: str) -> dict:
        while True:
            e = self.next_line()
            if e["ev"] == ev:
                return e
            self.assertNotIn(e["ev"], ("error", "stopped", "discarded"), self.lines)

    def control(self, c: str):
        subprocess.run([sys.executable, str(SCRIPTS / "record.py"), c], env=self.env, check=True, capture_output=True,
                       timeout=90)

    def test_record_pause_snap_resume_stop(self):
        self.start("--region", "0,0,321,241", "--fps", "15")
        started = self.until("started")
        self.assertAlmostEqual(started["t0"], time.time(), delta=30)
        time.sleep(1.5)
        self.control("snap")
        snap = self.until("snap")
        self.assertEqual((snap["n"], snap["file"]), (1, "shots/001.png"))
        self.control("pause")
        self.until("paused")
        self.control("snap")                      # snaps work while paused
        self.assertEqual(self.until("snap")["n"], 2)
        self.control("resume")
        self.until("resumed")
        time.sleep(1.5)
        self.control("stop")
        stopped = self.until("stopped")
        self.assertEqual(stopped["video"], "recording.mp4")
        self.assertEqual(self.p.wait(timeout=30), 0)
        self.assertEqual(self.q.get(timeout=5), "")          # nothing after the final line
        self.assertEqual([e["ev"] for e in self.lines], ["started", "snap", "paused", "snap", "resumed", "stopped"])

        s = self.session
        for f in ("recording.mp4", "events.jsonl", "meta.json", "shots.jsonl", "shots/001.png", "shots/002.png"):
            self.assertTrue((s / f).exists(), f)
        self.assertEqual([p.name for p in s.glob("seg*")], [])          # segments joined and removed
        w, h = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height",
                               "-of", "csv=p=0", str(s / "recording.mp4")], capture_output=True, text=True
                              ).stdout.strip().split(",")
        self.assertEqual((int(w), int(h)), (320, 240))                   # region rounded to even sizes
        self.assertGreater(stopped["duration"], 2.0)
        shots = [json.loads(l) for l in (s / "shots.jsonl").read_text().splitlines()]
        self.assertEqual([x["n"] for x in shots], [1, 2])
        for x in shots:   # the shots.jsonl contract (docs/design/snap-and-live.md)
            self.assertEqual(set(x), {"n", "file", "marked", "t", "wall", "region", "voice", "text", "strokes"})
            self.assertEqual(x["region"], [0, 0, 320, 240])
        self.assertLessEqual(shots[0]["t"], shots[1]["t"])
        types = [json.loads(l)["type"] for l in (s / "events.jsonl").read_text().splitlines()]
        self.assertEqual(types, ["snap", "pause", "snap", "resume", "stop"])
        meta = json.loads((s / "meta.json").read_text())
        self.assertEqual((meta["engine"], meta["video"], meta["segments"]), ("ffmpeg", "recording.mp4", 2))

    def test_discard(self):
        self.start("--region", "0,0,200,120")
        self.until("started")
        self.control("discard")
        self.assertEqual(self.until("discarded"), {"ev": "discarded"})
        self.assertEqual(self.p.wait(timeout=30), 2)
        self.assertFalse((self.session / "recording.mp4").exists())

    def test_error_line(self):
        self.start("--region", "1,2,3")           # bad region → die() → one final error line
        e = self.next_line()
        self.assertEqual(e["ev"], "error")
        self.assertIn("x,y,w,h", e["msg"])
        self.assertNotEqual(self.p.wait(timeout=30), 0)


if __name__ == "__main__":
    unittest.main()
