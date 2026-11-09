# Design: Blurt for iPhone (the iPhone as trackpad, keys and microphone)

The app is called Blurt on the iPhone too (it was Blurt Remote while in development; the code keeps `BlurtRemote`). Until it
is on the App Store, people build it themselves: [apps/ios/README.md](../../apps/ios/README.md). Settings → iPhone links there.

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

The first build followed the blind-operation advice: six large keys a page, a full-width talk bar, six pages. The founder's verdict after real use:
flipping through pages is far too slow. Then came the other extreme, 48 keys eight across, all on one screen: "too dense, more than I can remember"
(founder, 2026-11-08). Now there are few enough to learn, large enough to hit without looking. No setting for the keyboard's height or width: the
sizes are chosen, and whoever wants more keys adds them and scrolls.

```
PORTRAIT (402×874)            LANDSCAPE, keys open (956×440)           LANDSCAPE, keys away
┌ Mac name ──────────┐        ⚙ ┌────────────┐ 常用 字母 符号 更多  ▦    ⚙ ┌──────────────────┐ ▦
│  pad               │        ⌖ │  picture   │ [ ][ ][ ][ ][ ][ ]  ⌘⇥    ⌖ │                  │ ⌘⇥
│                    │          │            │ [ ][ ][ ][ ][ ][ ]  esc     │     picture      │ esc
└────────────────────┘        ◐ │            │ [ ][ ][ ][ ][ ][ ]  ✣     ◐ │                  │ ✣
⚙ 常用 字母 符号 更多 ⌖ ◐ ⌨ ✣    ⌨ └────────────┘ [ ][ ][ ][ ][ ][ ]  ↩     ⌨ └──────────────────┘ ↩
[ ][ ][ ][ ][ ][ ]                             [⌃][⌥][⌘][⇧][⇥][⌫]  🎤                            🎤
[ ][ ][ ][ ][ ][ ]
[ ][ ][ ][ ][ ][ ]
[ ][ ][ ][ ][ ][ ]
[⌃][⌥][⌘][⇧][⇥][esc][⌫][↩][␣][🎤]
```

- Portrait: a top row (settings, tabs, find the pointer, the screen, the system keyboard, the arrow key), six across for four rows of 48 pt, and the
  dock under them: ten even keys, the last the talk key. 311 pt in all. The top row is 52 pt so the arrow key has 25 pt for each of up and down. The
  dock runs from the modifiers to what's used most, so esc, delete, return and space are by the thumb. Left-Handed mirrors the dock; settings stays
  first in the top row and the arrow key comes in past it, so a slide to the left has room (founder, 2026-11-08: at the edge it had none). At the
  screen's edge a slide keeps repeating anyway. The talk key was twice as wide; the founder found it wasteful and wanted the space bar always there.
- Landscape: the black edges are used. The Dynamic Island's end holds what's rarely needed, around the island. The other end is the thumb's, and it
  never moves: the keys' switch, ⌘Tab, esc, the arrow key, return, space and the talk key, 8 pt taller than the keys above it (44–52 pt on a 17 Pro
  to a Pro Max, clear of the round corners). It was a tall bar, 70–110 pt, and the founder called it wasted (2026-11-08). That's what a person watching the picture needs. The rest
  (⌃ ⌥ ⌘ ⇧ ⇥ ⌫ and the pages) comes out beside it, 340 wide and as tall as the screen allows while a key stays key-shaped: no taller than 1.25 times its
  width, 65 pt here (60 left a band above and below; 72 made keys twice as tall as wide, founder 2026-11-08). The ten-across pages (字母, 符号)
  keep rows no taller than 1.4 times their width, at the bottom of the page by the dock's ⇧ and ⌘, as a keyboard's are, and goes away with the keys: a modifier is no use without keys to press, so putting them away lets go of any held on the Mac. The keys start out
  for the trackpad and put away for the picture. A 16:10 screen fits whole at full height with them put away. Turn the phone round to change hands.
- The microphone: the talk key and Voice Note both listen through the iPhone when Settings → Dictation → Use iPhone Microphone is on and
  the phone has microphone access; otherwise the Mac's. A voice note started from the phone asks it for its microphone (`ToPhone.listen`)
  and lets it go when the note ends. If the phone can't have it (a call), the note starts again on the Mac's microphone, quietly; the
  next note tries the phone again. Record (the screen recording) still uses the Mac's.
- Mint means listening (system.md §1). The words go large at the bottom of the pad, with Cancel, Structured and Translate.

## Keys

Pages of one shape, four rows, with tabs (常用 字母 符号 更多); one that grows scrolls a row at a time. Every key can be moved or changed, and everything
taken off the default page is in the key picker.

What earns a place on 常用, a row each so the rows can be learned (founder, 2026-11-08):

| Row | Keys |
|---|---|
| Editing | ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z ⌘A |
| Between things | ⌘Tab ⌘` ⌘[ ⌘] ⌃⇧Tab ⌃Tab (hold and slide steps both ways, so ⇧⌘Tab needs no key) |
| Acting | ⌘F ⌘K ⌘Space ⌃C ⌘T ⌘W (⌘K and ⌃C are written out: what ⌘K does depends on the app, and an icon on ⌃C would look like ⌘W, which can close a terminal) |
| Blurt | Snap, Record, Voice Note, Copy Text, Translate, Cards |

Off the page: anything a tap on a modifier and a key already in view can do (⌥⌫, ⌘⌫, ⌘↩, ⇧⇥, and ⌥L with the letters); what a tap on the picture does
(⌘L); and what's rarely needed on a phone (⌘S, ⌘P, ⇧⌘P, ⌘B, ⌘J). All Windows, App Windows and the desktop keys are on 更多, and three fingers do them anyway.
Find Pointer is about the whole screen, not the Mac's keys: it's a control by the tabs. 更多 and 字母 hold what only a computer has: F1–F12, Home, End,
Page Up and Down, and forward delete. The space bar is in the dock.

The **dock** stays put wherever the list is: ⌃ ⌥ ⌘ ⇧ ⇥ esc ⌫ ↩ space, and the talk key: what a phone's keyboard has no key for, and all four modifiers
side by side, because their state has to stay in sight. Esc Esc has no key of its own: tapping Esc twice does it. A key shows an icon and the key's
name, never what it's for; a few icons are drawn here (Keys/KeyMarks.swift) because they say it better: ⌘Tab is the Mac's row of apps with one
picked out, ⌘T ⌘W ⌃Tab a window with a tab bar, so they read as one family, ⌘A selected text with a phone's handles. The screen button stays a
display and lights up while it's on, like a modifier: a crossed-out eye over a live picture reads as off.

**The arrow key** is one key with four marked edges: tap towards an edge for that arrow, hold to repeat, drag for a run of them, tap then drag for ⇧
too. Where it goes matters more than how it looks: in a bottom row, down runs out of phone. So it's in the top row in portrait, and in the thumb's column in
landscape, with room every way. (Two rows of separate arrows came before this, and took too much room.)

**A key shows an icon and the name of the key, not what it's for** (founder, 2026-11-07): the same shortcut does different things in different apps,
and an icon says more in the room there is. What it's for lives in the key list and for VoiceOver. Any key can show text or an emoji instead; the
longer the text, the smaller it reads.

The sections: **常用** (24 keys, above), **字母** (the keyboard's own four rows, numbers on top, ten across, about the iPhone's key size), **符号**
(what ⇧ makes of them and the rest of the punctuation, the same size), **更多** (F-keys, navigation, the Mac's own moves). They're plain keys, so a
sticky ⌘ turns them into shortcuts. No key is on two pages or in the dock and a page (a test checks): 字母 had a space bar of its own and 符号 the
digits, ; and / again, until the founder asked why there were two space bars (2026-11-08). A page as it shipped is brought up to date; one its owner
changed is left alone. The one key shown twice is ⌘Tab in landscape with the keys out: on 常用, and in the thumb's column, where it has to be with
the keys put away.

On a touch landing in the list: keys that fire on lift can always be taken by the scroll. Keys that act at once (⌘⇥, ⌫, arrows) wait 120 ms or
for a slide sideways there, so a thumb meaning to scroll sends nothing. In the dock they act at once.

| Kind | Behaviour | Why |
|---|---|---|
| Plain | Fires on lift, slide off cancels, held still does nothing | A misplaced thumb costs nothing |
| Cycle (⌘⇥, ⌃⇥, ⌘\`) | Press holds the modifier and steps once; slide steps on, 22 pt per detent, left goes back; at the screen edge it keeps stepping, seven a second; lift lets go. The other keys dim and are out of play | A quick tap is "back to the last app"; holding reaches any of twenty apps |
| Arrows | One slot: drag for ticks every 24 pt; past 72 pt repeats, faster with distance; tap then drag adds ⇧ | No tiny D-pad, and text selection is one gesture |
| Sticky (⌘ ⇧ ⌥ ⌃) | Tap: next key or click. Double tap: locked. The Mac really holds it. Held 0.45 s: pressed on its own, down and up, and the Mac shows it | One thumb can't chord; ⌘-click and ⇧-arrows work everywhere. A lone ⇧ switches a Chinese or Japanese input method to English (founder, 2026-11-08: a tap only held it, so 。 kept coming out) |
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

On a Mac with no phone paired, nothing runs: no listener or Bonjour ad until Add iPhone… shows the code (opening
Settings → iPhone alone doesn't, so it never brings up macOS's Local Network prompt), and the session watch timer only runs
while a phone is connected.

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
counted. Encode 3 ms, decode 1.5–3 ms, no frames lost, no keyframes requested once stale frames were fixed.

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
  full height, between the two columns. Opening the keys leaves the stage beside them, so all of the picture stays in view. Corners are 6 pt: a rounded corner on a picture is a piece of the screen not seen.
  The button to turn it off is always outside the picture: it was once on top of it, white on white.
- **The phone owns the view; a pinch zooms it there and nothing on the Mac** (founder, 2026-11-07: with the screen off it stays ⌘+ / ⌘−). The first
  version scaled the picture about its centre and then the Mac cropped around the pointer, so the view jumped when the fingers lifted. Now it
  works like a photo: the point between the fingers stays under them, it stretches a little past the whole screen and springs back. The Mac is
  asked for that part of the screen up to about 7 times a second, at the same output size, so the text gets sharper the closer you look. Every
  frame says which part it shows (`RemoteCrop`, in the payload), and goes onto a plain layer in one commit with where that part belongs, so a new
  crop changes only the sharpness. A sample-buffer layer can't do that: it shows frames on its own clock, and each crop change twitched the picture. ScreenCaptureKit doesn't say which frame took a new crop, so frames wait out each change and the latest goes when it's done.
- **Two fingers scroll the Mac, zoomed in or not**, both ways, as on its own trackpad, and what's under the fingers scrolls: the pointer goes there
  first, so the session list and the conversation beside it in Claude Code each scroll on their own (founder, 2026-11-08). An earlier version made
  two fingers move the zoomed picture, as in Photos, and the article under them didn't scroll. The picture moves with the pointer instead: one
  finger is the pointer, which pushes the view when it nears an edge, and a pinch moves it as it zooms. Two fingers moving together are never quite
  the same distance apart: a scroll stays a scroll until they come 36 pt apart or together, then it's a pinch and nothing jumps. A last sight of
  the whole screen sits under the video, so a move past what's been sent shows that until the sharp part comes. If the view has moved off the
  pointer, the next touch brings the pointer to the middle of the view: what you touch is what you're looking at. The pointer slows with the square
  root of the zoom. The arrow key is keys, not a scroll: it moves a cursor or a selection.
- **The pointer isn't in the video.** Its position goes on its own, 60 times a second and twice a second regardless (they can be lost), and the
  phone draws it, moving it ahead on its own strokes, so it's never a frame late. The Mac has the last word 120 ms after a stroke, or 1.5 round
  trips. An earlier version dropped what arrived during a stroke, and nothing arrives after one, so the two drifted apart stroke by stroke and
  clicks missed (founder, 2026-11-07). Its shape goes when it changes.
- **The glass is the screen.** With the picture showing, a tap clicks what's under the finger, two fingers right-click there, a hold brings the pointer
  to the finger, and hold then drag follows it, so the pointer's position stops mattering for anything big enough to hit. Moving a finger is
  still the trackpad, for what isn't. A touch off the picture does nothing. Settings → Touch Mode (触控模式) turns it off: taps and scrolls then act
  at the pointer, as on a trackpad.

### What it costs (2026-11-08)

One choice in Settings → Mac Screen, not a frame rate, a resolution and a bitrate to work out. It sets a ceiling (ScreenPlan):

| | Width | Most Mbps | fps | Most MB a minute |
|---|---|---|---|---|
| Auto, same network | the phone's | 12 | 60 | 90 |
| Auto, Wi-Fi elsewhere | 1800 | 4 | 30 | 30 |
| Auto, mobile data | 1440 | 2 | 24 | 15 |
| Auto, Low Data Mode, or Data Saver | 1280 | 1 | 15 | 8 |
| Sharp, away / Balanced | the phone's / 1800 | 8 / 4 | 30 | 60 / 30 |

Under the ceiling (RemoteRate): the phone reports every second what arrived, every five while nothing does. Away it starts at half and climbs while
the picture uses what it has. A growing round trip, a full socket, too much on the way, or 5 % of frames lost over five seconds (one lost frame on
Wi-Fi says nothing) bring it down at once, to a little under what's getting through, then it waits to see the effect. It doesn't climb back past 90 %
of where trouble began for 30 s. Each frame gets at least 30 kbit: with less to spend there are fewer frames, because text matters more than motion.
Over the relay's stream the Mac stops sending once more than 1.5 s of picture is on its way, because keys go the same way and mustn't wait behind it,
and doesn't answer a keyframe request while one is in that stream. If the phone gets nothing for 6 s, those bytes went down a dead path: it starts
over from a keyframe. On a direct path keyframes go in paced batches at twice the rate, since one lost piece costs the whole frame. After 45 s
untouched, away from home, it goes to 5 fps until a finger lands. Not done: NACK or FEC for lost pieces, long-term references instead of keyframes.

A window that isn't changing still arrives from ScreenCaptureKit as complete frames at full rate, and used to cost 0.1–0.5 Mbps. Frames are now
compared byte for byte and skipped. When the picture stops the last frame goes again at real-time timestamps, until a resend comes out under 1.5 KB
(usually two or three, the largest 11–16 KB on the thin pipe); then nothing is sent.

Measured on the made-up terminal window scrolling at 30 Hz, the worst case for a screen:

| Test | Result |
|---|---|
| Data Saver, scrolling | 0.77 Mbps, 15 fps, 12-pt English and Chinese readable |
| Still window | 2–3 frames after stopping, then 0 |
| Thin pipe, 480 kbps out of the Mac, through a local relay, scrolling | one keyframe, no reconnect, steady 300–320 kbps at 7 fps |

The microphone is 256 kbps of plain PCM while talking, about 2 MB a minute; a take is seconds long, and what the recogniser hears matters more here.

### Several displays (2026-11-09)

A Mac with a monitor or two besides its own screen. Before this, the phone saw only the display the pointer was on when the picture
started. The 左侧桌面/右侧桌面 keys and three fingers sideways are Spaces, not displays.

- **One display at a time, the one the pointer is on.** The phone's screen is small, and the pointer is where the work is. Push the pointer
  past the edge onto the next display, from the phone or the Mac's own mouse, and the picture goes with it. It goes once the pointer has
  really crossed: 150 ms on the other display or 20 pt into it, so a pointer resting on the edge doesn't flip it back and forth.
- **The screen button chooses, and nothing new takes room** (the founder's bar: space is the point). With two or more displays it draws
  them as they stand, each on a foot, the one shown filled. A tap still turns the picture on and off. Press and slide sideways steps to
  the next display or the one before, one per 36 pt, in the order they stand, as the cycle keys step; lift to show it. Hold, and a map
  stays up: the displays to scale, named, and Follow Pointer (跟随指针) under them. The settings button's hold switches computers the same way.
  A separate control was tried on paper first: the top row has no 36 pt to spare (the tabs would drop to 30 pt each, and 字母 / Letters
  already shrink to fit).
- **The map takes the keys' place, never the picture's.** In portrait and on a big screen it covers the rows of keys under the top row,
  exactly their size, so the picture stays in full view while choosing. With the keys put away (a phone on its side, an iPad with the
  keys away) there's nothing under the button, so it comes up beside it, only while choosing.
- **A display chosen stays chosen** (a small pin on the button) until Follow Pointer, or until it's unplugged: then it's back to following.
  Choosing moves the pointer to the middle of that display, where the eyes go next, and the Mac shows the display's name for a moment at
  the bottom of it. A switch by following shows nothing on the Mac: the person moved the pointer there and saw it go. With the chosen
  display pinned, the pointer may leave it: the picture stays, the pointer isn't drawn, and a tap on the picture brings it back there.
  Choosing with the picture off turns it on: choosing what to see is asking to see it.
- **Another display is another screen**: the view starts whole. The last picture of the display left stays up and fades (0.22 s) as the
  first frame of the new one arrives, so the change is seen and never black; frames still on their way from the old one are told apart by
  their shape and dropped.
- **No gesture on the picture for it.** Three fingers sideways are Spaces, and the founder's; giving them a second meaning by context is
  a guess the hand can't see. An edge push already works without anything new: in following, the pointer pushed past the edge is the
  switch. In Touch Mode a dragged pointer stops at the picture's edge, so a drag can't change display by accident, and pinned means stay.
- **The pointer drawn on the phone crosses as the Mac's does**: the phone knows the arrangement, so its own guess runs off the picture
  onto a neighbour and stops only at the edge of them all, instead of sticking to the edge until the Mac says otherwise.
- **Mac**: the same ScreenCaptureKit stream changes its filter and configuration to the new display (`updateContentFilter`, macOS 14;
  on 13 the stream starts again), with an encoder of the new shape and a keyframe. The phone asks for an output box that fits every
  display's shape (`PadViewController`), so a switch needs no new request. Before that, each switch restarted the whole stream 1.5 s later.
  Displays come from `CGGetActiveDisplayList` (mirrors left out), names from `NSScreen`, changes from `CGDisplayRegisterReconfigurationCallback`.

Measured 2026-11-09, simulator ↔ this Mac (MacBook Pro 1728×1117 pt + DELL P2725QE at 1920×1080 pt, side by side), loopback network, three
runs of six switches (both ways, chosen and followed):

| From | To | ms |
|---|---|---|
| The Mac starts the switch | the filter and configuration changed | 52–98 |
| The Mac starts the switch | the new display's first frame (a keyframe, 30–82 KB) sent | 91–146 |
| The phone hears `screenView` | that frame is up | 38–63 |
| A display chosen on the phone | its first frame up on the phone | 105–167 |

The follow switch takes the same, after the 150 ms the pointer has to stay. Not measured on a real phone or over Wi-Fi: add a round trip.

Test hooks (debug builds): with `BLURT_TEST_COMMANDS=1` and nothing posted, the Mac moves a pretend pointer, so following it from display to
display is tried without moving anyone's real one. On the phone, `BLURT_DISPLAY_TEST=1` walks the switcher by itself (picture on, map held,
each display chosen, a slide, back to following, strokes across and back) and logs each step on the Mac (`display_test`, `display_switch`).

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
  for Claude Code or Codex that does the setup. The address is in the pairing code and reaches the phone again inside each sealed session, so the phone has nothing to configure.
  `ws://` works too: what passes is sealed either way, and it needs no domain. The room is an HMAC of the pair's key. The relay has no key.
- **Several Macs, one relay:** a phone keeps a list of Macs, each with its own key and so its own room: one address serves them all. Pair each Mac once
  by its code, from any network if that Mac has a relay. A Mac with no relay takes the one a phone already uses for its other Macs, unless its owner
  cleared the field, and Settings says it came from the phone. A code used over the relay needs a yes on the Mac, in Settings: otherwise a photo of the
screen would be enough from anywhere. A code only becomes a Mac on the phone once that Mac has answered it, so a stale one can't hurt a working pairing,
and a Mac paired again replaces its old entry on both ends. Tap a Mac in Settings to switch, or hold the
  settings button on the main screen; each row says whether it's connected, on this network or reachable by relay. A Mac can have several phones, one
  driving at a time. Removing on the phone tells the Mac.
- **Direct:** once a session is up on the relay, both ends trade addresses inside it (public IPv6, the IPv4 a STUN server sees, LAN
  addresses) and send each other packets to open their firewalls. The first that answers carries the pointer and video. Some networks can't
  do this (symmetric NAT, mobile carriers' CGNAT without IPv6); then it stays on the relay.
- **Over the relay** pointer messages drop to 30 a second and a frame is skipped rather than queued; the picture follows §What it costs. Back home the
  local network takes over by itself, checked every 10 s.
- With an address set, the Mac holds one idle WebSocket per paired phone. No address, nothing leaves the network. The Mac stays awake only while
  a phone is connected, so a sleeping Mac is out of reach.

Measured from this Mac through a US VPN, Cloudflare's IAD: relay round trip about 630 ms. From a Chinese network Cloudflare's free plan usually
lands on the US west coast or Hong Kong, so a server in China is much nearer. The founder's own relay is `relay.agihunt.info`, on the
agihunt.info server in Beijing (`blurt-relay.service`, certificate by acme.sh, `/etc/cron.d/blurt-relay-cert`): 10 ms from home on a direct route.
A VPN that sends the relay's domain abroad undoes that: such a domain needs a direct rule.

Quota, from Cloudflare's Durable Objects pricing page: 100,000 requests a day on the free plan, incoming WebSocket messages count 20:1, outgoing
are free, reset at 00:00 UTC. A screen session on the relay is about 70 incoming messages a second (15 video frames, 30 pointer, 30 cursor), so
3.5 requests a second: about 8 hours a day, shared by every user. Direct and local traffic doesn't count.

A server has no such quota, only its bandwidth: the picture over a relay is up to 2–4 Mbps per person and follows what the link carries. The Beijing server's outbound is a flat 3.4
Mbps, enough for its owner and no one else.

## Security

A key press here is a key press on the Mac, and earlier apps in this category had unauthenticated RCE over UDP.

- Pairing: QR code with a 256-bit key, good for one connection within two minutes. That connection spends it and is sent a
  new key inside the sealed session; the phone becomes a device only when it confirms keeping it. A photo of the code is
  worth nothing afterwards.
- **Every new phone needs a yes on the Mac, on any network**, and both show the same six digits from the handshake transcript and a nonce
  the phone committed to in its hello and reveals only after the Mac has answered, so nobody in the middle can choose an answer that makes
  the digits match (as Bluetooth's numeric comparison does). The yes is for the phone showing them. A code answers at most 8 handshakes,
  and a phone gives a code up after 3 sessions that never came to a question, so the digits can't be tried for. A question nobody
  answers is a no after two minutes. One new phone at a time; another using a code meanwhile is turned away, and the answer is tied to the
  session it was asked about. Allow is not the default button. (Security review, 2026-11-08: a code used on the local network went
  straight in, so a photo of it plus any route to the port, peer-to-peer Wi-Fi included, was enough; and a yes could be given to whoever
  asked last.)
- **A session opens only with the key its id has now**, compared in constant time. The review found a hole: a handshake begun with a
  code on a waiting relay connection stayed open after the owner paired on the local network, and its first sealed frame, hours later,
  was taken as the paired phone's. Now that's refused, the relay connection in a spent code's room is closed, and a waiting relay
  connection that has answered a hello has 6 s to see a sealed frame.
- Only a phone the owner just said yes to may set this Mac's relay or drop an older entry of its own.
- Test hooks (a code on stdout, keys in a file, an automatic yes, snapshots to a folder) exist in debug builds only, so no other program
  can borrow a release build's Screen Recording or microphone through them.
- Session: X25519 ephemerals, HKDF salted with the paired key and bound to the transcript, one ChaCha20-Poly1305 key each way,
  counter nonces. A stolen paired key can't read past traffic. UDP packets are sealed too; replays and overtaken packets drop.
- Blurt doesn't listen until a phone is paired. Nothing but the handshake is acted on before a session has greeted. Before
  the handshake a frame is at most 1 KB, at most 16 handshakes at once, a refusal closes the connection, and a UDP flow that
  isn't the session's is cancelled on its first packet.
- Links from outside the app ask before pairing: a web page can open `blurtremote://`.
- The relay and direct paths use the same handshake and seals as the local network; neither can read or forge a frame. Candidates are
  only exchanged inside the sealed session, between paired devices.
- A refused handshake is unauthenticated, so it's only believed when no other way in worked.
- Keys: iOS Keychain (this device only), macOS login Keychain. Sequences are capped (32 steps, 3 s of waits), text at 64 KB; a screen
  request's numbers are clamped. The 1 MB frame limit applies only after the first sealed frame.
- Left as they are (low): the relay can see room names, timing and sizes and can drop traffic, never read or forge it; a refusal
  during pairing is unauthenticated; scanning a code that claims an already paired Mac's id replaces that entry only after a confirmation
  (from the camera or the in-app scanner alike); a phone the owner approved may still offer this Mac the relay another of its Macs uses.

Peer-to-peer means anyone in radio range can reach the handshake (no further), and sees the Bonjour name and Mac id.

## Open

- All pt and ms values above are starting points to tune by hand.
- Not tried away from home on a real phone: relay latency from China, whether a direct path opens over mobile data.
- Not tried on a real phone: tap-where-you-touch against real windows, hold-and-drag on Blurt's area selection.
- Several displays (§Several displays): not tried on a real phone or with a real finger on the button (the switcher was walked by its test
  hook and drawn by `DisplaySwitchTests`), nor with three displays, one above another, or a display unplugged mid-picture.
- macOS Local Network and firewall behaviour for the signed release app.
- Bare letters typed as keys while the Mac's input method is on (digits are fine) go into its composition.
- Tap then drag clicks once first (the click can't wait for what comes next without delaying every tap).
- App Store: needs the bundle id registered, screenshots, and a price decision (reviews say: no subscription, no ads).

## iPad and iPhone Duo

2026-11-09. Status: the iPad is tested on the iPad Pro 13" and 11" (M4) simulators. The iPhone Duo runs closed on its own simulator (Xcode
27.2, iOS 27.2), in portrait and turned both ways, and its open display, its folds and opening mid-session are tested as layouts at its sizes
(unit tests, and renders of the real main screen). The simulator couldn't be opened here: no `simctl` command moves the hinge, and Device
Hub, which has the hinge slider, needs macOS 26.6 (this Mac runs 26.5).

What UIKit reports on the Duo closed (a debug build logs it as `BLURT_ROOM`):

| | Size | Safe area | Reserved regions |
|---|---|---|---|
| Closed, portrait | 466×678 @3× | right 84, bottom 34 | occlusion: the lens 37×37 at (400, 29), and the region kept clear around it, 84×82 in the top right corner |
| Closed, turned left / right | 678×466 | right 84 / left 84, bottom 34 | the same corner: bottom right / top left |
| Open (the panel) | 669×951 natural, 951×669 held open | not read | not read |

The hinge reports `closed`, angle 0. The 84 pt band is where iOS puts its bars on this display (Apple: toolbars and the status bar move to
the side). With the status bar hidden nothing is drawn there, so only the camera's corner is avoided: the keys get the whole width (450 pt
instead of 374) and the stage starts below the corner. The picture is 398×249, larger than on an iPhone 17 Pro (386×241). The open panel is
portrait in its own coordinates, but the phone open is wider than tall (164.6×117.8 mm), so held open the UI is 951×669 with the fold
running down the middle; turned, 669×951 with the fold across. That's how the tests take it.

**The layout depends on the room, not the device.** `PadLayout` takes six inputs: the view's size, the safe area, the fold and the cameras
as UIKit reports them (`UIView.reservedRegions`, iOS 27.1), the shape of the computer's screen, and the hand. It reads no device names, no
`userInterfaceIdiom`, and no orientation (Apple's Duo guidance says the same). An iPad window dragged to any size, Split View, Slide Over,
the Duo opening and a phone turning all go through the same arithmetic, and the tests run it at every size. There are three kinds:

| Room | Kind | Where it happens |
|---|---|---|
| at least 616 pt across and 520 down | big | an iPad full screen, Split View ½ and ⅔ on a 13", Stage Manager, the Duo open either way up |
| narrower, taller than wide | portrait | a phone, Split View ⅓ and an 11"'s ½, Slide Over, the Duo closed |
| shorter than 520, wider than tall | landscape | a phone on its side, a short window, the Duo closed and turned |

The big layout needs 616 pt: two halves wide enough for the dock's keys to stay key-shaped (no taller than 1.25 times their width), plus
a trackpad of at least 140 pt between them. In a narrower window, a portrait layout keeps the phone's block of keys, at most 456 pt wide.
The keys stay phone-sized and never stretch.

### The big stage

```
┌──────────────────── stage: picture, or trackpad ────────────────────┐
│                                                                      │
└──────────────┐                                       ┌──────────────┘
 ⚙ ⌖ ◐ ⌨ [⌘⇥]  │   trackpad between the thumbs          │ [↕] 常用 字母 符号 更多
 [ ][ ][ ]     │                                       │     [ ][ ][ ]
 …four rows…   │                                       │  …four rows…
 [⌃][⌥][⌘][⇧][⇥]                                       [esc][⌫][↩][␣][🎤]
```

- **A computer's screen is wider than these displays.** It's 16:10, against an iPad's 4:3 and the Duo's 1.42. A picture as wide as the
  display leaves a band under it, and the keys go there, so they cost the picture nothing. That's why the stage is on top and the keys
  below. A phone on its side is the opposite case (2.2:1): the free room is at the ends, so its keys go beside the picture.
- **Two halves, one per thumb.** They sit in the lower corners, where a two-handed grip puts the thumbs. A thumb sweeps about 236 pt from
  the edge it holds, and that is a half's width. Each page splits three and three (the letters five and five), and the dock five and
  five. The modifiers and ⇥ go under one thumb; esc, ⌫, ↩, space and the talk key go under the other. So one thumb holds ⌘ while the other
  presses C. The talk key is in the corner. Left-Handed mirrors the halves.
- **The top row of each half.** One half starts with the rarely needed controls at the edge (settings, find the pointer, the screen, the
  system keyboard), with ⌘Tab nearest the middle so its slide can run over the trackpad. The other half has the arrow key nearest the
  middle, then the tabs. The arrow key gets room every way: never at an edge, never in the bottom row.
- **A trackpad between the thumbs.** On anything this big, the stage is out of the thumbs' reach. With no picture, the stage and this pad
  are one glass with one outline, a T that reaches down to the thumbs. With the picture showing they're two things: a screen and a trackpad.
  A pinch on the trackpad zooms the view about its middle, and the pointer moves the view.
- **The keys go away only where that helps.** Sometimes the whole deck fits in the band a whole 16:10 picture leaves (an iPad upright, the
  Duo turned tall). Then the keys stay out and there's no switch. Elsewhere (an iPad on its side, the Duo open), they start out for the
  trackpad and put themselves away when the picture shows, down to two rows: the top row and the dock. A tab brings them back on its page,
  and tapping the page that's showing puts them away again. The dock never moves.
- **The output follows the stage** (`PadLayout.outputPixels`). The computer is asked for as many pixels as the stage has, at the size a
  zoomed picture fills it. A Split View window costs less, and opening the Duo asks for more. It's asked again only when that size changes
  by more than 8 %.

Measured at these sizes (points; "picture" is a whole 16:10 screen):

| Room | Stage, keys away / out | Picture, keys away / out | Keys |
|---|---|---|---|
| iPad Pro 13" landscape, 1376×1032 | 1356×893 / 1356×685 | 1356×847 / 1096×685 | page 75×48, dock 43×48 |
| iPad Pro 13" portrait, 1032×1376 | 1012×1029, keys always out | 1012×632 | the same |
| iPad Pro 11" landscape, 1210×834 | 1190×695 / 1190×487 | 1112×695 / 779×487 | the same |
| iPad 13" Split View ½, 683×1032 | 663×685, keys always out | 663×414 | the same |
| iPad 13" Split View ⅓, 438×1032 (portrait kind) | 422×687 | 422×263 | page 66×48 |
| Duo open, 951×669 | 931×530 / 931×322 | 848×530 / 515×322 | page 75×48, dock 43×48 |
| Duo open, turned tall, 669×951 | 649×604, keys always out | 649×406 | page 75×48, trackpad 161 wide |
| Duo closed, 466×678 (portrait kind, measured) | 450×249 | 398×249 | page 71×48 |
| Duo closed, turned, 678×466 (landscape kind, measured) | 514×454 keys away | 514×321 | thumb column 56 wide |
| iPhone 17 Pro portrait, for comparison | 386×475 | 386×241 | page 60×48 |

### The fold

The fold is read with `.includeInactive`. Fully open, it's still reported (an inactive line down the middle), so the keys are already
clear of it, and folding moves nothing but the stage. Apple's guidance says the same: "keep your layout from jumping when the region
becomes active." Nothing small goes on the fold: no key, no small target, and never the one-finger scroll strip. The strip moves to the
other edge, or stops short of a fold that runs across. The words, chips and messages on the stage keep to the thumb's side. The trackpads
may cross the fold, because fingers cross a crease without trouble.

- **Open flat**: the big stage, with the gap between the halves where the fold runs.
- **Partly folded like a laptop** (the fold runs across: `reservedRegions(kind: .division)` is active and wider than tall): the picture
  takes the upper half, to be viewed from a distance. The lower half lies on the table and holds the keys and the trackpad. Fingers type
  there, so the pages' keys grow into the room (75×72 at the Duo's size, still key-shaped) instead of leaving a gap under the fold.
- **Partly folded like a book** (the fold runs down the middle): the picture goes on one page. The other page, by the holding hand, is a
  phone's remote: pad, top row, pages and dock.
- **Tent and stand** get no layout of their own. If the system gives the app half the display, that's a size like any other.
- No posture is guessed from the accelerometer, only read from UIKit. `UIHingeInteraction` is used only to ask for a new layout when the
  hinge moves.

The fold and the cameras come through `Pad/Surroundings.swift`. It compiles only against UIKit 9127.0.85 or later (the iOS 27.1 SDK) and
runs only on iOS 27.1 or later. Built with Xcode 26, it returns nothing and the layout goes by size alone. Debug builds and tests can
pretend there's a fold (`Pretend.surround`).

**Opening the Duo mid-session**: the scene is resized. The connection belongs to the app, not the view, so nothing reconnects.
- Touches in flight end cleanly (`letGo`): a drag lets go, a scroll ends, a pointer's button comes up.
- Latched modifiers stay held.
- The zoomed view keeps its middle (`ViewPort.reshape`).
- The keys go back to their starting state only when the layout changes kind (closed portrait to open big), not at every step of a window
  being dragged.
- The stream asks for the new output size 1.5 s later, and the last picture stays up until the new one arrives.

On the outer display the camera sits in a corner, not in the middle of an end. With the phone on its side, the controls stack clear of the
camera (below it, or above it turned the other way) instead of around it; UIKit reports the lens and the region kept clear around it, and
the layout keeps out of both.

### Input on an iPad

- **A keyboard** (Magic Keyboard, Smart Keyboard, Bluetooth). Its keys are the computer's (`Pad/HardwareKeys.swift`).
  - Keys go by position (the HID usage), so the computer's own keyboard layout applies.
  - Modifiers are held exactly as long as they're held here, so ⌘-click on the pad and ⌘ held through Tab Tab Tab both work. Two physical
    keys can be one modifier on the computer (⌘ and Control are both Ctrl on Windows): it goes down with the first key and up with the last.
  - Other keys are pressed, and repeat while held, on the iPad side, so a lost "up" can't leave a key stuck down. As on the screen, nothing
    destructive repeats: esc, Return, ⌃C.
  - On Windows and Linux ⌘ is Ctrl by default, so ⌘C copies as a Mac user's fingers expect. Settings → "⌘ on This Keyboard" makes it the
    Windows or Super key instead. Control is Ctrl, and Option is Alt.
  - Tab, the arrows and esc are claimed ahead of iPadOS's focus movement and dismiss (`wantsPriorityOverSystemBehavior`, with every
    combination of modifiers).
  - While the system keyboard's text field is typing, the keys belong to it.
- **What iPadOS keeps**: ⌘Tab, ⌘Space, ⌘H, and the Globe key and its shortcuts never reach an app. Holding ⌘ may still show iPadOS's own
  shortcut list. For those, use the on-screen ⌘Tab key or the computer's own keys.
- **A mouse or trackpad**: with the picture showing, the iPad's pointer over the picture is the computer's pointer, at the same spot
  (absolute, at most 60 updates a second). Clicks, right-clicks (the secondary button) and drags are its buttons. With no picture, it moves
  the computer's pointer relatively, at 1.5 times its own speed and without the phone's curve, since the iPad has already accelerated it.
  Two fingers on a trackpad, or a wheel, scroll through the same scroll phases as the glass (`UIPanGestureRecognizer`,
  `allowedScrollTypesMask = .all`, no touches), and a flick coasts on the computer. The iPad's own pointer is hidden over both pads
  (`UIPointerStyle.hidden()`), because the computer's pointer is the one drawn.
- **Apple Pencil**: with the picture showing and Touch Mode on, the Pencil is the mouse button where it lands. Down presses, a stroke
  drags, up lets go: a tap is a click and a stroke selects. With hover (iPad Pro, M2 and later), the computer's pointer follows the tip
  before it touches. With no picture, the Pencil works like a finger on the trackpad.
- **An external display or Stage Manager**: nothing reads `UIScreen.main` for layout. The window's own size and scale decide. A window's
  controls along the top stay clear (`edgeInsets(for: .safeArea(cornerAdaptation: .vertical))`).

### Develop

In debug builds, `SIMCTL_CHILD_BLURT_REMOTE_PRETEND=1` lights the keys as if connected, and `=screen` also puts a made-up desktop where
the picture goes. With `TEST_RUNNER_BLURT_RENDER_DIR` set, `RenderTests` draws the real main screen to PNGs at every room above: iPad sizes
and multitasking widths, and the Duo open, closed, turned, folded like a laptop and folded like a book. A magenta band marks the fold.

### Open

- The Duo open hasn't been run: no `simctl` command moves the hinge, and Device Hub (Xcode 27.2's, with the hinge slider) won't launch on
  macOS 26.5. Unknown until it is:
  - the open display's safe area and the fold's band when partly folded (the tests take 24 pt);
  - whether the scene resigns active while the phone opens. If it does, latched modifiers are let go, as when leaving the app.
  To check: open it in Device Hub with the debug build running and read the `BLURT_ROOM` and `BLURT_HINGE` lines in its log.
- The simulator here couldn't be turned on its side. Simulator's Rotate turned the window but not the screen, for every app. iPad landscape
  and multitasking are judged from the renders, not from screenshots of the running app.
- Not tried with a real keyboard, mouse, trackpad or Pencil on an iPad. The simulator doesn't pass through hover, pointer buttons or HID
  usages faithfully.
- With no picture showing, the iPad's pointer stops at the pad's edge, and so does the computer's pointer. Pointer lock
  (`prefersPointerLocked` with GCMouse's raw movement) would fix that, but the mouse could then no longer reach the keys.
