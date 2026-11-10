# Blurt Remote: the wire, for every phone and every computer

2026-11-09. One protocol, written in three languages: Swift (`skills/blurt/recorder/macos/Sources/BlurtRemoteKit`, the reference, shared by the
Mac host and the iPhone / iPad app), Rust (`crates/blurt-remote`, the Windows and Linux host) and Kotlin (`apps/android/core`, the Android app).
They stay one protocol through **`tests/remote-vectors/vectors.json`**: written by `RemoteVectorsTests.swift`, and every implementation's tests
decode, encode, seal and open exactly what it says. A change to the wire is a change to the Swift types, then
`BLURT_WRITE_VECTORS=1 swift test --filter RemoteVectorsTests`, then the other two follow until their vector tests pass. Why and how it feels
to use: [remote.md](remote.md).

| | Mac | Windows | Linux (Ubuntu, Wayland) |
|---|---|---|---|
| iPhone, iPad, iPhone Duo | ✓ | ✓ | ✓ |
| Android phone, tablet, foldable | ✓ | ✓ | ✓ |

Any phone app talks to any host: the host says what it is (`platform`), the phone shows that computer's keys.

## Layers

```
 TCP (local) or WebSocket binary messages (relay)     UDP (local, or direct after the relay)
 ┌──────────────────────────────────────┐             ┌──────────────────────────────────────┐
 │ u32 BE length ∥ frame                │             │ u32 BE session ∥ u64 BE counter ∥    │
 │ frame = hello JSON (before keys) or  │             │ ChaCha20-Poly1305(kind ∥ body) ∥ tag │
 │ ChaCha20-Poly1305(kind ∥ body) ∥ tag │             └──────────────────────────────────────┘
 └──────────────────────────────────────┘
 kind: 0 control JSON · 1 audio PCM16 16 kHz mono LE · 2 pointer · 3 video piece (datagrams, or the relay stream) · 4 probe · 5 cursor · 6 video feedback
```

- **Framing** (`RemoteFrameReader`): 4-byte big-endian length, then the frame. Before the handshake a frame is at most 1,024 bytes; after the
  first sealed frame, 1 MiB. A length of 0 or over the limit closes the connection. Over the relay each WebSocket binary message carries
  whole length-prefixed frames (one per message as sent; a reader must still accept several or a split).
- **Handshake** (`RemoteCrypto.swift`): phone → host `{"v":1,"id":<device id>,"eph":<base64 X25519 public>,"c":<base64 SHA-256("commit" ∥
  nonce)>}`; host → phone `{"v":1,"eph":…,"proof":<base64 HMAC-SHA256(paired, "mac" ∥ transcript)>}` or `{"v":1,"error":"not_paired" | "version"
  | "bad_message"}` and close. `transcript = SHA-256("blurt-remote-1" ∥ id UTF-8 ∥ phoneEph ∥ hostEph)`. Keys: HKDF-SHA256(ikm = X25519 shared
  secret, salt = paired key, info = transcript, 64 bytes): first 32 phone→host, last 32 host→phone. JSON `Data` fields are standard base64
  with padding.
- **Seals**: ChaCha20-Poly1305, 12-byte nonce = u32 BE channel ∥ u64 BE counter. TCP channel 0, counters from 0, implicit, per direction. UDP
  channel 1, counters from 1, carried in the packet; a receiver takes anything newer, and anything in the last 64 not yet seen; older drops.
- **Six digits** (new phone waiting for a yes): `SHA-256("check" ∥ transcript ∥ nonce)`, first 4 bytes as u32 BE, mod 1,000,000, zero-padded.
  The phone reveals `nonce` in its first sealed message (`ToMac.hello.nonce`); the host checks it against `c` before showing digits.
- **Relay room**: `base64url(HMAC-SHA256(paired, "blurt-relay-room"))`, no padding. URL `<relay>/v1/<room>/<mac|phone>`. Close codes: 4000
  phone left, 4001 host gone, 4002 replaced. `tools/remote-relay` is the relay, unchanged for any host.
- **Pairing link** (QR): `blurtremote://pair?v=1&mac=<host id>&id=<device id>&k=<base64url key>&n=<name>&p=<tcp port>&a=<addr,addr>&r=<relay>`.
  `mac` is the host's id whatever the host is.
- **Discovery**: DNS-SD `_blurt-remote._tcp`, instance name = the computer's name, TXT `id=<host id>` (Mac: `RemoteServer.startListening`). TCP keeps
  its port across restarts; UDP is any free port, told in `session.udpPort`.

## Messages

Control messages are JSON in Swift's synthesized `Codable` shape: an object with one key, the case name; labelled values by label, unlabelled ones
as `_0`, `_1`; a case without values is `{"name":{}}`; optional values left out when nil. Readers ignore unknown keys and drop messages whose
case they don't know (a newer peer). Every case with an example: `vectors.json` → `toMac`, `toPhone`. Pointer packets (kind 2, `RemotePointerPacket`),
video pieces (kind 3, 17-byte header `RemoteVideoPacket` + payload `RemoteVideoPayload`) and the cursor (kind 5, `RemoteCursor`: two f32 LE,
then a u32 LE to a phone that numbers its moves) are binary: `pointer`, `video`, `cursor`, `cursorSeq` in the vectors.

The session, as the host runs it (reference: `RemoteServer.swift` `opened`, `greet`, `handle`): first sealed frame from the phone opens it (its
`hello` names the device and reveals the nonce) → a new device waits for the owner's yes (`pairingWaits`, then `newKey` → phone answers
`keyStored`) → `session` (name, UDP port and session number, canControl, version, candidates, displayAspect, relay, **platform**) → `front`,
`dictation`, `clock` → the phone probes UDP (pointer `scrollStop` packets sealed on channel 1); the host answers `udpOK` on TCP once one opens.
Quiet for 2 s: the host lets go of everything held (keys, buttons, dictation key). `ping` ↔ `pong` every second from the phone.

## Hosts (new 2026-11-09)

`session.platform` is `"mac"`, `"windows"` or `"linux"`; missing means a Mac before 1.0.15. Key names and `RemoteModifiers` bits are the same
everywhere; each host presses its own keys for them:

| Bit | Mac | Windows | Linux |
|---|---|---|---|
| command (1) | ⌘ | Win | Super |
| shift (2) | ⇧ | Shift | Shift |
| option (4) | ⌥ | Alt | Alt |
| control (8) | ⌃ | Ctrl | Ctrl |

So the phone sends what that computer's own keyboard would: copy is `{control,"C"}` to Windows and Linux, `{command,"C"}` to a Mac. The phone
keeps one key layout per platform (defaults differ: Ctrl+C / Ctrl+V…, Alt+Tab as the cycle key, Win/Super alone opens Start / Activities) and
labels modifiers as that platform does (Ctrl, Alt, Win or Super). `system` moves and `blurt` commands are meanings, mapped by the host.
`activate(bundle:)` is Mac only. `front.bundle` is an app id on a Mac, the exe name on Windows, the desktop file id (or WM class) on Linux.

### Default keys per host

The phone's 常用 page and dock for each platform (iOS `Model/Deck.swift`, Android `core/…/Deck.kt`; same four rows, a row each). What each
key does stays in its hint; the key shows the key's own name. `W` = command bit (Win / Super), `C` = control, `A` = option (Alt), `S` = shift.

| Row | Mac | Windows | Linux |
|---|---|---|---|
| Editing | ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z ⌘A | C+C C+V C+X C+Z C+Y C+A | C+C C+V C+X C+Z C+S+Z C+A |
| Between things | ⌘Tab⟳ ⌘\`⟳ ⌘[ ⌘] ⌃⇧Tab⟳ ⌃Tab⟳ | A+Tab⟳ W+Tab A+Left A+Right C+S+Tab⟳ C+Tab⟳ | A+Tab⟳ A+\`⟳ A+Left A+Right C+S+Tab⟳ C+Tab⟳ |
| Acting | ⌘F ⌘K ⌘Space ⌃C ⌘T ⌘W | C+F C+K W (alone: Start) C+S+C C+T C+W | C+F C+K W (alone: Activities) C+S+C C+T C+W |
| Blurt | Snap Record VoiceNote CopyText Translate Cards | same | same |
| Dock | ⌃ ⌥ ⌘ ⇧ ⇥ esc ⌫ ↩ ␣ 🎤 | Ctrl Win Alt Shift ⇥ esc ⌫ ↩ ␣ 🎤 | Ctrl Super Alt Shift ⇥ esc ⌫ ↩ ␣ 🎤 |

⟳ = a cycle key (hold and slide). On Windows and Linux, copy and Interrupt are both Ctrl+C in most apps, so the third row's slot that is
⌃C on a Mac is Ctrl+Shift+C there (copy in terminals: GNOME Terminal, Windows Terminal), with Ctrl+C already on the first row; the key
reads "Ctrl C" in full as on the Mac. 更多 on Windows / Linux: F1–F12, Home End PgUp PgDn ⌦, Win+D / Super+D (desktop), Win+E (files),
Win+L / Super+L (lock), Alt+F4, Ctrl+Shift+Esc (Task Manager, Windows), Win+Shift+S (snip, Windows). 字母 and 符号 are the same everywhere.

## Video codecs (new 2026-11-09)

`screen.codecs`: what the phone decodes, best first, `["hevc","h264"]` from Apple phones, what `MediaCodec` reports from Android. Missing means
HEVC only (phones before 1.0.15). The host picks the first it can encode in hardware, else H.264 in software, and says which in
`screenView.codec` (missing = `"hevc"`). The picture is NAL units with 4-byte big-endian lengths; a keyframe's parameter sets ride in the payload
(HEVC: VPS, SPS, PPS; H.264: SPS, PPS), bare NAL units. No B-frames, no reordering.

## Displays (new 2026-11-09)

A computer with several displays shows one at a time: the one the pointer is on by default, following it across, or one the phone chose.
Why and how it feels: [remote.md §Several displays](remote.md#several-displays). Vectors: `displays`, `screen_pinned_display`, `show_display`,
`show_display_follow`, `screen_view_display`.

- **`ToPhone.displays([RemoteDisplay])`**: every display, `{id, name, x, y, width, height, main}`. The frame is in points in the desktop's own
  coordinates: top-left origin, y down, as the computer's display settings arrange them (on a Mac, `CGDisplayBounds`; the main display is
  at 0,0 and others can be negative). `id` is stable while that display stays connected (Mac: the `CGDirectDisplayID` as a decimal string;
  Windows: the monitor's device name; Linux: the portal stream's id). A display mirroring another isn't listed. Sent once the session is up,
  right after `session`, and again whenever the arrangement changes (plugged in, unplugged, moved, another resolution), whenever there is at
  least one display. The phone shows its switcher only with two or more.
- **`RemoteScreenRequest.display: String?`**: the display the phone last chose, so a picture turned on again (or restarted for another
  size or route) shows what it showed. nil, or an id that's no longer there, follows the pointer.
- **`ToMac.showDisplay(String?)`**: an id pins the picture to that display and puts the pointer in its middle (a warp, as `pointerTo`
  does); the host shows the display's name in its own on-screen feedback. nil goes back to following the pointer. An id the host doesn't
  have is ignored. Valid with the picture off too: the choice holds for the next `screen`.
- **`ToPhone.screenView(…, display:)`**: the display the stream shows from now on. The host sends it before the first frame of a new
  display, and that frame is a keyframe with its parameter sets. `width`/`height` are the new display's size in points.
- **Following**: the host changes display once the pointer has really crossed: it has stayed on the other display for 150 ms or gone
  20 pt into it (`RemoteDisplayFollow`), so a pointer on the edge doesn't flip the picture back and forth. Moves from the phone and the
  computer's own mouse count alike. Relative pointer moves (`pointer` packets) cross between displays as the computer's own mouse does.
- **Pinned and the pointer leaves**: the picture stays; the cursor position (kind 5) goes outside 0…1 of the display shown, and the phone
  treats that as "the pointer is elsewhere". `pointerTo` and touch-to-click map onto the display shown.
- **Unplugged**: a pinned display that disappears is forgotten by both ends, and the host follows the pointer again; the new `displays`
  says which are left.
- **The output size**: `screen.width`/`height` are a box, not a shape. The host fits each display's own shape inside it, as large as the
  box and the display's pixels allow. A phone that knows the displays asks for a box that fits any of them, so a switch never needs a new
  `screen` request (iOS: `PadViewController`, the box from every display's aspect).
- **After a switch the phone** resets its view to the whole screen (another display is another screen), sends `screenCrop(whole)` (a crop
  in flight was for the display left), and drops decoded frames that don't have the new display's shape until the first that does.

Hosts that can show only one display (a Wayland portal session that granted one monitor) send `displays` with that one and ignore
`showDisplay`.

## The pointer's numbers (new 2026-11-11, 1.0.17)

The phone draws the computer's pointer itself, ahead on its own strokes, and takes the computer's word for where it is when the stroke
is over. A word from before the last moves made the pointer jump back and then forward ([remote.md](remote.md) §The pointer isn't in the
video), so each word now says which moves it includes. All additive, and nothing to negotiate:

- **The phone counts its pointer instructions**, relative moves and `pointerTo` alike, one counter per session, from 1, wrapping (u32).
  `RemotePointerPacket.move` carries the count as four more bytes after its two values (u32 LE; 13 bytes instead of 9), and
  `ToMac.pointerTo` as `seq`. Hosts before 1.0.17 read the first 9 bytes and ignore unknown JSON keys. Over the relay, where moves are
  added up and sent 30 times a second, every move still takes a number and the packet carries the newest.
- **The host remembers the newest number it has made** (a later one replaces it; one more than 65,536 behind is a phone that started over),
  and forgets it when a session opens. A `pointerTo` with no picture to place it on still counts.
- **Once the phone has sent a number, every cursor place (kind 5) is 12 bytes**: x, y, then that newest number (u32 LE). A phone that
  sends none gets 8 bytes as before; phones before 1.0.17 drop any other length. A place goes when the pointer moved **or the number
  changed** (a move against the screen's edge moves nothing, and the phone is waiting for its number), and now and then regardless. The
  place sent with a number must include that move: where the system reports a pointer just placed a moment late, the Mac host says
  where it put it for 150 ms. The Rust host knows a relative move only as a step, not where it ended (`GetCursorPos` on Windows, the
  PipeWire stream's cursor on Linux), so it holds the number back instead: a number is said once it is 150 ms old (`input::Told`), and
  numbers are kept per session, since a replaced phone's channel lingers 200 ms. Neither figure is measured on Windows or Linux.
- **The phone** (`RemoteCursor.wait`): a place whose number is the phone's own count or later (`(host − sent) as i32 ≥ 0`) counts at once.
  One behind it waits: for the place that does include everything, or, since a move lost on the way never gets its number, until the
  pointer has been still on the phone for max(0.5 s, 4 round trips); 3 s in the relay's stream, where nothing is lost but much can queue.
  A place with no number (a host before 1.0.17) counts after max(0.12 s, 1.5 round trips), as it always did.

Vectors: `pointer` → `move_seq`, `toMac` → `pointer_to_seq`, `cursorSeq`.

## Repairs: NACK, LTR refresh, parity (new 2026-11-09)

Why, the measurements and every timer: [remote-realtime.md](remote-realtime.md). The wire, all of it additive:

- `screen.features`: what the phone does, `["nack","ltr","fec"]` from Apple phones. Missing = none. The host answers with what it uses in
  `screenView.features` (missing = none, as from hosts before 1.0.15). Nothing below is sent to a peer that didn't name it.
- Video packet byte 8 is a flags byte: bit 0 keyframe (the old meaning: read it as `& 1`, not `== 1`), bit 1 **refresh** (decodable from
  frames the phone acknowledged), bit 2 **acknowledge** (the phone says when it has decoded this one). Bits 1–2 only with `ltr`.
- **Parity pieces** (`fec`): n = min(64, ⌈count / G⌉) groups, interleaved: group g holds the pieces i with i mod n = g. Parity piece g has
  `index = count + g`; its payload is one byte n, then the XOR over the group of (u16 BE payload length ∥ payload, zero-padded to the group's
  longest). Any one missing piece of a group is rebuilt from the rest. Receivers before 1.0.15 drop them (`index ≥ count`).
- **Frame kind 6, `videoFeedback`** (phone → host, datagrams; over the relay's stream it rides the stream). First byte the type, numbers
  big-endian. `1` nack: repeated (u32 frame, u16 n, n × u16 piece), n = 0xFFFF for a whole frame. `2` ack: u32 newest decoded frame that
  asked, u32 bitmap of the 32 before it (bit 0 = newest − 1). `3` lost: u32 the last frame decoded; the next one is gone, send a refresh.
  The host answers a nack by sending the stored pieces again, byte for byte as first sent (same frame id, index, flags, captured).

Vectors: `videoRepair` (a refresh frame's packets, its parity pieces, each feedback type), `screen_repairs`, `screen_view_repairs`.

## The desktop app (Windows, Linux): what Settings → Phone calls

Tauri commands, in `apps/desktop/src-tauri/src/remote.rs`; the React pane in `web/apps/desktop/src/settings` calls them through `api.ts`:

| Command | Arguments → result |
|---|---|
| `remote_status` | → `RemoteStatus` |
| `remote_show_pairing` | `{ on: bool }` → `RemoteStatus` (on: listen, advertise, make a code good for 2 minutes and one phone) |
| `remote_answer_pairing` | `{ yes: bool, digits: string }` → `RemoteStatus` (ignored unless `digits` are the current `asking` digits) |
| `remote_remove_device` | `{ id: string }` → `RemoteStatus` |
| `remote_set_relay` | `{ address: string }` → `RemoteStatus` (empty clears; error text if it doesn't parse) |
| `remote_check_relay` | `{ address: string }` → `bool` |
| `remote_set_screen_allowed` | `{ on: bool }` → `RemoteStatus` |
| `remote_relay_instructions` | → `string` (the prompt for Claude Code / Codex, as RemotePane.swift's Copy Instructions) |
| `remote_allow_firewall` | → `RemoteStatus` (Windows, on the owner's click only: Blurt's inbound rule through Windows' UAC prompt, waited for, then `firewall` checked again; a declined prompt leaves it `"blocked"`, no error; elsewhere it only answers) |

Event `remote://status` carries a fresh `RemoteStatus` whenever it changes:

```ts
type RemoteStatus = {
  listening: boolean
  pairing: null | { url: string; qrSvg: string; expiresAt: number }   // unix ms; qrSvg is a complete <svg> the host draws
  asking: null | { device: string; digits: string; viaRelay: boolean } // a new phone waits for a yes
  devices: { id: string; name: string; lastSeen: number | null }[]
  connected: null | { id: string; name: string; route: "local" | "direct" | "relay"; screen: boolean }
  relay: { address: string | null; fromPhone: boolean; reachable: boolean | null }
  screenAllowed: boolean
  canControl: boolean          // false: Wayland's Remote Desktop not granted yet, or an elevated window in front on Windows
  problem: string | null       // a sentence for the user, localised
  firewall: "ok" | "blocked" | "unknown" // Windows Defender Firewall keeps phones out on this network (remote_allow_firewall);
                               // "unknown": it couldn't be read; always "ok" off Windows (added 2026-11-09)
}
```
