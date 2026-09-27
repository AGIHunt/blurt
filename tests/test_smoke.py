"""Smoke tests for the stdlib-only scripts (no network, no ffmpeg, no models).

  python -m unittest discover -s tests
"""
from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"

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


def run(*args, **kw):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, encoding="utf-8",
                          timeout=30, **kw)


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.session = Path(tmp.name) / "session"
        (self.session / "frames").mkdir(parents=True)
        (self.session / "frames" / "I-1-1.jpg").write_bytes(b"0123456789")
        (self.session / "items.json").write_text(json.dumps(ITEMS, ensure_ascii=False), encoding="utf-8")


class ExportLocal(Base):
    def test_mixed_kinds(self):
        p = run(SCRIPTS / "export_local.py", self.session)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual(out["kinds"], {"issue": 1, "idea": 1, "task": 1, "note": 1})  # deleted item dropped
        md = (self.session / "items.md").read_text(encoding="utf-8")
        self.assertIn("## Issues (1)", md)
        self.assertNotIn("Dropped one", md)
        self.assertIn("](frames/I-1-1.jpg)", md)
        raw = (self.session / "notes.csv").read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))  # BOM so Excel reads CJK
        with open(self.session / "notes.csv", encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))
        self.assertEqual(rows[1][1], ITEMS["items"][4]["title"])  # comma / newline survive the round trip
        with open(self.session / "issues.csv", encoding="utf-8-sig", newline="") as fh:
            row = list(csv.DictReader(fh))[0]
        self.assertEqual(row["Tags"], "ui, css")

    def test_language_inference_and_override(self):
        data = {**ITEMS, "language": "zh-CN", "items": [ITEMS["items"][0]]}
        (self.session / "items.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        for args, heading, title_column, steps_label in (
            ((), "## 问题 (1)", "标题", "复现步骤"),
            (("--lang", "en"), "## Issues (1)", "Title", "Steps to reproduce"),
        ):
            with self.subTest(args=args):
                p = run(SCRIPTS / "export_local.py", self.session, *args)
                self.assertEqual(p.returncode, 0, p.stderr)
                # A single issue kind retains the issues.md filename.
                md = (self.session / "issues.md").read_text(encoding="utf-8")
                self.assertIn(heading, md.splitlines())
                self.assertIn(f"**{steps_label}**:", md)
                with open(self.session / "issues.csv", encoding="utf-8-sig", newline="") as fh:
                    rows = list(csv.DictReader(fh))
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0][title_column], data["items"][0]["title"])

    def test_custom_output_preserves_media_links(self):
        clip = self.session / "clips" / "I-1.mp4"
        clip.parent.mkdir()
        clip.write_bytes(b"test clip")
        data = json.loads((self.session / "items.json").read_text(encoding="utf-8"))
        data["items"][0]["clip"] = "clips/I-1.mp4"
        (self.session / "items.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        out = self.session.parent / "nested" / "export"
        p = run(SCRIPTS / "export_local.py", self.session, "--out", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        md = (out / "items.md").read_text(encoding="utf-8")
        with open(out / "issues.csv", encoding="utf-8-sig", newline="") as fh:
            row = list(csv.DictReader(fh))[0]
        for column, relative, source in (
            ("Screenshots", "../../session/frames/I-1-1.jpg", self.session / "frames" / "I-1-1.jpg"),
            ("Clip", "../../session/clips/I-1.mp4", clip),
        ):
            with self.subTest(column=column):
                self.assertIn(f"]({relative})", md)  # URLs use POSIX separators on Windows too.
                self.assertEqual(row[column], relative)
                self.assertEqual((out / row[column]).resolve(), source.resolve())
                self.assertTrue((out / row[column]).is_file())

    def test_missing_items_json(self):
        (self.session / "items.json").unlink()
        p = run(SCRIPTS / "export_local.py", self.session)
        self.assertEqual(p.returncode, 1)
        self.assertIn("items.json", p.stderr)
        self.assertNotIn("Traceback", p.stderr)


class ReviewServer(Base):
    def test_api_files_and_confirm(self):
        proc = subprocess.Popen([sys.executable, str(SCRIPTS / "review.py"), str(self.session), "--no-open"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.addCleanup(proc.kill)
        url = proc.stdout.readline().split()[-1]
        get = lambda path, **h: urllib.request.urlopen(urllib.request.Request(url + path, headers=h), timeout=5)  # noqa: E731

        self.assertEqual(len(json.load(get("api/items"))["items"]), 5)
        self.assertEqual(get("files/frames/I-1-1.jpg", Range="bytes=2-4").read(), b"234")  # video seeking
        with self.assertRaises(urllib.error.HTTPError):  # no path traversal out of the session
            get("files/../../etc/passwd")

        data = json.loads((self.session / "items.json").read_text(encoding="utf-8"))
        data["items"][0]["status"] = "deleted"
        req = urllib.request.Request(url + "api/confirm", data=json.dumps(data).encode(), method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        summary = json.loads(proc.communicate(timeout=10)[0].strip().splitlines()[-1])
        self.assertEqual((summary["reviewed"], summary["kept"], summary["deleted"]), (True, 3, 2))


if __name__ == "__main__":
    unittest.main()
