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

    def test_countdown_then_go(self):
        # the host's 3-2-1 (docs/design/windows-parity/recording.md §3): one line a second, `go` ends it at once
        self.start("--region", "0,0,200,120", "--countdown", "3")
        first = self.next_line()
        self.assertEqual(first, {"ev": "countdown", "n": 3, "total": 3})
        self.session.joinpath(".cmd").write_text("go\n")
        self.assertEqual(self.until("countdown")["n"], 0)
        self.until("started")
        self.control("stop")
        self.until("stopped")
        self.assertEqual(self.p.wait(timeout=30), 0)
        self.assertEqual([e["ev"] for e in self.lines].count("countdown"), 2)

    def test_countdown_cancelled(self):
        self.start("--region", "0,0,200,120", "--countdown", "5")
        self.assertEqual(self.next_line()["ev"], "countdown")
        self.session.joinpath(".cmd").write_text("discard\n")
        self.assertEqual(self.until("discarded"), {"ev": "discarded"})
        self.assertEqual(self.p.wait(timeout=30), 2)
        self.assertNotIn("started", [e["ev"] for e in self.lines])
        self.assertFalse((self.session / "recording.mp4").exists())

    def test_system_audio_track(self):
        # the host's loopback (system.pcm from system.json's t0) becomes the take's audio track, cut to the video
        self.session.mkdir(parents=True)
        rate, secs = 48000, 30
        tone = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=f=440:r={rate}:d={secs}",
                               "-f", "s16le", "-ac", "1", "-"], capture_output=True, check=True).stdout
        (self.session / "system.pcm").write_bytes(tone)
        (self.session / "system.json").write_text(json.dumps({"t0": time.time() - 1, "rate": rate}))
        self.start("--region", "0,0,200,120", "--fps", "15", "--system-audio")
        self.until("started")
        time.sleep(2)
        self.control("stop")
        stopped = self.until("stopped")
        streams = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,duration", "-of", "json",
                                  str(self.session / "recording.mp4")], capture_output=True, text=True).stdout
        kinds = [s["codec_type"] for s in json.loads(streams)["streams"]]
        self.assertEqual(sorted(kinds), ["audio", "video"])
        audio = next(s for s in json.loads(streams)["streams"] if s["codec_type"] == "audio")
        self.assertAlmostEqual(float(audio["duration"]), stopped["duration"], delta=0.5)
        self.assertFalse((self.session / "system.pcm").exists())        # in the video now
        self.assertTrue(json.loads((self.session / "meta.json").read_text())["system_audio"])

    def test_snap_region(self):
        # the host's snap flow during a take: a still of another area, numbered and logged like our own
        self.start("--region", "0,0,200,120", "--fps", "15")
        self.until("started")
        with open(self.session / ".cmd", "a") as fh:
            fh.write("snap-region:-40,30,161,91\n")
        e = self.until("snap")
        self.assertEqual((e["n"], e["file"]), (1, "shots/001.png"))
        self.control("snap")
        self.assertEqual(self.until("snap")["n"], 2)
        self.control("stop")
        self.until("stopped")
        shots = [json.loads(l) for l in (self.session / "shots.jsonl").read_text().splitlines()]
        self.assertEqual([x["region"] for x in shots], [[-40, 30, 161, 91], [0, 0, 200, 120]])
        snaps = [json.loads(l) for l in (self.session / "events.jsonl").read_text().splitlines()
                 if json.loads(l)["type"] == "snap"]
        self.assertEqual([(x["n"], x["via"]) for x in snaps], [(1, "picker"), (2, "command")])

    def kill_grabber(self, seg: str):
        out = subprocess.run(["pgrep", "-f", str(self.session / seg)], capture_output=True, text=True).stdout.split()
        self.assertTrue(out, f"no grabber writing {seg}")
        for pid in out:
            os.kill(int(pid), 9)

    @unittest.skipIf(sys.platform == "win32", "pgrep")
    def test_grabber_stopping_mid_take_is_started_again(self):
        # recording.md §6.6 (the Mac's Recorder.restartCapture): a new segment, the take goes on, the loss is said
        self.start("--region", "0,0,200,120", "--fps", "15")
        self.until("started")
        time.sleep(1.5)
        self.kill_grabber("seg00.mkv")
        self.assertEqual(self.until("capture_restarting")["attempt"], 1)
        self.until("capture_restarted")
        time.sleep(1.5)
        self.control("stop")
        stopped = self.until("stopped")
        self.assertEqual(stopped["recovered"][0]["kind"], "capture")
        self.assertGreater(stopped["lost_seconds"], 0)
        self.assertNotIn("ended_early", stopped)
        types = [json.loads(l)["type"] for l in (self.session / "events.jsonl").read_text().splitlines()]
        self.assertIn("capture_restarted", types)

    @unittest.skipIf(sys.platform == "win32", "pgrep")
    def test_finish_while_waiting_for_the_screen_keeps_what_was_recorded(self):
        self.env["BLURT_TEST_SCREEN_LOCKED"] = "1"
        self.start("--region", "0,0,200,120", "--fps", "15")
        self.until("started")
        time.sleep(1.5)
        self.kill_grabber("seg00.mkv")
        self.until("capture_waiting_for_screen")
        self.control("stop")
        stopped = self.until("stopped")
        self.assertGreater(stopped["duration"], 0.5)
        self.assertEqual(self.p.wait(timeout=30), 0)

    def test_pen_strokes_go_in_events(self):
        # the host's pen (recording.md §4.6): a stroke's shape and points at the video time it began
        self.start("--region", "0,0,200,120", "--fps", "15")
        self.until("started")
        time.sleep(1.2)
        with open(self.session / ".cmd", "a") as fh:
            fh.write('stroke:{"shape":"ellipse","points":[[0.1,0.2],[0.5,0.6]],"dur":0.4}\n')
        time.sleep(0.5)
        self.control("stop")
        self.until("stopped")
        st = [json.loads(l) for l in (self.session / "events.jsonl").read_text().splitlines() if '"stroke"' in l]
        self.assertEqual(len(st), 1)
        self.assertEqual((st[0]["shape"], st[0]["points"], st[0]["visible"]), ("ellipse", [[0.1, 0.2], [0.5, 0.6]], 3.0))
        self.assertAlmostEqual(st[0]["t"] - st[0]["t0"], 0.4, delta=0.01)

    def test_error_line(self):
        self.start("--region", "1,2,3")           # bad region → die() → one final error line
        e = self.next_line()
        self.assertEqual(e["ev"], "error")
        self.assertIn("x,y,w,h", e["msg"])
        self.assertNotEqual(self.p.wait(timeout=30), 0)


if __name__ == "__main__":
    unittest.main()
