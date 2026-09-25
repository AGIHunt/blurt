# /// script
# requires-python = ">=3.10"
# dependencies = ["sounddevice"]
# ///
"""Screen + microphone recorder (macOS & Windows).

Video: ffmpeg (macOS avfoundation, Windows ddagrab/gdigrab), video only.
Audio: PortAudio via `sounddevice`, written straight to WAV. (ffmpeg's own mic capture drops ~10% of samples on
macOS; PortAudio doesn't.) Both streams are wall-clock stamped and muxed in sync on stop.

  record.py devices                     list screens / microphones (JSON)
  record.py test [--seconds 3]          short capture -> checks permissions, mic level, returns a screen frame
  record.py start [--session DIR] ...   record until `record.py stop` (run this in the background)
  record.py stop                        stop the active recording gracefully
  record.py status                      show the active recording, if any
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import wave
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (IS_MAC, IS_WIN, STATE_FILE, die, ffmpeg_bin, fmt_ts, global_config, load_json,  # noqa: E402
                     new_session_dir, probe_duration, run, save_json)

VIRTUAL_MIC_HINTS = ("virtual", "blackhole", "loopback", "soundflower", "zoom", "teams", "oray", "vb-audio",
                     "voicemeeter", "stereo mix", "立体声混音", "aggregate", "聚集", "cable")
AUDIO_SR = 48000


# ---------------------------------------------------------------- devices
def list_screens() -> list[dict]:
    ff = ffmpeg_bin()
    if IS_MAC:
        out = run([ff, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""], check=False).stderr
        screens, section = [], None
        for line in out.splitlines():
            if "video devices" in line:
                section = "v"
            elif "audio devices" in line:
                section = "a"
            m = re.search(r"\]\s\[(\d+)\]\s(.+)$", line)
            if m and section == "v" and "capture screen" in m.group(2).lower():
                screens.append({"index": int(m.group(1)), "name": m.group(2).strip()})
        return screens
    return [{"index": 0, "name": "primary monitor (ddagrab output_idx / gdigrab desktop)"}]


def list_mics() -> list[dict]:
    import sounddevice as sd
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
            continue  # skip duplicate DirectSound/WDM-KS entries
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


# ---------------------------------------------------------------- audio
class MicRecorder:
    """Streams the mic to a WAV file; records the wall-clock time of the first captured sample."""

    def __init__(self, mic: dict, path: Path):
        import sounddevice as sd
        self.path, self.q, self.first_wall, self.overflows, self.frames = path, queue.Queue(), None, 0, 0
        self.sr = mic.get("samplerate") or AUDIO_SR
        self.stream = sd.RawInputStream(samplerate=self.sr, channels=1, dtype="int16", device=mic["index"],
                                        callback=self._cb)
        self.writer = threading.Thread(target=self._write, daemon=True)

    def _cb(self, data, frames, t, status):
        if self.first_wall is None:
            # wall time of the first sample = now - age of this buffer
            self.first_wall = time.time() - max(0.0, t.currentTime - t.inputBufferAdcTime)
        if status.input_overflow:
            self.overflows += 1
        self.q.put(bytes(data))

    def _write(self):
        with wave.open(str(self.path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.sr)
            while (chunk := self.q.get()) is not None:
                w.writeframes(chunk)
                self.frames += len(chunk) // 2

    def start(self):
        self.writer.start()
        self.stream.start()

    def stop(self):
        self.stream.stop()
        self.stream.close()
        self.q.put(None)
        self.writer.join()


# ---------------------------------------------------------------- video
def pick_encoder(ff: str) -> list[str]:
    candidates = (["h264_videotoolbox"] if IS_MAC else ["h264_nvenc", "h264_qsv", "h264_amf"]) + ["libx264"]
    for enc in candidates:
        if enc == "libx264":
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-tune", "zerolatency"]
        test = run([ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=640x360:d=0.2",
                    "-c:v", enc, "-f", "null", "-"], check=False)
        if test.returncode == 0:
            if enc == "h264_videotoolbox":
                return ["-c:v", enc, "-b:v", "2500k", "-maxrate", "4M", "-bufsize", "8M", "-realtime", "1"]
            if enc == "h264_nvenc":
                return ["-c:v", enc, "-preset", "p4", "-cq", "30"]
            return ["-c:v", enc, "-b:v", "2500k"]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30"]


def video_cmd(out: Path, screen: int | None, fps: int, max_width: int, grabber: str) -> list[str]:
    ff = ffmpeg_bin()
    scale = f"scale='min({max_width},iw)':-2"
    # info loglevel: we parse "start: <epoch>" (wall clock of the first frame) for A/V sync
    cmd = [ff, "-hide_banner", "-nostats", "-loglevel", "info", "-y"]
    wall = ["-use_wallclock_as_timestamps", "1"]
    if os.environ.get("BLURT_FAKE_SCREEN"):  # dev/CI: synthetic screen, exercises the plumbing
        cmd += [*wall, "-re", "-f", "lavfi", "-i", f"testsrc2=s=1280x720:r={fps}"]
        vf = "format=yuv420p"
    elif IS_MAC:
        if screen is None:
            screens = list_screens()
            if not screens:
                die("No capturable screen found (Screen Recording permission for the app hosting this agent?)")
            screen = screens[0]["index"]
        cmd += [*wall, "-thread_queue_size", "1024", "-f", "avfoundation", "-capture_cursor", "1",
                "-capture_mouse_clicks", "1", "-framerate", str(fps), "-i", f"{screen}:none"]
        vf = f"{scale},format=yuv420p"
    elif grabber == "ddagrab":
        cmd += [*wall, "-f", "lavfi", "-i", f"ddagrab=output_idx={screen or 0}:framerate={fps}:draw_mouse=1"]
        vf = f"hwdownload,format=bgra,{scale},format=yuv420p"
    else:
        cmd += [*wall, "-thread_queue_size", "1024", "-f", "gdigrab", "-framerate", str(fps), "-draw_mouse", "1",
                "-i", "desktop"]
        vf = f"{scale},format=yuv420p"
    return cmd + ["-vf", vf, *pick_encoder(ff), "-g", str(fps * 2), str(out)]


def first_frame_wall(log: Path) -> float | None:
    try:
        m = re.search(r"Duration: .*?start: (\d{9,}\.\d+)", log.read_text(encoding="utf-8", errors="replace"))
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None


def mux(video: Path, audio: Path | None, offset: float, out: Path) -> None:
    """offset = audio_start - video_start (seconds). Positive: audio began later -> delay it."""
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
    cmd += ["-movflags", "+faststart", str(out)]
    r = run(cmd, check=False)
    if r.returncode:
        die(f"mux failed: {r.stderr[-800:]}")


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


def notify(title: str, body: str) -> None:
    try:
        if IS_MAC:
            subprocess.Popen(["osascript", "-e", f"display notification {json.dumps(body, ensure_ascii=False)} "
                                                 f"with title {json.dumps(title, ensure_ascii=False)}"])
    except Exception:
        pass


# ---------------------------------------------------------------- core
class Recording:
    def __init__(self, session: Path, screen, mic, fps, max_width, grabber):
        self.session = session
        self.raw_video = session / "video.mkv"  # mkv survives crashes
        self.wav = session / "audio.wav"
        self.log_path = session / "ffmpeg.log"
        self.cmd = video_cmd(self.raw_video, screen, fps, max_width, grabber)
        self.mic = mic
        self.mic_rec = MicRecorder(mic, self.wav) if mic else None

    def start(self):
        if self.mic_rec:
            self.mic_rec.start()
        self.log = open(self.log_path, "w", encoding="utf-8")
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=self.log, stderr=self.log)

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> dict:
        if self.proc.poll() is None:
            try:
                self.proc.stdin.write(b"q")
                self.proc.stdin.flush()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                self.proc.wait(timeout=10)
        if self.mic_rec:
            self.mic_rec.stop()
        self.log.close()
        if not self.raw_video.exists() or self.raw_video.stat().st_size == 0:
            tail = self.log_path.read_text(encoding="utf-8", errors="replace")[-2000:]
            die(f"Recording failed (ffmpeg exited {self.proc.returncode}). Log tail:\n{tail}")
        v0 = first_frame_wall(self.log_path)
        a0 = self.mic_rec.first_wall if self.mic_rec else None
        offset = (a0 - v0) if (a0 and v0) else 0.0
        return {"video_start_wall": v0, "audio_start_wall": a0, "av_offset": round(offset, 3),
                "audio_overflows": self.mic_rec.overflows if self.mic_rec else None,
                "audio_seconds": round(self.mic_rec.frames / self.mic_rec.sr, 2) if self.mic_rec else 0}


def settings(a) -> tuple:
    cfg = global_config().get("record", {})
    mic = None if getattr(a, "no_mic", False) else pick_mic(a.mic or cfg.get("mic"))
    screen = a.screen if a.screen is not None else cfg.get("screen")
    grabber = getattr(a, "grabber", None) or cfg.get("grabber") or "ddagrab"
    if IS_WIN and grabber == "ddagrab" and "ddagrab" not in run([ffmpeg_bin(), "-hide_banner", "-filters"],
                                                                check=False).stdout:
        grabber = "gdigrab"
    return screen, mic, grabber, cfg


def cmd_devices(_a) -> None:
    print(json.dumps({"screens": list_screens(), "mics": list_mics()}, ensure_ascii=False, indent=2))


def cmd_test(a) -> None:
    out_dir = Path(a.out or Path.cwd() / ".blurt" / "test")
    out_dir.mkdir(parents=True, exist_ok=True)
    screen, mic, grabber, _ = settings(a)
    rec = Recording(out_dir, screen, mic, 15, 1920, grabber)
    rec.start()
    t0 = time.time()
    while time.time() - t0 < a.seconds + 15:
        if not rec.alive() or (time.time() - t0 > a.seconds and rec.raw_video.exists()
                               and rec.raw_video.stat().st_size > 0):
            break
        time.sleep(0.2)
    if not rec.raw_video.exists() or rec.raw_video.stat().st_size == 0:
        rec.proc.kill()
        if rec.mic_rec:
            rec.mic_rec.stop()
        print(json.dumps({"ok": False, "mic": mic, "error": "ffmpeg produced no video. On macOS this almost always "
                          "means Screen Recording permission is missing for the app hosting this agent: System "
                          "Settings → Privacy & Security → Screen & System Audio Recording → enable it, then restart "
                          "that app."}, ensure_ascii=False, indent=2))
        return
    info = rec.stop()
    video = out_dir / "test.mp4"
    mux(rec.raw_video, rec.wav, info["av_offset"], video)
    frame = out_dir / "test-frame.jpg"
    run([ffmpeg_bin(), "-y", "-loglevel", "error", "-sseof", "-0.5", "-i", str(video), "-frames:v", "1", str(frame)],
        check=False)
    vol = run([ffmpeg_bin(), "-hide_banner", "-i", str(rec.wav), "-af", "volumedetect", "-f", "null", "-"],
              check=False).stderr if mic else ""
    m = re.search(r"max_volume:\s*(-?[\d.]+) dB", vol)
    db = float(m.group(1)) if m else None
    print(json.dumps({
        "ok": True, "mic": mic, "frame": str(frame), "mic_max_volume_db": db,
        "mic_silent": db is None or db < -60, **info,
        "hint": "Look at the frame: wallpaper-only/black ⇒ Screen Recording permission missing. mic_silent ⇒ "
                "Microphone permission missing or wrong mic. On macOS grant both to the app hosting this agent "
                "(System Settings → Privacy & Security), then restart that app."}, ensure_ascii=False, indent=2))


def cmd_start(a) -> None:
    state = load_json(STATE_FILE)
    if state and _alive(state.get("pid")):
        die(f"A recording is already running: {state['session']}. Run `record.py stop` first.")
    session = (Path(a.session) if a.session else new_session_dir()).resolve()
    session.mkdir(parents=True, exist_ok=True)
    screen, mic, grabber, cfg = settings(a)
    rec = Recording(session, screen, mic, a.fps or cfg.get("fps", 30), a.max_width or cfg.get("max_width", 1920),
                    grabber)
    stop_flag = session / ".stop"
    stop_flag.unlink(missing_ok=True)
    rec.start()
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    save_json(STATE_FILE, {"pid": os.getpid(), "session": str(session), "started_at": started})
    save_json(session / "meta.json", {"started_at": started, "mic": mic, "cmd": rec.cmd})
    print(f"RECORDING session={session}", flush=True)
    print(f"mic={mic['name'] if mic else 'none'}  — stop with: record.py stop", flush=True)
    chime("start")
    notify("blurt 🐔", "Recording… / 正在录制")

    stopped_by = "ffmpeg_exit"
    t0 = time.time()
    signal.signal(signal.SIGINT, lambda *_: stop_flag.touch())
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, lambda *_: stop_flag.touch())
    try:
        while rec.alive():
            if stop_flag.exists():
                stopped_by = "stop"
                break
            if a.max_minutes and time.time() - t0 > a.max_minutes * 60:
                stopped_by = "max_duration"
                break
            time.sleep(0.3)
        info = rec.stop()
    finally:
        STATE_FILE.unlink(missing_ok=True)
        stop_flag.unlink(missing_ok=True)
    chime("stop")
    final = session / "recording.mp4"
    mux(rec.raw_video, rec.wav if mic else None, info["av_offset"], final)
    rec.raw_video.unlink(missing_ok=True)
    dur = probe_duration(final)
    meta = load_json(session / "meta.json", {})
    meta.update({"stopped_by": stopped_by, "video": final.name, "duration": dur, **info})
    save_json(session / "meta.json", meta)
    print(f"DONE video={final} duration={fmt_ts(dur)} stopped_by={stopped_by} av_offset={info['av_offset']}s",
          flush=True)


def cmd_stop(_a) -> None:
    state = load_json(STATE_FILE)
    if not state:
        die("No active recording.")
    session = Path(state["session"])
    (session / ".stop").touch()
    for _ in range(200):
        if not STATE_FILE.exists():
            break
        time.sleep(0.3)
    print(json.dumps({"stopped": True, "session": str(session)}))


def cmd_status(_a) -> None:
    state = load_json(STATE_FILE)
    if state and not _alive(state.get("pid")):
        STATE_FILE.unlink(missing_ok=True)
        state = None
    print(json.dumps(state or {"recording": False}, ensure_ascii=False))


def _alive(pid) -> bool:
    if not pid:
        return False
    if IS_WIN:
        out = run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], check=False).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("devices")
    t = sub.add_parser("test")
    t.add_argument("--seconds", type=float, default=3)
    t.add_argument("--screen", type=int)
    t.add_argument("--mic")
    t.add_argument("--out")
    s = sub.add_parser("start")
    s.add_argument("--session", help="session dir (default: ./.blurt/sessions/<timestamp>)")
    s.add_argument("--screen", type=int, help="macOS: avfoundation screen index; Windows: monitor index (ddagrab)")
    s.add_argument("--mic", help="mic index or name substring (see `devices`)")
    s.add_argument("--no-mic", action="store_true")
    s.add_argument("--fps", type=int)
    s.add_argument("--max-width", type=int)
    s.add_argument("--max-minutes", type=float, default=120)
    s.add_argument("--grabber", choices=["ddagrab", "gdigrab"], help="Windows only")
    sub.add_parser("stop")
    sub.add_parser("status")
    a = p.parse_args()
    {"devices": cmd_devices, "test": cmd_test, "start": cmd_start, "stop": cmd_stop, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    main()
