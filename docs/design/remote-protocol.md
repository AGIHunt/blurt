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
 kind: 0 control JSON · 1 audio PCM16 16 kHz mono LE · 2 pointer · 3 video piece (datagrams, or the relay stream) · 4 probe · 5 cursor
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
video pieces (kind 3, 17-byte header `RemoteVideoPacket` + payload `RemoteVideoPayload`) and the cursor (kind 5, two f32 LE) are binary: `pointer`,
`video`, `cursor` in the vectors.

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

## The desktop app (Windows, Linux): what Settings → Phone calls

Tauri commands, in `apps/desktop/src-tauri/src/remote.rs`; the React pane in `web/apps/desktop/src/settings` calls them through `api.ts`:

| Command | Arguments → result |
|---|---|
| `remote_status` | → `RemoteStatus` |
| `remote_show_pairing` | `{ on: bool }` → `RemoteStatus` (on: listen, advertise, make a code good for 2 minutes and one phone) |
| `remote_answer_pairing` | `{ yes: bool }` → `RemoteStatus` |
| `remote_remove_device` | `{ id: string }` → `RemoteStatus` |
| `remote_set_relay` | `{ address: string }` → `RemoteStatus` (empty clears; error text if it doesn't parse) |
| `remote_check_relay` | `{ address: string }` → `bool` |
| `remote_set_screen_allowed` | `{ on: bool }` → `RemoteStatus` |
| `remote_relay_instructions` | → `string` (the prompt for Claude Code / Codex, as RemotePane.swift's Copy Instructions) |

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
}
```
