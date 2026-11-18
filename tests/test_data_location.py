"""The data folder chosen in the Windows / Linux app (location.json, apps/desktop/src-tauri/src/location.rs): the scripts
an agent runs outside the app find the data there; BLURT_HOME / BLURT_WORKSPACE still win."""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/blurt/scripts"))
import _common  # noqa: E402


def test_pointer_then_default(tmp_path, monkeypatch):
    f = tmp_path / "location.json"
    home, ws = tmp_path / "E" / "Blurt" / ".blurt", tmp_path / "E" / "Blurt"
    monkeypatch.setenv("BLURT_LOCATION_FILE", str(f))
    monkeypatch.setattr(_common, "IS_MAC", False)
    monkeypatch.delenv("BLURT_HOME", raising=False)
    monkeypatch.delenv("BLURT_WORKSPACE", raising=False)
    assert _common.chosen_location() == {}
    assert _common.blurt_home() == Path.home() / ".blurt"
    f.write_text(json.dumps({"home": str(home), "workspace": str(ws), "own_caches": True}), encoding="utf-8")
    assert _common.blurt_home() == home
    assert _common.blurt_workspace() == ws
    # the app's own variables win
    monkeypatch.setenv("BLURT_HOME", str(tmp_path / "h"))
    assert _common.blurt_home() == tmp_path / "h"
    # a relative path or a broken file is no pointer
    f.write_text(json.dumps({"home": "rel", "workspace": str(ws)}), encoding="utf-8")
    assert _common.chosen_location() == {"workspace": str(ws)}
    f.write_text("{", encoding="utf-8")
    assert _common.chosen_location() == {}


def test_mac_ignores_it(tmp_path, monkeypatch):
    f = tmp_path / "location.json"
    f.write_text(json.dumps({"home": str(tmp_path / "x"), "workspace": str(tmp_path)}), encoding="utf-8")
    monkeypatch.setenv("BLURT_LOCATION_FILE", str(f))
    monkeypatch.setattr(_common, "IS_MAC", True)
    assert _common.chosen_location() == {}


def test_jobs_follow_it(tmp_path, monkeypatch):
    import jobs
    f = tmp_path / "location.json"
    f.write_text(json.dumps({"home": str(tmp_path / "d" / ".blurt"), "workspace": str(tmp_path / "d")}), encoding="utf-8")
    monkeypatch.setenv("BLURT_LOCATION_FILE", str(f))
    monkeypatch.setattr(_common, "IS_MAC", False)
    monkeypatch.delenv("BLURT_HOME", raising=False)
    assert jobs.home() == tmp_path / "d" / ".blurt"
    assert os.environ.get("BLURT_HOME") is None
