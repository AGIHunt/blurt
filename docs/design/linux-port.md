# Linux: Blurt on Ubuntu 26.04 GNOME (Wayland) — design and first build (2026-11-05)

Issue #34 asks for Ubuntu 26.04. The Tauri app already builds for Linux, but dictation, voice notes and Copy Text are
`#[cfg(windows)]`, and recording uses `x11grab`. Ubuntu 25.10 dropped the GNOME Xorg session, so 26.04 is Wayland
only: no global key hook, no `SendInput`, no foreground-window API, no window positioning, and `x11grab` sees only
XWayland windows. This doc measures each replacement on a real 26.04 GNOME desktop and picks one; §Built says what
the first build changed and what it was tested on.

## Answers

- **Dictation key: the GlobalShortcuts portal by default, evdev as an opt-in for right Alt alone.** The portal gives
  press *and* release for normal keys and combos, so tap / hold / double-tap work. It can't bind a modifier alone:
  `Alt_R` fires once on press, never releases, and then breaks the app's other shortcuts. Right Alt alone needs
  `/dev/input` (the `input` group), which is a system-wide key reader, so it stays an explicit choice.
- **Typing the text: the RemoteDesktop portal.** Its keyboard sends Ctrl+V (Ctrl+Shift+V in terminals); the text goes
  on XWayland's clipboard (built that way — the portal's Clipboard interface was the plan, §Built says why not). One system dialog, then a restore token: no dialog again. CJK
  works. Typing characters as keysyms drops everything non-Latin-1, so it's not used.
- **Which app a take goes into: AT-SPI.** Focus events give the app, pid, role (`terminal`, `text`,
  `password text`) and the text before the caret, on Wayland. Firefox / Chromium / Electron only join when
  accessibility is on at their launch, so Blurt turns `org.a11y.Status.IsEnabled` on, as Orca does.
- **Mic: cpal as it is.** ALSA's `default` goes to PipeWire through `pipewire-alsa`. No code change beyond the cfg.
- **Recording: ScreenCast portal → PipeWire → `gst-launch-1.0 pipewiresrc` → raw frames → ffmpeg.** ffmpeg 8.0 on
  26.04 has no PipeWire input. One dialog, then a restore token.
- **Snaps and Copy Text: the Screenshot portal.** Its permission dialog only shows while Blurt is the focused app, so
  onboarding asks for it with Blurt's window in front. After that, 0.33 s per shot from the background.
- **Overlays (island, cards, picker, note): run the app under XWayland** (`GDK_BACKEND=x11`). Native Wayland
  centres the island and ignores keep-above. Under XWayland it sits where we put it, stays on top and takes no focus,
  which is what `blurt-capture`'s overlay code already assumes on Linux.
- **OCR and speech: unchanged.** RapidOCR (`screen_ocr.py`) and sherpa-onnx are the same Python code as on Windows.
  Polish is cloud-only, as on Windows; the key goes in the Secret Service instead of Credential Manager.

## Test rig

GCP `ordo-platform`, asia-southeast1-b, n2-standard-8 (8 vCPU Cascade Lake, 32 GB), image
`ubuntu-2604-resolute-amd64-v20261104a` (26.04.1, kernel 7.0), `--enable-display-device`, `ubuntu-desktop-minimal`.
GDM auto-logs in a test user into a real GNOME 50.1 Wayland session on the virtual display (1920×1080, llvmpipe).
Versions: mutter 50.1, xdg-desktop-portal 1.21.1, xdg-desktop-portal-gnome 50.0, PipeWire 1.6.2, WirePlumber 0.5.13,
WebKitGTK 2.52.6, ffmpeg 8.0.1, IBus 1.5.34.

Driving it: a uinput keyboard and a uinput tablet act as the user's hands (they go through libinput like real
devices); a test-only Shell extension sets `unsafe_mode` so `org.gnome.Shell.Screenshot` and `Eval` work over SSH.
Portal probes are small Python/Gio scripts that register the host app id `dev.blurt.desktop` through
`org.freedesktop.host.portal.Registry` (the dialogs then say "Blurt"). Scripts: the session notes folder, `rig/`.

Portal versions on 26.04: GlobalShortcuts 1, RemoteDesktop 2 (device types 7), Clipboard 1, ScreenCast 5,
Screenshot 2, InputCapture 1. mutter has **no** `ext_data_control` / `wlr_data_control`, so `wl-copy` style
clipboard tools don't work in the background.

## The dictation key

| Way | Right Alt alone | Combo / single key | Press + release | Other keys (Esc, Shift, Ctrl) | Setup |
|---|---|---|---|---|---|
| GlobalShortcuts portal | ✗ fires once, no release, then the app's other shortcuts stop | ✓ | ✓ press, repeats every 30 ms after 0.5 s, release | only keys bound as shortcuts | one dialog, remembered |
| evdev `/dev/input` | ✓ | ✓ | ✓ < 1 ms | ✓ every key | user in `input` group + log out/in |
| IBus engine | – | – | – | only while Blurt is the active input method | replaces the user's IME |

Portal, measured (F9, Shift+Alt+R, Menu, Escape bound by `dev.blurt.desktop`): `Activated` arrives at the press,
then again every 30 ms while held (auto-repeat, must be deduplicated), `Deactivated` at the release; event time vs the
key's own time within 2 ms. The first `BindShortcuts` shows GNOME's "Add Keyboard Shortcuts" dialog listing every
shortcut with its key (the user can change them there, and later in Settings → Apps → Blurt); later sessions bind in
9–150 ms with no dialog. Alt+Space never reaches the portal: it's GNOME's window menu.

evdev, measured: without the `input` group the user can't open any keyboard; with it, every key of every keyboard,
read < 1 ms after the kernel's timestamp. Devices come and go (USB, Bluetooth, our own uinput rig), so the reader has
to watch for new ones. It only reads — the key still reaches the app in front. **A lone right-Alt tap opens Firefox's
menu bar** (checked), the same problem Windows had; the fix is the same idea: when the key is used alone, send a
harmless key through the RemoteDesktop session while Alt is still down so the app sees "Alt + something".

**Decision.**
- Default: a portal shortcut, tap or hold, through the same `DictationTrigger` as the Mac/Windows. Suggested key:
  **Menu** on keyboards that have one (a single key next to right Alt, press/release measured), else Ctrl+Alt+Space;
  the user can pick another in GNOME's dialog. Everything inside a take that needs other keys (double-tap ⇧ / ⌃ to
  switch style, Esc to cancel) comes from evdev when it's on; in portal mode Esc is a second, short-lived portal
  session bound only to Escape for the length of a take (measured: Escape binds and reports press/release), and the
  double-tap modifiers are not available — the island's buttons do the same.
- Opt-in "Use right Alt alone": Settings explains that it lets Blurt read the keyboard, runs
  `pkexec usermod -aG input $USER`, and asks for a log out/in. Then evdev drives the trigger exactly like
  `keys_win.rs` does (sided key codes mapped to the VK codes `trigger.rs` already speaks).
- `DictationTriggerTests` stay the spec; the Linux key sources only produce `Event::Key` / `Event::Tick`.

## Putting the text in

| Way | gedit | Ptyxis (terminal) | CJK | Focus taken | Setup |
|---|---|---|---|---|---|
| RemoteDesktop: Clipboard + Ctrl+V keycodes | ✓ | ✓ with Ctrl+Shift+V | ✓ | no | one dialog, restore token |
| RemoteDesktop: keysyms | Latin-1 only (`abc-é-中文` → `abc--`) | – | ✗ | no | same |
| Native Wayland GTK clipboard (unfocused) | ✗ silently ignored | – | – | – | – |
| XWayland GTK clipboard (unfocused) + any Ctrl+V | ✓ | – | – | no | needs a key sender too |
| AT-SPI `EditableText.InsertText` | GTK text views only | ✗ (terminal isn't editable) | ✓ | no | none |
| uinput (ydotool) Ctrl+V | ✓ | ✓ | (clipboard still needed) | no | `input` group |

RemoteDesktop, measured: `CreateSession` 3 ms, `SelectDevices` 1–4 ms, `Start` 8 ms with a restore token (first time:
the dialog), `SetSelection` 1 ms, Ctrl+V 2.5 ms; the target app pulls the text through `SelectionTransfer` right after
the keys. Plain Ctrl+V in Ptyxis pastes nothing (bash reads it as quoted-insert); Ctrl+Shift+V works. Each `Start`
returns a new single-use token; we keep the latest.

GNOME's dialog is titled only "Remote Desktop", has **"Allow Remote Interaction" off by default** and "Allow Clipboard
Access" on, and a "Remember This Selection" box. If the user clicks Share without turning interaction on, `devices` is
0 — onboarding must check and explain. While a session is open GNOME shows an orange "remote" chip in the top bar; it
goes away when the session closes.

**Decision.** Open a RemoteDesktop session at the take's key-down (8 ms with the token), close it after the paste. The
orange chip then shows while Blurt is listening, like a recording light, and never sits there idle. Text goes in
through the clipboard (saved first and put back afterwards, the way Windows does), then Ctrl+V, or Ctrl+Shift+V when
the take's app is a terminal. (Planned through the portal's Clipboard; built on XWayland's — §Built.)

## Which app the take goes into

The Mac and Windows only paste into the app the take started in, read the field before the caret for polish, and hold
the text in password fields. On Wayland only AT-SPI gives any of this to an app. Measured, from focus events
(`object:state-changed:focused`), 10–20 ms after Alt+Tab:

| App | AT-SPI says |
|---|---|
| Ptyxis | app `ptyxis`, pid, role `terminal`, Text with the screen before the caret, not editable |
| GNOME Text Editor | role `text`, editable, EditableText + Text, caret, text before it |
| zenity `--password` | role `password text` |
| Firefox (default) | nothing |
| Firefox after `org.a11y.Status.IsEnabled = true` and a restart | app `firefox_firefox`, pid |

**Decision.** Blurt sets `IsEnabled` at first run (apps started later expose themselves; Chromium/Electron get a bit
slower with accessibility on — to measure with VS Code in the build round) and keeps a focus listener running. The take
records the focused app/pid/role at key-down; delivery compares with the focus at paste time. When nothing is known
(an app without accessibility), it pastes with Ctrl+V and doesn't claim to know the app. Terminals by role
`terminal`, or by app name for ones that don't speak AT-SPI (kitty, Alacritty, WezTerm, Ghostty: table in `apps.rs`).

## Mic

cpal 0.16 sees one host (ALSA) with devices `default` and `pipewire`; `default` goes to PipeWire's default source.
Measured with a virtual source playing speech: first samples 32 ms after `play()`, 4.01 s of audio for 4 s, 44.1 kHz
stereo float (the existing resampler takes it to 16 kHz mono). The device to use is chosen in GNOME Settings → Sound,
so Blurt shows that name (from PipeWire) and doesn't offer its own picker. ALSA prints "Unknown PCM pulse/jack/oss"
on stderr while enumerating — cosmetic, silenced with `snd_lib_error_set_handler`. GNOME has no mic permission for
host apps (only Flatpak), so there is nothing to ask.

## Recording

ScreenCast (monitor, cursor embedded, `persist_mode` 2): the first `Start` shows "Blurt wants to share your screen"
with the monitor list and "Remember this selection"; with the token, `Start` takes 17 ms, no dialog. Then
`OpenPipeWireRemote` gives a fd; `gst-launch-1.0 pipewiresrc fd=… path=<node> ! videoconvert ! videorate !
video/x-raw,format=I420,framerate=30/1 ! fdsink` pipes raw frames to ffmpeg (`-f rawvideo`, libx264 veryfast).
Measured 1080p: 293 frames in 9.77 s at a steady 30 fps; ffmpeg ~1.1 cores, gst-launch ~0.1 core. The first frame
arrives ~0.9 s after start, so the countdown has to cover it and the A/V clock starts at the first frame, not at
`Start`. GNOME shows its screen-share chip while recording, and it is in the video (top-right corner).

Overlays can't be hidden from the capture on Linux (no `WDA_EXCLUDEFROMCAPTURE`); `region.rs` already keeps the bar
outside the recorded area on Linux. A region is a crop of the monitor stream.

**Decision.** The app does the portal (ashpd `screencast`) and hands the fd and node to `record.py` (`--pw-fd`,
`--pw-node`); `record.py` runs gst-launch → ffmpeg instead of `x11grab` when it gets them. gst-launch and the PipeWire
plugin come with the Ubuntu desktop (to confirm on the fresh VM); the .deb depends on them and on `ffmpeg`.

## Snaps and Copy Text

Screenshot portal, `interactive=false`: the first call fails with "Only the focused app is allowed to show a system
access dialog" unless Blurt is the focused app; once allowed (stored in the permission store under `screenshot`), each
shot takes 0.33 s and returns a PNG in `~/Pictures` (Blurt moves it into the session and deletes the original). The
picker then works on that still, as on Windows. Copy Text uses the same still and the existing RapidOCR path.

## Overlays

A GTK window with the island's settings (undecorated, keep-above, no focus, skip taskbar) moved to (780, 40):

| Backend | Where it ended up | Keep above |
|---|---|---|
| Wayland | (813, 526) — centred by mutter | no |
| XWayland | (780, 40) | yes, and no focus taken |

**No island at rest (founder, 2026-11-05).** On the Mac the island fills the notch, space the screen doesn't use
anyway. Ubuntu has no notch: the top-centre spot is GNOME's clock and the top bar, so a resting island covers them.
On Linux (and, to decide separately, Windows) the island shows only while something is happening: listening,
recording, a voice note, cards just captured. Then it goes away. What it shows at rest (project, jobs, sessions that
need you, the review count) lives in the tray menu and the main window.

**Windows too, and a switch (2026-11-11).** A Windows user kept clicking the cards' count ("□ 2") and the top edge's
6 px hot strip while reaching for a maximized browser's tabs. Windows and Linux now share one setting, General →
"Show the island at the top when idle" (`app.island_idle`, the Mac's key; island.rs `shows_at_rest`), off by default
there (the Mac keeps it on: its top is the menu bar). Off: the cards' count and Peep thinking over an organize stay
out of the ears; the top strip takes no clicks and the pointer at the top edge brings nothing out (overlay.rs
`set_peek`, island.ts `quietAtRest`). Live things still show: recording, dictation, a voice note, a card flying in,
a done moment, a toast. Hanging cards: the tray's Show cards, the cards key and the main window's notice. On: as
before.

**Decision.** `GDK_BACKEND=x11` for the whole app on GNOME Wayland, set before GTK starts (lib.rs, next to the
DMA-BUF workaround). The island appears only for activity now, but that pill and the cards still need a fixed
position and keep-above, which only XWayland gives. Portals, AT-SPI and PipeWire don't care which backend the window uses. Risk to check: XWayland
windows are blurry at fractional scaling (125 %/150 %) unless mutter's `xwayland-native-scaling` is on.

## Onboarding on Linux

Four system dialogs, each asked where it makes sense, with one line of ours before it:
1. Add Keyboard Shortcuts (first run): the dictation key and the record / snap / voice keys.
2. Remote Desktop (first run): "turn on Allow Remote Interaction — Blurt only uses it to press paste". Checked.
3. Screenshot (first run, Blurt's window in front).
4. Share Screen (first recording).
Plus the optional right-Alt step (input group, log out/in).

## Built (2026-11-05, branch feat/linux-port)

What changed from the plan once it ran:

- **Clipboard: XWayland's, not the portal's.** The app runs under XWayland anyway, and an X client sets the clipboard
  without focus (measured above). The portal's `RequestClipboard` failed with "Invalid state" in the app; dropping it
  leaves the RemoteDesktop session for the keys only, and GNOME's dialog loses its clipboard switch.
- **The Remote Desktop dialog has to be parented — to the island.** Started from a take, GNOME opened it *behind*
  the app in front (no focus, no parent) and the take waited on it unseen. Blurt can't bring its own window forward
  either: right after the user typed elsewhere, GNOME's focus-stealing prevention only shows "Blurt is ready". Given
  the island (an always-on-top X11 window) as its parent (`x11:<xid>`), the dialog comes up in front. So a take never
  waits on it: until access is given the text is copied ("Copied · paste with Ctrl+V. Let Blurt type it for you:
  [Allow typing]"), and the first such take of a run asks at once, over the island; the dialog shows only "Allow
  Remote Interaction". The Share Screen dialog is parented to the island the same way.
- **The working directory is `~/.blurt`.** uv reads the directory it runs in (a project's `.venv`, a pyproject);
  started from a terminal inside some project, or a folder it can't read, every script failed.
- **The portals find the app by a desktop file named after its id.** The .deb ships a hidden
  `dev.blurt.desktop.desktop` next to `Blurt.desktop`.
- **The island takes clicks through an X input shape.** Under XWayland an X client learns the pointer's position
  only while it is over one of its windows, so the polling click-through (Windows) never saw the pointer coming. The
  island's drawn rects become its input shape instead (`overlay.rs input_shape`); tao's own click-through must not be
  called on Linux (it replaces the shape, and on a window not yet shown it panics — `chrome.rs` hit that).
- **WebKitGTK drops a click whose element was redrawn** between press and release (WebView2 sends it to the common
  ancestor). The island treats a press and release on the same action as the click.
- **The portal repeats Activated every 30 ms while a key is held**, and on a separate stream from Deactivated: a
  repeat can arrive after the release. Repeats are dropped, and an Activated not newer than the last release is
  stale. (Before, holding Shift+Alt+R would have started and stopped a recording many times.)
- **Recording:** one gst-launch per take; record.py relays its raw frames to each segment's ffmpeg (stdin) and keeps
  the latest for snaps — a PipeWire remote serves one client, so a resume can't open a second gst on it.
- **`libportaudio2` isn't on a stock 26.04 desktop** (record.py's mic): the .deb depends on it, with ffmpeg, python3
  (uv's wheel is unpacked with `python3 -m zipfile`; GNU tar can't read zip), gstreamer1.0-tools / -pipewire and
  pipewire-bin (pw-play for the sounds).
- **The Linux build of `main` didn't compile:** tauri-plugin-deep-link 2.6.2 against rust-ini 0.21.3 (Linux-only
  code). 2.6.3 fixes it.

Tested on the VM (GNOME 50.1 Wayland, a virtual mic playing a recorded take, uinput keyboard/tablet as the user):

| Case | Result |
|---|---|
| Dictation key (Menu, portal) held, speech, released → gedit | typed "这个feature下周上线。" (Fun-ASR-Nano, local) |
| Same into Ptyxis | `echo 这个feature下周上线。` typed with Ctrl+Shift+V and ran |
| First take before access | copied, Ctrl+V pasted it; "Allow typing" → dialog over Blurt → next take types |
| Voice note (Shift+Alt+V, again to stop) | card filed, said "这个feature下周上线。" |
| Recording (Shift+Alt+R, drag 1200×800, Shift+Alt+S) | 11.3 s video at the area, 11.1 s audio, A/V offset −0.16 s, transcript right |
| Rust tests | 244 pass (`cargo test --lib`; `tests/session.rs` doesn't compile on main either) |
| .deb on a fresh 26.04 desktop VM | `apt install ./Blurt_1.0.12_amd64.deb` 22 s (pulled ffmpeg, libportaudio2; the rest is on the desktop); Welcome; uv + Python fetched on first run; SenseVoice for the first minutes; first take copied + dialog over the island; allowed; next take typed into gedit |

**Which Linux (2026-11-09): Ubuntu 24.04 or later, Debian 13 or later** (Fedora 40 or later for the rpm). The packages are
built on ubuntu-24.04 (desktop.yml), because Blurt Remote's PipeWire crates don't build against 22.04's PipeWire 0.3.48. So
they need glibc 2.39: the deb depends on `libc6 (>= 2.39)` and the rpm on `libc.so.6(GLIBC_2.39)(64bit)`. The AppImage needs
the same, unchecked. Details in [remote-linux.md](remote-linux.md) §Which Linux.

Packages: `Blurt_1.0.12_amd64.deb` 8.1 MB, `Blurt_1.0.12_amd64.AppImage` 94 MB (built on the VM with the Tauri CLI;
the AppImage wasn't run — it has no system desktop file, so the portal dialogs won't name Blurt).

Code: `dictation/keys_linux.rs` (evdev + portal), `dictation/insert_linux.rs` (RemoteDesktop keys, X11 clipboard,
AT-SPI), `dictation/secret_linux.rs` (Secret Service), `capture/portal_linux.rs` (ScreenCast), record.py
`PipeWireFeed`; engine / voice / snap_voice / mic behind `cfg(dict)` (Windows or Linux, build.rs).

## Not done or not measured yet

- Snaps and Copy Text through the Screenshot portal (the still for the picker; `screen_text` is still Windows-only).
- Evdev mode end to end in the app (measured standalone; the app was tested in portal mode), the right-Alt opt-in step
  in Settings, Esc during a take in portal mode.
- Onboarding: the Remote Desktop / Screenshot steps in the Welcome (today: "Allow typing" on the first take).
- Shortcut labels show the portal's raw text ("Press <Shift><Alt>a"); the Welcome shows "Not set" in portal mode;
  GNOME's "Add Keyboard Shortcuts" dialog opens behind the Welcome (parent it to the main window).
- The island's toast button by mouse under XWayland: hovering the toast can open the island before the click lands
  (seen with the test rig's pointer; "Allow typing" is also asked by itself, so dictation doesn't depend on it).
- Tips that need keys the portal doesn't give ("Double-tap Shift…") still show.
- No resting island (founder, above): not changed yet.
- VS Code / Chromium with accessibility on, fractional scaling under XWayland, a real microphone, AltGr layouts, KDE.
