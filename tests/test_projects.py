"""Projects (contract K2): projects.json and projects.py — keys and slugs, open / remove / set / use / resolve,
the v0.6 migration, and assignment: the user's current project or none (Unassigned), an organizing run's project
only ever a suggestion, the candidates its prompt lists — nothing moves an item but the user."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_store import TmpCase, make_repo, ok, run_cli  # noqa: E402

import projects  # noqa: E402
import store as st  # noqa: E402


class Keys(TmpCase):
    def test_default_keys(self):
        k = projects.default_key
        self.assertEqual(k("bug-agent", set()), "BA")
        self.assertEqual(k("airank", set()), "AIR")
        self.assertEqual(k("my_cool.app", set()), "MCA")
        self.assertEqual(k("BlurtDesktop", set()), "BD")
        self.assertEqual(k("HTTPServer", set()), "HS")
        self.assertEqual(k("a-b-c-d", set()), "ABC")
        self.assertEqual(k("口喷鸡", set()), "P01")
        self.assertEqual(k("口喷鸡", {"P01"}), "P02")
        self.assertEqual(k("bug-agent", {"BA"}), "BA2")
        self.assertEqual(k("bug-agent", {"BA", "BA2"}), "BA3")
        self.assertEqual(k("in", set()), "IN2")  # IN is the inbox's
        self.assertEqual(k("3d-viewer", set()), "DVI")  # must start with a letter
        for name in ("bug-agent", "airank", "口喷鸡", "x", "2048", "über-app"):
            self.assertRegex(k(name, set()), r"^[A-Z][A-Z0-9]{1,4}$", name)
        self.assertEqual(projects.default_slug("Bug Agent!", "abc123def456", set()), "bug-agent")
        self.assertEqual(projects.default_slug("口喷鸡", "abc123def456", set()), "p-abc123")
        self.assertEqual(projects.default_slug("bug-agent", "x", {"bug-agent"}), "bug-agent-2")


class Registry(TmpCase):
    def test_open_list_use_resolve_set_remove(self):
        a = make_repo(self.tmp / "bug-agent")
        b = self.tmp / "notes"
        b.mkdir()
        out = ok("projects.py", "add", a, "--description", "the blurt repo", env=self.e.env())
        pa = out["project"]
        self.assertTrue(out["created"])
        self.assertEqual((pa["key"], pa["slug"], pa["name"], pa["git"], pa["exists"]), ("BA", "bug-agent", "bug-agent",
                                                                                         True, True))
        self.assertEqual(pa["store"], str(a / ".blurt"))
        self.assertEqual(pa["id"], projects.project_id(a))
        self.assertTrue((a / ".blurt" / "store.json").is_file())
        self.assertFalse(ok("projects.py", "add", a, env=self.e.env())["created"])
        pb = ok("projects.py", "add", b, "--name", "Daily notes", "--key", "DN", env=self.e.env())["project"]
        self.assertEqual((pb["key"], pb["git"]), ("DN", False))
        for bad, code in ((self.tmp / "nope", "not_found"), (a / "README.md", "not_a_folder")):
            c, o = run_cli("projects.py", "add", bad, env=self.e.env())
            self.assertEqual((c, o["code"]), (1, code))
        c, o = run_cli("projects.py", "add", self.tmp / "x", "--key", "DN", env=self.e.env())
        self.assertEqual(o["code"], "not_found")
        (self.tmp / "x").mkdir()
        c, o = run_cli("projects.py", "add", self.tmp / "x", "--key", "DN", env=self.e.env())
        self.assertEqual((c, o["code"]), (1, "key_taken"))
        # the registry file: what the apps read
        reg = json.loads((self.e.home / "projects.json").read_text())
        self.assertEqual((reg["schema"], reg["current"]), (1, None))
        self.assertNotIn("route_threshold", reg)
        self.assertEqual(set(reg["projects"][0]), {"id", "path", "name", "key", "slug", "description", "default_agent",
                                                   "worktree", "worktree_root", "modules", "opened",
                                                   "last_used", "pinned"})
        self.assertNotIn("projects", json.loads((self.e.home / "config.json").read_text()))
        # list: most recently used first; the inbox apart
        lst = ok("projects.py", "list", env=self.e.env())
        self.assertEqual([p["key"] for p in lst["projects"]], ["DN", "BA"])
        self.assertEqual(lst["inbox"]["id"], "inbox")
        self.assertEqual((lst["inbox"]["key"], lst["inbox"]["name"], lst["inbox"]["unassigned"]), ("IN", "Unassigned", 0))
        # use / current
        self.assertEqual(ok("projects.py", "use", pa["id"], env=self.e.env())["current"], pa["id"])
        cur = ok("projects.py", "current", env=self.e.env())
        self.assertEqual((cur["current"], cur["project"]["key"]), (pa["id"], "BA"))
        self.assertEqual([p["key"] for p in ok("projects.py", "list", env=self.e.env())["projects"]], ["BA", "DN"])
        ok("projects.py", "set", pb["id"], "--json", '{"pinned": true}', env=self.e.env())
        self.assertEqual([p["key"] for p in ok("projects.py", "list", env=self.e.env())["projects"]], ["DN", "BA"])
        self.assertEqual(run_cli("projects.py", "use", "nope", env=self.e.env())[1]["code"], "no_project")
        # resolve: the deepest project a path is in
        inner = a / "apps" / "web"
        inner.mkdir(parents=True)
        pi = ok("projects.py", "add", inner, env=self.e.env())["project"]
        self.assertEqual(ok("projects.py", "resolve", inner / "src" / "x.ts", env=self.e.env())["project"]["id"], pi["id"])
        self.assertEqual(ok("projects.py", "resolve", a / "README.md", env=self.e.env())["project"]["id"], pa["id"])
        self.assertIsNone(ok("projects.py", "resolve", self.tmp, env=self.e.env())["project"])
        self.assertEqual(ok("projects.py", "resolve", self.e.ws / "inbox" / "items",
                            env=self.e.env())["project"]["id"], "inbox")
        # set: settings; the key only while the project has no items
        out = ok("projects.py", "set", pa["id"], "--json", json.dumps({
            "name": "Blurt", "modules": [{"name": "review page", "paths": ["web/packages/review"], "description": ""}],
            "worktree": False, "key": "BL"}), env=self.e.env())
        self.assertEqual((out["project"]["name"], out["project"]["key"], out["project"]["worktree"]), ("Blurt", "BL", False))
        self.assertEqual(json.loads((a / ".blurt" / "store.json").read_text())["key"], "BL")
        ok("items.py", "add", "--project", "BL", "--json", '{"kind":"note","title":"first"}', env=self.e.env())
        self.assertTrue((a / ".blurt" / "items" / "BL-1-first.md").is_file())
        for patch, code in (({"key": "BX"}, "key_in_use"), ({"key": "in"}, "bad_key"), ({"key": "DN"}, "key_taken"),
                            ({"path": "/x"}, "bad_field"), ({"name": " "}, "bad_field"), ({"modules": "x"}, "bad_field"),
                            ({"hints": {"apps": ["Xcode"]}}, "bad_field")):  # v0.8's front-app guessing is gone
            c, o = run_cli("projects.py", "set", pa["id"], "--json", json.dumps(patch), env=self.e.env())
            self.assertEqual((c, o["code"]), (1, code), patch)
        # remove: unregisters only
        ok("projects.py", "remove", pa["id"], env=self.e.env())
        self.assertTrue((a / ".blurt" / "items" / "BL-1-first.md").is_file())
        self.assertIsNone(ok("projects.py", "current", env=self.e.env())["current"])
        self.assertEqual(run_cli("projects.py", "remove", pa["id"], env=self.e.env())[1]["code"], "no_project")

    def test_remove_restores_losslessly_and_the_users_order(self):
        """Remove from Blurt is undoable without asking (micro 9): restore puts back exactly what was removed; the
        user's own order (micro 11) is the registry's, and using a project never changes it."""
        a, b, c = (make_repo(self.tmp / n) for n in ("alpha", "beta", "gamma"))
        ids = [ok("projects.py", "add", p, env=self.e.env())["project"]["id"] for p in (a, b, c)]
        ok("projects.py", "set", ids[1], "--json", json.dumps({"description": "the API", "default_agent": "codex",
                                                               "worktree": False}), env=self.e.env())
        ok("projects.py", "use", ids[1], env=self.e.env())
        reg = lambda: json.loads((self.e.home / "projects.json").read_text())  # noqa: E731
        before = reg()
        removed = ok("projects.py", "remove", ids[1], env=self.e.env())["removed"]
        self.assertEqual((removed["index"], removed["current"]), (1, True))
        self.assertIsNone(reg()["current"])
        back = ok("projects.py", "restore", "--json", json.dumps(removed), env=self.e.env())["project"]
        self.assertEqual(back["id"], ids[1])
        self.assertEqual(reg(), before)          # name, key, settings, place in the list, current: all as they were
        c2, o = run_cli("projects.py", "restore", "--json", json.dumps(removed), env=self.e.env())
        self.assertEqual((c2, o["code"]), (1, "exists"))
        # the user's order: dragged in the sidebar; untouched by use
        ok("projects.py", "order", ids[2], ids[0], env=self.e.env())
        self.assertEqual([p["id"] for p in reg()["projects"]], [ids[2], ids[0], ids[1]])
        ok("projects.py", "use", ids[1], env=self.e.env())
        self.assertEqual([p["id"] for p in reg()["projects"]], [ids[2], ids[0], ids[1]])
        self.assertEqual(run_cli("projects.py", "order", "nope", env=self.e.env())[1]["code"], "no_project")

    def test_open_items_counts(self):
        a = self.tmp / "p"
        a.mkdir()
        pa = ok("projects.py", "add", a, env=self.e.env())["project"]
        uids = [ok("items.py", "add", "--project", pa["id"], "--json", json.dumps({"kind": "issue", "title": f"t{n}"}),
                   env=self.e.env())["uid"] for n in range(4)]
        ok("items.py", "work", uids[0], "--state", "to_verify", "--claim", "fixed", env=self.e.env())
        ok("items.py", "user-ops", "--project", pa["id"], "--json",
           json.dumps([{"op": "set", "id": uids[1], "set": {"status": "deleted"}}]), env=self.e.env())
        ok("items.py", "work", uids[2], "--state", "in_progress", env=self.e.env())
        row = ok("projects.py", "list", env=self.e.env())["projects"][0]
        self.assertEqual(row["open_items"], 2)  # todo + in_progress; not to_verify, not deleted
        ok("items.py", "add", "--project", "inbox", "--json", '{"kind":"note","title":"loose"}', env=self.e.env())
        self.assertEqual(ok("projects.py", "list", env=self.e.env())["inbox"]["unassigned"], 1)

    def test_reopen_a_moved_or_removed_folder(self):
        """A project folder renamed on disk, opened again: the same project (its items, key, settings) at the new
        path — not a second, empty one. A folder removed from Blurt earlier keeps its store's id and key."""
        a = self.tmp / "billing-api"
        a.mkdir()
        pa = ok("projects.py", "add", a, "--description", "invoices", env=self.e.env())["project"]
        ok("items.py", "add", "--project", pa["id"], "--json", '{"kind":"issue","title":"first"}', env=self.e.env())
        b = self.tmp / "billing-api-v2"
        a.rename(b)
        self.assertFalse(ok("projects.py", "list", env=self.e.env())["projects"][0]["exists"])
        out = ok("projects.py", "add", b, env=self.e.env())
        self.assertFalse(out["created"])
        self.assertEqual(out["relocated"], str(a.resolve()))
        self.assertEqual((out["project"]["id"], out["project"]["key"], out["project"]["description"], out["project"]["exists"]),
                         (pa["id"], "BA", "invoices", True))
        rows = ok("projects.py", "list", env=self.e.env())["projects"]
        self.assertEqual([(r["id"], r["path"], r["open_items"]) for r in rows], [(pa["id"], str(b.resolve()), 1)])
        self.assertEqual(ok("items.py", "list", "--project", pa["id"], env=self.e.env())["items"][0]["title"], "first")
        # opened once more at its new place (Open Folder again, a drop, the launch migration): still that project
        twice = ok("projects.py", "add", b, env=self.e.env())
        self.assertEqual((twice["created"], twice["project"]["id"]), (False, pa["id"]))
        self.assertEqual(len(ok("projects.py", "list", env=self.e.env())["projects"]), 1)
        cfg = json.loads((self.e.home / "config.json").read_text())
        cfg["record"].update(workspaces=[str(b)], workspace=str(b))
        (self.e.home / "config.json").write_text(json.dumps(cfg))
        self.assertEqual(ok("projects.py", "migrate", env=self.e.env())["added"], 0)
        self.assertEqual([r["id"] for r in ok("projects.py", "list", env=self.e.env())["projects"]], [pa["id"]])
        ok("projects.py", "use", "inbox", env=self.e.env())
        # removed, then opened again (at yet another path): the store's id and key come back with it
        ok("projects.py", "remove", pa["id"], env=self.e.env())
        c = self.tmp / "billing"
        b.rename(c)
        again = ok("projects.py", "add", c, env=self.e.env())
        self.assertTrue(again["created"])
        self.assertEqual((again["project"]["id"], again["project"]["key"], again["project"]["open_items"]), (pa["id"], "BA", 1))
        # a copy next to a folder that still exists stays a project of its own
        d = self.tmp / "billing-copy"
        import shutil
        shutil.copytree(c, d)
        copy = ok("projects.py", "add", d, env=self.e.env())["project"]
        self.assertNotEqual(copy["id"], pa["id"])

    def test_migrate_from_v06_config(self):
        a, b = make_repo(self.tmp / "one"), make_repo(self.tmp / "two")
        cfg = {"record": {"install_app": False, "workspaces": [str(a), str(b), str(self.tmp / "gone")],
                          "workspace": str(b)}}
        (self.e.home / "config.json").write_text(json.dumps(cfg))
        out = ok("projects.py", "migrate", env=self.e.env())
        self.assertEqual((out["added"], out["current"]), (2, projects.project_id(b)))
        # carried over, not chosen: the app asks once (current_by "migrate")
        self.assertEqual(ok("projects.py", "current", env=self.e.env())["current_by"], "migrate")
        again = ok("projects.py", "migrate", env=self.e.env())
        self.assertEqual((again["added"], again["current"]), (0, projects.project_id(b)))
        self.assertEqual(ok("projects.py", "list", env=self.e.env())["current_by"], "migrate")
        # the user's answer (keep it) makes it theirs
        ok("projects.py", "use", projects.project_id(b), env=self.e.env())
        self.assertEqual(ok("projects.py", "current", env=self.e.env())["current_by"], "user")
        ok("projects.py", "use", "inbox", env=self.e.env())
        self.assertIsNone(ok("projects.py", "migrate", env=self.e.env())["current"])  # the user's choice stays
        self.assertEqual(ok("projects.py", "current", env=self.e.env())["current_by"], "user")
        self.assertEqual(json.loads((self.e.home / "config.json").read_text()), cfg)  # config.json untouched

    def test_migrated_by_an_earlier_build_is_asked_about(self):
        """A registry an earlier v0.7 build migrated (no current_by) still gets the question once."""
        a = make_repo(self.tmp / "one")
        pid = ok("projects.py", "add", a, env=self.e.env())["project"]["id"]
        reg = json.loads((self.e.home / "projects.json").read_text())
        reg.update(current=pid, _migrated=True)
        (self.e.home / "projects.json").write_text(json.dumps(reg))
        ok("projects.py", "migrate", env=self.e.env())
        self.assertEqual(ok("projects.py", "current", env=self.e.env())["current_by"], "migrate")


class Assignment(TmpCase):
    def setUp(self):
        super().setUp()
        self.web = make_repo(self.tmp / "web-app")
        (self.web / "src" / "auth").mkdir(parents=True)
        (self.web / "src" / "auth" / "Login.tsx").write_text("export {}\n")
        self.docs = self.tmp / "handbook"
        self.docs.mkdir()
        self.pw = ok("projects.py", "add", self.web, env=self.e.env())["project"]
        self.pd = ok("projects.py", "add", self.docs, "--description", "the team handbook", env=self.e.env())["project"]

    def inbox(self, **fields) -> str:
        return ok("items.py", "add", "--project", "inbox", "--json", json.dumps({"kind": "issue", **fields}),
                  env=self.e.env())["uid"]

    def test_none_is_unassigned_and_old_words_mean_the_same(self):
        """The current project is the user's pick or none: `use inbox` (or v0.8's "auto", or "none") = Unassigned;
        a v0.8 registry that says "auto" and still has route_threshold reads as none, and loses the threshold on
        the next write."""
        for word in ("inbox", "none", "auto"):
            ok("projects.py", "use", self.pw["id"], env=self.e.env())
            self.assertIsNone(ok("projects.py", "use", word, env=self.e.env())["current"], word)
            self.assertIsNone(json.loads((self.e.home / "projects.json").read_text())["current"])
        reg = json.loads((self.e.home / "projects.json").read_text())
        reg.update(current="auto", route_threshold=0.75)
        (self.e.home / "projects.json").write_text(json.dumps(reg))
        cur = ok("projects.py", "current", env=self.e.env())
        self.assertEqual((cur["current"], cur["project"]), (None, None))
        self.assertIsNone(ok("projects.py", "list", env=self.e.env())["current"])
        ok("projects.py", "use", self.pd["id"], env=self.e.env())
        self.assertNotIn("route_threshold", json.loads((self.e.home / "projects.json").read_text()))
        # nothing to route with any more
        self.assertEqual(run_cli("projects.py", "route", "--items", "x", env=self.e.env())[1]["code"], "bad_args")

    def test_the_organizer_only_suggests(self):
        """SKILL.md §3 for an Unassigned capture: the run may write "project" per item — however sure it says it is,
        the item stays in Unassigned with suggested_project; an unknown project is no suggestion."""
        session = self.e.ws / "inbox" / "sessions" / "20261022-141500"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "issue", "title": "sure", "project": "WA", "project_confidence": 0.98,
             "project_reason": "the sign-in page", "code_refs": ["src/auth/Login.tsx:42"]},
            {"id": "I-002", "kind": "issue", "title": "unsure", "project": self.pd["id"], "project_confidence": 0.4,
             "project_reason": "mentions onboarding"},
            {"id": "I-003", "kind": "note", "title": "no idea"},
            {"id": "I-004", "kind": "note", "title": "unknown project", "project": "NOPE"},
            {"id": "I-005", "kind": "note", "title": "no confidence given", "project": self.pd["key"]}]}))
        out = ok("items.py", "ingest", session, env=self.e.env())
        self.assertEqual(out["inbox"], 5)
        by = {r["local"]: ok("items.py", "get", r["uid"], env=self.e.env())["item"] for r in out["items"]}
        self.assertEqual({k: v["project"] for k, v in by.items()}, dict.fromkeys(by, "inbox"))
        self.assertEqual(by["I-001"]["suggested_project"],
                         {"id": self.pw["id"], "confidence": 0.98, "reason": "the sign-in page"})
        self.assertEqual(by["I-001"]["project_by"], "capture")
        self.assertNotIn("project_confidence", by["I-001"])
        self.assertNotIn("project_reason", by["I-001"])
        self.assertEqual(by["I-002"]["suggested_project"]["id"], self.pd["id"])
        self.assertEqual(by["I-005"]["suggested_project"], {"id": self.pd["id"], "reason": ""})
        self.assertNotIn("suggested_project", by["I-003"])
        self.assertNotIn("suggested_project", by["I-004"])
        # nothing in the background moves them later either
        time.sleep(1.0)
        self.assertEqual(list((self.web / ".blurt" / "items").glob("*.md")), [])

    def test_a_project_the_user_set_wins_over_the_organizer(self):
        """A capture made with a current project: its items go there, whatever project the run wrote."""
        session = self.web / ".blurt" / "sessions" / "20261022-151500"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "issue", "title": "x", "project": self.pd["id"], "project_confidence": 0.99}]}))
        out = ok("items.py", "ingest", session, env=self.e.env())
        it = ok("items.py", "get", out["items"][0]["uid"], env=self.e.env())["item"]
        self.assertEqual((it["project"], it["project_by"]), (self.pw["id"], "capture"))
        self.assertNotIn("suggested_project", it)

    def test_a_top_level_project_is_only_a_suggestion(self):
        """A run that writes "project" at the top of items.json (instead of per item) moves nothing: the Unassigned
        batch stays in Unassigned, each item suggesting that project; the batch doesn't remember it as its place."""
        session = self.e.ws / "inbox" / "sessions" / "20261022-143000"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"project": "WA", "items": [
            {"id": "I-001", "kind": "issue", "title": "one"},
            {"id": "I-002", "kind": "issue", "title": "two", "project": self.pd["key"]}]}))
        out = ok("items.py", "ingest", session, env=self.e.env())
        self.assertEqual(out["inbox"], 2)
        by = {r["local"]: ok("items.py", "get", r["uid"], env=self.e.env())["item"] for r in out["items"]}
        self.assertEqual({k: v["project"] for k, v in by.items()}, {"I-001": "inbox", "I-002": "inbox"})
        self.assertEqual(by["I-001"]["suggested_project"]["id"], self.pw["id"])
        self.assertEqual(by["I-002"]["suggested_project"]["id"], self.pd["id"])  # its own word comes first
        self.assertIsNone(json.loads((session / "batch.json").read_text()).get("project"))
        # a later ingest of the same session (the run adds an item) still files nothing
        (session / "items.json").write_text(json.dumps({"project": "WA", "items": [
            {"id": "I-003", "kind": "note", "title": "three"}]}))
        again = ok("items.py", "ingest", session, env=self.e.env())
        self.assertEqual(again["items"][0]["project"], "inbox")

    def test_move_from_leaves_items_the_user_moved(self):
        """`move --from Q`: "Filed to X · Change" and its Undo move only the items still where the recording put
        them; one the user has moved by hand since stays where they put it, and comes back in "kept"."""
        a, b, c = (self.inbox(title=t) for t in ("a", "b", "c"))
        ok("items.py", "move", c, "--project", self.pd["id"], env=self.e.env())  # the user's own move
        out = ok("items.py", "move", a, b, c, "--project", self.pw["id"], "--from", "inbox", env=self.e.env())
        self.assertEqual(sorted(m["uid"] for m in out["moved"]), sorted([a, b]))
        self.assertEqual(out["kept"], [{"uid": c, "project": self.pd["id"]}])
        self.assertEqual(ok("items.py", "get", c, env=self.e.env())["item"]["project"], self.pd["id"])
        # Undo: those two back, from where they went (by key works too); c is still left alone
        back = ok("items.py", "move", a, b, "--project", "inbox", "--from", "WA", env=self.e.env())
        self.assertEqual(len(back["moved"]), 2)
        self.assertEqual({ok("items.py", "get", u, env=self.e.env())["item"]["project"] for u in (a, b)}, {"inbox"})
        # several --from: any of them; without --from every item moves and there is no "kept"
        both = ok("items.py", "move", a, c, "--project", self.pw["id"], "--from", "inbox", "--from", self.pd["id"],
                  env=self.e.env())
        self.assertEqual(len(both["moved"]), 2)
        self.assertNotIn("kept", ok("items.py", "move", a, "--project", "inbox", env=self.e.env()))

    def test_moving_keeps_the_suggestion_for_undo(self):
        """Looks like X · Move = the user's move; ⌘Z moves it back, and the suggestion is still there to show."""
        session = self.e.ws / "inbox" / "sessions" / "20261022-161500"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "issue", "title": "crash", "project": "WA", "project_reason": "sign-in"}]}))
        uid = ok("items.py", "ingest", session, env=self.e.env())["items"][0]["uid"]
        moved = ok("items.py", "move", uid, "--project", "WA", env=self.e.env())["moved"]
        self.assertEqual((moved[0]["from"], moved[0]["to"], moved[0]["id"]), ("inbox", self.pw["id"], "WA-1"))
        it = ok("items.py", "get", uid, env=self.e.env())["item"]
        self.assertEqual((it["project"], it["project_by"]), (self.pw["id"], "user"))
        self.assertIn("project", it["_user"])
        back = ok("items.py", "move", uid, "--project", "inbox", "--by", "user", env=self.e.env())["moved"][0]
        self.assertEqual(back["id"], "IN-1")  # its old id again
        it = ok("items.py", "get", uid, env=self.e.env())["item"]
        self.assertEqual((it["project"], it["suggested_project"]["id"]), ("inbox", self.pw["id"]))
        # the AI never moves: --by ai is gone
        self.assertEqual(run_cli("items.py", "move", uid, "--project", "WA", "--by", "ai", env=self.e.env())[1]["code"],
                         "bad_args")

    def test_candidates_for_the_organizer_prompt(self):
        """What an organizing run of an Unassigned capture is told: every project with a folder — id, key, name,
        description, path, its newest 5 live titles (newest first) — and the prompt text; nothing without projects."""
        for n in range(7):
            ok("items.py", "add", "--project", self.pw["id"], "--json", json.dumps({"kind": "issue", "title": f"bug {n}"}),
               env=self.e.env())
        gone = ok("items.py", "add", "--project", self.pw["id"], "--json", '{"kind":"note","title":"thrown away"}',
                  env=self.e.env())["uid"]
        ok("items.py", "state", gone, "--action", "discard", "--by", "user", env=self.e.env())
        out = ok("projects.py", "candidates", env=self.e.env())
        by = {r["key"]: r for r in out["projects"]}
        self.assertEqual(set(by), {"WA", "HAN"})
        self.assertEqual(by["WA"]["recent"], ["bug 6", "bug 5", "bug 4", "bug 3", "bug 2"])
        self.assertEqual((by["HAN"]["description"], by["HAN"]["recent"], by["HAN"]["path"]),
                         ("the team handbook", [], str(self.docs.resolve())))
        text = out["text"]
        self.assertIn(f"id {self.pw['id']}, key WA, folder {self.web.resolve()}", text)
        self.assertIn('Newest items: "bug 6"; "bug 5"', text)
        self.assertIn("About: the team handbook", text)
        self.assertIn('"project"', text)
        self.assertIn("only a suggestion", text)
        self.assertNotIn("thrown away", text)
        two = ok("projects.py", "candidates", "--recent", "2", env=self.e.env())["projects"]
        self.assertEqual(next(r for r in two if r["key"] == "WA")["recent"], ["bug 6", "bug 5"])
        # a folder that is gone is no candidate; none left → no text
        import shutil
        shutil.rmtree(self.docs)
        self.assertEqual([r["key"] for r in ok("projects.py", "candidates", env=self.e.env())["projects"]], ["WA"])
        for p in (self.pw, self.pd):
            ok("projects.py", "remove", p["id"], env=self.e.env())
        self.assertEqual(ok("projects.py", "candidates", env=self.e.env()), {"ok": True, "projects": [], "text": ""})

    def test_capture_with_a_current_project_goes_straight_there(self):
        session = self.web / ".blurt" / "sessions" / "20261022-101500"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"items": [{"id": "I-001", "kind": "idea", "title": "x"}]}))
        out = ok("items.py", "ingest", session, env=self.e.env())
        self.assertEqual((out["inbox"], out["items"][0]["id"], out["items"][0]["project"]), (0, "WA-1", self.pw["id"]))
        self.assertEqual(ok("items.py", "get", "WA-1", env=self.e.env())["item"]["project_by"], "capture")
        # a session whose meta.json names a project (switched on the island mid-recording) goes there
        s2 = self.e.ws / "inbox" / "sessions" / "20261022-111500"
        s2.mkdir(parents=True)
        (s2 / "meta.json").write_text(json.dumps({"project": self.pd["id"]}))
        (s2 / "items.json").write_text(json.dumps({"items": [{"id": "I-001", "kind": "idea", "title": "y"}]}))
        self.assertEqual(ok("items.py", "ingest", s2, env=self.e.env())["items"][0]["project"], self.pd["id"])
        # BLURT_PROJECT (set by the app for the agent) works the same
        s3 = self.e.ws / "inbox" / "sessions" / "20261022-121500"
        s3.mkdir(parents=True)
        (s3 / "items.json").write_text(json.dumps({"items": [{"id": "I-001", "kind": "idea", "title": "z"}]}))
        out = ok("items.py", "ingest", s3, env=self.e.env(BLURT_PROJECT=self.pw["id"]))
        self.assertEqual(out["items"][0]["id"], "WA-2")
        # shots assigned to a project on the island (shots.jsonl) go there
        s4 = self.e.ws / "inbox" / "sessions" / "20261022-131500-shots"
        (s4 / "shots").mkdir(parents=True)
        (s4 / "shots" / "001.png").write_bytes(b"png")
        (s4 / "shots" / "002.png").write_bytes(b"png")
        (s4 / "shots.jsonl").write_text("\n".join(json.dumps(x) for x in (
            {"n": 1, "file": "shots/001.png", "project": None}, {"n": 2, "file": "shots/002.png", "project": None},
            {"n": 1, "project": self.pd["id"], "assigned_by": "user"})) + "\n")
        (s4 / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "note", "title": "a", "frames": [{"path": "shots/001.png", "t": None}]},
            {"id": "I-002", "kind": "note", "title": "b", "frames": [{"path": "shots/002.png", "t": None}]}]}))
        out = ok("items.py", "ingest", s4, env=self.e.env())
        self.assertEqual([r["project"] for r in out["items"]], [self.pd["id"], "inbox"])
        a = ok("items.py", "get", out["items"][0]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["project_by"], a["source"]["shot"], a["source"]["type"]), ("user", 1, "snap"))
        self.assertTrue(Path(a["frames"][0]["path"]).is_file())
        self.assertTrue(a["frames"][0]["path"].startswith(str(self.docs / ".blurt" / "assets")))

    def test_a_voice_input_in_a_shots_batch_is_a_voice_item(self):
        """⌥⇧V without a project hangs a voice card in the shots batch; its item says source.type voice, not snap."""
        s = self.e.ws / "inbox" / "sessions" / "20261022-141500-shots"
        (s / "shots").mkdir(parents=True)
        (s / "shots.jsonl").write_text("\n".join(json.dumps(x) for x in (
            {"n": 1, "type": "voice", "file": None, "voice": "shots/001.wav", "said": "water the basil", "project": None},
            {"n": 1, "project": None, "assigned_by": "ai"})) + "\n")
        (s / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "task", "title": "Water the basil", "source": {"shot": 1}}]}))
        out = ok("items.py", "ingest", s, env=self.e.env())
        a = ok("items.py", "get", out["items"][0]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["source"]["type"], a["source"]["shot"]), ("voice", 1))


if __name__ == "__main__":
    import unittest
    unittest.main()
