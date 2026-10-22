#!/usr/bin/env python3
"""Lay out the fixture sessions as a v0.7 user would have them — a git project opened in Blurt, its sessions migrated
into Markdown, the index built — for the desktop app's smoke runs and the Linux e2e.

  python3 apps/desktop/scripts/fixture_index.py OUT_DIR [--env-file F]

OUT_DIR/repo                          a git project (`projects.py add`), its store at repo/.blurt (never in git)
OUT_DIR/home/Blurt                    BLURT_WORKSPACE; the -shots fixture lands in recordings/ (migrated to inbox/)
OUT_DIR/blurt-home                    BLURT_HOME: projects.json, index.db (`index.py scan`)

Prints one JSON line {home, repo, blurt_home, workspace, index_db, project, scan}. --env-file writes KEY=VALUE lines
(HOME, BLURT_HOME, BLURT_WORKSPACE) for CI's $GITHUB_ENV or a shell `set -a; . F`. OUT_DIR is wiped first.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests" / "fixtures" / "sessions"
SCRIPTS = Path(os.environ.get("BLURT_SCRIPTS") or ROOT / "skills" / "blurt" / "scripts")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("--env-file")
    a = p.parse_args()
    out = Path(a.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    home, repo, bh = out / "home", out / "repo", out / "blurt-home"
    ws = home / "Blurt"
    bh.mkdir(parents=True)
    (bh / "config.json").write_text(json.dumps({"record": {"install_app": False}}), encoding="utf-8")
    env = {**os.environ, "HOME": str(home), "BLURT_HOME": str(bh), "BLURT_WORKSPACE": str(ws)}
    env.pop("BLURT_NO_INDEX", None)
    uv = shutil.which("uv")
    py = [uv, "run", "--quiet", "--script"] if uv else [sys.executable]

    def run(script: str, *args: str) -> dict:
        r = subprocess.run([*py, str(SCRIPTS / script), *args], env=env, capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            sys.exit(f"{script} {' '.join(args)} failed:\n{r.stderr}{r.stdout}")
        return json.loads(r.stdout.strip().splitlines()[-1])

    repo.mkdir(parents=True)
    git = ["git", "-c", "user.email=e2e@blurt", "-c", "user.name=e2e"]
    (repo / "README.md").write_text("fixture project\n", encoding="utf-8")
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "init"]):
        subprocess.run([*git, *cmd], cwd=repo, check=True, capture_output=True)
    project = run("projects.py", "add", str(repo), "--name", "my-saas")["project"]
    for s in sorted(d for d in FIXTURES.iterdir() if d.is_dir()):
        dest = (ws / "recordings") if s.name.endswith("-shots") else (repo / ".blurt" / "sessions")
        shutil.copytree(s, dest / s.name)
    run("items.py", "migrate", "--all")
    scan = run("index.py", "scan")
    info = {"home": str(home), "repo": str(repo), "blurt_home": str(bh), "workspace": str(ws),
            "index_db": str(bh / "index.db"), "project": project["id"], "scan": scan}
    if a.env_file:
        Path(a.env_file).write_text(f"HOME={home}\nBLURT_HOME={bh}\nBLURT_WORKSPACE={ws}\n", encoding="utf-8")
    print(json.dumps(info))  # ASCII: Windows pipes default to a legacy code page


if __name__ == "__main__":
    main()
