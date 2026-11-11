"""tk_recorder.py shot --image: a picture already taken (Linux: GNOME's Screenshot portal) goes into the batch as
shots/NNN.png with its line, numbered after what is there."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import tk_recorder  # noqa: E402


def test_a_picture_already_taken_is_copied_in_and_numbered(tmp_path):
    session = tmp_path / "shots-batch"
    (session / "shots").mkdir(parents=True)
    (session / "shots" / "001.png").write_bytes(b"older")
    pic = tmp_path / "snap.png"
    pic.write_bytes(b"\x89PNG fake")
    r = tk_recorder.cli_shot(session, [10, 20, 300, 200], "inbox", pic)
    assert r["ok"] and r["n"] == 2 and r["file"] == "shots/002.png"
    assert (session / "shots" / "002.png").read_bytes() == b"\x89PNG fake"
    line = json.loads((session / "shots.jsonl").read_text(encoding="utf-8").splitlines()[-1])
    assert line["region"] == [10, 20, 300, 200] and line["type"] == "shot" and line["project"] == "inbox"


def test_a_missing_picture_is_a_failed_snap(tmp_path):
    r = tk_recorder.cli_shot(tmp_path / "s", [0, 0, 10, 10], None, tmp_path / "gone.png")
    assert not r["ok"] and r["code"] == "snap"
