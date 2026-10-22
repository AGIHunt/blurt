#!/usr/bin/env python3
"""A realistic Blurt world for the main window (WP5): the repo's fixture sessions plus N synthetic sessions spread over
a few bound projects, then `index.py scan` builds $BLURT_HOME/index.db.

  BLURT_HOME=… BLURT_WORKSPACE=… python3 make_fixture.py [--items 20000] [--per-session 50] [--repos DIR]

Everything goes under $BLURT_WORKSPACE (default workspace, recordings/) and --repos (default $BLURT_WORKSPACE/../repos);
$BLURT_HOME/config.json gets record.workspaces. Refuses to run without both variables, so it can never write to
~/Blurt or ~/.blurt.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
FIXTURES = REPO / "tests" / "fixtures" / "sessions"
SCRIPTS = REPO / "skills" / "blurt" / "scripts"

ISSUES = ["登录按钮点击无响应", "价格页在移动端溢出", "头像上传返回 500", "保存后 toast 叠加三个", "暗色模式下表格边框看不见",
          "Checkout button stays disabled after coupon", "Search results flicker while typing", "侧栏折叠后图标错位",
          "Onboarding skips the last step", "通知设置不生效", "Dropdown clipped by the modal", "导出 CSV 中文乱码",
          "Infinite spinner on slow network", "快捷键 ⌘S 没反应", "Avatar crop is off by a few pixels", "分页跳到第一页",
          "Date picker shows UTC instead of local time", "拖拽排序后顺序没保存", "Tooltip covers the button it explains",
          "上传大文件时进度条倒退"]
IDEAS = ["空状态学 Linear 的做法", "Command palette for every action", "给图表加对比上周", "Keyboard-first triage mode",
         "首页加一个最近项目区", "Show a diff preview before saving", "用颜色区分环境", "Inline AI suggestions in the editor",
         "做一个分享链接的只读视图", "Bulk edit for tags"]
NOTES = ["竞品的定价页用了三档", "Users mostly come from the docs", "客户说导出很重要", "The API returns 120 ms p50",
         "设计稿里间距是 8 的倍数"]
TASKS = ["升级到 React 19", "Write the migration guide", "补齐埋点", "Rotate the staging keys", "把图标换成 SF Symbols"]
MODULES = ["auth", "billing", "ui", "profile", "search", "settings", "editor", "export"]
SEV = ["high", "medium", "low", None]
REPOS = ["my-saas", "landing-page", "ios-app"]


def item(rng: random.Random, n: int, base: float) -> dict:
    kind = rng.choices(["issue", "idea", "note", "task"], [60, 20, 10, 10])[0]
    pool = {"issue": ISSUES, "idea": IDEAS, "note": NOTES, "task": TASKS}[kind]
    title = rng.choice(pool) + ("" if rng.random() < .6 else f" #{rng.randint(2, 99)}")
    it = {"id": f"I-{n:03d}", "kind": kind, "title": title, "quote": f"这里{title}，你看一下。",
          "time": {"start": round(n * 3.1, 1), "end": round(n * 3.1 + 2, 1)},
          "frames": [{"path": "frames/f.jpg", "t": round(n * 3.1 + 1, 1)}], "tags": [rng.choice(MODULES)],
          "confidence": "high", "questions": [], "answer": "", "exported": {},
          "status": rng.choices(["draft", "confirmed", "deleted"], [30, 65, 5])[0], "module": rng.choice(MODULES)}
    if kind == "issue":
        it.update(severity=rng.choice(SEV), actual="现在的表现：" + title, expected="应该正常工作", steps=["打开页面", "操作一下"])
        if rng.random() < .3:
            it["code_refs"] = [f"src/{it['module']}/index.ts:{rng.randint(1, 300)}"]
        r = rng.random()
        if r < .25:
            st = rng.choices(["fixing", "fixed", "wontfix", "reopened"], [3, 6, 1, 1])[0]
            it["fix"] = {"state": st, "agent": rng.choice(["claude", "codex", "human"]), "run_id": None, "commit": None,
                         "pr": None, "note": "", "at": round(base + n * 60, 1)}
    elif kind == "idea":
        it.update(why="灵感来自别家产品", next="画个草图")
    return it


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", type=int, default=20000)
    ap.add_argument("--per-session", type=int, default=50)
    ap.add_argument("--repos", type=Path)
    a = ap.parse_args()
    if not os.environ.get("BLURT_HOME") or not os.environ.get("BLURT_WORKSPACE"):
        sys.exit("set BLURT_HOME and BLURT_WORKSPACE (this never writes to ~/.blurt or ~/Blurt)")
    home, ws = Path(os.environ["BLURT_HOME"]), Path(os.environ["BLURT_WORKSPACE"])
    repos_dir = a.repos or ws.parent / "repos"
    for p in (ws / "recordings", *(repos_dir / r for r in REPOS)):
        shutil.rmtree(p, ignore_errors=True)
    (home / "index.db").unlink(missing_ok=True)
    for suffix in ("-wal", "-shm"):
        (home / f"index.db{suffix}").unlink(missing_ok=True)
    rec = ws / "recordings"
    rec.mkdir(parents=True)
    # the real fixture sessions: the default workspace gets all three, my-saas gets copies under new names
    for s in FIXTURES.iterdir():
        shutil.copytree(s, rec / s.name)
    frame = next(FIXTURES.glob("*/frames/*.jpg"))
    rng = random.Random(7)
    sessions = max(1, a.items // a.per_session)
    now = time.time()
    for k in range(sessions):
        repo = repos_dir / REPOS[k % len(REPOS)]
        t = now - (sessions - k) * 3600 * 5
        name = time.strftime("%Y%m%d-%H%M%S", time.localtime(t)) + ("-shots" if k % 7 == 3 else "")
        d = repo / ".blurt" / "sessions" / name
        (d / "frames").mkdir(parents=True)
        shutil.copy(frame, d / "frames" / "f.jpg")
        shots = name.endswith("-shots")
        (d / "meta.json").write_text(json.dumps({"author": "Tester", "duration": None if shots else 120.0,
                                                 "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)),
                                                 **({"mode": "shots"} if shots else {"video": "recording.mp4"})}))
        if k >= sessions - 3:  # the newest few: not processed yet (inbox)
            continue
        doc = {"session": name, "title": f"{repo.name} walkthrough {k}", "reviewed": k % 5 != 0,
               "items": [item(rng, n + 1, t) for n in range(a.per_session)]}
        (d / "items.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1))
    cfg_p = home / "config.json"
    cfg = json.loads(cfg_p.read_text()) if cfg_p.exists() else {}
    cfg.setdefault("record", {})["workspaces"] = [str(repos_dir / r) for r in REPOS]
    cfg["record"].setdefault("install_app", False)
    cfg["skill_dir"] = str(SCRIPTS.parent)
    home.mkdir(parents=True, exist_ok=True)
    cfg_p.write_text(json.dumps(cfg, indent=2, sort_keys=True))
    for r in REPOS:
        (repos_dir / r / ".git").mkdir(parents=True, exist_ok=True)
    out = subprocess.run(["uv", "run", "-q", str(SCRIPTS / "index.py"), "scan"], capture_output=True, text=True)
    print(out.stdout.strip() or out.stderr.strip())


if __name__ == "__main__":
    main()
