"""Model downloads (`transcribe.py setup`, `polish.py setup`; _common's download helpers): a mirror download cut short
is never "installed", a partial file is continued with an HTTP Range request, one download of a model at a time, and a
setup ends with the app that started it. No network: urlopen is faked; the scratch BLURT_HOME is conftest's.

  uv run --with numpy --with pytest pytest tests/test_model_downloads.py -q
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import _common as C  # noqa: E402
import polish as P  # noqa: E402
import transcribe as T  # noqa: E402

REPO = "mlx-community/Test-ASR-4bit"
FILES = {"config.json": b"{}", "model.safetensors": b"w" * 3000, "tokenizer.json": b"t" * 50,
         "tokenizer_config.json": b"{}", "vocab.json": b"v" * 20}


class FakeResponse(io.BytesIO):
    def __init__(self, data: bytes, status: int = 200, length: int | None = None):
        super().__init__(data)
        self.status = status
        self.headers = {"content-length": str(len(data) if length is None else length)}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class FakeModelScope:
    """The ModelScope API and file URLs; `fail_on` makes opening that file raise (the connection drops), `ranges`
    whether the server honours Range."""

    def __init__(self, files: dict[str, bytes], fail_on: str | None = None, ranges: bool = True):
        self.files, self.fail_on, self.ranges = files, fail_on, ranges
        self.opened: list[tuple[str, str | None]] = []

    def __call__(self, req, timeout=None):
        url = req.full_url if hasattr(req, "full_url") else req
        rng = req.get_header("Range") if hasattr(req, "get_header") else None
        if "/api/v1/models/" in url:
            listing = [{"Type": "blob", "Path": p, "Size": len(b)} for p, b in self.files.items()]
            return FakeResponse(json.dumps({"Data": {"Files": listing + [{"Type": "blob", "Path": "README.md", "Size": 3}]}}).encode())
        name = url.rsplit("/", 1)[-1]
        self.opened.append((name, rng))
        if name == self.fail_on:
            raise urllib.error.URLError("connection reset")
        data = self.files[name]
        if rng and self.ranges:
            start = int(rng.split("=")[1].rstrip("-"))
            return FakeResponse(data[start:], status=206)
        return FakeResponse(data)


def asr_entry(name: str) -> dict:
    return {"id": name, "backend": "qwen3-asr-mlx", "local": True, "size_mb": 1,
            "install": {"hf": f"mlx-community/{name}"}}


class MirrorDownloadIsCompleteOrNotInstalled(unittest.TestCase):
    def setUp(self):
        self.name = f"Test-ASR-{os.getpid()}-{time.time_ns()}"
        self.dest = T.MODELS_DIR / "asr" / self.name
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dest, ignore_errors=True))

    def test_a_drop_after_the_weights_leaves_it_not_installed(self):
        # the dogfood case: the connection drops opening tokenizer.json, after model.safetensors came in
        fake = FakeModelScope(FILES, fail_on="tokenizer.json")
        with mock.patch.object(urllib.request, "urlopen", fake), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(T.Fail):
                T._modelscope(f"mlx-community/{self.name}", 1)
        self.assertTrue((self.dest / "config.json").exists() and (self.dest / "model.safetensors").exists())
        self.assertIsNone(T.model_path(asr_entry(self.name)))         # not "installed: true" any more
        self.assertFalse(T.installed(asr_entry(self.name)))
        # the next try fetches only what is missing, and then it is a model
        ok = FakeModelScope(FILES)
        with mock.patch.object(urllib.request, "urlopen", ok), contextlib.redirect_stderr(io.StringIO()):
            T._modelscope(f"mlx-community/{self.name}", 1)
        self.assertNotIn("model.safetensors", [n for n, _ in ok.opened])
        self.assertEqual(T.model_path(asr_entry(self.name)), self.dest)
        self.assertFalse((self.dest / C.DOWNLOAD_MARKER).exists())

    def test_a_file_shorter_than_its_manifest_is_not_complete(self):
        ok = FakeModelScope(FILES)
        with mock.patch.object(urllib.request, "urlopen", ok), contextlib.redirect_stderr(io.StringIO()):
            T._modelscope(f"mlx-community/{self.name}", 1)
        self.assertTrue(C.folder_complete(self.dest))
        (self.dest / "vocab.json").write_bytes(b"v")
        self.assertFalse(C.folder_complete(self.dest))

    def test_an_older_download_without_a_manifest_still_counts_when_whole(self):
        self.dest.mkdir(parents=True)
        (self.dest / "config.json").write_text("{}")
        (self.dest / "model-00001-of-00002.safetensors").write_bytes(b"a")
        (self.dest / "model.safetensors.index.json").write_text(json.dumps(
            {"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}))
        self.assertIsNone(T.model_path(asr_entry(self.name)))          # a shard is missing
        (self.dest / "model-00002-of-00002.safetensors").write_bytes(b"b")
        self.assertEqual(T.model_path(asr_entry(self.name)), self.dest)


class HuggingFaceSnapshotIsCompleteOrNotInstalled(unittest.TestCase):
    """The Hugging Face cache side of transcribe.py's model_path: a snapshot that a setup cut short between files
    (no *.incomplete blob left, but a shard or the tokenizer missing) is not installed."""

    def setUp(self):
        self.hub = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.hub, ignore_errors=True))
        self.name = f"Test-HF-{os.getpid()}-{time.time_ns()}"
        self.repo = f"mlx-community/{self.name}"
        self.snap = self.hub / ("models--" + self.repo.replace("/", "--")) / "snapshots" / "abc123"
        self.snap.mkdir(parents=True)
        (self.hub / ("models--" + self.repo.replace("/", "--")) / "blobs").mkdir()
        rec = T._hf_record(self.repo)
        self.addCleanup(lambda: rec.unlink(missing_ok=True))
        p = mock.patch.dict(os.environ, {"HF_HUB_CACHE": str(self.hub)})
        p.start()
        self.addCleanup(p.stop)

    def put(self, *names):
        for n in names:
            (self.snap / n).write_text("{}" if n.endswith(".json") else "x")

    def test_a_snapshot_missing_a_shard_or_its_tokenizer_is_not_installed(self):
        m = asr_entry(self.name)
        self.put("config.json", "model-00001-of-00002.safetensors", "tokenizer_config.json")
        (self.snap / "model.safetensors.index.json").write_text(json.dumps(
            {"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}))
        self.assertIsNone(T.model_path(m))                       # a shard missing
        self.put("model-00002-of-00002.safetensors")
        self.assertIsNone(T.model_path(m))                       # the tokenizer its config asks for missing
        self.put("vocab.json")
        self.assertIsNone(T.model_path(m))                       # BPE: merges.txt too
        self.put("merges.txt")
        self.assertEqual(T.model_path(m), self.snap)

    def test_no_config_is_not_a_model(self):
        self.put("weights.safetensors")
        self.assertIsNone(T.hf_snapshot(self.repo))
        self.put("config.json")
        self.assertEqual(T.hf_snapshot(self.repo), self.snap)    # mlx whisper: config + one weights file

    def test_a_finished_setup_lists_its_files(self):
        self.put("config.json", "weights.safetensors", "extra.json")
        C.write_text_atomic(T._hf_record(self.repo), json.dumps({"snapshot": "abc123", "files": ["config.json", "weights.safetensors", "extra.json"]}))
        self.assertEqual(T.hf_snapshot(self.repo), self.snap)
        (self.snap / "extra.json").unlink()
        self.assertIsNone(T.hf_snapshot(self.repo))             # a file the finished setup had is gone


class DictationNeedsTheVad(unittest.TestCase):
    """dictation-models: a model whose files are in but whose VAD (silero_vad.onnx) isn't can't dictate — the warm
    server answers model_missing under BLURT_NO_DOWNLOAD — so it isn't "installed" for the dictation key."""

    def test_files_without_the_vad_are_not_installed(self):
        vad = T.MODELS_DIR / "silero_vad.onnx"
        had = vad.read_bytes() if vad.is_file() else None
        self.addCleanup(lambda: vad.write_bytes(had) if had is not None else vad.unlink(missing_ok=True))
        vad.unlink(missing_ok=True)
        # without the copy the skill ships (v1.0.6): what an install that lost it would see
        with mock.patch.object(T, "installed", return_value=True), \
                mock.patch.object(T, "BUNDLED_VAD", T.MODELS_DIR / "no-such-vad.onnx"):
            d = T.dictation_models()
            self.assertFalse(d["vad"])
            local = [r for r in d["models"] if r["files"]]
            self.assertTrue(local)
            vad_models = [r for r in local if T.entry(r["id"]).get("local", True) and not T.entry(r["id"]).get("builtin")]
            self.assertFalse(any(r["installed"] for r in vad_models))
            # macOS's own recogniser finds its own pauses: installed without the VAD (first-minute-speech.md)
            self.assertTrue(all(r["installed"] for r in local if T.entry(r["id"]).get("builtin")))
            vad.parent.mkdir(parents=True, exist_ok=True)
            vad.write_bytes(b"onnx")
            self.assertTrue(all(r["installed"] for r in T.dictation_models()["models"]))


class PolishSetupNeverSaysOkOnAPartialModel(unittest.TestCase):
    def test_both_sources_failing_is_an_error(self):
        name = f"Test-Polish-{os.getpid()}-{time.time_ns()}"
        m = {"id": "test-polish", "repo": f"mlx-community/{name}", "size_mb": 1}
        dest = P.POLISH_DIR / name
        self.addCleanup(lambda: __import__("shutil").rmtree(dest, ignore_errors=True))
        fake = FakeModelScope(FILES, fail_on="tokenizer_config.json")
        hf = mock.Mock(side_effect=RuntimeError("hf down"))
        hf.__name__ = "_huggingface"
        with mock.patch.object(urllib.request, "urlopen", fake), mock.patch.object(P, "_huggingface", hf), \
                mock.patch.object(P, "mirror_on", return_value=True), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(P.Fail):
                P._download(m)
        self.assertIsNone(P.model_path(m))
        ok = FakeModelScope(FILES)
        with mock.patch.object(urllib.request, "urlopen", ok), mock.patch.object(P, "mirror_on", return_value=True), \
                contextlib.redirect_stderr(io.StringIO()):
            P._download(m)
        self.assertEqual(P.model_path(m), dest)


class PartialFilesAreContinued(unittest.TestCase):
    def test_range_continues_and_a_server_ignoring_it_starts_over(self):
        tmp = Path(tempfile.mkdtemp()) / "model.safetensors.part"
        data = bytes(range(256)) * 40
        tmp.write_bytes(data[:1000])
        fake = FakeModelScope({"model.safetensors": data})
        with mock.patch.object(urllib.request, "urlopen", fake):
            got = C.fetch("https://x/model.safetensors", tmp, len(data))
        self.assertEqual(got, len(data))
        self.assertEqual(tmp.read_bytes(), data)
        self.assertEqual(fake.opened, [("model.safetensors", "bytes=1000-")])
        # a server that sends the whole file again (200): written from the start, not appended
        tmp.write_bytes(data[:1000])
        dumb = FakeModelScope({"model.safetensors": data}, ranges=False)
        with mock.patch.object(urllib.request, "urlopen", dumb):
            C.fetch("https://x/model.safetensors", tmp, len(data))
        self.assertEqual(tmp.read_bytes(), data)
        # already whole: nothing is fetched
        with mock.patch.object(urllib.request, "urlopen", mock.Mock(side_effect=AssertionError("fetched"))):
            self.assertEqual(C.fetch("https://x/model.safetensors", tmp, len(data)), len(data))


class OneDownloadOfAModelAtATime(unittest.TestCase):
    def test_a_second_setup_waits_and_finds_it_installed(self):
        name = f"Test-Lock-{os.getpid()}-{time.time_ns()}"
        m = asr_entry(name)
        dest = T.MODELS_DIR / "asr" / name
        self.addCleanup(lambda: __import__("shutil").rmtree(dest, ignore_errors=True))
        runs = []

        def slow_install(entry):
            runs.append(threading.get_ident())
            time.sleep(0.4)
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "config.json").write_text("{}")
            (dest / "model.safetensors").write_bytes(b"w")
            return dest

        vad = T.MODELS_DIR / "silero_vad.onnx"
        if not vad.exists():
            vad.parent.mkdir(parents=True, exist_ok=True)
            vad.write_bytes(b"vad")
            self.addCleanup(vad.unlink)
        out = []
        with mock.patch.object(T, "_install_unlocked", slow_install), mock.patch.object(T, "runs_here", return_value=True):
            ts = [threading.Thread(target=lambda: out.append(T.install_model(m))) for _ in range(2)]
            for t in ts:
                t.start()
            for t in ts:
                t.join(5)
        self.assertEqual(len(runs), 1)                 # downloaded once
        self.assertEqual(out, [dest, dest])            # both callers end with the model


class SetupEndsWithItsApp(unittest.TestCase):
    def test_the_setup_stops_when_its_parent_is_gone(self):
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.6)"])
        threading.Thread(target=parent.wait, daemon=True).start()       # reaped when it ends, as launchd would
        code =("import sys, time; sys.path.insert(0, %r); import _common as C; C.watch_parent(%d, 0.1); time.sleep(20)"
                % (str(SCRIPTS), parent.pid))
        t0 = time.time()
        child = subprocess.run([sys.executable, "-c", code], timeout=15)
        parent.wait()
        self.assertEqual(child.returncode, 143)
        self.assertLess(time.time() - t0, 10)

    def test_setup_takes_parent(self):
        for script in ("transcribe.py", "polish.py"):
            p = subprocess.run([sys.executable, str(SCRIPTS / script), "setup", "--help"], capture_output=True, text=True,
                               env={**os.environ, "BLURT_NO_DOWNLOAD": "1"}, timeout=60)
            self.assertIn("--parent", p.stdout, script)


if __name__ == "__main__":
    unittest.main()
