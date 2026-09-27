"""Tk-based recorder UI: region picker, 3-2-1 countdown, floating control bar (pause / marker / discard / stop).

Used on Windows (primary) and on macOS when the native Swift recorder can't be built. Video is captured with
ffmpeg (Windows: gdigrab region; macOS: avfoundation + crop), audio with PortAudio (MicRecorder). Pause stops the
current video segment and drops audio; segments are aligned by wall clock and joined on stop.

The control bar is excluded from capture on Windows 10 2004+ (SetWindowDisplayAffinity) and always sits outside
the recorded region when there is room.
"""
from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import IS_MAC, IS_WIN, ffmpeg_bin, fix_tcl_env, run  # noqa: E402

ACCENT = "#ff5c3d"
AMBER = "#ffc23d"
BG = "#17171a"
BG2 = "#26262b"
FG = "#f4f4f5"
MUTED = "#9a9aa1"


def zh(lang: str) -> bool:
    return lang.startswith("zh")


def enable_dpi_awareness() -> None:
    if IS_WIN:
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            try:
                import ctypes
                ctypes.windll.user32.SetProcessDPIAware()
            except Exception:
                pass


def exclude_from_capture(win) -> None:
    """Hide a Tk window from screen capture (Windows 10 2004+)."""
    if not IS_WIN:
        return
    try:
        import ctypes
        win.update_idletasks()
        hwnd = ctypes.windll.user32.GetParent(win.winfo_id()) or win.winfo_id()
        ctypes.windll.user32.SetWindowDisplayAffinity(hwnd, 0x11)  # WDA_EXCLUDEFROMCAPTURE
    except Exception:
        pass


def mac_backing_scale() -> float:
    """Ratio of captured pixels to Tk points on the main display."""
    try:
        from record import list_screens  # noqa: F401
        out = run(["system_profiler", "SPDisplaysDataType"], check=False).stdout
        if "Retina" in out or "UI Looks like" in out:
            return 2.0
    except Exception:
        pass
    return 1.0


def virtual_screen(root) -> tuple[int, int, int, int]:
    if IS_WIN:
        try:
            import ctypes
            m = ctypes.windll.user32.GetSystemMetrics
            return m(76), m(77), m(78), m(79)  # SM_X/YVIRTUALSCREEN, SM_CX/CYVIRTUALSCREEN
        except Exception:
            pass
    return 0, 0, root.winfo_screenwidth(), root.winfo_screenheight()


# ------------------------------------------------------------------ picker
class Picker:
    """Full-screen dim overlay; drag to select, Enter/Space to start, F full screen, L last area, Esc cancel."""

    HOLE = "#010203"

    def __init__(self, root, lang: str, last: list | None, done):
        import tkinter as tk
        self.tk, self.root, self.lang, self.last, self.done = tk, root, lang, last, done
        self.vx, self.vy, self.vw, self.vh = virtual_screen(root)
        w = self.win = tk.Toplevel(root)
        w.overrideredirect(True)
        w.geometry(f"{self.vw}x{self.vh}+{self.vx}+{self.vy}")
        w.attributes("-topmost", True)
        w.configure(bg="black", cursor="crosshair")
        if IS_WIN:
            w.attributes("-alpha", 0.55)
            w.attributes("-transparentcolor", self.HOLE)  # the selection becomes a real hole
        else:
            w.attributes("-alpha", 0.35)
        self.c = tk.Canvas(w, bg="black", highlightthickness=0, bd=0)
        self.c.pack(fill="both", expand=True)
        self.sel: list[int] | None = None
        self.start = None
        self.mode = None
        self.c.bind("<ButtonPress-1>", self.down)
        self.c.bind("<B1-Motion>", self.drag)
        self.c.bind("<ButtonRelease-1>", self.up)
        self.c.bind("<Double-Button-1>", lambda e: self.finish(True))
        for k in ("<Return>", "<KP_Enter>", "<space>"):
            w.bind(k, lambda e: self.finish(True))
        w.bind("<Escape>", lambda e: self.finish(False))
        w.bind("<f>", lambda e: self.full())
        w.bind("<l>", lambda e: self.use_last())
        self.toolbar = None
        self.redraw()
        w.focus_force()
        w.after(50, w.focus_force)

    def t(self, a, b):
        return a if zh(self.lang) else b

    def full(self):
        self.sel = [0, 0, self.vw, self.vh]
        self.redraw()

    def use_last(self):
        if self.last:
            x, y, w, h = self.last
            self.sel = [x - self.vx, y - self.vy, w, h]
            self.redraw()

    def down(self, e):
        if self.sel:
            x, y, w, h = self.sel
            if x + 8 < e.x < x + w - 8 and y + 8 < e.y < y + h - 8:
                self.mode, self.start = "move", (e.x, e.y, x, y)
                return
        self.mode, self.start = "new", (e.x, e.y)

    def drag(self, e):
        if self.mode == "new":
            x0, y0 = self.start
            if abs(e.x - x0) + abs(e.y - y0) > 4:
                self.sel = [min(x0, e.x), min(y0, e.y), abs(e.x - x0), abs(e.y - y0)]
        elif self.mode == "move":
            sx, sy, x, y = self.start
            w, h = self.sel[2:]
            self.sel = [max(0, min(self.vw - w, x + e.x - sx)), max(0, min(self.vh - h, y + e.y - sy)), w, h]
        self.redraw()

    def up(self, _e):
        if self.sel and (self.sel[2] < 16 or self.sel[3] < 16):
            self.sel = None
        self.mode = None
        self.redraw()

    def redraw(self):
        c = self.c
        c.delete("all")
        hint = self.t("拖拽框选录制区域 · F 全屏 · L 上次区域 · Enter 开始 · Esc 取消",
                      "Drag to select an area · F full screen · L last area · Enter start · Esc cancel")
        c.create_text(self.vw // 2, 40, text=hint, fill="white", font=("Segoe UI", 13, "bold"))
        if self.toolbar:
            self.toolbar.destroy()
            self.toolbar = None
        if not self.sel:
            return
        x, y, w, h = self.sel
        if IS_WIN:
            c.create_rectangle(x, y, x + w, y + h, fill=self.HOLE, outline="")
        c.create_rectangle(x - 1, y - 1, x + w + 1, y + h + 1, outline="white", width=2)
        for hx, hy in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
            c.create_rectangle(hx - 4, hy - 4, hx + 4, hy + 4, fill="white", outline=ACCENT)
        c.create_text(x + 4, y - 14, anchor="w", text=f"{w} × {h}", fill="white", font=("Segoe UI", 10, "bold"))
        self.place_toolbar()

    def place_toolbar(self):
        tk = self.tk
        f = self.toolbar = tk.Frame(self.win, bg=BG, padx=6, pady=6)
        mk = lambda txt, cmd, bg=BG2: tk.Button(f, text=txt, command=cmd, bg=bg, fg="white", activebackground=bg,  # noqa: E731
                                                 activeforeground="white", relief="flat", bd=0, padx=14, pady=6,
                                                 font=("Segoe UI", 10, "bold"), cursor="hand2")
        mk(self.t("全屏", "Full screen"), self.full).pack(side="left", padx=3)
        if self.last:
            mk(self.t("上次区域", "Last area"), self.use_last).pack(side="left", padx=3)
        mk(self.t("取消", "Cancel"), lambda: self.finish(False)).pack(side="left", padx=3)
        mk("● " + self.t("开始录制", "Start recording"), lambda: self.finish(True), ACCENT).pack(side="left", padx=3)
        f.update_idletasks()
        x, y, w, h = self.sel
        fx = max(8, min(x + w // 2 - f.winfo_reqwidth() // 2, self.vw - f.winfo_reqwidth() - 8))
        fy = y + h + 12 if y + h + 60 < self.vh else max(8, y - 56)
        f.place(x=fx, y=fy)

    def finish(self, ok: bool):
        sel = self.sel
        self.win.destroy()
        if ok and sel:
            x, y, w, h = sel
            self.done([x + self.vx, y + self.vy, w // 2 * 2, h // 2 * 2])
        else:
            self.done(None)


# ------------------------------------------------------------------ recorder
class TkRecorder:
    def __init__(self, session: Path, mic: dict | None, fps: int, max_width: int, lang: str, countdown: int,
                 last_region: list | None, region: list | None, command_file: Path, on_event):
        self.session, self.mic, self.fps, self.max_width = session, mic, fps, max_width
        self.lang, self.countdown_n, self.last_region, self.fixed_region = lang, countdown, last_region, region
        self.command_file, self.on_event = command_file, on_event
        self.region: list[int] | None = None
        self.segments: list[dict] = []
        self.proc = None
        self.audio = None
        self.paused = False
        self.elapsed_before = 0.0
        self.seg_started = None
        self.events = []
        self.result = None

    def t(self, a, b):
        return a if zh(self.lang) else b

    def elapsed(self) -> float:
        return self.elapsed_before + ((time.time() - self.seg_started) if self.seg_started and not self.paused else 0)

    def log(self, type_: str, **kw):
        self.events.append({"t": round(self.elapsed(), 3), "type": type_, **kw})

    # --- ui
    def run(self) -> dict:
        fix_tcl_env()
        import tkinter as tk
        enable_dpi_awareness()
        self.root = tk.Tk()
        self.root.withdraw()
        self.on_event({"event": "ready", "engine": "tk"})
        if self.fixed_region:
            self.root.after(10, lambda: self.selected(self.fixed_region))
        else:
            Picker(self.root, self.lang, self.last_region, self.selected)
        self.root.after(300, self.poll_commands)
        self.start_hotkeys()
        self.root.mainloop()
        return self.result or {"event": "cancelled"}

    def selected(self, region):
        if not region:
            self.result = {"event": "cancelled"}
            self.root.quit()
            return
        self.region = region
        self.on_event({"event": "selected", "region": region})
        self.countdown(self.countdown_n)

    def countdown(self, n):
        import tkinter as tk
        if n <= 0:
            self.begin()
            return
        x, y, w, h = self.region
        cw = tk.Toplevel(self.root)
        cw.overrideredirect(True)
        cw.attributes("-topmost", True)
        size = 150
        cw.geometry(f"{size + 120}x{size + 20}+{x + w // 2 - (size + 120) // 2}+{y + h // 2 - size // 2}")
        cw.configure(bg=BG)
        lbl = tk.Label(cw, text=str(n), fg="white", bg=BG, font=("Segoe UI", 64, "bold"))
        lbl.pack(expand=True, fill="both")
        tk.Label(cw, text=self.t("准备，开喷", "Get ready"), fg=MUTED, bg=BG, font=("Segoe UI", 10)).pack()
        hint = self.t("Alt+Shift+P 暂停/继续 · Alt+Shift+S 完成 · 点一下跳过", "Alt+Shift+P pause · Alt+Shift+S finish · click to skip")
        tk.Label(cw, text=hint if IS_WIN else self.t("点一下跳过", "click to skip"), fg=MUTED, bg=BG,
                 font=("Segoe UI", 8), wraplength=size + 120).pack(pady=(2, 10))

        state = {"done": False}

        def finish():
            if state["done"]:
                return
            state["done"] = True
            cw.destroy()
            self.root.after(120, self.begin)
        for wdg in (cw, lbl):
            wdg.bind("<Button-1>", lambda e: finish())

        def tick(k):
            if state["done"]:
                return
            if k == 0:
                finish()
                return
            lbl.config(text=str(k))
            self.on_event({"event": "countdown", "n": k})
            self.root.after(1000, lambda: tick(k - 1))
        tick(n)

    def begin(self):
        self.show_chrome()
        if self.mic:
            from record import MicRecorder
            self.audio = MicRecorder(self.mic, self.session / "audio.wav", gate=lambda: not self.paused)
            self.audio.start()
        self.start_segment()
        self.on_event({"event": "recording"})
        self.gen = getattr(self, "gen", 0) + 1
        self.root.after(200, self.tick, self.gen)

    def show_chrome(self):
        import tkinter as tk
        x, y, w, h = self.region
        # border just outside the region (never inside the captured pixels)
        self.borders = []
        for gx, gy, gw, gh in ((x - 3, y - 3, w + 6, 3), (x - 3, y + h, w + 6, 3), (x - 3, y, 3, h), (x + w, y, 3, h)):
            b = tk.Toplevel(self.root)
            b.overrideredirect(True)
            b.attributes("-topmost", True)
            b.configure(bg=ACCENT)
            b.geometry(f"{gw}x{gh}+{gx}+{gy}")
            exclude_from_capture(b)
            self.borders.append(b)
        hud = self.hud = tk.Toplevel(self.root)
        hud.overrideredirect(True)
        hud.attributes("-topmost", True)
        hud.configure(bg=BG)
        row = tk.Frame(hud, bg=BG, padx=10, pady=6)
        row.pack()
        self.dot = tk.Label(row, text="●", fg="#ff3b30", bg=BG, font=("Segoe UI", 12))
        self.dot.pack(side="left")
        self.clock = tk.Label(row, text="00:00", fg=FG, bg=BG, font=("Consolas" if IS_WIN else "Menlo", 13, "bold"), width=6)
        self.clock.pack(side="left", padx=(4, 8))
        mk = lambda txt, cmd, tip, bg=BG2: tk.Button(row, text=txt, command=cmd, bg=bg, fg="white", activebackground=bg,  # noqa: E731
                                                      activeforeground="white", relief="flat", bd=0, width=3,
                                                      font=("Segoe UI Symbol" if IS_WIN else "Helvetica", 11, "bold"),
                                                      cursor="hand2")
        self.pause_btn = mk("⏸", self.toggle_pause, "pause")
        self.pause_btn.pack(side="left", padx=2)
        mk("↺", self.redo, "restart").pack(side="left", padx=2)
        done = mk("■ " + self.t("完成", "Finish"), self.stop, "stop", "#e0342b")
        done.config(width=0, padx=10)
        done.pack(side="left", padx=(4, 0))
        # drag to move
        row.bind("<ButtonPress-1>", lambda e: setattr(self, "_drag", (e.x_root - hud.winfo_x(), e.y_root - hud.winfo_y())))
        row.bind("<B1-Motion>", lambda e: hud.geometry(f"+{e.x_root - self._drag[0]}+{e.y_root - self._drag[1]}"))
        hud.update_idletasks()
        hw, hh = hud.winfo_reqwidth(), hud.winfo_reqheight()
        vx, vy, vw, vh = virtual_screen(self.root)
        hx = max(vx + 8, min(x + w // 2 - hw // 2, vx + vw - hw - 8))
        hy = y + h + 14 if y + h + 14 + hh < vy + vh - 40 else (y - hh - 14 if y - hh - 14 > vy else y + h - hh - 16)
        hud.geometry(f"+{hx}+{hy}")
        exclude_from_capture(hud)

    def tick(self, gen=0):
        if self.result or gen != getattr(self, "gen", 0):
            return
        s = int(self.elapsed())
        self.clock.config(text=f"{s // 60:02d}:{s % 60:02d}" if s < 3600 else f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}")
        self.dot.config(fg=AMBER if self.paused else ("#ff3b30" if int(time.time() * 2) % 2 else "#7a1f1a"))
        self.root.after(250, self.tick, gen)

    # --- capture
    def video_cmd(self, out: Path) -> list[str]:
        ff = ffmpeg_bin()
        x, y, w, h = self.region
        scale = f"scale='min({self.max_width},iw)':-2,format=yuv420p"
        cmd = [ff, "-hide_banner", "-nostats", "-loglevel", "info", "-y", "-use_wallclock_as_timestamps", "1"]
        if os.environ.get("BLURT_FAKE_SCREEN"):
            cmd += ["-re", "-f", "lavfi", "-i", f"testsrc2=s={w}x{h}:r={self.fps}"]
            vf = "format=yuv420p"
        elif IS_WIN:
            cmd += ["-thread_queue_size", "1024", "-f", "gdigrab", "-framerate", str(self.fps), "-draw_mouse", "1",
                    "-offset_x", str(x), "-offset_y", str(y), "-video_size", f"{w}x{h}", "-i", "desktop"]
            vf = scale
        else:
            from record import list_screens
            screen = list_screens()[0]["index"]
            sf = mac_backing_scale()  # avfoundation delivers physical (Retina) pixels
            cmd += ["-thread_queue_size", "1024", "-f", "avfoundation", "-capture_cursor", "1", "-capture_mouse_clicks", "1",
                    "-framerate", str(self.fps), "-i", f"{screen}:none"]
            vf = f"crop={int(w * sf)}:{int(h * sf)}:{int(x * sf)}:{int(y * sf)},{scale}"
        from record import pick_encoder
        return cmd + ["-vf", vf, *pick_encoder(ff), "-g", str(self.fps * 2), str(out)]

    def start_segment(self):
        i = len(self.segments)
        out = self.session / f"seg{i:02d}.mkv"
        log = self.session / f"seg{i:02d}.log"
        fh = open(log, "w", encoding="utf-8")
        seg = {"video": out, "log": log, "fh": fh, "audio_from": self.audio.frames if self.audio else 0,
               "wall_start": time.time()}
        seg["proc"] = subprocess.Popen(self.video_cmd(out), stdin=subprocess.PIPE, stdout=fh, stderr=fh)
        self.segments.append(seg)
        self.seg_started = time.time()

    def end_segment(self):
        seg = self.segments[-1]
        p = seg["proc"]
        if p.poll() is None:
            try:
                p.stdin.write(b"q")
                p.stdin.flush()
            except Exception:
                pass
            try:
                p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                p.terminate()
                p.wait(timeout=10)
        seg["fh"].close()
        seg["audio_to"] = self.audio.frames if self.audio else 0
        seg["wall_end"] = time.time()
        self.elapsed_before += time.time() - self.seg_started
        self.seg_started = None

    # --- controls
    def toggle_pause(self):
        if not self.segments or self.result:
            return
        if self.paused:
            self.paused = False
            self.start_segment()
            self.log("resume")
            self.pause_btn.config(text="⏸")
            self.on_event({"event": "resumed", "t": round(self.elapsed(), 2)})
        else:
            self.log("pause")
            self.end_segment()
            self.paused = True
            self.pause_btn.config(text="▶")
            self.on_event({"event": "paused", "t": round(self.elapsed(), 2)})

    def marker(self):
        if self.segments and not self.paused:
            self.log("marker")
            self.on_event({"event": "marker", "t": round(self.elapsed(), 2)})

    def redo(self):
        """Restart (same area, fresh take) / keep recording / discard — one button, one question."""
        from tkinter import messagebox
        was_paused = self.paused
        if not was_paused:
            self.toggle_pause()
        ans = messagebox.askyesnocancel(
            "blurt", self.t("这段不满意？\n\n是：重新录制（删掉刚才的内容，同一区域重新开始）\n否：放弃并退出\n取消：继续录制",
                            "Not happy with this take?\n\nYes: restart in the same area\nNo: discard and quit\nCancel: keep recording"),
            parent=self.hud)
        if ans is True:
            self.restart()
        elif ans is False:
            self.stop(discard=True)
        elif not was_paused:
            self.toggle_pause()

    def restart(self):
        if not self.paused and self.segments:
            self.end_segment()
        if self.audio:
            self.audio.stop()
        for w in [self.hud, *self.borders]:
            w.destroy()
        for seg in self.segments:
            for f in (seg["video"], seg["log"]):
                Path(f).unlink(missing_ok=True)
        (self.session / "audio.wav").unlink(missing_ok=True)
        self.segments, self.audio, self.paused, self.elapsed_before, self.seg_started, self.events = [], None, False, 0.0, None, []
        self.on_event({"event": "restarting"})
        self.countdown(self.countdown_n)

    def discard(self):
        self.stop(discard=True)

    def stop(self, discard: bool = False):
        if self.result or not self.segments:
            if not self.segments:
                self.result = {"event": "cancelled"}
                self.root.quit()
            return
        if not self.paused:
            self.log("stop")
            self.end_segment()
        if self.audio:
            self.audio.stop()
        for w in [self.hud, *self.borders]:
            w.destroy()
        self.result = {"event": "cancelled", "reason": "discarded"} if discard else self.finalize()
        self.root.quit()

    def finalize(self) -> dict:
        """Join segments; align each segment's audio slice to its first video frame by wall clock."""
        from record import first_frame_wall
        parts = []
        sr = self.audio.sr if self.audio else 48000
        a0 = self.audio.first_wall if self.audio else None
        for i, seg in enumerate(self.segments):
            if not seg["video"].exists() or seg["video"].stat().st_size == 0:
                continue
            v0 = first_frame_wall(seg["log"]) or seg["wall_start"]
            part = self.session / f"part{i:02d}.mp4"
            cmd = [ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", str(seg["video"])]
            n = seg["audio_to"] - seg["audio_from"]
            if self.audio and a0 and n > 0:
                # unpaused audio is contiguous; this slice started (wall) when the gate reopened
                aw = a0 if i == 0 else seg["wall_start"]
                lead = v0 - aw                       # >0: audio began before the first video frame
                ss = seg["audio_from"] / sr + max(0.0, lead)
                af = "anull" if lead >= 0 else f"adelay={int(-lead * 1000)}:all=1"
                cmd += ["-ss", f"{ss:.3f}", "-t", f"{n / sr - max(0.0, lead):.3f}", "-i", str(self.session / "audio.wav"),
                        "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-af", af, "-c:a", "aac", "-b:a", "96k",
                        "-ac", "1", "-ar", "48000"]
            else:
                cmd += ["-c", "copy"]
            cmd += [str(part)]
            r = run(cmd, check=False)
            if r.returncode == 0:
                parts.append(part)
        if not parts:
            return {"event": "error", "code": "no_frames", "message": "no video captured"}
        final = self.session / "recording.mp4"
        lst = self.session / "parts.txt"
        lst.write_text("".join(f"file '{p.name}'\n" for p in parts), encoding="utf-8")
        run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
             "-c", "copy", "-movflags", "+faststart", str(final)], check=False)
        for p in [*parts, lst, *(s["video"] for s in self.segments), *(s["log"] for s in self.segments)]:
            Path(p).unlink(missing_ok=True)
        with open(self.session / "events.jsonl", "w", encoding="utf-8") as fh:
            for e in self.events:
                fh.write(json.dumps(e) + "\n")
        return {"event": "stopped", "file": str(final), "duration": round(self.elapsed_before, 2),
                "audio_overflows": self.audio.overflows if self.audio else None}

    # --- external control: record.py stop/pause/resume/marker, hotkeys
    def poll_commands(self):
        if self.result:
            return
        try:
            if self.command_file.exists():
                cmds = self.command_file.read_text(encoding="utf-8").split()
                self.command_file.unlink()
                for c in cmds:
                    self.command(c)
        except Exception:
            pass
        self.root.after(250, self.poll_commands)

    def command(self, c: str):
        if c == "stop":
            self.stop() if self.segments else self.selected(None)
        elif c == "discard":
            self.stop(discard=True)
        elif c == "restart" and self.segments:
            self.restart()
        elif c == "pause" and not self.paused or c == "resume" and self.paused or c == "toggle":
            self.toggle_pause()
        elif c == "marker":
            self.marker()

    def start_hotkeys(self):
        if not IS_WIN:
            return
        q: queue.Queue = queue.Queue()

        def loop():
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            MOD = 0x0001 | 0x0004 | 0x4000  # ALT | SHIFT | NOREPEAT
            for i, vk in enumerate((0x50, 0x4D, 0x53), 1):  # P, M, S
                user32.RegisterHotKey(None, i, MOD, vk)
            msg = wintypes.MSG()
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
                if msg.message == 0x0312:  # WM_HOTKEY
                    q.put({1: "toggle", 2: "marker", 3: "stop"}.get(msg.wParam))

        threading.Thread(target=loop, daemon=True).start()

        def drain():
            while not q.empty():
                c = q.get()
                if c:
                    self.command(c)
            if not self.result:
                self.root.after(150, drain)
        self.root.after(150, drain)
