# Design: Blurt Remote (the iPhone as trackpad, keys and microphone)

2026-11-07. Status: used on an iPhone 16 at home. The screen features and everything away from home are tested on the simulator only.

Who it's for: someone sitting 1–2 m from a mirrored big screen, phone in hand, talking to agents. Eyes are on the Mac.
That one fact decides most of this: keys must be hit without looking, and feedback belongs on the Mac.

Parts: `apps/ios` (the iPhone app, UIKit main screen + SwiftUI sheets), `Sources/BlurtRemoteKit` (wire format, crypto, key
names; builds for both), `Sources/BlurtApp/Remote` (the Mac side), `Settings/RemotePane.swift`.

## How it was decided

Independent agents reviewed this from zero, without seeing each other's work, then a second round judged the real screens
and code:

| Agent | Result that changed the design |
|---|---|
| Vibe coder walking real sessions | Numbers for agent prompts; timing gestures (Esc Esc) must run on the Mac; Cancel must never be Esc; ⌃C never repeats; the release of a held ⌘ must survive a dropped phone |
| Interaction designer | One pad, one talk bar, six keys that never move; thumb grip per orientation; hold-and-slide; fire on lift |
| Market research (11,370 App Store reviews of 15 apps) | Not connecting is the top complaint (13 % of 1–2★), then subscriptions (10 %), then reconnects (5 %). Feel (lag, cursor, scroll) 2–3 % each, but it's what the best-loved apps are praised for |
| Visual judge | Contrast too low for arm's length (6/10): lighter keys, page name instead of bare dots, talk bar as the one primary thing, words near the thumb |
| Security review | QR key must not be the lasting key; deep links must ask; unauthenticated DoS paths closed |
| Use critic (walking the code through real situations) | 16 fixes, among them: a palm firing a desktop switch, a resting thumb right-clicking, a click after using the real mouse landing at the old spot, the phone's own click ending a push-to-talk, two phones throwing each other off forever |

## Layout

The first build followed the blind-operation advice: six large keys a page, a full-width talk bar, six pages. The founder's
verdict after real use: flipping through pages is far too slow, the talk bar takes too much room, and iPhone users are used
to small keys. So keys are now about the size of the system keyboard's and nearly everything sits on one page.

```
PORTRAIT (402×874)                LANDSCAPE (874×402)
┌ Mac name ──────────┐            ⚙ 常用 更多 Blurt ⌨  ┌──────────┐
│  pad 386×434       │            [ ][ ][ ][ ][ ]      │          │
└────────────────────┘            [ ][ ][ ][ ][ ]      │  pad     │
 ⚙  常用  更多  Blurt  ⌨           [ ][ ][ ][ ][ ]      │          │
[⌘ ][⇧ ][⌥ ][⌃ ][⌫ ]              [ ][ ][ ][ ][ ]      │          │
[⌘A][⌘X][⌘C][⌘V][⌘Z]              [🎤][ ][ ][ ][ ]      └──────────┘
[1 ][2 ][3 ][⇧⇥][⌃C]
[⌘⇥][⌘`][⌃⇥][⌘R][⎋⎋]
[↕↔][⇥ ][⎋ ][↩ ][🎤]
```

- Portrait: a top row (tabs, the arrow key), eight across for six rows of 46 pt, and a dock of one row under them with the talk key. Everything used
  daily is on one screen, with nothing to scroll for. The keys above that are for the rest, and the picture has what's left.
- Landscape: a side strip at the Dynamic Island's end, with controls in the margin above and below the island and a column of the dock beside them;
  the keys come out at the other end, eight across at 44 pt. The dock is always there, even with the keys put away. Turn the phone round to change hands.
- The talk key takes the corner by the thumb: bottom right in portrait, the outer bottom corner in landscape; Left-Handed
  swaps it. It's a key like the others, mint while listening, with Cancel, Structured and Translate and the words so far at the bottom of the pad, not over keys still in use.
- Rows go by reach: send and stop nearest, then switching, agent answers and interrupt, editing, modifiers at the top.
- Mint means listening (system.md §1). The words go large at the bottom of the pad.

## Keys

One list, like the emoji keyboard (founder, 2026-11-07: Esc wasn't there on the Blurt page, and the keys used most aren't all on one page). It
scrolls and comes to rest on a row; the tabs jump to its sections and follow it. The **dock** stays put wherever the list is: esc ⇥ ⌫ ⌘ ⇧ ⌃ ↩, and
the talk key. The modifiers are here because their state has to stay in sight. Esc Esc has no key of its own: tapping Esc twice does it.

**The arrow key** is one key with four marked edges: tap towards an edge for that arrow, hold to repeat, drag for a run of them, tap then drag for ⇧
too. Where it goes matters more than how it looks: in a bottom row, down runs out of phone. So it's in the top row in portrait, and halfway up the
side strip in landscape, with room every way. (Two rows of separate arrows came before this, and took too much room.)

**A key shows an icon and the name of the key, not what it's for** (founder, 2026-11-07): the same shortcut does different things in different apps,
and an icon says more in the room there is. What it's for lives in the key list and for VoiceOver. Any key can show text or an emoji instead; the
longer the text, the smaller it reads.

The sections: **常用** (48 keys: edit, switch, tabs, editors, Blurt, windows), **字母** (the keyboard's own rows, ten across, about the iPhone's key size),
**符号** (symbols, navigation, F-keys, the same size). They're plain keys, so a sticky ⌘ turns them into shortcuts. 1, 2, 3 for terminal prompts are in
字母, and in the picker as keys of their own.

On a touch landing in the list: keys that fire on lift can always be taken by the scroll. Keys that act at once (⌘⇥, ⌫, arrows) wait 120 ms or
for a slide sideways there, so a thumb meaning to scroll sends nothing. In the dock they act at once.

| Kind | Behaviour | Why |
|---|---|---|
| Plain | Fires on lift, slide off cancels, held still does nothing | A misplaced thumb costs nothing |
| Cycle (⌘⇥, ⌃⇥, ⌘\`) | Press holds the modifier and steps once; slide steps on, 22 pt per detent, left goes back; at the screen edge it keeps stepping, seven a second; lift lets go. The other keys dim and are out of play | A quick tap is "back to the last app"; holding reaches any of twenty apps |
| Arrows | One slot: drag for ticks every 24 pt; past 72 pt repeats, faster with distance; tap then drag adds ⇧ | No tiny D-pad, and text selection is one gesture |
| Sticky (⌘ ⇧ ⌥ ⌃) | Tap: next key or click. Double tap: locked. The Mac really holds it | One thumb can't chord; ⌘-click and ⇧-arrows work everywhere |
| Sequence | Runs on the Mac in one go | Esc Esc's timing can't depend on Wi-Fi |
| Text | Types a string, Return if asked | `/compact` and the like |
| Repeating | ⌫ and arrows fire on press and repeat | Nothing destructive repeats: never Esc, ⌃C or Return (⌃C twice exits Claude Code) |

"Tabs" is smart: ⌘⇧] in terminals, ⌃⇥ elsewhere, from the app in front.

Deliberately not defaults: y/n keys (no longer Claude Code defaults), media keys, snippets for things you can say.

Customising is on the phone only, from the end of the list or Settings: everything laid out, dock first. Hold and drag a key: the others make way
as it passes, so what will happen shows before it's let go, and into the dock it swaps, since the dock always has its keys. Tap one to choose its
icon, text or small line, or what it does; minus to remove, plus to add. Sections can be renamed, added and removed. The picker has the whole
keyboard and about 90 actions with search, plus New Shortcut (tap modifiers, tap a key, optional hold-and-slide) and Text.

## Trackpad

Raw touches into `PadEngine`, a pure state machine with tests (no gesture recognisers: they add delay). Tap click; tap, tap
double click; tap then drag, surviving a lift for 0.45 s so a drag can cross a big screen in strokes; hold then lift right
click; hold then drag is a drag, the plain press-and-drag every mouse has (the phone taps back at the hold; iPhones since the 11 have no force
sensing, so a hard press is just this hold). That's how a screenshot area gets selected. One thumb scrolls along the edge of the pad next to it. Two
fingers scroll / tap right click / pinch zoom; three fingers change
desktop (left, right), all windows (up), app windows (down). A touch that stops a coast never clicks. A resting thumb never clicks (tap under 220 ms).

Pointer gain rises smoothly from 1× for a slow finger to 5.5× for a fast one, because the glass is a tenth of a trackpad and
the target may be 4K; reviews of other apps single out steep curves and bad slow-speed precision. Scrolling is
continuous-phase CGEvents so apps rubber-band as with a trackpad; the coast runs on the Mac at 120 Hz.

iOS: `preferredScreenEdgesDeferringSystemGestures = .all`, status bar off, idle timer off while open, no rotation during a
touch, large contacts ignored as palms. The screen stays on while the app is open and dims only after 5 minutes idle, for a phone left on the desk
(20 s was the first value; it read as the phone misbehaving).

## Dictation

The talk bar **is** Blurt's dictation key: `Dictation.remoteKey` feeds the same `DictationTrigger` as Fn, so tap, hold,
double-tap-to-send and every edge case come along. The phone's microphone replaces the Mac's when "Use iPhone Microphone" is
on (default): at 2 m the Mac's mic hears the room. 16 kHz PCM16 pieces go over TCP from the key-down; `RemoteMicFeed` holds up
to a second until the take starts, and `NoteVoice.phoneFeed` takes them in the mic's place, so VAD, streaming, polish, the
voiceprint gate and the history work unchanged. Cancel, Structured, Translate are Blurt commands, never Esc: a late Esc would
interrupt the agent.

The permissions Blurt needs to hear Fn aren't needed for a press from the phone.

## Connection

`Link` tries the last addresses and Bonjour (`_blurt-remote._tcp`, peer-to-peer Wi-Fi included, so two devices with no shared
network still connect) at once, and takes whichever answers. It connects when the app opens and comes back, with no
prompt. Keys pressed while disconnected are dropped, never queued: a late ⌘W is worse than a missing one.

Control and audio use TCP; pointer and scroll use UDP once a probe gets through, falling back to the TCP stream.

| Measured (simulator ↔ Mac, loopback network) | |
|---|---|
| Back from another app to connected | 0.8 s |
| Mac app restarted, to connected | 2.6 s |
| Dictation from phone audio to Apple Speech | recognised 58/58 characters of a `say` clip |
| A 80 pt swipe through real CGEvents | pointer moved 79 pt at slow speed |
| ⌘⇥ through real CGEvents, twice | front app changed and came back, no modifier left down |
| Hold ⌘⇥, one slide to the screen edge, hold 2 s | ⌘ held, Tab ×30, ⌘ released, nothing else pressed |
| ⌃↑ posted plain / with the keyboard's fn + numpad flags | nothing / Mission Control opens (arrows need those flags for macOS's shortcuts) |

If a session goes quiet for 2 s, the Mac lets go of everything held, including the dictation key. A background phone sends
`releaseAll` first.

## Screen

A test build of showing the Mac's screen on the phone, off unless asked for; while off nothing is captured or sent. ScreenCaptureKit →
VideoToolbox HEVC (low-latency rate control, no reordering, 12 Mbps cap) → sealed UDP datagrams of up to 1,180 bytes → hardware
decode. A frame missing a piece is dropped and the phone asks for a keyframe. Mac only: Windows would need its own capture, encoder
and input.

Measured 2026-11-07, iPhone 16 ↔ MacBook over home Wi-Fi, three runs of 12 s a stage, a 1512×945 window of made-up terminal text
scrolling at 30 Hz, stream 2042 px wide at most:

| Stage | fps | Mbps | Age of frame at decode, ms (p50 / p95 / max) |
|---|---|---|---|
| Whole window | 56–57 | 12.2 | 15–17 / 67–126 / 94–220 |
| 2× | 56–57 | 3.8 | 10 / 57–62 / 82–89 |
| 3× | 57 | 1.3 | 8 / 56–58 / 78 (one run hit a Wi-Fi stall: 224 / 406) |

Age is from the Mac composing the frame to the phone decoding it; the phone's panel adds up to 16 ms and the Mac's own display path isn't
counted. Encode 3 ms, decode 1.5–3 ms, no frames lost, no keyframes requested once stale frames were fixed. Screen idle: about 0.5 Mbps.

Pointer path, gaps between 10 ms probes arriving at the Mac, ms:

| | p50 | p95 | p99 |
|---|---|---|---|
| Video off | 10 | 11–13 | 75–205 |
| Whole window | 10 | 14.5 | 79 |
| 2× / 3× | 10 | 13 | 74–75 |

So the video doesn't disturb the pointer. About 1 % of gaps reach 75 ms with or without it; turning peer-to-peer Wi-Fi off for these
connections didn't change that. Text stayed sharp while scrolling at every zoom, small Chinese included.

### How it works now

- The display button turns it on and off; while off nothing is captured or sent. The Mac and its display stay awake while it shows.
- **The pad is the stage, and the picture sits in it like a photo** (founder, 2026-11-07: an earlier version kept the pad to the Mac's shape, and
  zoomed in the black around it was wasted). Whole and letterboxed at first, near the thumb in portrait; zoomed, it fills all the room there is,
  whatever its shape. The Mac is sent a crop of the screen's own shape around what's in view. Portrait: everything above the keys. Landscape: the
  full height, up to the side strip. Opening the keys leaves the stage beside them, so all of the picture stays in view. Corners are 6 pt: a rounded corner on a picture is a piece of the screen not seen.
  The button to turn it off is always outside the picture: it was once on top of it, white on white.
- **The phone owns the view; a pinch zooms it there and nothing on the Mac** (founder, 2026-11-07: with the screen off it stays ⌘+ / ⌘−). The first
  version scaled the picture about its centre and then the Mac cropped around the pointer, so the view jumped when the fingers lifted. Now it
  works like a photo: the point between the fingers stays under them, it stretches a little past the whole screen and springs back. The Mac is
  asked for that part of the screen up to about 7 times a second, at the same output size, so the text gets sharper the closer you look. Every
  frame says which part it shows (`RemoteCrop`, in the payload), and goes onto a plain layer in one commit with where that part belongs, so a new
  crop changes only the sharpness. A sample-buffer layer can't do that: it shows frames on its own clock, and each crop change twitched the picture. ScreenCaptureKit doesn't say which frame took a new crop, so frames wait out each change and the latest goes when it's done.
- **Moving around, zoomed in.** Two fingers move the picture, as in Photos. Two fingers moving together are never quite the same distance apart,
  and passing that on made a move shimmer: it stays a move until they come 14% apart or together, then it's a pinch and nothing jumps. One finger is still the pointer, which pushes the view when it
  nears an edge. A last sight of the whole screen sits under the video, so a move past what's been sent shows that until the sharp part comes.
  If the view has moved off the pointer, the next touch brings the pointer to the middle of the view: what you touch is what you're looking at.
  Zoomed in, two fingers can't also scroll: scroll along the edge of the pad. The pointer slows with the square root of the zoom.
- **The pointer isn't in the video.** Its position goes on its own, 60 times a second and twice a second regardless (they can be lost), and the
  phone draws it, moving it ahead on its own strokes, so it's never a frame late. The Mac has the last word 120 ms after a stroke, or 1.5 round
  trips. An earlier version dropped what arrived during a stroke, and nothing arrives after one, so the two drifted apart stroke by stroke and
  clicks missed (founder, 2026-11-07). Its shape goes when it changes.
- **The glass is the screen.** With the picture showing, a tap clicks what's under the finger, two fingers right-click there, a hold brings the pointer
  to the finger, and hold then drag follows it, so the pointer's position stops mattering for anything big enough to hit. Moving a finger is
  still the trackpad, for what isn't. A touch off the picture does nothing. Settings → Tap Clicks Where You Touch turns it off.

## Away from home

Three routes, tried together, best one kept:

| Route | When | Carries | Feel |
|---|---|---|---|
| Local | Same network, or peer-to-peer Wi-Fi | Everything | As measured above |
| Direct | Away; a path opens to the Mac | Pointer, video (UDP); control stays on the relay | Close to local, depends on the networks |
| Relay | Away; once the Mac has a relay address | Everything, stream of sealed frames | Depends on how near the relay is |

- **Relay:** Blurt doesn't run one: it's an open-source project, and a shared relay would be a cost and a service to keep up (founder, 2026-11-07).
  Each owner runs their own, a Cloudflare Worker with one hibernating Durable Object per paired phone or one Node process on a server
  (tools/remote-relay, same protocol), and pastes its address into Settings → iPhone → Relay Address. Copy Instructions there gives a prompt
  for Claude Code or Codex that does the setup. The address reaches the phone inside the sealed session, so the phone has nothing to configure,
  and it must connect once on the same network to learn it. `ws://` works too: what passes is sealed either way, and it needs no domain.
  The room is an HMAC of the pair's key. The relay has no key. Pairing still needs the QR code on the same network: the relay only carries pairs.
- **Direct:** once a session is up on the relay, both ends trade addresses inside it (public IPv6, the IPv4 a STUN server sees, LAN
  addresses) and send each other packets to open their firewalls. The first that answers carries the pointer and video. Some networks can't
  do this (symmetric NAT, mobile carriers' CGNAT without IPv6); then it stays on the relay.
- **Over the relay** video drops to 1280 px, 15 fps, 1.5 Mbps; pointer messages to 30 a second; a frame is skipped rather than queued. When a
  direct path opens the picture goes back to full. Back home the local network takes over by itself, checked every 10 s.
- With an address set, the Mac holds one idle WebSocket per paired phone. No address, nothing leaves the network. The Mac stays awake only while
  a phone is connected, so a sleeping Mac is out of reach.

Measured from this Mac through a US VPN, Cloudflare's IAD: relay round trip about 630 ms. From a Chinese network Cloudflare's free plan usually
lands on the US west coast or Hong Kong, so a server in China is much nearer. The founder's own relay is `relay.agihunt.info`, on the
agihunt.info server in Beijing (`blurt-relay.service`, certificate by acme.sh, `/etc/cron.d/blurt-relay-cert`): 10 ms from home on a direct route.
A VPN that sends the relay's domain abroad undoes that: such a domain needs a direct rule.

Quota, from Cloudflare's Durable Objects pricing page: 100,000 requests a day on the free plan, incoming WebSocket messages count 20:1, outgoing
are free, reset at 00:00 UTC. A screen session on the relay is about 70 incoming messages a second (15 video frames, 30 pointer, 30 cursor), so
3.5 requests a second: about 8 hours a day, shared by every user. Direct and local traffic doesn't count.

A server has no such quota, only its bandwidth: the picture over a relay is about 1.5 Mbps per person. The Beijing server's outbound is a flat 3.4
Mbps, enough for its owner and no one else.

## Security

A key press here is a key press on the Mac, and earlier apps in this category had unauthenticated RCE over UDP.

- Pairing: QR code with a 256-bit key, good for one connection within two minutes. That connection spends it and is sent a
  new key inside the sealed session; the phone becomes a device only when it confirms keeping it. A photo of the code is
  worth nothing afterwards.
- Session: X25519 ephemerals, HKDF salted with the paired key and bound to the transcript, one ChaCha20-Poly1305 key each way,
  counter nonces. A stolen paired key can't read past traffic. UDP packets are sealed too; replays and overtaken packets drop.
- Blurt doesn't listen until a phone is paired. Nothing but the handshake is acted on before a session has greeted. Before
  the handshake a frame is at most 1 KB, at most 16 handshakes at once, a refusal closes the connection, and a UDP flow that
  isn't the session's is cancelled on its first packet.
- Links from outside the app ask before pairing: a web page can open `blurtremote://`.
- The relay and direct paths use the same handshake and seals as the local network; neither can read or forge a frame. Candidates are
  only exchanged inside the sealed session, between paired devices.
- A refused handshake is unauthenticated, so it's only believed when no other way in worked.
- Keys: iOS Keychain (this device only), macOS login Keychain. Sequences are capped (32 steps, 3 s of waits), text at 64 KB.

Peer-to-peer means anyone in radio range can reach the handshake (no further), and sees the Bonjour name and Mac id.

## Open

- All pt and ms values above are starting points to tune by hand.
- Not tried away from home on a real phone: relay latency from China, whether a direct path opens over mobile data.
- Not tried on a real phone: tap-where-you-touch against real windows, hold-and-drag on Blurt's area selection.
- Only the display the pointer is on is shown when the stream starts; a second display isn't followed yet.
- macOS Local Network and firewall behaviour for the signed release app.
- Bare letters typed as keys while the Mac's input method is on (digits are fine) go into its composition.
- Tap then drag clicks once first (the click can't wait for what comes next without delaying every tap).
- App Store: needs the bundle id registered, screenshots, and a price decision (reviews say: no subscription, no ads).
