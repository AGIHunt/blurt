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
    assert "`mark_fixed`" in text and "items.py work <uid> --state to_verify --claim fixed" in text
    assert "Don't push" in text
    assert f"## 1. {a['id']} · Login button 0" in text and "uid " + a["uid"] + " · issue · high · module auth" in text
    assert "**They said**\n> I click login and nothing happens" in text and "1. Open the page\n2. Click Login" in text
    assert "**Suspected code** `web/src/Login.tsx:42`" in text
    images = re.findall(r"!\[([^\]]*)\]\(<?([^)>]+)>?\)", text)
    assert len(images) == 2 and images[0][0] == "Frame 1 · 0:14 — login button greyed out"
    for _, path in images:  # absolute, and they exist
        assert Path(path).is_absolute() and Path(path).is_file()
    assert out["instruction"] == (f"Please handle these 2 items — details and screenshots are in {note}. When you're done, "
                                  "call mark_fixed for each if the blurt MCP is available.")
    assert out["full"] == text.split("---\n", 2)[2].lstrip("\n") and not out["full"].startswith("---")
    one = p2.run("handoff.py", "create", "--items", a["uid"], "--lang", "en")
    assert one["id"] != out["id"] and one["instruction"] == (
        f"Please handle {a['id']} — details and screenshots are in {one['path']}. When you're done, call mark_fixed if "
        "the blurt MCP is available.")
    assert p2.get(a["uid"])["work"]["state"] == "todo"  # not marked without --mark
    got = p2.run("handoff.py", "get", out["id"])
    assert {k: got[k] for k in ("id", "path", "instruction", "full", "items")} == \
        {k: out[k] for k in ("id", "path", "instruction", "full", "items")}


def test_zh_and_mark(p2):
    proj = p2.project(p2.repo())
    (a,) = items_with_frames(p2, proj["id"], 1)
    out = p2.run("handoff.py", "create", "--items", a["uid"], "--lang", "zh", "--mark")
    assert out["instruction"] == f"请处理 {a['id']}，详情和截图见 {out['path']}。做完后如果有 blurt MCP，调用 mark_fixed。"
    text = Path(out["path"]).read_text()
    assert "项目文件夹：" in text and "**原话**" in text and "**复现步骤**" in text and "截图 1 · 0:14" in text
    assert "uid " + a["uid"] + " · 问题 · 高 · 模块 auth" in text
    w = p2.get(a["uid"])["work"]
    assert w["state"] == "handed_off" and w["to"] == "external" and w["handoff"] == out["id"] and w["by"] == "user"
    many = p2.run("handoff.py", "create", "--items", a["uid"], p2.item(proj["id"])["uid"], "--lang", "zh")
    assert many["instruction"].startswith("请处理这 2 个条目，详情和截图见 ") and "逐条调用 mark_fixed" in many["instruction"]


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
    assert p2.run("handoff.py", "create", "--items", "x", "--to", "session", "--mark", ok=False)["code"] == "bad_args"
