"""v1 / v2 sessions → Markdown stores (contract K1 "migrate", K3 mapping): every item of tests/fixtures/sessions/*
lands in the right store with its uid, its review status, its v2 fix as work, the user's edits and merges; ids are
handed out in session order; it is idempotent; the index follows."""
from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_store import FIXTURES, SHOTS, V1, V2, TmpCase, copy_session, make_repo, ok, run_cli  # noqa: E402

import _common  # noqa: E402
import store as st  # noqa: E402
from _common import legacy_uid  # noqa: E402

# K3 one state, from the fixtures' status + v2 fix: v1 = 3 kept + 1 deleted; shots = 2 drafts; v2 = fixed (claim),
# fixing, a draft, a draft the user said won't do (the reported case: it must leave the inbox), a reopened draft
STATE_COUNTS = {"todo": 3, "discarded": 1, "new": 4, "to_verify": 1, "in_progress": 1, "wontfix": 1}


def v2(name: str) -> dict:
    return json.loads((FIXTURES / "sessions" / name / "items.json").read_text())


class Migrate(TmpCase):
    def setUp(self):
        super().setUp()
        self.repo = make_repo(self.tmp / "bug-agent")
        sessions = self.repo / ".blurt" / "sessions"
        self.v1, self.v2 = copy_session(V1, sessions), copy_session(V2, sessions)
        self.shots = copy_session(SHOTS, self.e.ws / "recordings")
        # v0.6 kept bound repos in config.json record.workspaces
        cfg = json.loads((self.e.home / "config.json").read_text())
        cfg["record"].update(workspaces=[str(self.repo)], workspace=str(self.repo))
        (self.e.home / "config.json").write_text(json.dumps(cfg))

    def items_of(self, store_root: Path) -> dict[str, dict]:
        return {it["uid"]: it for it in (st.read_item(p) for p in st.Store(store_root).files())}

    def test_dry_run_writes_nothing(self):
        out = ok("items.py", "migrate", "--all", "--dry-run", env=self.e.env())
        self.assertEqual((out["sessions"], out["items"], out["dry_run"]), (3, 11, True))
        self.assertTrue((self.v1 / "items.json").is_file())
        self.assertFalse((self.v1 / "batch.json").exists())
        self.assertFalse((self.repo / ".blurt" / "items").exists())

    def test_everything_carries_over(self):
        out = ok("items.py", "migrate", "--all", env=self.e.env())
        self.assertEqual((out["sessions"], out["items"], out["skipped"]), (3, 11, []))
        # the bound repo became a project, and the current one
        proj = ok("projects.py", "current", env=self.e.env())
        self.assertEqual(proj["project"]["path"], str(self.repo))
        self.assertEqual(proj["project"]["key"], "BA")
        repo_items = self.items_of(self.repo / ".blurt")
        inbox_items = self.items_of(self.e.ws / "inbox")
        # counts: every item except the one the user merged away (V1 I-004)
        self.assertEqual(len(repo_items), 4 + 5)
        self.assertEqual(len(inbox_items), 2)
        # uids: v2 ULIDs kept, v1 items get their legacy uid
        want = {legacy_uid(V1, i["id"]) for i in v2(V1)["items"] if i["id"] != "I-004"} | \
            {i["uid"] for i in v2(V2)["items"]}
        self.assertEqual(set(repo_items), want)
        self.assertEqual(set(inbox_items), {legacy_uid(SHOTS, "I-001"), legacy_uid(SHOTS, "I-002")})
        # ids in session order (V1 before V2), per store
        by_local = {(Path(i["source"]["session"]).name, i["source"]["local_id"]): i for i in repo_items.values()}
        self.assertEqual([by_local[(V1, x)]["id"] for x in ("I-001", "I-002", "I-003", "I-005")],
                         ["BA-1", "BA-2", "BA-3", "BA-4"])
        self.assertEqual([by_local[(V2, f"I-00{n}")]["id"] for n in range(1, 6)], [f"BA-{n}" for n in range(5, 10)])
        self.assertEqual(sorted(i["id"] for i in inbox_items.values()), ["IN-1", "IN-2"])
        # fix → state + work (K3 mapping), history too
        s = {x: by_local[(V2, x)]["state"] for x in ("I-001", "I-002", "I-003", "I-004", "I-005")}
        w = {x: by_local[(V2, x)].get("work") for x in ("I-001", "I-002", "I-003", "I-004", "I-005")}
        self.assertEqual((s["I-001"], w["I-001"]["claim"], w["I-001"]["commit"]), ("to_verify", "fixed", "a1c3e5f"))
        self.assertEqual((s["I-002"], w["I-002"]["agent"], w["I-002"]["job"]),
                         ("in_progress", "codex", "r-20261021-110000-cd34"))
        self.assertIsNone(w["I-003"])  # never handed off: no work key
        self.assertEqual((s["I-004"], w["I-004"]["claim"]), ("wontfix", None))  # a human's wontfix
        self.assertEqual(w["I-005"]["by"], "user")  # reopened
        self.assertEqual(s["I-005"], "new")  # a reopened draft: still new
        self.assertEqual([h["state"] for h in by_local[(V2, "I-005")]["work_history"]], ["in_progress", "to_verify"])
        self.assertEqual(by_local[(V2, "I-001")]["work_history"][0]["state"], "in_progress")
        for wk in [x for x in w.values() if x]:
            self.assertEqual(list(wk), list(_common.WORK_KEYS))
            self.assertRegex(wk["at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")
        for wk in by_local[(V2, "I-005")]["work_history"]:
            self.assertEqual(list(wk), ["state", *_common.WORK_KEYS])
        self.assertTrue(all("status" not in i for i in repo_items.values()))
        self.assertTrue(all("fix" not in i and "fix_history" not in i for i in repo_items.values()))
        # review status, the user's edits, merges
        old1 = {i["id"]: i for i in v2(V1)["items"]}
        for x in ("I-001", "I-002", "I-003", "I-005"):
            it = by_local[(V1, x)]
            self.assertEqual(it["state"], _common.state_of(old1[x]))  # draft → new, confirmed → todo, …
            self.assertEqual(it.get("_user"), old1[x].get("_user"))
            self.assertEqual(it["title"], old1[x]["title"])
            self.assertEqual(it["project_by"], "migrate")
            self.assertEqual(it["project"], proj["project"]["id"])
        self.assertEqual(by_local[(V1, "I-003")]["merged_from"], [legacy_uid(V1, "I-004")])
        self.assertEqual(by_local[(V1, "I-001")]["steps"], old1["I-001"]["steps"])
        self.assertEqual(by_local[(V1, "I-001")]["source"]["url"], "https://example.test/login")
        b1 = json.loads((self.v1 / "batch.json").read_text())
        self.assertEqual(b1["removed"], {legacy_uid(V1, "I-004"): legacy_uid(V1, "I-003")})
        self.assertEqual(b1["items"], [legacy_uid(V1, x) for x in ("I-001", "I-002", "I-003", "I-005")])
        self.assertEqual(b1["local"]["I-004"], legacy_uid(V1, "I-004"))
        self.assertEqual((b1["title"], b1["reviewed"], b1["source_video"]), (v2(V1)["title"], True, "recording.mp4"))
        # sources
        for it in repo_items.values():
            self.assertEqual(it["source"]["type"], "recording")
            self.assertEqual(it["source"]["by"], "Tester")  # meta.json author
            self.assertTrue(os.path.isabs(it["source"]["session"]))
        for it in inbox_items.values():
            self.assertEqual((it["source"]["type"], it["project"]), ("snap", "inbox"))
            self.assertEqual(it["source"]["session"], str(self.shots))  # v0.6 recordings stay where they are
        self.assertEqual(sorted(i["source"]["shot"] for i in inbox_items.values()), [1, 2])
        # frames and clips copied into assets/<uid>/ (hard links on one volume), relative to the store
        a = by_local[(V2, "I-001")]
        self.assertEqual([f["path"] for f in a["frames"]], [f"assets/{a['uid']}/1.jpg", f"assets/{a['uid']}/2.jpg"])
        self.assertEqual(a["clip"], f"assets/{a['uid']}/clip.mp4")
        self.assertEqual(a["frames"][1]["caption"], "Network 面板：POST /avatar 500")
        src = self.v2 / "frames" / "I-001-2.jpg"
        self.assertEqual((self.repo / ".blurt" / a["frames"][1]["path"]).stat().st_ino, src.stat().st_ino)
        marked = next(i for i in inbox_items.values() if i["source"]["shot"] == 2)
        self.assertEqual(marked["frames"][0]["path"], f"assets/{marked['uid']}/1.marked.png")
        for it in [*repo_items.values(), *inbox_items.values()]:
            for f in it.get("frames") or []:
                self.assertTrue((Path(st.Store(self.repo / ".blurt").root if it["project"] != "inbox" else
                                      self.e.ws / "inbox") / f["path"]).is_file(), f)
        # items.json kept for reference, never read again
        self.assertTrue((self.v1 / "items.v2.json").is_file())
        self.assertFalse((self.v1 / "items.json").exists())
        # the Markdown body is in the language of the session
        md = (self.repo / ".blurt" / "items").glob("BA-1-*.md").__next__().read_text()
        self.assertIn("## 复现步骤\n\n1. 打开 /login", md)

    def test_idempotent(self):
        ok("items.py", "migrate", "--all", env=self.e.env())
        before = {p: p.read_bytes() for p in (self.repo / ".blurt" / "items").iterdir()}
        out = ok("items.py", "migrate", "--all", env=self.e.env())
        self.assertEqual((out["sessions"], out["items"]), (0, 0))  # nothing left with an items.json
        out = ok("items.py", "migrate", str(self.v1), env=self.e.env())
        self.assertEqual(out["skipped"], [{"dir": str(self.v1), "why": "no items.json"}])
        self.assertEqual({p: p.read_bytes() for p in (self.repo / ".blurt" / "items").iterdir()}, before)
        self.assertEqual(json.loads((self.repo / ".blurt" / "store.json").read_text())["next"], 10)
        ok("projects.py", "migrate", env=self.e.env())  # the registry too
        self.assertEqual(len(ok("projects.py", "list", env=self.e.env())["projects"]), 1)

    def test_root_and_single_sessions_and_bad_files(self):
        broken = self.repo / ".blurt" / "sessions" / "20261022-000000"
        broken.mkdir()
        (broken / "items.json").write_text("{not json")
        out = ok("items.py", "migrate", "--root", self.repo, env=self.e.env())
        self.assertEqual(out["sessions"], 2)
        self.assertEqual(out["skipped"][0]["dir"], str(broken))
        self.assertIn("items.json", out["skipped"][0]["why"])
        # the folder was not registered: migrating its store registered it (store.json knows its key)
        self.assertEqual(json.loads((self.repo / ".blurt" / "store.json").read_text())["key"], "BA")
        out = ok("items.py", "migrate", self.shots, env=self.e.env())
        self.assertEqual((out["sessions"], out["items"]), (1, 2))

    def test_any_items_py_command_migrates_a_v2_session_first(self):
        """An agent following the v0.6 SKILL.md (items.py patch SESSION I-003 …) keeps working."""
        out = ok("items.py", "patch", self.v2, "I-003", "--set", "owner=amy", env=self.e.env())
        self.assertEqual(out["id"], "BA-3")  # this session migrated on its own: its ids start at 1
        self.assertTrue((self.v2 / "batch.json").is_file())
        self.assertTrue((self.v2 / "items.ingested.json").is_file())
        self.assertEqual(ok("items.py", "get", self.v2, "I-003", env=self.e.env())["item"]["owner"], "amy")
        self.assertEqual(ok("items.py", "get", "01KAQ6N2W8C3D4E5F6G7H8J9KP", env=self.e.env())["item"]["id"], "BA-3")

    def test_index_follows(self):
        env = self.e.env(BLURT_NO_INDEX="")
        env.pop("BLURT_NO_INDEX", None)
        p = run_cli("index.py", "scan", "--root", self.repo, env=env)[1]
        self.assertEqual((p["sessions"], p["items"]), (3, 11))
        con = sqlite3.connect(self.e.home / "index.db")
        self.assertEqual(con.execute("SELECT COUNT(*) FROM sessions WHERE legacy = 1").fetchone()[0], 3)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM items WHERE path LIKE '%#%'").fetchone()[0], 11)
        legacy_uids = {r[0] for r in con.execute("SELECT uid FROM items")}
        ok("items.py", "migrate", "--all", env=env)  # items.py re-indexes what it wrote
        self.assertEqual(con.execute("SELECT COUNT(*) FROM sessions WHERE legacy = 1").fetchone()[0], 0)
        self.assertEqual(con.execute("SELECT COUNT(*) FROM items WHERE path LIKE '%#%'").fetchone()[0], 0)
        self.assertEqual({r[0] for r in con.execute("SELECT uid FROM items")}, legacy_uids)  # same identities
        self.assertEqual(con.execute("SELECT item_id FROM items WHERE uid = ?", ("01KAQ6N2W8C3D4E5F6G7H8J9KM",))
                         .fetchone()[0], "BA-5")
        rows = dict(con.execute("SELECT state, COUNT(*) FROM items GROUP BY state").fetchall())
        self.assertEqual(rows, STATE_COUNTS)
        counts = dict(con.execute("SELECT dir, item_count FROM sessions").fetchall())
        self.assertEqual(counts, {str(self.v1): 3, str(self.v2): 5, str(self.shots): 2})


class DanglingWork(TmpCase):
    """Items that point at a session that no longer exists (a v0.6 run id, a removed job) lose that pointer once, so
    nothing offers to open it; they keep their state."""

    def test_migrate_all_forgets_sessions_that_are_gone(self):
        env = self.e.env(BLURT_NO_INDEX="")
        env.pop("BLURT_NO_INDEX", None)
        (self.e.home / "jobs").mkdir()
        (self.e.home / "jobs" / "j-20261024-100000-live.json").write_text(json.dumps({"id": "j-20261024-100000-live"}))
        made = {}
        for name, state, job in (("legacy", "in_progress", "r-20261021-212222-xw1r"), ("gone", "to_verify", "j-20260901-1-gone"),
                                 ("live", "in_progress", "j-20261024-100000-live"), ("done", "done", "j-20260901-2-gone")):
            it = ok("items.py", "add", "--project", "inbox", "--json", json.dumps({"kind": "issue", "title": name}), env=env)
            ok("items.py", "state", it["uid"], "--state", "in_progress", "--job", job, "--by", "agent", env=env)
            if state != "in_progress":
                ok("items.py", "state", it["uid"], "--state", state, "--by", "user" if state == "done" else "agent",
                   *(["--claim", "fixed"] if state == "to_verify" else []), env=env)
            made[name] = it["uid"]
        ok("index.py", "scan", env=env)
        dry = ok("items.py", "migrate", "--all", "--dry-run", env=env)
        self.assertEqual(len(dry["repaired"]), 2)
        out = ok("items.py", "migrate", "--all", env=env)
        self.assertEqual(len(out["repaired"]), 2)

        def work(name):
            it = ok("items.py", "get", made[name], env=env)["item"]
            return it["state"], it["work"]["job"], it["work"]["to"]
        self.assertEqual(work("legacy"), ("in_progress", None, "session"))  # still in progress: the user decides
        self.assertEqual(work("gone"), ("to_verify", None, "session"))
        self.assertEqual(work("live"), ("in_progress", "j-20261024-100000-live", None))  # its job is there
        self.assertEqual(work("done")[1], "j-20260901-2-gone")  # finished: nothing offers it any more
        self.assertEqual(ok("items.py", "migrate", "--all", env=env)["repaired"], [])  # once


if __name__ == "__main__":
    import unittest
    unittest.main()
