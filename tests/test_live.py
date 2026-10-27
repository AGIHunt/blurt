"""Live pipeline (scripts/live.py): chunking, pcm → transcript equivalence with a whole-file run, drafts validation,
shots voice notes, and the Tk recorder's pcm sidecar. No models, no network: a tiny energy VAD and a fake backend
stand in for Silero / SenseVoice (an optional test uses the real ones when they are installed).

  uv run --with numpy python -m unittest tests.test_live -v
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import wave
from collections import deque
from pathlib import Path
from types import SimpleNamespace

import numpy as np

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
os.environ.setdefault("BLURT_HOME", tempfile.mkdtemp(prefix="blurt-home-"))

import live  # noqa: E402
import transcribe  # noqa: E402

SR = 16000


# ------------------------------------------------------------------ stand-ins
class FakeVAD:
    """Energy VAD with the sherpa-onnx VoiceActivityDetector interface (accept_waveform/front/pop/empty/flush)."""

    def __init__(self, max_speech: float, thr: float = 0.02, min_silence: float = 0.3):
        self.thr, self.min_sil, self.max_len = thr, int(min_silence * SR), int(max_speech * SR)
        self.t, self.start, self.cur, self.sil, self.q = 0, None, [], 0, deque()

    def _emit(self):
        x = np.concatenate(self.cur)
        x = x[:len(x) - self.sil] if self.sil else x
        if len(x):
            self.q.append(SimpleNamespace(start=self.start, samples=x))
        self.start, self.cur, self.sil = None, [], 0

    def accept_waveform(self, x):
        x = np.asarray(x, np.float32)
        loud = len(x) > 0 and float(np.sqrt(np.mean(x * x))) > self.thr
        if self.start is None:
            if loud:
                self.start, self.cur, self.sil = self.t, [x], 0
        else:
            self.cur.append(x)
            self.sil = 0 if loud else self.sil + len(x)
            if self.sil >= self.min_sil or sum(map(len, self.cur)) >= self.max_len:
                self._emit()
        self.t += len(x)

    def flush(self):
        if self.start is not None:
            self._emit()

    def is_speech_detected(self):
        return self.start is not None

    def empty(self):
        return not self.q

    @property
    def front(self):
        return self.q[0]

    def pop(self):
        self.q.popleft()


def fake_make_vad(max_speech=25):
    return FakeVAD(max_speech), 512


class FakeBackend:
    """Text = a fingerprint of the exact samples, so any chunk-boundary difference shows up as different text."""
    max_chunk = 10
    model = None

    def __init__(self, *_a, **_k):
        self.calls = 0

    def transcribe(self, x):
        self.calls += 1
        return [(0.0, len(x) / SR, f"w{len(x)}-{int(np.abs(x).sum() * 1000) % 100000}")]


def narration(seed: int = 0, seconds: float = 150) -> np.ndarray:
    """Tone bursts (speech) with gaps from 0.1 s (inside a word) to 6 s (thinking), and some long monologues."""
    rnd = np.random.default_rng(seed)
    parts, total = [np.zeros(int(0.4 * SR), np.float32)], 0.0
    while total < seconds:
        dur = float(rnd.choice([0.4, 1.0, 2.5, 4.0, 7.0, 12.0, 16.0]))
        t = np.arange(int(dur * SR)) / SR
        f = float(rnd.uniform(150, 600))
        parts.append((0.3 * np.sin(2 * np.pi * f * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32))
        gap = float(rnd.choice([0.1, 0.35, 0.6, 0.9, 1.1, 1.6, 2.4, 3.5, 6.0]))
        parts.append(np.zeros(int(gap * SR), np.float32))
        total += dur + gap
    return np.concatenate(parts)


def rmtree_retry(p: Path) -> None:
    """Windows refuses to delete a file another thread has open for a moment (live.py reading / appending)."""
    for _ in range(50):
        try:
            shutil.rmtree(p)
            return
        except FileNotFoundError:
            return
        except OSError:
            time.sleep(0.05)
    shutil.rmtree(p)


def to_pcm(x: np.ndarray) -> bytes:
    return (np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes()


def from_pcm(b: bytes) -> np.ndarray:
    return np.frombuffer(b, np.int16).astype(np.float32) / 32768


class Patched(unittest.TestCase):
    """transcribe.make_vad → FakeVAD for the duration of a test (whole-file runs and live runs alike)."""

    def setUp(self):
        self._make_vad = transcribe.make_vad
        transcribe.make_vad = fake_make_vad
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def tearDown(self):
        transcribe.make_vad = self._make_vad


# ------------------------------------------------------------------ chunking / joining
class Chunking(Patched):
    def batch_chunks(self, x, max_chunk):
        return transcribe.group_chunks(transcribe.vad_segments(x, max_speech=min(25, max_chunk)), max_chunk)

    def live_chunks(self, x, max_chunk, seed=0):
        ch = live.LiveChunker(fake_make_vad, max_chunk)
        rnd = np.random.default_rng(seed)
        out, i = [], 0
        while i < len(x):  # the recorder appends irregular pieces
            n = int(rnd.integers(200, 6000))
            out += ch.feed(x[i:i + n])
            i += n
        return out + ch.finish(len(x) / SR)

    def test_same_chunks_as_whole_file(self):
        for seed in range(4):
            for max_chunk in (10, 20, 60):
                x = narration(seed)
                self.assertEqual(self.live_chunks(x, max_chunk, seed), self.batch_chunks(x, max_chunk),
                                 f"seed {seed} max_chunk {max_chunk}")

    def test_chunk_rules(self):
        x = narration(7, 300)
        chunks = self.live_chunks(x, 10)
        for (s, e), nxt in zip(chunks, chunks[1:] + [None]):
            self.assertLessEqual(e - s, 10 + 0.4)  # + padding, + VAD window granularity
            if nxt:
                # joins are in pauses; only a forced split of nonstop speech (max length) overlaps, by the
                # 0.15 + 0.2 s padding — exactly as in a whole-file run
                self.assertLessEqual(e, nxt[0] + 0.35 + 1e-6)
        self.assertTrue(all(0 <= s < e <= len(x) / SR for s, e in chunks))

    def test_closes_early_at_a_pause(self):
        """A caption should not wait for the next sentence: the chunk closes ~max_gap + margin after speech ends."""
        tone = 0.3 * np.sin(2 * np.pi * 300 * np.arange(2 * SR) / SR).astype(np.float32)
        ch = live.LiveChunker(fake_make_vad, 10)
        got = ch.feed(np.concatenate([tone, np.zeros(int(1.5 * SR), np.float32)]))
        self.assertEqual(got, [])
        got = ch.feed(np.zeros(int(1.5 * SR), np.float32))
        self.assertEqual(len(got), 1)
        self.assertAlmostEqual(got[0][0], 0.0, places=2)


class RealVad(unittest.TestCase):
    """The real Silero VAD (when installed locally): the early close must never split what a whole-file run joins."""

    def test_real_vad_equivalence(self):
        try:
            import sherpa_onnx  # noqa: F401
        except ImportError:
            self.skipTest("sherpa-onnx not installed")
        if not (transcribe.MODELS_DIR / "silero_vad.onnx").exists():
            self.skipTest("silero_vad.onnx not downloaded")
        rnd = np.random.default_rng(3)
        # noise-modulated bursts look enough like speech to Silero to trigger it
        parts = []
        for _ in range(40):
            n = int(rnd.uniform(0.5, 9) * SR)
            t = np.arange(n) / SR
            env = (0.5 + 0.5 * np.sin(2 * np.pi * 4 * t)) ** 2
            voiced = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 12) for f0 in [rnd.uniform(110, 220)])
            parts += [(0.1 * env * voiced).astype(np.float32), np.zeros(int(rnd.choice([0.2, 0.7, 1.2, 2, 4]) * SR), np.float32)]
        x = np.concatenate(parts)
        batch = transcribe.group_chunks(transcribe.vad_segments(x, 10), 10)
        ch = live.LiveChunker(transcribe.make_vad, 10)
        got = []
        for i in range(0, len(x), 1600):
            got += ch.feed(x[i:i + 1600])
        got += ch.finish(len(x) / SR)
        self.assertEqual(got, batch)


# ------------------------------------------------------------------ pcm → transcript
class LivePipeline(Patched):
    def feed(self, session: Path, takes: list[bytes], gap: float = 0.0, discard: bool = False):
        """Play the recorder: append audio.pcm in 100 ms pieces; restart = remove live/ and start a new file."""
        def run():
            for k, pcm in enumerate(takes):
                livedir = session / "live"
                if k:
                    rmtree_retry(livedir)
                    time.sleep(0.4)
                livedir.mkdir(parents=True, exist_ok=True)
                with open(livedir / "audio.pcm", "wb") as fh:
                    for i in range(0, len(pcm), 3200 * 4):
                        fh.write(pcm[i:i + 3200 * 4])
                        fh.flush()
                        if gap:
                            time.sleep(gap)
            if discard:
                rmtree_retry(session)
            else:
                (session / "live" / "stop").touch()
        session.mkdir(parents=True, exist_ok=True)  # the recorder made it before live.py starts
        th = threading.Thread(target=run, daemon=True)
        th.start()
        return th

    def whole_file(self, x: np.ndarray) -> dict:
        backend = FakeBackend()
        a = SimpleNamespace(model=None)
        results, speech, blank = transcribe.transcribe_track(x, backend, "fake", 1, quiet=True)
        return transcribe.build_transcript("recording.mp4", "fake", backend, a, len(x) / SR, speech, blank, results, 0)

    def live_run(self, session: Path) -> live.LiveRun:
        run = live.LiveRun(session, backend=FakeBackend(), make_vad=fake_make_vad, name="fake")
        self.assertEqual(run.run(), 0)
        return run

    def test_equivalent_to_whole_file(self):
        x = narration(11, 120)
        pcm = to_pcm(x)
        session = self.tmp / "s1"
        th = self.feed(session, [pcm], gap=0.002)
        self.live_run(session)
        th.join()
        got = json.loads((session / "transcript.json").read_text(encoding="utf-8"))
        want = self.whole_file(from_pcm(pcm))
        for k in ("source", "backend", "duration", "speech_seconds", "segments"):
            self.assertEqual(got[k], want[k], k)
        self.assertEqual(sorted(got), sorted(want))  # same document shape as transcribe.py run
        lines = [json.loads(l) for l in (session / "live" / "transcript.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(lines, [{k: s[k] for k in ("start", "end", "text")} for s in got["segments"]])
        st = json.loads((session / "live" / "status.json").read_text(encoding="utf-8"))
        self.assertEqual(st["asr"], "done")
        self.assertTrue({"asr", "drafts", "updated", "note"} <= set(st))
        txt = (session / "transcript.txt").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(txt), len(got["segments"]))

    def test_restart_keeps_only_the_new_take(self):
        a, b = to_pcm(narration(1, 40)), to_pcm(narration(2, 30))
        session = self.tmp / "s2"
        th = self.feed(session, [a, b], gap=0.002)
        self.live_run(session)
        th.join()
        got = json.loads((session / "transcript.json").read_text(encoding="utf-8"))
        self.assertEqual(got["segments"], self.whole_file(from_pcm(b))["segments"])

    def test_discard_writes_nothing(self):
        session = self.tmp / "s3"
        th = self.feed(session, [to_pcm(narration(4, 20))], gap=0.001, discard=True)
        self.live_run(session)
        th.join()
        self.assertFalse(session.exists())

    def test_transcribe_reuses_live_transcript(self):
        """transcribe.py run on the session's recording returns the live transcript instead of redoing it."""
        if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
            self.skipTest("ffmpeg not installed")
        session = self.tmp / "s4"
        (session / "live").mkdir(parents=True)
        x = narration(5, 10)
        with wave.open(str(session / "recording.wav"), "wb") as w:
            w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR)
            w.writeframes(to_pcm(x))
        doc = {"source": "recording.wav", "backend": "sensevoice", "model": "sense-voice-small-int8",
               "duration": round(len(x) / SR, 2), "speech_seconds": 5.0, "elapsed_seconds": 0.1,
               "segments": [{"start": 0.4, "end": 2.0, "text": "made live"}]}
        transcribe.save_json(session / "transcript.json", doc)
        transcribe.save_json(session / "live" / "status.json", {"asr": "done", "drafts": "off", "updated": time.time(), "note": ""})
        import subprocess
        p = subprocess.run([sys.executable, str(SCRIPTS / "transcribe.py"), "run", str(session / "recording.wav")],
                           capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = json.loads(p.stdout)
        self.assertTrue(out.get("live"))
        self.assertEqual(json.loads((session / "transcript.json").read_text(encoding="utf-8")), doc)
        self.assertIn("made live", (session / "transcript.txt").read_text(encoding="utf-8"))
        # a different length (another take) must not be reused
        doc["duration"] += 30
        transcribe.save_json(session / "transcript.json", doc)
        a = SimpleNamespace(force=False)
        self.assertIsNone(transcribe.live_transcript(session / "recording.wav", session, a, {}))
        self.assertIsNone(transcribe.live_transcript(session / "recording.wav", session, SimpleNamespace(force=True), {}))


# ------------------------------------------------------------------ drafts
class Drafts(unittest.TestCase):
    def test_apply_ops_validates(self):
        drafts: dict = {}
        answer = {"ops": [
            {"op": "add", "kind": "issue", "title": " 保存按钮  错位 ", "t": 12.3, "confidence": "high"},
            {"op": "add", "kind": "idea", "title": "Borrow the onboarding", "t": 9999},
            {"op": "add", "kind": "bogus", "title": "x", "t": 1},           # bad kind
            {"op": "add", "kind": "note", "title": "", "t": 1},             # no title
            {"op": "update", "id": "d9", "title": "nope"},                   # unknown id
            "junk",
        ]}
        lines, problems, nxt = live.apply_ops(drafts, answer, duration=120.0, next_id=1)
        self.assertEqual([l["id"] for l in lines], ["d1", "d2"])
        self.assertEqual(lines[0], {"id": "d1", "op": "add", "kind": "issue", "title": "保存按钮 错位", "t": 12.3,
                                    "confidence": "high"})
        self.assertEqual(list(lines[0]), ["id", "op", "kind", "title", "t", "confidence"])
        self.assertEqual(lines[1]["t"], 120.0)            # clamped to what was recorded
        self.assertEqual(lines[1]["confidence"], "high")  # default
        self.assertEqual(len(problems), 4)
        self.assertEqual(nxt, 3)
        lines, problems, nxt = live.apply_ops(drafts, {"ops": [
            {"op": "update", "id": "d1", "kind": "task", "confidence": "low"},
            {"op": "drop", "id": "d2"},
            {"op": "update", "id": "d1", "kind": "issue2"},
        ]}, 130.0, nxt)
        self.assertEqual(lines[0], {"id": "d1", "op": "update", "kind": "task", "title": "保存按钮 错位", "t": 12.3,
                                    "confidence": "low"})
        self.assertEqual(lines[1]["op"], "drop")
        self.assertEqual(lines[1]["title"], "Borrow the onboarding")
        self.assertEqual(set(drafts), {"d1"})
        self.assertEqual(len(problems), 1)

    def test_extract_json(self):
        self.assertEqual(live.extract_json('```json\n{"ops": []}\n```'), {"ops": []})
        self.assertEqual(live.extract_json('Sure! {"ops": [{"op":"drop","id":"d1"}]} done'),
                         {"ops": [{"op": "drop", "id": "d1"}]})
        with self.assertRaises(ValueError):
            live.extract_json("no json here")
        _, problems, _ = live.apply_ops({}, {"nope": 1}, 10, 1)
        self.assertTrue(problems)

    def test_prompt_is_bounded(self):
        segs = [{"start": i * 5.0, "end": i * 5.0 + 4, "text": "一句很长的话" * 10} for i in range(400)]
        p = live.build_prompt({"d1": {"id": "d1", "kind": "issue", "title": "x", "t": 3.0, "confidence": "high"}},
                              segs, sent_upto=1900)
        self.assertLess(len(p), 7000)
        self.assertIn("d1 [issue]", p)
        self.assertIn("[1995]", p)  # the newest speech is always there

    def test_drafter_triggers_and_appends(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        fake = tmp / "agent.py"
        fake.write_text('import sys, json\nsys.stdin.read()\nprint(json.dumps({"ops": [{"op": "add", "kind": "task", '
                        '"title": "Send the test account", "t": 30}]}))\n', encoding="utf-8")
        os.environ["BLURT_LIVE_DRAFTS_CMD"] = f'"{sys.executable}" "{fake}"'
        self.addCleanup(os.environ.pop, "BLURT_LIVE_DRAFTS_CMD", None)
        d = live.Drafter(tmp)
        self.assertTrue(d.enabled)
        segs = [{"start": i * 10.0, "end": i * 10.0 + 9, "text": f"s{i}"} for i in range(5)]  # 45 s of speech
        d.maybe(segs, pos=60, in_speech=False, last_speech_end=49)
        self.assertFalse(d.busy() or (tmp / "drafts.jsonl").exists())  # < 60 s of new speech
        segs += [{"start": 50.0 + i * 10, "end": 59.0 + i * 10, "text": f"t{i}"} for i in range(3)]  # 72 s
        d.maybe(segs, pos=79.5, in_speech=False, last_speech_end=79)
        self.assertFalse(d.busy())  # no 3 s pause yet
        d.maybe(segs, pos=83, in_speech=False, last_speech_end=79)
        d.thread.join(30)
        lines = [json.loads(l) for l in (tmp / "drafts.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(lines, [{"id": "d1", "op": "add", "kind": "task", "title": "Send the test account", "t": 30.0,
                                  "confidence": "high"}])
        self.assertEqual(d.sent_upto, 79.0)
        log = json.loads((tmp / "drafts.log").read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(log["ops"], 1)

    def test_drafter_failure_is_contained(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        os.environ["BLURT_LIVE_DRAFTS_CMD"] = f'"{sys.executable}" -c "print(\'not json\')"'
        self.addCleanup(os.environ.pop, "BLURT_LIVE_DRAFTS_CMD", None)
        d = live.Drafter(tmp)
        d.start([{"start": 0.0, "end": 5.0, "text": "x"}], 6)
        d.thread.join(30)
        self.assertEqual(d.state, "error")
        self.assertFalse((tmp / "drafts.jsonl").exists())

    def test_agent_env_strips_host_session(self):
        os.environ["CLAUDECODE"] = "1"
        os.environ["CLAUDE_CODE_SIMPLE"] = "1"
        os.environ["USE_STAGING_OAUTH"] = "1"
        try:
            env = live.agent_env()
        finally:
            for k in ("CLAUDECODE", "CLAUDE_CODE_SIMPLE", "USE_STAGING_OAUTH"):
                os.environ.pop(k, None)
        self.assertFalse({"CLAUDECODE", "CLAUDE_CODE_SIMPLE", "USE_STAGING_OAUTH"} & set(env))
        self.assertIn("PATH", env)


# ------------------------------------------------------------------ shots
class Shots(Patched):
    def test_voice_notes_become_said(self):
        session = self.tmp / "shots-session"
        (session / "shots").mkdir(parents=True)
        transcribe.save_json(session / "meta.json", {"mode": "shots", "engine": "native-app"})
        recs = []
        for n in (1, 2, 3):
            rec = {"n": n, "file": f"shots/{n:03d}.png", "marked": None, "t": None, "wall": 1.0 + n, "region": [0, 0, 10, 10],
                   "voice": f"shots/{n:03d}.wav" if n != 2 else None, "text": "typed" if n == 2 else "", "strokes": []}
            recs.append(rec)
            if rec["voice"]:
                with wave.open(str(session / rec["voice"]), "wb") as w:
                    w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR)
                    w.writeframes(to_pcm(narration(n, 6)))
        (session / "shots.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs), encoding="utf-8")

        backends, load = transcribe.BACKENDS, transcribe.load_audio
        transcribe.BACKENDS = {**backends, "sensevoice": FakeBackend}
        transcribe.load_audio = lambda p, track=0: from_pcm(wave.open(str(p)).readframes(10 ** 9))
        try:
            a = SimpleNamespace(backend="sensevoice", model=None, language=None, prompt=None, concurrency=1, force=False)
            quiet = contextlib.redirect_stdout(io.StringIO())
            with quiet:
                transcribe.transcribe_shots(session, a)
            lines = (session / "shots.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 5)  # two update lines appended, nothing rewritten
            latest = transcribe.read_shots(session)
            self.assertTrue(latest[1]["said"].startswith("w"))
            self.assertEqual(latest[1]["file"], "shots/001.png")  # the update line is the whole record + said
            self.assertNotIn("said", latest[2])                    # no voice note
            self.assertTrue(latest[3]["said"])
            with contextlib.redirect_stdout(io.StringIO()):
                transcribe.transcribe_shots(session, a)            # idempotent
            self.assertEqual(len((session / "shots.jsonl").read_text(encoding="utf-8").splitlines()), 5)
            a.force = True
            with contextlib.redirect_stdout(io.StringIO()):
                transcribe.transcribe_shots(session, a)
            self.assertEqual(len((session / "shots.jsonl").read_text(encoding="utf-8").splitlines()), 7)
        finally:
            transcribe.BACKENDS, transcribe.load_audio = backends, load

    def test_structured_voice_note_keeps_structure_on_retranscribe(self):
        # a Structured note (structure: true) re-transcribed: the note goes through the same structure request and the
        # transcript stays as said_raw; with no polish model the note is the transcript and said_raw is cleared
        session = self.tmp / "shots-structured"
        (session / "shots").mkdir(parents=True)
        transcribe.save_json(session / "meta.json", {"mode": "shots", "engine": "native-app"})
        rec = {"n": 1, "file": "shots/001.png", "voice": "shots/001.wav", "text": "", "structure": True,
               "said": "1. old\n2. list", "said_raw": "old list"}
        with wave.open(str(session / rec["voice"]), "wb") as w:
            w.setnchannels(1), w.setsampwidth(2), w.setframerate(SR)
            w.writeframes(to_pcm(narration(1, 6)))
        (session / "shots.jsonl").write_text(json.dumps(rec) + "\n", encoding="utf-8")
        backends, load, structure = transcribe.BACKENDS, transcribe.load_audio, transcribe.structure_note
        transcribe.BACKENDS = {**backends, "sensevoice": FakeBackend}
        transcribe.load_audio = lambda p, track=0: from_pcm(wave.open(str(p)).readframes(10 ** 9))
        try:
            a = SimpleNamespace(backend="sensevoice", model=None, language=None, prompt=None, concurrency=1, force=True)
            seen = []
            transcribe.structure_note = lambda t: seen.append(t) or "- structured"
            with contextlib.redirect_stdout(io.StringIO()):
                transcribe.transcribe_shots(session, a)
            latest = transcribe.read_shots(session)[1]
            self.assertEqual(latest["said"], "- structured")
            self.assertEqual(latest["said_raw"], seen[0])
            self.assertTrue(seen[0])
            transcribe.structure_note = lambda t: None             # no polish model
            with contextlib.redirect_stdout(io.StringIO()):
                transcribe.transcribe_shots(session, a)
            latest = transcribe.read_shots(session)[1]
            self.assertEqual(latest["said"], seen[0])
            self.assertIsNone(latest["said_raw"])
            self.assertTrue(latest["structure"])
        finally:
            transcribe.BACKENDS, transcribe.load_audio, transcribe.structure_note = backends, load, structure


# ------------------------------------------------------------------ the Tk/ffmpeg recorder's sidecar
class Sidecar(unittest.TestCase):
    def test_resampler(self):
        from record import Resampler
        for sr in (48000, 44100, 22050, 16000):
            t = np.arange(sr * 2) / sr
            x = 0.5 * np.sin(2 * np.pi * 440 * t) + 0.3 * np.sin(2 * np.pi * 3000 * t)
            if sr > 16000:
                x += 0.2 * np.sin(2 * np.pi * 11000 * t)  # above 8 kHz: must be filtered, not aliased
            pcm = to_pcm(x)
            rs, out, step = Resampler(sr), b"", int(sr * 0.0213) * 2
            for i in range(0, len(pcm), step):
                out += rs.feed(pcm[i:i + step])
            out += rs.feed(b"", final=True)
            y = from_pcm(out)
            self.assertEqual(len(y), 2 * SR, sr)
            n = np.arange(len(y)) / SR
            ref = 0.5 * np.sin(2 * np.pi * 440 * n) + 0.3 * np.sin(2 * np.pi * 3000 * n)
            err = float(np.sqrt(np.mean((y[800:-800] - ref[800:-800]) ** 2)))
            self.assertLess(err, 0.01, sr)

    def test_segments_follow_the_video(self):
        from record import LivePcm
        d = Path(tempfile.mkdtemp()) / "live"
        self.addCleanup(shutil.rmtree, d.parent, True)
        lp = LivePcm(d, 16000)
        lp.segment(0)
        lp.feed(np.arange(8000, dtype=np.int16).tobytes())   # held until the lead is known
        self.assertEqual((d / "audio.pcm").stat().st_size, 0)
        lp.set_lead(0, 0.25)                                  # mic opened 0.25 s before the first frame: drop it
        lp.segment(8000)                                      # resume after a pause
        lp.feed(np.arange(8000, 16000, dtype=np.int16).tobytes())
        lp.set_lead(1, -0.1)                                  # video began 0.1 s before the mic: silence
        lp.finish()
        y = np.frombuffer((d / "audio.pcm").read_bytes(), np.int16)
        self.assertEqual(len(y), 4000 + 1600 + 8000)
        self.assertEqual(y[0], 4000)
        self.assertTrue((y[4000:5600] == 0).all())
        self.assertEqual(y[5600], 8000)
        self.assertTrue((d / "stop").exists())

    def test_discard_removes_live(self):
        from record import LivePcm
        d = Path(tempfile.mkdtemp()) / "live"
        lp = LivePcm(d, 48000)
        lp.segment(0)
        lp.feed(b"\0\0" * 4800)
        lp.discard()
        self.assertFalse(d.exists())
        shutil.rmtree(d.parent, True)


if __name__ == "__main__":
    unittest.main()
