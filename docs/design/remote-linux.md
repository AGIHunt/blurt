# Blurt Remote on Linux: the host's backend (Ubuntu 26.04 GNOME, Wayland)

2026-11-09. The phone as trackpad, keys, microphone and screen view for Blurt on Linux. Product and wire are
[remote.md](remote.md) and [remote-protocol.md](remote-protocol.md); the contract is `crates/blurt-remote/src/host.rs`; this is
`crates/blurt-remote/src/platform/linux/`. How the desktop app already uses portals: [linux-port.md](linux-port.md).

## Design

One xdg-desktop-portal session does everything: a **RemoteDesktop** session (keyboard + pointer) with **ScreenCast**
attached (one monitor, `cursor_mode` metadata), `persist_mode` 2 and a restore token. So GNOME asks once, in one dialog,
and after that every session starts with no dialog. It's separate from the app's own short-lived RemoteDesktop session
for paste, and the two don't interfere. The session starts lazily, on the first input or screen request.
`Screen::prepare` (new in host.rs, additive) lets the server wait for the dialog without holding the backend, so keys keep
working while GNOME asks. When the last phone leaves (`keep_awake(false)`), the session closes 30 s later and GNOME's
orange chips go away.

```
portal ScreenCast ─fd,node─▶ libpipewire stream (SHM, BGRx) ─▶ Mirror ──cut the crop──▶ GStreamer appsrc
   cursor meta: position + bitmap ─▶ Input::pointer / cursor_shape     damage meta ─▶ only changed rectangles copied
appsrc ─▶ videoconvertscale (constant output size, I420/NV12) ─▶ x264enc | vah264enc | nvh264enc … ─▶ h264parse ─▶ appsink
   ─▶ nal.rs: Annex B → 4-byte lengths + SPS/PPS on keyframes (host.rs EncodedFrame)
portal RemoteDesktop ◀─ one task, in order ◀─ Input (keys.rs state machine, keysyms, smooth axis + finish)
```

Decisions, and why:

- **libpipewire directly, not `pipewiresrc`.** Only the stream carries the pointer (cursor metadata: position and
  bitmap, because the cursor isn't drawn into the frames) and video damage. GStreamer's source passes on neither. Buffers
  are SHM (MemFd/MemPtr), never DMA-BUF: the crop is cut on the CPU anyway.
- **A mirror of the monitor, and the crop cut from it.** GNOME sends a frame only when something changes. A new crop on a
  still screen has no frame to come from, so it's cut from the copy. Each frame copies only its damaged rectangles in.
  A cut identical to the last one isn't encoded: a change outside the phone's view, or a pointer-only update, costs
  nothing. Every frame's `crop` is exactly the rectangle it was cut from.
- **The crop changes appsrc's caps, never the output's.** videoconvertscale renegotiates its input; the encoder sees one
  size forever. So a crop change needs no restart, no keyframe, and leaves no black frame. Output is the monitor's shape,
  as large as asked, never above the monitor's pixels (as on the Mac).
- **Encoder chosen at runtime.** Hardware first, per the phone's order: VA (`vah264enc`/`vah265enc`, then gstreamer-vaapi),
  NVENC, QSV. Otherwise `x264enc`. HEVC only when the phone prefers it and a hardware HEVC encoder exists.
  `BLURT_REMOTE_ENCODER` forces one. x264 runs with `tune=zerolatency speed-preset=superfast`, sliced threads (≤ 4,
  so a picture is several slices), no B-frames, `key-int-max=600`, a keyframe on request, a VBV of about 4 frames
  (120–300 ms) and repeat-headers.
- **The caps say 60 fps, whatever the rate.** With a variable rate (0/1), x264 holds every picture back until the next
  one arrives (it needs the next timestamp). On a still screen the last frame never came out: measured, 4 of 5. So the
  rate is nominal, and the bitrate is scaled to `bitrate × 60 / fps`, so each real frame gets `bitrate / fps`. Rate
  changes go to the running encoder.
- **Back-pressure, not queues.** At most two pictures are in the encoder. A newer cut replaces a waiting one.
- **Keys by evdev code at US positions.** Command → `KEY_LEFTMETA`, control → Ctrl, option → Alt. Modifiers go down
  Ctrl, Alt, Shift, Super and come up in reverse, the way a keyboard presses them. A lone Super down/up opens Activities
  like a real tap. `release_all` and losing the session leave nothing down.
- **Text.** ASCII up to 64 characters goes as keysyms: mutter finds each one on the user's own layout and adds Shift. Text
  that isn't ASCII, is longer, or is typed while an IBus input method is current (gsettings `mru-sources`) is pasted
  through the clipboard. The default is XWayland's clipboard + Ctrl+V with the old text put back; the app can pass its
  own dictation insert with `set_paste`, which knows terminals want Ctrl+Shift+V.
- **Scrolling.** Smooth `NotifyPointerAxis` in logical pixels, in the direction host.rs defines, flipped if the user's
  GNOME touchpad natural-scroll is off. The `finish` goes 60 ms after a gesture ends, or 90 ms after the server's coast,
  so GTK doesn't start a coast of its own on top. Discrete steps (30 px each, fractions carried) only if the portal
  refuses smooth scrolling.
- **Absolute moves.** In the stream's frame pixels on GNOME (mutter divides by the scale), logical pixels elsewhere (KDE).
- **Keep awake.** org.freedesktop.portal.Inhibit, suspend (+ idle when the screen shows), released when the phone goes.
- **System moves (GNOME).** Super = overview; Super+\` = the app's next window; Super+PageUp/PageDown = workspaces;
  Ctrl+= / Ctrl+- = zoom; a lone Ctrl = Locate Pointer (when it's on).

## Measured (2026-11-09)

Rig: GCP n2-standard-8 (Cascade Lake, 8 vCPU, no GPU: llvmpipe, so x264), Ubuntu 26.04.1, GNOME 50.1 Wayland, PipeWire 1.6.2,
GStreamer 1.28.2, a 1920×1080 monitor at 100 %. `examples/linux_smoke.rs`, then the real host (`examples/host.rs --real`)
with the test phone (`examples/phone.rs`) on a Mac, over the internet.

| | |
|---|---|
| First session | GNOME's "Remote Desktop" dialog, **"Allow Remote Interaction" off by default**: it has to be turned on (else `can_control` stays false) |
| Later sessions (restore token) | portal session open in 30–39 ms, no dialog; screen start (PipeWire connect + first frame + encoder) 55–66 ms |
| 1920×1080 → 1920×1080, x264, scrolling terminal | convert+encode 11–12 ms mean (max 18–22 steady, 60–80 for the first frame); frame age at encoder output p50 11–13 ms, p95 15–21 ms |
| 1920×1080 → 1280×720 | convert+encode 6.2–7.0 ms mean; age p50 7–8 ms, p95 24–40 ms |
| Source rate | GNOME on llvmpipe sends a scrolling, maximised terminal at ~15 fps (gnome-shell ~190 % CPU), and every frame was encoded; with a text editor and a moving pointer, 34–42 fps. A real GPU will send more |
| Bitrate, scrolling terminal | 1.5–2.2 Mbit/s at 1080p (8 Mbit/s cap, 15 fps source); 0.7–0.9 Mbit/s at 720p (2 Mbit/s); a live `set_rate` took effect without a restart |
| Still screen | 115 compositor frames (pointer moving, nothing changing in the view) → 7 encoded; a refresh resends the last cut as P-frames |
| Crop changes, 7 a second for 2 s | no restart, no keyframe, one output size; 28 different crops labelled; the `.h264` decodes cleanly with ffmpeg |
| Encoder unit test (videotestsrc noise 1080p → 720p, 120 frames, 4 crops, 4 → 1 Mbit/s) | 120/120 out, keyframes exactly where asked (with SPS, PPS), slices only, one decoded size; 8146 → 2214 bytes a frame after the rate change |
| Keys | `Typed as keysyms: Hello @#~ {}` + Return into gnome-text-editor, exactly (shifted symbols included) |
| Paste | `hello from the phone, café 中文` into gnome-text-editor (XWayland clipboard + Ctrl+V) |
| Super tap | Activities opened; Escape closed it |
| Pointer | relative 6-pt steps in a square read back from the cursor meta; `move_to(0.5, 0.5)` read back as (0.5, 0.5) |
| Cursor shape | 24×24 pt PNG (452–725 bytes) with its hot spot, sent only when it changed (arrow → I-beam) |
| Real host + test phone on a Mac, over a relay on the VM | 116/116 H.264 frames at 1280×720 in 12 s, decoded by ffmpeg |
| Real host + test phone on a Mac, direct UDP (Singapore VM ↔ the Mac's NAT) | 98 frames at 1280×720 in 12 s, 2 keyframes (11 asked), none dropped, decoded by ffmpeg. Before `phone.rs` asked for keyframes as the iOS app does, one lost piece of the first keyframe left it with nothing. Plain UDP from the VM to the Mac passed at every size from 200 to 1472 bytes, and in bursts of 100 |
| The desktop app (apps/desktop/src-tauri) on 26.04 | `cargo check` and `cargo build` pass with the backend in (one old warning, `mic.rs`) |

Screenshots: `promo/cases/remote-linux/` (the dialog, the streamed terminal, typed and pasted text, the overview, frames
decoded on the phone side).

## Testing

- Any OS: `cargo test` runs the pure parts: key table against RemoteKeys.swift, modifier order, text plan, crop / scroll /
  pointer math, mirror, Annex B → AVCC.
- Linux with GStreamer: the same, plus the encoder tests (real x264 + avdec_h264).
- Docker: `crates/blurt-remote/ci/linux/run.sh` (Ubuntu 26.04: check, clippy `-D warnings`, tests). Not run to the end
  here: the image's apt install failed with 404s through this machine's proxy. The VM ran the same checks natively.
  Headless GNOME in Docker wasn't tried, because a real desktop was available.
- A real desktop: `cargo run --release --example linux_smoke -- --seconds 10 --type "text" --overview` in the user's
  session (it prints portal and start times, fps, kbit/s, frame age, pointer, cursor shape, and writes an `.h264`).
- The whole host: `cargo run --release --example host -- --real --port 47321` and pair a phone with the printed link.

## For the app

The app calls `blurt_remote::platform::backend()` (remote.rs). On Linux, before that, it should call:
`platform::linux::set_state_dir(blurt_home/portal)` (the token next to the app's own), `set_dialog_parent(island xid)` (so
GNOME's dialog opens in front, as for paste), and `set_paste(|t| insert…)` (the dictation insert, which knows terminals). The
`.deb` needs `gstreamer1.0-plugins-base/-good/-ugly` (x264), `gstreamer1.0-plugins-bad` (VA), and `libpipewire-0.3-0`.

## Open

- Not tried: a GPU (VA / NVENC paths, their property names), HiDPI / fractional scaling (logical vs pixel sizes are handled
  but unmeasured), KDE, an X11 session, multiple monitors (the portal picks one; the user chooses it in the dialog).
- Scrolling wasn't verified on screen: the test pointer wasn't over a scrollable view.
- IBus detection reads GNOME's settings; other desktops' input methods aren't detected.
- The libei path (`ConnectToEIS`) would avoid one D-Bus round trip per event; the portal calls are queued and coalesced instead.
