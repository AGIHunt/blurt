"""Adaptive local speech recognition (docs/design/next-round.md K9): the model registry, hardware tiers, the
recommendation, which model a run uses, resource caps (threads, priority, one batch job at a time), the voice-note
fast path and its warm server, the CLI's JSON, archive installs, and the error metric the benchmark uses.
No models and no network: fake backends stand in. Tests that need a real model skip when it isn't installed.

  uv run --with numpy --with pytest pytest tests/test_asr_select.py -q
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import time
import unittest
import wave
from argparse import Namespace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
RESOURCES = ROOT / "skills" / "blurt" / "recorder" / "macos" / "Sources" / "BlurtApp" / "Resources"
sys.path.insert(0, str(SCRIPTS))
os.environ.setdefault("BLURT_HOME", tempfile.mkdtemp(prefix="blurt-home-"))

import transcribe as T  # noqa: E402

SR = 16000


def hw(os_="darwin", arch="arm64", ram=128.0, gpu=None, perf=6, eff=12, battery=False) -> dict:
    h = {"os": os_, "arch": arch, "chip": "test", "perf_cores": perf, "eff_cores": eff, "ram_gb": ram,
         "gpu": gpu or ({"kind": "apple", "name": "Apple GPU", "cores": 10} if os_ == "darwin" and arch == "arm64"
                        else {"kind": "none", "name": None}),
         "ane": os_ == "darwin" and arch == "arm64", "on_battery": battery}
    h["tier"] = T.tier_for(h)
    return h


@contextlib.contextmanager
def config(cfg: dict):
    """$BLURT_HOME/config.json = cfg for the block, then put back whatever was there.
    global_config() reads $BLURT_HOME at call time, and a test module collected earlier may have pointed it elsewhere
    after transcribe was imported: pin it to T.BLURT_HOME for the block so the config written here is the one read."""
    path = T.BLURT_HOME / "config.json"
    old = path.read_bytes() if path.exists() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg), encoding="utf-8")
    old_env = os.environ.get("BLURT_HOME")
    os.environ["BLURT_HOME"] = str(T.BLURT_HOME)
    try:
        yield
    finally:
        if old_env is None:
            os.environ.pop("BLURT_HOME", None)
        else:
            os.environ["BLURT_HOME"] = old_env
        if old is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(old)


def fake_installed(*ids):
    """Patch T.installed so exactly these registry ids count as downloaded."""
    real = T.installed
    T.installed = lambda m: m["id"] in ids or (not m.get("local", True) and real(m))
    return real


class FakeBackend:
    max_chunk = 10
    model = "fake"

    def __init__(self, *_a, **_k):
        pass

    def transcribe(self, x):
        return [(0.0, len(x) / SR, f"heard {len(x) / SR:.1f}s", "en")]


def write_wav(path: Path, seconds: float = 1.5) -> Path:
    t = np.arange(int(seconds * SR)) / SR
    x = (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())
    return path


def run_cli(*args, env=None, timeout=120):
    e = {**os.environ, "BLURT_HOME": str(T.BLURT_HOME), **(env or {})}
    p = subprocess.run([sys.executable, str(SCRIPTS / "transcribe.py"), *args], capture_output=True, text=True,
                       encoding="utf-8", timeout=timeout, env=e)
    line = next((ln for ln in reversed(p.stdout.splitlines()) if ln.startswith("{")), "{}")
    return p, json.loads(line)


def strings(lang: str) -> dict:
    text = (RESOURCES / f"{lang}.lproj" / "Speech.strings").read_text(encoding="utf-8")
    return dict(re.findall(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', text, re.M))


# ------------------------------------------------------------------ registry
class Registry(unittest.TestCase):
    def test_contract_fields(self):
        ids = [m["id"] for m in T.entries()]
        self.assertEqual(len(ids), len(set(ids)))
        for fixed in ("sensevoice-small", "whisper-large-v3-turbo-mlx", "whisper-large-v3-turbo-ct2", "whisper-large-v3-turbo-q4-mlx"):
            self.assertIn(fixed, ids)
        for m in T.entries():
            for k in ("id", "backend", "model", "languages", "size_mb", "ram_mb", "platforms", "requires", "streaming",
                      "tiers", "verified"):
                self.assertIn(k, m, f"{m['id']}: {k}")
            self.assertIn(m["backend"], T.BACKENDS, m["id"])
            self.assertIn(m["verified"], ("run", "docs"))
            self.assertTrue(m["languages"] == "multi" or (isinstance(m["languages"], list) and m["languages"]))
            if m.get("local", True):
                # macOS's own recogniser has nothing to install (first-minute-speech.md)
                self.assertTrue(m.get("install") or m.get("builtin"), m["id"])
                self.assertIn("rtf_ref", m, m["id"])  # measured on the reference machine (asr-benchmark.md)
            if m.get("package"):
                self.assertEqual(T.EXTRA_PACKAGES.get(m["backend"]), m["package"])

    def test_strings_are_localized(self):
        en, zh = strings("en"), strings("zh-Hans")
        self.assertEqual(set(en), set(zh))
        ph = re.compile(r"%(?:\d+\$)?[@dlfs]+")
        for k in en:
            self.assertEqual(sorted(ph.findall(en[k])), sorted(ph.findall(zh[k])), k)
        for m in T.entries():
            if m.get("quality_note_key"):
                self.assertIn(m["quality_note_key"], en)
        for tier in ("pro", "standard", "light", "minimal"):
            self.assertIn(f"speech.tier.{tier}", en)
        for p in T.PURPOSES:
            self.assertIn(f"speech.purpose.{p}", en)

    def test_bench_samples(self):
        samples = T.registry()["bench"]["samples"]
        for lang in ("zh", "en", "ja", "ko", "es", "fr", "de"):
            self.assertIn(lang, samples)
            self.assertTrue(samples[lang]["text"] and samples[lang]["locale"] and samples[lang]["voices"])


# ------------------------------------------------------------------ tiers and recommendation
class Tiers(unittest.TestCase):
    def test_tiers(self):
        self.assertEqual(hw(ram=128)["tier"], "pro")              # M5 Max
        self.assertEqual(hw(ram=32)["tier"], "pro")
        self.assertEqual(hw(ram=24)["tier"], "standard")
        self.assertEqual(hw(ram=16)["tier"], "standard")
        self.assertEqual(hw(ram=8)["tier"], "light")
        self.assertEqual(hw(ram=4)["tier"], "minimal")
        self.assertEqual(hw("linux", "x86_64", 32, {"kind": "nvidia", "name": "RTX", "vram_gb": 12}, 8, 0)["tier"], "pro")
        self.assertEqual(hw("windows", "x86_64", 16, {"kind": "nvidia", "name": "RTX", "vram_gb": 6}, 4, 0)["tier"], "standard")
        self.assertEqual(hw("linux", "x86_64", 16, None, 8, 0)["tier"], "standard")
        self.assertEqual(hw("windows", "x86_64", 8, None, 4, 0)["tier"], "light")
        self.assertEqual(hw("linux", "x86_64", 16, None, 2, 0)["tier"], "minimal")

    def test_probe_shape(self):
        p = T.probe(refresh=True)
        for k in ("os", "arch", "chip", "perf_cores", "eff_cores", "ram_gb", "gpu", "ane", "on_battery", "tier"):
            self.assertIn(k, p)
        self.assertIn(p["tier"], ("pro", "standard", "light", "minimal"))
        self.assertIn(p["gpu"]["kind"], ("apple", "nvidia", "none"))


class Recommend(unittest.TestCase):
    def pick(self, h, langs, purpose="batch", cfg=None):
        return T.recommend(langs, purpose, h, cfg or {})["pick"]["model"]

    def test_apple_pro(self):
        h = hw(ram=128)
        # Chinese / English: one Qwen3-ASR for every job (v1.0.2) — the one dictation runs on, the 1.7B (v1.0.7)
        for purpose in ("batch", "live", "note"):
            self.assertEqual(self.pick(h, ["zh", "en"], purpose), "qwen3-asr-1.7b-mlx")
        # on battery too: a recording doesn't swap dictation's model for a smaller one
        self.assertEqual(self.pick(hw(ram=128, battery=True), ["zh", "en"]), "qwen3-asr-1.7b-mlx")
        # a base M1 / M2 (too slow for the 1.7B): the 0.6B, as before
        slow = {**h, "chip": "Apple M2"}
        self.assertEqual(self.pick(slow, ["zh", "en"]), "qwen3-asr-0.6b-mlx")
        self.assertEqual(self.pick(h, ["ja", "en"]), "whisper-large-v3-turbo-mlx")       # Japanese: Whisper
        self.assertEqual(self.pick(h, ["de", "en"], "note"), "whisper-large-v3-turbo-mlx")

    def test_apple_one_model_for_chinese_and_english(self):
        for purpose in ("batch", "live", "note"):
            self.assertEqual(self.pick(hw(ram=16), ["zh", "en"], purpose), "qwen3-asr-1.7b-mlx")
            self.assertEqual(self.pick(hw(ram=24), ["en"], purpose), "qwen3-asr-1.7b-mlx")
        self.assertEqual(self.pick(hw(ram=8, perf=4, eff=4), ["zh", "en"], "note"), "sensevoice-small")   # light

    def test_apple_standard(self):
        h = hw(ram=16)
        self.assertEqual(self.pick(h, ["en", "ja"]), "whisper-large-v3-turbo-mlx")
        self.assertEqual(self.pick(h, ["en", "ja"], "live"), "sensevoice-small")
        # the warm purposes take the 4-bit Whisper on 16 GB (arch098); recordings keep the full one
        self.assertEqual(self.pick(h, ["es", "en"], "live"), "whisper-large-v3-turbo-q4-mlx")
        self.assertEqual(self.pick(h, ["de", "en"], "note"), "whisper-large-v3-turbo-q4-mlx")
        self.assertEqual(self.pick(h, ["de", "en"]), "whisper-large-v3-turbo-mlx")
        self.assertEqual(self.pick(hw(ram=32), ["de", "en"], "note"), "whisper-large-v3-turbo-mlx")   # pro unchanged

    def test_apple_light(self):
        h = hw(ram=8, perf=4, eff=4)
        self.assertEqual(self.pick(h, ["zh", "en"]), "sensevoice-small")
        self.assertEqual(self.pick(h, ["es"]), "whisper-large-v3-turbo-q4-mlx")

    def test_minimal_points_to_the_cloud(self):
        h = hw(ram=4, perf=2, eff=2)
        r = T.recommend(["fr"], "batch", h, {})
        self.assertTrue(r.get("cloud_recommended"))
        self.assertEqual(r["pick"]["model"], "sensevoice-small")
        self.assertFalse(T.recommend(["zh"], "batch", h, {}).get("cloud_recommended"))

    def test_cpu_only_and_nvidia(self):
        cpu = hw("linux", "x86_64", 16, None, 8, 0)
        self.assertEqual(self.pick(cpu, ["zh", "en"]), "sensevoice-small")
        self.assertEqual(self.pick(cpu, ["de"]), "qwen3-asr-0.6b-onnx")
        nv = hw("windows", "x86_64", 32, {"kind": "nvidia", "name": "RTX", "vram_gb": 12}, 8, 0)
        self.assertEqual(self.pick(nv, ["ja", "en"]), "whisper-large-v3-turbo-ct2")
        self.assertEqual(self.pick(nv, ["ja", "en"], "note"), "sensevoice-small")

    def test_never_an_mlx_model_off_apple_silicon(self):
        for h in (hw("linux", "x86_64", 64, None, 16, 0), hw("darwin", "x86_64", 32, {"kind": "none"}, 8, 0)):
            for langs in (["zh"], ["de"], ["ko", "fr"]):
                for p in T.PURPOSES:
                    m = T.entry(self.pick(h, langs, p))
                    self.assertTrue(T.runs_here(m, f"{h['os']}-{h['arch']}"), (h["os"], langs, p, m["id"]))

    def test_battery_goes_lighter(self):
        h = hw(ram=16, battery=True)
        r = T.recommend(["es"], "batch", h, {})
        self.assertEqual(r["effective_tier"], "light")
        self.assertEqual(r["pick"]["model"], "whisper-large-v3-turbo-q4-mlx")
        self.assertEqual(T.recommend(["es"], "batch", h, {"on_battery": "same"})["effective_tier"], "standard")

    def test_candidates(self):
        r = T.recommend(["zh", "es"], "batch", hw(ram=16), {})
        self.assertEqual(r["languages"], ["zh", "es"])
        row = next(c for c in r["candidates"] if c["id"] == "sensevoice-small")
        self.assertEqual(row["speaks"], ["zh"])
        for c in r["candidates"]:
            for k in ("id", "languages", "size_mb", "ram_mb", "rtf_est", "quality_note_key", "installed", "fits"):
                self.assertIn(k, c)
        self.assertEqual(r["candidates"][0]["id"], r["pick"]["model"])

    def test_user_languages(self):
        self.assertEqual(T.user_languages({"languages": ["ja", "ko"]}), ["ja", "ko"])
        self.assertEqual(T.user_languages({"languages": "es, fr"}), ["es", "fr"])
        self.assertIn("en", T.user_languages({}))


# ------------------------------------------------------------------ which model a run uses
class Select(unittest.TestCase):
    def setUp(self):
        self.real = fake_installed("sensevoice-small")
        self.addCleanup(setattr, T, "installed", self.real)

    def test_auto_uses_only_what_is_installed(self):
        with config({"asr": {"languages": ["de", "en"]}}):
            for p in T.PURPOSES:
                self.assertEqual(T.select(p)["id"], "sensevoice-small")
        T.installed = lambda m: m["id"] in ("sensevoice-small", "whisper-large-v3-turbo-mlx", "qwen3-asr-0.6b-onnx")
        with config({"asr": {"languages": ["de", "en"]}}):
            want = T.recommend(["de", "en"], "batch", cfg={"languages": ["de", "en"]})["pick"]["model"]
            if T.installed(T.entry(want)) and T.runs_here(T.entry(want)):
                self.assertEqual(T.select("batch")["id"], want)

    def test_manual_choices(self):
        with config({"asr": {"auto": False, "models": {"batch": "whisper-large-v3-turbo-q4-mlx", "note": "sensevoice-small"}}}):
            self.assertEqual(T.select("batch")["id"], "whisper-large-v3-turbo-q4-mlx")
            self.assertEqual(T.select("note")["id"], "sensevoice-small")
            self.assertEqual(T.select("live")["id"], "sensevoice-small")  # nothing chosen: the legacy default
        with config({"asr": {"backend": "mlx-whisper"}}):  # a legacy explicit backend stays the user's choice
            self.assertFalse(T.is_auto(T.asr_config()))
            self.assertEqual(T.select("batch")["id"], "whisper-large-v3-turbo-mlx")
        with config({"asr": {"backend": "faster-whisper", "model": "large-v3-turbo"}}):
            self.assertEqual(T.select("batch")["id"], "whisper-large-v3-turbo-ct2")
        with config({"asr": {"backend": "sensevoice"}}):
            self.assertTrue(T.is_auto(T.asr_config()))

    def test_explicit_options_win(self):
        with config({"asr": {"auto": False, "models": {"batch": "whisper-large-v3-turbo-q4-mlx"}}}):
            a = Namespace(backend=None, model=None, model_id="sensevoice-small", language=None, prompt=None)
            self.assertEqual(T.resolve_backend(a, "batch"), "sensevoice")
            a = Namespace(backend="mlx-whisper", model="mlx-community/whisper-large-v3-turbo-q4", model_id=None, language="auto",
                          prompt=None)
            self.assertEqual(T.resolve_backend(a), "mlx-whisper")
            self.assertEqual((a.model_id, a.model, a.language), ("whisper-large-v3-turbo-q4-mlx", "mlx-community/whisper-large-v3-turbo-q4", None))
            with self.assertRaises(T.Fail) as e:
                T.select("batch", Namespace(model_id="no-such-model"))
            self.assertEqual(e.exception.code, "unknown_model")

    def test_local_only_refuses_cloud(self):
        with config({"privacy": {"local_asr": True}, "asr": {"auto": False, "backend": "openai"}}):
            with self.assertRaises(T.Fail) as e:
                T.resolve_backend(Namespace(backend=None, model=None, model_id=None, language=None, prompt=None))
            self.assertEqual(e.exception.code, "privacy")


# ------------------------------------------------------------------ resource caps
class Limits(unittest.TestCase):
    def test_defaults_and_overrides(self):
        self.assertEqual(T.limits(hw(perf=6), {})["threads"], 3)    # M5 Max: 6 super cores → 3
        self.assertEqual(T.limits(hw(perf=12), {})["threads"], 4)
        self.assertEqual(T.limits(hw(perf=1), {})["threads"], 1)
        lim = T.limits(hw(), {})
        self.assertEqual((lim["max_concurrent"], lim["max_memory_fraction"]), (1, 0.25))
        self.assertEqual(lim["priority"]["batch"], "utility")
        self.assertEqual(lim["priority"]["note"], "user-initiated")
        lim = T.limits(hw(), {"limits": {"threads": 2, "max_concurrent": 2, "priority": "background",
                                         "max_memory_fraction": 0.4}})
        self.assertEqual((lim["threads"], lim["max_concurrent"], lim["priority"]["batch"], lim["max_memory_fraction"]),
                         (2, 2, "background", 0.4))

    def test_one_batch_job_at_a_time(self):
        """A second transcription waits for the slot, says so, and records it on its job (K4 events)."""
        holder = subprocess.Popen([sys.executable, "-c", textwrap.dedent(f"""
            import sys, time; sys.path.insert(0, {str(SCRIPTS)!r})
            import transcribe as T
            with T.AsrSlot(1):
                print("held", flush=True); time.sleep(2.0)
        """)], stdout=subprocess.PIPE, text=True, env={**os.environ, "BLURT_HOME": str(T.BLURT_HOME)})
        self.addCleanup(holder.wait)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        job = f"j-test-{os.getpid()}"
        os.environ["BLURT_JOB"] = job
        self.addCleanup(os.environ.pop, "BLURT_JOB", None)
        err = io.StringIO()
        t0 = time.time()
        with contextlib.redirect_stderr(err), T.AsrSlot(1, poll=0.05) as slot:
            waited = time.time() - t0
            self.assertEqual(slot.slot, 0)
        self.assertGreater(waited, 1.0)
        self.assertIn("queued", err.getvalue())
        events = [json.loads(ln) for ln in (T.BLURT_HOME / "jobs" / f"{job}.events.jsonl").read_text().splitlines()]
        self.assertEqual([e["event"] for e in events], ["asr.queued", "asr.started"])
        self.assertEqual(events[0]["step"], {"id": "transcribe", "state": "pending"})
        self.assertEqual(events[1]["step"]["state"], "running")

    def test_slots_are_counted_and_time_out(self):
        with T.AsrSlot(2) as a, T.AsrSlot(2, timeout=60) as b:
            self.assertEqual({a.slot, b.slot}, {0, 1})
        holder = subprocess.Popen([sys.executable, "-c", textwrap.dedent(f"""
            import sys, time; sys.path.insert(0, {str(SCRIPTS)!r})
            import transcribe as T
            with T.AsrSlot(1):
                print("held", flush=True); time.sleep(1.5)
        """)], stdout=subprocess.PIPE, text=True, env={**os.environ, "BLURT_HOME": str(T.BLURT_HOME)})
        self.addCleanup(holder.wait)
        holder.stdout.readline()
        with self.assertRaises(T.Fail) as e, contextlib.redirect_stderr(io.StringIO()):
            with T.AsrSlot(1, timeout=0.3, poll=0.05):
                pass
        self.assertEqual((e.exception.code, e.exception.exit_code), ("lock_timeout", 3))

    def test_batch_priority_reaches_every_thread(self):
        """throttle('batch'): nice 10, thread pools capped, and on macOS a utility QoS clamp — CPU time of worker
        threads (the kind onnxruntime starts) is accounted as utility, not as the default class."""
        script = Path(tempfile.mkdtemp()) / "burn.py"
        script.write_text(textwrap.dedent(f"""
            import json, os, sys, threading, time
            sys.path.insert(0, {str(SCRIPTS)!r})
            import transcribe as T
            T.throttle("batch", 2)
            q0 = T.qos_cpu_seconds() or {{}}
            def burn():
                t = time.time()
                while time.time() - t < 0.6: sum(i * i for i in range(2000))
            ts = [threading.Thread(target=burn) for _ in range(2)]
            [t.start() for t in ts]; [t.join() for t in ts]
            q1 = T.qos_cpu_seconds() or {{}}
            print(json.dumps({{"nice": os.getpriority(os.PRIO_PROCESS, 0), "omp": os.environ.get("OMP_NUM_THREADS"),
                              "clamp": os.environ.get("BLURT_QOS_CLAMP"),
                              "qos": {{k: round(v - q0.get(k, 0), 2) for k, v in q1.items()}}}}))
        """))
        p = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, timeout=60,
                           env={**os.environ, "BLURT_HOME": str(T.BLURT_HOME)})
        out = json.loads(p.stdout.strip().splitlines()[-1])
        self.assertEqual((out["nice"], out["omp"]), (10, "2"))
        if sys.platform == "darwin" and Path("/usr/sbin/taskpolicy").exists():
            self.assertEqual(out["clamp"], "utility")
            q = out["qos"]  # CPU seconds the worker threads burnt, per QoS class
            self.assertGreater(q.get("utility", 0), 0.9 * sum(q.values()), q)

    def test_interactive_purposes_keep_normal_priority(self):
        p = subprocess.run([sys.executable, "-c", textwrap.dedent(f"""
            import os, sys; sys.path.insert(0, {str(SCRIPTS)!r})
            import transcribe as T
            print(T.apply_priority("user-initiated"), os.getpriority(os.PRIO_PROCESS, 0))
        """)], capture_output=True, text=True, timeout=60, env={**os.environ, "BLURT_HOME": str(T.BLURT_HOME)})
        # unchanged from what it inherited (a test runner may itself run niced, e.g. in the background)
        self.assertTrue(p.stdout.strip().endswith(f" {os.getpriority(os.PRIO_PROCESS, 0)}"), p.stdout + p.stderr)

    def test_real_thread_cap(self):
        """With the real SenseVoice model (skipped when not downloaded): 1 thread ≈ 1 busy core, 4 threads > 1.5."""
        try:
            import sherpa_onnx  # noqa: F401
        except ImportError:
            self.skipTest("sherpa-onnx not installed")
        if not (T.MODELS_DIR / "sensevoice" / "model.int8.onnx").exists():
            self.skipTest("SenseVoice not downloaded")
        x = (np.random.default_rng(0).standard_normal(SR * 8) * 0.1).astype(np.float32)
        cores = {}
        for n in (1, 4):
            b = T.SenseVoice(Namespace(threads=n, language=None, prompt=None))
            b.transcribe(x[:SR])
            c0, t0 = os.times(), time.perf_counter()
            for _ in range(3):
                b.transcribe(x)
            dt, c1 = time.perf_counter() - t0, os.times()
            cores[n] = ((c1.user - c0.user) + (c1.system - c0.system)) / dt
        self.assertLess(cores[1], 1.35, cores)
        self.assertGreater(cores[4], 1.5, cores)


# ------------------------------------------------------------------ voice notes
class Notes(unittest.TestCase):
    def setUp(self):
        self.patches = {"BACKENDS": T.BACKENDS, "vad_segments": T.vad_segments}
        T.BACKENDS = {**T.BACKENDS, "sensevoice": FakeBackend}
        T.vad_segments = lambda x, max_speech=25: [(0.0, len(x) / SR)]
        self.real = fake_installed("sensevoice-small")
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        for k, v in self.patches.items():
            setattr(T, k, v)
        T.installed = self.real

    def test_note_in_process(self):
        with config({"asr": {"auto": False, "backend": "sensevoice"}}):
            r = T.NoteEngine().note(write_wav(self.tmp / "n.wav", 1.5))
        self.assertTrue(r["ok"])
        self.assertEqual((r["text"], r["language"], r["model"]), ("heard 1.5s", "en", "sensevoice-small"))
        self.assertIsInstance(r["ms"], int)

    def test_warm_server(self):
        args = Namespace(preload=True, idle=0.8, exit_after=4, parent=None)
        out = io.StringIO()
        with config({"asr": {"auto": False, "backend": "sensevoice"}}):
            def serve():
                with contextlib.redirect_stdout(out):
                    T.cmd_serve(args)
            th = threading.Thread(target=serve, daemon=True)
            th.start()
            deadline = time.time() + 10
            while not T.SERVE_FILE.exists() and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(T.SERVE_FILE.exists())
            self.assertTrue(T._server_call({"cmd": "ping"})["loaded"])
            r = T._server_call({"cmd": "note", "wav": str(write_wav(self.tmp / "s.wav", 2.0)), "language": "auto"})
            self.assertEqual((r["ok"], r["text"]), (True, "heard 2.0s"))
            info = json.loads(T.SERVE_FILE.read_text())
            import socket
            with socket.create_connection(("127.0.0.1", info["port"]), timeout=2) as s:  # wrong token
                s.sendall(b'{"cmd": "ping", "token": "nope"}\n')
                self.assertEqual(json.loads(s.recv(4096))["code"], "auth")
            # the model unused for 0.8 s: the server ends — an unload kept most of the memory resident (arch091)
            th.join(10)
        self.assertFalse(th.is_alive())
        self.assertFalse(T.SERVE_FILE.exists())

    def serve_in_thread(self, args, stderr=None):
        out = io.StringIO()

        def serve():
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(stderr or out):
                T.cmd_serve(args)
        th = threading.Thread(target=serve, daemon=True)
        th.start()
        deadline = time.time() + 10
        while not T.SERVE_FILE.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(T.SERVE_FILE.exists())
        return th, out

    def test_a_failed_preload_leaves_no_run_file(self):
        # v0.9 dogfood: a run file left pointing at a dead (or stuck) process — the app trusted it and waited for a
        # server that would never answer
        class Broken(FakeBackend):
            def __init__(self, *_a, **_k):
                raise T.Fail("the model is broken", "error")
        T.BACKENDS = {**T.BACKENDS, "sensevoice": Broken}
        with config({"asr": {"auto": False, "backend": "sensevoice"}}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(T.Fail):
                T.cmd_serve(Namespace(preload=True, idle=600, exit_after=1800, parent=None))
        self.assertFalse(T.SERVE_FILE.exists())

    def test_a_server_ends_without_the_interpreters_teardown(self):
        # a finalizer deadlocked during teardown kept servers alive for hours: serve ends with os._exit, after its
        # run file is gone (the finally in cmd_serve) — also when it failed
        ended = []

        def fake_exit(code=0):
            ended.append(code)
            raise SystemExit(code)
        saved = (T.cmd_serve, T.server_exit, sys.argv)
        try:
            T.server_exit = fake_exit
            sys.argv = ["transcribe.py", "serve"]
            T.cmd_serve = lambda a: None
            with self.assertRaises(SystemExit):
                T.main()

            def fails(a):
                raise T.Fail("no", "deps", 4)
            T.cmd_serve = fails
            with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                T.main()
        finally:
            T.cmd_serve, T.server_exit, sys.argv = saved
        self.assertEqual(ended, [0, 4])

    def test_warm_server_exits_when_asked(self):
        # dict026: Blurt quitting (or anyone) asks the server to go, and the memory comes back at once
        with config({"asr": {"auto": False, "backend": "sensevoice"}}):
            th, out = self.serve_in_thread(Namespace(preload=True, idle=600, exit_after=1800, parent=None))
            self.assertEqual(T._server_call({"cmd": "exit"})["ok"], True)
            th.join(5)
        self.assertFalse(th.is_alive())
        self.assertFalse(T.SERVE_FILE.exists())
        self.assertIn("serve: exiting (asked)", out.getvalue())

    def test_warm_server_ends_with_its_app(self):
        # started by the app with --parent: once that process is gone (a quit, a crash), the server ends too
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            with config({"asr": {"auto": False, "backend": "sensevoice"}}):
                th, out = self.serve_in_thread(Namespace(preload=True, idle=600, exit_after=1800, parent=child.pid))
                self.assertEqual(json.loads(T.SERVE_FILE.read_text())["parent"], child.pid)
                self.assertTrue(T._server_call({"cmd": "ping"})["ok"])
                child.kill()
                child.wait()
                th.join(5)
        finally:
            if child.poll() is None:
                child.kill()
        self.assertFalse(th.is_alive())
        self.assertIn("serve: exiting (parent_gone)", out.getvalue())
        self.assertFalse(T.SERVE_FILE.exists())

    def test_warm_server_cleans_up_when_its_app_pipe_is_gone(self):
        # the app's stderr pipe closes with it: the server's last word must not stop it removing its run file
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        dead = io.StringIO()
        try:
            with config({"asr": {"auto": False, "backend": "sensevoice"}}):
                th, _out = self.serve_in_thread(Namespace(preload=True, idle=600, exit_after=1800, parent=child.pid), dead)
                dead.close()                                   # writes now raise, as on a closed pipe
                child.kill()
                child.wait()
                th.join(5)
        finally:
            if child.poll() is None:
                child.kill()
        self.assertFalse(th.is_alive())
        self.assertFalse(T.SERVE_FILE.exists())


# ------------------------------------------------------------------ CLI
class CLI(unittest.TestCase):
    def test_probe(self):
        p, out = run_cli("probe")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(out["ok"])
        self.assertIn(out["tier"], ("pro", "standard", "light", "minimal"))
        self.assertIn("threads", out["limits"])

    def test_models_and_recommend(self):
        p, out = run_cli("models")
        self.assertEqual(p.returncode, 0, p.stderr)
        ids = {m["id"] for m in out["models"]}
        self.assertTrue({m["id"] for m in T.entries()} <= ids)
        self.assertEqual(set(out["selected"]), set(T.PURPOSES))
        self.assertEqual(set(out["recommended"]), set(T.PURPOSES))
        for k in ("models_dir", "auto", "hardware", "limits", "languages"):
            self.assertIn(k, out)
        p, out = run_cli("recommend", "--languages", "de,en", "--purpose", "batch")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(out["languages"], ["de", "en"])
        self.assertIn(out["pick"]["model"], {c["id"] for c in out["candidates"]})

    def test_errors_are_json_with_codes(self):
        p, out = run_cli("note", "/nonexistent/voice.wav")
        self.assertEqual((p.returncode, out["ok"], out["code"]), (1, False, "not_found"))
        p, out = run_cli("bench", "--model-id", "no-such-model")
        self.assertEqual((p.returncode, out["code"]), (1, "unknown_model"))

    def test_auto_plan(self):
        p, out = run_cli("auto")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(set(out["models"]), set(T.PURPOSES))
        for n in out["needs_download"]:
            self.assertTrue(n["size_mb"] > 0 and n["purposes"])

    def test_auto_apply_pins_only_the_recommended(self):
        # a stand-in (a Whisper from a shared cache while the 1.7B isn't in) is never pinned: once the 1.7B is in,
        # it runs — before the next `auto --apply`
        probe = T.probe
        T.probe = lambda *a, **k: {**hw(ram=128), "fingerprint": "test"}
        real = fake_installed("apple-speech", "whisper-large-v3-turbo-mlx", "silero-vad")
        try:
            with config({"asr": {"languages": ["zh", "en"]}}):
                out = T.auto_plan(True)
                self.assertEqual(out["models"]["batch"], "whisper-large-v3-turbo-mlx")
                self.assertEqual(T.global_config()["asr"]["models"], {})
                T.installed = lambda m: m["id"] in ("apple-speech", "whisper-large-v3-turbo-mlx", "qwen3-asr-1.7b-mlx",
                                                    "silero-vad")
                T.auto_plan(True)
                self.assertEqual(T.global_config()["asr"]["models"]["note"], "qwen3-asr-1.7b-mlx")
        finally:
            T.probe, T.installed = probe, real


# ------------------------------------------------------------------ installs, metric, language codes
class Install(unittest.TestCase):
    def test_archive_install_keeps_only_what_runs(self):
        src = Path(tempfile.mkdtemp())
        top = src / "sherpa-onnx-test-model"
        (top / "tokenizer").mkdir(parents=True)
        (top / "test_wavs").mkdir()
        (top / "model.onnx").write_bytes(b"onnx")
        (top / "tokenizer" / "vocab.json").write_text("{}")
        (top / "test_wavs" / "a.wav").write_bytes(b"x" * 100)
        arc = src / "m.tar.bz2"
        with tarfile.open(arc, "w:bz2") as tar:
            tar.add(top, arcname=top.name)
        vad = T.MODELS_DIR / "silero_vad.onnx"
        if not vad.exists():
            vad.parent.mkdir(parents=True, exist_ok=True)
            vad.write_bytes(b"vad")
            self.addCleanup(vad.unlink)
        m = {"id": "test-archive", "backend": "sensevoice", "install": {
            "archive": arc.as_uri(), "dir": f"test-archive-{os.getpid()}", "keep": ["model.onnx", "tokenizer/"]}}
        with contextlib.redirect_stderr(io.StringIO()):
            path = T.install_model(m)
        self.addCleanup(lambda: __import__("shutil").rmtree(path, ignore_errors=True))
        self.assertEqual(sorted(str(p.relative_to(path)) for p in path.rglob("*")),
                         ["model.onnx", "tokenizer", "tokenizer/vocab.json"])
        self.assertTrue(T.installed(m))

    def test_error_rate(self):
        self.assertEqual(T.error_rate("Hello, world!", "hello world", "en"), 0.0)
        self.assertEqual(T.error_rate("the cat sat", "the hat sat", "en"), round(1 / 3, 4))
        self.assertEqual(T.error_rate("登录按钮", "登陆按钮", "zh"), 0.25)
        self.assertEqual(T.error_rate("ログイン。", "ログイン", "ja"), 0.0)
        self.assertEqual(T.error_rate("", "", "en"), 0.0)

    def test_text_helpers(self):
        # syllables: the "too little text for the speech" check that triggers Whisper's per-language split
        self.assertEqual(T.syllables("我先打开登录页面"), 8)
        self.assertEqual(T.syllables("ログインボタン"), 7)
        self.assertEqual(T.syllables("로그인 버튼"), 5)
        self.assertEqual(T.syllables("One idea, we could add an export"), 10)  # an estimate: silent e counts
        self.assertEqual(T.cjk_punctuation("我先打开登录页面,输入邮箱和密码,然后点击登录按钮。"),
                         "我先打开登录页面，输入邮箱和密码，然后点击登录按钮。")
        self.assertEqual(T.cjk_punctuation("Hello, world: ok?"), "Hello, world: ok?")
        self.assertEqual(T.cjk_punctuation("按钮?没反应! 再试"), "按钮？没反应！再试")

    def test_language_codes(self):
        self.assertEqual(T.lang_code("<|zh|>"), "zh")
        self.assertEqual(T.lang_code("Japanese"), "ja")
        self.assertEqual(T.lang_code("yue"), "yue")
        self.assertIsNone(T.lang_code(""))

    def test_transcript_carries_language(self):
        backend = FakeBackend()
        results = [(0.0, 1.0, "hi", None, "en"), (1.0, 2.0, "你好", None, "zh"), (2.0, 3.0, "again", None, "en")]
        d = T.build_transcript("r.mp4", "fake", backend, Namespace(model=None), 3, 3, 0, results, 0.1)
        self.assertEqual([s["language"] for s in d["segments"]], ["en", "zh", "en"])
        self.assertEqual(d["languages"], ["en", "zh"])


# ------------------------------------------------------------------ macOS's own recogniser (first-minute-speech.md)
class AppleSpeechSelect(unittest.TestCase):
    """Nothing downloaded: macOS 26's SpeechTranscriber runs dictation, voice notes and recordings; a local model takes
    over as soon as one is installed; never for a language it doesn't speak."""

    def test_it_runs_when_nothing_is_downloaded(self):
        real = fake_installed("apple-speech")
        try:
            with config({"asr": {"languages": ["zh", "en"]}}):
                self.assertEqual(T.select("note")["id"], "apple-speech")
                self.assertEqual(T.select("batch")["id"], "apple-speech")
                d = T.dictation_models(hw())
                self.assertEqual(d["selected"], "apple-speech")
                self.assertTrue(d["ready"])                 # no VAD needed: it finds its own pauses
                self.assertEqual(d["missing"], [])
                # the download still offered (the upgrade): this Mac's (dictation_tier — 128 GB, not a base M1 / M2)
                self.assertEqual(d["recommended"], "qwen3-asr-1.7b-mlx")
                self.assertEqual(d["plan"]["recognizer"], "qwen3-asr-1.7b-mlx")
                self.assertTrue({m["id"]: m for m in d["models"]}["apple-speech"]["builtin"])
                # an 8 GB Mac: Fun-ASR-Nano for a Chinese + English speaker (no local polish beside it), never macOS's own
                self.assertEqual(T.dictation_models(hw(ram=8.0))["recommended"], "fun-asr-nano-mlx")
                # 16 GB: the 1.7B, unless the chip is a base M1 / M2 or the 1.7B measured too slow here
                self.assertEqual(T.dictation_models(hw(ram=16.0))["recommended"], "qwen3-asr-1.7b-mlx")
                self.assertEqual(T.dictation_models({**hw(ram=16.0), "chip": "Apple M1"})["recommended"],
                                 "fun-asr-nano-mlx")
            with config({"asr": {"languages": ["de", "en"]}}):
                # a language Fun-ASR-Nano doesn't speak: the 0.6B, and no Fun-ASR-Nano row
                d = T.dictation_models(hw(ram=8.0))
                self.assertEqual(d["recommended"], "qwen3-asr-0.6b-mlx")
                self.assertNotIn("fun-asr-nano-mlx", [m["id"] for m in d["models"]])
                self.assertEqual(T.dictation_models({**hw(ram=16.0), "chip": "Apple M1"})["recommended"],
                                 "qwen3-asr-0.6b-mlx")
        finally:
            T.installed = real

    def vad(self, present: bool):
        """silero_vad.onnx in (or out of) the test models dir for this test, as it was afterwards"""
        f = T.MODELS_DIR / "silero_vad.onnx"
        was = f.read_bytes() if f.exists() else None
        if present:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(was or b"vad")
        else:
            f.unlink(missing_ok=True)
            # and none shipped with the skill (v1.0.6's models/silero_vad.onnx, which bundled_vad() would copy in)
            bundled = T.BUNDLED_VAD
            T.BUNDLED_VAD = f.parent / "no-bundled-vad.onnx"
            self.addCleanup(setattr, T, "BUNDLED_VAD", bundled)
        self.addCleanup(lambda: f.write_bytes(was) if was is not None else f.unlink(missing_ok=True))

    def test_model_files_without_the_vad_dont_beat_macos_speech(self):
        # a Whisper in a shared Hugging Face cache, no silero_vad.onnx yet: the first Fn must listen, not ask for 1 MB
        self.vad(False)
        real = fake_installed("apple-speech", "whisper-large-v3-turbo-mlx")
        try:
            with config({"asr": {"languages": ["zh", "en"]}}):
                self.assertEqual(T.select("note")["id"], "apple-speech")
                d = T.dictation_models(hw())
                self.assertEqual(d["selected"], "apple-speech")
                self.assertTrue(d["ready"])
                self.assertEqual(d["missing"], [])
                self.vad(True)
                self.assertEqual(T.select("note")["id"], "whisper-large-v3-turbo-mlx")   # the VAD is in: it takes over
        finally:
            T.installed = real

    def test_a_chosen_model_still_asks_for_the_vad(self):
        self.vad(False)
        real = fake_installed("apple-speech", "qwen3-asr-1.7b-mlx")
        try:
            with config({"asr": {"languages": ["zh", "en"]}, "record": {"dictation": {"asr_model": "qwen3-asr-1.7b-mlx"}}}):
                d = T.dictation_models(hw())
                self.assertEqual(d["selected"], "qwen3-asr-1.7b-mlx")
                self.assertEqual(d["missing"], ["silero-vad"])
        finally:
            T.installed = real

    def test_a_local_model_takes_over(self):
        self.vad(True)
        real = fake_installed("apple-speech", "qwen3-asr-1.7b-mlx")
        try:
            with config({"asr": {"languages": ["zh", "en"]}}):
                self.assertEqual(T.dictation_models(hw())["selected"], "qwen3-asr-1.7b-mlx")
                self.assertEqual(T.select("note")["id"], "qwen3-asr-1.7b-mlx")
        finally:
            T.installed = real

    def test_never_for_a_language_it_does_not_speak(self):
        real = fake_installed("apple-speech")
        try:
            with config({"asr": {"languages": ["th"]}}):
                self.assertNotEqual(T.select("note")["id"], "apple-speech")
        finally:
            T.installed = real

    def test_locale(self):
        with config({"asr": {"languages": ["zh", "en"]}}):
            self.assertEqual(T.apple_locale(None), "zh-CN")
            self.assertEqual(T.apple_locale("en"), "en-US")
            self.assertIsNone(T.apple_locale("th"))
        # English first, Chinese too: the Chinese recogniser, which hears the English words as well (as the app's
        # AppleSpeech.automatic) — an English Mac whose user speaks Chinese
        with config({"asr": {"languages": ["en", "zh"]}}):
            self.assertEqual(T.apple_locale("auto"), "zh-CN")
        with config({"asr": {"languages": ["en", "fr"]}}):
            self.assertEqual(T.apple_locale(None), "en-US")
        with config({"asr": {"languages": ["en", "zh"], "language": "en"}}):
            self.assertEqual(T.apple_locale(None), "en-US")

    def test_whole_audio_through_the_app_without_vad(self):
        # the Blurt executable's `--speech` answer, faked: one line of JSON with each phrase's time
        with tempfile.TemporaryDirectory() as d:
            helper = Path(d) / "blurt-recorder"
            helper.write_text(textwrap.dedent("""\
                #!/bin/sh
                echo '{"event":"apple_speech_assets","result":"installed"}'
                echo '{"ok":true,"text":"你好。世界。","locale":"'"$4"'","segments":[{"start":0.1,"end":0.9,"text":"你好。"},{"start":1.0,"end":1.4,"text":"世界。"}]}'
                """))
            helper.chmod(0o755)
            old = (os.environ.get("BLURT_APP_BIN"), T._APPLE_OK, T.vad_segments)
            os.environ["BLURT_APP_BIN"] = str(helper)
            T._APPLE_OK = True

            def no_vad(*_a, **_k):
                raise AssertionError("macOS's recogniser needs no VAD")
            T.vad_segments = no_vad
            try:
                with config({"asr": {"languages": ["zh"]}}):
                    b = T.AppleSpeech(Namespace(language=None))
                    self.assertTrue(b.set_vocab([{"term": "tmux"}]))
                    wav = write_wav(Path(d) / "a.wav", 1.5)
                    res, speech, blank = T.transcribe_track(T.read_wav(wav), b, "apple", 1, quiet=True)
            finally:
                os.environ.pop("BLURT_APP_BIN", None)
                if old[0]:
                    os.environ["BLURT_APP_BIN"] = old[0]
                T._APPLE_OK, T.vad_segments = old[1], old[2]
        self.assertEqual([r[2] for r in res], ["你好。", "世界。"])
        self.assertEqual(res[1][:2], (1.0, 1.4))
        self.assertEqual(res[0][4], "zh")
        self.assertAlmostEqual(speech, 1.5, places=2)
        self.assertEqual(blank, 0.0)

    def test_it_needs_macos_26_and_the_app(self):
        old = (os.environ.get("BLURT_APP_BIN"), T._APPLE_OK, T.apple_speech_helper)
        try:
            os.environ["BLURT_APP_BIN"] = "/nonexistent/blurt-recorder"
            T._APPLE_OK = None
            T.apple_speech_helper = lambda: None
            self.assertFalse(T.apple_speech_ok())
            self.assertIsNotNone(T.backend_ready("apple"))
        finally:
            T.apple_speech_helper = old[2]
            os.environ.pop("BLURT_APP_BIN", None)
            if old[0]:
                os.environ["BLURT_APP_BIN"] = old[0]
            T._APPLE_OK = old[1]


class DictationTier(unittest.TestCase):
    """Defaults by Mac (docs/design/dictation.md §Defaults by Mac): the shared fixture BlurtCore's DictationTier is
    checked against too."""

    def test_the_shared_fixture(self):
        rows = [json.loads(l) for l in (ROOT / "tests" / "fixtures" / "dictation_tier.jsonl").read_text().splitlines() if l.strip()]
        self.assertGreaterEqual(len(rows), 10)
        for r in rows:
            got = T.dictation_tier(r["ram_gb"], r["rtf"], r["slow"], r["cloud"], r.get("languages"))
            for k, v in r["want"].items():
                self.assertEqual(got[k], v, f"{r['case']}: {k}")
            self.assertEqual(got["second_transcript"], got["cloud_polish"])
            self.assertEqual(got["first"], "apple-speech")

    def test_slow_chips(self):
        self.assertTrue(T.slow_chip("Apple M2"))
        self.assertFalse(T.slow_chip("Apple M2 Max"))
        self.assertFalse(T.slow_chip(None))

    def test_a_measured_rtf_decides(self):
        real = T._bench_results
        try:
            T._bench_results = lambda: {"qwen3-asr-1.7b-mlx": {"rtf": 0.09}}
            with config({"asr": {"languages": ["fr", "en"]}}):
                self.assertEqual(T.dictation_models(hw(ram=16.0))["recommended"], "qwen3-asr-0.6b-mlx")
            with config({"asr": {"languages": ["zh", "en"]}}):
                self.assertEqual(T.dictation_models(hw(ram=16.0))["recommended"], "fun-asr-nano-mlx")
        finally:
            T._bench_results = real


class CloudSpeed(unittest.TestCase):
    """asr.cloud.speed: every cloud service can hear the audio sped up (default 1x since dictation sends the whole take:
    2.02 % at 1x against 3.32 % at 1.5x on the founder's takes); times come back on the original
    timeline; dictation offers a cloud service once its key is set (first-minute-speech.md §2.4)."""

    def test_setting(self):
        with config({}):
            self.assertEqual(T.cloud_speed(), 1.0)
        with config({"asr": {"cloud": {"speed": 1.5}}}):
            self.assertEqual(T.cloud_speed(), 1.5)
        with config({"asr": {"cloud": {"speed": 2}}}):
            self.assertEqual(T.cloud_speed(), 2.0)
        with config({"asr": {"cloud": {"speed": 1.2, "openai-compatible": {"service": "groq"}}}}):
            self.assertEqual(T.cloud_speed(), 1.0)      # the nearest offered one
        with config({"asr": {"cloud": {"speed": "fast"}}}):
            self.assertEqual(T.cloud_speed(), 1.0)

    @unittest.skipUnless(__import__("shutil").which("ffmpeg"), "needs ffmpeg")
    def test_speed_up_keeps_length_ratio(self):
        x = (0.3 * np.sin(2 * np.pi * 220 * np.arange(3 * SR) / SR)).astype(np.float32)
        self.assertEqual(len(T.speed_up(x, 1.0)), len(x))
        self.assertAlmostEqual(len(T.speed_up(x, 1.5)) / SR, 2.0, delta=0.05)
        self.assertAlmostEqual(len(T.speed_up(x, 2.0)) / SR, 1.5, delta=0.05)

    @unittest.skipUnless(__import__("shutil").which("ffmpeg"), "needs ffmpeg")
    def test_openai_compatible_times_back_on_the_original_timeline(self):
        sent = {}

        def fake_post(url, body, headers, retries=4, timeout=120):
            sent["bytes"] = len(body)
            return {"language": "english", "segments": [{"start": 0.0, "end": 0.8, "text": "a"}, {"start": 0.8, "end": 1.5, "text": "b"}]}
        old = (T._post, os.environ.get("BLURT_ASR_API_KEY"))
        T._post = fake_post
        os.environ["BLURT_ASR_API_KEY"] = "test"
        try:
            with config({"asr": {"cloud": {"speed": 2}}}):
                b = T.OpenAICompat(Namespace(model="whisper-1", language=None, prompt=None))
                x = np.zeros(3 * SR, dtype=np.float32)
                segs = b.transcribe(x)
        finally:
            T._post = old[0]
            if old[1] is None:
                os.environ.pop("BLURT_ASR_API_KEY", None)
            else:
                os.environ["BLURT_ASR_API_KEY"] = old[1]
        self.assertLess(sent["bytes"], 3 * SR * 2 * 0.6)     # about half the audio went
        self.assertEqual([s[:2] for s in segs], [(0.0, 1.6), (1.6, 3.0)])

    def test_dictation_offers_a_keyed_cloud_service(self):
        real = fake_installed("apple-speech")
        old = os.environ.get("DASHSCOPE_API_KEY")
        try:
            with config({"asr": {"languages": ["zh"]}}):
                os.environ.pop("DASHSCOPE_API_KEY", None)
                self.assertNotIn("qwen3-asr-flash", [m["id"] for m in T.dictation_models(hw())["models"]])
                os.environ["DASHSCOPE_API_KEY"] = "test"
                d = T.dictation_models(hw())
                self.assertIn("qwen3-asr-flash", [m["id"] for m in d["models"]])
                self.assertFalse(d["selected_cloud"])
            with config({"asr": {"languages": ["zh"]}, "record": {"dictation": {"asr_model": "qwen3-asr-flash"}}}):
                d = T.dictation_models(hw())
                self.assertEqual(d["selected"], "qwen3-asr-flash")
                self.assertTrue(d["selected_cloud"])
            with config({"asr": {"languages": ["zh"]}, "privacy": {"local_asr": True}}):
                self.assertNotIn("qwen3-asr-flash", [m["id"] for m in T.dictation_models(hw())["models"]])
        finally:
            T.installed = real
            if old is None:
                os.environ.pop("DASHSCOPE_API_KEY", None)
            else:
                os.environ["DASHSCOPE_API_KEY"] = old


class OneKey(unittest.TestCase):
    """Model Studio (the recommended key in China): polish and translate on DeepSeek V4.1 Flash there, Copy Text from
    Screen on its vision model; on a Mac without macOS's recogniser its key recognises speech too."""

    def test_preset(self):
        import polish_cloud
        cfg = polish_cloud.settings({"provider": "dashscope", "key": "k"})
        self.assertEqual((cfg["model"], cfg["vision_model"]), ("deepseek-v4.1-flash", "qwen3.6-flash"))
        self.assertIn("dashscope.aliyuncs.com", cfg["base_url"])
        self.assertEqual(polish_cloud.settings({"provider": "deepseek", "key": "k"})["vision_model"], "")

    def test_job_models(self):
        import polish_cloud, polish
        cfg = polish_cloud.settings({"provider": "deepseek", "key": "k", "translate_model": "deepseek-v4-pro"})
        self.assertEqual((cfg["model"], cfg["translate_model"]), ("deepseek-flash", "deepseek-v4-pro"))
        sent = {}

        def fake_complete(c, msgs, timeout, max_tokens):
            sent["model"] = c["model"]
            return {"text": "hi", "usage": {}, "ms": 1}
        old = polish_cloud.complete
        polish_cloud.complete = fake_complete
        try:
            polish.cloud_translate("你好", "en", {"provider": "deepseek", "key": "k", "translate_model": "deepseek-v4-pro"})
            self.assertEqual(sent["model"], "deepseek-v4-pro")
            polish.cloud_translate("你好", "en", {"provider": "deepseek", "key": "k"})
            self.assertEqual(sent["model"], "deepseek-flash")       # "" = the polish model
        finally:
            polish_cloud.complete = old

    def test_dashscope_speech_model_from_settings(self):
        old = {k: os.environ.get(k) for k in ("DASHSCOPE_API_KEY", "DASHSCOPE_ASR_MODEL")}
        try:
            os.environ["DASHSCOPE_API_KEY"] = "test"
            os.environ.pop("DASHSCOPE_ASR_MODEL", None)
            self.assertEqual(T.DashScope(Namespace(model="qwen3-asr-flash", prompt=None, language=None)).model, "qwen3-asr-flash")
            os.environ["DASHSCOPE_ASR_MODEL"] = "qwen3-asr-flash-2026-02-10"
            self.assertEqual(T.DashScope(Namespace(model="qwen3-asr-flash", prompt=None, language=None)).model, "qwen3-asr-flash-2026-02-10")
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_cloud_speech_before_a_download_without_apple(self):
        real = fake_installed()
        old = {k: os.environ.get(k) for k in ("DASHSCOPE_API_KEY", "BLURT_NO_APPLE_SPEECH")}
        try:
            os.environ["BLURT_NO_APPLE_SPEECH"] = "1"
            os.environ["DASHSCOPE_API_KEY"] = "test"
            with config({"asr": {"languages": ["zh"]}}):
                self.assertEqual(T.select("note")["id"], "qwen3-asr-flash")
                d = T.dictation_models(hw())
                self.assertEqual(d["selected"], "qwen3-asr-flash")
                self.assertTrue(d["ready"] and d["selected_cloud"])
            with config({"asr": {"languages": ["zh"]}, "privacy": {"local_asr": True}}):
                self.assertEqual(T.select("note")["id"], "sensevoice-small")
            os.environ.pop("DASHSCOPE_API_KEY")
            with config({"asr": {"languages": ["zh"]}}):
                self.assertEqual(T.select("note")["id"], "sensevoice-small")
        finally:
            T.installed = real
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


# ------------------------------------------------------------------ the real thing (opt-in: BLURT_ASR_SLOW=1)
@unittest.skipUnless(os.environ.get("BLURT_ASR_SLOW") and sys.platform == "darwin", "set BLURT_ASR_SLOW=1 (macOS, models installed)")
class Multilingual(unittest.TestCase):
    def test_say_samples_are_recognised(self):
        """zh / en / ja with SenseVoice, es with Whisper large-v3-turbo: each under 10 % error on `say` speech."""
        for model, langs in (("sensevoice-small", "zh,en,ja"), ("whisper-large-v3-turbo-mlx", "es")):
            if not T.installed(T.entry(model)):
                self.skipTest(f"{model} not downloaded")
            p, out = run_cli("bench", "--model-id", model, "--languages", langs, "--no-save", timeout=900)
            self.assertEqual(p.returncode, 0, p.stderr[-800:])
            for lang in langs.split(","):
                self.assertLess(out["error"][lang], 0.10, (model, lang, out))


if __name__ == "__main__":
    unittest.main()
