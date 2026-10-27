"""export_local.py bundle: the hand-off bundle — one self-contained .zip (summary.md, items/*.md, frames/, clips/)
with only relative paths, named "<project>-<date>-<n items>.zip", by REF or by a project filter. Temp BLURT_HOME only.

  uv run --with pytest pytest tests/test_bundle.py -q
"""
from __future__ import annotations

import re
import sys
import zipfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import SCRIPTS, p2  # noqa: E402,F401

sys.path.insert(0, str(SCRIPTS))
import export_local  # noqa: E402

TODAY = date.today().isoformat()


def seed(p2, n=3):
    """A project "Checkout Web" with issues (frames, a clip, code refs) and an idea, in several states."""
    repo = p2.repo("checkout")
    proj = p2.project(repo, name="Checkout Web")
    media = p2.tmp / "media files"  # a space in the path
    media.mkdir()
    out = []
    for i in range(n):
        it = p2.item(proj["id"], title=f"Pay button {i} does nothing", module="payment" if i else "cart",
                     owner="Ana", severity="high", actual="Nothing happens", expected="It pays",
                     steps=["Open the cart", "Click Pay"], code_refs=[f"web/src/Pay{i}.tsx:42"],
                     quote=f"I click pay and nothing happens ({i})")
        png = media / f"pay {i}.png"
        png.write_bytes(b"\x89PNG\r\n\x1a\nframe" + bytes([i]))
        p2.run("items.py", "set-frames", it["uid"], f"{png}@14.2#the pay button, greyed out")
        out.append(it)
    clip = media / "pay.mp4"
    clip.write_bytes(b"\x00\x00\x00\x18ftypmp42clip")
    p2.run("items.py", "patch", out[0]["uid"], "--set", f"clip={clip}")
    idea = p2.item(proj["id"], kind="idea", title="Remember the last card", why="Fewer steps at checkout")
    p2.run("items.py", "state", out[0]["uid"], "--action", "keep", "--by", "user")
    gone = p2.item(proj["id"], title="Thrown away")
    p2.run("items.py", "state", gone["uid"], "--action", "discard", "--by", "user")
    return repo, proj, out, idea, gone


def read_zip(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as z:
        return {n: z.read(n) for n in z.namelist()}


def test_bundle_by_items_is_self_contained(p2):
    repo, proj, issues, idea, _ = seed(p2)
    out_dir = p2.tmp / "out"
    out = p2.run("export_local.py", "bundle", "--items", issues[0]["uid"], issues[1]["id"], idea["uid"],
                 issues[0]["uid"], "-o", out_dir, "--lang", "en")
    assert out["ok"] and out["items"] == 3  # a REF given twice counts once
    assert out["name"] == f"checkout-web-{TODAY}-3-items.zip" and Path(out["path"]) == out_dir.resolve() / out["name"]
    assert out["kinds"] == {"issue": 2, "idea": 1} and out["states"] == {"new": 2, "todo": 1}
    assert out["uids"] == [issues[0]["uid"], issues[1]["uid"], idea["uid"]] and out["missing"] == []
    files = read_zip(Path(out["path"]))
    root = f"checkout-web-{TODAY}-3-items/"
    assert all(n.startswith(root) for n in files)
    names = {n[len(root):] for n in files}
    assert {"summary.md", f"clips/{issues[0]['id']}.mp4", f"frames/{issues[0]['id']}-1.png",
            f"frames/{issues[1]['id']}-1.png"} <= names
    assert len([n for n in names if n.startswith("items/")]) == 3
    assert files[root + f"clips/{issues[0]['id']}.mp4"].endswith(b"clip")

    summary = files[root + "summary.md"].decode()
    assert summary.startswith("# Checkout Web hand-off\n") and f"3 items · Checkout Web · {TODAY}" in summary
    assert "**By kind**: 2 issues · 1 idea" in summary and "**By state**: 2 new · 1 to do" in summary
    sec = summary.split(f"## {issues[0]['id']} · Pay button 0 does nothing", 1)[1].split("\n## ", 1)[0]
    assert "**State**: To do · **Kind**: Issue · **Module**: cart · **Owner**: Ana" in sec
    assert "> I click pay and nothing happens (0)" in sec and "1. Open the cart\n2. Click Pay" in sec
    assert "**Suspected code**: `web/src/Pay0.tsx:42`" in sec
    assert f"![Frame 1 — the pay button, greyed out](<frames/{issues[0]['id']}-1.png>)" in sec
    assert f"[Clip](<clips/{issues[0]['id']}.mp4>)" in sec

    # every link resolves inside the bundle, and nothing points at this machine
    for name, data in files.items():
        if not name.endswith(".md"):
            continue
        text = data.decode()
        assert str(p2.tmp) not in text and "/Users/" not in text and str(repo) not in text, name
        here = Path(name).parent
        for link in re.findall(r"\]\(<([^>]+)>\)", text):
            assert not link.startswith("/") and (here / link).as_posix().replace("/items/../", "/") in files, (name, link)

    item_md = next(d.decode() for n, d in files.items() if n.startswith(root + "items/") and issues[0]["id"] in n)
    assert item_md.startswith(f"# {issues[0]['id']} · Pay button 0 does nothing")
    assert "**Actual**: Nothing happens" in item_md and "**Expected**: It pays" in item_md
    assert f"(<../frames/{issues[0]['id']}-1.png>)" in item_md and f"uid `{issues[0]['uid']}`" in item_md
    idea_md = next(d.decode() for n, d in files.items() if n.startswith(root + "items/") and idea["id"] in n)
    assert "**Why**: Fewer steps at checkout" in idea_md and "_user" not in idea_md and "work" not in idea_md

    para = out["summary"]
    assert para.startswith("Checkout Web hand-off: 3 items (2 issues, 1 idea; 2 new, 1 to do).")
    assert f"Items: {issues[0]['id']} Pay button 0 does nothing; " in para and "\n" not in para
    # nothing changed state
    assert p2.get(issues[1]["uid"])["state"] == "new" and p2.get(issues[0]["uid"])["state"] == "todo"


def test_bundle_by_project_filters_and_never_overwrites(p2):
    _, proj, issues, idea, gone = seed(p2, 3)
    first = p2.run("export_local.py", "bundle", "--project", proj["key"], "--lang", "en")
    # the default: the project's store exports/, every kind, all but discarded, by kind then id
    assert Path(first["path"]).parent == (Path(proj["path"]) / ".blurt" / "exports").resolve()
    assert first["items"] == 4 and gone["uid"] not in first["uids"] and first["uids"][-1] == idea["uid"]
    again = p2.run("export_local.py", "bundle", "--project", proj["key"], "--lang", "en")
    assert again["path"] != first["path"] and again["name"].endswith("~2.zip") and Path(first["path"]).is_file()
    only = p2.run("export_local.py", "bundle", "--project", proj["id"], "--kind", "issue", "--state", "new",
                  "-o", p2.tmp / "b", "--title", "Payment issues for Ana")
    assert only["uids"] == [issues[1]["uid"], issues[2]["uid"]] and only["title"] == "Payment issues for Ana"
    assert only["name"] == f"checkout-web-{TODAY}-2-items.zip"
    assert read_zip(Path(only["path"]))[f"checkout-web-{TODAY}-2-items/summary.md"].decode().startswith(
        "# Payment issues for Ana\n")
    gone_too = p2.run("export_local.py", "bundle", "--project", proj["id"], "--state", "discarded", "-o", p2.tmp / "c")
    assert gone_too["uids"] == [gone["uid"]] and gone_too["name"].endswith("-1-item.zip")
    exact = p2.run("export_local.py", "bundle", "--items", idea["uid"], "-o", p2.tmp / "picked" / "mine.zip")
    assert exact["path"] == str((p2.tmp / "picked" / "mine.zip").resolve()) and "mine/summary.md" in read_zip(Path(exact["path"]))


def test_bundle_zh_and_mixed_projects(p2):
    _, proj, issues, _, _ = seed(p2, 1)
    other = p2.project(p2.repo("site"), name="官网")
    zh = p2.item(other["id"], title="首页按钮太小", quote="这个按钮太小了", language="zh")
    out = p2.run("export_local.py", "bundle", "--items", zh["uid"], issues[0]["uid"], "-o", p2.tmp / "z", "--lang", "zh")
    assert out["name"] == f"blurt-{TODAY}-2条.zip"  # two projects: no project in the name
    s = read_zip(Path(out["path"]))[f"blurt-{TODAY}-2条/summary.md"].decode()
    assert s.startswith("# 交接包\n") and "**按类型**：2 个问题" in s and "**按状态**：新 1 条 · 要做 1 条" in s
    assert "**项目**：官网" in s and "**项目**：Checkout Web" in s  # each item says which project it is from
    assert "**: " not in s  # Chinese labels take the full-width colon
    assert out["summary"].startswith("交接包：2 条（2 个问题；新 1 条，要做 1 条）。解压后打开 summary.md")
    one = p2.run("export_local.py", "bundle", "--items", zh["uid"], "-o", p2.tmp / "z1")  # language from the item
    assert one["name"] == f"官网-{TODAY}-1条.zip" and one["summary"].startswith("官网 交接包：1 条")


def test_bundle_errors(p2):
    _, proj, issues, _, _ = seed(p2, 1)
    for args, code in ((["--items", "BA-999"], "not_found"), (["--project", "nope"], "no_project"),
                       (["--project", proj["id"], "--state", "fixed"], "bad_args"),
                       (["--project", proj["id"], "--kind", "task"], "no_items"),
                       (["--items", issues[0]["uid"], "--project", proj["id"]], "bad_args"), ([], "bad_args")):
        out = p2.run("export_local.py", "bundle", *args, ok=False)
        assert out["_exit"] == 1 and out["ok"] is False and out["code"] == code, (args, out)
    # a frame that is gone is listed, the bundle is still made
    Path(p2.get(issues[0]["uid"])["frames"][0]["path"]).unlink()
    out = p2.run("export_local.py", "bundle", "--items", issues[0]["uid"], "-o", p2.tmp / "m")
    assert out["ok"] and len(out["missing"]) == 1 and out["missing"][0].startswith(f"{issues[0]['id']}: ")
    assert out["files"] == 1  # the clip
    # … and the teammate reads that a screenshot is missing, in summary.md and in the item's file
    files = read_zip(Path(out["path"]))
    for name in (n for n in files if n.endswith(".md")):
        assert "_Not included, the file is gone: Frame 1 — the pay button, greyed out_" in files[name].decode(), name
    # a folder that can't be written, a file where the folder should be: an error line, not a traceback
    (p2.tmp / "plain.txt").write_text("x")
    for target in (p2.tmp / "plain.txt", p2.tmp / "plain.txt" / "deeper"):
        bad = p2.run("export_local.py", "bundle", "--items", issues[0]["uid"], "-o", target, ok=False)
        assert bad["_exit"] == 1 and bad["code"] == "io" and "can't write" in bad["error"], bad
    ro = p2.tmp / "readonly"
    ro.mkdir()
    ro.chmod(0o500)
    try:
        bad = p2.run("export_local.py", "bundle", "--items", issues[0]["uid"], "-o", ro, ok=False)
        assert bad["code"] == "io" and "Traceback" not in bad.get("_stderr", ""), bad
    finally:
        ro.chmod(0o700)
    assert not list(ro.iterdir())  # no temp file left behind


def test_bundle_scrubs_every_local_path_and_returns_an_absolute_path(p2):
    repo, proj, issues, _, _ = seed(p2, 1)
    store = Path(proj["path"]) / ".blurt"
    it = p2.item(proj["id"], title="Crash on start", actual=f"crash in {repo}, log at {store}/logs/x.log",
                 expected=f"opens; see /Volumes/Data/dumps/core.1 and {p2.tmp}/elsewhere/trace.txt",
                 code_refs=[f"{repo}/web/src/App.tsx:3", "/tmp/other/file.ts:9", "C:\\Users\\ana\\src\\Pay.tsx:4"],
                 quote="POST /api/v1/users fails, see https://example.com/Users/a/b")
    (p2.tmp / "work").mkdir()
    out = p2.run("export_local.py", "bundle", "--items", it["uid"], "-o", "rel-out", cwd=p2.tmp / "work")
    assert Path(out["path"]).is_absolute() and Path(out["path"]) == (p2.tmp / "work" / "rel-out" / out["name"]).resolve()
    files = read_zip(Path(out["path"]))
    for name, data in files.items():
        text = data.decode()
        for bad in (str(repo), str(p2.tmp), str(p2.tmp.resolve()), "/Volumes/", "/tmp/", "/private/", "C:\\"):
            assert bad not in text, (name, bad)
    md = next(d.decode() for n, d in files.items() if n.endswith(".md") and "/items/" in n)
    assert f"crash in {repo.name}, log at logs/x.log" in md  # the project folder by its name; inside it, relative
    assert "see core.1 and trace.txt" in md
    assert "`web/src/App.tsx:3`, `file.ts:9`, `Pay.tsx:4`" in md
    assert "POST /api/v1/users fails, see https://example.com/Users/a/b" in md  # a route and a URL stay as they are


def test_bundle_summary_section_always_says_what_the_item_is(p2):
    _, proj, _, idea, _ = seed(p2, 1)
    task = p2.item(proj["id"], kind="task", title="Ask Ana about cards", quote="", details="Before Friday's demo")
    out = p2.run("export_local.py", "bundle", "--items", idea["uid"], task["uid"], "-o", p2.tmp / "s", "--lang", "en")
    s = next(d.decode() for n, d in read_zip(Path(out["path"])).items() if n.endswith("/summary.md"))
    sec = s.split(f"## {idea['id']} · Remember the last card", 1)[1].split("\n## ", 1)[0]
    assert "**Why**: Fewer steps at checkout" in sec
    assert "**Details**: Before Friday's demo" in s.split(f"## {task['id']}", 1)[1]
    assert "**By kind**: 1 idea · 1 task" in s and out["summary"].startswith("Checkout Web hand-off: 2 items (1 idea, 1 task;")


def test_bundle_names_the_inbox_in_the_bundle_language(p2):
    zh_ui = p2.home / "config.json"
    zh_ui.write_text('{"record": {"install_app": false}, "lang": "zh"}')
    it = p2.item("inbox", title="Something loose")
    out = p2.run("export_local.py", "bundle", "--project", "inbox", "--lang", "en", "-o", p2.tmp / "i")
    assert out["name"] == f"unassigned-{TODAY}-1-item.zip" and out["title"] == "Unassigned hand-off", out
    assert out["uids"] == [it["uid"]]
    zh = p2.run("export_local.py", "bundle", "--project", "inbox", "--lang", "zh", "-o", p2.tmp / "i")
    assert zh["name"] == f"未归类-{TODAY}-1条.zip"


def test_bundle_name_and_slug():
    d = date(2026, 10, 25)
    assert export_local.bundle_name("Checkout Web", 12, "en", d) == "checkout-web-2026-10-25-12-items.zip"
    assert export_local.bundle_name("Checkout Web", 1, "en", d) == "checkout-web-2026-10-25-1-item.zip"
    assert export_local.bundle_name("官网 / 首页", 3, "zh", d) == "官网-首页-2026-10-25-3条.zip"
    assert export_local.bundle_name(None, 2, "fr", d) == "blurt-2026-10-25-2-items.zip"  # unknown language: English
    assert export_local.slug("  ../a:b\\c  ") == "a-b-c" and export_local.slug("***") == "blurt"
