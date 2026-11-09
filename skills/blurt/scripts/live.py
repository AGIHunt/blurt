# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy==2.3.4; python_version >= '3.11'", "numpy==2.2.6; python_version < '3.11'", "sherpa-onnx==1.13.8", "truststore==0.10.5", "opencc-python-reimplemented==0.1.7"]
# ///
"""Live transcript while a recording runs (L1), so it is ready when the take ends. docs/design/snap-and-live.md §4.

  live.py run <session> [--watch-pid PID]     started by the recorder when recording begins; exits by itself
  live.py simulate <audio> <session> [--speed N] [--run]
                                              feed an audio file into <session>/live/audio.pcm in real time (N× faster;
                                              0 = as fast as possible), then create live/stop — for tests and timing.
                                              --run also starts `live.py run` and reports stop → transcript latency
  live.py status <session>                    print live/status.json

`run` tails live/audio.pcm (16 kHz mono s16le, written by the recorder, pause-gated: byte offset / 32000 = video time),
cuts it at pauses with the same VAD and chunking as `transcribe.py run`, transcribes each chunk with the configured ASR
backend as soon as it closes, and appends live/transcript.jsonl. When live/stop appears it drains the rest and writes
<session>/transcript.json + transcript.txt — the same document `transcribe.py run` makes from the whole file (it then
returns instantly). Chunks are cut exactly where a whole-file run cuts them, so the text is the same.

Config ($BLURT_HOME/config.json → record): live (default true). No model drafts items while recording: the agent
that organizes the take reads the finished transcript.

Files in <session>/live/: audio.pcm, stop (recorder) · transcript.jsonl, status.json. Our stderr goes to
<session>/live.log (kept across restarts).
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import IS_WIN, die, ffmpeg_bin, global_config, load_json, save_json  # noqa: E402

SR = 16000
BPS = SR * 2                    # bytes per second of audio.pcm
CLOSE_MARGIN = 1.0              # see LiveChunker


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def pid_alive(pid: int | None) -> bool:
    if not pid:
        return True
    if IS_WIN:
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return code.value == 259  # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


# ------------------------------------------------------------------ chunking
class LiveChunker:
    """Streaming twin of transcribe.vad_segments + group_chunks: the same VAD fed the same windows, the same padding
    and the same greedy grouping, so the chunks (and the text) equal a whole-file run over the same samples.

    A chunk is closed when the next speech segment can't join it (gap > max_gap or too long) — exactly the
    whole-file rule — or early, once the stream is max_gap + CLOSE_MARGIN past its end and the VAD hears no speech:
    a later segment then starts after that gap (the VAD's look-back is ~0.3 s + 0.15 s padding), so it could not
    have joined anyway. Early closing is what makes captions appear ~2 s after a pause rather than at the next one."""

    def __init__(self, make_vad, max_chunk: float, max_gap: float = 1.0):
        from transcribe import pad_segment
        self.pad = pad_segment
        self.vad, self.win = make_vad(min(25, max_chunk))
        self.max_len, self.max_gap = max_chunk, max_gap
        self.rest = np.zeros(0, np.float32)
        self.fed = 0                      # samples given to the VAD
        self.cur: list[float] | None = None
        self.last_speech_end = 0.0

    @property
    def pos(self) -> float:
        return self.fed / SR

    def in_speech(self) -> bool:
        return bool(self.vad.is_speech_detected())

    def feed(self, x: np.ndarray) -> list[tuple[float, float]]:
        buf = np.concatenate([self.rest, x]) if len(self.rest) else x
        n = len(buf) // self.win * self.win
        out: list[tuple[float, float]] = []
        for i in range(0, n, self.win):
            self.vad.accept_waveform(buf[i:i + self.win])
            self.fed += self.win
            out += self._drain()
        self.rest = buf[n:]
        if self.cur and not self.in_speech() and self.pos > self.cur[1] + self.max_gap + CLOSE_MARGIN:
            out.append(tuple(self.cur))
            self.cur = None
        return out

    def finish(self, duration: float) -> list[tuple[float, float]]:
        out: list[tuple[float, float]] = []
        if len(self.rest):  # the whole-file run feeds the last partial window too
            self.vad.accept_waveform(self.rest)
            self.fed += len(self.rest)
            self.rest = np.zeros(0, np.float32)
        self.vad.flush()
        out += self._drain(duration)
        if self.cur:
            out.append(tuple(self.cur))
            self.cur = None
        return out

    def _drain(self, duration: float = float("inf")) -> list[tuple[float, float]]:
        out = []
        while not self.vad.empty():
            seg = self.vad.front
            s, e = self.pad(seg.start / SR, (seg.start + len(seg.samples)) / SR, duration)
            self.last_speech_end = (seg.start + len(seg.samples)) / SR
            self.vad.pop()
            if self.cur and s - self.cur[1] <= self.max_gap and e - self.cur[0] <= self.max_len:
                self.cur[1] = e
            else:
                if self.cur:
                    out.append(tuple(self.cur))
                self.cur = [s, e]
        return out


# ------------------------------------------------------------------ the live run
class Discarded(Exception):
    pass


class LiveRun:
    def __init__(self, session: Path, watch_pid: int | None = None, backend=None, make_vad=None, name: str | None = None,
                 workers: int | None = None):
        self.session, self.live = session, session / "live"
        self.pcm, self.stop_file = self.live / "audio.pcm", self.live / "stop"
        self.watch_pid = watch_pid
        self.backend, self.name, self._make_vad = backend, name, make_vad
        self.workers = workers
        self.asr, self.note = "running", ""
        self.last_status = 0.0
        self.decode_seconds = 0.0

    # --- status.json: {"asr","updated","note"} (+ audio_seconds, pid)
    def status(self, force: bool = False) -> None:
        if not force and time.time() - self.last_status < 1:
            return
        self.last_status = time.time()
        if not self.live.is_dir():
            return  # discarded: never recreate the folder
        st = {"asr": self.asr, "updated": round(time.time(), 2), "note": self.note,
              "audio_seconds": round(getattr(self, "offset", 0) / BPS, 1), "pid": os.getpid()}
        try:
            save_json(self.live / "status.json", st)
        except OSError:
            pass

    def reset(self) -> None:
        from transcribe import make_vad
        self.offset, self.ino = 0, None
        self.segments: list[dict] = []
        self.speech = self.blank = 0.0
        self.chunker = LiveChunker(self._make_vad or make_vad, self.backend.max_chunk)
        self.pending: deque = deque()
        if self.live.is_dir():
            (self.live / "transcript.jsonl").write_text("", encoding="utf-8")

    def read_slice(self, s: float, e: float) -> np.ndarray:
        a, b = int(s * SR), int(e * SR)
        try:
            with open(self.pcm, "rb") as fh:
                fh.seek(a * 2)
                raw = fh.read((b - a) * 2)
        except FileNotFoundError:  # live/ went away between pull() and here: a restart or a discard
            raise Discarded()
        return np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768

    def submit(self, chunks) -> None:
        from transcribe import decode_slice
        for s, e in chunks:
            x = self.read_slice(s, e)
            self.speech += e - s

            def work(x=x, s=s, e=e):
                t0 = time.time()
                r = decode_slice(self.backend, x, s, e)
                return r, time.time() - t0
            self.pending.append(((s, e), self.pool.submit(work)))

    def commit(self, wait: bool = False) -> None:
        from transcribe import is_blank
        while self.pending and (wait or self.pending[0][1].done()):
            (s, e), fut = self.pending.popleft()
            r, secs = fut.result()
            self.decode_seconds += secs
            if is_blank(r):
                self.blank += e - s
            lines = [{"start": round(a, 2), "end": round(b, 2), "text": t, **({"language": lg[0]} if lg else {})}
                     for a, b, t, *lg in r if t]
            self.segments += lines
            if lines and self.live.is_dir():
                with open(self.live / "transcript.jsonl", "a", encoding="utf-8") as fh:
                    for ln in lines:
                        fh.write(json.dumps(ln, ensure_ascii=False) + "\n")

    def pull(self) -> bool:
        """Read what the recorder appended. False when nothing new. Raises Discarded when live/ went away."""
        try:
            st = self.pcm.stat()
        except FileNotFoundError:
            raise Discarded()
        if self.ino is not None and (st.st_ino != self.ino or st.st_size < self.offset):
            log("audio.pcm was restarted (new take) — starting over")
            self.reset()
        self.ino = st.st_ino
        n = (st.st_size - self.offset) // 2 * 2
        if n <= 0:
            return False
        with open(self.pcm, "rb") as fh:
            fh.seek(self.offset)
            raw = fh.read(n)
        n = len(raw) // 2 * 2
        self.offset += n
        x = np.frombuffer(raw[:n], dtype=np.int16).astype(np.float32) / 32768
        for i in range(0, len(x), SR * 5):  # big backlog (slow start): keep chunks flowing
            self.submit(self.chunker.feed(x[i:i + SR * 5]))
            self.commit()
        return True

    def wait_for_take(self, timeout: float) -> bool:
        t0 = time.time()
        seen = self.session.exists()
        while time.time() - t0 < timeout:
            if self.pcm.exists():
                return True
            seen = seen or self.session.exists()
            if (seen and not self.session.exists()) or not pid_alive(self.watch_pid):
                return False
            time.sleep(0.2)
        return False

    def run(self) -> int:
        if not self.wait_for_take(60):
            log("no live/audio.pcm appeared — nothing to do")
            return 0
        self.offset = 0
        self.pool = ThreadPoolExecutor(self.workers or 1)
        self.reset()
        self.status(force=True)
        dead_since = None
        while True:
            try:
                got = self.pull()
                self.commit()
                self.status()
                if self.stop_file.exists():
                    self.pull()
                    return self.finish()
                if not pid_alive(self.watch_pid):  # the recorder died without a stop: keep what was said
                    dead_since = dead_since or time.time()
                    if time.time() - dead_since > 3:
                        log("recorder exited without live/stop — finishing anyway")
                        return self.finish()
                if not got:
                    time.sleep(0.1)
            except Discarded:
                if not self.session.exists():
                    log("session removed (discarded) — exiting")
                    return 0
                log("live/ removed (discarded / restarting) — waiting for a new take")
                if not self.wait_for_take(30):
                    return 0
                self.reset()
                self.status(force=True)

    def finish(self) -> int:
        from transcribe import build_transcript, write_transcript
        duration = self.offset / BPS
        self.submit(self.chunker.finish(duration))
        self.commit(wait=True)
        recs = sorted(self.session.glob("recording.*"))
        source = recs[0].name if recs else "recording.mp4"
        results = [(s["start"], s["end"], s["text"], None, s.get("language")) for s in self.segments]

        class A:  # what build_transcript wants to know about the run's options
            model = None
        data = build_transcript(source, self.name, self.backend, A, duration, self.speech, self.blank, results,
                                self.decode_seconds)
        files = write_transcript(self.session, data)
        self.asr, self.note = "done", f"{len(data['segments'])} segments, {duration:.0f}s"
        self.status(force=True)
        log(f"transcript written: {files[0]} ({len(data['segments'])} segments)")
        self.pool.shutdown(wait=False)
        return 0


# ------------------------------------------------------------------ commands
def asr_setup():
    """(name, backend, workers) for the live model (asr.models.live / the recommendation, installed only), or
    (None, reason, 0) when it can't run here right now. Capped like every ASR run (K9): asr.limits.threads threads
    (leave CPU to the app being recorded), user-initiated priority, MLX memory cap. A backend whose package is
    missing re-runs this process under `uv run --with <package>` (transcribe.ensure_package)."""
    import argparse
    import transcribe as T

    a = argparse.Namespace(backend=None, model=None, model_id=None, language=None, prompt=None, concurrency=4,
                           threads=None)
    try:
        name = T.resolve_backend(a, "live")
        why = T.backend_ready(name, a.model_id)
        if why:
            return None, why, 0
        T.throttle("live")
        backend = T.make_backend(name, a, "live")
    except T.Fail as e:
        return None, f"{e} ({e.code})", 0
    return name, backend, 1 if name in T.LOCAL else a.concurrency


def cmd_run(a) -> int:
    session = Path(a.session).resolve()
    live = session / "live"
    os.environ["BLURT_NO_DOWNLOAD"] = "1"
    if global_config().get("record", {}).get("live") is False:
        log("record.live is false — off")
        return 0
    run = LiveRun(session, a.watch_pid)
    if not run.wait_for_take(60):
        log("no live/audio.pcm appeared — nothing to do")
        return 0
    try:
        name, backend, workers = asr_setup()
    except (SystemExit, Exception) as e:  # die() / an import error inside a backend — the recording must not notice
        name, backend, workers = None, f"ASR setup failed ({type(e).__name__}: {e})"[:300], 0
    if name is None:
        # no usable ASR: say so and get out of the way (the audio sidecar isn't needed then)
        run.asr, run.note = "off", str(backend)
        run.status(force=True)
        log(f"ASR off: {backend}")
        while live.is_dir() and not (live / "stop").exists() and pid_alive(a.watch_pid):
            time.sleep(1)
            run.status()
        (live / "audio.pcm").unlink(missing_ok=True)
        return 0
    run.backend, run.name, run.workers = backend, name, workers
    log(f"live: {name}")
    try:
        return run.run()
    except Exception as e:
        run.asr, run.note = "error", f"{type(e).__name__}: {e}"[:300]
        run.status(force=True)
        raise


def cmd_simulate(a) -> int:
    src, session = Path(a.audio), Path(a.session).resolve()
    if not src.exists():
        die(f"{src} not found")
    live = session / "live"
    live.mkdir(parents=True, exist_ok=True)
    for f in ("stop", "status.json", "transcript.jsonl"):
        (live / f).unlink(missing_ok=True)
    (session / "transcript.json").unlink(missing_ok=True)
    raw = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-i", str(src), "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], capture_output=True).stdout
    if not raw:
        die(f"no audio decoded from {src}")
    proc = None
    with open(live / "audio.pcm", "wb") as fh:
        if a.run:
            proc = subprocess.Popen([sys.executable, __file__, "run", str(session), "--watch-pid", str(os.getpid())])
        step = BPS // 10  # 100 ms, like the recorder
        t0 = time.time()
        for i in range(0, len(raw), step):
            fh.write(raw[i:i + step])
            fh.flush()
            if a.speed > 0:
                time.sleep(max(0.0, t0 + (i + step) / BPS / a.speed - time.time()))
    feed_s = time.time() - t0
    (live / "stop").touch()
    t_stop = time.time()
    out = {"audio_seconds": round(len(raw) / BPS, 1), "feed_seconds": round(feed_s, 1), "pcm": str(live / "audio.pcm")}
    if proc:
        while proc.poll() is None and (load_json(live / "status.json", {}) or {}).get("asr") != "done":
            time.sleep(0.05)
        out["stop_to_transcript_seconds"] = round(time.time() - t_stop, 2)
        out["transcript"] = str(session / "transcript.json") if (session / "transcript.json").exists() else None
        proc.wait(timeout=60)
        out["exit"] = proc.returncode
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def cmd_status(a) -> int:
    print(json.dumps(load_json(Path(a.session) / "live" / "status.json", {}) or {"asr": None}, ensure_ascii=False, indent=2))
    return 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="tail <session>/live/audio.pcm until live/stop")
    r.add_argument("session")
    r.add_argument("--watch-pid", type=int, help="the recorder's pid: if it dies without live/stop, finish anyway")
    s = sub.add_parser("simulate", help="write an audio file into <session>/live/audio.pcm in real time, then stop")
    s.add_argument("audio")
    s.add_argument("session")
    s.add_argument("--speed", type=float, default=1.0, help="N× real time; 0 = as fast as possible")
    s.add_argument("--run", action="store_true", help="also run `live.py run` and time stop → transcript.json")
    st = sub.add_parser("status")
    st.add_argument("session")
    a = p.parse_args()
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit({"run": cmd_run, "simulate": cmd_simulate, "status": cmd_status}[a.cmd](a))


if __name__ == "__main__":
    main()
