"""items.json v2 (contract C1) and the items.py v2 CLI (C2): uid, fix / fix_history, get / list / fix / user-ops /
ensure-uids, and the guarantees the desktop apps rely on (docs/design/desktop-app.md §5, §6 WP1)."""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "skills/blurt/scripts"
FIXTURES = REPO / "tests/fixtures/sessions"
V1, SHOTS, V2 = "20261019-093000", "20261020-141500-shots", "20261021-101500"
sys.path.insert(0, str(SCRIPTS))
import _common  # noqa: E402
import items  # noqa: E402
import review  # noqa: E402
from _common import FIX_STATES, legacy_uid, load_session  # noqa: E402

ULID = re.compile(r"[0-7][0-9A-HJKMNP-TV-Z]{25}")
ENV = {**os.environ, "BLURT_NO_INDEX": "1"}


def contract_legacy_uid(session_name: str, item_id: str) -> str:
    """C1, written out independently of _common."""
    return "L" + hashlib.sha1(f"{session_name}/{item_id}".encode()).hexdigest()[:25]


def cli(session, cmd, *args, stdin=None, env=None):
    p = subprocess.run([sys.executable, str(SCRIPTS / "items.py"), cmd, str(session), *map(str, args)],
                       capture_output=True, text=True, encoding="utf-8", timeout=60, input=stdin, env=env or ENV)
    lines = p.stdout.strip().splitlines()
    assert len(lines) == 1, f"expected one JSON line, got {p.stdout!r} / {p.stderr!r}"
    return p.returncode, json.loads(lines[0])


def ok(session, cmd, *args, **kw):
    code, out = cli(session, cmd, *args, **kw)
    assert code == 0 and out.get("ok") is not False, out
    return out


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def copy(self, name: str) -> Path:
        dst = self.tmp / name
        shutil.copytree(FIXTURES / name, dst)
        return dst

    def raw(self, s: Path) -> bytes:
        return (s / "items.json").read_bytes()


class Fixtures(Base):
    def test_fixtures_match_the_contract(self):
        v1 = load_session(FIXTURES / V1)
        self.assertNotIn("schema", v1)
        self.assertTrue(all("uid" not in i and "fix" not in i for i in v1["items"]))
        self.assertEqual(v1["_removed"], {"I-004": "I-003"})
        self.assertTrue(any(i["status"] == "deleted" for i in v1["items"]))
        self.assertTrue((FIXTURES / V1 / "recording.mp4").is_file())

        shots = load_session(FIXTURES / SHOTS)
        self.assertNotIn("source_video", shots)
        self.assertEqual(json.loads((FIXTURES / SHOTS / "meta.json").read_text())["mode"], "shots")
        for i in shots["items"]:
            self.assertTrue(all(f["t"] is None and (FIXTURES / SHOTS / f["path"]).is_file() for f in i["frames"]))

        v2 = load_session(FIXTURES / V2)
        self.assertEqual(next(iter(v2)), "schema")
        self.assertEqual(v2["schema"], 2)
        states = set()
        for i in v2["items"]:
            self.assertRegex(i["uid"], ULID)
            for f in [i.get("fix"), *(i.get("fix_history") or [])]:
                if f:
                    self.assertEqual(set(f), {"state", "agent", "run_id", "commit", "pr", "note", "at"})
                    self.assertIn(f["state"], FIX_STATES)
            if i.get("fix"):
                states.add(i["fix"]["state"])
            self.assertTrue(all((FIXTURES / V2 / f["path"]).is_file() for f in i["frames"]))
        self.assertEqual(states, set(FIX_STATES))
        self.assertTrue(any(not i.get("fix") for i in v2["items"]))

    def test_review_page_serves_fixtures(self):
        for name, video in ((V1, True), (SHOTS, False), (V2, True)):
            h = review.make_handler(FIXTURES / name, threading.Event())
            r = h.__new__(h)
            r.path, r.command, r.headers, r._send = "/api/items", "GET", {}, Mock()
            r.do_GET()
            code, body = r._send.call_args.args[:2]
            self.assertEqual(code, 200)
            self.assertIs(json.loads(body)["_video"], video, name)


class Uid(Base):
    def test_legacy_uid_formula(self):
        self.assertEqual(legacy_uid(V1, "I-001"), contract_legacy_uid(V1, "I-001"))
        self.assertEqual(len(legacy_uid(V1, "I-001")), 26)
        self.assertTrue(legacy_uid(V1, "I-001").startswith("L"))
        u = _common.new_ulid()
        self.assertRegex(u, ULID)
        self.assertNotIn("L", u)  # never collides with a legacy uid
        self.assertLess(_common.new_ulid(1.0), _common.new_ulid(2.0))  # sorts by time

    def test_get_and_list_compute_uids_without_writing(self):
        s = self.copy(V1)
        before = self.raw(s)
        out = ok(s, "get", "I-001")
        self.assertEqual(out["item"]["uid"], contract_legacy_uid(V1, "I-001"))
        self.assertEqual(list(out["item"])[:2], ["id", "uid"])
        self.assertEqual(out["session"], str(s.resolve()))
        self.assertEqual(ok(s, "get", contract_legacy_uid(V1, "I-002"))["item"]["id"], "I-002")
        listed = ok(s, "list")["items"]
        self.assertEqual([i["id"] for i in listed], ["I-001", "I-002", "I-003"])  # deleted left out
        self.assertEqual([i["uid"] for i in listed], [contract_legacy_uid(V1, x) for x in ("I-001", "I-002", "I-003")])
        self.assertEqual(self.raw(s), before)

    def test_ensure_uids_writes_the_legacy_value_once(self):
        s = self.copy(V1)
        self.assertEqual(ok(s, "ensure-uids")["assigned"], 4)
        data = load_session(s)
        self.assertEqual(next(iter(data)), "schema")
        self.assertEqual(data["schema"], 2)
        self.assertEqual(data["agent_at"], load_session(FIXTURES / V1)["agent_at"])  # not the agent working
        for i in data["items"]:
            self.assertEqual(list(i)[:2], ["id", "uid"])
            self.assertEqual(i["uid"], contract_legacy_uid(V1, i["id"]))
        before = self.raw(s)
        self.assertEqual(ok(s, "ensure-uids")["assigned"], 0)
        self.assertEqual(self.raw(s), before)  # idempotent, no rewrite
        v2 = self.copy(V2)
        before = self.raw(v2)
        self.assertEqual(ok(v2, "ensure-uids")["assigned"], 0)
        self.assertEqual(self.raw(v2), before)

    def test_every_agent_write_persists_uids_and_schema(self):
        s = self.copy(V1)
        ok(s, "patch", "I-002", "--set", "next=ship it")
        data = load_session(s)
        self.assertEqual(data["schema"], 2)
        self.assertEqual([i["uid"] for i in data["items"]], [contract_legacy_uid(V1, i["id"]) for i in data["items"]])

    def test_add_assigns_a_ulid(self):
        s = self.copy(V2)
        out = ok(s, "add", "--json", '{"kind":"idea","title":"新的想法"}', "--after", "01KAQ6N2W8C3D4E5F6G7H8J9KM")
        self.assertEqual(out["id"], "I-006")
        self.assertRegex(out["uid"], ULID)
        data = load_session(s)
        self.assertEqual([i["id"] for i in data["items"]][:2], ["I-001", "I-006"])  # --after accepts a uid
        self.assertEqual(ok(s, "get", out["uid"])["item"]["title"], "新的想法")
        code, err = cli(s, "add", "--json", '{"kind":"idea","title":"x","uid":"01KAQ6N2W8C3D4E5F6G7H8J9KM"}')
        self.assertEqual((code, err["ok"]), (1, False))

    def test_id_or_uid_everywhere(self):
        s = self.copy(V1)
        u1, u4 = contract_legacy_uid(V1, "I-001"), contract_legacy_uid(V1, "I-004")
        out = ok(s, "patch", u1, "--set", "owner=amy", "--set", "title=nope")
        self.assertEqual((out["id"], out["written"], out["kept_user"]), ("I-001", ["owner"], ["title"]))
        self.assertEqual(ok(s, "set-frames", u1, "frames/I-001-1.jpg@1.5")["id"], "I-001")
        self.assertEqual(ok(s, "fix", u1, "--state", "fixing", "--agent", "claude")["id"], "I-001")
        # the user merged I-004 away: its legacy uid still resolves, and the write is skipped
        self.assertEqual(ok(s, "patch", u4, "--set", "x=1")["skipped"], "merged into I-003")
        self.assertEqual(ok(s, "fix", u4, "--state", "fixed")["skipped"], "merged into I-003")
        code, out = cli(s, "get", u4)
        self.assertEqual(code, 1)
        self.assertIn("merged into I-003", out["error"])
        code, out = cli(s, "get", "L" + "0" * 25)
        self.assertEqual((code, out["ok"]), (1, False))


class Fix(Base):
    def test_state_changes_go_to_history(self):
        s = self.copy(V1)
        a = ok(s, "fix", "I-001", "--state", "fixing", "--agent", "claude", "--run-id", "r-1")
        self.assertEqual(a["uid"], contract_legacy_uid(V1, "I-001"))
        self.assertEqual({k: v for k, v in a["fix"].items() if k != "at"},
                         {"state": "fixing", "agent": "claude", "run_id": "r-1", "commit": None, "pr": None,
                          "note": ""})
        # same run finishes it: agent and run_id carry over from "fixing"
        b = ok(s, "fix", "I-001", "--state", "fixed", "--commit", "abc1234", "--note", "null check")["fix"]
        self.assertEqual((b["agent"], b["run_id"], b["commit"], b["note"]), ("claude", "r-1", "abc1234", "null check"))
        # same state again: updates the current fix, no history entry
        c = ok(s, "fix", "I-001", "--state", "fixed", "--pr", "https://example.test/pr/1")["fix"]
        self.assertEqual((c["commit"], c["pr"], c["note"]), ("abc1234", "https://example.test/pr/1", "null check"))
        d = ok(s, "fix", "I-001", "--state", "reopened", "--note", "still broken")["fix"]
        self.assertEqual((d["agent"], d["run_id"], d["commit"]), ("human", None, None))  # no carry from "fixed"
        item = ok(s, "get", "I-001")["item"]
        self.assertEqual(item["fix"], d)
        self.assertEqual([f["state"] for f in item["fix_history"]], ["fixing", "fixed"])
        self.assertEqual(item["fix_history"][1]["pr"], "https://example.test/pr/1")
        self.assertEqual(item["status"], "confirmed")  # review status is separate from fix.state
        self.assertIsInstance(item["fix"]["at"], float)

    def test_env_defaults_from_the_app(self):
        s = self.copy(V2)
        out = ok(s, "fix", "I-003", "--state", "fixing", env={**ENV, "BLURT_AGENT": "kimi", "BLURT_RUN_ID": "r-9"})
        self.assertEqual((out["fix"]["agent"], out["fix"]["run_id"]), ("kimi", "r-9"))
        out = ok(s, "fix", "I-003", "--state", "fixed", "--agent", "codex",
                 env={**ENV, "BLURT_AGENT": "kimi", "BLURT_RUN_ID": "r-9"})
        self.assertEqual((out["fix"]["agent"], out["fix"]["run_id"]), ("codex", "r-9"))  # the flag wins

    def test_fix_fields_are_protected_from_patch(self):
        s = self.copy(V2)
        for field in ("fix", "fix_history", "uid", "schema"):
            code, out = cli(s, "patch", "I-001" if field != "schema" else ".", "--set", f"{field}=1")
            self.assertEqual((code, out["ok"]), (1, False), field)
        code, out = cli(s, "fix", "I-001", "--state", "done")
        self.assertEqual((code, out["ok"]), (1, False))

    def test_list_filters(self):
        s = self.copy(V2)
        ids = lambda *a: [i["id"] for i in ok(s, "list", *a)["items"]]  # noqa: E731
        self.assertEqual(ids(), ["I-001", "I-002", "I-003", "I-004", "I-005"])
        self.assertEqual(ids("--kind", "issue"), ["I-001", "I-002", "I-005"])
        self.assertEqual(ids("--kind", "idea", "--kind", "task"), ["I-003", "I-004"])
        self.assertEqual(ids("--status", "draft"), ["I-003", "I-004", "I-005"])
        self.assertEqual(ids("--fix-state", "fixed"), ["I-001"])
        self.assertEqual(ids("--fix-state", "none"), ["I-003"])
        self.assertEqual(ids("--fix-state", "fixing", "--fix-state", "reopened"), ["I-002", "I-005"])
        v1 = self.copy(V1)
        self.assertEqual([i["id"] for i in ok(v1, "list", "--status", "deleted")["items"]], ["I-005"])


class UserOps(Base):
    OPS = [
        {"op": "set", "id": "I-001", "set": {"title": "登录按钮没反应（Safari）", "status": "confirmed", "_touched": True}},
        {"op": "set", "id": "I-002", "set": {"answer": "下周做"}, "unset": ["next"]},
        {"op": "set", "id": "I-003", "set": {"merged_from": ["I-004", "I-002"]}},
        {"op": "remove", "id": "I-002", "into": "I-003"},
        {"op": "add", "item": {"id": "I-004", "kind": "issue", "title": "价格表被截断"}, "after": "I-003"},
        {"op": "set", "id": "I-999", "set": {"title": "gone"}},  # unknown ids are ignored, as on the page
    ]

    def via_review(self, s: Path, ops, confirm=False):
        h = review.make_handler(s, threading.Event())
        r = h.__new__(h)
        body = json.dumps({"ops": ops}).encode()
        r.path, r.command = "/api/confirm" if confirm else "/api/items", "POST"
        r.headers, r.rfile, r._send = {"Content-Length": str(len(body))}, io.BytesIO(body), Mock()
        r.do_POST()
        code, _body, _ctype, extra = r._send.call_args.args
        self.assertEqual(code, 200)
        return extra["ETag"]

    def via_items(self, s: Path, ops, confirm=False):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), patch.dict(os.environ, {"BLURT_NO_INDEX": "1"}):
            items.main(["user-ops", str(s), "--json", json.dumps(ops), *(["--confirm"] if confirm else [])])
        return json.loads(buf.getvalue())

    def test_same_bytes_as_review_post(self):
        for fixture in (V1, SHOTS, V2):
            for confirm in (False, True):
                a, b = self.copy(fixture), self.tmp / f"{fixture}-b"
                shutil.copytree(FIXTURES / fixture, b)
                ops = [op for op in self.OPS if fixture != SHOTS or op.get("id") in ("I-001", "I-002")]
                with patch("time.time", return_value=1792570000.04):
                    tag = self.via_review(a, ops, confirm)
                    out = self.via_items(b, ops, confirm)
                self.assertEqual(self.raw(a), self.raw(b), (fixture, confirm))
                self.assertEqual(out, {"ok": True, "etag": tag})  # same ETag the browser host sees
                shutil.rmtree(a), shutil.rmtree(b)

    def test_cli_stdin_and_semantics(self):
        s = self.copy(V1)
        out = ok(s, "user-ops", "--stdin", stdin=json.dumps(self.OPS))
        self.assertRegex(out["etag"], r'^"[0-9a-f]{16}"$')
        self.assertEqual(out["etag"], review.etag(self.raw(s)))
        data = load_session(s)
        self.assertNotIn("schema", data)  # user-ops writes exactly what the page would: no uid, schema, agent_at
        self.assertEqual(data["agent_at"], load_session(FIXTURES / V1)["agent_at"])
        self.assertEqual([i["id"] for i in data["items"]], ["I-001", "I-003", "I-004", "I-005"])
        self.assertEqual(data["_removed"], {"I-002": "I-003"})  # I-004 came back
        i1 = data["items"][0]
        self.assertEqual(set(i1["_user"]), {"title", "severity", "status"})  # _touched is not a user field
        # and the agent now keeps its hands off what the user set
        self.assertEqual(ok(s, "patch", "I-001", "--set", "title=agent")["kept_user"], ["title"])
        ok(s, "user-ops", "--confirm")
        self.assertTrue(load_session(s)["reviewed"])
        # the page's POST body works too
        ok(s, "user-ops", "--json", json.dumps({"ops": [{"op": "set", "id": "I-001", "set": {"owner": "bo"}}]}))
        self.assertEqual(load_session(s)["items"][0]["owner"], "bo")

    def test_bad_ops_change_nothing(self):
        s = self.copy(V1)
        before = self.raw(s)
        for bad in ("not json", "{}", '[{"op":"merge","id":"I-001"}]', '[{"op":"set"}]', '[{"op":"add","item":{}}]',
                    '[{"op":"set","id":"I-001","set":[1]}]', '[1]'):
            code, out = cli(s, "user-ops", "--json", bad)
            self.assertEqual((code, out["ok"]), (1, False), bad)
        code, out = cli(s, "user-ops")
        self.assertEqual(code, 1)
        self.assertEqual(self.raw(s), before)

    def test_empty_titles_are_refused_everywhere(self):
        s = self.copy(V1)
        before = self.raw(s)
        for title in ("", "   ", "\n\t", "\u3000", None):
            bad = [{"op": "set", "id": "I-002", "set": {"answer": "x"}},
                   {"op": "set", "id": "I-001", "set": {"title": title}}]
            code, out = cli(s, "user-ops", "--json", json.dumps(bad))
            self.assertEqual((code, out["ok"]), (1, False), title)
            self.assertIn("title can't be empty", out["error"])
            self.assertIn("I-001", out["error"])
            # review.py: 400 with the same message, nothing written (not even the valid op before it)
            h = review.make_handler(s, threading.Event())
            r = h.__new__(h)
            body = json.dumps({"ops": bad}).encode()
            r.path, r.command = "/api/items", "POST"
            r.headers, r.rfile, r._send = {"Content-Length": str(len(body))}, io.BytesIO(body), Mock()
            r.do_POST()
            code, payload, _ctype = r._send.call_args.args[:3]
            self.assertEqual(code, 400)
            self.assertIn("title can't be empty", json.loads(payload)["error"])
        code, out = cli(s, "user-ops", "--json", json.dumps([{"op": "set", "id": "I-001", "unset": ["title"]}]))
        self.assertEqual(code, 1)
        self.assertIn("title can't be removed", out["error"])
        code, out = cli(s, "user-ops", "--json", json.dumps([{"op": "add", "item": {"id": "I-009", "title": " "}}]))
        self.assertEqual(code, 1)
        self.assertEqual(self.raw(s), before)
        # the agent's patch too
        for args in (["--set", "title="], ["--set", "title=  "], ["--unset", "title"]):
            code, out = cli(s, "patch", "I-001", *args)
            self.assertEqual((code, out["ok"]), (1, False), args)
            self.assertIn("title", out["error"])
        self.assertEqual(self.raw(s), before)
        ok(s, "patch", "I-001", "--set", "title=  still fine ")  # a real title (spaces around it) is fine

    def test_apply_user_ops_is_shared(self):
        self.assertIs(review.apply_user_ops, _common.apply_user_ops)
        self.assertIs(items.apply_user_ops, _common.apply_user_ops)


class Cli(Base):
    def test_errors_are_one_json_line(self):
        s = self.copy(V1)
        for args in (("patch", "I-001", "--set", "novalue"), ("patch", "I-077", "--set", "a=1"), ("get",),
                     ("list", "--status", "maybe"), ("set-frames", "I-001", "frames/missing.jpg")):
            code, out = cli(s, *args)
            self.assertEqual((code, out["ok"]), (1, False), args)
            self.assertTrue(out["error"])
        code, out = cli(self.tmp / "nowhere", "list")
        self.assertEqual((code, out["ok"]), (1, False))

    def test_lock_timeout_exits_3(self):
        s = self.copy(V1)
        before = self.raw(s)
        with _common.items_lock(s):
            code, out = cli(s, "patch", "I-001", "--set", "owner=x", env={**ENV, "BLURT_LOCK_TIMEOUT": "0.3"})
        self.assertEqual((code, out["ok"]), (3, False))
        self.assertEqual(self.raw(s), before)

    def test_two_processes_100_patches_each_lose_nothing(self):
        s = self.copy(V2)
        worker = ("import sys; sys.path.insert(0, sys.argv[1]); import items\n"
                  "for n in range(100):\n"
                  "    items.main(['patch', sys.argv[2], sys.argv[3], '--set', f'{sys.argv[4]}{n}=%d' % n])\n")
        procs = [subprocess.Popen([sys.executable, "-c", worker, str(SCRIPTS), str(s), iid, tag],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV, text=True)
                 for iid, tag in (("I-001", "a"), ("01KAQ6N2W8C3D4E5F6G7H8J9KM", "b"))]
        outs = [p.communicate(timeout=120) for p in procs]
        self.assertEqual([p.returncode for p in procs], [0, 0], [e for _, e in outs])
        self.assertEqual([len(o.splitlines()) for o, _ in outs], [100, 100])
        item = next(i for i in load_session(s)["items"] if i["id"] == "I-001")
        for tag in "ab":
            self.assertEqual([item.get(f"{tag}{n}") for n in range(100)], list(range(100)), tag)
        self.assertEqual(item["fix"]["state"], "fixed")  # untouched fields survive
        self.assertEqual(list(s.glob("*.tmp")), [])


class Reindex(Base):
    def run_with_index(self, fake_update, home: Path, s: Path):
        fake = types.ModuleType("index")
        fake.update_sessions = fake_update
        buf = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "BLURT_NO_INDEX"}
        with patch.dict(sys.modules, {"index": fake}), patch.dict(os.environ, {**env, "BLURT_HOME": str(home)},
                                                                   clear=True), contextlib.redirect_stdout(buf):
            items.main(["patch", str(s), "I-001", "--set", "owner=x"])
        return buf.getvalue()

    def test_index_updated_after_writes_only_when_an_index_exists(self):
        s = self.copy(V2)
        home = self.tmp / "home"
        home.mkdir()
        calls = []

        def update(dirs):
            print("noise from index.py")  # must not break the one-line contract
            calls.append(list(dirs))
            return {"updated": 1, "ms": 1}

        self.run_with_index(update, home, s)
        self.assertEqual(calls, [])  # no index.db: nothing reads one
        (home / "index.db").write_bytes(b"")
        out = self.run_with_index(update, home, s)
        self.assertEqual(calls, [[s.resolve()]])
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertTrue(json.loads(out)["ok"])

        def broken(_dirs):
            raise RuntimeError("database is locked")

        out = self.run_with_index(broken, home, s)  # failures are ignored: the write already happened
        self.assertTrue(json.loads(out)["ok"])
        self.assertEqual(next(i for i in load_session(s)["items"] if i["id"] == "I-001")["owner"], "x")


if __name__ == "__main__":
    unittest.main()
