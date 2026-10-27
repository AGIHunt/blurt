"""Smoke tests for the stdlib-only scripts (no network, no ffmpeg, no models).

  python -m unittest discover -s tests
"""
from __future__ import annotations

import csv
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(Path(__file__).parent))
from test_store import Env  # noqa: E402

ITEMS = {
    "title": "Settings walkthrough",
    "language": "en",
    "digest": "Two fixes and one idea.",
    "items": [
        {"id": "I-1", "kind": "issue", "title": "Save sits 6px low", "actual": "misaligned", "expected": "aligned",
         "steps": ["Open Settings"], "frames": [{"path": "frames/I-1-1.jpg", "caption": "save"}], "tags": ["ui", "css"]},
        {"id": "I-2", "kind": "issue", "title": "Dropped one", "status": "deleted"},
        {"id": "D-1", "kind": "idea", "title": "Tip card, \"not\" empty state", "why": "feels dead"},
        {"id": "T-1", "kind": "task", "title": "Ask design for copy"},
        {"id": "N-1", "kind": "note", "title": "逗号, 引号与换行\n第二行"},
    ],
}


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(os.path.realpath(tmp.name))
        self.env = Env(root)
        # a session in the inbox store, as the Blurt app makes them in auto mode
        self.session = self.env.ws / "inbox" / "sessions" / "20261022-101500"
        (self.session / "frames").mkdir(parents=True)
        (self.session / "frames" / "I-1-1.jpg").write_bytes(b"0123456789")
        (self.session / "items.json").write_text(json.dumps(ITEMS, ensure_ascii=False), encoding="utf-8")

    def run_script(self, *args, **kw):
        return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, encoding="utf-8",
                              timeout=30, env=self.env.env(), **kw)


class ExportLocal(Base):
    def test_mixed_kinds(self):
        p = self.run_script(SCRIPTS / "export_local.py", self.session)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual(out["kinds"], {"issue": 1, "idea": 1, "task": 1, "note": 1})  # deleted item dropped
        md = (self.session / "items.md").read_text(encoding="utf-8")
        self.assertIn("## Issues (1)", md)
        self.assertNotIn("Dropped one", md)
        link = md.split("![save](", 1)[1].split(")", 1)[0]  # the frame, relative to the export
        self.assertEqual((self.session / link).resolve().read_bytes(), b"0123456789")
        self.assertTrue(link.startswith("../../assets/"))
        self.assertIn("### IN-1 Save sits 6px low", md)
        raw = (self.session / "notes.csv").read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))  # BOM so Excel reads CJK
        with open(self.session / "notes.csv", encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))
        self.assertEqual(rows[1][1], ITEMS["items"][4]["title"])  # comma / newline survive the round trip
        with open(self.session / "issues.csv", encoding="utf-8-sig", newline="") as fh:
            row = list(csv.DictReader(fh))[0]
        self.assertEqual(row["Tags"], "ui, css")
        self.assertNotIn("uid", row)  # bookkeeping stays out of the sheet
        # a whole project (here: the inbox) into its store's exports/
        p = self.run_script(SCRIPTS / "export_local.py", "--project", "inbox")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue((self.env.ws / "inbox" / "exports" / "items.md").is_file())

    def test_missing_items(self):
        (self.session / "items.json").unlink()
        p = self.run_script(SCRIPTS / "export_local.py", self.session)
        self.assertEqual(p.returncode, 1)
        self.assertIn("items.json", p.stderr)
        self.assertNotIn("Traceback", p.stderr)


class ReviewServer(Base):
    def test_api_files_and_confirm(self):
        proc = subprocess.Popen([sys.executable, str(SCRIPTS / "review.py"), str(self.session), "--no-open"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                env=self.env.env())
        self.addCleanup(proc.kill)
        url = proc.stdout.readline().split()[-1]
        get = lambda path, **h: urllib.request.urlopen(urllib.request.Request(url + path, headers=h), timeout=5)  # noqa: E731

        doc = json.load(get("api/items"))
        self.assertEqual(len(doc["items"]), 5)
        self.assertEqual(doc["scope"], {"session": str(self.session)})
        frame = doc["items"][0]["frames"][0]["path"]
        self.assertTrue(os.path.isabs(frame))
        self.assertEqual(get("files/" + urllib.parse.quote(frame, safe=""), Range="bytes=2-4").read(), b"234")  # seeking
        self.assertEqual(get("files/" + urllib.parse.quote(frame)).read(), b"0123456789")  # files//abs/path works too
        self.assertEqual(get("files/frames/I-1-1.jpg").read(), b"0123456789")  # the old relative form
        for bad in ("files/../../etc/passwd", "files/%2Fetc%2Fpasswd", "files" + urllib.parse.quote(str(SCRIPTS / "items.py"))):
            with self.assertRaises(urllib.error.HTTPError, msg=bad):  # only known stores, sessions, handoff
                get(bad)
        ops = [{"op": "set", "id": doc["items"][0]["uid"], "set": {"status": "deleted"}}]
        req = urllib.request.Request(url + "api/confirm", data=json.dumps({"ops": ops}).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})  # as the page sends it
        merged = json.load(urllib.request.urlopen(req, timeout=5))
        self.assertTrue(merged["reviewed"])
        summary = json.loads(proc.communicate(timeout=10)[0].strip().splitlines()[-1])
        self.assertEqual((summary["reviewed"], summary["kept"], summary["deleted"]), (True, 3, 2))
        self.assertEqual(summary["file"], str(self.session / "batch.json"))
        self.assertEqual(len(summary["items"]), 3)


class PenMarks(unittest.TestCase):
    def test_strokes_group_into_marks(self):
        try:
            import numpy, PIL  # noqa: F401  (frames.py imports them at module level)
        except ImportError:
            self.skipTest("numpy / pillow not installed")
        sys.path.insert(0, str(SCRIPTS))
        import frames
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        video = Path(tmp.name) / "recording.mp4"
        loop = [[0.5 + 0.1 * math.cos(i / 4), 0.5 + 0.1 * math.sin(i / 4)] for i in range(27)]
        events = [{"t": 1.0, "type": "click", "x": 0.1, "y": 0.1},
                  {"t": 5.0, "t0": 4.0, "type": "stroke", "visible": 3, "points": loop},
                  {"t": 7.5, "t0": 7.0, "type": "stroke", "visible": 3, "points": [[0.2, 0.8], [0.3, 0.8], [0.4, 0.8]]},
                  {"t": 30.0, "t0": 30.0, "type": "stroke", "visible": 3, "points": [[0.9, 0.9]]}]
        (video.parent / "events.jsonl").write_text("\n".join(map(json.dumps, events)), encoding="utf-8")
        (video.parent / "transcript.json").write_text(json.dumps({"segments": [
            {"start": 3.0, "end": 8.0, "text": "this headline"}, {"start": 20.0, "end": 22.0, "text": "unrelated"}]}))
        frames.probe_size = lambda _: (1600, 1000)
        m = frames.marks(video)["marks"]
        self.assertEqual([[s["shape"] for s in g["strokes"]] for g in m], [["loop", "line"], ["tap"]])
        self.assertEqual(m[0]["frame_t"], 7.8)          # both strokes of the first mark are on screen then
        self.assertEqual(m[0]["said"], "this headline")
        x, y, w, h = m[0]["box"]
        self.assertTrue(x <= 0.2 and y <= 0.4 and x + w >= 0.6 and y + h >= 0.8)


    def test_the_pens_own_shapes_win(self):
        """v0.9-next: the recording pen draws boxes (⌃⇧), ellipses (⌃⌥) and snaps rough shapes clean; events.jsonl says
        which (`shape`), and a long thin box — which the length heuristic would call free — is still a loop."""
        try:
            import numpy, PIL  # noqa: F401
        except ImportError:
            self.skipTest("numpy / pillow not installed")
        sys.path.insert(0, str(SCRIPTS))
        import frames
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        video = Path(tmp.name) / "recording.mp4"
        c = [[0.1, 0.40], [0.9, 0.40], [0.9, 0.44], [0.1, 0.44], [0.1, 0.40]]
        box = [p for q in c for p in (q, q)]                 # corners doubled, as the app stores a box
        ell = [[0.5 + 0.2 * math.cos(i / 72 * 2 * math.pi), 0.5 + 0.1 * math.sin(i / 72 * 2 * math.pi)] for i in range(73)]
        events = [{"t": 1.0, "t0": 0.5, "type": "stroke", "visible": 3, "shape": "box", "points": box},
                  {"t": 9.0, "t0": 8.5, "type": "stroke", "visible": 3, "shape": "ellipse", "points": ell},
                  {"t": 20.0, "t0": 19.5, "type": "stroke", "visible": 3, "shape": "line", "points": [[0.1, 0.9], [0.6, 0.9]]},
                  {"t": 30.0, "t0": 29.5, "type": "stroke", "visible": 3, "points": [[0.1, 0.4], [0.9, 0.4], [0.9, 0.44], [0.1, 0.44]]}]
        (video.parent / "events.jsonl").write_text("\n".join(map(json.dumps, events)), encoding="utf-8")
        frames.probe_size = lambda _: (1600, 1000)
        got = [s["shape"] for s in frames.strokes(video)]
        self.assertEqual(got, ["loop", "loop", "line", "free"])
        self.assertEqual(frames.strokes(video)[0]["box"], [0.1, 0.4, 0.8, 0.04])


if __name__ == "__main__":
    unittest.main()
