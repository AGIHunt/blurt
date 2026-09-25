"""CLI tests for skills/blurt/scripts/export_local.py (stdlib only, no network)."""
from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts" / "export_local.py"


def make_issue(**overrides):
    issue = {
        "id": "B-001",
        "title": "Login button unresponsive",
        "module": "Login page",
        "owner": "Wang",
        "severity": "high",
        "type": "bug",
        "actual": "Nothing happens on click",
        "expected": "Redirect to home",
        "steps": ["Open login page", "Click Login"],
        "time": {"start": 12.4, "end": 30.1},
        "quote": "It does nothing",
        "frames": [{"path": "frames/B-001-1.jpg", "t": 14.2, "caption": "no change"}],
        "clip": "clips/B-001.mp4",
        "code_refs": ["src/pages/Login.tsx:42"],
        "questions": [],
        "status": "draft",
    }
    issue.update(overrides)
    return issue


class ExportLocalCliTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.session = self.root / "session"
        self.session.mkdir()

    def write_issues(self, issues, **meta):
        data = {"session": "test", "language": "en", "issues": issues}
        data.update(meta)
        (self.session / "issues.json").write_text(
            json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.session), *args],
            capture_output=True, text=True, encoding="utf-8", timeout=15)

    def outputs(self, out=None):
        out = Path(out or self.session)
        md = (out / "issues.md").read_text(encoding="utf-8")
        with (out / "issues.csv").open(encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))
        return md, rows

    def test_english_labels_default(self):
        self.write_issues([make_issue()])
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        md, rows = self.outputs()
        self.assertIn("# Issues (1)", md)
        self.assertIn("**Steps to reproduce**:", md)
        self.assertEqual(rows[0][:4], ["ID", "Summary", "Module", "Owner"])
        self.assertEqual(json.loads(proc.stdout)["issues"], 1)

    def test_chinese_inference_and_lang_override(self):
        self.write_issues([make_issue(title="登录按钮点击后无响应")], language="zh-CN")
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        md, rows = self.outputs()
        self.assertIn("# 问题清单 (1)", md)
        self.assertIn("**复现步骤**:", md)
        self.assertEqual(rows[0][:2], ["编号", "问题描述"])
        proc = self.run_cli("--lang", "en")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        md, rows = self.outputs()
        self.assertIn("# Issues (1)", md)
        self.assertEqual(rows[0][:2], ["ID", "Summary"])

    def test_deleted_issues_excluded(self):
        self.write_issues([make_issue(), make_issue(id="B-002", title="Removed bug", status="deleted")])
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        md, rows = self.outputs()
        self.assertIn("B-001", md)
        self.assertNotIn("B-002", md)
        self.assertNotIn("Removed bug", md)
        self.assertEqual([row[0] for row in rows[1:]], ["B-001"])
        self.assertEqual(json.loads(proc.stdout)["issues"], 1)

    def test_csv_bom_unicode_and_escaping(self):
        tricky = '逗号, "引号" 与换行\n第二行'
        self.write_issues([make_issue(title=tricky, actual="点击后无反应")])
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        raw = (self.session / "issues.csv").read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))  # UTF-8 BOM so Excel reads CJK
        md, rows = self.outputs()
        self.assertEqual(rows[1][1], tricky)  # comma/quote/newline survive the CSV round-trip
        self.assertEqual(rows[1][6], "点击后无反应")
        self.assertIn(tricky, md)  # Unicode preserved verbatim in Markdown

    def test_custom_out_keeps_relative_media_paths(self):
        frame = self.session / "frames" / "B-001-1.jpg"
        clip = self.session / "clips" / "B-001.mp4"
        frame.parent.mkdir()
        frame.write_bytes(b"x")
        clip.parent.mkdir()
        clip.write_bytes(b"x")
        out = self.root / "out"
        self.write_issues([make_issue()])
        proc = self.run_cli("--out", str(out))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        md, rows = self.outputs(out)
        self.assertIn("(../session/frames/B-001-1.jpg)", md)  # POSIX separators on all OSes
        self.assertIn("(../session/clips/B-001.mp4)", md)
        self.assertEqual(rows[1][11], "../session/frames/B-001-1.jpg")  # frames column
        self.assertEqual(rows[1][12], "../session/clips/B-001.mp4")  # clip column
        self.assertEqual((out / rows[1][11]).resolve(), frame.resolve())
        self.assertEqual((out / rows[1][12]).resolve(), clip.resolve())

    def test_missing_issues_json_fails_clearly(self):
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("issues.json not found", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)  # clean error, not a crash dump


if __name__ == "__main__":
    unittest.main()
