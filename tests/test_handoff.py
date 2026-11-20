"""handoff.py (contract K6): the note an agent reads, the one-line instruction, --mark. Temp BLURT_HOME only.

  uv run --with pytest pytest tests/test_handoff.py -q
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import p2  # noqa: E402,F401


def items_with_frames(p2, proj, n=2):
    shots = p2.tmp / "shots"
    shots.mkdir(exist_ok=True)
    out = []
    for i in range(n):
        it = p2.item(proj, title=f"Login button {i}", severity="high", module="auth", actual="Nothing happens",
                     expected="It signs in", steps=["Open the page", "Click Login"], code_refs=["web/src/Login.tsx:42"])
        png = shots / f"frame {i}.png"  # a space in the path
        png.write_bytes(b"\x89PNG\r\n\x1a\nfake")
        p2.run("items.py", "set-frames", it["uid"], f"{png}@14.2#login button greyed out")
        out.append(it)
    return out


def test_note_and_instruction_en(p2):
    repo = p2.repo()
    proj = p2.project(repo)
    a, b = items_with_frames(p2, proj["id"])
    out = p2.run("handoff.py", "create", "--items", a["uid"], b["id"], "--lang", "en")
    assert re.fullmatch(r"H-\d{4}", out["id"]) and out["items"] == [a["uid"], b["uid"]]
    note = Path(out["path"])
    assert note == p2.home / "handoff" / f"{out['id']}.md"
    text = note.read_text()
    fm = text.split("---\n")[1]
    assert f"handoff: {out['id']}" in fm and "to: external" in fm and "lang: en" in fm
    assert json.loads(re.search(r"^project: (.*)$", fm, re.M).group(1)) == {"id": proj["id"], "name": proj["name"],
                                                                              "path": proj["path"]}
    assert f"# 2 items for {proj['name']}" in text and f"Project folder: {proj['path']}" in text
    assert "`mark_fixed`" in text and "items.py' state <uid> --state to_verify --claim fixed" in text
    # the fallback is for a call that fails too (Codex with approval "never"), and it starts with In progress
    assert "a call fails" in text and "items.py' state <uid> --state in_progress --agent <name>" in text
    assert "Don't push" in text
    assert f"## 1. {a['id']} · Login button 0" in text and "uid " + a["uid"] + " · issue · high · module auth" in text
    assert "**They said**\n> I click login and nothing happens" in text and "1. Open the page\n2. Click Login" in text
    assert "**Suspected code** `web/src/Login.tsx:42`" in text
    images = re.findall(r"!\[([^\]]*)\]\(<?([^)>]+)>?\)", text)
    assert len(images) == 2 and images[0][0] == "Frame 1 · 0:14 — login button greyed out"
    for _, path in images:  # absolute, and they exist
        assert Path(path).is_absolute() and Path(path).is_file()
    assert out["instruction"] == (f"Please handle these 2 items — details and screenshots are in {note}. Report back on "
                                  "each with the blurt MCP tool mark_fixed when you start and when you're done; if that "
                                  "fails, run the command in the note.")
    assert out["full"] == text.split("---\n", 2)[2].lstrip("\n") and not out["full"].startswith("---")
    one = p2.run("handoff.py", "create", "--items", a["uid"], "--lang", "en")
    assert one["id"] != out["id"] and one["instruction"] == (
        f"Please handle {a['id']} — details and screenshots are in {one['path']}. Report back with the blurt MCP tool "
        "mark_fixed when you start and when you're done; if that fails, run the command in the note.")
    # one item: its own uid in the commands, nothing to fill in but the agent's name
    assert f"items.py' state {a['uid']} --state to_verify --claim fixed" in Path(one["path"]).read_text()
    assert p2.get(a["uid"])["state"] == "new"  # not marked without --mark
    got = p2.run("handoff.py", "get", out["id"])
    assert {k: got[k] for k in ("id", "path", "instruction", "full", "items")} == \
        {k: out[k] for k in ("id", "path", "instruction", "full", "items")}


def test_zh_and_mark(p2):
    proj = p2.project(p2.repo())
    (a,) = items_with_frames(p2, proj["id"], 1)
    out = p2.run("handoff.py", "create", "--items", a["uid"], "--lang", "zh", "--mark")
    assert out["instruction"] == (f"请处理 {a['id']}，详情和截图见 {out['path']}。开始和做完时用 blurt MCP 工具 mark_fixed "
                                  "报告；调用失败就运行说明里的命令。")
    text = Path(out["path"]).read_text()
    assert "项目文件夹：" in text and "**原话**" in text and "**复现步骤**" in text and "截图 1 · 0:14" in text
    assert "uid " + a["uid"] + " · 问题 · 高 · 模块 auth" in text
    w = p2.get(a["uid"])["work"]
    assert p2.get(a["uid"])["state"] == "handed_off"
    assert w["to"] == "external" and w["handoff"] == out["id"] and w["by"] == "user"
    many = p2.run("handoff.py", "create", "--items", a["uid"], p2.item(proj["id"])["uid"], "--lang", "zh")
    assert many["instruction"].startswith("请处理这 2 个事项，详情和截图见 ") and "逐条报告" in many["instruction"]


def test_ids_never_repeat(p2):
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    first = p2.run("handoff.py", "create", "--items", it["uid"])["id"]
    (p2.home / "handoff" / ".seq").unlink()  # a lost counter
    second = p2.run("handoff.py", "create", "--items", it["uid"])["id"]
    assert int(second[2:]) == int(first[2:]) + 1


def test_mixed_projects_and_inbox(p2):
    pa = p2.project(p2.repo("one"))
    pb = p2.project(p2.repo("two"))
    a, b = p2.item(pa["id"]), p2.item(pb["id"])
    inbox = p2.run("items.py", "add", "--project", "inbox", "--json", json.dumps({"kind": "idea", "title": "Dark mode",
                                                                                   "summary": "Add a dark theme"}))
    out = p2.run("handoff.py", "create", "--items", a["uid"], b["uid"], inbox["uid"], "--lang", "en")
    text = Path(out["path"]).read_text()
    assert "# 3 items\n" in text and "Project folder" not in text and "project: null" in text
    assert f"project {pa['name']}" in text and f"project {pb['name']}" in text
    assert "**Summary**\nAdd a dark theme" in text
    solo = p2.run("handoff.py", "create", "--items", inbox["uid"], "--lang", "en")
    assert "Project folder" not in Path(solo["path"]).read_text()


def test_errors(p2):
    assert p2.run("handoff.py", "create", "--items", "nope", ok=False)["_exit"] == 1
    assert p2.run("handoff.py", "get", "H-9999", ok=False)["code"] == "no_handoff"
    assert p2.run("handoff.py", "get", "../x", ok=False)["code"] == "bad_args"
    assert p2.run("handoff.py", "create", "--items", "x", "--to", "session", ok=False)["code"] == "bad_args"


def test_prompt_work_points_at_the_note(p2):
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    out = p2.run("agents.py", "prompt", "work", "--items", it["uid"], "--lang", "en")
    # the first line is a human title (what Codex / Claude list the conversation as), then the instructions
    title, blank, rest = out["prompt"].split("\n", 2)
    assert title == f"{it['id']} · The login button does nothing (Blurt hand-off)" == out["title"] and blank == ""
    assert rest.startswith(f"Read {out['path']} and handle the items in it.")
    assert "don't commit unless the user asks" in out["prompt"] and "mark_fixed" in out["prompt"]
    note = Path(out["path"]).read_text()
    assert "to: external" in note and "branch:" not in note and "uv run" not in note  # no sandbox prompt for uv
    assert p2.get(it["uid"])["state"] == "new"  # a prompt marks nothing
    zh = p2.run("agents.py", "prompt", "work", "--items", it["uid"], "--handoff", out["handoff"], "--lang", "zh")
    zt, _, zrest = zh["prompt"].split("\n", 2)
    assert zt == f"{it['id']} · The login button does nothing（口喷鸡交接）"
    assert zh["handoff"] == out["handoff"] and zrest.startswith(f"读 {out['path']}，") and "不要推送" in zh["prompt"]
    two = p2.item(proj["id"], title="Second\nline")
    many = p2.run("agents.py", "prompt", "work", "--items", it["uid"], two["uid"], "--lang", "en")
    assert many["prompt"].split("\n", 1)[0] == f"2 items · {proj['name']} (Blurt hand-off)"


def test_work_title_rules():
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
    import agents
    one = {"id": "AW-12", "uid": "u1", "title": "  Login\n button   does nothing  "}
    assert agents.work_title([one], "Atlas", "en") == "AW-12 · Login button does nothing (Blurt hand-off)"
    assert agents.work_title([one], "Atlas", "zh-Hans") == "AW-12 · Login button does nothing（口喷鸡交接）"
    # a long title is cut, never the id or the suffix; the whole line stays one line within TITLE_MAX
    long = agents.work_title([{**one, "title": "x" * 400}], None, "en")
    assert long.startswith("AW-12 · xxx") and long.endswith("… (Blurt hand-off)") and len(long) <= agents.TITLE_MAX
    assert "\n" not in long
    assert agents.work_title([{"uid": "abcdef0123", "title": ""}], None, "en") == "abcdef01 (Blurt hand-off)"
    assert agents.work_title([one, {**one, "id": "AW-13"}], "Atlas Web", "en") == "2 items · Atlas Web (Blurt hand-off)"
    assert agents.work_title([one, one, one], "口喷鸡 iOS", "zh") == "3 个事项 · 口喷鸡 iOS（口喷鸡交接）"
    assert agents.work_title([one, one], None, "en") == "2 items (Blurt hand-off)"


def test_done_when_and_who_reports(p2):
    """A task's Done when (its `expected`, as the page names it) reaches the agent under that name; the fallback's
    report names the agent that ran it, and the user's own hand-off never credits one."""
    proj = p2.project(p2.repo())
    task = p2.run("items.py", "add", "--project", proj["id"], "--json", json.dumps(
        {"kind": "task", "title": "Write hello", "details": "Add hello.txt", "expected": "hello.txt says hi"}))
    out = p2.run("handoff.py", "create", "--items", task["uid"], "--lang", "en", "--mark")
    text = Path(out["path"]).read_text()
    assert "**Done when**\nhello.txt says hi" in text and "**Expected**" not in text
    assert text.index("**Details**") < text.index("**Done when**")
    zh = Path(p2.run("handoff.py", "create", "--items", task["uid"], "--lang", "zh")["path"]).read_text()
    assert "**完成标准**\nhello.txt says hi" in zh
    issue = p2.item(proj["id"], expected="It signs in")
    assert "**Expected**\nIt signs in" in Path(p2.run("handoff.py", "create", "--items", issue["uid"], "--lang", "en")["path"]).read_text()
    w = p2.get(task["uid"])["work"]
    assert w["agent"] == "human" and w["by"] == "user"
    # the note's fallback without --agent: no name, never the user's "human"
    p2.run("items.py", "state", task["uid"], "--state", "in_progress")
    assert p2.get(task["uid"])["work"]["agent"] is None
    p2.run("items.py", "state", task["uid"], "--state", "to_verify", "--claim", "fixed", "--agent", "codex")
    assert p2.get(task["uid"])["work"]["agent"] == "codex"
    # the user's own change after it is the user's, not "Done by Codex"
    p2.run("items.py", "state", task["uid"], "--action", "done", "--by", "user")
    w = p2.get(task["uid"])["work"]
    assert w["agent"] == "human" and w["by"] == "user"


def test_undo_skips_items_an_agent_moved(p2):
    """⌘Z's state step names the state it left the item in: an item an agent has moved on since keeps its report."""
    proj = p2.project(p2.repo())
    a, b = p2.item(proj["id"]), p2.item(proj["id"])
    p2.run("items.py", "state", a["uid"], b["uid"], "--action", "keep", "--by", "user")
    p2.run("handoff.py", "create", "--items", a["uid"], b["uid"], "--mark")
    p2.run("items.py", "state", a["uid"], "--state", "to_verify", "--claim", "fixed", "--agent", "codex")
    out = p2.run("items.py", "state", a["uid"], b["uid"], "--state", "todo", "--by", "user", "--undo",
                 "--from-state", "handed_off")
    assert out["kept"] == [{"uid": a["uid"], "id": a["id"], "state": "to_verify"}]
    assert [i["uid"] for i in out["items"]] == [b["uid"]]
    assert p2.get(a["uid"])["state"] == "to_verify" and p2.get(b["uid"])["state"] == "todo"
    assert p2.get(b["uid"])["work"] == {"state": "todo"}  # (no work key) its first hand-off taken back: no hand-off record left behind
