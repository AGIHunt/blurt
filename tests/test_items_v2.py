"""items.py v3 (contract K1, K3): the agent's items.json → items (ingest), every command by REF and by the v2
`SESSION ID` form, the user's fields kept, work states and who may set them, doc / poll / user-ops (the same result as
review.py), moves, and the guarantees hosts rely on (one JSON line, error codes, locks, nothing lost under load)."""
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import threading
import types
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
from test_store import SCRIPTS, TmpCase, ok, run_cli  # noqa: E402

import _common  # noqa: E402
import items  # noqa: E402
import review  # noqa: E402
import store as st  # noqa: E402

ULID = re.compile(r"[0-7][0-9A-HJKMNP-TV-Z]{25}")
AGENT_JSON = {"title": "Settings walkthrough", "language": "en", "digest": "## Overview", "processing": True,
              "agent_at": 1792560000.0,
              "source_video": "recording.mp4", "items": [
                  {"id": "I-001", "kind": "issue", "title": "Save sits 6px low", "quote": "the save button is low",
                   "actual": "misaligned", "expected": "aligned", "steps": ["Open Settings", "Look at Save"],
                   "time": {"start": 1.0, "end": 3.5}, "severity": "low", "source": {"app": "Chrome"}},
                  {"id": "I-002", "kind": "idea", "title": "Tip card", "why": "the empty state feels dead"},
                  {"id": "I-003", "kind": "task", "title": "Ask design for copy"}]}


class Base(TmpCase):
    def setUp(self):
        super().setUp()
        self.proj = self.tmp / "web-app"
        self.proj.mkdir()
        self.p = ok("projects.py", "add", self.proj, env=self.e.env())["project"]
        self.s = self.proj / ".blurt" / "sessions" / "20261022-101500"
        (self.s / "frames").mkdir(parents=True)
        for n in range(1, 4):
            (self.s / "frames" / f"I-00{n}-1.jpg").write_bytes(b"jpg%d" % n)
        (self.s / "recording.mp4").write_bytes(b"mp4")
        (self.s / "items.json").write_text(json.dumps(AGENT_JSON))

    def cli(self, *args, **kw):
        return run_cli("items.py", *args, env=self.e.env(**kw.pop("env", {})), **kw)

    def ok(self, *args, **kw):
        return ok("items.py", *args, env=self.e.env(**kw.pop("env", {})), **kw)

    def item(self, ref) -> dict:
        return self.ok("get", ref)["item"]

    def file(self, ref) -> Path:
        return Path(self.ok("path", ref)["path"])


class Ingest(Base):
    def test_ingest_writes_items_and_batch(self):
        out = self.ok("ingest", self.s)
        self.assertEqual([r["id"] for r in out["items"]], ["WA-1", "WA-2", "WA-3"])
        self.assertEqual(out["inbox"], 0)
        self.assertTrue(all(ULID.fullmatch(r["uid"]) is None for r in out["items"]))  # draft items: legacy uid
        self.assertEqual([r["local"] for r in out["items"]], ["I-001", "I-002", "I-003"])
        self.assertFalse((self.s / "items.json").exists())
        self.assertTrue((self.s / "items.ingested.json").is_file())  # kept for debugging
        b = json.loads((self.s / "batch.json").read_text())
        self.assertEqual((b["schema"], b["title"], b["processing"], b["reviewed"]), (3, "Settings walkthrough", True, False))
        self.assertEqual(b["items"], [r["uid"] for r in out["items"]])
        self.assertEqual(b["local"], {r["local"]: r["uid"] for r in out["items"]})
        a = self.item("WA-1")
        self.assertEqual((a["status"], a["project"], a["project_by"], a["source"]["type"], a["source"]["app"],
                          a["source"]["local_id"], a["source"]["session"]),
                         ("draft", self.p["id"], "capture", "recording", "Chrome", "I-001", str(self.s)))
        self.assertEqual(a["steps"], ["Open Settings", "Look at Save"])
        self.assertNotIn("work", a)  # todo
        md = Path(a["path"]).read_text()
        self.assertTrue(Path(a["path"]).name == "WA-1-save-sits-6px-low.md")
        self.assertIn("## Steps\n\n1. Open Settings\n2. Look at Save", md)
        # nothing pending: a second ingest is a no-op
        self.assertEqual(self.ok("ingest", self.s)["items"], [])

    def test_old_skill_flow_auto_ingests(self):
        """SKILL.md §3–§4 as v0.6 agents do it: write items.json, then items.py with SESSION ID."""
        out = self.ok("set-frames", self.s, "I-001", "frames/I-001-1.jpg@2.5#the save button")
        self.assertEqual((out["id"], out["written"]), ("WA-1", ["frames"]))
        a = self.item("WA-1")
        self.assertEqual(a["frames"], [{"path": str(self.proj / ".blurt" / "assets" / a["uid"] / "1.jpg"), "t": 2.5,
                                        "caption": "the save button"}])
        self.assertEqual(Path(a["frames"][0]["path"]).read_bytes(), b"jpg1")
        self.assertIn("![the save button · 0:02](../assets/", Path(a["path"]).read_text())
        self.ok("patch", self.s, "I-002", "--set", 'code_refs=["web/Tip.tsx:3"]', "--set", "next_steps=[\"prototype\"]")
        self.assertEqual(self.item("WA-2")["code_refs"], ["web/Tip.tsx:3"])
        self.ok("patch", self.s, ".", "--set", "digest=## Better overview")
        self.assertEqual(json.loads((self.s / "batch.json").read_text())["digest"], "## Better overview")
        out = self.ok("done", self.s)
        self.assertEqual((out["items"], out["no_frames"]), (3, ["WA-2", "WA-3"]))
        self.assertFalse(json.loads((self.s / "batch.json").read_text())["processing"])

    def test_agent_rewrites_items_json_after_the_user_edited(self):
        self.ok("ingest", self.s)
        self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": "I-001", "set": {"title": "Mine"}}]))
        again = json.loads(json.dumps(AGENT_JSON))
        again["items"][0]["title"] = "agent's"
        again["items"][0]["owner"] = "amy"
        again["items"].append({"id": "I-004", "kind": "note", "title": "one more"})
        (self.s / "items.json").write_text(json.dumps(again))
        out = self.ok("ingest", self.s)
        self.assertEqual([r["id"] for r in out["items"]], ["WA-1", "WA-2", "WA-3", "WA-4"])
        a = self.item("WA-1")
        self.assertEqual((a["title"], a["owner"]), ("Mine", "amy"))  # the user's title wins, the agent's field lands
        self.assertEqual(len(st.Store(self.proj / ".blurt").files()), 4)

    def test_loose_session_goes_to_the_inbox(self):
        loose = self.tmp / "some" / "where"
        loose.mkdir(parents=True)
        (loose / "items.json").write_text(json.dumps({"items": [{"id": "I-1", "kind": "note", "title": "n"}]}))
        out = self.ok("ingest", loose)
        self.assertEqual((out["items"][0]["id"], out["inbox"]), ("IN-1", 1))
        self.assertEqual(self.item("IN-1")["source"]["type"], "import")


class Refs(Base):
    def setUp(self):
        super().setUp()
        self.ok("ingest", self.s)
        self.u1 = json.loads((self.s / "batch.json").read_text())["local"]["I-001"]

    def test_every_way_to_name_an_item(self):
        path = self.file("WA-1")
        for ref in ("WA-1", self.u1, str(path)):
            self.assertEqual(self.item(ref)["uid"], self.u1, ref)
        self.assertEqual(self.ok("get", self.s, "I-001")["item"]["uid"], self.u1)
        self.assertEqual(self.ok("get", self.s, self.u1)["item"]["id"], "WA-1")
        p = self.ok("path", "WA-1")
        self.assertEqual((p["uid"], p["id"], p["project"], p["store"]), (self.u1, "WA-1", self.p["id"],
                                                                          str(self.proj / ".blurt")))
        g = self.ok("get", "WA-1")
        self.assertEqual((g["session"], g["item"]["_project"]["key"]), (str(self.s), "WA"))
        for bad in ("WA-99", "01JB7ZK3Q4M8W2E5R6T9Y0ZZZZ", "nope"):
            code, out = self.cli("get", bad)
            self.assertEqual((code, out["code"]), (1, "not_found"), bad)

    def test_list_filters(self):
        ids = lambda *a: [i["id"] for i in self.ok("list", *a)["items"]]  # noqa: E731
        self.assertEqual(ids(self.s), ["WA-1", "WA-2", "WA-3"])  # session: review order
        self.assertEqual(ids("--project", "WA"), ["WA-3", "WA-2", "WA-1"])  # project: newest first (ties: id desc)
        self.assertEqual(ids(self.s, "--kind", "idea", "--kind", "task"), ["WA-2", "WA-3"])
        self.ok("work", "WA-1", "--state", "in_progress")
        self.assertEqual(ids(self.s, "--work", "in_progress"), ["WA-1"])
        self.assertEqual(ids(self.s, "--fix-state", "fixing"), ["WA-1"])  # the v2 name
        self.assertEqual(ids(self.s, "--fix-state", "none"), ["WA-2", "WA-3"])
        self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": "WA-3", "set": {"status": "deleted"}}]))
        self.assertEqual(ids(self.s), ["WA-1", "WA-2"])  # deleted only when asked for
        self.assertEqual(ids(self.s, "--status", "deleted"), ["WA-3"])
        self.assertTrue(all(os.path.isabs(i["path"]) for i in self.ok("list")["items"]))


class AgentWrites(Base):
    def setUp(self):
        super().setUp()
        self.ok("ingest", self.s)

    def test_user_fields_are_kept_unless_forced(self):
        self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": "WA-1", "set": {"title": "Mine",
                                                                                                "_touched": True}}]))
        out = self.ok("patch", "WA-1", "--set", "title=agent", "--set", "owner=amy")
        self.assertEqual((out["written"], out["kept_user"]), (["owner"], ["title"]))
        self.assertEqual(self.item("WA-1")["title"], "Mine")
        self.ok("patch", "WA-1", "--set", "title=from chat", "--force")
        self.assertEqual(self.item("WA-1")["title"], "from chat")
        self.assertNotIn("_touched", self.item("WA-1")["_user"])  # bookkeeping keys aren't user fields

    def test_protected_and_user_only_fields(self):
        for field in ("work", "work_history", "fix", "uid", "id", "project", "aliases", "created", "_user", "path"):
            code, out = self.cli("patch", "WA-1", "--set", f"{field}=1")
            self.assertEqual((code, out["code"]), (1, "protected"), field)
        code, out = self.cli("patch", "WA-1", "--set", "status=confirmed")  # keeping / dropping is the user's call
        self.assertEqual((code, out["code"]), (1, "user_only"))
        self.ok("patch", "WA-1", "--set", "status=deleted", "--force")  # the user said so in chat
        self.assertEqual(self.item("WA-1")["status"], "deleted")
        out = self.ok("patch", "WA-1", "--set", "owner=x")
        self.assertIn("dropped", out["note"])
        for args in (["--set", "title="], ["--set", "title=  "], ["--unset", "title"]):
            code, out = self.cli("patch", "WA-2", *args)
            self.assertEqual((code, out["ok"]), (1, False), args)
            self.assertIn("title", out["error"])

    def test_add(self):
        out = self.ok("add", self.s, "--json", '{"kind":"idea","title":"New one"}', "--after", "WA-1")
        self.assertRegex(out["uid"], ULID)
        self.assertEqual(out["id"], "WA-4")
        b = json.loads((self.s / "batch.json").read_text())
        self.assertEqual(b["items"][1], out["uid"])  # --after (an id, a uid or a draft id)
        self.assertTrue(Path(out["path"]).is_file())
        out = self.ok("add", self.s, "--json", '{"kind":"note","title":"draft id","id":"I-009"}')
        self.assertEqual(self.ok("get", self.s, "I-009")["item"]["uid"], out["uid"])
        code, err = self.cli("add", self.s, "--json", '{"kind":"note","title":"again","id":"I-009"}')
        self.assertEqual((code, err["code"]), (1, "taken"))
        code, err = self.cli("add", self.s, "--json", json.dumps({"kind": "note", "title": "x", "uid": out["uid"]}))
        self.assertEqual((code, err["code"]), (1, "taken"))
        inbox = self.ok("add", "--project", "inbox", "--json", '{"kind":"note","title":"loose"}')
        self.assertEqual(inbox["id"], "IN-1")
        code, err = self.cli("add", "--project", "nope", "--json", '{"kind":"note","title":"x"}')
        self.assertEqual(err["code"], "no_project")

    def test_set_frames_append_and_merged(self):
        self.ok("set-frames", "WA-1", str(self.s / "frames" / "I-001-1.jpg") + "@1")
        self.ok("set-frames", self.s, "I-001", "frames/I-002-1.jpg", "--append")
        a = self.item("WA-1")
        self.assertEqual([Path(f["path"]).name for f in a["frames"]], ["1.jpg", "2.jpg"])
        # the user merged WA-2 into WA-1: WA-2's evidence goes to WA-1
        self.ok("user-ops", self.s, "--json", json.dumps([
            {"op": "set", "id": "WA-1", "set": {"merged_from": ["I-002"]}}, {"op": "remove", "id": "WA-2", "into": "WA-1"}]))
        out = self.ok("set-frames", self.s, "I-002", "frames/I-003-1.jpg")
        self.assertEqual(out["appended_to"], "WA-1")
        self.assertEqual(len(self.item("WA-1")["frames"]), 3)
        self.assertEqual(self.item("WA-1")["merged_from"], [self.ok("path", "WA-2")["uid"]])  # draft id → uid
        self.assertEqual(self.ok("patch", self.s, "I-002", "--set", "x=1")["skipped"], "merged into WA-1")
        code, out = self.cli("get", "WA-2")
        self.assertEqual((code, out["code"]), (1, "merged"))
        code, out = self.cli("set-frames", "WA-1", "frames/missing.jpg")
        self.assertEqual((code, out["code"]), (1, "not_found"))


class Work(Base):
    def setUp(self):
        super().setUp()
        self.ok("ingest", self.s)

    def test_who_may_set_what(self):
        # an agent: start, claim, never done / wontfix / handed_off
        w = self.ok("work", "WA-1", "--state", "in_progress", "--agent", "claude", "--job", "j-1")["items"][0]["work"]
        self.assertEqual((w["state"], w["agent"], w["job"], w["by"]), ("in_progress", "claude", "j-1", "agent"))
        self.assertEqual(list(w), list(_common.WORK_KEYS))
        for state in ("done", "wontfix", "handed_off"):
            code, out = self.cli("work", "WA-1", "--state", state)
            self.assertEqual((code, out["code"]), (1, "bad_transition"), state)
        w = self.ok("work", "WA-1", "--state", "to_verify", "--claim", "fixed", "--commit", "abc1234",
                    "--note", "nudged 6px")["items"][0]["work"]
        self.assertEqual((w["state"], w["claim"], w["agent"], w["job"], w["commit"]),
                         ("to_verify", "fixed", "claude", "j-1", "abc1234"))  # agent and job carry over
        w = self.ok("work", "WA-1", "--state", "to_verify", "--pr", "https://example.test/pr/1")["items"][0]["work"]
        self.assertEqual((w["commit"], w["pr"], w["claim"]), ("abc1234", "https://example.test/pr/1", "fixed"))
        # only the user marks it done (or reopens it)
        w = self.ok("work", "WA-1", "--state", "done", "--by", "user")["items"][0]["work"]
        self.assertEqual((w["state"], w["by"], w["commit"]), ("done", "user", "abc1234"))
        hist = self.item("WA-1")["work_history"]
        self.assertEqual([h["state"] for h in hist], ["in_progress", "to_verify"])  # same state: no new entry
        self.assertEqual(self.ok("work", "WA-1", "--state", "todo", "--by", "user", "--note", "still low")
                         ["items"][0]["work"]["agent"], "human")
        code, out = self.cli("work", "WA-1", "--state", "in_progress", "--by", "robot")
        self.assertEqual(code, 1)

    def test_handoffs_and_deleted_items(self):
        w = self.ok("work", "WA-2", "--state", "handed_off", "--by", "user", "--handoff", "H-0012")["items"][0]
        self.assertEqual((w["work"]["to"], w["work"]["handoff"]), ("external", "H-0012"))
        self.assertNotIn("confirmed", w)
        out = self.ok("work", "WA-3", "--state", "handed_off", "--by", "app", "--agent", "codex", "--job", "j-9")
        self.assertEqual((out["items"][0]["work"]["to"], out["items"][0]["confirmed"]), ("session", True))
        self.assertEqual(self.item("WA-3")["status"], "confirmed")  # dispatching a draft keeps it
        w = self.ok("work", "WA-3", "--state", "in_progress", "--by", "app")["items"][0]["work"]
        self.assertEqual((w["agent"], w["job"], w["to"]), ("codex", "j-9", "session"))
        self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": "WA-1", "set": {"status": "deleted"}}]))
        code, out = self.cli("work", "WA-1", "--state", "handed_off", "--by", "app")
        self.assertEqual((code, out["code"]), (1, "deleted"))
        # several at once: all checked before any is written
        code, out = self.cli("work", "WA-2", "WA-1", "--state", "in_progress")
        self.assertEqual(out["code"], "deleted")
        self.assertEqual(self.item("WA-2")["work"]["state"], "handed_off")

    def test_env_defaults_and_the_v2_fix_alias(self):
        env = {"BLURT_AGENT": "kimi", "BLURT_RUN_ID": "r-9"}
        w = self.ok("fix", self.s, "I-002", "--state", "fixing", env=env)["work"]
        self.assertEqual((w["state"], w["agent"], w["job"], w["by"]), ("in_progress", "kimi", "r-9", "agent"))
        w = self.ok("fix", "WA-2", "--state", "fixed", "--commit", "abc", env={**env, "BLURT_JOB": "j-2"})["work"]
        self.assertEqual((w["state"], w["claim"], w["commit"], w["job"]), ("to_verify", "fixed", "abc", "j-2"))
        w = self.ok("fix", "WA-2", "--state", "wontfix", env=env)["work"]
        self.assertEqual((w["state"], w["claim"]), ("to_verify", "wontfix"))  # an agent's wontfix is a claim
        w = self.ok("fix", "WA-3", "--state", "wontfix")["work"]  # no agent anywhere: the user's own call
        self.assertEqual((w["state"], w["agent"], w["by"]), ("wontfix", "human", "user"))
        w = self.ok("fix", "WA-2", "--state", "reopened", env=env)["work"]  # an agent takes its claim back
        self.assertEqual(w["state"], "todo")
        code, out = self.cli("fix", "WA-1", "--state", "done")
        self.assertEqual(code, 1)

    def test_job_events(self):
        jobs = self.e.home / "jobs"
        jobs.mkdir()
        (jobs / "j-20261022-101500-ab12.json").write_text("{}")
        s2 = self.proj / ".blurt" / "sessions" / "20261022-111500"
        s2.mkdir()
        (s2 / "items.json").write_text(json.dumps({"items": [{"id": "I-1", "kind": "note", "title": "x"}]}))
        env = {"BLURT_JOB": "j-20261022-101500-ab12"}
        self.ok("ingest", s2, env=env)
        self.ok("done", s2, env=env)
        ev = [json.loads(x) for x in (jobs / "j-20261022-101500-ab12.events.jsonl").read_text().splitlines()]
        self.assertEqual([(e["source"], e["event"], e["step"]["id"], e["step"]["state"]) for e in ev],
                         [("items", "step", "write", "done"), ("items", "step", "frames", "done")])
        self.assertEqual(len(ev[0]["items"]), 1)
        self.ok("done", s2, env={"BLURT_JOB": "j-nope"})  # no such job: nothing appended, no error


class Moves(Base):
    def test_move_changes_id_keeps_uid_assets_and_aliases(self):
        self.ok("ingest", self.s)
        self.ok("set-frames", "WA-1", str(self.s / "frames" / "I-001-1.jpg"))
        other = self.tmp / "other-proj"
        other.mkdir()
        po = ok("projects.py", "add", other, env=self.e.env())["project"]
        uid = self.ok("path", "WA-1")["uid"]
        out = self.ok("move", "WA-1", "--project", po["key"])["moved"][0]
        self.assertEqual((out["uid"], out["from"], out["to"], out["id"]), (uid, self.p["id"], po["id"], "OP-1"))
        a = self.item(uid)
        self.assertEqual((a["id"], a["aliases"], a["project"], a["project_by"]), ("OP-1", ["WA-1"], po["id"], "user"))
        self.assertTrue(Path(a["frames"][0]["path"]).is_file())
        self.assertTrue(a["frames"][0]["path"].startswith(str(other / ".blurt" / "assets" / uid)))
        self.assertFalse((self.proj / ".blurt" / "assets" / uid).exists())
        self.assertEqual(self.item("WA-1")["uid"], uid)  # the old id still finds it
        self.assertEqual(self.ok("get", self.s, "I-001")["item"]["id"], "OP-1")  # and so does the session's draft id
        # ids are never reused: the next AP item is WA-4
        self.assertEqual(self.ok("add", "--project", "WA", "--json", '{"kind":"note","title":"n"}')["id"], "WA-4")
        # moved back: a new id again, both old ids remembered
        self.ok("move", uid, "--project", "WA")
        self.assertEqual(self.item(uid)["aliases"], ["WA-1", "OP-1"])
        self.assertEqual(self.item(uid)["id"], "WA-5")


class UserOps(Base):
    OPS = [
        {"op": "set", "id": "I-001", "set": {"title": "Save is low (Safari)", "status": "confirmed", "_touched": True}},
        {"op": "set", "id": "I-002", "set": {"answer": "next week"}, "unset": ["why"]},
        {"op": "set", "id": "I-003", "set": {"merged_from": ["I-002"]}},
        {"op": "remove", "id": "I-002", "into": "I-003"},
        {"op": "add", "item": {"id": "I-002", "kind": "idea", "title": "Tip card"}, "after": "I-003"},
        {"op": "work", "id": "I-001", "state": "wontfix", "note": "by design"},
        {"op": "set", "id": "I-999", "set": {"title": "gone"}},  # unknown ids are ignored, as on the page
    ]

    def setUp(self):
        super().setUp()
        self.ok("ingest", self.s)

    def via_review(self, scope, ops, confirm=False):
        h = review.make_handler(scope, threading.Event())
        r = h.__new__(h)
        body = json.dumps({"ops": ops}).encode()
        r.path, r.command = "/api/confirm" if confirm else "/api/items", "POST"
        r.headers, r.rfile, r._send = {"Content-Length": str(len(body))}, io.BytesIO(body), Mock()
        r.do_POST()
        code, payload, _ctype, extra = r._send.call_args.args
        self.assertEqual(code, 200, payload)
        return json.loads(payload), extra["ETag"]

    def via_items(self, args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            items.main(args)
        return json.loads(buf.getvalue())

    def snapshot(self):
        files = {p.name: p.read_text() for p in sorted((self.proj / ".blurt" / "items").glob("*.md"))}
        return files, (self.s / "batch.json").read_text()

    def reset(self):
        import shutil  # noqa: PLC0415
        shutil.rmtree(self.proj / ".blurt" / "items")
        shutil.rmtree(self.proj / ".blurt" / "assets", ignore_errors=True)
        (self.s / "batch.json").unlink()
        (self.s / "items.ingested.json").rename(self.s / "items.json")
        st.Store(self.proj / ".blurt").set_meta(next=1)
        st._MAPS.clear()
        self.ok("ingest", self.s)

    def test_same_result_as_review_post(self):
        for confirm in (False, True):
            with patch("time.time", return_value=1792570000.04), patch.object(_common, "now_iso",
                                                                             return_value="2026-10-22T10:00:00+08:00"):
                with patch.object(items, "now_iso", return_value="2026-10-22T10:00:00+08:00"):
                    doc, tag = self.via_review({"session": str(self.s)}, self.OPS, confirm)
                    a = self.snapshot()
                    self.reset()
                    out = self.via_items(["user-ops", str(self.s), "--json", json.dumps(self.OPS),
                                          *(["--confirm"] if confirm else [])])
                    b = self.snapshot()
            self.assertEqual(a, b, confirm)  # byte for byte the same files
            self.assertEqual((out["ok"], out["etag"]), (True, tag))
            self.assertEqual(out["doc"], doc)
            self.reset()

    def test_semantics(self):
        out = self.ok("user-ops", self.s, "--stdin", stdin=json.dumps(self.OPS))
        doc = out["doc"]
        self.assertEqual(out["etag"], items.doc_etag(doc))
        self.assertEqual([i["id"] for i in doc["items"]], ["WA-1", "WA-3", "WA-2"])  # I-002 came back after I-003
        self.assertEqual(doc["_removed"], {})
        a = self.item("WA-1")
        self.assertEqual(set(a["_user"]), {"title", "status"})
        self.assertEqual((a["status"], a["work"]["state"], a["work"]["by"], a["work"]["note"]),
                         ("confirmed", "wontfix", "user", "by design"))
        self.assertTrue(a["_touched"])
        self.assertNotIn("why", self.item("WA-2"))
        self.assertIn("why", self.item("WA-2")["_user"])
        self.assertEqual(self.ok("patch", "WA-1", "--set", "title=agent")["kept_user"], ["title"])
        # a merge (remove) on its own: the item is deleted with merged_into, and leaves the doc
        out = self.ok("user-ops", self.s, "--json", json.dumps([{"op": "remove", "id": "WA-3", "into": "WA-1"}]))
        uid3 = self.ok("path", "WA-3")["uid"]
        self.assertEqual(out["doc"]["_removed"], {uid3: self.ok("path", "WA-1")["uid"]})
        self.assertEqual([i["id"] for i in out["doc"]["items"]], ["WA-1", "WA-2"])
        h = st.read_header(self.file("WA-3"))
        self.assertEqual((h["status"], h["merged_into"]), ("deleted", self.ok("path", "WA-1")["uid"]))
        # ops by uid, the page's POST body as is, and --confirm
        self.ok("user-ops", self.s, "--confirm", "--json", json.dumps({"ops": [{"op": "set", "id": a["uid"],
                                                                                 "set": {"owner": "bo"}}]}))
        self.assertEqual(self.item("WA-1")["owner"], "bo")
        self.assertTrue(json.loads((self.s / "batch.json").read_text())["reviewed"])

    def test_changing_project_is_a_move_by_the_user(self):
        other = self.tmp / "other-proj"
        other.mkdir()
        po = ok("projects.py", "add", other, env=self.e.env())["project"]
        uid = self.ok("path", "WA-2")["uid"]
        out = self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": uid, "set": {"project": po["id"]}}]))
        moved = next(i for i in out["doc"]["items"] if i["uid"] == uid)
        self.assertEqual((moved["id"], moved["project"], moved["_project"]["key"]), ("OP-1", po["id"], "OP"))
        self.assertIn("project", moved["_user"])
        # an id in an op goes stale after a move, the uid doesn't: an edit by uid lands
        self.ok("user-ops", self.s, "--json", json.dumps([{"op": "set", "id": uid, "set": {"answer": "yes"}}]))
        self.assertEqual(self.item(uid)["answer"], "yes")
        self.assertEqual(out["doc"]["projects"][-1]["id"], "inbox")
        self.assertEqual({p["key"] for p in out["doc"]["projects"]}, {"WA", "OP", "IN"})

    def test_bad_ops_change_nothing(self):
        before = self.snapshot()
        for bad in ("not json", "{}", '[{"op":"merge","id":"WA-1"}]', '[{"op":"set"}]', '[{"op":"add","item":{}}]',
                    '[{"op":"set","id":"WA-1","set":[1]}]', '[1]', '[{"op":"work","id":"WA-1","state":"later"}]'):
            code, out = self.cli("user-ops", self.s, "--json", bad)
            self.assertEqual((code, out["ok"]), (1, False), bad)
        code, out = self.cli("user-ops", self.s)
        self.assertEqual(code, 1)
        for title in ("", "   ", "　", None):
            bad = [{"op": "set", "id": "WA-2", "set": {"answer": "x"}}, {"op": "set", "id": "WA-1", "set": {"title": title}}]
            code, out = self.cli("user-ops", self.s, "--json", json.dumps(bad))
            self.assertEqual((code, out["code"]), (1, "bad_value"), title)
            self.assertIn("title can't be empty", out["error"])
        self.assertEqual(self.snapshot(), before)

    def test_doc_and_poll(self):
        out = self.ok("doc", self.s)
        doc, tag = out["doc"], out["etag"]
        self.assertEqual((doc["schema"], doc["scope"], doc["title"], doc["processing"]),
                         (3, {"session": str(self.s)}, "Settings walkthrough", True))
        self.assertEqual((doc["source_video"], doc["_video"]), (str(self.s / "recording.mp4"), True))
        self.assertTrue(all(os.path.isabs(i["path"]) and i["_project"]["key"] == "WA" for i in doc["items"]))
        self.assertEqual(self.ok("poll", self.s, "--etag", tag), {"ok": True, "etag": tag})
        self.ok("patch", "WA-3", "--set", "owner=x")
        changed = self.ok("poll", self.s, "--etag", tag)
        self.assertNotEqual(changed["etag"], tag)
        self.assertEqual(changed["doc"]["items"][2]["owner"], "x")
        proj = self.ok("doc", "--project", "WA", "--kind", "issue")["doc"]
        self.assertEqual((proj["scope"], [i["id"] for i in proj["items"]]),
                         ({"project": self.p["id"], "kind": ["issue"]}, ["WA-1"]))
        self.assertEqual(self.cli("doc")[1]["ok"], False)


class Cli(Base):
    def test_errors_are_one_json_line_with_a_code(self):
        self.ok("ingest", self.s)
        for args, code in ((("patch", "WA-1", "--set", "novalue"), "bad_args"),
                           (("patch", "WA-77", "--set", "a=1"), "not_found"), (("get",), "bad_args"),
                           (("list", "--status", "maybe"), "bad_args"), (("work", "WA-1"), "bad_args"),
                           (("list", self.tmp / "nowhere"), "not_found")):
            c, out = self.cli(*args)
            self.assertEqual((c, out["ok"], out["code"]), (1, False, code), args)
            self.assertTrue(out["error"])

    def test_broken_items_json(self):
        (self.s / "items.json").write_text("{nope")
        code, out = self.cli("patch", self.s, "I-001", "--set", "x=1")
        self.assertEqual((code, out["code"]), (1, "bad_json"))
        self.assertTrue((self.s / "items.json").is_file())

    def test_lock_timeout_exits_3(self):
        self.ok("ingest", self.s)
        path = self.file("WA-1")
        before = path.read_bytes()
        with st.Store(self.proj / ".blurt").lock():
            code, out = self.cli("patch", "WA-1", "--set", "owner=x", env={"BLURT_LOCK_TIMEOUT": "0.3"})
        self.assertEqual((code, out["code"]), (3, "locked"))
        self.assertEqual(path.read_bytes(), before)

    def test_two_processes_100_writes_each_lose_nothing(self):
        self.ok("ingest", self.s)
        uid = self.ok("path", "WA-1")["uid"]
        worker = ("import sys, io, contextlib; sys.path.insert(0, sys.argv[1]); import items\n"
                  "for n in range(100):\n"
                  "    with contextlib.redirect_stdout(io.StringIO()):\n"
                  "        items.main(['patch', sys.argv[2], '--set', f'{sys.argv[3]}{n}=%d' % n])\n")
        procs = [subprocess.Popen([sys.executable, "-c", worker, str(SCRIPTS), ref, tag], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=self.e.env(), text=True)
                 for ref, tag in (("WA-1", "a"), (uid, "b"))]
        outs = [p.communicate(timeout=300) for p in procs]
        self.assertEqual([p.returncode for p in procs], [0, 0], [e for _, e in outs])
        item = self.item("WA-1")
        for tag in "ab":
            self.assertEqual([item.get(f"{tag}{n}") for n in range(100)], list(range(100)), tag)
        self.assertEqual(item["steps"], ["Open Settings", "Look at Save"])  # untouched fields survive
        self.assertEqual(list((self.proj / ".blurt" / "items").glob(".*tmp")), [])

    def test_ensure_uids_for_a_session_not_ingested(self):
        out = self.ok("ensure-uids", self.s)
        self.assertEqual(out["assigned"], 3)
        data = json.loads((self.s / "items.json").read_text())
        self.assertEqual(data["schema"], 2)
        self.assertEqual(data["items"][0]["uid"], _common.legacy_uid(self.s.name, "I-001"))
        self.assertEqual(self.ok("ensure-uids", self.s)["assigned"], 0)
        self.ok("ingest", self.s)
        self.assertEqual(self.ok("ensure-uids", self.s)["assigned"], 0)


class Reindex(Base):
    def run_with_index(self, fake_update, args):
        fake = types.ModuleType("index")
        fake.update_paths = fake_update
        buf = io.StringIO()
        env = {**self.e.vars}
        env.pop("BLURT_NO_INDEX")
        with patch.dict(sys.modules, {"index": fake}), patch.dict(os.environ, env, clear=False), \
                contextlib.redirect_stdout(buf):
            os.environ.pop("BLURT_NO_INDEX", None)
            items.main(args)
        return buf.getvalue()

    def test_index_updated_after_writes_only_when_an_index_exists(self):
        self.ok("ingest", self.s)
        calls = []

        def update(paths):
            print("noise from index.py")  # must not break the one-line contract
            calls.append([str(p) for p in paths])
            return {"updated": 1, "ms": 1}

        self.run_with_index(update, ["patch", "WA-1", "--set", "owner=x"])
        self.assertEqual(calls, [])  # no index.db: nothing reads one
        (self.e.home / "index.db").write_bytes(b"")
        out = self.run_with_index(update, ["patch", "WA-1", "--set", "owner=y"])
        # the item, and the session whose batch got its agent_at stamp (still processing)
        self.assertEqual(calls, [[str(self.file("WA-1")), str(self.s)]])
        self.assertEqual(len(out.strip().splitlines()), 1)

        def broken(_paths):
            raise RuntimeError("database is locked")

        out = self.run_with_index(broken, ["patch", "WA-1", "--set", "owner=z"])  # the write already happened
        self.assertTrue(json.loads(out)["ok"])
        self.assertEqual(self.item("WA-1")["owner"], "z")


if __name__ == "__main__":
    import unittest
    unittest.main()
