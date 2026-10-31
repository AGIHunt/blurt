"""v0.7 token diet: captures with a note become items without an agent (captures.py), the processing model and
the token count of an unattended run (agents.py processing / parse_usage / command --processing), and the
dispatch panel's model (sessions.py dispatch --model → the agent's model flag)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_store import TmpCase, make_repo, ok, run_cli  # noqa: E402

import agents  # noqa: E402
import captures  # noqa: E402
import store as st  # noqa: E402


def shots_session(store: Path, lines: list[dict]) -> Path:
    d = store / "sessions" / "20261022-101500-shots"
    (d / "shots").mkdir(parents=True)
    for o in lines:
        if o.get("file"):
            (d / o["file"]).write_bytes(b"\x89PNG\r\n\x1a\nfake")
        if o.get("marked"):
            (d / o["marked"]).write_bytes(b"\x89PNG\r\n\x1a\nink")
    (d / "shots.jsonl").write_text("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in lines))
    (d / "meta.json").write_text(json.dumps({"mode": "shots", "state": "collecting"}))
    return d


class Heuristics(TmpCase):
    def test_kind_guess(self):
        g = captures.guess_kind
        self.assertEqual(g("The save button does nothing, looks like a bug"), "issue")
        self.assertEqual(g("登录按钮点了没反应"), "issue")
        self.assertEqual(g("Remember to ask Lee about the pricing page"), "task")
        self.assertEqual(g("记得跟进一下这个合同"), "task")
        self.assertEqual(g("What if the sidebar folded into icons?"), "idea")
        self.assertEqual(g("这个网站的导航做得好，可以借鉴"), "idea")
        self.assertEqual(g("Q3 revenue was 12% up"), "note")
        self.assertEqual(g(""), "note")

    def test_note_is_typed_then_said(self):
        """v0.8: a shot with typed text and a spoken note carries both (the card shows both); typed comes first."""
        n = captures.note_of
        self.assertEqual(n({"text": "fdsfdsa", "said": "按钮被挡住了"}), "fdsfdsa\n按钮被挡住了")
        self.assertEqual(n({"text": " see header ", "said": None}), "see header")
        self.assertEqual(n({"text": None, "said": "只有说的"}), "只有说的")
        self.assertEqual(n({"text": "same words", "said": "same words"}), "same words")
        self.assertEqual(n({"text": "the logo overlaps, fix it", "said": "the logo overlaps"}), "the logo overlaps, fix it")
        self.assertEqual(n({"text": "", "said": ""}), "")
        f = captures.fields_for(5, {"type": "shot", "file": "shots/005.png", "text": "Header looks off.",
                                    "said": "the logo overlaps the menu"}, "en")
        self.assertEqual((f["title"], f["quote"]), ("Header looks off", "Header looks off.\nthe logo overlaps the menu"))

    def test_first_sentence(self):
        f = captures.first_sentence
        self.assertEqual(f("The save button does nothing. It used to work yesterday."), "The save button does nothing")
        self.assertEqual(f("登录按钮没反应。昨天还好好的"), "登录按钮没反应")
        self.assertEqual(f("Why is this grey? No idea"), "Why is this grey?")
        self.assertEqual(f("\n\n  first line\nsecond line"), "first line")
        long = "word " * 40
        t = f(long)
        self.assertLessEqual(len(t), captures.TITLE_MAX)
        self.assertTrue(t.endswith("…") and not t.endswith(" …"))
        self.assertLessEqual(len(f("汉" * 200)), captures.TITLE_MAX)


class FileCaptures(TmpCase):
    def setUp(self):
        super().setUp()
        self.repo = make_repo(self.tmp / "web-app")
        self.p = ok("projects.py", "add", self.repo, env=self.e.env())["project"]
        self.s = shots_session(Path(self.p["store"]), [
            {"n": 1, "type": "shot", "file": "shots/001.png", "marked": "shots/001.marked.png", "wall": 1761100000,
             "text": "The export button is broken. Clicking it does nothing.", "project": self.p["id"],
             "assigned_by": "capture"},
            {"n": 2, "type": "voice", "file": None, "voice": "shots/002.wav", "said": "记得问一下设计稿的进度",
             "wall": 1761100100, "project": self.p["id"], "assigned_by": "capture"},
            {"n": 3, "type": "shot", "file": "shots/003.png", "wall": 1761100200, "text": None, "project": None},
            {"n": 4, "type": "shot", "file": "shots/004.png", "wall": 1761100300, "text": "gone"},
            {"n": 4, "deleted": True},
        ])

    def test_file_with_notes_no_agent(self):
        out = ok("captures.py", "file", self.s, "--captures", "1", "2", "3", "4", "9", env=self.e.env())
        made = {r["n"]: r for r in out["items"]}
        self.assertEqual(sorted(made), [1, 2, 3])
        self.assertEqual({s["n"]: s["reason"] for s in out["skipped"]}, {4: "deleted", 9: "missing"})
        a = ok("items.py", "get", made[1]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["kind"], a["title"], a["quote"]), ("issue", "The export button is broken",
                                                                "The export button is broken. Clicking it does nothing."))
        self.assertEqual(a["project"], self.p["id"])
        self.assertEqual(a["enrich"], "pending")
        self.assertEqual((a["source"]["type"], a["source"]["shot"]), ("snap", 1))
        self.assertEqual(len(a["frames"]), 2)
        self.assertTrue(a["frames"][0]["path"].endswith(".marked.png"))
        self.assertTrue(all(Path(f["path"]).is_file() for f in a["frames"]))
        b = ok("items.py", "get", made[2]["uid"], env=self.e.env())["item"]
        self.assertEqual((b["kind"], b["source"]["type"], b.get("frames") or []), ("task", "voice", []))
        c = ok("items.py", "get", made[3]["uid"], env=self.e.env())["item"]
        self.assertRegex(c["title"], r"^Screenshot \d\d:\d\d$")  # config lang en; no note → says what it is
        self.assertEqual(c["kind"], "note")
        # a second call files nothing twice
        again = ok("captures.py", "file", self.s, "--captures", "1", "2", env=self.e.env())
        self.assertEqual((again["items"], {s["reason"] for s in again["skipped"]}), ([], {"filed"}))
        self.assertEqual(len(ok("items.py", "list", "--project", self.p["id"], env=self.e.env())["items"]), 3)

    def test_taken_capture_is_not_filed_until_put_back(self):
        """v0.8.1: a card dragged out into another app is "taken" (Recently Taken, 7 days), not a card and not deleted:
        filing it is skipped; put back on its thread (`taken: null`, the later line wins) it files as usual."""
        jl = self.s / "shots.jsonl"
        jl.write_text(jl.read_text() + json.dumps({"n": 3, "taken": 1761100500.25}) + "\n")
        out = ok("captures.py", "file", self.s, "--captures", "3", env=self.e.env())
        self.assertEqual((out["items"], out["skipped"]), ([], [{"n": 3, "reason": "taken"}]))
        jl.write_text(jl.read_text() + json.dumps({"n": 3, "taken": None}) + "\n")
        out = ok("captures.py", "file", self.s, "--captures", "3", env=self.e.env())
        self.assertEqual([r["n"] for r in out["items"]], [3])

    def test_project_capture_without_a_note_and_a_retried_card_are_filed(self):
        """v0.9: with a current project a snap without a note is filed there too ("Screenshot 14:32"); a card whose
        words failed remembers its project (`intended_project`) and, once Retry has them, is assigned back and filed
        (the app's lines, later ones winning key by key)."""
        jl = self.s / "shots.jsonl"
        (self.s / "shots/005.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
        (self.s / "shots/006.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
        lines = [{"n": 5, "type": "shot", "file": "shots/005.png", "wall": 1761100400, "text": None, "project": self.p["id"],
                  "assigned_by": "capture"},
                 {"n": 6, "type": "shot", "file": "shots/006.png", "wall": 1761100500, "voice": "shots/006.wav",
                  "project": self.p["id"], "assigned_by": "capture"},
                 {"n": 6, "project": None, "assigned_by": None, "intended_project": self.p["id"]},
                 {"n": 6, "said": "the coupon field is cut off"},
                 {"n": 6, "project": self.p["id"], "assigned_by": "capture", "intended_project": None}]
        jl.write_text(jl.read_text() + "".join(json.dumps(o) + "\n" for o in lines))
        out = ok("captures.py", "file", self.s, "--captures", "5", "6", env=self.e.env())
        made = {r["n"]: r for r in out["items"]}
        self.assertEqual(sorted(made), [5, 6])
        self.assertEqual({r["project"] for r in made.values()}, {self.p["id"]})
        self.assertRegex(made[5]["title"], r"^Screenshot \d\d:\d\d$")
        self.assertEqual(made[6]["title"], "the coupon field is cut off")

    def test_a_type_chosen_in_the_note_is_the_items_kind(self):
        """2026-10-31: the note bubble's type (问题 / 想法 / 笔记 / 待办 → shots.jsonl "kind") is the item's kind, over
        the keyword guess, and stays the user's: the AI fill-in's patch keeps it. Cleared (`"kind": null`, the later
        line winning) or never set, the guess decides as before; a value that isn't one of the four is ignored."""
        jl = self.s / "shots.jsonl"
        for n in (5, 6, 7):
            (self.s / f"shots/00{n}.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
        lines = [{"n": 1, "kind": "idea"},                        # "…is broken" would guess issue
                 {"n": 5, "type": "shot", "file": "shots/005.png", "wall": 1761100400, "text": "Q3 revenue was up",
                  "kind": "task", "project": self.p["id"]},
                 {"n": 6, "type": "shot", "file": "shots/006.png", "wall": 1761100500, "text": "this crashes",
                  "kind": "issue", "project": self.p["id"]},
                 {"n": 6, "kind": None},                          # cleared: undecided again
                 {"n": 7, "type": "shot", "file": "shots/007.png", "wall": 1761100600, "text": "plain words",
                  "kind": "bogus", "project": self.p["id"]}]
        jl.write_text(jl.read_text() + "".join(json.dumps(o) + "\n" for o in lines))
        out = ok("captures.py", "file", self.s, "--captures", "1", "3", "5", "6", "7", env=self.e.env())
        made = {r["n"]: r for r in out["items"]}
        self.assertEqual({n: r["kind"] for n, r in made.items()}, {1: "idea", 3: "note", 5: "task", 6: "issue", 7: "note"})
        a = ok("items.py", "get", made[1]["uid"], env=self.e.env())["item"]
        self.assertEqual(a["kind"], "idea")
        self.assertIn("kind", a.get("_user") or {})
        for n in (3, 6, 7):                                      # undecided: the guess, and nothing kept as the user's
            self.assertNotIn("kind", ok("items.py", "get", made[n]["uid"], env=self.e.env())["item"].get("_user") or {})
        # AI fill-in: its kind doesn't replace the user's, the rest goes in
        p = ok("items.py", "patch", made[1]["uid"], "--set", "kind=issue", "--set", "title=Export does nothing", "--unset",
               "enrich", env=self.e.env())
        self.assertEqual(p.get("kept_user"), ["kind"])
        a = ok("items.py", "get", made[1]["uid"], env=self.e.env())["item"]
        self.assertEqual((a["kind"], a["title"], a.get("enrich")), ("idea", "Export does nothing", None))
        # an undecided one takes the fill-in's kind
        ok("items.py", "patch", made[3]["uid"], "--set", "kind=issue", env=self.e.env())
        self.assertEqual(ok("items.py", "get", made[3]["uid"], env=self.e.env())["item"]["kind"], "issue")

    def test_an_organized_snap_keeps_its_chosen_type(self):
        """Organize (an agent writes items.json, items.py ingest): an item made from a snap the user gave a type is that
        kind whatever the agent guessed — a shots batch and a recording's snaps (⌥A while recording) alike; an item
        from a snap without one keeps the agent's kind. A re-ingest's kind doesn't replace it either."""
        rec = Path(self.p["store"]) / "sessions" / "20261022-110000"
        (rec / "shots").mkdir(parents=True)
        (rec / "recording.mp4").write_bytes(b"mp4")
        (rec / "shots/001.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
        (rec / "shots/002.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
        (rec / "shots.jsonl").write_text(
            json.dumps({"n": 1, "type": "shot", "file": "shots/001.png", "t": 4.2, "wall": 1761100000, "text": "later"}) + "\n"
            + json.dumps({"n": 1, "kind": "task"}) + "\n"
            + json.dumps({"n": 2, "type": "shot", "file": "shots/002.png", "t": 9.0, "wall": 1761100005}) + "\n")
        for session, shot_frames in ((self.s, ("shots/003.png", "shots/001.png")), (rec, ("shots/002.png", "shots/001.png"))):
            if session == self.s:
                jl = self.s / "shots.jsonl"
                jl.write_text(jl.read_text() + json.dumps({"n": 1, "kind": "task"}) + "\n")
            undecided, chosen = shot_frames
            (session / "items.json").write_text(json.dumps({"items": [
                {"id": "I-001", "kind": "issue", "title": "From an undecided snap", "frames": [{"path": undecided}]},
                {"id": "I-002", "kind": "issue", "title": "From a typed snap", "source": {"shot": 1},
                 "frames": [{"path": chosen}]}]}))
            out = ok("items.py", "ingest", session, env=self.e.env())
            uids = {r["local"]: r["uid"] for r in out["items"]}
            a, b = (ok("items.py", "get", uids[k], env=self.e.env())["item"] for k in ("I-001", "I-002"))
            self.assertEqual((a["kind"], b["kind"]), ("issue", "task"), session.name)
            self.assertIn("kind", b.get("_user") or {})
            self.assertNotIn("kind", a.get("_user") or {})
            # the agent writes items.json again (a second pass): the user's type stays
            (session / "items.json").write_text(json.dumps({"items": [
                {"id": "I-002", "kind": "idea", "title": "From a typed snap", "source": {"shot": 1}}]}))
            ok("items.py", "ingest", session, env=self.e.env())
            self.assertEqual(ok("items.py", "get", uids["I-002"], env=self.e.env())["item"]["kind"], "task")

    def test_explicit_project_wins(self):
        other = ok("projects.py", "add", make_repo(self.tmp / "docs"), env=self.e.env())["project"]
        out = ok("captures.py", "file", self.s, "--captures", "3", "--project", other["id"], env=self.e.env())
        self.assertEqual(out["items"][0]["project"], other["id"])
        it = ok("items.py", "get", out["items"][0]["uid"], env=self.e.env())["item"]
        self.assertEqual(it["project"], other["id"])
        self.assertTrue(it["path"].startswith(str(Path(other["store"]))))


    def test_a_project_whose_folder_moved_is_never_made_again(self):
        """dogfood v0.9-2: filing into a project whose folder was moved ran `mkdir -p` on the old path — an empty
        project came back there, BA-1 again beside the moved BA-1…, and opening the moved folder made a second project.
        Now it answers folder_missing and writes nothing; once the folder is located (projects.py add) it files on,
        with the next id."""
        a = self.tmp / "billing-api"
        a.mkdir()
        ba = ok("projects.py", "add", a, env=self.e.env())["project"]
        ok("items.py", "add", "--project", ba["id"], "--json", '{"kind":"issue","title":"first"}', env=self.e.env())
        moved = self.tmp / "billing-api-moved"
        a.rename(moved)
        c, o = run_cli("captures.py", "file", self.s, "--captures", "3", "--project", ba["id"], env=self.e.env())
        self.assertEqual((c, o["code"]), (1, "folder_missing"))
        self.assertFalse(a.exists())                                     # the old folder isn't made again
        self.assertEqual(json.loads((moved / ".blurt" / "store.json").read_text())["next"], 2)
        c, o = run_cli("items.py", "add", "--project", ba["id"], "--json", '{"kind":"note","title":"x"}', env=self.e.env())
        self.assertEqual((c, o["code"], a.exists()), (1, "folder_missing", False))
        # located: the same project at its new place, and the capture files there with the next id
        back = ok("projects.py", "add", moved, env=self.e.env())
        self.assertEqual((back["project"]["id"], back["relocated"]), (ba["id"], str(a.resolve())))
        out = ok("captures.py", "file", self.s, "--captures", "3", "--project", ba["id"], env=self.e.env())
        self.assertEqual(out["items"][0]["id"], "BA-2")

    def test_store_ensure_never_makes_a_project_folder(self):
        gone = self.tmp / "gone"
        with self.assertRaises(st.FolderMissing):
            st.Store(gone / ".blurt").ensure("abc", "GO")
        self.assertFalse(gone.exists())


class Processing(TmpCase):
    def cfg(self, **rec):
        return {"record": rec}

    def test_cheap_model_from_codex_cache(self):
        codex_home = self.tmp / "codex"
        codex_home.mkdir()
        (codex_home / "models_cache.json").write_text(json.dumps({"models": [
            {"slug": "big", "display_name": "Big", "description": "Frontier intelligence", "visibility": "list", "priority": 1},
            {"slug": "hidden-cheap", "description": "Fast and affordable", "visibility": "hide", "priority": 2},
            {"slug": "old-fast", "description": "Older fast and efficient model.", "visibility": "list", "priority": 9},
            {"slug": "luna", "display_name": "Luna", "description": "Fast and affordable model for easier tasks.",
             "visibility": "list", "priority": 5}]}))
        (codex_home / "config.toml").write_text('model = "big"\nmodel_reasoning_effort = "high"\n[x]\nmodel = "no"\n')
        env = {"CODEX_HOME": str(codex_home)}
        m = agents.models("codex", self.cfg(), env)
        self.assertEqual([r["id"] for r in m["models"]], ["big", "luna", "old-fast"])
        self.assertEqual((m["cheapest"], m["cli_default"]), ("luna", "big"))
        p = agents.processing("codex", self.cfg(), env)
        self.assertEqual((p["model"], p["effort"]), ("luna", "low"))
        self.assertEqual(p["args"], ["-m", "luna", "-c", 'model_reasoning_effort="low"'])
        # the user's setting wins; "default" = the CLI's own model
        p = agents.processing("codex", self.cfg(agent_processing={"codex": {"model": "default", "effort": "medium"}}), env)
        self.assertEqual(p["args"], ["-c", 'model_reasoning_effort="medium"'])
        p = agents.processing("claude", self.cfg(), env)
        self.assertEqual(p["args"], ["--model", "haiku", "--effort", "low"])

    def test_recordings_and_cards_have_their_own_model(self):
        """A recording is organized with the CLI's own model at low effort, a batch of cards (and AI fill-in) with the
        cheapest; each is the user's to change (record.agent_processing.<id>.<kind>), and v0.8's one {model, effort}
        still stands for both."""
        rec = agents.processing("claude", self.cfg(), kind="recording")
        self.assertEqual((rec["model"], rec["effort"], rec["args"]), (None, "low", ["--effort", "low"]))
        cards = agents.processing("claude", self.cfg(), kind="cards")
        self.assertEqual((cards["model"], cards["effort"]), ("haiku", "low"))
        self.assertEqual(agents.processing("claude", self.cfg())["model"], "haiku")  # cards unless said otherwise
        mine = self.cfg(agent_processing={"claude": {"recording": {"model": "opus", "effort": "medium"},
                                                     "cards": {"model": "sonnet"}}})
        self.assertEqual(agents.processing("claude", mine, kind="recording")["args"], ["--model", "opus", "--effort", "medium"])
        self.assertEqual(agents.processing("claude", mine, kind="cards")["args"], ["--model", "sonnet", "--effort", "low"])
        old = self.cfg(agent_processing={"claude": {"model": "sonnet", "effort": "high"}})
        for k in agents.KINDS:
            self.assertEqual(agents.processing("claude", old, kind=k)["args"], ["--model", "sonnet", "--effort", "high"], k)
        out = agents.command("claude", "headless", "hi", self.tmp, events=False, mcp=False, processing_run="recording",
                             cfg=self.cfg())
        self.assertEqual(out["processing"], {"model": None, "effort": "low"})
        self.assertNotIn("--model", out["argv"])

    def test_command_processing_adds_model_and_usage_flags(self):
        out = agents.command("claude", "headless", "hi", self.tmp, events=False, mcp=False, processing_run=True,
                             cfg=self.cfg())
        self.assertEqual(out["argv"][-6:], ["--model", "haiku", "--effort", "low", "--output-format", "json"])
        self.assertEqual((out["processing"], out["usage"]), ({"model": "haiku", "effort": "low"}, "claude-json"))
        plain = agents.command("claude", "headless", "hi", self.tmp, events=False, mcp=False, cfg=self.cfg())
        self.assertNotIn("--model", plain["argv"])

    def test_parse_usage(self):
        defs = agents.definitions(self.cfg())
        codex_log = "codex\nhi\ntokens used\n19,006\nhi\n"
        self.assertEqual(agents.parse_usage(defs["codex"], codex_log), {"tokens": 19006})
        self.assertEqual(agents.parse_usage(defs["codex"], "tokens used: 1 234\n"), {"tokens": 1234})
        claude = json.dumps({"type": "result", "result": "ok", "usage": {"input_tokens": 10, "cache_read_input_tokens": 2000,
                                                                         "cache_creation_input_tokens": 300, "output_tokens": 45}})
        self.assertEqual(agents.parse_usage(defs["claude"], "noise\n" + claude + "\n"),
                         {"tokens": 2355, "input": 2310, "output": 45})
        jsonl = "\n".join(json.dumps(o) for o in [{"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 5}},
                                                  {"type": "turn.completed", "usage": {"input_tokens": 50, "output_tokens": 5}}])
        self.assertEqual(agents.parse_usage({}, jsonl)["tokens"], 160)
        self.assertIsNone(agents.parse_usage(defs["codex"], "nothing here"))
        f = self.tmp / "agent.log"
        f.write_text("old run\ntokens used\n99\n── new run\n" + codex_log)
        off = len("old run\ntokens used\n99\n".encode())
        self.assertEqual(ok("agents.py", "usage", "codex", f, "--offset", off, env=self.e.env())["usage"], {"tokens": 19006})

    def test_session_command_model(self):
        stub = self.tmp / "bin"
        stub.mkdir()
        for b in ("codex", "claude", "kimi"):
            (stub / b).write_text("#!/bin/sh\nexit 0\n")
            (stub / b).chmod(0o755)
        env = {"PATH": str(stub)}
        c = agents.session_command("codex", "do it", self.tmp, job="j-1", mcp=False, model="luna", cfg=self.cfg(), env=env)
        self.assertEqual(c["argv"][-5:], ["-m", "luna", "-c", "check_for_update_on_startup=false", "do it"])
        c = agents.session_command("claude", "do it", self.tmp, job="j-1", mcp=False, model="sonnet", cfg=self.cfg(),
                                   env=env, settings=self.tmp / "s.json")
        self.assertEqual(c["argv"][-4:], ["--model", "sonnet", "--", "do it"])
        c = agents.session_command("codex", "do it", self.tmp, job="j-1", mcp=False, model="default", cfg=self.cfg(), env=env)
        self.assertNotIn("-m", c["argv"])
        with self.assertRaisesRegex(ValueError, "can't be given a model"):
            agents.session_command("kimi", "x", self.tmp, job="j-1", mcp=False, model="m", cfg=self.cfg(), env=env)
