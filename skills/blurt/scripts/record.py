# /// script
# requires-python = ">=3.10"
# dependencies = ["sounddevice", "numpy"]
# ///
"""Screen + microphone recorder (macOS, Windows, Linux/X11) with a proper recording UI.

The user picks the area to record (drag / click a window / full screen), a 3-2-1 countdown runs, and a floating
control bar offers pause, marker, discard and stop — so they never have to come back to the chat to stop.
The control bar and the region border are never part of the recording.

Engines (auto-selected; override with --engine or ~/.blurt/config.json → record.engine):
  native   macOS: ScreenCaptureKit app (recorder/macos, a SwiftPM package), built on first use with `swift build`.
  tk       Windows, Linux/X11 (and macOS fallback): Tk picker + control bar, ffmpeg video, PortAudio mic.
  ffmpeg   headless full-screen capture, stop from chat only (no GUI available).

  record.py start [--session DIR] [--region x,y,w,h | --last-region] [--engine E] [--countdown 3]
                                        run in the background; exits when the user stops (prints DONE …)
  record.py stop | pause | resume | restart | discard | snap   control the active recording from the chat (snap =
                                        a full-resolution still of the area now → shots/)
  record.py inbox                       recordings made with the Blurt app (~/Blurt, bound projects) + processed?
  record.py install-app                 double-clickable recorder: ~/Applications/Blurt.app / Start-menu "Blurt"
  record.py status                      active recording, if any
  record.py devices                     screens / microphones (JSON)
  record.py test [--seconds 3]          headless capture → permission / mic check, returns a screen frame
  record.py build                       (macOS) compile the native recorder now
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import wave
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (BLURT_HOME, IS_LINUX, IS_MAC, IS_WIN, STATE_FILE, die, ffmpeg_bin, fix_tcl_env, fmt_ts,  # noqa: E402
                     global_config, load_json, new_session_dir, probe_duration, run, save_json, update_global_config)

VIRTUAL_MIC_HINTS = ("virtual", "blackhole", "loopback", "soundflower", "zoom", "teams", "oray", "vb-audio",
                     "voicemeeter", "stereo mix", "立体声混音", "aggregate", "聚集", "cable")
AUDIO_SR = 48000
SWIFT_DIR = Path(__file__).resolve().parent.parent / "recorder" / "macos"
AGENTS_JSON = Path(__file__).with_name("agents.json")  # bundled into the app (Agents.swift)


def out(obj: dict | str) -> None:
    print(obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------- devices
def list_screens() -> list[dict]:
    ff = ffmpeg_bin()
    if IS_MAC:
        res = run([ff, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""], check=False).stderr
        screens, section = [], None
        for line in res.splitlines():
            if "video devices" in line:
                section = "v"
            elif "audio devices" in line:
                section = "a"
            m = re.search(r"\]\s\[(\d+)\]\s(.+)$", line)
            if m and section == "v" and "capture screen" in m.group(2).lower():
                screens.append({"index": int(m.group(1)), "name": m.group(2).strip()})
        return screens
    return [{"index": 0, "name": "primary monitor"}]


def list_mics() -> list[dict]:
    try:
        import sounddevice as sd
        sd.query_hostapis()
    except Exception as e:  # PortAudio missing (Linux: libportaudio2) or no audio service/device at all
        print(f"no microphone available: {e}", file=sys.stderr)
        return []
    try:
        default_in = sd.default.device[0]
    except Exception:
        default_in = None
    hostapis = sd.query_hostapis()
    mics = []
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] < 1:
            continue
        api = hostapis[d["hostapi"]]["name"]
        if IS_WIN and "WASAPI" not in api and "MME" not in api:
            continue
        mics.append({"index": i, "name": d["name"], "api": api, "default": i == default_in,
                     "samplerate": int(d["default_samplerate"])})
    return mics


def pick_mic(wanted: str | None) -> dict | None:
    mics = list_mics()
    if not mics:
        return None
    if wanted is not None:
        for m in mics:
            if str(m["index"]) == str(wanted) or str(wanted).lower() in m["name"].lower():
                return m
        die(f"Microphone '{wanted}' not found. Available: {[m['name'] for m in mics]}")
    for m in mics:
        if m["default"] and not any(h in m["name"].lower() for h in VIRTUAL_MIC_HINTS):
            return m
    real = [m for m in mics if not any(h in m["name"].lower() for h in VIRTUAL_MIC_HINTS)]
    return (real or mics)[0]


# ---------------------------------------------------------------- audio (tk / ffmpeg engines)
class MicRecorder:
    """Streams the mic to WAV via PortAudio (ffmpeg's own mic capture drops ~10% of samples on macOS).
    `gate()` False ⇒ samples are dropped (pause). Records the wall-clock time of the first sample.
    `live`: also feed <session>/live/audio.pcm for live.py (LivePcm; the caller registers video segments)."""

    def __init__(self, mic: dict, path: Path, gate=None, live: Path | None = None):
        import sounddevice as sd
        self.path, self.q, self.first_wall, self.overflows, self.frames = path, queue.Queue(), None, 0, 0
        self.gate = gate or (lambda: True)
        self.sr = mic.get("samplerate") or AUDIO_SR
        self.live = None
        if live is not None:
            try:
                self.live = LivePcm(live, self.sr)
            except Exception as e:  # never block a recording on the sidecar
                print(f"(no live audio: {e})", file=sys.stderr)
        self.stream = sd.RawInputStream(samplerate=self.sr, channels=1, dtype="int16", device=mic["index"],
                                        callback=self._cb)
        self.writer = threading.Thread(target=self._write, daemon=True)

    def _cb(self, data, frames, t, status):
        if self.first_wall is None:
            self.first_wall = time.time() - max(0.0, t.currentTime - t.inputBufferAdcTime)
        if status.input_overflow:
            self.overflows += 1
        if self.gate():
            self.q.put(bytes(data))

    def _write(self):
        with wave.open(str(self.path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.sr)
            while (chunk := self.q.get()) is not None:
                w.writeframes(chunk)
                self.frames += len(chunk) // 2
                if self.live:
                    try:
                        self.live.feed(chunk)
                    except Exception as e:
                        print(f"(live audio stopped: {e})", file=sys.stderr)
                        self.live = None

    def start(self):
        self.writer.start()
        self.stream.start()

    def stop(self):
        self.stream.stop()
        self.stream.close()
        self.q.put(None)
        self.writer.join()


# ---------------------------------------------------------------- live audio sidecar (tk / ffmpeg engines)
class Resampler:
    """Streaming windowed-sinc (Kaiser) resampler for int16 mono, any rate → 16 kHz, with anti-alias low-pass."""

    def __init__(self, in_sr: int, out_sr: int = 16000, half_taps: int = 16):
        import numpy as np
        self.np, self.in_sr, self.out_sr = np, in_sr, out_sr
        self.step = in_sr / out_sr                       # input samples per output sample
        self.fc = min(1.0, out_sr / in_sr) * 0.94        # cutoff, as a fraction of the input Nyquist
        self.W = int(np.ceil(half_taps / self.fc))       # kernel half-width in input samples
        self.buf = np.zeros(self.W, np.float32)          # leading zeros = history before the first sample
        self.base = -self.W                              # input index of buf[0]
        self.n = 0                                       # next output sample

    def _kernel(self, d):
        np = self.np
        r = np.clip(d / self.W, -1.0, 1.0)
        return self.fc * np.sinc(self.fc * d) * np.i0(8.0 * np.sqrt(1.0 - r * r)) / np.i0(8.0)

    def feed(self, pcm: bytes, final: bool = False) -> bytes:
        np = self.np
        x = np.frombuffer(pcm[:len(pcm) // 2 * 2], dtype=np.int16).astype(np.float32)
        if self.in_sr == self.out_sr:
            return pcm[:len(pcm) // 2 * 2]
        if final:
            x = np.concatenate([x, np.zeros(self.W + 1, np.float32)])
        self.buf = np.concatenate([self.buf, x])
        end = self.base + len(self.buf)                  # first input index we don't have
        last = int(np.floor((end - self.W - 1) / self.step))
        if final:
            last = int(np.floor((end - self.W - 2) / self.step))
        if last < self.n:
            return b""
        P = np.arange(self.n, last + 1) * self.step      # output positions on the input timeline
        k0 = np.floor(P).astype(int)
        taps = np.arange(-self.W + 1, self.W + 1)
        idx = k0[:, None] + taps[None, :]
        y = (self.buf[idx - self.base] * self._kernel(P[:, None] - idx)).sum(axis=1)
        self.n = last + 1
        keep = int(np.floor(self.n * self.step)) - self.W - 1   # drop history no future output needs
        if keep > self.base:
            self.buf = self.buf[keep - self.base:]
            self.base = keep
        return np.clip(np.round(y), -32768, 32767).astype(np.int16).tobytes()


class LivePcm:
    """Writes <session>/live/audio.pcm (16 kHz mono s16le) for live.py while the WAV is being recorded.

    The mp4's audio is cut per video segment: each segment's first `lead` seconds (mic opened before ffmpeg's first
    frame) are dropped, or silence is added when the video started first (see TkRecorder.finalize / mux). The same is
    done here, so byte offset / 32000 == video time. A segment's samples are held until its lead is known (ffmpeg log),
    at most HOLD seconds."""

    HOLD = 4.0

    def __init__(self, live_dir: Path, in_sr: int):
        self.dir, self.sr = Path(live_dir), in_sr
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "stop").unlink(missing_ok=True)
        self.fh = open(self.dir / "audio.pcm", "wb")
        self.rs = Resampler(in_sr)
        self.lock = threading.Lock()
        self.segments: list[dict] = []   # {"start": frame, "lead": s | None, "added": wall}
        self.frame = 0                   # gated frames received
        self.held = bytearray()          # frames not yet released, starting at self.held_at
        self.held_at = 0
        self.closed = False
        self.flushed = 0.0

    def segment(self, start_frame: int) -> int:
        """A video segment starts at this frame of the gated audio stream (MicRecorder.frames)."""
        with self.lock:
            self.segments.append({"start": start_frame, "lead": None, "added": time.time(), "begun": False, "skip": 0})
            return len(self.segments) - 1

    def set_lead(self, i: int, lead: float) -> None:
        with self.lock:
            if 0 <= i < len(self.segments) and self.segments[i]["lead"] is None:
                self.segments[i]["lead"] = float(lead)
        self.feed(b"")

    def lead_known(self, i: int) -> bool:
        return self.segments[i]["lead"] is not None

    def _release(self, final: bool) -> bytes:
        out = bytearray()
        while True:
            n = len(self.held) // 2
            pos = self.held_at
            if not self.segments:
                if final:
                    self.held.clear()
                return bytes(out)
            if pos < self.segments[0]["start"]:  # before the first segment: not in the video (as in finalize)
                d = min(n, self.segments[0]["start"] - pos)
                if d == 0:
                    return bytes(out)
                del self.held[:d * 2]
                self.held_at += d
                continue
            k = max(j for j, s in enumerate(self.segments) if s["start"] <= pos)
            seg = self.segments[k]
            nxt = self.segments[k + 1]["start"] if k + 1 < len(self.segments) else None
            if seg["lead"] is None:
                if not final and time.time() - seg["added"] < self.HOLD:
                    return bytes(out)
                seg["lead"] = 0.0
            if not seg["begun"]:
                seg["begun"] = True
                seg["skip"] = int(round(max(0.0, seg["lead"]) * self.sr))
                if seg["lead"] < 0:
                    out += b"\0\0" * int(round(-seg["lead"] * self.sr))
            avail = n if nxt is None else min(n, nxt - pos)
            if avail <= 0:
                return bytes(out)
            if seg["skip"]:
                d = min(seg["skip"], avail)
                seg["skip"] -= d
            else:
                d = avail
                out += self.held[:d * 2]
            del self.held[:d * 2]
            self.held_at += d

    def feed(self, chunk: bytes, final: bool = False) -> None:
        with self.lock:
            if self.closed:
                return
            self.held += chunk
            self.frame += len(chunk) // 2
            out = self._release(final)
            data = self.rs.feed(out, final=final) if out or final else b""
            if data:
                self.fh.write(data)
            if final or time.time() - self.flushed > 0.1:  # ≈100 ms, like the native recorder
                self.fh.flush()
                self.flushed = time.time()

    def finish(self) -> None:
        """All audio is in (MicRecorder.stop joined its writer): release the rest, then create live/stop."""
        self.feed(b"", final=True)
        with self.lock:
            self.closed = True
            self.fh.close()
        (self.dir / "stop").touch()

    def discard(self) -> None:
        with self.lock:
            self.closed = True
            self.fh.close()
        shutil.rmtree(self.dir, ignore_errors=True)


LIVE: dict = {}  # {"proc": the live.py process of the current take}


def live_enabled(cfg: dict | None = None) -> bool:
    return (cfg if cfg is not None else global_config().get("record", {})).get("live") is not False \
        and (Path(__file__).parent / "live.py").exists() and shutil.which("uv") is not None


def start_live(session: Path) -> subprocess.Popen | None:
    """Run live.py for this take in the background (transcript + drafts while recording). Never fails the recording."""
    if not live_enabled():
        return None
    live = session / "live"
    try:
        live.mkdir(parents=True, exist_ok=True)
        log = open(session / "live.log", "a", encoding="utf-8")  # outside live/: a restart deletes live/
        kw = {"creationflags": 0x00000200 | 0x08000000} if IS_WIN else {"start_new_session": True}  # own group, no window
        return subprocess.Popen([shutil.which("uv"), "run", "-q", str(Path(__file__).parent / "live.py"), "run",
                                 str(session), "--watch-pid", str(os.getpid())],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log, **kw)
    except Exception as e:
        print(f"(live transcript not started: {e})", file=sys.stderr)
        return None


def end_live(proc: subprocess.Popen | None, session: Path, stopped: bool, wait: float = 10) -> None:
    """After the take: let live.py finish the transcript (briefly — transcribe.py waits longer if needed), or, for a
    cancelled take, stop it and remove live/."""
    live = session / "live"
    if not stopped:
        if proc and proc.poll() is None:
            proc.terminate()
        shutil.rmtree(live, ignore_errors=True)
        return
    if proc is None:
        shutil.rmtree(live, ignore_errors=True)  # no live run: the sidecar is just litter
        return
    t0 = time.time()
    while proc.poll() is None and time.time() - t0 < wait:
        if (load_json(live / "status.json", {}) or {}).get("asr") in ("done", "off", "error"):
            break
        time.sleep(0.2)


# ---------------------------------------------------------------- video helpers (tk / ffmpeg engines)
def pick_encoder(ff: str) -> list[str]:
    candidates = (["h264_videotoolbox"] if IS_MAC else ["h264_nvenc", "h264_qsv", "h264_amf"]) + ["libx264"]
    for enc in candidates:
        if enc == "libx264":
            break
        test = run([ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=640x360:d=0.2",
                    "-c:v", enc, "-f", "null", "-"], check=False)
        if test.returncode == 0:
            if enc == "h264_videotoolbox":
                return ["-c:v", enc, "-b:v", "2500k", "-maxrate", "4M", "-bufsize", "8M", "-realtime", "1"]
            if enc == "h264_nvenc":
                return ["-c:v", enc, "-preset", "p4", "-cq", "30"]
            return ["-c:v", enc, "-b:v", "2500k"]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-tune", "zerolatency"]


def first_frame_wall(log: Path) -> float | None:
    try:
        m = re.search(r"Duration: .*?start: (\d{9,}\.\d+)", Path(log).read_text(encoding="utf-8", errors="replace"))
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None


def headless_video_cmd(out_path: Path, screen, fps: int, max_width: int) -> list[str]:
    ff = ffmpeg_bin()
    scale = f"scale='min({max_width},iw)':-2,format=yuv420p"
    cmd = [ff, "-hide_banner", "-nostats", "-loglevel", "info", "-y", "-use_wallclock_as_timestamps", "1"]
    if os.environ.get("BLURT_FAKE_SCREEN"):
        cmd += ["-re", "-f", "lavfi", "-i", f"testsrc2=s=1280x720:r={fps}"]
        scale = "format=yuv420p"
    elif IS_MAC:
        if screen is None:
            screens = list_screens() or die("No capturable screen (Screen Recording permission?)")
            screen = screens[0]["index"]
        cmd += ["-thread_queue_size", "1024", "-f", "avfoundation", "-capture_cursor", "1",
                "-capture_mouse_clicks", "1", "-framerate", str(fps), "-i", f"{screen}:none"]
    elif IS_LINUX:
        cmd += ["-thread_queue_size", "1024", "-f", "x11grab", "-framerate", str(fps), "-draw_mouse", "1",
                "-i", os.environ.get("DISPLAY", ":0")]
    else:
        dda = f"ddagrab=output_idx={screen or 0}:framerate={fps}:draw_mouse=1"
        # ddagrab needs Desktop Duplication on a D3D11 device: absent over RDP, on GPU-less VMs, in service sessions
        has_dda = "ddagrab" in run([ff, "-hide_banner", "-filters"], check=False).stdout and run(
            [ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", dda, "-frames:v", "1", "-f", "null", "-"],
            check=False).returncode == 0
        if has_dda:
            cmd += ["-f", "lavfi", "-i", dda]
            scale = "hwdownload,format=bgra," + scale
        else:
            cmd += ["-thread_queue_size", "1024", "-f", "gdigrab", "-framerate", str(fps), "-draw_mouse", "1",
                    "-i", "desktop"]
    return cmd + ["-vf", scale, *pick_encoder(ff), "-g", str(fps * 2), str(out_path)]


def mux(video: Path, audio: Path | None, offset: float, dest: Path) -> None:
    """offset = audio_start - video_start (s). Positive ⇒ audio began later ⇒ delay it."""
    cmd = [ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", str(video)]
    if audio and audio.exists() and audio.stat().st_size > 1000:
        if offset >= 0:
            cmd += ["-i", str(audio)]
            af = f"adelay={int(offset * 1000)}:all=1"
        else:
            cmd += ["-ss", f"{-offset:.3f}", "-i", str(audio)]
            af = "anull"
        cmd += ["-map", "0:v", "-map", "1:a", "-c:v", "copy", "-af", af, "-c:a", "aac", "-b:a", "96k", "-shortest"]
    else:
        cmd += ["-c", "copy"]
    r = run(cmd + ["-movflags", "+faststart", str(dest)], check=False)
    if r.returncode:
        die(f"mux failed: {r.stderr[-800:]}")


# ---------------------------------------------------------------- native macOS recorder
APP_BUNDLE = BLURT_HOME / "Blurt.app"
ICON = Path(__file__).resolve().parent.parent / "assets" / "icon.png"
INFO_PLIST = SWIFT_DIR / "Info.plist"


def swift_sources() -> list[Path]:
    """Everything the build depends on: Package.swift, Info.plist, Sources/** (not .build/)."""
    files = [SWIFT_DIR / "Package.swift", INFO_PLIST]
    files += sorted(p for p in (SWIFT_DIR / "Sources").rglob("*") if p.is_file() and not p.name.startswith("."))
    return [f for f in files if f.exists()]


def swift_build(scratch: Path, triple: str | None = None) -> Path | None:
    """`swift build -c release` (Command Line Tools are enough) → the blurt-recorder executable, or None."""
    cmd = ["swift", "build", "-c", "release", "--package-path", str(SWIFT_DIR), "--scratch-path", str(scratch),
           "--product", "blurt-recorder"]
    if triple:
        cmd += ["--triple", triple]
    r = run(cmd, check=False)
    if r.returncode:
        print(f"native recorder build failed{f' for {triple}' if triple else ''}:\n{(r.stderr or r.stdout)[-2500:]}",
              file=sys.stderr)
        return None
    r = run(cmd + ["--show-bin-path"], check=False)
    exe = Path(r.stdout.strip().splitlines()[-1]) / "blurt-recorder" if r.returncode == 0 and r.stdout.strip() else None
    return exe if exe and exe.exists() else None


def native_binary(build: bool = True) -> Path | None:
    """The recorder lives inside ~/.blurt/Blurt.app so it can also be launched as a standalone app.
    Built from recorder/macos (a SwiftPM package) with `swift build`; BLURT_UNIVERSAL=1 → arm64 + x86_64 (lipo);
    BLURT_SPARKLE=1 → with Sparkle (auto-update; release builds, see scripts/release-mac.sh)."""
    if not IS_MAC or not (SWIFT_DIR / "Package.swift").exists():
        return None
    remember_skill_dir()
    h = hashlib.sha256()
    for p in swift_sources():
        h.update(str(p.relative_to(SWIFT_DIR)).encode() + b"\0" + p.read_bytes())
    if AGENTS_JSON.exists():
        h.update(AGENTS_JSON.read_bytes())
    if os.environ.get("BLURT_UNIVERSAL"):
        h.update(b"universal")
    sparkle = os.environ.get("BLURT_SPARKLE") == "1"
    if sparkle:
        h.update(b"sparkle")
    digest = h.hexdigest()[:12]
    exe = APP_BUNDLE / "Contents" / "MacOS" / "blurt-recorder"
    stamp = APP_BUNDLE / "Contents" / "Resources" / "source.sha"
    if exe.exists() and stamp.exists() and stamp.read_text().strip() == digest:
        return exe
    if not build:
        return None
    if not shutil.which("swift"):
        return None
    print("building native recorder (one-time, ~1 min)…", file=sys.stderr, flush=True)
    # Package.swift reads BLURT_SPARKLE: separate scratch dirs so SwiftPM's cached manifest never mixes the two
    scratch = BLURT_HOME / "build" / ("swiftpm-sparkle" if sparkle else "swiftpm")
    tmp = BLURT_HOME / "build" / "blurt-recorder"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.unlink(missing_ok=True)
    if os.environ.get("BLURT_UNIVERSAL"):  # release builds: arm64 + x86_64 in one binary
        parts = []
        for arch in ("arm64", "x86_64"):
            built = swift_build(scratch, f"{arch}-apple-macosx13.0")
            if not built:
                return None
            parts.append(str(built))
        r = run(["lipo", "-create", *parts, "-output", str(tmp)], check=False)
        if r.returncode:
            print(f"lipo failed: {r.stderr[-800:]}", file=sys.stderr)
            return None
    else:
        built = swift_build(scratch)
        if not built:
            return None
        shutil.copy2(built, tmp)
    run(["strip", "-S", "-x", str(tmp)], check=False)   # local symbols / debug notes: ~1.9 → 1.2 MB per arch
    shutil.rmtree(APP_BUNDLE, ignore_errors=True)
    (APP_BUNDLE / "Contents" / "MacOS").mkdir(parents=True)
    (APP_BUNDLE / "Contents" / "Resources").mkdir(parents=True)
    shutil.move(str(tmp), exe)
    if sparkle:  # swift build leaves the (universal, Sparkle-signed) framework next to the executable
        fw = Path(run(["swift", "build", "-c", "release", "--package-path", str(SWIFT_DIR), "--scratch-path", str(scratch),
                       "--show-bin-path"], check=False).stdout.strip().splitlines()[-1]) / "Sparkle.framework"
        if not fw.exists():
            fw = next(scratch.glob("*/release/Sparkle.framework"), fw)
        if not fw.exists():
            print("Sparkle.framework missing from the build", file=sys.stderr)
            return None
        (APP_BUNDLE / "Contents" / "Frameworks").mkdir()
        dest = APP_BUNDLE / "Contents" / "Frameworks" / "Sparkle.framework"
        shutil.copytree(fw, dest, symlinks=True)
        prune_sparkle(dest)
    shutil.copy(INFO_PLIST, APP_BUNDLE / "Contents" / "Info.plist")
    make_icns(APP_BUNDLE / "Contents" / "Resources" / "AppIcon.icns")
    make_menu_icon(APP_BUNDLE / "Contents" / "Resources")
    if AGENTS_JSON.exists():
        shutil.copy(AGENTS_JSON, APP_BUNDLE / "Contents" / "Resources" / "agents.json")
    stamp.write_text(digest)          # before signing: the signature seals Resources/
    sign_app(APP_BUNDLE)
    ensure_app_installed(force=True)
    return exe


def prune_sparkle(fw: Path) -> None:
    """Drop what a non-sandboxed app doesn't load (headers, module map, the XPC services Sparkle only needs inside the
    App Sandbox) — ~0.6 MB — and re-sign what's left ad hoc, inside out (release-mac.sh re-signs with Developer ID)."""
    for rel in ("Headers", "PrivateHeaders", "Modules", "XPCServices"):
        for p in (fw / rel, fw / "Versions" / "B" / rel):
            if p.is_symlink():
                p.unlink()
            elif p.exists():
                shutil.rmtree(p)
    b = fw / "Versions" / "B"
    for nested in (b / "Autoupdate", b / "Updater.app", fw):
        run(["codesign", "--force", "--sign", "-", str(nested)], check=False)


def remember_skill_dir() -> None:
    skill = str(Path(__file__).resolve().parent.parent)
    if global_config().get("skill_dir") != skill:
        update_global_config({"skill_dir": skill})


def ensure_app_installed(force: bool = False) -> Path | None:
    """Keep a double-clickable recorder where people look for apps — done automatically on first use / update.
    Opt out with ~/.blurt/config.json → {"record": {"install_app": false}}. With a non-default BLURT_HOME (tests, CI)
    nothing is installed unless that config says {"install_app": true} — a test build must never replace the real app."""
    setting = global_config().get("record", {}).get("install_app")
    if setting is False or (setting is not True and "BLURT_HOME" in os.environ):
        return None
    try:
        if IS_MAC:
            dest = Path.home() / "Applications" / "Blurt.app"
            if dest.exists() and not force:
                return dest
            if not (APP_BUNDLE / "Contents" / "MacOS" / "blurt-recorder").exists():
                return None
            dest.parent.mkdir(exist_ok=True)
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(APP_BUNDLE, dest, symlinks=True)
            sign_app(dest)
            print(f"installed standalone recorder: {dest}", file=sys.stderr, flush=True)
            return dest
        if IS_WIN:
            lnk = Path(os.environ["APPDATA"]) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Blurt.lnk"
            if lnk.exists() and not force:
                return lnk
            uv = shutil.which("uv")
            if not uv:
                return None
            ps = (f"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{lnk}');$s.TargetPath='{uv}';"
                  f"$s.Arguments='run --gui-script \"{Path(__file__).resolve()}\" start --inbox';"
                  f"$s.WorkingDirectory='{Path.home()}';$s.Save()")
            run(["powershell", "-NoProfile", "-Command", ps], check=False)
            return lnk if lnk.exists() else None
    except Exception as e:  # never block a recording on this
        print(f"(could not install standalone recorder: {e})", file=sys.stderr)
    return None


def sign_app(bundle: Path) -> None:
    """Ad-hoc sign with a designated requirement on the bundle id (not the default per-build cdhash), so macOS keeps
    the Screen Recording / Microphone grant across rebuilds and updates instead of silently revoking it."""
    run(["codesign", "--force", "--sign", "-", "--identifier", "dev.blurt.recorder",
         "-r=designated => identifier \"dev.blurt.recorder\"", str(bundle)], check=False)


def make_menu_icon(res: Path) -> None:
    """Menu-bar icon: a monochrome template (macOS tints it for light / dark menu bars)."""
    for name in ("MenuIconTemplate.png", "MenuIconTemplate@2x.png"):
        src = ICON.parent / name
        if src.exists():
            shutil.copy(src, res / name)


def make_icns(dest: Path) -> None:
    if not ICON.exists():
        return
    iconset = BLURT_HOME / "build" / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True)
    for size in (16, 32, 64, 128, 256, 512):
        run(["sips", "-z", str(size), str(size), str(ICON), "--out", str(iconset / f"icon_{size}x{size}.png")], check=False)
        if size <= 256:
            run(["sips", "-z", str(size * 2), str(size * 2), str(ICON), "--out", str(iconset / f"icon_{size}x{size}@2x.png")],
                check=False)
    run(["iconutil", "-c", "icns", str(iconset), "-o", str(dest)], check=False)


def inbox_dir() -> Path:
    """The default workspace's recordings (the Blurt app and --inbox): ~/Blurt/recordings."""
    return Path.home() / "Blurt" / "recordings"


def recording_roots() -> list[Path]:
    """Everywhere recordings may live: the default workspace and projects bound in the app."""
    roots = [inbox_dir()]
    for w in global_config().get("record", {}).get("workspaces", []) or []:
        roots.append(Path(w) / ".blurt" / "sessions")
    return [r for r in dict.fromkeys(roots) if r.exists()]


def tk_available() -> bool:
    fix_tcl_env()
    try:
        import tkinter
        r = tkinter.Tcl()  # interpreter only, no window
        r.eval("info library")
        return True
    except Exception:
        return False


def choose_engine(wanted: str | None) -> str:
    if wanted:
        return wanted
    if IS_MAC and native_binary(build=True):
        return "native"
    if tk_available():
        return "tk"
    return "ffmpeg"


# ---------------------------------------------------------------- ux helpers
def chime(kind: str) -> None:
    try:
        if IS_MAC:
            snd = {"start": "Glass", "stop": "Submarine"}[kind]
            subprocess.Popen(["afplay", f"/System/Library/Sounds/{snd}.aiff"])
        elif IS_WIN:
            import winsound
            winsound.MessageBeep(winsound.MB_OK if kind == "start" else winsound.MB_ICONASTERISK)
    except Exception:
        pass


def lang() -> str:
    cfg = global_config()
    if cfg.get("lang"):
        return cfg["lang"]
    if IS_MAC:
        r = run(["defaults", "read", "-g", "AppleLanguages"], check=False).stdout
        return "zh" if "zh" in r.split(",")[0] else "en"
    import locale
    return "zh" if (locale.getlocale()[0] or "").lower().startswith(("zh", "chinese")) else "en"


def parse_region(s: str | None) -> list[int] | None:
    if not s:
        return None
    p = [int(float(v)) for v in s.split(",")]
    if len(p) != 4:
        die("--region needs x,y,w,h")
    return p


# ---------------------------------------------------------------- start
def cmd_start(a) -> None:
    state = load_json(STATE_FILE)
    if state and _alive(state.get("pid")):
        die(f"A recording is already running: {state['session']}. Run `record.py stop` first.")
    if a.session:
        session = Path(a.session)
    elif a.inbox:
        session = inbox_dir() / datetime.now().strftime("%Y%m%d-%H%M%S")
    else:
        session = new_session_dir()
    session = session.resolve()
    session.mkdir(parents=True, exist_ok=True)
    cfg = global_config().get("record", {})
    engine = choose_engine(a.engine or cfg.get("engine"))
    if IS_WIN:
        ensure_app_installed()
    last = cfg.get("last_region")
    region = parse_region(a.region) or (last if a.last_region else None)
    cmd_file = session / ".cmd"
    cmd_file.unlink(missing_ok=True)
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    save_json(STATE_FILE, {"pid": os.getpid(), "session": str(session), "engine": engine, "started_at": started})
    meta = {"started_at": started, "engine": engine}
    out(f"SESSION {session}  engine={engine}")
    LIVE.clear()
    try:
        if engine == "native":
            result = run_native(session, a, cfg, last, region, cmd_file)
        elif engine == "tk":
            result = run_tk(session, a, cfg, last, region, cmd_file)
        else:
            result = run_headless(session, a, cfg, cmd_file)
    finally:
        STATE_FILE.unlink(missing_ok=True)
        cmd_file.unlink(missing_ok=True)

    ev = result.get("event")
    end_live(LIVE.get("proc"), session, stopped=ev == "stopped")
    if ev == "cancelled":
        out(f"CANCELLED {result.get('reason', 'by user')} — nothing was recorded")
        sys.exit(2)
    if ev == "error":
        hint = ""
        if result.get("code") == "screen_permission":
            hint = (" → grant Screen Recording to the app hosting this agent (System Settings → Privacy & Security → "
                    "Screen & System Audio Recording), then restart that app.")
        die(f"recording failed: {result.get('code')}: {result.get('message')}{hint}")
    final = session / "recording.mp4"
    if result.get("region"):
        update_global_config({"record": {"last_region": result["region"]}})
    dur = probe_duration(final)
    events = session / "events.jsonl"
    n_markers = sum(1 for l in events.open(encoding="utf-8") if '"marker"' in l) if events.exists() else 0
    meta.update({k: v for k, v in result.items() if k not in ("event", "file")}, video=final.name, duration=dur)
    save_json(session / "meta.json", meta)
    shots = session / "shots.jsonl"
    n_shots = len({json.loads(l)["n"] for l in shots.open(encoding="utf-8") if l.strip()}) if shots.exists() else 0
    out(f"DONE video={final} duration={fmt_ts(dur)} markers={n_markers} shots={n_shots} events={'events.jsonl' if events.exists() else '-'}")


def run_native(session: Path, a, cfg, last, region, cmd_file: Path) -> dict:
    exe = native_binary()
    args = [str(exe), "--out", str(session / "recording.mp4"), "--events", str(session / "events.jsonl"),
            "--fps", str(a.fps or cfg.get("fps", 30)), "--max-width", str(a.max_width or cfg.get("max_width", 2560)),
            "--countdown", str(a.countdown if a.countdown is not None else cfg.get("countdown", 3)), "--lang", lang()]
    if region:
        args += ["--region", ",".join(map(str, region))]
    elif last:
        args += ["--last-region", ",".join(map(str, last))]
    if a.no_mic:
        args += ["--no-mic"]
    elif a.mic or cfg.get("mic"):
        args += ["--mic", str(a.mic or cfg.get("mic"))]
    if a.system_audio or cfg.get("system_audio"):
        args += ["--system-audio"]
    use_live = not a.no_mic and live_enabled(cfg)
    if not use_live:
        args += ["--no-live"]
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8")
    final: dict = {}
    selected = None

    def reader():
        nonlocal final, selected
        for line in p.stdout:
            line = line.strip()
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("event") == "configured":
                selected = e.get("region")
            if e.get("event") == "recording" and use_live and "proc" not in LIVE:
                LIVE["proc"] = start_live(session)
            if e.get("event") in ("stopped", "cancelled", "error"):
                final = e
            if e.get("event") not in ("configured",):
                out(e)

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    forward = lambda c: (p.stdin.write(c + "\n"), p.stdin.flush())  # noqa: E731
    signal.signal(signal.SIGINT, lambda *_: forward("stop"))
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, lambda *_: forward("stop"))
    t0 = time.time()
    while p.poll() is None:
        if cmd_file.exists():
            for c in cmd_file.read_text(encoding="utf-8").split():
                try:
                    forward(c)
                except Exception:
                    pass
            cmd_file.unlink(missing_ok=True)
        if a.max_minutes and time.time() - t0 > a.max_minutes * 60:
            forward("stop")
        time.sleep(0.25)
    th.join(timeout=2)
    if not final:
        final = {"event": "error", "code": f"exit_{p.returncode}", "message": "recorder exited unexpectedly"}
    if final.get("event") == "stopped" and selected:
        final["region"] = [int(v) for v in selected]
    return final


def run_tk(session: Path, a, cfg, last, region, cmd_file: Path) -> dict:
    from tk_recorder import TkRecorder
    mic = None if a.no_mic else pick_mic(a.mic or cfg.get("mic"))
    def on_event(e):
        out(e)
        if e.get("event") == "recording" and rec.live_audio and "proc" not in LIVE:
            LIVE["proc"] = start_live(session)
    rec = TkRecorder(session, mic, a.fps or cfg.get("fps", 30), a.max_width or cfg.get("max_width", 2560), lang(),
                     a.countdown if a.countdown is not None else cfg.get("countdown", 3), last, region, cmd_file, on_event)
    rec.live_audio = bool(mic) and live_enabled(cfg)
    result = rec.run()
    if result.get("event") == "stopped" and rec.region:
        result["region"] = rec.region
    return result


def run_headless(session: Path, a, cfg, cmd_file: Path) -> dict:
    mic = None if a.no_mic else pick_mic(a.mic or cfg.get("mic"))
    raw, wav, log_path = session / "video.mkv", session / "audio.wav", session / "ffmpeg.log"
    audio = MicRecorder(mic, wav, live=session / "live" if live_enabled(cfg) else None) if mic else None
    if audio:
        if audio.live:
            audio.live.segment(0)
        audio.start()
    log = open(log_path, "w", encoding="utf-8")
    p = subprocess.Popen(headless_video_cmd(raw, a.screen, a.fps or cfg.get("fps", 30), a.max_width or cfg.get("max_width", 1920)),
                         stdin=subprocess.PIPE, stdout=log, stderr=log)
    chime("start")
    out({"event": "recording", "engine": "ffmpeg"})
    if audio and audio.live:
        LIVE["proc"] = start_live(session)
    t0 = time.time()
    signal.signal(signal.SIGINT, lambda *_: cmd_file.write_text("stop"))
    discard = False
    while p.poll() is None:
        cmds = cmd_file.read_text(encoding="utf-8").split() if cmd_file.exists() else []
        cmd_file.unlink(missing_ok=True)
        if "stop" in cmds or "discard" in cmds or (a.max_minutes and time.time() - t0 > a.max_minutes * 60):
            discard = "discard" in cmds
            break
        if audio and audio.live and not audio.live.lead_known(0) and audio.first_wall:
            v0 = first_frame_wall(log_path)  # mux() shifts the audio by the same amount
            if v0:
                audio.live.set_lead(0, v0 - audio.first_wall)
        time.sleep(0.3)
    if p.poll() is None:
        try:
            p.stdin.write(b"q")
            p.stdin.flush()
            p.wait(timeout=20)
        except Exception:
            p.terminate()
    if audio:
        audio.stop()
        if audio.live:
            audio.live.discard() if discard else audio.live.finish()
    log.close()
    chime("stop")
    if discard:
        return {"event": "cancelled", "reason": "discarded"}
    if not raw.exists() or raw.stat().st_size == 0:
        return {"event": "error", "code": "no_frames", "message": log_path.read_text(errors="replace")[-800:]}
    v0 = first_frame_wall(log_path)
    off = (audio.first_wall - v0) if (audio and audio.first_wall and v0) else 0.0
    mux(raw, wav if audio else None, off, session / "recording.mp4")
    raw.unlink(missing_ok=True)
    return {"event": "stopped", "av_offset": round(off, 3)}


# ---------------------------------------------------------------- control
def send(command: str) -> None:
    state = load_json(STATE_FILE)
    if not state or not _alive(state.get("pid")):
        STATE_FILE.unlink(missing_ok=True)
        die("No active recording.")
    session = Path(state["session"])
    with open(session / ".cmd", "a", encoding="utf-8") as fh:
        fh.write(command + "\n")
    if command in ("stop", "discard"):
        for _ in range(240):
            if not STATE_FILE.exists():
                break
            time.sleep(0.25)
    print(json.dumps({"sent": command, "session": str(session)}))


def cmd_status(_a) -> None:
    state = load_json(STATE_FILE)
    if state and not _alive(state.get("pid")):
        STATE_FILE.unlink(missing_ok=True)
        state = None
    print(json.dumps(state or {"recording": False}, ensure_ascii=False))


def cmd_devices(_a) -> None:
    print(json.dumps({"screens": list_screens(), "mics": list_mics(),
                      "engine": choose_engine(global_config().get("record", {}).get("engine"))},
                     ensure_ascii=False, indent=2))


def cmd_inbox(_a) -> None:
    """Recordings made with the standalone app (or --inbox) and whether they've been turned into issues yet."""
    rows = []
    def is_shots(d: Path) -> bool:  # snap mode: screenshots + voice notes, no video
        return (load_json(d / "meta.json", {}) or {}).get("mode") == "shots"

    dirs = [d for r in recording_roots() for d in r.glob("*/") if (d / "recording.mp4").exists() or is_shots(d)]
    for d in sorted(dirs, key=lambda x: x.name, reverse=True):
        meta = load_json(d / "meta.json", {}) or {}
        out = load_json(d / "items.json")
        # items.json with "processing": true is a first draft whose frames are still being filled in (review.py
        # shows it early) — not processed yet
        processing = bool((out or {}).get("processing"))
        row = {"session": str(d), "author": meta.get("author"), "processed": out is not None and not processing,
               "processing": processing, "reviewed": bool((out or {}).get("reviewed"))}
        if is_shots(d):
            row = {"session": str(d), "mode": "shots", "shots": len(list((d / "shots").glob("[0-9]*.png")))
                   - len(list((d / "shots").glob("*.marked.png"))), **{k: v for k, v in row.items() if k != "session"}}
        else:
            row["duration"] = meta.get("duration") or round(probe_duration(d / "recording.mp4"), 1)
        rows.append(row)
    print(json.dumps({"roots": [str(r) for r in recording_roots()], "recordings": rows}, ensure_ascii=False, indent=2))


def cmd_install_app(_a) -> None:
    """(Re)install the standalone recorder: ~/Applications/Blurt.app (macOS) / Start-menu "Blurt" (Windows).
    Normally not needed — it's installed automatically the first time the recorder is built / used."""
    if IS_MAC and not native_binary():
        die("Needs Xcode Command Line Tools: xcode-select --install")
    dest = ensure_app_installed(force=True)
    print(json.dumps({"installed": str(dest) if dest else None, "recordings": str(inbox_dir())}, ensure_ascii=False))


def cmd_build(_a) -> None:
    exe = native_binary()
    app = ensure_app_installed() if exe else None
    print(json.dumps({"native": str(exe) if exe else None, "app": str(app) if app else None,
                      "hint": None if exe else "needs macOS + Xcode Command Line Tools (xcode-select --install)"}))


def cmd_test(a) -> None:
    """Headless 3 s capture: verifies Screen Recording + Microphone permission for the hosting app."""
    out_dir = Path(a.out or Path.cwd() / ".blurt" / "test")
    out_dir.mkdir(parents=True, exist_ok=True)
    mic = pick_mic(a.mic or global_config().get("record", {}).get("mic"))
    video, wav, log_path = out_dir / "test.mkv", out_dir / "audio.wav", out_dir / "ffmpeg.log"
    audio = MicRecorder(mic, wav) if mic else None
    if audio:
        audio.start()
    cmd = headless_video_cmd(video, a.screen, 15, 1920)
    cmd[-1:-1] = ["-t", str(a.seconds)]
    try:
        with open(log_path, "w", encoding="utf-8") as log:
            subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=log, timeout=a.seconds + 20)
    except subprocess.TimeoutExpired:
        if audio:
            audio.stop()
        print(json.dumps({"ok": False, "mic": mic, "error": "ffmpeg hung opening the screen: Screen Recording "
                          "permission is missing for the app hosting this agent (System Settings → Privacy & Security "
                          "→ Screen & System Audio Recording), then restart that app."}, ensure_ascii=False, indent=2))
        return
    if audio:
        audio.stop()
    if not video.exists() or video.stat().st_size == 0:
        print(json.dumps({"ok": False, "mic": mic, "error": log_path.read_text(errors="replace")[-800:]}, ensure_ascii=False))
        return
    frame = out_dir / "test-frame.jpg"
    run([ffmpeg_bin(), "-y", "-loglevel", "error", "-sseof", "-0.5", "-i", str(video), "-frames:v", "1",
         "-vf", "scale='min(1280,iw)':-2", str(frame)], check=False)
    vol = run([ffmpeg_bin(), "-hide_banner", "-i", str(wav), "-af", "volumedetect", "-f", "null", "-"],
              check=False).stderr if audio else ""
    m = re.search(r"max_volume:\s*(-?[\d.]+) dB", vol)
    db = float(m.group(1)) if m else None
    print(json.dumps({"ok": True, "mic": mic, "frame": str(frame), "mic_max_volume_db": db,
                      "mic_silent": db is None or db < -60,
                      "audio_seconds": round(audio.frames / audio.sr, 2) if audio else 0,
                      "engine": choose_engine(global_config().get("record", {}).get("engine")),
                      "hint": "Look at the frame: wallpaper-only/black ⇒ Screen Recording permission missing. "
                              "mic_silent ⇒ Microphone permission missing or wrong mic."}, ensure_ascii=False, indent=2))


def _alive(pid) -> bool:
    if not pid:
        return False
    if IS_WIN:
        res = run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], check=False).stdout
        return str(pid) in res
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--session", help="session dir (default: ./.blurt/sessions/<timestamp>)")
    s.add_argument("--inbox", action="store_true", help="save to the default workspace (~/Blurt/recordings) instead of the project")
    s.add_argument("--engine", choices=["native", "tk", "ffmpeg"])
    s.add_argument("--region", help="x,y,w,h in screen points — skip the picker")
    s.add_argument("--last-region", action="store_true", help="reuse the last area without asking")
    s.add_argument("--countdown", type=int)
    s.add_argument("--screen", type=int, help="ffmpeg engine: screen index")
    s.add_argument("--mic", help="mic name substring or index (see `devices`)")
    s.add_argument("--no-mic", action="store_true")
    s.add_argument("--system-audio", action="store_true",
                   help="also record what the Mac plays (call voices, demo sound) as a second track; native engine, macOS 13+")
    s.add_argument("--fps", type=int)
    s.add_argument("--max-width", type=int)
    s.add_argument("--max-minutes", type=float, default=120)
    for c in ("stop", "pause", "resume", "restart", "marker", "snap", "discard", "status", "devices", "build", "inbox", "install-app"):
        sub.add_parser(c)
    t = sub.add_parser("test")
    t.add_argument("--seconds", type=float, default=3)
    t.add_argument("--screen", type=int)
    t.add_argument("--mic")
    t.add_argument("--out")
    a = p.parse_args()
    if a.cmd in ("stop", "pause", "resume", "restart", "marker", "snap", "discard"):
        return send(a.cmd)
    {"start": cmd_start, "status": cmd_status, "devices": cmd_devices, "build": cmd_build, "test": cmd_test,
     "inbox": cmd_inbox, "install-app": cmd_install_app}[a.cmd](a)


if __name__ == "__main__":
    main()
