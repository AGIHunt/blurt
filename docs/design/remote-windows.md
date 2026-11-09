# Blurt Remote on Windows

2026-11-09. Windows as the host for Blurt on the phone: the same wire as the Mac ([remote-protocol.md](remote-protocol.md)), with the
screen, encoder and input of Windows 10 1903+ and 11. Why it works the way it does: [remote.md](remote.md).

## Windows backend

`crates/blurt-remote/src/platform/windows`, the contract in `host.rs`. The pure parts build on every OS and are unit-tested on the Mac
(`cargo test platform::windows`): key tables, the bitstream, geometry, key and click bookkeeping, the wheel, frame pacing, cursor pixels.

### Screen

```
monitor under the pointer ─ Windows.Graphics.Capture (BGRA texture, no cursor, no border where allowed)
        │                    └ DXGI Desktop Duplication where WGC isn't there
        ▼
held copy of the whole monitor (GPU) ── a crop change, refresh() or keyframe() is made from it at once
        ▼
D3D11 video processor: crop rect → output size, BGRA → NV12 BT.709 limited (ring of 4)
        ▼
Media Foundation encoder: hardware MFT (NVENC / Quick Sync / AMF …), async, reading the texture through the DXGI device manager
        │                  └ Microsoft's software H.264 MFT, at most 1280 on the long side, NV12 read back to memory
        ▼
Annex B → 4-byte length-prefixed NAL units, VPS / SPS / PPS apart on keyframes (annexb.rs) → EncodedFrame
```

- **One worker thread owns every D3D11, WinRT and MF object.** The `Screen` the server holds only sends it commands, so it is `Send`
  whatever COM is, and it is per-monitor DPI aware on that thread whatever the app is.
- **Output size:** the monitor's shape, as large as the phone asked, never more pixels than the monitor has, even numbers (as the
  Mac). It stays the same for the stream; a crop is only a source rectangle for the next blit, so up to 7 crops a second cost nothing.
- **Crops land on the next frame.** The Mac waits for ScreenCaptureKit to take a new source rect; here the whole monitor is held on the
  GPU, so a crop change is drawn from it at once, even on a still screen. Each frame carries the crop it shows, rounded to the source
  pixel it really starts on (whole stays exactly whole: the phone keeps that frame as its backdrop).
- **A still screen sends nothing.** WGC and Duplication only give a frame when the monitor changed. Dirty regions (Duplication always,
  WGC from Windows 11 24H2) skip changes outside the crop. Without them the new NV12 output is read back and compared byte for byte
  with the last one sent, as the Mac does. `refresh()` re-encodes the held picture (the encoder sharpens it); `keyframe()` forces an IDR.
- **Encoder settings**, as VideoToolbox on the Mac: `CODECAPI_AVLowLatencyMode` (one in, one out), no B-frames, CBR at `bitrate`
  with a one-second buffer and a 2× peak, a GOP of 1,000,000 frames (or 600 seconds where refused) with
  `CODECAPI_AVEncVideoForceKeyFrame` on request, one slice, quality-vs-speed 33. H.264 High (Main where refused), HEVC Main. Bitrate
  changes go to `CODECAPI_AVEncCommonMeanBitRate` while streaming. The media type's frame rate can't change mid-stream, and the rate
  control spends per frame by it. So when `set_rate` lowers fps, the mean is scaled by `type_fps ÷ fps` (at most 8×), and each frame
  still gets `bitrate ÷ fps`. On the Mac VideoToolbox does this from timestamps.
- **Codec:** the first of the phone's `codecs` with a hardware encoder; else software H.264 if the phone takes H.264. Old phones send
  no list, which means HEVC only. On a PC without a hardware HEVC encoder they get "This PC has no video encoder for the phone's
  formats", since Windows has no software HEVC encoder.
- **Clock:** `now()` and `captured` are QueryPerformanceCounter seconds, the clock of WGC's `SystemRelativeTime` and DXGI's
  `LastPresentTime`.
- **Numbers:** `WinScreen::take_stats()` (fps, encode ms, convert ms, kbps, keyframes, skipped). `BLURT_REMOTE_LOG=1` logs the setup
  and errors to stderr.

### Input

- **Keys:** `SendInput`. Letters, digits and punctuation go as US-layout scan codes alone (`KEYEVENTF_SCANCODE`), as the Mac's kVK
  codes are positions, so on AZERTY the wire's "Q" types A, as that physical key would. Navigation keys go as VK + scan code +
  `KEYEVENTF_EXTENDEDKEY` (arrows, Home, End, PgUp, PgDn, Delete, Insert, Win): without it, games and apps that read scan codes see the
  keypad. Modifiers: command → left Win, control → left Ctrl, option → left Alt, shift → left Shift, down in that order and up in
  reverse. Function does nothing.
- **Never stuck:** a modifier is down while anything holds it (sticky, a held chord) and comes up with the last one. `release_all` lets
  go of buttons, held keys and modifiers, and is safe twice. A lone Win tap opens Start, as a real one does. A Win or Alt held
  through a click or a scroll gets the mask key (VK 0xE8, as the desktop app's dictation key) before it comes up, so Start doesn't
  open and the menu bar doesn't take focus.
- **Text:** `KEYEVENTF_UNICODE`, surrogate pairs as their two units, newlines as Return. Longer than 64 UTF-16 units, or while an
  IME is on in its own script (`ImmGetDefaultIMEWnd` + `IMC_GETOPENSTATUS` / `IMC_GETCONVERSIONMODE` native), it is pasted
  instead. The clipboard is saved first. Ctrl+V goes by VK, so it is V on any layout, with held Win / Shift / Alt let go around it.
  The clipboard is put back after 600 ms, unless more text came or someone copied since. This is the desktop app's insert_win.rs
  paste, copied in clipboard.rs because this crate can't depend on the app.
- **Pointer:** absolute moves over the virtual desktop (`MOUSEEVENTF_VIRTUALDESK`). The position is kept in physical pixels with its
  fractions, so "Enhance pointer precision" doesn't bend the phone's own curve a second time. A relative move uses the scale of the
  monitor it starts on, so mixed-DPI desks move evenly, and it is clamped to the nearest monitor edge. A real mouse moved more than
  3 px takes over. Buttons carry the position in the same event, so a click lands where the pointer was just put.
- **Double clicks:** Windows counts them itself (`GetDoubleClickTime`, `SM_CXDOUBLECLK`). When the server sends `clicks ≥ 2` and the
  second press is outside the system's box (within 64 px), it is put back on the first. When it comes later than the system's time
  (Wi-Fi), the event gets a time stamp just after the first click's release. Unit-tested; not yet checked on a real desktop.
- **Wheel:** points → wheel units at `120 ÷ (lines × 100/3)` (SPI_GETWHEELSCROLLLINES, 3 by default), 1.2 units a point, so content
  in browsers moves with the finger. High-resolution: whole units that aren't multiples of 120, with the fractions carried over.
  Positive dy → positive WHEEL (up), positive dx → negative HWHEEL (left). Windows has no global direction setting for wheels, so
  there is nothing to honour.
- **System moves:** Win+Tab (all windows, and app windows: Windows has no per-app view), Ctrl+Win+← / → (desktops), Ctrl and the
  layout's own + / − (zoom), Find Pointer = a Ctrl tap when "Show location of pointer" is on.
- **Pointer position:** `GetCursorPos` → 0…1 of the monitor being shown. **Shape:** `GetCursorInfo`, on a new HCURSOR only:
  `GetIconInfo` → RGBA (alpha, AND mask, or monochrome AND/XOR where "invert" is drawn black with a white outline) → PNG, sizes and hot
  spot in points.
- **can_control** is false on the secure desktop (UAC prompt, lock screen: `OpenInputDesktop` fails), and while the window in front
  belongs to an elevated process and we aren't elevated: UIPI drops the input without an error. Task Manager is elevated for
  admins, so it counts. Cached for 300 ms.
- Every event carries `dwExtraInfo = 0x42524D54` ("BRMT", the Mac's marker). **The integrator needs to make** the desktop app's
  dictation hook (`dictation/keys_win.rs`, which already skips its own "BLRT") treat these as the Mac does: a tap on the pad must not
  count as a key joined to a push-to-talk.
- **Keep awake:** a power request (`PowerCreateRequest`, "Blurt: a phone is connected", system and optionally display), not
  `SetThreadExecutionState`, which belongs to whichever thread called it. `powercfg /requests` shows it.

### What's verified

On the Mac: 51 unit tests (key table against every wire name, modifier bookkeeping and the mask, Annex B with 3- and 4-byte start
codes, crop → pixel rect and its tag, output size, absolute coordinates over mixed-DPI desks with negative origins, relative moves,
wheel, double-click plans, pacing, cursor bitmaps). Real H.264 High and HEVC Main streams from brew's ffmpeg
(`testdata/make-streams.sh`) go to the wire's form and back, and ffmpeg decodes the round trip cleanly. (Since the session server
arrived, `cargo check --target x86_64-pc-windows-msvc` from a Mac needs a C compiler for that target: `ring`, through rustls, builds C.)

On Windows (blurt-win: GCP g2-standard-4, NVIDIA L4 with Google's GRID driver 596.86, Windows Server 2025 build 26100, an 800×600
console display on Microsoft's basic adapter plus a second 1280×800 one): `cargo build --release --examples`, `cargo test --release`
(the whole crate: 96 tests, the backend's 51 among them, pass) and `cargo clippy --release --all-targets` are clean natively.

### Measured (2026-11-09, blurt-win)

`examples/win_smoke.rs` at 12 Mbps / 60 fps asked, then 2 Mbps / 30 fps. "Encode" is from the frame going to the encoder to its
output; "convert" is the video processor's crop + scale + NV12 plus the read-back compare where it runs.

| Run | Encoder | Output | Whole: fps / encode / convert | 3× moving 7/s: crop shown after | 2 Mbps / 30 fps stage |
|---|---|---|---|---|---|
| synthetic, session 0 | NVIDIA H.264 MFT (L4) | 1920×1080 | 56.7 / 4.4 ms / 2.2 ms | p50 17.5 ms, max 24.8 ms (12/12) | 31.9 fps, 1.66 Mbps |
| synthetic, session 0 | NVIDIA HEVC MFT (L4) | 1920×1080 | 57.0 / 3.3 ms / 2.2 ms | p50 14.2 ms, max 16.1 ms (12/12) | 31.4 fps, 1.93 Mbps |
| synthetic, session 0 | Microsoft H.264 (software) | 1280×720 | 56.4 / 4.8 ms / 2.5 ms | p50 18.0 ms, max 26.0 ms (12/12) | 31.8 fps, 2.69 Mbps |
| real monitor (WGC), console | Microsoft H.264 (software)* | 800×600 | 30.4 (the console prints at 30 Hz) / 3.3 ms / 1.2 ms | p50 7.5 ms, max 11.7 ms (12/12) | 19.8 fps, 1.39 Mbps |

\* In the interactive console session the NVIDIA MFTs (H.264 and HEVC) fail `ActivateObject` with E_UNEXPECTED ("Catastrophic
failure") at any size, while the same MFTs work in session 0 (SSH) and from the same build. This VM's display is driven by
Microsoft's basic adapter, and the GRID driver is unlicensed: the likely cause. The backend then falls back to the software encoder
on its own, as it should. **A real desktop GPU driving its own monitor (NVENC, Quick Sync, AMF) is untested.**

- Streams: ffprobe reads H.264 High / HEVC Main, no B-frames, BT.709 limited range (the hardware encoder; Microsoft's software one
  writes no colour description), and ffmpeg decodes every file without an error. The real-monitor picture shows the console with no
  pointer in it and no yellow capture border (`IsBorderRequired = false` honoured on Server 2025).
- A still screen: 1.3–2 fps right after it stops (the last changes and the cursor's frames), then nothing; 15 of every 16 WGC
  frames on a still desktop with the pointer moving are skipped by their dirty regions. `refresh()` ×3: 18 KB, 49 KB, then 0.5 KB
  resends; `keyframe()`: one IDR within 300 ms.
- Rate: whole-screen stages stay under the asked rate (7.6 Mbps of 12 on scrolling text); a crop that jumps 7 times a second over
  scrolling text overshoots to about 16 Mbps of 12 with either encoder (each jump is a new picture): the one-second buffer lets it.
  A shorter buffer (0.5 s) is the knob if the network can't take it; untried.
- Age from capture to the encoded frame: p50 6 ms, p95 10 ms at 1080p whole (hardware); 14 ms when the read-back compare runs too.
- Input on the real desktop: 4 pt × 10 relative moves on a side of a square: 40 px, 39 px, 41 px, 39 px (a pixel off now and then:
  Windows' own rounding of absolute coordinates; fractions are kept here, so it doesn't add up). `can_control` true, the cursor's
  shape 32×32 pt PNG with its hot spot.
- `displays()`: in the console `\\.\DISPLAY1` 800×600 at 0,0 (main) and `\\.\DISPLAY2` 1280×800 at 800,0; in session 0 one
  "WinDisc" 1024×768.

End to end, the real host (`cargo run --release --example host -- --real`, in the console session through `schtasks /it`) and the
Rust phone (`examples/phone.rs`) on a Mac in another country, over the internet: pairing with the test yes, session with
`platform: "windows"`, both displays listed, UDP confirmed, cursor datagrams arriving, the screen on (WGC → software H.264 on
DISPLAY1), a key pressed (Ctrl+C reached the focused window). Found that way and fixed: an access violation in
`GraphicsCapture.dll_unloaded` after every stop (the worker's apartment was COM's last one, so the DLL went with a WGC callback on
its way; the MTA is now kept for the process, and FrameArrived removed before closing), and no first picture on a still screen (WGC
gives a frame only on a change; the first now comes from GDI). Not seen working there: video reaching the Rust phone (the first two
frames went before UDP was confirmed, and it asks for no keyframe), and following the pointer onto the second display (no new
`screenView` after 1,200 pt of moves to the right). The iPhone app in the simulator wasn't paired with it (see the report).

Several displays, again (2026-11-09; the host as above, `examples/phone.rs --cross` on the VM itself against 127.0.0.1, so no
firewall rule): follow, pin and unpin work on real Windows, with the backend and the server as they were. What stood in the way was
the test phone. It pressed Ctrl+C first thing, and on the VM the focused window is the console the host runs in: the host was
gone 30 ms after the screen was asked for (no crash in the event log; the phone just saw the connection close). And it could miss
the display list: the list could go out before `session` (the session's watch looks at the displays every 2 s, and `session` is
sent from a task of its own), `phone::pair` drops what comes before `session`, and an unchanged list isn't sent again. Now
`--cross` presses no key, starts at the left edge and crosses 2,400 pt at a time, and the server sends the list only after
`session`, as the Mac does (always so over the relay, where `session` waits on STUN). One run, 16 s, seen at the phone:

| Step | `screenView` |
|---|---|
| start, pointer at the left edge | DISPLAY1 800×600 at 0.44 s |
| 2,400 pt right (24 relative moves through SendInput) at 3.23 s | DISPLAY2 1280×800 at 3.45 s (stop + start: WGC on the other monitor) |
| pinned DISPLAY1 at 6.49 s | DISPLAY1 at 6.70 s |
| 2,400 pt right, pinned, at 8.86 s | none |
| following again at 12.01 s (the pointer on DISPLAY2) | DISPLAY2 at 12.38 s |

Each part decodes (ffmpeg, no errors) at its display's size and shows that display (the console on DISPLAY1, the desktop and
taskbar on DISPLAY2). Both monitors are at 100 % here: a second display at another scale is untried on Windows (geometry.rs's
tests cover the arithmetic).

```
cargo run --release --example win_smoke                  # the monitor under the pointer, hardware encoder
cargo run --release --example win_smoke -- --software    # Microsoft's software H.264
cargo run --release --example win_smoke -- --synthetic   # no desktop (a service, SSH = session 0): text-like rows at 1920×1080
```

## Firewall and network

The host listens on TCP (a fixed port, so the phone's saved address keeps working) and UDP (any free port), on all interfaces, only
after the owner clicks Add Phone, as on the Mac.

What Windows Defender Firewall does with this, for Blurt's **per-user** NSIS install (`installMode: currentUser`, no admin rights,
the exe under `%LOCALAPPDATA%\Blurt`):

- **Measured on Windows Server 2025** (firewall on for every profile, the network Public, no rule for the exe): the host listened
  and **nothing was shown**: no prompt, and connections from outside never arrived, until a rule was added
  (`netsh advfirewall firewall add rule … program=<host.exe> dir=in action=allow profile=any`). Server doesn't notify by default; the
  client editions below were not tried here.
- The first time the exe listens on a non-loopback address, Windows 10 / 11 shows "Windows Defender Firewall has blocked some features of
  this app" with Private checked and Public unchecked. Allowing it needs an administrator. A standard user gets a UAC credential
  prompt, an admin gets a UAC yes. That creates inbound allow rules for this exe path, TCP and UDP.
- **Cancel, or no admin at hand:** Windows silently creates inbound *block* rules for the exe (TCP and UDP) for that profile. The
  phone then never connects on the local network, and Windows doesn't ask again.
- **The network's profile matters:** a home Wi-Fi Windows filed as Public (the default for a new network unless the user said
  otherwise) isn't covered by the Private rule. That is the most likely "my phone can't find my PC".
- Rules are tied to the exe's path. An update in place keeps them; installing to another folder asks again.
- Outbound is allowed by default: the relay (WebSocket out) needs nothing, and the direct path's UDP hole punching opens from inside,
  so its replies come back through the stateful firewall without an inbound rule.
- Discovery: the system's own mDNS rule ("mDNS (UDP-In)") is on for Private networks; an in-app responder on 5353 would need its own
  rule as above.

So a prompt can't be relied on: the app (or an installer) has to add the rule itself. What it should add, exactly: one inbound
allow rule for Blurt's exe, TCP and UDP (no port: the UDP port is any free one), Private and Public profiles, removed on uninstall:

```
netsh advfirewall firewall delete rule name=all program="%LOCALAPPDATA%\Blurt\blurt.exe" dir=in
netsh advfirewall firewall add rule name="Blurt (phone)" dir=in action=allow program="%LOCALAPPDATA%\Blurt\blurt.exe" enable=yes profile=private,public
```

(the first line clears a block rule a cancelled prompt left). Both need an administrator once, through one UAC prompt.

What the app should do (proposed; what's done since is under **Implemented** below):

1. **Before listening for the first time** (Add Phone), say what's coming: "Windows will ask whether Blurt may accept connections from
   your phone. Choose Allow (Private networks)." The prompt then reads as expected, not as an alarm.
2. **Check, don't guess:** read the firewall's state through `INetFwPolicy2` (COM, no admin needed): the current profile, whether
   it's Public, and whether an inbound rule for Blurt's exe blocks or allows. If blocked, or the network is Public with no allow
   rule, say so in Settings → Phone (`RemoteStatus.problem`) with one button that runs, elevated through ShellExecute `runas` (one
   UAC prompt):
   `netsh advfirewall firewall add rule name="Blurt (phone)" dir=in action=allow program="<exe>" profile=private,public enable=yes`
   (after deleting any block rule for the same program). Also offer "This is my home network" (Settings → Network → Private).
3. **The installer stays per-user.** It can't add firewall rules without admin rights, and asking every user for admin rights at
   install time for a feature most never turn on would be wrong. An optional per-machine (admin) install could add the rule in
   `NSIS_HOOK_POSTINSTALL` with the same netsh line, and remove it in `NSIS_HOOK_POSTUNINSTALL`.
4. **When the phone can't connect on the local network but the relay works,** the phone should say so ("Connected through your relay:
   Windows' firewall may be blocking the local network") rather than nothing.

**Implemented (2026-11-09; apps/desktop/src-tauri/src/remote_firewall.rs, PhonePane.tsx):**

- **The check** (2): `INetFwPolicy2` through COM, no administrator: the active profiles (`CurrentProfileTypes`), whether the firewall is
  on in each, "block all inbound", the default inbound action, and every inbound rule whose program is this exe (`%VAR%`s expanded,
  case ignored). `RemoteStatus.firewall` is `"blocked"` when any active profile with the firewall on blocks the exe's TCP or UDP, or
  has no rule allowing both (inbound defaults to block); `"ok"` otherwise; `"unknown"` when COM couldn't read it. It runs when the
  host starts listening, when Settings shows the code, and when the network's profile changes (the profile types polled every
  10 s while listening). Not through `problem`: a field of its own, so the pane can put the button with it.
- **The fix**: `remote_allow_firewall`, only from the button. One `cmd.exe /d /s /c "<the two netsh lines above>"`, started with
  `ShellExecuteExW` and the `runas` verb (Windows' own UAC prompt), hidden, waited for (up to 2 min), then the check again. Declined:
  still `"blocked"`, no error. An exe path with `" & | ^ < > %` in it isn't put on a command line (nothing runs; logged).
- **Settings → Phone**: "Windows Firewall is blocking phones on this network." / "Windows 防火墙挡住了这个网络上的手机。", the line
  that Windows will ask for an administrator's permission, and **Allow…**, above the pairing area (`?phone=firewall` in the browser
  stand-in).
- **Uninstall** (3): the per-user uninstaller isn't elevated, so `NSIS_HOOK_POSTUNINSTALL` (installer/hooks.nsh) looks for the rule
  (`netsh … show rule name="Blurt (phone)"`, no rights needed) and only if it's there deletes it through one UAC prompt
  (`ExecShellWait runas`). Never in a silent run (updates): the rule still fits the same exe path. Declined: the rule stays, pointing
  at an exe that's gone. The hook compiles with makensis 3; the uninstaller hasn't been run on Windows.
- **On blurt-win** (Public profile, firewall on; the check built alone as a probe exe, run over SSH): no rule
  → `blocked` (21 ms); the fix's own command line run in the (already elevated) SSH session → one rule, In, Private,Public,
  protocol Any, program = the exe, Allow → `ok` (19 ms); a UDP block rule beside it → `blocked`; both deleted → `blocked`. The UAC
  prompt itself wasn't clicked (it shows in the console session, out of reach over SSH). Found there: a COM object released after
  `CoUninitialize` crashed the process (0xC0000005); the release order is explicit now.
- Not done: (1) the word before listening, "This is my home network", and (4) on the phone.
