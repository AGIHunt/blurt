"""screen_ocr.py's own rules (the reading itself needs RapidOCR and its models: measured in docs/design/windows-models.md)."""
import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import screen_ocr  # noqa: E402


def test_cjk_and_latin_get_their_space_back():
    assert screen_ocr.spaced("用ClaudeCode跑") == "用 ClaudeCode 跑"
    assert screen_ocr.spaced("the save button") == "the save button"


def test_models_come_from_hugging_face_at_a_pinned_commit_or_modelscope_first_with_the_mirror():
    f = screen_ocr.MODEL_FILES[0]
    hf, ms = screen_ocr.model_urls(f, mirror=False)
    assert hf.startswith("https://huggingface.co/PaddlePaddle/") and f"/resolve/{f['rev']}/" in hf
    assert ms.startswith("https://modelscope.cn/models/PaddlePaddle/")
    assert screen_ocr.model_urls(f, mirror=True) == [ms, hf]


def _fake_site(monkeypatch, tmp_path, good: dict[str, bytes], bad_hosts=()):
    """fetch() stand-in: a bad host serves the wrong bytes; every fetch is recorded."""
    calls = []

    def fetch(url, tmp, size=None, progress=None, timeout=60):
        calls.append(url)
        name = next(n for n, f in files.items() if f["repo"] in url and url.endswith(f["file"]))
        body = b"not the model" if any(h in url for h in bad_hosts) else good[name]
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(body)
        return len(body)

    files = {}
    model_files = []
    for i, (name, body) in enumerate(good.items()):
        f = {"path": name, "repo": f"repo{i}", "rev": "abc", "file": f"file{i}.bin", "size": len(body),
             "sha256": hashlib.sha256(body).hexdigest()}
        files[name] = f
        model_files.append(f)
    monkeypatch.setenv("BLURT_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(screen_ocr, "MODEL_FILES", model_files)
    monkeypatch.setattr(screen_ocr, "fetch", fetch)
    monkeypatch.setattr(screen_ocr, "mirror_on", lambda: False)
    return calls


def test_a_file_whose_hash_is_wrong_is_not_kept_and_the_other_site_is_tried(monkeypatch, tmp_path):
    good = {"det.onnx": b"det-bytes", "rec.onnx": b"rec-bytes"}
    calls = _fake_site(monkeypatch, tmp_path, good, bad_hosts=("huggingface.co",))
    d = screen_ocr.ensure_models(tmp_path / "m")
    assert {n: (d / n).read_bytes() for n in good} == good
    assert [u.split("/")[2] for u in calls] == ["huggingface.co", "modelscope.cn"] * 2
    assert not list(d.glob("*.part"))
    # installed: a second call fetches nothing
    calls.clear()
    screen_ocr.ensure_models(tmp_path / "m")
    assert calls == []


def test_no_site_with_the_right_file_is_a_network_failure_and_installs_nothing(monkeypatch, tmp_path):
    _fake_site(monkeypatch, tmp_path, {"det.onnx": b"det-bytes"}, bad_hosts=("huggingface.co", "modelscope.cn"))
    with pytest.raises(screen_ocr.Fail) as e:
        screen_ocr.ensure_models(tmp_path / "m")
    assert e.value.code == "network"
    assert not (tmp_path / "m" / "det.onnx").exists()
    assert not screen_ocr.folder_complete(tmp_path / "m")


def test_the_recogniser_characters_come_from_its_yml(tmp_path):
    pytest.importorskip("yaml")
    (tmp_path / "rec.yml").write_text("PostProcess:\n  name: CTCLabelDecode\n  character_dict:\n  - '!'\n  - 你\n  - '1'\n",
                                      encoding="utf-8")
    assert screen_ocr.keys_file(tmp_path).read_text(encoding="utf-8") == "!\n你\n1\n"
