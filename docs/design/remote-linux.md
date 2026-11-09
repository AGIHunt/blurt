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
- **Several monitors.** The portal is asked for several monitor sources. Each shared stream (its id, position and logical
  size) is a `Backend::displays` entry. Switching restarts the stream on the other monitor (`set_display` says no), which
  takes about 60 ms. A restore token from a one-monitor grant still opened with no dialog.
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
| The iPhone app (simulator on a Mac, H.264) ↔ the real host, direct UDP, its own screen test (`BLURT_SCREEN_TEST=display`, 12 s a stage) | Ubuntu's screen shown with the Linux keys (Ctrl / Super / Alt) and the pointer drawn from the cursor meta (I-beam). Round trip Mac ↔ Singapore 570 ms p50 (this Mac's network). Whole screen: 10 fps, 2.5 Mbit/s, frame age at decode p50 311 ms / p95 336 ms (≈ half the round trip + 20 ms), decode 4.2 ms, 2 frames dropped, 5 keyframes asked. 2× zoom: 10 fps, 2.2 Mbit/s, p50 312 ms, decode 3.5 ms. 3× zoom: 9 fps, 0.2 Mbit/s, p50 308 ms, decode 2.6 ms, nothing dropped |
| Scrolling | a 310-pt two-finger gesture at a steady speed (the test's, not a hand's) moved gnome-text-editor from line 1 to line 48 at the top, the right way. That includes GTK's own coast after the finish: the gesture ended at full speed |
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

The app calls `blurt_remote::platform::backend()` (remote.rs). On Linux, before that, `linux_setup` (remote.rs) calls:

- `set_state_dir($BLURT_HOME/portal)`: the restore token next to the app's own (`screencast.token`, `remote-desktop.token`).
- `set_dialog_parent`: the main window's X11 id at once (setup runs on the main thread), then the island's once it exists
  (it is made on a thread of its own a moment later; polled for up to 10 s). The island is always on top, so GNOME's dialog
  opens in front, as for dictation's access.
- `set_paste(linux_paste)`: dictation's own clipboard + Ctrl+V (Ctrl+Shift+V into a terminal, by AT-SPI's role or the app's
  name) on dictation's Remote Desktop session, and the user's clipboard back 0.8 s later unless they copied something since.
  When dictation has no access yet (no token: `insert_linux::has_access`), it returns false and the crate pastes its own way
  through the phone's session, so it never opens a second dialog.

Not run on a Linux desktop yet: the desktop app with this wiring type-checks and lints in Docker (Ubuntu 24.04, as CI), and
nothing more.

### Which Linux: Ubuntu 24.04 or later, Debian 13 or later

The Linux packages are built on Ubuntu 24.04 (desktop.yml), so they need **Ubuntu 24.04 or later, Debian 13 or later**
(glibc 2.39; Fedora 40 or later for the rpm). 22.04 can't build them: the `libspa` / `pipewire` crates (0.10) want PipeWire
1.0 headers, and 22.04 has 0.3.48 (`spa_meta_first`, `spa_meta_region_is_valid` and `spa_video_info_raw.flags` are missing;
checked in Docker). The Linux port targets 26.04 (issue #34), so the floor costs nothing that was promised. tauri.conf.json
makes it explicit: the deb depends on `libc6 (>= 2.39)` and the rpm on `libc.so.6(GLIBC_2.39)(64bit)`. The rpm is written
by name only, since Tauri's bundler passes each entry to `rpm::Dependency::any` and `glibc >= 2.39` would become a package
name. The AppImage has the same floor (glibc from the build machine), but nothing checks it.

### Packages (tauri.conf.json)

What the backend loads at run time, and where each piece is (checked with `apt-file` / `dnf repoquery`, 2026-11-09):

| Needs | Ubuntu 24.04 (noble) | Ubuntu 26.04 | Fedora 42 |
|---|---|---|---|
| appsrc/appsink, videoconvertscale | gstreamer1.0-plugins-base | same | gstreamer1-plugins-base |
| h264parse / h265parse (videoparsersbad) | gstreamer1.0-plugins-bad | same | gstreamer1-plugins-bad-free |
| x264enc | gstreamer1.0-plugins-ugly | same | not in Fedora (RPM Fusion's gstreamer1-plugins-ugly) |
| openh264enc (the fallback) | gstreamer1.0-plugins-bad | same | gstreamer1-plugin-openh264 (its libopenh264 from the fedora-cisco-openh264 repo, on by default in Workstation) |
| vah264enc / vah265enc (VA) | gstreamer1.0-plugins-bad | **gstreamer1.0-plugins-extra** (split out) | gstreamer1-plugins-bad-free, but Fedora's Mesa has no H.264/HEVC encode (RPM Fusion's mesa-freeworld) |
| libpipewire-0.3.so.0 | libpipewire-0.3-0t64, which provides `libpipewire-0.3-0` | same | pipewire-libs |

- **deb** depends: `libc6 (>= 2.39)`, `gstreamer1.0-plugins-base`, `-good`, `-ugly`, `-bad`, and `libpipewire-0.3-0`. That
  last one is the t64 package's virtual name on 24.04 / 26.04 and Debian 13; apt accepts it unversioned. It recommends
  `gstreamer1.0-plugins-extra`, which has VA on 26.04. 24.04 doesn't have it: apt skips it there, and -bad has VA.
- **rpm** depends: `libc.so.6(GLIBC_2.39)(64bit)`, `gstreamer1-plugins-base`, `-good`, `gstreamer1-plugins-bad-free`,
  `pipewire-libs`. It recommends `gstreamer1-plugin-openh264` and `gstreamer1-plugins-ugly`. Those are weak, so a machine
  without the Cisco repo or RPM Fusion still installs; dnf skips what it can't find. On stock Fedora the phone's screen is
  openh264, since x264 and VA encode come from RPM Fusion. The names are Fedora's; openSUSE's differ (`gstreamer-plugins-*`,
  `libpipewire-0_3-0`).
- A GPU's VA driver (mesa-va-drivers, intel-media-va-driver) isn't a dependency. Ubuntu's desktop installs Mesa's, and x264
  is the fallback without one.

### AppImage

`bundleMediaFramework` is false, so no GStreamer plugins are inside. But linuxdeploy copies every library the binary links
unless it's on its exclude list. WebKitGTK and this backend both link `libgstreamer-1.0`, `libgstbase`, `libgstapp`,
`libgstvideo` and `libpipewire-0.3`, so the AppImage carries the CI machine's copies (Ubuntu 24.04: GStreamer 1.24, PipeWire
1.0.5). On 26.04, GStreamer then loads the system's 1.28 plugins into a 1.24 core, and any built against newer symbols fail
to load: x264enc, VA or h264parse may show as "not installed". libpipewire 1.0.5 likewise loads the system's 1.6 SPA
plugins. Not checked on a machine yet. What it would need, in order of preference:

1. Leave GStreamer and PipeWire out of the AppImage, so the system's are used. That means linuxdeploy's
   `--exclude-library 'libgst*' --exclude-library 'libpipewire-0.3*'`, passed through the bundler's environment if Tauri
   allows it. Every desktop with WebKitGTK's media and PipeWire has these libraries, and GStreamer's ABI is stable going
   forward (WebKit built against 1.24 runs on 1.28). The AppImage then needs what the deb lists from the system.
2. Or `bundleMediaFramework: true`: GStreamer and its plugins from the build machine go inside (older encoders, a larger
   image, x264's GPL in the bundle), and PipeWire still comes from the system.

Until then the AppImage's phone screen is untested and probably limited; the deb is the supported way.

## Open

- Not tried: a GPU (VA / NVENC paths, their property names), HiDPI / fractional scaling (logical vs pixel sizes are handled
  but unmeasured), KDE, an X11 session.
- Taps on the iPhone simulator weren't available, so input from the iPhone app itself (rather than from the test phone and
  `linux_smoke`) is untested.
- Several monitors: listed from the portal and switched by restarting the stream. Tested with one monitor only.
- IBus detection reads GNOME's settings; other desktops' input methods aren't detected.
- The libei path (`ConnectToEIS`) would avoid one D-Bus round trip per event; the portal calls are queued and coalesced instead.
