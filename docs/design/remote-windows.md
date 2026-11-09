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

On the Mac, 51 unit tests: every wire key name against the table, scan codes checked by hand, no two keys alike; modifier order,
sticky / held / release_all, the mask; Annex B splitting with 3- and 4-byte start codes and emulation bytes. Real H.264 High and
HEVC Main streams from brew's ffmpeg (`testdata/make-streams.sh`, 60 frames, keyframe every 30) go to the wire's form and back,
and ffprobe decodes the round trip. Also tested: crop → pixel rect and the tag it carries, output size, absolute coordinates landing
on the pixel over mixed-DPI desks with negative origins, relative moves across monitors, wheel accumulation and direction, double-click
plans, frame pacing, cursor bitmaps. `cargo check` and `cargo clippy --all-targets --target x86_64-pc-windows-msvc` are clean.

On Windows (blurt-win, GCP g2-standard-4, NVIDIA L4, Windows Server 2025): see §Measured.

### Measured

Not yet: SSH to the test VM didn't come up (see the report). `examples/win_smoke.rs` writes the numbers:

```
cargo run --release --example win_smoke                  # the monitor under the pointer, hardware encoder
cargo run --release --example win_smoke -- --software    # Microsoft's software H.264
cargo run --release --example win_smoke -- --synthetic   # no desktop: text-like rows scrolling at 1920×1080
```

## Firewall and network

The host listens on TCP (a fixed port, so the phone's saved address keeps working) and UDP (any free port), on all interfaces, only
after the owner clicks Add Phone, as on the Mac.

What Windows Defender Firewall does with this, for Blurt's **per-user** NSIS install (`installMode: currentUser`, no admin rights,
the exe under `%LOCALAPPDATA%\Blurt`):

- The first time the exe listens on a non-loopback address, Windows shows "Windows Defender Firewall has blocked some features of
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

What the app should do (proposed, not done; the installer isn't changed here):

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
