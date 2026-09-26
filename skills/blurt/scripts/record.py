# /// script
# requires-python = ">=3.10"
# dependencies = ["sounddevice"]
# ///
"""Screen + microphone recorder (macOS & Windows) with a proper recording UI.

The user picks the area to record (drag / click a window / full screen), a 3-2-1 countdown runs, and a floating
control bar offers pause, marker, discard and stop — so they never have to come back to the chat to stop.
The control bar and the region border are never part of the recording.

Engines (auto-selected; override with --engine or ~/.blurt/config.json → record.engine):
  native   macOS: ScreenCaptureKit app (recorder/macos/BlurtRecorder.swift), built on first use with swiftc.
  tk       Windows (and macOS fallback): Tk picker + control bar, ffmpeg video, PortAudio mic.
  ffmpeg   headless full-screen capture, stop from chat only (no GUI available).

  record.py start [--session DIR] [--region x,y,w,h | --last-region] [--engine E] [--countdown 3]
                                        run in the background; exits when the user stops (prints DONE …)
  record.py stop | pause | resume | restart | discard     control the active recording from the chat
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
from _common import (BLURT_HOME, IS_MAC, IS_WIN, STATE_FILE, die, ffmpeg_bin, fix_tcl_env, fmt_ts,  # noqa: E402
                     global_config, load_json, new_session_dir, probe_duration, run, save_json, update_global_config)

VIRTUAL_MIC_HINTS = ("virtual", "blackhole", "loopback", "soundflower", "zoom", "teams", "oray", "vb-audio",
                     "voicemeeter", "stereo mix", "立体声混音", "aggregate", "聚集", "cable")
AUDIO_SR = 48000
SWIFT_SRC = Path(__file__).resolve().parent.parent / "recorder" / "macos" / "BlurtRecorder.swift"


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
    `gate()` False ⇒ samples are dropped (pause). Records the wall-clock time of the first sample."""

    def __init__(self, mic: dict, path: Path, gate=None):
        import sounddevice as sd
        self.path, self.q, self.first_wall, self.overflows, self.frames = path, queue.Queue(), None, 0, 0
        self.gate = gate or (lambda: True)
        self.sr = mic.get("samplerate") or AUDIO_SR
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

    def start(self):
        self.writer.start()
        self.stream.start()

    def stop(self):
        self.stream.stop()
        self.stream.close()
        self.q.put(None)
        self.writer.join()


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
    else:
        has_dda = "ddagrab" in run([ff, "-hide_banner", "-filters"], check=False).stdout
        if has_dda:
            cmd += ["-f", "lavfi", "-i", f"ddagrab=output_idx={screen or 0}:framerate={fps}:draw_mouse=1"]
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
INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.blurt.recorder</string>
<key>CFBundleName</key><string>Blurt</string>
<key>CFBundleDisplayName</key><string>Blurt 吐槽鸡</string>
<key>CFBundleExecutable</key><string>blurt-recorder</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Blurt records your voice while you narrate feedback.</string>
<key>NSScreenCaptureUsageDescription</key><string>Blurt records the screen area you select.</string>
</dict></plist>
"""


def native_binary(build: bool = True) -> Path | None:
    """The recorder lives inside ~/.blurt/Blurt.app so it can also be launched as a standalone app."""
    if not IS_MAC or not SWIFT_SRC.exists():
        return None
    remember_skill_dir()
    digest = hashlib.sha256(SWIFT_SRC.read_bytes() + INFO_PLIST.encode()).hexdigest()[:12]
    exe = APP_BUNDLE / "Contents" / "MacOS" / "blurt-recorder"
    stamp = APP_BUNDLE / "Contents" / "Resources" / "source.sha"
    if exe.exists() and stamp.exists() and stamp.read_text().strip() == digest:
        return exe
    if not build:
        return None
    swiftc = shutil.which("swiftc")
    if not swiftc:
        return None
    print("building native recorder (one-time, ~20s)…", file=sys.stderr, flush=True)
    tmp = BLURT_HOME / "build" / "blurt-recorder"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    if os.environ.get("BLURT_UNIVERSAL"):  # release builds: arm64 + x86_64 in one binary
        parts = []
        for arch in ("arm64", "x86_64"):
            out_arch = tmp.with_name(f"blurt-recorder-{arch}")
            r = run([swiftc, "-O", "-swift-version", "5", "-target", f"{arch}-apple-macos13.0", str(SWIFT_SRC), "-o", str(out_arch)],
                    check=False)
            if r.returncode:
                print(f"build failed for {arch}:\n{r.stderr[-1500:]}", file=sys.stderr)
                return None
            parts.append(str(out_arch))
        r = run(["lipo", "-create", *parts, "-output", str(tmp)], check=False)
    else:
        r = run([swiftc, "-O", "-swift-version", "5", str(SWIFT_SRC), "-o", str(tmp)], check=False)
    if r.returncode:
        print(f"native recorder build failed, falling back:\n{r.stderr[-1500:]}", file=sys.stderr)
        return None
    shutil.rmtree(APP_BUNDLE, ignore_errors=True)
    (APP_BUNDLE / "Contents" / "MacOS").mkdir(parents=True)
    (APP_BUNDLE / "Contents" / "Resources").mkdir(parents=True)
    shutil.move(str(tmp), exe)
    (APP_BUNDLE / "Contents" / "Info.plist").write_text(INFO_PLIST, encoding="utf-8")
    make_icns(APP_BUNDLE / "Contents" / "Resources" / "AppIcon.icns")
    make_menu_icon(APP_BUNDLE / "Contents" / "Resources")
    stamp.write_text(digest)          # before signing: the signature seals Resources/
    sign_app(APP_BUNDLE)
    ensure_app_installed(force=True)
    return exe


def remember_skill_dir() -> None:
    skill = str(Path(__file__).resolve().parent.parent)
    if global_config().get("skill_dir") != skill:
        update_global_config({"skill_dir": skill})


def ensure_app_installed(force: bool = False) -> Path | None:
    """Keep a double-clickable recorder where people look for apps — done automatically on first use / update.
    Opt out with ~/.blurt/config.json → {"record": {"install_app": false}}."""
    if global_config().get("record", {}).get("install_app") is False:
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
    """Menu-bar icon: the logo trimmed to its content, 18 pt tall (36 px @2x)."""
    if not ICON.exists():
        return
    tmp = BLURT_HOME / "build" / "menu.png"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    # crop to the logo's content box (transparent margins trimmed)
    run(["sips", "-c", "349", "425", "--cropOffset", "80", "47", str(ICON), "--out", str(tmp)], check=False)
    run(["sips", "-Z", "44", str(tmp), "--out", str(res / "MenuIcon@2x.png")], check=False)
    run(["sips", "-Z", "22", str(tmp), "--out", str(res / "MenuIcon.png")], check=False)


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
    out(f"DONE video={final} duration={fmt_ts(dur)} markers={n_markers} events={'events.jsonl' if events.exists() else '-'}")


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
    rec = TkRecorder(session, mic, a.fps or cfg.get("fps", 30), a.max_width or cfg.get("max_width", 2560), lang(),
                     a.countdown if a.countdown is not None else cfg.get("countdown", 3), last, region, cmd_file, out)
    result = rec.run()
    if result.get("event") == "stopped" and rec.region:
        result["region"] = rec.region
    return result


def run_headless(session: Path, a, cfg, cmd_file: Path) -> dict:
    mic = None if a.no_mic else pick_mic(a.mic or cfg.get("mic"))
    raw, wav, log_path = session / "video.mkv", session / "audio.wav", session / "ffmpeg.log"
    audio = MicRecorder(mic, wav) if mic else None
    if audio:
        audio.start()
    log = open(log_path, "w", encoding="utf-8")
    p = subprocess.Popen(headless_video_cmd(raw, a.screen, a.fps or cfg.get("fps", 30), a.max_width or cfg.get("max_width", 1920)),
                         stdin=subprocess.PIPE, stdout=log, stderr=log)
    chime("start")
    out({"event": "recording", "engine": "ffmpeg"})
    t0 = time.time()
    signal.signal(signal.SIGINT, lambda *_: cmd_file.write_text("stop"))
    discard = False
    while p.poll() is None:
        cmds = cmd_file.read_text(encoding="utf-8").split() if cmd_file.exists() else []
        cmd_file.unlink(missing_ok=True)
        if "stop" in cmds or "discard" in cmds or (a.max_minutes and time.time() - t0 > a.max_minutes * 60):
            discard = "discard" in cmds
            break
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
    dirs = [d for r in recording_roots() for d in r.glob("*/") if (d / "recording.mp4").exists()]
    for d in sorted(dirs, key=lambda x: x.name, reverse=True):
        meta = load_json(d / "meta.json", {}) or {}
        out = load_json(d / "items.json")
        rows.append({"session": str(d), "duration": meta.get("duration") or round(probe_duration(d / "recording.mp4"), 1),
                     "author": meta.get("author"), "processed": out is not None,
                     "reviewed": bool((out or {}).get("reviewed"))})
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
    s.add_argument("--fps", type=int)
    s.add_argument("--max-width", type=int)
    s.add_argument("--max-minutes", type=float, default=120)
    for c in ("stop", "pause", "resume", "restart", "marker", "discard", "status", "devices", "build", "inbox", "install-app"):
        sub.add_parser(c)
    t = sub.add_parser("test")
    t.add_argument("--seconds", type=float, default=3)
    t.add_argument("--screen", type=int)
    t.add_argument("--mic")
    t.add_argument("--out")
    a = p.parse_args()
    if a.cmd in ("stop", "pause", "resume", "restart", "marker", "discard"):
        return send(a.cmd)
    {"start": cmd_start, "status": cmd_status, "devices": cmd_devices, "build": cmd_build, "test": cmd_test,
     "inbox": cmd_inbox, "install-app": cmd_install_app}[a.cmd](a)


if __name__ == "__main__":
    main()
