"""Installed-only discovery and handoff to the local inference runtimes."""
import json
import os
import sys
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import model_api_engine as api


@pytest.fixture
def library(tmp_path, monkeypatch):
    # In production these calls run in a dedicated worker process.
    for name in ("BLURT_NO_DOWNLOAD", "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"):
        monkeypatch.setenv(name, "1")
    monkeypatch.setattr(api, "BLURT_HOME", tmp_path)
    monkeypatch.setenv("BLURT_HOME", str(tmp_path))
    models = tmp_path / "models"
    monkeypatch.setattr(api.speech, "MODELS_DIR", models)
    monkeypatch.setattr(api.polish, "POLISH_DIR", models / "polish")
    monkeypatch.setattr(api.screen_text, "MODEL_DIR", models / "screen_text")
    monkeypatch.setattr(api.screen_ocr, "MODEL_DIR", models / "ocr" / "PP-OCRv6-tiny")
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hub"))
    monkeypatch.setattr(api.speech, "platform_key", lambda: "darwin-arm64")
    monkeypatch.setattr(api.polish, "supported", lambda: True)
    return models


def write_model(dir_, chat_template=False):
    dir_.mkdir(parents=True)
    (dir_ / "config.json").write_text("{}")
    (dir_ / "model.safetensors").write_bytes(b"test")
    if chat_template:
        (dir_ / "tokenizer_config.json").write_text(json.dumps({"chat_template": "{{ messages }}"}))


def test_installed_models_only_and_platform_filter(library, monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", "fixture")
    assert api.available_models() == []
    write_model(library / "asr" / "Qwen3-ASR-1.7B-8bit")
    gemma = library / "polish" / "gemma-4-e2b-it-4bit"
    write_model(gemma, chat_template=True)
    write_model(library / "polish" / "Qwen3-0.6B-4bit")  # no chat template
    write_model(library / "screen_text" / "PaddleOCR-VL-1.6-4bit")
    sense = library / "sensevoice"
    sense.mkdir()
    (sense / "model.int8.onnx").write_bytes(b"weight")
    assert {(m["id"], m["capability"]) for m in api.available_models()} == {
        ("qwen3-asr-1.7b-mlx", "transcription"), ("gemma4-e2b", "chat"), ("paddleocr-vl-1.6", "ocr")}
    (sense / "tokens.txt").write_text("tokens")
    monkeypatch.setattr(api.speech, "platform_key", lambda: "windows-x86_64")
    monkeypatch.setattr(api.polish, "supported", lambda: False)
    assert [m["id"] for m in api.available_models()] == ["sensevoice-small"]
    with pytest.raises(LookupError):
        api.worker_command(str(gemma), "worker.py")
    with pytest.raises(ValueError, match="does not support chat"):
        api.chat("sensevoice-small", [], 1, 0)


def test_hf_snapshot_discovery_and_incomplete_download(library):
    repo = Path(os.environ["HF_HUB_CACHE"]) / "models--mlx-community--gemma-4-e2b-it-4bit"
    write_model(repo / "snapshots" / "rev", chat_template=True)
    assert api._find("gemma4-e2b").path == repo / "snapshots" / "rev"
    (repo / "blobs").mkdir()
    (repo / "blobs" / "model.incomplete").touch()
    assert api.available_models() == []


def test_worker_uses_prepared_python_or_only_cached_compatible_packages(library, monkeypatch, tmp_path):
    write_model(library / "asr" / "Qwen3-ASR-1.7B-8bit")
    monkeypatch.setattr(api.importlib.util, "find_spec", lambda name: object())
    assert api.worker_command("qwen3-asr-1.7b-mlx", "worker.py") == [sys.executable, "-u", "worker.py"]
    uv = tmp_path / "uv"
    uv.touch()
    monkeypatch.setattr(api.shutil, "which", lambda name: str(uv))
    monkeypatch.setattr(api.importlib.util, "find_spec", lambda name: None)
    cmd = api.worker_command("qwen3-asr-1.7b-mlx", "worker.py")
    assert "--offline" in cmd and "--no-python-downloads" in cmd and "mlx-qwen3-asr==0.4.4" in cmd
    assert cmd[-3:] == ["python", "-u", "worker.py"]


def test_transcription_uses_chosen_weights_uploaded_samples_and_language(library, monkeypatch, tmp_path):
    pytest.importorskip("numpy")
    path = library / "asr" / "Qwen3-ASR-1.7B-8bit"
    write_model(path)
    wav = tmp_path / "uploaded"
    with wave.open(str(wav), "wb") as f:
        f.setparams((1, 2, 16000, 0, "NONE", ""))
        f.writeframes(b"\x00\x40" * 1600)
    calls = []
    monkeypatch.setattr(api, "_recognizer", None)
    monkeypatch.setattr(api, "_recognizer_key", None)
    monkeypatch.setattr(api.speech, "limits", lambda: {"threads": 1})
    def new_backend(args):
        calls.append((args.model, args.language))
        return SimpleNamespace(no_vad=True, transcribe=lambda x: [(0, len(x) / 16000, f"sample={x[0]}", "en")])
    monkeypatch.setitem(api.speech.BACKENDS, "qwen3-asr-mlx", new_backend)
    for lang in ["en", "en", "ja"]:
        assert api.transcribe("qwen3-asr-1.7b-mlx", str(wav), lang) == "sample=0.5"
    assert calls == [(str(path), "en"), (str(path), "ja")]
    monkeypatch.setattr(api, "MAX_AUDIO_SECONDS", 0)
    with pytest.raises(ValueError, match="exceeds"):
        api._audio(str(wav))


def test_chat_stream_preserves_turns_and_sampling(library, monkeypatch):
    write_model(library / "polish" / "gemma-4-e2b-it-4bit", chat_template=True)
    calls = []
    def template(messages, **kw):
        calls.append((messages, kw))
        return [42]
    def generate(model, tok, tokens, **kw):
        calls.append((tokens, kw))
        return [SimpleNamespace(text="Pa"), SimpleNamespace(text="ris")]
    monkeypatch.setattr(api, "_chat_model", lambda p: (object(), SimpleNamespace(apply_chat_template=template)))
    monkeypatch.setitem(sys.modules, "mlx_lm", SimpleNamespace(stream_generate=generate))
    monkeypatch.setitem(sys.modules, "mlx_lm.sample_utils", SimpleNamespace(make_sampler=lambda temp: temp))
    messages = [{"role": "system", "content": "One word."}, {"role": "user", "content": "Capital of France?"}]
    assert list(api.chat_stream("gemma4-e2b", messages, 12, 0.5)) == ["Pa", "ris"]
    assert calls == [(messages, {"add_generation_prompt": True, "tokenize": True, "enable_thinking": False}),
                     ([42], {"max_tokens": 12, "sampler": 0.5})]


def test_ocr_reads_raw_image_and_rejects_oversized_input_before_inference(library, monkeypatch, tmp_path):
    im = pytest.importorskip("PIL.Image")
    write_model(library / "screen_text" / "PaddleOCR-VL-1.6-4bit")
    image = tmp_path / "upload"
    im.new("RGB", (8, 8)).save(image, "PNG")
    calls = []
    def read(path, draft):
        calls.append((path, draft))
        return {"text": "Read words"}
    monkeypatch.setattr(api, "_reader", lambda name: SimpleNamespace(read=read))
    assert api.ocr("paddleocr-vl-1.6", str(image)) == "Read words"
    im.new("1", (2000, 2001)).save(image, "PNG")
    with pytest.raises(ValueError, match="pixels"):
        api.ocr("paddleocr-vl-1.6", str(image))
    assert calls == [(str(image), None)]


def test_cpu_ocr_requires_all_weights_and_never_fetches_them(library, monkeypatch):
    d = api.screen_ocr.MODEL_DIR
    d.mkdir(parents=True)
    files = [{"path": name, "size": 1} for name in ("det.onnx", "rec.onnx", "rec.yml")]
    (d / ".blurt-manifest.json").write_text(json.dumps(files))
    for f in files:
        (d / f['path']).write_bytes(b'x')
    monkeypatch.setattr(api.screen_ocr, 'MODEL_FILES', files)
    assert [m['id'] for m in api.available_models()] == [api.TINY_OCR]
    (d / 'rec.onnx').unlink()
    assert api.available_models() == []
    monkeypatch.setattr(api.screen_ocr, 'ensure_models', lambda: pytest.fail('initiated a download'))
    monkeypatch.setitem(sys.modules, 'rapidocr', SimpleNamespace(ModelType=object(),
                        OCRVersion=SimpleNamespace(PPOCRV6='v6'), RapidOCR=lambda **kw: pytest.fail('fell back')))
    with pytest.raises(api.screen_ocr.Fail, match='not installed'):
        api.screen_ocr.Engine(installed_only=True).load()


def test_concurrent_prepare_shares_runtime_between_models(library, monkeypatch):
    for name in ("gemma-4-e2b-it-4bit", "Qwen3-0.6B-4bit"):
        write_model(library / "polish" / name, chat_template=True)
    calls = []
    monkeypatch.setattr(api, "_uv", lambda: "uv")
    monkeypatch.setattr(api, "_indexes", lambda _: [])

    def run(command, stage):
        calls.append(command)
        if command[1] == "venv":
            python = api._env_python(Path(command[-1]))
            python.parent.mkdir(parents=True)
            python.touch()

    monkeypatch.setattr(api, "_prepare_step", run)
    ids = ["gemma4-e2b", "qwen3-0.6b"]
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(api.prepare_runtime, ids))
    assert results == [{"id": mid, "prepared": True} for mid in ids]
    assert [cmd[1] for cmd in calls].count("venv") == 1
    installs = [cmd for cmd in calls if cmd[1] == "pip"]
    assert len(installs) == 1 and api.polish.MLX_PACKAGE in installs[0]
    cmd = api.worker_command(ids[0], "worker.py")
    assert Path(cmd[0]).is_relative_to(api.BLURT_HOME / "model-api" / "runtimes")
    assert api.worker_command(ids[1], "worker.py") == cmd


def test_incomplete_runtime_never_selected_and_retries_in_place(library, monkeypatch):
    write_model(library / "asr" / "Qwen3-ASR-1.7B-8bit")
    model_id = "qwen3-asr-1.7b-mlx"
    attempts = []
    imports_work = False
    monkeypatch.setattr(api, "_uv", lambda: "uv")
    monkeypatch.setattr(api.importlib.util, "find_spec", lambda _: None)

    def run(command, stage):
        attempts.append(command)
        if command[1] == "venv":
            python = api._env_python(Path(command[-1]))
            python.parent.mkdir(parents=True, exist_ok=True)
            python.touch()
        if command[1] == "-I" and not imports_work:
            raise RuntimeError("import failed")

    monkeypatch.setattr(api, "_prepare_step", run)
    with pytest.raises(RuntimeError, match="import failed"):
        api.prepare_runtime(model_id)
    assert "--offline" in api.worker_command(model_id, "worker.py")
    imports_work = True
    assert api.prepare_runtime(model_id)["prepared"]
    assert any("--reinstall" in cmd for cmd in attempts)
    python = Path(api.worker_command(model_id, "worker.py")[0])
    assert python.is_file() and python != Path(sys.executable)


def test_runtime_identity_tracks_only_requirements_and_platform(tmp_path, monkeypatch):
    monkeypatch.setattr(api, "HERE", tmp_path)
    monkeypatch.setattr(api, "BLURT_HOME", tmp_path)
    script = tmp_path / "backend.py"
    metadata = '# /// script\n# requires-python = ">=3.11"\n# dependencies = ["numpy==2.3.4"]\n# ///\n'
    script.write_text(metadata + 'some_code = 1\n')
    name = api._environment(script.name, "extra==1")
    script.write_text(metadata + 'some_code = 2\n')
    assert api._environment(script.name, "extra==1") == name
    assert api._environment(script.name, "extra==2") != name
    script.write_text(metadata.replace("2.3.4", "2.3.5"))
    assert api._environment(script.name, "extra==1") != name
    script.write_text(metadata)
    monkeypatch.setattr(api.speech, "platform_key", lambda: "different-platform")
    assert api._environment(script.name, "extra==1") != name
