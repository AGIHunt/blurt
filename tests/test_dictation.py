"""Dictation history (docs/design/dictation.md): the append-only history.jsonl the macOS app writes, read back by
dictation.py (edits applied, retention), and "Turn into item" (items.py add, no agent).

  uv run --with pytest pytest tests/test_dictation.py -q
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_store import TmpCase, make_repo, ok, run_cli  # noqa: E402


def entry(i: str, days_ago: float = 0, **kw) -> dict:
    t = (datetime.now(timezone.utc) - timedelta(days=days_ago)).astimezone().isoformat(timespec="seconds")
    e = {"id": i, "t": t, "app": "Notes", "bundle": "com.apple.Notes", "duration": 3.2, "raw": "嗯那个记得问一下设计稿的进度",
         "polished": "记得问一下设计稿的进度。", "text": "记得问一下设计稿的进度。", "model": "qwen3.5-4b", "fell_back": False,
         "reason": None, "insert": "pasted", "audio": None}
    e.update(kw)
    return e


class History(TmpCase):
    def write(self, lines: list[dict]) -> Path:
        d = self.e.home / "dictation"
        d.mkdir(parents=True, exist_ok=True)
        p = d / "history.jsonl"
        p.write_text("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in lines), encoding="utf-8")
        return p

    def test_list_applies_edits(self):
        self.write([entry("d-1", 2), entry("d-2", 1, text="Hello.", raw="um hello", app="Slack"), entry("d-3", 0),
                    {"op": "delete", "ids": ["d-3"]}, {"op": "item", "id": "d-1", "item": "BA-1", "uid": "01X"},
                    "not json"])
        out = ok("dictation.py", "list", env=self.e.env())
        self.assertEqual([e["id"] for e in out["entries"]], ["d-2", "d-1"])          # newest first, d-3 deleted
        self.assertEqual(out["entries"][1]["item"], "BA-1")
        self.assertEqual([e["id"] for e in ok("dictation.py", "list", "--query", "slack", env=self.e.env())["entries"]], ["d-2"])
        self.assertEqual([e["id"] for e in ok("dictation.py", "list", "--days", "1.5", env=self.e.env())["entries"]], ["d-2"])

    def test_clear_op(self):
        self.write([entry("d-1"), {"op": "clear"}, entry("d-2")])
        self.assertEqual([e["id"] for e in ok("dictation.py", "list", env=self.e.env())["entries"]], ["d-2"])

    def test_prune_drops_old_entries_and_their_audio(self):
        audio = self.e.home / "dictation" / "audio"
        audio.mkdir(parents=True)
        (audio / "d-old.wav").write_bytes(b"RIFF")
        (audio / "d-new.wav").write_bytes(b"RIFF")
        p = self.write([entry("d-old", 40, audio="audio/d-old.wav"), entry("d-new", 1, audio="audio/d-new.wav"),
                        {"op": "item", "id": "d-new", "item": "BA-2", "uid": "01Y"}, {"op": "delete", "ids": ["nope"]}])
        self.assertEqual(ok("dictation.py", "prune", env=self.e.env())["removed"], 1)          # default: 30 days
        self.assertFalse((audio / "d-old.wav").exists())
        self.assertTrue((audio / "d-new.wav").exists())
        lines = [json.loads(x) for x in p.read_text().splitlines()]
        self.assertEqual([x.get("id") for x in lines], ["d-new", "d-new"])                  # the entry, its item op
        self.assertEqual(ok("dictation.py", "list", env=self.e.env())["entries"][0]["item"], "BA-2")
        cfg = json.loads((self.e.home / "config.json").read_text())
        cfg["record"]["dictation"] = {"retention_days": 0}
        (self.e.home / "config.json").write_text(json.dumps(cfg))
        self.assertEqual(ok("dictation.py", "prune", env=self.e.env())["removed"], 1)

    def test_prune_removes_orphaned_audio(self):
        # dict025: a dropped take's wav (and its pieces) with no entry goes once it is an hour old; a kept one and a
        # take still running stay
        audio = self.e.home / "dictation" / "audio"
        audio.mkdir(parents=True)
        old = time.time() - 2 * 3600
        for n in ("d-kept.wav", "d-lost.wav", "d-lost-p1.wav", "d-now.wav"):
            (audio / n).write_bytes(b"RIFF")
            if n != "d-now.wav":
                os.utime(audio / n, (old, old))
        self.write([entry("d-kept", 1, audio="audio/d-kept.wav")])
        ok("dictation.py", "prune", env=self.e.env())
        self.assertEqual(sorted(p.name for p in audio.iterdir()), ["d-kept.wav", "d-now.wav"])

    def test_prune_keeps_an_interrupted_take_for_the_app(self):
        # quit mid-take: the take's own recording (no entry) stays within the retention — the app turns it into an
        # "interrupted" entry with Retry; its pieces go, and so does one older than the retention
        audio = self.e.home / "dictation" / "audio"
        audio.mkdir(parents=True)
        two_h, forty_d = time.time() - 2 * 3600, time.time() - 40 * 86400
        for n, t in (("d-20261030-141400-dccd.wav", two_h), ("d-20261030-141400-dccd-p1.wav", two_h),
                     ("d-20260901-101010-abcd.wav", forty_d)):
            (audio / n).write_bytes(b"RIFF")
            os.utime(audio / n, (t, t))
        self.write([entry("d-1", 1)])
        ok("dictation.py", "prune", env=self.e.env())
        self.assertEqual(sorted(p.name for p in audio.iterdir()), ["d-20261030-141400-dccd.wav"])

    def test_turn_into_item(self):
        repo = make_repo(self.tmp / "web-app")
        proj = ok("projects.py", "add", repo, env=self.e.env())["project"]
        self.write([entry("d-1", text="The export button is broken. Clicking it does nothing.", raw="um the export button")])
        out = ok("dictation.py", "item", "d-1", "--project", proj["id"], env=self.e.env())
        it = out["item"]
        self.assertEqual(it["kind"], "issue")
        self.assertEqual(it["title"], "The export button is broken")          # first sentence, trailing stop trimmed
        md = Path(it["path"]).read_text(encoding="utf-8")
        self.assertIn("Clicking it does nothing.", md)
        self.assertIn("dictation", md)
        listed = ok("dictation.py", "list", env=self.e.env())["entries"][0]
        self.assertEqual(listed["item"], it["id"])
        again = ok("dictation.py", "item", "d-1", env=self.e.env())["item"]                  # once only
        self.assertTrue(again["already"])
        # Unassigned by default
        self.write([entry("d-2")])
        it2 = ok("dictation.py", "item", "d-2", env=self.e.env())["item"]
        self.assertEqual(it2["project"], "inbox")
        self.assertEqual(it2["kind"], "task")                                               # 记得… = a to-do
        code, err = run_cli("dictation.py", "item", "d-404", env=self.e.env())
        self.assertEqual((code, err["code"]), (1, "not_found"))
