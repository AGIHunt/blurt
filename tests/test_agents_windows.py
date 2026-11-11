"""agents.py install on Windows: the skill folder becomes a directory junction (a symlink needs Developer Mode or
admin: WinError 1314), a copy where no junction can be made; a junction already there counts as installed.

  uv run --with pytest pytest tests/test_agents_windows.py -q      (Windows only)
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import agents  # noqa: E402

pytestmark = pytest.mark.skipif(os.name != "nt", reason="junctions are Windows'")


def _cfg(skills: Path) -> dict:
    return {"record": {"agent_defs": {"t": {"skill_dir": str(skills)}}}}


def test_skill_is_a_junction_and_then_exists(tmp_path):
    skills = tmp_path / "skills"
    dry = agents.install("t", mcp=False, dry_run=True, cfg=_cfg(skills))["changes"][0]
    assert dry["action"] == "symlink" and dry["kind"] == "junction" and not skills.exists()
    out = agents.install("t", mcp=False, cfg=_cfg(skills))
    ch = out["changes"][0]
    assert out["applied"] and ch["ok"] and ch["kind"] == "junction", ch
    link = skills / "blurt"
    assert link.is_junction() if hasattr(link, "is_junction") else True
    assert (link / "SKILL.md").read_bytes() == (agents.SKILL_ROOT / "SKILL.md").read_bytes()
    again = agents.install("t", mcp=False, cfg=_cfg(skills))
    assert again["applied"] and again["changes"][0]["action"] == "exists", again


def test_no_junction_falls_back_to_a_copy(tmp_path, monkeypatch):
    import _winapi

    def refuse(*_):
        raise OSError("no junctions here")
    monkeypatch.setattr(_winapi, "CreateJunction", refuse)
    skills = tmp_path / "skills"
    out = agents.install("t", mcp=False, cfg=_cfg(skills))
    assert out["applied"] and out["changes"][0]["kind"] == "copy"
    assert agents._our_copy(skills / "blurt")
    again = agents.install("t", mcp=False, cfg=_cfg(skills))["changes"][0]
    assert again["action"] == "exists" and again["kind"] == "copy" and again["refreshed"]


def test_a_junction_to_another_skill_is_a_conflict(tmp_path):
    import _winapi
    other = tmp_path / "other"
    other.mkdir()
    skills = tmp_path / "skills"
    skills.mkdir()
    _winapi.CreateJunction(str(other), str(skills / "blurt"))
    ch = agents.install("t", mcp=False, cfg=_cfg(skills))["changes"][0]
    assert ch["action"] == "conflict"
