# Blurt on the phone: the Rust host (Windows, Linux)

2026-11-09. The Mac host is Swift (`Sources/BlurtApp/Remote`); Windows and Linux run the same thing in Rust: `crates/blurt-remote`,
started by the desktop app (`apps/desktop/src-tauri/src/remote.rs`). Behaviour, product decisions and security rules are
[remote.md](remote.md)'s; the wire is [remote-protocol.md](remote-protocol.md). This page is only what's particular to the port.

## Shape

```
 phone ──TCP / relay WS──▶ channel.rs ─▶ server.rs (pairing, sessions, relay, watch) ─▶ input.rs ─▶ Backend::input()
       ◀──UDP datagrams──┘                         │                                 (thread of its own)
                                                    ├─▶ screen.rs (rate, packets, pacing) ◀─ Backend::screen() frames
                                                    └─▶ App (remote.rs): dictation, Blurt's commands, status, the yes
```

- **Policy here, pressing there.** What the Mac's RemoteInput decides is platform-neutral and lives in `input.rs`: modifiers from
  every source (sticky, held chords) are unioned and the backend is told the union with `set_held`, a chord is
  `set_held(keep | mods)`, `key(name, 0, None)`, `set_held(keep)`; clicks are counted here (same button, 0.5 s, 6 pt); scroll phases;
  the fling's coast at 120 Hz (`ScrollPhase::Momentum` steps, then one `Momentum (0, 0)` that ends it); sequences (32 steps, 3 s of
  waits, each at most 2 s). A backend only presses. Unknown key names are the modifiers alone, as on the Mac.
- **Threads.** A tokio runtime of its own (2 workers) for sockets and timers; one input thread (a sequence's wait holds up nothing
  else); one thread that calls the app's hooks, never under the server's locks, so a hook may call back into `Host`. The backend sits
  behind one mutex; the screen's frame sink never takes it (its `stop` may be waiting for the thread that calls the sink).
- **Screen.** The backend encodes; frames arrive already encoded, so a frame the way out can't take can't simply be skipped as the
  Mac skips one before encoding: it's dropped, the stream is marked broken, and a keyframe is asked for once the way is clear
  (`Screen::keyframe`). Over the relay's stream that's rare (the Mac's 1.5 s hold-back runs before the frame is dropped). The output
  size is the phone's box fitted to `display_aspect()`; idle pace is `set_rate(bitrate, 5)`.
- **Sockets.** TCP and UDP are one dual-stack socket each (`[::]`, v6only off); IPv4 phones are v4-mapped. UDP send buffer 4 MB:
  macOS starts at 9 KB, and a keyframe is a hundred datagrams at once. The TCP port is kept in `host.json`.
- **Storage.** `$BLURT_HOME/remote/host.json` (id, port, relay: missing = never set, `null` = cleared by the owner; relay from a
  phone; screen allowed), `devices.json` (unix ms), each phone's 32-byte key as base64 in Credential Manager (`Blurt Phone/remote-<id>`)
  or the Secret Service (application blurt, service `remote-<id>`; no Secret Service: the app's 0600 file fallback). Test builds
  (`BLURT_TEST_COMMANDS=1` in a debug build) keep keys in `test-keys.json` and may answer pairing themselves
  (`BLURT_TEST_PAIR_ANSWER`).
- **Dictation.** The phone's talk key goes into dictation's own trigger as the dictation key's code (engine.rs `Remote::Key`), so
  tap, hold, double tap and every edge case are the computer's. A press from a phone that wants its microphone opens `Mic::phone`
  (the crate's `MicFeed`: PCM16 → f32, 320-sample frames, the last second kept until the take attaches) in place of cpal. Phase
  (from the island's state, on each `island::refresh`), level, the words so far (finished pieces; the computer's recognisers have
  no pending words) and what was typed go back. Cancel / Structured / Translate / Send are the trigger's and the island's own moves.
  Voice Note from the phone listens through it (`ToPhone.listen`), or quietly through the computer's if the phone can't.
- **Keys from the phone aren't the user's.** The Windows backend tags its SendInput events `BRMT`; dictation's hook ignores them, as
  the Mac's listener ignores RemoteInput's. Linux: the RemoteDesktop portal injects into the compositor, not through a `/dev/input`
  device, so the evdev listener never sees them (a uinput backend would have to be filtered by device name).

## Several displays (2026-11-09)

The wire: `ToPhone.displays` (every display, its frame in desktop points, which is main), `screen.display` (an id = pinned; none =
follow the pointer), `ToMac.showDisplay` (pin, the pointer to that display's middle; none = follow), `screenView.display`.

- **The backend says what's there** (`Backend::displays`, `Input::pointer_desktop`, both with defaults: no list = one display, as
  before). The server asks every 2 s while a phone is connected, and right after the session opens; a change goes to the phone.
- **Follow** (displays.rs, the default): the display under the pointer, but a pointer that only grazes the next one doesn't flip the
  picture: it moves once the pointer has been on another display for 150 ms, or 20 pt into it at once. **Pinned**: the phone's choice
  stays wherever the pointer goes; the pointer goes to its middle. A display that disappears (unplugged, a lid closed) unpins and
  follows on the display under the pointer.
- **A move** is `Screen::set_display` when the backend can and the two displays have the same shape (same output size); otherwise
  the stream stops and starts again on the new display, in its own shape (`ScreenConfig.display`). Either way a screenView with the
  display's id and size, and a keyframe; nothing from before the move is sent once it's asked for. The pointer's place goes as 0…1 of
  the display shown, so `pointerTo` and a tap on the picture land on that display (backends map `move_to` to the display they show).
- **Windows**: `EnumDisplayMonitors` + `GetMonitorInfoW` (`MONITORINFOEXW`): the device name (`\\.\DISPLAY2`) is the id, a monitor's
  frame is its physical rectangle ÷ its own scale, the pointer the same way by the monitor it's on; the stream captures the monitor
  `ScreenConfig.display` names. No in-place switch yet (the stream starts again: a WGC start, a keyframe).
- **Linux** (left to the Linux backend): the ScreenCast portal can hand over several sources (`types: MONITOR`, `multiple: true`), one
  PipeWire stream each, with `position` and `size` in each stream's properties: those are the displays (ids from the stream ids, or
  the connector names Mutter gives); the pointer on the desktop from the RemoteDesktop session's absolute motion (`NotifyPointerMotionAbsolute`
  takes a stream and a position in it). Until then the default — one display, no list — works as before.

## Measured (this Mac, loopback, 2026-11-09)

| Test | Result |
|---|---|
| `tests/vectors.rs` against vectors.json | every message both ways, packets, payload, pairing link, relay room, the handshake byte for byte |
| `tests/server.rs` (the real server, a Rust phone) | pairing with digits and a yes, new key, session (platform, aspect), Ctrl+C as set_held 8 / C / set_held 0, pointer over TCP then UDP, udpOK, talk key, 33-step sequence dropped, no screen → the plain sentence, 2 s quiet → release all and the talk key up, spent code refused, the kept key opens, removal; 4 KB hello closed at once, an idle handshake closed at 6 s; a yes with other digits answers nothing, closing the pane keeps the question, a no makes a fresh code |
| iPhone app (simulator, `xcodegen` + `xcodebuild`, link by `simctl openurl`) ↔ `cargo run --example host` | pairs (the phone's own confirmation, then the six digits and the test yes), session, UDP, ⌘V as Win+V, pad strokes as moves, the talk key down / up, 2.4 s of the phone's microphone (38,400 samples, a `say` clip via `BLURT_REMOTE_TEST_WAV`), back by itself after the host restarted, screen: 8,463 pieces in 6 s, 0 lost (the app decodes only HEVC yet, so nothing shown) |
| Same, over a local relay (`tools/remote-relay/server.js`, `BLURT_RELAY_ONLY`) | pairs over the relay (the question says so), the direct path opens from the session's candidates (route `direct`), keys and moves arrive |
| `--screen-test` → `cargo run --example phone` → ffmpeg | 1280×720 H.264 at 30 fps, 2 Mbps: 239 frames in 8 s, 0 dropped, decodes cleanly, the zoomed crop half-way through is the right part |
| Same over the relay's stream | one message a frame, 247 frames, rate starts at half (1 Mbps) and climbs (1.25, 1.56 Mbps) |
| `tests/displays.rs` (two displays, the real server, a Rust phone) | the list right after the session; following: 5 pt into the other display is nothing for 100 ms and a switch after 150 ms, in the new display's shape (a new stream 1600×900 for 2560×1440); 25 pt in is a switch at once (< 140 ms); pinned: the picture moves, the pointer goes to the middle, the pointer elsewhere moves nothing; unpinned: back to where the pointer is; the pinned display unplugged: the new list, following on the one left; plugged back in and the pointer on it: followed; the phone leaving stops the stream |
| `--screen-test --displays 2` → `--example phone --cross` | displays listed, the stream starts on TEST-1, the pointer pushed across → TEST-2 at 3.6 s, pinned TEST-1 → back with the pointer in its middle, each part decodes and shows its own pattern (testsrc2 / SMPTE bars). Since 2026-11-09 (8 s run): across → TEST-2 at 1.61 s, pinned → TEST-1 at 3.24 s, across while pinned → no change, following again → TEST-2 at 6.02 s; the same on Windows (remote-windows.md) |
| The desktop app (debug build on this Mac, real Settings → Phone over Tauri IPC, `BLURT_TEST_EVAL` to drive the page) ↔ the Rust phone | the code shows as a QR image with a 2:00 countdown; a bad relay address is refused in a sentence; the phone's question raises the window and the app-wide dialog shows the phone's own digits; Allow pairs it, the pane lists it ("last used: now"); a screen request on a host with no screen gets the plain sentence |

## Open

- Nothing has run on Windows or Linux yet: the crate and the desktop app type-check for `x86_64-pc-windows-msvc` from the Mac (with a
  stand-in C compiler and resource compiler), the crate for `x86_64-unknown-linux-gnu`. The desktop app with the Linux wiring (remote.rs
  `linux_setup`) type-checks and lints in Docker on Ubuntu 24.04, CI's runner (remote-linux.md §For the app). It hasn't been
  used on a desktop.
- `Screen::start` runs under the backend's mutex: a portal dialog that waits on the user holds the phone's keys until it's answered.
- STUN: from this network (mainland China) stun.cloudflare.com and Google's never answered, so the host asks stun.miwifi.com too and
  takes the first answer (the public IPv4 then came back). The Mac asks only Cloudflare's. A direct path across real NATs is untried.
- No HUD on the computer for the phone's keys yet (the Mac's RemoteHUD): `App::hud` is called, the desktop app doesn't draw it.
- The front app is polled once a second while a phone is connected (the Mac is told by NSWorkspace).
- DNS-SD is mdns-sd's own responder; on Windows and Linux it runs beside the system's (Bonjour / Avahi), not through it.
