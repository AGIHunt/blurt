"""A worktree for a dispatch must not fail because one Git LFS object is missing on the server."""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import sessions  # noqa: E402


@pytest.mark.skipif(not shutil.which("git-lfs"), reason="needs git-lfs")
def test_worktree_add_survives_missing_lfs_object(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    g = lambda *a, **kw: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, **kw)  # noqa: E731
    g("init", "-q")
    g("config", "user.email", "t@t")
    g("config", "user.name", "t")
    (repo / ".gitattributes").write_text("*.png filter=lfs diff=lfs merge=lfs -text\n")
    (repo / "a.png").write_text("version https://git-lfs.github.com/spec/v1\noid sha256:" + "0" * 64 + "\nsize 123\n")
    g("-c", "filter.lfs.clean=cat", "add", ".")
    g("-c", "filter.lfs.clean=cat", "commit", "-qm", "init")
    g("remote", "add", "origin", "https://example.invalid/x.git")
    sha = g("rev-parse", "HEAD", text=True).stdout.strip()
    wt = tmp_path / "wt"
    sessions.add_worktree(repo, "blurt-test", str(wt), sha)
    assert (wt / "a.png").read_text().startswith("version https://git-lfs")
