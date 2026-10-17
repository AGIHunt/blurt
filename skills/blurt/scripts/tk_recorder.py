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
from _common import IS_MAC, IS_WIN, ffmpeg_bin, fix_tcl_env, global_config, probe_duration, run  # noqa: E402

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


def _fxdbg(msg: str) -> None:
    """Optional pointer-feedback diagnostics: set BLURT_FX_DEBUG=<file> to append per-tick traces."""
    p = os.environ.get("BLURT_FX_DEBUG")
    if p:
        try:
            with open(p, "a", encoding="utf-8") as f:
                f.write(f"{time.monotonic():.3f} {msg}\n")
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


# ------------------------------------------------------------------ pointer (Windows parity with the native macOS recorder)
if IS_WIN:
    import ctypes

    class _POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    class _RECT(ctypes.Structure):
        _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long), ("r", ctypes.c_long), ("b", ctypes.c_long)]

    def cursor_pos() -> tuple[int, int]:
        pt = _POINT()
        ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
        return int(pt.x), int(pt.y)

    def window_rect_at(x: int, y: int) -> list[int] | None:
        """Physical-pixel rect (x, y, w, h) of the top-level window under the point."""
        u = ctypes.windll.user32
        hwnd = u.WindowFromPoint(_POINT(x, y))
        if not hwnd:
            return None
        hwnd = u.GetAncestor(hwnd, 2) or hwnd  # GA_ROOT
        rc = _RECT()
        if not u.GetWindowRect(hwnd, ctypes.byref(rc)):
            return None
        return [int(rc.l), int(rc.t), max(0, int(rc.r - rc.l)), max(0, int(rc.b - rc.t))]


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

    def up(self, e):
        if self.mode == "new" and self.sel is None and IS_WIN:
            # plain click = select the window under the cursor (parity with the native macOS picker)
            r = None
            self.win.withdraw()  # get the overlay out of WindowFromPoint's way
            try:
                r = window_rect_at(e.x_root, e.y_root)
            except Exception:
                pass
            finally:
                self.win.deiconify()
            if r:
                x, y = max(self.vx, r[0]), max(self.vy, r[1])
                w = min(r[0] + r[2], self.vx + self.vw) - x
                h = min(r[1] + r[3], self.vy + self.vh) - y
                if w >= 16 and h >= 16:
                    self.sel = [x - self.vx, y - self.vy, w // 2 * 2, h // 2 * 2]
        if self.sel and (self.sel[2] < 16 or self.sel[3] < 16):
            self.sel = None
        self.mode = None
        self.redraw()

    def redraw(self):
        c = self.c
        c.delete("all")
        hint = self.t("拖拽框选 / 单击选窗口 · F 全屏 · L 上次区域 · Enter 开始 · Esc 取消",
                      "Drag an area · click selects a window · F full screen · L last area · Enter start · Esc cancel")
        c.create_text(self.vw // 2, 40, text=hint, fill="white", font=("Segoe UI", 13, "bold"))
        if self.toolbar:
            self.toolbar.destroy()
            self.toolbar = None
        if not self.sel:
            return
        x, y, w, h = self.sel
        if IS_WIN:
            c.create_rectangle(x, y, x + w, y + h, fill=self.HOLE, outline="")
        c.create_rectangle(x - 1, y - 1, x + w + 1, y + h + 1, outline=ACCENT, width=3)
        for hx, hy in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
            c.create_rectangle(hx - 4, hy - 4, hx + 4, hy + 4, fill=ACCENT, outline="white")
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
        self._last_cur = None
        self._btn_down = False
        self._drag_anchor = None
        self._dragging = False
        self.events = []
        self.result = None

    def t(self, a, b):
        return a if zh(self.lang) else b

    def elapsed(self) -> float:
        return self.elapsed_before + ((time.time() - self.seg_started) if self.seg_started and not self.paused else 0)

    def log(self, type_: str, t: float | None = None, **kw):
        self.events.append({"t": round(t if t is not None else self.elapsed(), 3), "type": type_, **kw})

    # --- ui
    def run(self) -> dict:
        fix_tcl_env()
        import tkinter as tk
        enable_dpi_awareness()
        from record import pick_encoder
        self._enc_warm = threading.Thread(target=lambda: pick_encoder(ffmpeg_bin()), daemon=True)  # probe while user picks
        self._enc_warm.start()
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
        if getattr(self, "_hq", None):  # drop hotkey events queued before the take started
            while not self._hq.empty():
                self._hq.get()
        self.ending = False
        if self.mic:
            from record import MicRecorder
            self.audio = MicRecorder(self.mic, self.session / "audio.wav",
                                     gate=lambda: not self.paused and not self.ending)
            self.audio.start()
        self.start_segment()
        self.on_event({"event": "recording"})
        self.hotkeys(True)
        self.start_mouse_hook()  # 按下即记: exact press events for clicks/markers/drags
        self.gen = getattr(self, "gen", 0) + 1
        self.root.after(200, self.tick, self.gen)
        if IS_WIN:
            self.root.after(150, self._ptick, self.gen)  # cursor/click logging while recording

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
        self._mk_btn = mk("⚑", lambda: self.command("marker", src="bar"),
                          self.t("标记模式：之后每次点击都编号", "marker mode: next clicks get numbered"))
        self._mk_btn.pack(side="left", padx=2)
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
        if IS_WIN:
            # once mapped: the ⚑ button's screen centre — deterministic target for the marker e2e.
            # The bar maps only after the countdown, so poll until winfo reports real coords
            # (ring21: a fixed +500 ms read fired before the map and logged (0,0), missing the arm)
            def _log_mk(tries: int = 0):
                bx = self._mk_btn.winfo_rootx() + self._mk_btn.winfo_width() // 2
                by = self._mk_btn.winfo_rooty() + self._mk_btn.winfo_height() // 2
                if (bx or by) or tries > 40:
                    _fxdbg(f"bar mk_btn={bx},{by}")
                else:
                    self.root.after(200, lambda: _log_mk(tries + 1))
            self.root.after(500, _log_mk)

    def tick(self, gen=0):
        if self.result or gen != getattr(self, "gen", 0):
            return
        s = int(self.elapsed())
        self.clock.config(text=f"{s // 60:02d}:{s % 60:02d}" if s < 3600 else f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}")
        self.dot.config(fg=AMBER if self.paused else ("#ff3b30" if int(time.time() * 2) % 2 else "#7a1f1a"))
        self.root.after(250, self.tick, gen)

    def _ptick(self, gen=0):
        """Windows: log cursor moves, left-clicks and press-drags into events.jsonl (frames.py --ring reads
        cursor/click; drags also get a live red rectangle in the video itself). Clicks come from the
        WH_MOUSE_LL hook when it is running — press-time exact, 按下即记; otherwise the GetAsyncKeyState
        rising edge (tick-time cursor, can lose presses under load)."""
        if self.result or gen != getattr(self, "gen", 0) or self.ending:
            return
        down_now = False
        try:
            import ctypes  # noqa: PLC0415 — bound only under IS_WIN at module level
            # 0x8000 = down right now (drives drag tracking / release); the 0x0001 rising edge is
            # only used when the LL hook is unavailable
            st = ctypes.windll.user32.GetAsyncKeyState(0x01)
            down_now = bool(st & 0x8000)
            clicked = bool(st & 0x0001) or (down_now and not self._btn_down)
            released = not down_now and self._btn_down
            self._btn_down = down_now
            x, y = cursor_pos()
            rx, ry, rw, rh = self.region
            inside = rw > 0 and rh > 0 and rx <= x < rx + rw and ry <= y < ry + rh
            evs = self._drain_presses()
            if evs is None:  # no hook: legacy poll — one synthetic press, tick-time cursor
                evs = [("down", None, x, y)] if clicked and not self.paused else []
            for kind, pt_ev, px, py in evs:
                p_inside = rw > 0 and rh > 0 and rx <= px < rx + rw and ry <= py < ry + rh
                if kind == "down":
                    if not self.paused:
                        if p_inside:
                            t_ev = self.elapsed_before + (pt_ev - self.seg_started) \
                                if pt_ev and self.seg_started else None
                            if getattr(self, "_marker_armed", False):
                                # marker mode: the click is the next number — but it waits for the
                                # release so a press that turns into a drag stays unmarked (user:
                                # 我拖动画框的时候，就不要标 1 和 2). No hook → no up events: drop
                                # immediately rather than never (legacy poll path).
                                if pt_ev is None:
                                    self._drop_marker(px, py, t=t_ev)
                                else:
                                    self._pending_marker = (px, py, t_ev)
                            else:
                                self.log("click", t=t_ev, x=round((px - rx) / rw, 4), y=round((py - ry) / rh, 4))
                                self._last_cur = None
                                self.click_flash(px, py)  # live feedback for the operator; the video gets
                                # the antialiased disc from overlay_halo.py — two independent layers
                        self._drag_anchor = (px, py)
                        self._dragging = False
                else:  # up — completes a pending armed marker unless the press became a drag
                    pend = getattr(self, "_pending_marker", None)
                    if pend is not None:
                        self._pending_marker = None
                        if not self._dragging and not self.paused:
                            fx = round(max(0.0, min(1.0, (pend[0] - rx) / rw)), 4) if rw > 0 else 0.5
                            fy = round(max(0.0, min(1.0, (pend[1] - ry) / rh)), 4) if rh > 0 else 0.5
                            self.log("click", t=pend[2], x=fx, y=fy)
                            self._last_cur = None
                            self._drop_marker(pend[0], pend[1], t=pend[2])
            _fxdbg(f"tick x={x} y={y} inside={inside} down={down_now} presses={len(evs)} rel={released}")
            if released:
                if self._dragging:
                    ax0, ay0 = self._drag_anchor or (x, y)
                    self.log("drag", x=round(max(0.0, min(1.0, (ax0 - rx) / rw)), 4) if rw > 0 else 0.0,
                             y=round(max(0.0, min(1.0, (ay0 - ry) / rh)), 4) if rh > 0 else 0.0,
                             x2=round(max(0.0, min(1.0, (x - rx) / rw)), 4) if rw > 0 else 0.0,
                             y2=round(max(0.0, min(1.0, (y - ry) / rh)), 4) if rh > 0 else 0.0)
                    # the marquee STAYS after release (user take 20260930-064755: 框消失的话，
                    # 你可能不知道我拖的是什么地方): it is a plain captured window, so the box
                    # persists in the video for free; the next drag repositions it, pause/stop clear it
                self._drag_anchor = None
                self._dragging = False
            elif down_now and self._drag_anchor is not None and not self.paused:
                ax, ay = self._drag_anchor
                if abs(x - ax) > 8 or abs(y - ay) > 8:  # a click without drift is a click, not a drag
                    self._dragging = True
                    self._cflash_hide()  # the press became a drag — the click disc is noise here
                    # (user take 20260930-064755: 我当我要拖的时候，他那个实心圆是不是不要出现)
                    self.drag_rect(ax, ay, x, y)  # marquee follows the drag, visible in the video
            if not self.paused:
                if inside:
                    fx, fy = round((x - rx) / rw, 4), round((y - ry) / rh, 4)
                    # heartbeat while parked: a still cursor emits nothing by movement-detection, and
                    # overlay_halo's GAP rule would then hide the disc whenever the user pauses the
                    # mouse to point and talk — so re-emit the position at least every 0.2 s (< GAP)
                    now = time.time()
                    if (fx, fy) != self._last_cur or now - getattr(self, "_last_cur_t", 0.0) > 0.2:
                        self._last_cur = (fx, fy)
                        self._last_cur_t = now
                        self.log("cursor", x=fx, y=fy)
                    self.halo(x, y)  # the 光圈 rides the cursor, in the video too — inside the region only
                else:
                    self.halo_hide()  # outside the region there is nothing to mark; keeps the HUD clickable
            else:
                self.halo_hide()
            # Click shield over the region (user take 20260929-150206 I-001): clicks and drags that mark
            # the video must not select/operate the content underneath (macOS behaviour — "拖动的时候不
            # 能选择其后面的东西"). A near-invisible layered window WITHOUT WS_EX_TRANSPARENT covers the
            # region and takes the hits, so apps below never see them; the polling here is unaffected
            # (events.jsonl, the click log and marquee keep working) and the HUD outside the region stays
            # clickable. A static surface never needs recomposition, so the layered-window freeze
            # phenomenon cannot bite. Hidden while paused so the user can interact with apps.
            # Alpha must be nonzero: layered-window hit testing lets mouse messages through pixels whose
            # alpha is exactly 0 (MS docs), so 0.0 would be a fully click-through shield (ring9: CLICKED);
            # 1/255 ≈ 0.4% is imperceptible in the captured video but hit-testable everywhere.
            shield = getattr(self, "_shield", None)
            if not self.paused:
                if shield is None:
                    import tkinter as tk
                    shield = tk.Toplevel(self.root)
                    shield.overrideredirect(True)
                    shield.attributes("-topmost", True)
                    shield.attributes("-alpha", 1.0 / 255)
                    self._shield = shield
                shield.geometry(f"{rw}x{rh}+{rx}+{ry}")
                shield.deiconify()
                shield.lift()
            elif shield is not None:
                shield.withdraw()
        except Exception:
            import traceback
            _fxdbg("PTICK-EXC " + traceback.format_exc().replace("\n", " | "))
        self.root.after(50, self._ptick, gen)

    def drag_rect(self, ax: int, ay: int, x: int, y: int):
        """Live red marquee following a press-drag, like a screenshot selection (the demo's drag feedback).
        Four solid slivers, not one region-carved frame: a SetWindowRgn frame that resizes every tick leaves
        its old carve-outs unrepainted on screen (nested ghost rects); plain windows move/resize cleanly."""
        import tkinter as tk
        x0, y0, x1, y1 = min(ax, x), min(ay, y), max(ax, x), max(ay, y)
        b = 3  # frame thickness, physical px
        edges = {"t": (x0, y0, x1 - x0 + b, b), "b": (x0, y1, x1 - x0 + b, b),
                 "l": (x0, y0, b, y1 - y0 + b), "r": (x1, y0, b, y1 - y0 + b)}
        wins = getattr(self, "_dragwins", None)
        if wins is None:
            wins = {}
            for k in "tblr":
                w_ = tk.Toplevel(self.root)
                w_.overrideredirect(True)
                w_.attributes("-topmost", True)
                w_.configure(bg="#ff2d2d")
                wins[k] = w_
            self._dragwins = wins
        for k, (ex, ey, ew, eh) in edges.items():
            wins[k].geometry(f"{max(1, ew)}x{max(1, eh)}+{ex}+{ey}")
            wins[k].deiconify()
        for w_ in wins.values():
            w_.lift()

    def drag_rect_hide(self):
        for win in (getattr(self, "_dragwins", None) or {}).values():
            try:
                win.withdraw()
            except Exception:
                pass

    def _wda_disc(self, key: str | None, w: int, color: str, numbered: bool = False, store: bool = True):
        """One reusable screen-only disc window (WDA_EXCLUDEFROMCAPTURE): the eye sees it, the
        capture never does — the video's markers are composited separately by overlay_halo.py.
        Stored as self.<key> = [win, label|None, w] unless store=False (caller keeps the handle,
        e.g. one persistent badge window per marker number); plain windows repaint fine under load."""
        import ctypes  # noqa: PLC0415
        import tkinter as tk  # noqa: PLC0415
        win = tk.Toplevel(self.root)
        win.overrideredirect(True)
        win.attributes("-topmost", True)
        win.configure(bg=color)
        lab = None
        if numbered:
            lab = tk.Label(win, text="", fg="white", bg=color,
                           font=("Segoe UI", max(14, w // 3), "bold"))
            lab.pack(expand=True, fill="both")
        win.withdraw()
        exclude_from_capture(win)
        u32 = ctypes.windll.user32
        hwnd = u32.GetParent(win.winfo_id()) or win.winfo_id()
        getp = getattr(u32, "GetWindowLongPtrW", u32.GetWindowLongW)
        setp = getattr(u32, "SetWindowLongPtrW", u32.SetWindowLongW)
        setp(hwnd, -20, getp(hwnd, -20) | 0x20 | 0x80)  # WS_EX_TRANSPARENT|TOOLWINDOW
        u32.SetWindowRgn(hwnd, ctypes.windll.gdi32.CreateEllipticRgn(0, 0, w, w), True)
        if store:
            setattr(self, key, [win, lab, w])
        return [win, lab, w]

    def click_flash(self, x: int, y: int):
        """Live click feedback for the operator's eyes (Mac parity): a solid colour disc that flashes
        on the click point for ~0.45s. The translucent antialiased disc the AI sees is composited
        later by overlay_halo.py; this window only answers the human's click (take 20260930-052441:
        "双击是没有光圈的" — while recording, nothing on screen acknowledged the clicks)."""
        if not IS_WIN:
            return
        st = getattr(self, "_cflash", None)
        if st is None:
            rec = global_config().get("record", {}) or {}
            if rec.get("live_click", True) is False:
                self._cflash = False  # opt-out switch; checked once per recording
                return
            win = self._wda_disc("_cflash", max(24, int(rec.get("click_size") or 56)),
                                 str(rec.get("click_color") or "#ff2d2d").strip())[0]
            self._cflash_after = None
        else:
            win = st[0] if st else None
        if not win:
            return
        w = self._cflash[2]
        win.geometry(f"{w}x{w}+{x - w // 2}+{y - w // 2}")
        win.deiconify()
        # stay up ~0.45s (the composite's CLICK_HOLD); a double-click's second press re-arms
        if getattr(self, "_cflash_after", None):
            try:
                self.root.after_cancel(self._cflash_after)
            except Exception:
                pass
        self._cflash_after = self.root.after(450, self._cflash_hide)

    def _cflash_hide(self):
        self._cflash_after = None
        st = getattr(self, "_cflash", None)
        if st and st[0]:
            try:
                st[0].withdraw()
            except Exception:
                pass

    def marker_flash(self, x: int, y: int, n: int):
        """Persistent numbered badge at the marker point (user: 我用小红旗标的 1 和 2 也不应该消失，
        就放在上面就可以了) — one WDA window per number, kept until the take ends (cleared with the
        marquee by _clear_annotations on stop/restart). Screen-only; the video's badges are
        composited by overlay_halo.py from the marker events, so persistence costs no capture."""
        if not IS_WIN:
            return
        badges = getattr(self, "_mbadges", None)
        if badges is None:
            badges = self._mbadges = {}
        st = badges.get(n)
        if st is None:
            rec = global_config().get("record", {}) or {}
            st = self._wda_disc(None, max(44, int(rec.get("click_size") or 56) + 10),
                                str(rec.get("click_color") or "#ff2d2d").strip(),
                                numbered=True, store=False)
            badges[n] = st
        st[1].config(text=str(n))
        w = st[2]
        st[0].geometry(f"{w}x{w}+{x - w // 2}+{y - w // 2}")
        st[0].deiconify()
        st[0].lift()

    def _clear_annotations(self):
        """The take's live annotations die with its windows (user: 关闭整个窗口以后，画的框就不在
        了) — stop()/restart() only destroyed hud+borders, so the red marquee outlived the take
        through the whole post-processing, and a crashed teardown left it stuck on screen."""
        for win in (getattr(self, "_dragwins", None) or {}).values():
            try:
                win.destroy()
            except Exception:
                pass
        self._dragwins = None
        for st in (getattr(self, "_mbadges", None) or {}).values():
            try:
                st[0].destroy()
            except Exception:
                pass
        self._mbadges = {}
        self._pending_marker = None

    def halo(self, x: int, y: int):
        """The 光圈 rides the cursor, in two independent layers:
        - in the video: always composited post-hoc by overlay_halo.py — every window-based disc froze
          in or vanished from real gdigrab capture, and the opaque-slice disc occluded content with
          seams and jaggies (user take 20260929-161905). The composite is antialiased, truly ~50%
          translucent, riding the interpolated cursor track from events.jsonl.
        - on screen (optional, config record.live_halo — take 181524: the user missed seeing a halo
          while moving): a colour-carved disc window with WDA_EXCLUDEFROMCAPTURE, so the eye sees a
          live halo while the capture (and thus the composite) never does. Plain windows repaint fine
          under capture load (the drag marquee proves it every take); WDA + carving only change how
          screen and capture see the window, never what gets encoded.
        """
        if not IS_WIN:
            return
        if getattr(self, "_live_halo", None) is None:
            self._live_halo = False  # disabled unless config turns it on (checked once per recording)
            rec = global_config().get("record", {}) or {}
            if not rec.get("live_halo"):
                return
            import ctypes  # noqa: PLC0415
            import tkinter as tk  # noqa: PLC0415
            color = str(rec.get("halo_color") or "#ff2fd6").strip()
            w = max(24, int(rec.get("halo_size") or 100))
            win = tk.Toplevel(self.root)
            win.overrideredirect(True)
            win.attributes("-topmost", True)
            win.configure(bg=color)
            win.withdraw()
            exclude_from_capture(win)  # invisible to gdigrab — the composite owns the video
            u32 = ctypes.windll.user32
            hwnd = u32.GetParent(win.winfo_id()) or win.winfo_id()
            getp = getattr(u32, "GetWindowLongPtrW", u32.GetWindowLongW)
            setp = getattr(u32, "SetWindowLongPtrW", u32.SetWindowLongW)
            setp(hwnd, -20, getp(hwnd, -20) | 0x20 | 0x80)  # WS_EX_TRANSPARENT|TOOLWINDOW: click-through
            u32.SetWindowRgn(hwnd, ctypes.windll.gdi32.CreateEllipticRgn(0, 0, w, w), True)  # round on screen
            self._live_halo = win
            self._live_halo_size = w
        win = self._live_halo
        if not win:
            return
        w = self._live_halo_size
        win.geometry(f"{w}x{w}+{x - w // 2}+{y - w // 2}")
        win.deiconify()

    def halo_hide(self):
        win = getattr(self, "_live_halo", None)
        if win:
            try:
                win.withdraw()
            except Exception:
                pass

    # --- capture
    def video_cmd(self, out: Path) -> list[str]:
        ff = ffmpeg_bin()
        if getattr(self, "_enc_warm", None) and self._enc_warm.is_alive():
            self._enc_warm.join()  # encoder probe usually finished during the picker/countdown
        # ffmpeg ≥7.1's gdigrab is per-monitor-DPI-aware: -offset_x/-video_size are PHYSICAL pixels, matching
        # every coordinate this process handles (Tk PMv2 events/geometry, GetCursorPos, GetWindowRect). Verified
        # 2026-09-29 on a 225% display: a marker at physical (500,400) lands in the -offset_x 399 capture.
        # Older DPI-unaware gdigrab (≤7.0) would need logical coords — the old logical_region() hack — but it
        # also silently MISSES topmost-region rings placed at true physical positions. We require the aware path.
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
        self.ending = False
        out = self.session / f"seg{i:02d}.mkv"
        log = self.session / f"seg{i:02d}.log"
        fh = open(log, "w", encoding="utf-8")
        seg = {"video": out, "log": log, "fh": fh, "audio_from": self.audio.frames if self.audio else 0,
               "wall_start": time.time()}
        seg["proc"] = subprocess.Popen(self.video_cmd(out), stdin=subprocess.PIPE, stdout=fh, stderr=fh)
        self.segments.append(seg)
        self.seg_started = time.time()
        seg["t0_wall"], seg["eb"] = self.seg_started, self.elapsed_before  # event-clock zero for sync.json
        self._last_cur = None  # the timeline jumped (pause/resume) — force a fresh cursor event
        self._btn_down = False
        self._drag_anchor = None
        self._dragging = False
        # no drag_rect_hide here: the marquee is an annotation the user wants kept (1) until the
        # take ends — pause/resume only closes the segment, not the drawing

    def end_segment(self):
        seg = self.segments[-1]
        self.ending = True                       # freeze audio writes now: ffmpeg's shutdown can take seconds
        seg["audio_to"] = self.audio.frames if self.audio else 0
        end_wall = time.time()
        p = seg["proc"]
        if p.poll() is None:
            try:
                p.stdin.write(b"q")
                p.stdin.flush()
            except Exception:
                pass
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait(timeout=5)
        seg["fh"].close()
        seg["wall_end"] = end_wall
        self.elapsed_before += end_wall - (self.seg_started or end_wall)
        self.seg_started = None

    # --- controls
    def toggle_pause(self):
        if not self.segments or self.result or self.ending:
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

    def _drop_marker(self, x: int, y: int, t: float | None = None):
        """Log marker n at screen (x, y): events.jsonl line + live numbered flash. The review
        chips (review._markers_payload) and the composite badges (overlay_halo._markers) hang
        off this event. t = the exact event time when the caller knows it (hook press time)."""
        n = getattr(self, "_marker_n", 0) + 1
        self._marker_n = n
        rx, ry, rw, rh = self.region
        fx = round(max(0.0, min(1.0, (x - rx) / rw)), 4) if rw > 0 else 0.5
        fy = round(max(0.0, min(1.0, (y - ry) / rh)), 4) if rh > 0 else 0.5
        self.log("marker", t=t, n=n, x=fx, y=fy)
        self.on_event({"event": "marker", "t": round(t if t is not None else self.elapsed(), 2), "n": n})
        self.marker_flash(x, y, n)

    def marker(self):
        """Instant numbered marker at the cursor (Alt+Shift+M / chat control): point somewhere,
        keep the mouse still, press M — the number lands where you're pointing. Marker MODE (the
        ⚑ button) is different: every subsequent click gets the next number — see arm_markers()."""
        if self.segments and not self.paused:
            self._drop_marker(*cursor_pos())

    def arm_markers(self):
        """⚑ toggles marker mode (user, mid-turn on e2e-ring18: 点了小红旗以后…每在框里面点一次鼠标，
        它就会有一个 1、有一个 2 — explicitly NOT "turn my previous click into the marker"). While
        armed every content click in the region drops the next numbered marker at the click point;
        the button lights red until toggled off."""
        self._marker_armed = not getattr(self, "_marker_armed", False)
        btn = getattr(self, "_mk_btn", None)
        if btn is not None:
            btn.config(bg="#e0342b" if self._marker_armed else BG2)
        self.log("marker_mode", on=self._marker_armed)

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
        self.hotkeys(False)
        self.stop_mouse_hook()
        if not self.paused and self.segments:
            self.end_segment()
        if self.audio:
            self.audio.stop()
        for w in [self.hud, *self.borders]:
            w.destroy()
        self._clear_annotations()  # marquee + numbered badges die with the take's windows
        logs = self.session / "logs"
        for seg in self.segments:
            Path(seg["video"]).unlink(missing_ok=True)
            try:
                logs.mkdir(exist_ok=True)
                Path(seg["log"]).rename(logs / Path(seg["log"]).name)  # keep ffmpeg's log: it explains dead takes
            except OSError:
                pass
        (self.session / "audio.wav").unlink(missing_ok=True)
        self.segments, self.audio, self.paused, self.elapsed_before, self.seg_started, self.events = [], None, False, 0.0, None, []
        self._marker_n = 0  # numbering restarts with the new take
        self._marker_armed = False  # the rebuilt bar's ⚑ starts unlit
        self.on_event({"event": "restarting"})
        self.countdown(self.countdown_n)

    def discard(self):
        self.stop(discard=True)

    def stop(self, discard: bool = False, src: str = "ui"):
        if self.result or not self.segments or self.ending:
            if not self.segments and not self.ending:
                self.result = {"event": "cancelled"}
                self.root.quit()
            return
        self.hotkeys(False)
        self.stop_mouse_hook()
        if not self.paused:
            self.log("stop", src=src)
            self.end_segment()
        if self.audio:
            self.audio.stop()
        for w in [self.hud, *self.borders]:
            w.destroy()
        self._clear_annotations()  # marquee + numbered badges die with the take's windows
        self.result = {"event": "cancelled", "reason": "discarded"} if discard else self.finalize()
        self.root.quit()

    def finalize(self) -> dict:
        """Join segments; align each segment's audio slice to its first video frame by wall clock."""
        from record import first_frame_wall
        parts = []
        sr = self.audio.sr if self.audio else 48000
        a0 = self.audio.first_wall if self.audio else None
        sync, off = [], 0.0
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
                sync.append([round(off, 3), round(v0 - seg.get("t0_wall", v0) + seg.get("eb", 0.0), 3)])
                off += probe_duration(part) or 0.0
        if not parts:
            return {"event": "error", "code": "no_frames", "message": "no video captured"}
        final = self.session / "recording.mp4"
        lst = self.session / "parts.txt"
        lst.write_text("".join(f"file '{p.name}'\n" for p in parts), encoding="utf-8")
        run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
             "-c", "copy", "-movflags", "+faststart", str(final)], check=False)
        if sync:
            # per-segment sync for post-processing (overlay_halo): video-file time t inside segment k maps to
            # event time t - offset_k + delta_k. delta = first frame's wall epoch (ffmpeg's own `start:` line,
            # exact) minus the event clock's zero for that segment — gdigrab startup latency (~0.3 s) otherwise
            # leaves the cursor track trailing the drawn cursor during fast motion (ring13: 80 px).
            (self.session / "sync.json").write_text(json.dumps({"segs": sync}), encoding="utf-8")
        logs = self.session / "logs"
        for s in self.segments:  # keep ffmpeg's per-segment logs: they explain dead takes
            try:
                logs.mkdir(exist_ok=True)
                Path(s["log"]).rename(logs / Path(s["log"]).name)
            except OSError:
                pass
        for p in [*parts, lst, *(s["video"] for s in self.segments)]:
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

    def command(self, c: str, src: str = "chat"):
        if c == "stop":
            self.stop(src=src) if self.segments else self.selected(None)
        elif c == "discard":
            self.stop(discard=True)
        elif c == "restart" and self.segments:
            self.restart()
        elif c == "pause" and not self.paused or c == "resume" and self.paused or c == "toggle":
            self.toggle_pause()
        elif c == "marker":
            self.arm_markers() if src == "bar" else self.marker()

    def start_hotkeys(self):
        if not IS_WIN:
            return
        self._hk = {"tid": 0, "on": False}
        q = self._hq = queue.Queue()

        def loop():
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            self._hk["tid"] = ctypes.windll.kernel32.GetCurrentThreadId()
            MOD = 0x0001 | 0x0004 | 0x4000  # ALT | SHIFT | NOREPEAT
            msg = wintypes.MSG()
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                if msg.message == 0x0312:  # WM_HOTKEY
                    q.put({1: "toggle", 2: "marker", 3: "stop"}.get(msg.wParam))
                elif msg.message == 0x8001:  # WM_APP+1: register/unregister
                    if msg.wParam and not self._hk["on"]:
                        self._hk["on"] = all(user32.RegisterHotKey(None, i, MOD, vk)
                                             for i, vk in enumerate((0x50, 0x4D, 0x53), 1))  # P, M, S
                    elif not msg.wParam and self._hk["on"]:
                        for i in (1, 2, 3):
                            user32.UnregisterHotKey(None, i)
                        self._hk["on"] = False

        threading.Thread(target=loop, daemon=True).start()

        def drain():
            while not q.empty():
                c = q.get()
                if c and self.segments and not self.result:  # hotkeys only act while a take is running
                    self.command(c, src="hotkey")
            if not self.result:
                self.root.after(150, drain)
        self.root.after(150, drain)

    def start_mouse_hook(self):
        """WH_MOUSE_LL, 按下即记 (user take 202612: a click lost at 28.8s; e2e-ring20: a drag press
        never logged): the GetAsyncKeyState poll can miss quick presses when Tk stalls and always
        logs the cursor wherever it has drifted by tick time. The LL hook delivers every left press
        the moment it happens with the exact position. The callback only queues — a slow hook proc
        gets silently dropped by Windows — and the Tk tick consumes and logs."""
        if not IS_WIN:
            return
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.windll.user32
        HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        # ctypes guesses c_int args without argtypes: the 64-bit lParam/HHOOK overflowed, every
        # mouse event raised inside the proc and the traceback flood starved the Tk loop (ring21)
        user32.CallNextHookEx.argtypes = (ctypes.c_void_p, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        user32.CallNextHookEx.restype = ctypes.c_ssize_t
        user32.SetWindowsHookExW.argtypes = (ctypes.c_int, HOOKPROC, ctypes.c_void_p, wintypes.DWORD)
        user32.SetWindowsHookExW.restype = ctypes.c_void_p
        user32.UnhookWindowsHookEx.argtypes = (ctypes.c_void_p,)

        class MSLLHOOKSTRUCT(ctypes.Structure):
            _fields_ = [("pt", wintypes.POINT), ("mouseData", wintypes.DWORD),
                        ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                        ("dwExtraInfo", ctypes.c_size_t)]

        q = queue.Queue()
        hm = self._mh = {"q": q, "on": False, "tid": 0, "proc": None}

        def proc(n_code, w_param, l_param):
            if n_code == 0 and w_param in (0x0201, 0x0202):  # HC_ACTION, WM_LBUTTONDOWN/UP
                ms = ctypes.cast(l_param, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
                q.put(("down" if w_param == 0x0201 else "up", time.time(), ms.pt.x, ms.pt.y))
            return user32.CallNextHookEx(None, n_code, w_param, l_param)

        hm["proc"] = HOOKPROC(proc)  # the trampoline must outlive the hook

        def run():
            u32 = ctypes.windll.user32
            k32 = ctypes.windll.kernel32
            hm["tid"] = k32.GetCurrentThreadId()
            hh = u32.SetWindowsHookExW(14, hm["proc"], None, 0)  # WH_MOUSE_LL, global
            hm["on"] = bool(hh)
            if not hh:
                return  # Tk tick falls back to the GetAsyncKeyState rising edge
            msg = wintypes.MSG()
            while u32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                pass  # the hook does the work; this pump only keeps it serviced
            u32.UnhookWindowsHookEx(hh)

        threading.Thread(target=run, daemon=True, name="blurt-mouse-hook").start()

    def stop_mouse_hook(self):
        hm = getattr(self, "_mh", None)
        if hm:
            hm["on"] = False
            if hm.get("tid"):
                try:
                    import ctypes  # noqa: PLC0415 — bound only under IS_WIN at module level
                    # PostThreadMessageW lives in user32, not kernel32 — a wrong dll here raised out
                    # of stop()/restart() and left the bar unclosable (20260930 cmdtest)
                    ctypes.windll.user32.PostThreadMessageW(hm["tid"], 0x0012, 0, 0)  # WM_QUIT → unhook
                except Exception:
                    pass  # teardown must never block a stop; the daemon thread dies with the process

    def _drain_presses(self):
        """Left button events queued by the LL hook since the last tick, [("down"|"up", wall_t, x, y)];
        None when the hook is not running (caller falls back to the GetAsyncKeyState rising edge)."""
        mh = getattr(self, "_mh", None)
        if not mh or not mh.get("on"):
            return None
        out = []
        try:
            while True:
                out.append(mh["q"].get_nowait())
        except queue.Empty:
            pass
        return out

    def hotkeys(self, on: bool, _retry: bool = True):
        """Alt+Shift+P/M/S are registered only while a take runs: before that the combos stay free
        (Alt+Shift is also the Windows input-language switch — a pre-take press used to queue a stop)."""
        st = getattr(self, "_hk", None)
        if not (st and st.get("tid")):
            if _retry and not self.result:
                self.root.after(80, lambda: self.hotkeys(on, _retry=False))
            return
        import ctypes
        ctypes.windll.user32.PostThreadMessageW(st["tid"], 0x8001, 1 if on else 0, 0)
