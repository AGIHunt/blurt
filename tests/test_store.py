"""The Markdown item store (contract K1): the file format (front-matter + sections) and its round trip, files edited
by hand or by other tools, slugs and ids, the store counter, .git/info/exclude.

Shared helpers for the storage tests live here too (Env, run_cli, make_repo, copy_fixtures_into_store).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
FIXTURES = ROOT / "tests" / "fixtures"
sys.path.insert(0, str(SCRIPTS))
import store as st  # noqa: E402

V1, SHOTS, V2 = "20261019-093000", "20261020-141500-shots", "20261021-101500"


# ------------------------------------------------------------------ shared helpers
def git(cwd: Path, *args) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
                          env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}).stdout


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", ".")
    (path / "README.md").write_text("hi\n")
    git(path, "add", "README.md")
    git(path, "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "-m", "init")
    return path


class Env:
    """A private BLURT_HOME / BLURT_WORKSPACE (never the user's), set for this process and for CLI children."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home = tmp / "blurt-home"
        self.ws = tmp / "Blurt"
        self.home.mkdir(parents=True, exist_ok=True)
        (self.home / "config.json").write_text(json.dumps({"record": {"install_app": False}, "lang": "en"}))
        self.vars = {"BLURT_HOME": str(self.home), "BLURT_WORKSPACE": str(self.ws),
                     "BLURT_NO_INDEX": "1", "BLURT_AGENT": "", "BLURT_JOB": "", "BLURT_RUN_ID": "",
                     "BLURT_PROJECT": ""}
        self._patch = patch.dict(os.environ, self.vars)

    def __enter__(self):
        self._patch.start()
        import items  # noqa: PLC0415
        items._NAMES = None
        st._MAPS.clear()
        return self

    def __exit__(self, *exc):
        self._patch.stop()

    def env(self, **extra) -> dict:
        e = {**os.environ, **self.vars, **{k: str(v) for k, v in extra.items()}}
        return {k: v for k, v in e.items() if v != "" or k not in self.vars}


def run_cli(script: str, *args, env: dict, stdin: str | None = None) -> tuple[int, dict]:
    p = subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, args)], capture_output=True, text=True,
                       encoding="utf-8", timeout=120, input=stdin, env=env)
    lines = p.stdout.strip().splitlines()
    assert len(lines) == 1, f"expected one JSON line, got {p.stdout!r} / {p.stderr!r}"
    return p.returncode, json.loads(lines[0])


def ok(script: str, *args, env: dict, **kw) -> dict:
    code, out = run_cli(script, *args, env=env, **kw)
    assert code == 0 and out.get("ok") is not False, out
    return out


def copy_session(name: str, dest_sessions: Path) -> Path:
    d = dest_sessions / name
    shutil.copytree(FIXTURES / "sessions" / name, d)
    return d


class TmpCase(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory()
        self.addCleanup(t.cleanup)
        self.tmp = Path(os.path.realpath(t.name))
        self.e = Env(self.tmp)
        self.e.__enter__()
        self.addCleanup(self.e.__exit__)


# ------------------------------------------------------------------ the format
FULL = {"id": "BA-12", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABCD", "kind": "issue", "title": "登录按钮点击后无响应",
        "state": "new", "work": {"to": None, "agent": None, "job": None, "handoff": None,
                                 "claim": None, "note": "", "commit": None, "pr": None, "at": None, "by": None},
        "project": "3f2a9c1b7e44", "project_by": "capture", "project_confidence": None,
        "created": "2026-10-22T10:15:00+08:00", "updated": "2026-10-22T10:20:41+08:00",
        "source": {"type": "recording", "by": "john", "role": None, "app": "Chrome", "url": "https://example.test/a b",
                   "session": "/x/.blurt/sessions/20261022-101500", "shot": None, "local_id": "I-001"},
        "language": "zh", "severity": "high", "module": "auth", "owner": "", "assignee": None, "tags": ["登录"],
        "confidence": "high", "time": {"start": 12.4, "end": 30.1},
        "frames": [{"path": "assets/01JB7ZK3Q4M8W2E5R6T9Y0ABCD/1.png", "t": 74.2, "caption": "登录按钮是灰的 [x]"}],
        "clip": "assets/01JB7ZK3Q4M8W2E5R6T9Y0ABCD/clip.mp4", "code_refs": ["web/src/Login.tsx:42"], "exported": {},
        "merged_into": None, "merged_from": [], "aliases": ["IN-3"], "work_history": [], "_user": {"title": 1792560123.4},
        "quote": "这个按钮点了没反应\n\n第二段", "summary": "s", "why": "w", "inspired_by": "i", "actual": "a",
        "expected": "e", "steps": ["打开 /login", "点击登录\n  还是没反应"], "details": "## 不是小节\n```\n## code\n```\n**粗**",
        "next_steps": ["- 嵌套"], "open_questions": ["q1"], "questions": ["Safari 也这样吗？"], "answer": "是",
        "competitor_notes": "长文本\n第二行", "next": "试 fzf", "yes_string": "yes", "num_string": "1e44",
        "type": "bug"}


class Format(unittest.TestCase):
    def test_round_trip_every_field(self):
        text = st.render(FULL)
        back = st.parse(text)
        self.assertEqual(back, {**FULL, "schema": 3})
        self.assertEqual(st.render(back), text)  # stable

    def test_front_matter_shape(self):
        text = st.render(FULL)
        fm = text.split("---\n")[1].splitlines()
        keys = [ln.split(":", 1)[0] for ln in fm]
        fixed = [k for k in st.FM_ORDER if k in keys]
        self.assertEqual(keys[:len(fixed)], fixed)  # the fixed order first …
        rest = keys[len(fixed):]
        self.assertEqual(rest, sorted(rest))  # … then the unknown keys, alphabetically
        self.assertEqual(keys[0], "schema")
        line = dict(ln.split(": ", 1) for ln in fm)
        self.assertEqual(line["id"], "BA-12")  # plain strings stay bare
        self.assertEqual(line["title"], '"登录按钮点击后无响应"')
        self.assertEqual(line["created"], '"2026-10-22T10:15:00+08:00"')  # dates quoted: still strings in any YAML
        self.assertEqual(line["yes_string"], '"yes"')
        self.assertEqual(line["num_string"], '"1e44"')
        self.assertEqual(line["project_confidence"], "null")
        for ln in fm:  # every value is one line of JSON (or a bare safe string)
            v = ln.split(": ", 1)[1]
            if v[0] in '{["' or v in ("null", "true", "false"):
                json.loads(v)

    def test_sections_by_language(self):
        zh = st.render(FULL)
        for h in ("## 原话", "## 概要", "## 为什么", "## 灵感来源", "## 实际效果", "## 预期效果", "## 复现步骤",
                  "## 详情", "## 下一步", "## 待定问题", "## 需要你确认", "## 你的回答", "## 截图",
                  "## competitor_notes"):
            self.assertIn("\n" + h + "\n", zh)
        en = st.render({**FULL, "language": "en"})
        for h in ("## Said", "## Summary", "## Steps", "## Questions for you", "## Your answer", "## Screenshots"):
            self.assertIn("\n" + h + "\n", en)
        self.assertNotIn("\n# ", zh)  # no H1: the title is in the front-matter
        self.assertIn("> 这个按钮点了没反应\n>\n> 第二段", zh)
        self.assertIn("1. 打开 /login\n2. 点击登录\n", zh)
        self.assertIn("![登录按钮是灰的 (x) · 1:14](../assets/01JB7ZK3Q4M8W2E5R6T9Y0ABCD/1.png)", zh)
        # the section order of the contract
        order = [zh.index(h) for h in ("## 原话", "## 概要", "## 复现步骤", "## 详情", "## 你的回答",
                                       "## competitor_notes", "## 截图")]
        self.assertEqual(order, sorted(order))
        # a zh file reads back in en and the other way round
        self.assertEqual(st.parse(en)["steps"], FULL["steps"])

    def test_empty_fields_are_left_out(self):
        text = st.render({"id": "IN-1", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABCE", "kind": "note", "title": "t",
                          "quote": "", "steps": [], "answer": None, "due": None})
        self.assertNotIn("##", text)
        self.assertEqual(set(st.parse(text)), {"schema", "id", "uid", "kind", "title", "state"})

    def test_values_that_cant_be_sections_stay_in_front_matter(self):
        it = {"id": "IN-1", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABCE", "kind": "note", "title": "t",
              "questions": [{"q": "a", "a": "b"}], "steps": [1, 2], "answer": 42, "short_custom": "x" * 200}
        back = st.parse(st.render(it))
        self.assertEqual({k: back[k] for k in it}, it)
        self.assertNotIn("## short_custom", st.render(it))  # ≤ 200 chars, one line: front-matter

    def test_slug(self):
        self.assertEqual(st.slugify("登录按钮点击后无响应"), "登录按钮点击后无响应")
        self.assertEqual(st.slugify("  Login (Safari) — doesn't work!! "), "login-safari-doesn-t-work")
        self.assertEqual(st.slugify("ＡＢＣ１２３"), "abc123")  # NFKC
        self.assertEqual(st.slugify("Café über Straße"), "café-über-straße")
        self.assertEqual(st.slugify("ログインボタンが反応しない"), "ログインボタンが反応しない")
        self.assertEqual(st.slugify("!!!"), "")
        long = st.slugify("a" * 30 + " " + "b" * 30)
        self.assertEqual(len(long), 48)
        self.assertFalse(long.endswith("-"))
        self.assertEqual(st.slugify("界" * 60), "界" * 48)  # characters, not bytes
        self.assertEqual(st.item_filename("BA-12", "Login"), "BA-12-login.md")
        self.assertEqual(st.item_filename("BA-12", "…"), "BA-12.md")


class HandEdits(TmpCase):
    def write(self, name: str, text: str) -> Path:
        p = self.tmp / "items" / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p

    def test_hand_edited_file_reads_back(self):
        """Edited in a Markdown editor: a section moved and reworded, a section the user added, a block YAML list."""
        p = self.write("BA-1-x.md", (FIXTURES / "stores" / "hand-edited" / "BA-1-login.md").read_text())
        item = st.read_item(p)
        self.assertEqual(item["tags"], ["login", "safari"])  # block list from another tool
        self.assertEqual(item["title"], "Login button does nothing")
        self.assertEqual(item["steps"], ["Open /login", "Click Sign in"])
        self.assertEqual(item["expected"], "It signs in.")  # heading case and spaces don't matter
        self.assertEqual(item["quote"], "the login button does nothing")
        self.assertEqual(item["_sections"], [["My notes", "Check with **Amy**."]])
        self.assertEqual(item["owner"], "amy")
        # written back: the user's section survives, the format is ours again, and it still reads the same
        again = st.parse(st.render(item))
        self.assertEqual({k: v for k, v in again.items() if k != "schema"},
                         {k: v for k, v in item.items() if k != "schema"})
        self.assertIn("## My notes\n\nCheck with **Amy**.", st.render(item))

    def test_unparseable_files_are_never_overwritten(self):
        bad = (FIXTURES / "stores" / "hand-edited" / "BA-2-broken.md").read_text()
        p = self.write("BA-2-broken.md", bad)
        with self.assertRaises(st.Unparseable):
            st.read_item(p)
        for text in ("no front-matter", "---\nid: X\n", "---\nuid: 01JB7ZK3Q4M8W2E5R6T9Y0ABCD\nx: {nope\n---\n",
                     "---\nuid: 01JB7ZK3Q4M8W2E5R6T9Y0ABCD\nuid: again\n---\n", "---\ntitle: no uid\n---\n"):
            with self.assertRaises(st.Unparseable, msg=text):
                st.parse(text)
        # items.py refuses to write it (code unparseable) and leaves the bytes alone
        s = st.Store(self.tmp)
        (self.tmp / "store.json").write_text(json.dumps({"schema": 3, "project": "inbox", "key": "BA", "next": 3}))
        code, out = run_cli("items.py", "patch", str(p), "--set", "owner=x", env=self.e.env())
        self.assertEqual((code, out["code"]), (1, "unparseable"))
        self.assertEqual(p.read_text(), bad)
        self.assertIsNone(s.find(uid="01JB7ZK3Q4M8W2E5R6T9Y0ABCD"))


class StoreBasics(TmpCase):
    def test_ids_counter_and_lookup(self):
        (self.tmp / "proj").mkdir()      # a project store is made only inside a folder that is there
        s = st.Store(self.tmp / "proj" / ".blurt")
        self.assertTrue(s.ensure("p1", "PR"))
        self.assertFalse(s.ensure("p1", "PR"))
        with s.lock():
            ids = [s.next_id() for _ in range(3)]
        self.assertEqual(ids, ["PR-1", "PR-2", "PR-3"])
        st.write_item(s.items_dir / "PR-2-two.md", {"id": "PR-2", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABC2", "kind": "note",
                                                     "title": "two", "aliases": ["IN-7"]})
        self.assertEqual(s.path_for_id("PR-2").name, "PR-2-two.md")
        self.assertEqual(s.find(uid="01JB7ZK3Q4M8W2E5R6T9Y0ABC2").name, "PR-2-two.md")
        self.assertEqual(s.find(alias="IN-7").name, "PR-2-two.md")
        self.assertIsNone(s.find(uid="01JB7ZK3Q4M8W2E5R6T9Y0ABC9"))
        # a file that appears later is found (the uid map follows the folder)
        st.write_item(s.items_dir / "PR-3.md", {"id": "PR-3", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABC3", "kind": "note",
                                                "title": "three"})
        self.assertEqual(s.find(uid="01JB7ZK3Q4M8W2E5R6T9Y0ABC3").name, "PR-3.md")
        # a counter that went back (restored from a backup) never hands out an id that exists
        s.set_meta(next=2)
        with s.lock():
            self.assertEqual(s.next_id(), "PR-4")
        self.assertEqual(json.loads((s.root / "store.json").read_text())["next"], 5)
        self.assertEqual(st.Store(st.inbox_root()).key, "IN")


class GitExclude(TmpCase):
    def test_exclude_written_once_and_git_status_clean(self):
        repo = make_repo(self.tmp / "repo")
        out = ok("projects.py", "add", repo, env=self.e.env())
        self.assertTrue(out["created"] and out["project"]["git"])
        exclude = repo / ".git" / "info" / "exclude"
        text = exclude.read_text()
        self.assertIn(st.EXCLUDE_COMMENT + "\n/.blurt/\n", text)
        self.assertFalse((repo / ".gitignore").exists())  # never touched
        # items, assets and sessions under .blurt are invisible to git
        (repo / ".blurt" / "sessions" / "s1").mkdir(parents=True)
        (repo / ".blurt" / "sessions" / "s1" / "recording.mp4").write_bytes(b"x")
        ok("items.py", "add", "--project", out["project"]["id"], "--json", '{"kind":"note","title":"hello"}',
           env=self.e.env())
        self.assertEqual(git(repo, "status", "--porcelain"), "")
        # idempotent: opening the folder again, migrating, or a store write add nothing
        ok("projects.py", "add", repo, env=self.e.env())
        st.ensure_git_exclude(repo)
        self.assertEqual(exclude.read_text(), text)
        self.assertEqual(text.count("/.blurt/"), 1)

    def test_subfolder_project_and_worktree(self):
        repo = make_repo(self.tmp / "mono")
        (repo / "apps" / "web").mkdir(parents=True)
        self.assertEqual(st.ensure_git_exclude(repo / "apps" / "web"), "/apps/web/.blurt/")
        self.assertIsNone(st.ensure_git_exclude(repo / "apps" / "web"))
        wt = self.tmp / "wt"
        git(repo, "worktree", "add", "-q", str(wt), "-b", "side")
        self.assertEqual(st.ensure_git_exclude(wt), "/.blurt/")  # the common dir's exclude, shared by worktrees
        self.assertIn("/.blurt/", (repo / ".git" / "info" / "exclude").read_text())
        (wt / ".blurt").mkdir()
        (wt / ".blurt" / "x.md").write_text("x")
        self.assertEqual(git(wt, "status", "--porcelain"), "")

    def test_a_line_the_user_wrote_counts(self):
        repo = make_repo(self.tmp / "own")
        exclude = repo / ".git" / "info" / "exclude"
        exclude.write_text(exclude.read_text() + ".blurt/\n")
        self.assertIsNone(st.ensure_git_exclude(repo))
        self.assertIsNone(st.ensure_git_exclude(self.tmp))  # not a git work tree: nothing to do

    def test_tracked_files_are_reported_not_untracked(self):
        repo = make_repo(self.tmp / "tracked")
        (repo / ".blurt").mkdir()
        (repo / ".blurt" / "config.json").write_text("{}")
        git(repo, "add", "-f", ".blurt/config.json")
        st.ensure_git_exclude(repo)
        self.assertEqual(st.tracked_store_files(repo), [".blurt/config.json"])
        self.assertIn(".blurt/config.json", git(repo, "ls-files"))


if __name__ == "__main__":
    unittest.main()
