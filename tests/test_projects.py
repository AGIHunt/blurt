"""Projects (contract K2): projects.json and projects.py — keys and slugs, open / remove / set / use / resolve,
the v0.6 migration, and AI routing (rules, the small model, the threshold, the user's choice wins)."""
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
        self.assertEqual((reg["schema"], reg["current"], reg["route_threshold"]), (1, "auto", 0.75))
        self.assertEqual(set(reg["projects"][0]), {"id", "path", "name", "key", "slug", "description", "default_agent",
                                                   "worktree", "worktree_root", "modules", "hints", "opened",
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
            "hints": {"domains": ["blurt.dev"], "apps": ["Blurt"]}, "worktree": False, "key": "BL"}), env=self.e.env())
        self.assertEqual((out["project"]["name"], out["project"]["key"], out["project"]["worktree"]), ("Blurt", "BL", False))
        self.assertEqual(json.loads((a / ".blurt" / "store.json").read_text())["key"], "BL")
        ok("items.py", "add", "--project", "BL", "--json", '{"kind":"note","title":"first"}', env=self.e.env())
        self.assertTrue((a / ".blurt" / "items" / "BL-1-first.md").is_file())
        for patch, code in (({"key": "BX"}, "key_in_use"), ({"key": "in"}, "bad_key"), ({"key": "DN"}, "key_taken"),
                            ({"path": "/x"}, "bad_field"), ({"name": " "}, "bad_field"), ({"modules": "x"}, "bad_field")):
            c, o = run_cli("projects.py", "set", pa["id"], "--json", json.dumps(patch), env=self.e.env())
            self.assertEqual((c, o["code"]), (1, code), patch)
        # remove: unregisters only
        ok("projects.py", "remove", pa["id"], env=self.e.env())
        self.assertTrue((a / ".blurt" / "items" / "BL-1-first.md").is_file())
        self.assertEqual(ok("projects.py", "current", env=self.e.env())["current"], "auto")
        self.assertEqual(run_cli("projects.py", "remove", pa["id"], env=self.e.env())[1]["code"], "no_project")

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
        ok("projects.py", "use", "auto", env=self.e.env())
        self.assertEqual(ok("projects.py", "migrate", env=self.e.env())["current"], "auto")  # the user's choice stays
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


class Route(TmpCase):
    def setUp(self):
        super().setUp()
        self.web = make_repo(self.tmp / "web-app")
        (self.web / "src" / "auth").mkdir(parents=True)
        (self.web / "src" / "auth" / "Login.tsx").write_text("export {}\n")
        self.docs = self.tmp / "handbook"
        self.docs.mkdir()
        self.pw = ok("projects.py", "add", self.web, env=self.e.env())["project"]
        self.pd = ok("projects.py", "add", self.docs, env=self.e.env())["project"]
        ok("projects.py", "set", self.pw["id"], "--json", json.dumps({"hints": {"domains": ["example.test"], "apps": []},
                                                                    "modules": [{"name": "billing"}]}), env=self.e.env())
        ok("projects.py", "set", self.pd["id"], "--json", json.dumps({"hints": {"domains": [], "apps": ["Notion"]},
                                                                    "description": "the team handbook"}), env=self.e.env())

    def model(self, answer: str) -> str:
        """A stand-in for the small model ($BLURT_ROUTE_CMD): reads the prompt, answers with some chatter + JSON."""
        f = self.tmp / f"answer-{len(answer)}.txt"
        f.write_text("Sure, here you go:\n" + answer)
        script = self.tmp / "model.py"
        script.write_text("import sys\nprompt = sys.stdin.read()\nassert 'Projects:' in prompt\n"
                          "print(open(sys.argv[1], encoding='utf-8').read())\n")
        return f"{sys.executable} {script} {f}"

    def inbox(self, **fields) -> str:
        return ok("items.py", "add", "--project", "inbox", "--json", json.dumps({"kind": "issue", **fields}),
                  env=self.e.env())["uid"]

    def test_rules_then_model_then_threshold(self):
        u_code = self.inbox(title="crash", code_refs=["src/auth/Login.tsx:42"])
        u_url = self.inbox(title="slow page", source={"url": "https://www.example.test/pricing"})
        u_app = self.inbox(title="typo", source={"app": "Notion"})
        u_mod = self.inbox(title="invoice", module="Billing")
        u_low = self.inbox(title="something vague")
        u_high = self.inbox(title="handbook onboarding page is outdated")
        answer = json.dumps([{"uid": u_low, "project": self.pd["id"], "confidence": 0.5, "reason": "maybe docs"},
                             {"uid": u_high, "project": self.pd["id"], "confidence": 0.9, "reason": "handbook"}])
        cmd = self.model(answer)
        out = ok("projects.py", "route", "--items", u_code, u_url, u_app, u_mod, u_low, u_high, "--apply",
                 env=self.e.env(BLURT_ROUTE_CMD=cmd))
        by = {s["uid"]: s for s in out["suggestions"]}
        self.assertEqual((by[u_code]["project"], by[u_code]["confidence"], by[u_code]["by"]), (self.pw["id"], 0.95, "rule"))
        self.assertEqual((by[u_url]["project"], by[u_url]["confidence"]), (self.pw["id"], 0.9))
        self.assertEqual((by[u_app]["project"], by[u_app]["confidence"]), (self.pd["id"], 0.9))
        self.assertEqual((by[u_mod]["project"], by[u_mod]["confidence"]), (self.pw["id"], 0.8))
        self.assertEqual((by[u_low]["by"], by[u_high]["by"]), ("llm", "llm"))
        self.assertEqual(set(out["moved"]), {u_code, u_url, u_app, u_mod, u_high})
        # moved: in the project's store, by ai with its confidence, the inbox id kept as an alias
        it = ok("items.py", "get", u_code, env=self.e.env())["item"]
        self.assertEqual((it["project"], it["project_by"], it["project_confidence"], it["id"]),
                         (self.pw["id"], "ai", 0.95, "WA-1"))
        self.assertEqual(it["aliases"], ["IN-1"])
        self.assertEqual(ok("items.py", "get", "IN-1", env=self.e.env())["item"]["uid"], u_code)  # old id still works
        # below the threshold: stays in the inbox with a suggestion
        low = ok("items.py", "get", u_low, env=self.e.env())["item"]
        self.assertEqual((low["project"], low["suggested_project"]),
                         ("inbox", {"id": self.pd["id"], "confidence": 0.5, "reason": "maybe docs"}))
        self.assertEqual(ok("items.py", "get", u_high, env=self.e.env())["item"]["project"], self.pd["id"])
        # a higher threshold just suggests
        u2 = self.inbox(title="crash 2", code_refs=["src/auth/Login.tsx:1"])
        out = ok("projects.py", "route", "--items", u2, "--apply", "--threshold", "0.99", "--no-llm", env=self.e.env())
        self.assertEqual(out["moved"], [])
        self.assertEqual(ok("items.py", "get", u2, env=self.e.env())["item"]["suggested_project"]["confidence"], 0.95)

    def test_the_users_choice_is_never_overridden(self):
        u = self.inbox(title="crash", code_refs=["src/auth/Login.tsx:42"])
        ok("items.py", "move", u, "--project", self.pd["id"], "--by", "user", env=self.e.env())
        it = ok("items.py", "get", u, env=self.e.env())["item"]
        self.assertIn("project", it["_user"])
        self.assertEqual(it["project_by"], "user")
        out = ok("projects.py", "route", "--items", u, "--apply", env=self.e.env())
        self.assertEqual((out["suggestions"], out["moved"]), ([], []))
        code, o = run_cli("items.py", "move", u, "--project", self.pw["id"], "--by", "ai", env=self.e.env())
        self.assertEqual(o["moved"], [])
        self.assertEqual(ok("items.py", "get", u, env=self.e.env())["item"]["project"], self.pd["id"])
        # dry: without --apply nothing changes
        v = self.inbox(title="x", source={"app": "Notion"})
        out = ok("projects.py", "route", "--items", v, "--no-llm", env=self.e.env())
        self.assertEqual((out["suggestions"][0]["project"], out["moved"]), (self.pd["id"], []))
        self.assertEqual(ok("items.py", "get", v, env=self.e.env())["item"]["project"], "inbox")

    def test_background_route_is_a_job(self):
        """--apply (the run ingest starts) reports as a K4 route job owned by projects.py; a preview writes none."""
        u = self.inbox(title="typo", source={"app": "Notion"})
        out = ok("projects.py", "route", "--items", u, "--no-llm", env=self.e.env())
        self.assertNotIn("job", out)
        out = ok("projects.py", "route", "--items", u, "--apply", "--no-llm", env=self.e.env())
        job = json.loads((self.e.home / "jobs" / f"{out['job']}.json").read_text())
        self.assertEqual((job["type"], job["owner"], job["state"], job["project"], job["items"]),
                         ("route", "projects.py", "done", "inbox", [u]))
        self.assertEqual([(s["id"], s["state"]) for s in job["steps"]], [("route", "done")])
        self.assertIsNotNone(job["ended"])

    def test_model_failure_leaves_items_in_the_inbox(self):
        u = self.inbox(title="vague")
        bad = f"{sys.executable} -c \"import sys; sys.exit(3)\""
        out = ok("projects.py", "route", "--items", u, "--apply", env=self.e.env(BLURT_ROUTE_CMD=bad))
        self.assertEqual((out["suggestions"][0]["project"], out["moved"]), (None, []))
        self.assertIn("model", out["suggestions"][0]["reason"])
        nonsense = f"{sys.executable} -c \"print('no json here')\""
        out = ok("projects.py", "route", "--items", u, "--apply", env=self.e.env(BLURT_ROUTE_CMD=nonsense))
        self.assertEqual(out["moved"], [])
        self.assertEqual(run_cli("projects.py", "route", "--items", "nope", env=self.e.env())[1]["code"], "not_found")

    def test_ingest_in_auto_mode_routes_in_the_background(self):
        """An agent's items.json for a capture made in auto mode: the items land in the inbox, then route moves them."""
        session = self.e.ws / "inbox" / "sessions" / "20261022-101500-shots"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"title": "t", "language": "en", "items": [
            {"id": "I-001", "kind": "issue", "title": "login crash", "code_refs": ["src/auth/Login.tsx:9"]},
            {"id": "I-002", "kind": "note", "title": "no idea"}]}))
        env = self.e.env()
        env.pop("BLURT_NO_ROUTE")
        out = ok("items.py", "ingest", session, env={**env, "BLURT_ROUTE_CMD": self.model("[]")})
        self.assertEqual(out["inbox"], 2)
        deadline = time.time() + 20
        while time.time() < deadline:
            moved = list((self.web / ".blurt" / "items").glob("*.md"))
            if moved:
                break
            time.sleep(0.2)
        self.assertEqual([p.name for p in moved], ["WA-1-login-crash.md"])
        self.assertEqual(len(list((self.e.ws / "inbox" / "items").glob("*.md"))), 1)
        doc = ok("items.py", "doc", session, env=self.e.env())["doc"]  # the batch still lists both, wherever they are
        self.assertEqual([i["_project"]["key"] for i in doc["items"]], ["WA", "IN"])

    def test_the_agent_proposes_a_project_per_item(self):
        """SKILL.md §3 in auto mode: project + project_confidence per item; below the threshold → Unassigned with
        the suggestion, and no background routing for it."""
        session = self.e.ws / "inbox" / "sessions" / "20261022-141500"
        session.mkdir(parents=True)
        (session / "items.json").write_text(json.dumps({"items": [
            {"id": "I-001", "kind": "issue", "title": "sure", "project": "WA", "project_confidence": 0.92},
            {"id": "I-002", "kind": "issue", "title": "unsure", "project": self.pd["id"], "project_confidence": 0.4,
             "project_reason": "mentions onboarding"},
            {"id": "I-003", "kind": "note", "title": "no idea"},
            {"id": "I-004", "kind": "note", "title": "unknown project", "project": "NOPE"}]}))
        out = ok("items.py", "ingest", session, env=self.e.env())
        by = {r["local"]: r for r in out["items"]}
        self.assertEqual((by["I-001"]["project"], by["I-001"]["id"]), (self.pw["id"], "WA-1"))
        a = ok("items.py", "get", by["I-001"]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["project_by"], a["project_confidence"]), ("ai", 0.92))
        self.assertNotIn("project_reason", a)
        b = ok("items.py", "get", by["I-002"]["uid"], env=self.e.env())["item"]
        self.assertEqual((b["project"], b["suggested_project"]),
                         ("inbox", {"id": self.pd["id"], "confidence": 0.4, "reason": "mentions onboarding"}))
        self.assertEqual((by["I-003"]["project"], by["I-004"]["project"]), ("inbox", "inbox"))

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
        out = ok("items.py", "ingest", s, env=self.e.env(BLURT_NO_ROUTE="1"))
        a = ok("items.py", "get", out["items"][0]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["source"]["type"], a["source"]["shot"]), ("voice", 1))


if __name__ == "__main__":
    import unittest
    unittest.main()
