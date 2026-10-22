"""K3 — one state per item: the transitions table (the same fixture the web and Swift implementations test against),
migration from every older shape (v0.6 items.json, early v0.7 status + work files), and the case the user reported:
items marked "won't do" leave the inbox."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_items_v2 import Base  # noqa: E402
from test_store import FIXTURES, ok, run_cli  # noqa: E402

import _common  # noqa: E402
import store as st  # noqa: E402

LIFE = json.loads((FIXTURES / "lifecycle.json").read_text(encoding="utf-8"))
UID = "01JB7ZK3Q4M8W2E5R6T9Y0ABCD"


def test_states_and_groups_match_the_fixture():
    assert list(_common.STATES) == LIFE["states"]
    g = LIFE["groups"]
    assert (list(_common.INBOX_STATES), list(_common.OPEN_STATES), list(_common.ACTIVE_STATES),
            list(_common.CLOSED_STATES)) == (g["inbox"], g["open"], g["active"], g["closed"])


def test_actions_match_the_fixture():
    assert list(_common.ACTIONS) == [a["action"] for a in LIFE["actions"]]  # also the menus' order
    for a in LIFE["actions"]:
        frm, to = _common.ACTIONS[a["action"]]
        assert (list(frm), to) == (a["from"], a["to"]), a["action"]
    for state, menu in LIFE["menus"].items():
        valid = [a for a in _common.ACTIONS if _common.action_target(a, state, "todo")]
        assert valid == menu, state
    # every "back" key (R) is unambiguous: at most one per state
    for state in LIFE["states"]:
        assert sum(1 for a in LIFE["actions"] if a["key"] == "r" and state in a["from"]) <= 1, state
    assert _common.action_target("restore", "discarded", "in_progress") == "in_progress"
    assert _common.action_target("restore", "discarded", None) == "new"
    assert _common.action_target("keep", "todo") is None


def test_who_may_move():
    agent = {tuple(m) for m in LIFE["agent_moves"]}
    app = agent | {tuple(m) for m in LIFE["app_extra_moves"]}
    for a in LIFE["states"]:
        for b in LIFE["states"]:
            assert _common.may_move(a, b, "agent") == ((a, b) in agent), (a, b)
            assert _common.may_move(a, b, "app") == ((a, b) in app), (a, b)
    # the user: exactly the actions (restore to wherever it was), plus handing off again
    for a in LIFE["actions"]:
        for f in a["from"]:
            assert _common.may_move(f, a["to"] or "todo", "user"), (a["action"], f)
    for s in ("todo", "done", "wontfix", "discarded"):  # never an agent's call
        assert not any(_common.may_move(f, s, "agent") for f in LIFE["states"] if f != s and s != "todo"
                       or f in ("new", "done", "wontfix", "discarded")), s
    assert not _common.may_move("new", "done", "user")  # not in the menu: keep it first


def test_migration_cases():
    for case in LIFE["migrate"]:
        item = {"uid": UID, **json.loads(json.dumps(case["in"]))}
        assert _common.state_of(item) == case["state"], case
        out = _common.migrate_state(item)
        assert out["state"] == case["state"] and "status" not in out and "fix" not in out, case
        assert out.get("restore_to") == case.get("restore_to"), case
        assert "state" not in (out.get("work") or {}), case
        assert _common.migrate_state(json.loads(json.dumps(out))) == out  # idempotent


class Files(Base):
    def test_an_early_v07_file_reads_as_one_state_and_is_rewritten_on_the_next_write(self):
        self.ok("ingest", self.s)
        path = self.file("WA-2")
        text = path.read_text()
        old = text.replace("state: new\n", 'status: draft\nwork: {"state": "wontfix", "to": null, "agent": "human", '
                           '"job": null, "handoff": null, "claim": null, "note": "", "commit": null, "pr": null, '
                           '"at": "2026-10-22T10:00:00+08:00", "by": "user"}\n')
        assert old != text
        path.write_text(old)
        it = self.item("WA-2")
        self.assertEqual((it["state"], it["work"]["by"]), ("wontfix", "user"))  # draft + won't do = won't do
        self.assertNotIn("status", it)
        self.assertEqual(path.read_text(), old)  # reading never writes
        self.ok("patch", "WA-2", "--set", "owner=amy")
        new = path.read_text()
        self.assertIn("\nstate: wontfix\n", new)
        self.assertNotIn("status:", new)
        self.assertNotIn('"state"', new.split("\n---\n")[0].split("work:")[1].split("\n")[0])
        # a hand-edited file with a state the app doesn't know falls back to the old fields
        path.write_text(new.replace("state: wontfix", "state: someday"))
        self.assertEqual(self.item("WA-2")["state"], "new")

    def test_the_reported_case_wont_do_leaves_the_inbox(self):
        """Five new items; the user marks two "won't do": the inbox (new + to verify) counts three, everywhere."""
        self.ok("ingest", self.s)
        self.ok("add", self.s, "--json", '{"kind":"note","title":"four"}')
        self.ok("add", self.s, "--json", '{"kind":"note","title":"five"}')
        env = {k: v for k, v in self.e.env().items() if k != "BLURT_NO_INDEX"}
        ok("index.py", "scan", env=env)
        con = sqlite3.connect(self.e.home / "index.db")
        inbox = lambda: con.execute("SELECT COUNT(*) FROM items WHERE state IN ('new', 'to_verify')").fetchone()[0]  # noqa: E731
        self.assertEqual(inbox(), 5)
        # through the page (user-ops) and through the CLI the apps call — both re-index
        ok("items.py", "user-ops", self.s, "--json", json.dumps([{"op": "state", "id": "WA-1", "action": "wontfix"}]),
           env=env)
        ok("items.py", "state", "WA-2", "--action", "wontfix", "--by", "user", env=env)
        self.assertEqual(inbox(), 3)
        self.assertEqual(len(ok("items.py", "list", "--project", "WA", "--state", "new", "--state", "to_verify",
                                env=env)["items"]), 3)
        # an agent's claim brings one back for the user to verify; their "done" takes it out
        ok("items.py", "state", "WA-3", "--state", "to_verify", "--claim", "fixed", "--agent", "claude", env=env)
        self.assertEqual(inbox(), 3)
        ok("items.py", "state", "WA-3", "--action", "done", "--by", "user", env=env)
        self.assertEqual(inbox(), 2)
        rows = dict(con.execute("SELECT state, COUNT(*) FROM items GROUP BY state").fetchall())
        self.assertEqual(rows, {"new": 2, "wontfix": 2, "done": 1})
        code, out = run_cli("items.py", "state", "WA-4", "--action", "done", "--by", "user", env=env)
        self.assertEqual((code, out["code"]), (1, "bad_transition"))  # new → done isn't a step: keep it first

    def test_a_v06_session_migrates_to_states(self):
        sessions = self.proj / ".blurt" / "sessions"
        for name in ("20261019-093000", "20261021-101500"):
            import shutil  # noqa: PLC0415
            shutil.copytree(FIXTURES / "sessions" / name, sessions / name)
        self.ok("migrate", "--all")
        every = [x for s in _common.STATES for x in ("--state", s)]
        got = {(i["source"]["local_id"], Path(i["source"]["session"]).name): i
               for i in self.ok("list", "--project", "WA", *every)["items"]}
        self.assertEqual(got[("I-004", "20261021-101500")]["state"], "wontfix")  # draft + the user's wontfix
        self.assertEqual(got[("I-001", "20261021-101500")]["state"], "to_verify")
        self.assertEqual((got[("I-005", "20261019-093000")]["state"], got[("I-005", "20261019-093000")]["restore_to"]),
                         ("discarded", "new"))  # deleted before it was kept: restores as new
        for p in st.Store(self.proj / ".blurt").files():
            text = p.read_text()
            self.assertIn("\nstate: ", text)
            self.assertNotIn("\nstatus: ", text)
