#!/usr/bin/env python3
"""Lay out WP1's fixture sessions as a user would have them and index them with index.py — what the desktop app's
smoke test and the Linux e2e open.

  python3 apps/desktop/scripts/fixture_index.py OUT_DIR [--env-file F]

OUT_DIR/home/Blurt/recordings/<shots session>     the default workspace (BLURT_WORKSPACE)
OUT_DIR/repo/.blurt/sessions/<video sessions>     a project workspace ("repo")
OUT_DIR/blurt-home/index.db                       BLURT_HOME, built by `index.py scan --root OUT_DIR/repo`

Prints one JSON line {home, repo, blurt_home, workspace, index_db, scan}. --env-file writes KEY=VALUE lines (HOME,
BLURT_HOME, BLURT_WORKSPACE) for CI's $GITHUB_ENV or a shell `set -a; . F`. OUT_DIR is wiped first.
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
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"


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
    for s in sorted(d for d in FIXTURES.iterdir() if d.is_dir()):
        dest = (ws / "recordings") if s.name.endswith("-shots") else (repo / ".blurt" / "sessions")
        shutil.copytree(s, dest / s.name)
    bh.mkdir(parents=True)
    env = {**os.environ, "HOME": str(home), "BLURT_HOME": str(bh), "BLURT_WORKSPACE": str(ws)}
    env.pop("BLURT_NO_INDEX", None)
    uv = shutil.which("uv")
    cmd = [uv, "run", "--quiet", "--script"] if uv else [sys.executable]
    r = subprocess.run([*cmd, str(SCRIPTS / "index.py"), "scan", "--root", str(repo)], env=env, capture_output=True,
                       text=True, encoding="utf-8")
    if r.returncode != 0:
        sys.exit(f"index.py scan failed:\n{r.stderr}{r.stdout}")
    scan = json.loads(r.stdout.strip().splitlines()[-1])
    info = {"home": str(home), "repo": str(repo), "blurt_home": str(bh), "workspace": str(ws),
            "index_db": str(bh / "index.db"), "scan": scan}
    if a.env_file:
        Path(a.env_file).write_text(f"HOME={home}\nBLURT_HOME={bh}\nBLURT_WORKSPACE={ws}\n", encoding="utf-8")
    print(json.dumps(info))  # ASCII: Windows pipes default to a legacy code page


if __name__ == "__main__":
    main()
