# Design: a live picture (the computer's screen on the phone, as close to real time as the network allows)

2026-11-09. Status: built on the reference path (Mac host ↔ iPhone app), measured on this Mac (M5 Max, macOS 26.5) with the iPhone 17 Pro
simulator (iOS 27.2) over loopback, with a made-up network laid over it. Specified below for the Rust host (Windows, Linux) and the Android app;
the Android app's receiver is built and measured on the emulator (§Android), and the Rust host's repairs are built and measured against both
phone apps (§Rust host).
Not yet tried on a real iPhone over Wi-Fi. How the picture works and what it costs: [remote.md](remote.md) §Screen; the wire:
[remote-protocol.md](remote-protocol.md) §Repairs.

The founder's ask (2026-11-09): the live desktop still doesn't feel real-time. Is 60 fps too low? Is there room in compression, given that a
screen of text is mostly still? A few hundred MB to 1 GB an hour is fine, but no data spent for its own sake.

## What made it feel slow

### Where a frame's time goes

Every frame now carries its timing through each stage (`ScreenTiming` on the Mac, `ScreenStream.report` on the phone), and the phone's display
link says when it reaches the glass. A 1512×945 window of made-up terminal text scrolling smoothly at 60 Hz (`testwin2 scroll`), Auto at
home (1866×1206, 12 Mbps ceiling), clean loopback, ms from the Mac composing the frame:

| Stage | p50 | p95 | What it is |
|---|---|---|---|
| ScreenCaptureKit hands it over | 0.8 | 3.1 | composed → our callback |
| Encoded, pieces sent | 7.1 | 9.6 | HEVC, low-latency mode: 6.1 ms p50 of it |
| First piece at the phone | 7.2 | 9.8 | sealing, UDP |
| Last piece at the phone | 8.0 | 10.5 | a 25 KB frame is 22 pieces |
| Decoded | 10.7 | 13.5 | 2.5 ms in the simulator's decoder |
| On the layer (main thread commit) | 11.5 | 14.2 | |
| At the glass (next vsync) | 15–21 | 26–27 | plus up to a frame of waiting for the 60 Hz panel; its p50 moves 4–10 ms between runs with the phase |

(The final build; before the changes below the same test read 0.7 / 6.9 / 7.3 / 8.2 / 11.0 / 11.7 / 19.2 at p50, at 53 frames a second
instead of 59.) So a clean path is about 11 ms from the Mac's frame to the phone's layer and 15–21 ms to its glass, plus the Mac's own display
path. The encoder (6 ms) and the panel's vsync (4–10 ms) are the two largest parts, and neither is the network. This was already good. **What made it feel slow is what happens when
anything goes wrong**, and on Wi-Fi something always does.

### A lost piece cost seconds

A frame is cut into 1,180-byte pieces: 24 for a scrolling frame, 146 for the first keyframe. One piece lost dropped the frame, every frame
after it, and asked for a keyframe; the Mac answered at most every 0.7 s; the keyframe was 100–170 KB and itself 100+ pieces that could lose
one; and the rate controller read the losses as congestion and cut the bitrate, so text went soft for 30 s after. Measured with pieces dropped
at random on the phone (`BLURT_TEST_LOSS`, bursts of 2–3 as Wi-Fi loses them), scrolling, before the repairs:

| Pieces lost | Frames shown / s (of 59) | Frames dropped in 12 s | Keyframes asked | Longest freeze | Bitrate after |
|---|---|---|---|---|---|
| none | 59 | 0 | 0 | 35 ms | 12.2 Mbps |
| 1 % | 24–34 | 299–408 | 27–36 | 1.3–1.6 s | 4.2–4.4 Mbps |
| 3 % | 2 | 446 | 51 | 2.3 s | 7.5 (nothing decodable) |
| 1 %, the 15 Hz terminal (`testwin`) | 8 (of 14) | 97 | 26 | 2.7 s | 5 Mbps |

The real iPhone 16 runs in remote.md lost nothing in 12 s, but a session is hours: one loss every few minutes is enough to freeze the
picture now and then and soften it for half a minute, which reads as "not real time".

### Stalls are Wi-Fi's, and only Wi-Fi's

remote.md's p95 of 57–126 ms and max of 94–406 ms on the iPhone 16 are frames arriving late, not lost: the pointer's own 10 ms probes show the
same 75–205 ms gaps at p99 with the video off. A radio dozing between beacons, a busy channel, a scan: everything stops, then arrives at once.
Laid over loopback (`BLURT_TEST_STALL=80:2`, 80 ms every 2 s): age max 88–93 ms with or without any repair. Nothing at either end can deliver
bytes through a radio that isn't sending; what the ends can do is not make it worse (no keyframe storm after it, no frame given up that was
only late), show the newest frame the moment it arrives (done), and mark the video so a Wi-Fi access point queues it ahead of bulk traffic
(see §Not built).

### Crop changes hold frames

ScreenCaptureKit doesn't say which frame took a new crop, so frames wait out each change (remote.md §Screen). Measured: each change holds
frames 23–27 ms (p50; up to 209 ms), and panning at 2× (the view moving 7 times a second, `pan2`) drops the frames shown from 59 to 44–46 a
second (36–41 before the changes below), with gaps up to 68 ms, and a crop asked for showed on the phone 36 ms later (p50). Built: §5.

### Frame rate

Frames past the panel's rate are never seen: on the founder's iPhone 16 (60 Hz) 60 is the most that helps, and the phone already shows only the
newest decoded frame at the next vsync. What helped was **capturing** at 120 on a 60 Hz content: at 1/60 s ScreenCaptureKit's grid beats
against the app's own 60 Hz drawing and 7 frames in 60 fell between captures (53 fps of a 60 Hz scroll). See §What was built, 4.

## What was built

The first three are offered by the phone in its screen request and used only if the host names them back in `screenView` (remote-protocol.md
§Repairs), so a phone or host before 1.0.15 goes on exactly as before; 4–6 change nothing on the wire. Code: `BlurtRemoteKit/RemoteVideoRepair.swift` (wire, receiver,
history, parity: pure, with tests), `BlurtApp/Remote/RemoteScreenRepair.swift` (the Mac's half), `ScreenStream.swift` (the phone's).

### 1. NACK: missing pieces sent again (`nack`)

The Mac keeps its last second of pieces (at most 6 MB). The phone's receiver (`RemoteVideoReceiver`) holds frames in order and names what's
missing; the Mac sends those pieces again, byte for byte. At home that's back in a few ms, before the frame is due; the frames behind it wait.

- A piece is asked for when a later piece of its frame has arrived, a later frame has begun, or its frame has been quiet for max(30 ms, 2 RTT)
  (the end of a frame, on a still screen). A whole frame missing (a gap in the numbers) is asked for whole.
- Asked again after max(12 ms, 1.5 RTT), at most 4 times, and never into a stall (nothing at all for 20 ms).
- **Patience**: frames wait behind a missing one at most min(150 ms, max(40 ms, 3 RTT + 20 ms)) while other pieces keep arriving; during a
  stall the clock stops, up to 350 ms. Then that frame is given up (see 2).
- The Mac sends again at most max(300 KB, bitrate / 16) a second: past that the network is the trouble, and the rate comes down instead.

### 2. LTR refresh instead of keyframes (`ltr`)

VideoToolbox marks frames it may refer back to (`kVTCompressionPropertyKey_EnableLTR`; each such frame carries
`kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`). The Mac flags them, the phone acknowledges each once decoded (batched, every 20 ms at
most), and the Mac hands the tokens back to the encoder (`kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`). A frame given up is answered with
`kVTEncodeFrameOptionKey_ForceLTRRefresh`: a P-frame from an acknowledged frame, flagged *refresh*, which the phone decodes without anything
in between. Apple's WWDC21 session showed this with H.264; it works with HEVC in low-latency mode too. Measured with the encoder alone
(`scratchpad vt/ltr.swift`: 2000×1250 synthetic text scrolling 2 px a frame, frames 60–63 never decoded):

| After the loss | Size of the recovering frame | Decoded | Picture (PSNR) after |
|---|---|---|---|
| keyframe (before) | 856 KB | 56 / 56 | 42 dB mean, 34 min: the rate controller pays for the keyframe for a second |
| LTR refresh | 6.8 KB | 56 / 56 | 54.7 dB mean, 53.5 min: as before the loss |

With repairs, the periodic keyframe every 600 frames (every 10–12 s of scrolling, 100–170 KB at once and the frames around it starved) is
gone too: nothing needs it. A decoder error still asks for a real keyframe, and a host without LTR answers "lost" with one.

### 3. Parity (`fec`)

One XOR parity piece for about every G pieces mends any one loss in its group without asking. The groups are interleaved (piece i is in
group i mod n), so a burst of up to n pieces lost in a row costs each group one. At home NACK is cheaper (back in a few ms, and
costs only what was lost); parity is for a round trip too long to wait for. The Mac picks G from the phone's reports: round trip ≥ 30 ms and
pieces asked for again > 5 % → G = 4, > 1 % → 8, > 0.2 % → 16, else none; under 30 ms, G = 8 only past 10 % loss. WebRTC draws the same
line (NACK only below 20 ms round trip). Over the relay's stream there's no loss to mend and none is sent.

### 4. Frames at the panel's rate, captured early

- At home the phone asks for its panel's top rate: 120 on ProMotion (iPhone Pro, iPad Pro), 60 otherwise (`ScreenPlan(panel:)`). The bitrate
  ceiling is the same, so it costs no more data.
- At 60 frames or more the Mac captures at 120 regardless, and frames go at the phone's rate *on average*: each frame time earns a frame's
  credit (at most 1.5 saved), a frame may go with half a credit, and one that comes earlier still waits for its turn instead of being dropped.
- The phone runs a display link asking for the panel's top rate while frames come, which is how an app tells ProMotion it wants 120 Hz
  (`CADisableMinimumFrameDurationOnPhone` was already set), and lets it go after a second without one. It also measures when each frame
  reaches the glass.

### 5. Crops on the GPU, not in ScreenCaptureKit (2026-11-09, second round)

Zoomed in, ScreenCaptureKit now sends the whole display at its own pixels, and each frame is cropped and scaled to the output size here
(`RemoteScreenCrop.swift`: VTPixelTransferSession, the source's clean aperture, `kVTScalingMode_CropSourceToCleanAperture`, into a pooled
NV12 buffer). A new crop applies to the next frame captured, and at once to the last one, so on a still screen too the new part shows
without waiting. Every frame is labelled with the crop it was cut with, so the phone places it exactly. The whole view stays as it was:
ScreenCaptureKit scales to the output size, no GPU pass. Between the two the stream changes size, and frames say which they are by their size
(at the output size: whole; at the display's: cut here), so even that change holds nothing. A frame captured at 120 for a 60 Hz phone is
cropped only if it's really sent.

Measured (`testwin2 scroll`, the view moving 7 times a second; "crop shown" is from the phone asking for a crop to a frame with that crop on
its layer; the integration build before, this one after, same session):

| | Before (ScreenCaptureKit's `sourceRect`) | After (cropped on the GPU) |
|---|---|---|
| Frames shown a second, panning at 2× / 3× | 44 / 50 | 59 / 59 |
| Longest gap between pictures, panning 2× / 3× | 69 / 126 ms | 37 / 29 ms |
| Crop shown, panning 2×, ms p50 / p95 / max | 36 / 45 / 62 | 20 / 30 / 32 |
| Crop shown, panning a still screen | 40 / 47 / 48 | 20 / 25 / 31 |
| Panning 2× with 1 % of pieces lost: frames a second, crop shown p50 | 44, 37 ms | 59, 18 ms |
| Frames held per crop change | 24 ms p50, up to 264 | none |
| GPU crop and scale, per frame sent | — | 1.4 ms p50, 2.0 p95 (3024×1890 → 1866×1166) |
| Composed → sent on the Mac, p50: zoomed still / panning | 7.1 / 6.8–9.1 ms | 8.6 / 11.5–11.9 ms |
| The app's CPU (one core = 100 %): whole view / zoomed | — | 13.1–13.8 % / 13.4–16.2 % |

- The cost is a GPU pass per frame sent: 1.4 ms here, 2.0–2.3 ms from a 3456×2234, 5120×2880 or 7680×4320 source to the phone's 2622 px
  (`scratchpad vt/crop3.swift`), about 80–130 ms of GPU work a second at 59 frames. Core Image did the same crop in 1.1 ms, but VideoToolbox's
  is synchronous and keeps the colour attachments, so it stays. Power itself isn't measured: `powermetrics` needs root here; the app's CPU
  moves by 0–3 points (one core), within run-to-run noise.
- While panning, frames leave the Mac 3–5 ms later at p50: the frame cut for each new crop takes a turn in the phone's frame rate, and the
  next capture waits for its credit. Waiting instead for the next capture to carry the crop (when frames keep coming) was tried: crop shown got
  6 ms worse (26 against 20 p50) with a 186 ms outlier, so the immediate frame stays.

### 6. Marking the picture and the pointer for Wi-Fi (2026-11-09, second round)

What WMM does: four queues (access categories) on every Wi-Fi radio, each with its own contention parameters. Voice (VO): the shortest
waits, bursts of at most 1.5 ms; video (VI): short waits, bursts up to 3 ms with aggregation; best effort (BE) and background (BK) wait longer
and back off further. A device picks the queue for what it sends from the packet's priority; an access point picks it for what it sends to a
phone from the packet's DSCP (RFC 8325: EF 46 → VO, AF41 34 → VI; many access points simply use DSCP ÷ 8). Large frames belong in VI: VO's short
bursts would cost a scrolling frame its aggregation.

| Flow | Before | After | How it was checked |
|---|---|---|---|
| Phone → Mac (pointer, probes, repairs' feedback) | VO (`.interactiveVoice`, already) | VO | `nettop -J tc_class`: VO |
| Mac → phone (picture, pointer's place, probe echoes) | BE (the UDP listener had no service class) | VI (`.interactiveVideo` on the listener; the flows it accepts inherit it) | `nettop`: BE in the integration build, VI in this one |
| DSCP in the IP header, either way | 0 | 0 | `IP_RECVTOS` on a receiving socket (`scratchpad vt/tos.swift`; tcpdump needs root here) |

The DSCP stays 0, and Network.framework can't change that: every service class (and `SO_NET_SERVICE_TYPE` on a plain socket) arrived with
TOS 0, while `IP_TOS` on a plain socket arrived intact (0xa0, 0x88). macOS writes DSCP for a service class only on a network marked
QoS-capable (`sysctl net.qos.policy.wifi_enabled: 0`, `capable_enabled: 0`; Cisco Fast Lane networks set it by profile). So the marks
choose the queue on the **sending device's own radio**: the phone's pointer goes ahead of its other traffic, and a Mac on Wi-Fi sends the
picture ahead of a download. The **access point's** queue to the phone, where most Wi-Fi delay is, still sees DSCP 0 from a Mac. Writing
DSCP needs a plain socket with `IP_TOS` for the Mac's sending path, in place of the NWListener flow (§Not built). Not measurable on loopback;
on the real network, a busy download running while scrolling is the test.

### 7. A still picture made sharp in steps (2026-11-11)

The founder on an iPad (2026-11-10): text is sometimes soft, and scrolling a little makes it sharp. Not the network: our own budget.
When the picture stopped the Mac sent the same frame again at most eight times, 0.2 s apart, and took a resend under 1.5 KB to mean
"as good as it gets". Each resend gets what the rate control allows one frame, and on a screen full of text no resend ever comes out
that small, so the count decided, and under a few Mbps it ran out first. Then nothing more was sent until something moved, which
bought eight more: the scroll that made it sharp. And the rate doesn't climb on a still screen (RemoteRate: it proves nothing about the
network), so after one dip it stayed where it fell while the reading went on.

Measured with the encoder alone, set up as `RemoteScreen.makeEncoder` (HEVC, low-latency rate control, M-series): a dark window full of
13 pt code, English and Chinese, in five colours, scrolled for 1.5 s at the rate, then still. PSNR of the luma against the source, after
decoding; the ceiling here is about 41.6 dB at 1800 wide and 44.3 at 2752 (what 4:2:0 and the conversion leave). By eye the eight resends
at 2 Mbps leave strokes of 帧 and 码 smeared, at 700 kbps the whole line; at QP 22 the picture is the source's equal.

| Rate, width | When it stops | Eight resends (before) | In steps to QP 22 (now) |
|---|---|---|---|
| 700 kbps, 1800 | 15.7 dB (frames dropped) | 33.6 dB, 131 KB, 1.6 s, then nothing | 39.5 dB, 407 KB, 6.0 s |
| 2 Mbps, 1800 | 33.7 dB | 39.3 dB, 444 KB, 1.6 s, then nothing | 41.4 dB, 502 KB, 2.1 s |
| 4 Mbps, 1800 | 37.7 dB | 42.2 dB, 726 KB, 1.6 s | 41.6 dB, 350 KB, 0.7 s |
| 12 Mbps, 2752 | 39.8 dB | 44.2 dB, 1,178 KB, 1.6 s | 43.6 dB, 605 KB, 0.7 s |

What was tried on the way (same picture, 2 Mbps):

- **More plain resends**: 12 reach 39.7 dB for 630 KB and are still 40–50 KB each. The rate control lowers its quantiser a little per
  frame and never says it has finished.
- **A ceiling alone, held** (`MaxAllowedFrameQP` 22 again and again): the encoder goes on spending a frame's share below the ceiling for
  no gain (41.4 → 41.5 dB over twelve more resends, 50 KB each). So the ladder ends on the first frame made at the last step; nothing is
  measured to decide it.
- **The quantiser fixed** (min = max): the second frame at the same value still costs 60 KB, so "a small resend means done" doesn't hold
  for this encoder either, and at 12 Mbps it ends lower (41.8 dB) than the rate control's own choice.
- **One big step** (straight to 22): the fewest bytes (about 230 KB to 39.5 dB), but one frame of 180–300 KB, which is 0.7–3 s of a thin
  link in one piece; in the relay's stream keys wait behind it, and the rate control then drops what follows.

Built (`RemoteSharpen`, BlurtRemoteKit; `RemoteScreen.refine`): the ceiling starts at 40 and comes down to 22. A step is 4 at first, 2 more
after a resend that cost under a third of 0.4 s of the rate, half after one that cost more than 0.4 s of it. The next resend waits until
the last has had time to get through (its bytes at the rate, at least 0.1 s), so the picture never takes more than the rate. A resend the
rate control drops goes again 0.2 s later (at 700 kbps: 22 dropped beside the 8 that went). Any moving frame, keyframe or refresh takes the
ceiling off and starts the ladder over. An encoder that takes no ceiling gets the eight plain resends as before.

A real screen is seldom quite still, which the encoder-alone runs above couldn't show and the first live session did (a test host on
this Mac's own desktop, the Rust test phone, 2026-11-11): a caret blinks, a spinner turns, and each is a frame of a few hundred bytes,
28 a second here. Every frame of the screen's own started the ladder over, as it had always reset the eight resends, so with a spinner
it never began, and under a blinking caret it would have begun again twice a second, never reaching sharp and sending its first steps
each time. Now only a frame of half the rate's share or more (3 KB at least) is the picture really changing (`RemoteSharpen.moved`);
smaller ones leave the steps where they are, and on the Mac the steps wait for 0.2 s without such a frame rather than without any
frame, so text gets sharp beside a spinner too. Live at 2 Mbps: a keyframe of 77 KB, the ladder in the second after it (257 KB in
all), then the desktop's own small frames and nothing else. The Rust host has the same rule for starting over but still waits for a
screen with nothing moving before it resends: its backends tell a resend from the screen's own frame by there being no other. The resends count as
sent, so a rate that dipped can climb a step on them (RemoteRate asks that 60 % of the rate be in use).

The Rust host has the same ladder (`sharpen.rs`, `Screen::sharpen` and `caps_quantiser`), but none of its encoders takes a ceiling
(measured on an NVIDIA L4, 2026-11-11): Media Foundation's (NVIDIA HEVC and H.264, Microsoft's software H.264) accept one and ignore
it, byte for byte; x264enc, x265enc and openh264enc can't change one while running; GStreamer 1.24's NVENC elements answer every
change with a keyframe. What does work there is the rate: for the one resend the encoder is given the rate that step needs, and put
back at once. So `sharpen(max_qp)` means "as sharp as that ceiling would make it", by whichever means the encoder answers to, and
the ladder, its pacing and its end are the same everywhere.

| Host encoder | Eight resends (before), 2 Mbps | The ladder (now), 2 Mbps | Best this page can be |
|---|---|---|---|
| Windows, NVIDIA HEVC | 31.3 dB | 45.4 dB, 304 KB, 0.6 s | 55.1 dB |
| Linux, x264enc | 24.7 dB | 36.6 dB, 412 KB, 1.4 s | 38.8 dB |
| Linux, nvcudah264enc | 30.5 dB | 37.3 dB, 432 KB, 1.9 s | 38.8 dB |

(Each host's own PSNR measure; they don't compare with each other or with the Mac's. 700 kbps and 4 Mbps, the tuning and the method:
[remote-windows.md](remote-windows.md), [remote-linux.md](remote-linux.md). Crops to look at: `promo/cases/remote-sharpen/`.) On
Linux the resends had been starved besides: the encoders are told 60 frames a second, so each resend got a sixtieth of a second of
the rate, and dense text on x264 never left 20–25 dB under 4 Mbps.

Still eight plain resends, because nothing could be measured or nothing answered: on Windows NVIDIA H.264 and the software H.264
encoder (a raised rate does nothing; see below), Quick Sync and AMF (no such machine); on Linux VA-API (`vah264enc`, `vah265enc`:
what most Intel and AMD machines use, and Google Cloud has none), x265enc, openh264enc and 1.24's nvh264enc / nvh265enc.

Found on the way and not fixed:

- **Windows H.264 never gets sharp on a screen of text**, NVIDIA's or the software encoder: moving frames are about three times the
  rate's share at 30 or 60 frames a second, and once still the picture stays at 21–24 dB whatever is resent. Machines with no HEVC
  hardware encoder. Its own investigation.
- **Linux: a change of rate costs a keyframe** on x265enc, openh264enc and 1.24's nvh264enc / nvh265enc (103–168 KB at 2 Mbps), on
  every step the rate control takes, as before today. `Screen::rate_change_is_cheap` keeps §8's faster resends off them.
- **The first resend can be large** where the encoder spends a buffer that refilled while the screen was still: up to 1.5 s of the
  rate in one frame on nvcudah264enc at 700 kbps, 1.0 s on x264enc, 1.9 times the 0.4 s budget on Windows HEVC. Over the relay's
  one stream a key waits behind it.
- **x264enc now runs with `qp-step` 24** (its default 4 let the quantiser fall only 4 a frame, and the ladder ended at 27.6 dB).
  Moving frames measured the same size; what it does to a real desktop's moving picture hasn't been looked at.

### 8. A rate that fell finds its way back while the screen is read (2026-11-11)

The rate comes down at once on trouble and goes up a quarter at a time, only after three calm reports and only while 60 % of it is in
use: a still screen proves nothing about the network. Reading is mostly still screens. So after one dip (a neighbour's download, a train
tunnel) the rate sat where it fell for as long as the reading went on, the next scroll began soft and slow however good the network had
become again, and over the relay, where it starts at half the ceiling, it could sit at half all evening.

The only thing sent on a still screen is §7's resends, so they ask. While there is room above the rate (`RemoteRate.probe`) they go
at 1.5 times the rate, and the phone's next report answers:

- all of it arrived (nine tenths of what was sent in that report's time) and nothing shows trouble: the network carries it. The rate
  goes to nine tenths of how fast the resends really went (`RemoteProbe`: their bytes over the time each was given; less than the pace
  when resends were small or dropped, never more), no further than the ceiling.
- trouble in that report: the network has no more than it had. Nothing is cut, since the trouble was the question's own doing, and
  no resend goes faster than the rate again for 30 reports. Trouble without a question is cut as before.

The encoder has to be told. Paced at 1.5 times the rate with the encoder left at the rate, the resends still left at 1.0–1.1 times
it: the rate control drops and shrinks them (measured as in §7: 700 kbps → 690, 2 Mbps → 2.0, 4 Mbps → 4.3 Mbps). With the
encoder's own rate at the pace while the ladder runs, 2 Mbps → 2.73 Mbps (1.37 times; nine resends, none dropped), and at 4 Mbps
four resends of 386 KB in all, whose turns add up to about 0.55 s (1.4 times by `RemoteProbe`'s count; the ladder is over in 0.7 s, so
a whole second's average would say less). At 700 kbps it is still 1.05 times, 11 dropped: a step there costs
more than the rate control will pass at once, so the lowest rates climb the old way instead, which the ladder also feeds, being several
seconds of a rate in use. `RemoteScreen.encode` sets the rate to the pace for a sharpening resend and back for any other frame.

Not measured on a network: only the arithmetic, as a run of reports (`testOverAnHourOfReadingTheRateSettlesJustUnderWhatTheNetworkCarries`:
a network that carries 3 Mbps, a rate at the floor, a still picture every 20 s; back over 2.1 Mbps within 30 pictures, never lower for
asking). The cost when the answer is no: over the relay's one stream, up to half a second of picture ahead of a key, once per 30 reports.

### Measured, before and after (same tests, `BLURT_SCREEN_REPAIR=0` on the phone for before)

Scrolling at 60 Hz (`testwin2 scroll`), Auto at home, 12 s a stage, two stages (whole and 2×) each unless one number is given. "Longest
gap" is the longest time between two new pictures on the phone; the usual gap at 59 frames a second is 17 ms.

| Network | | Frames shown / s | Age at decode, ms p50 / p95 / max | Longest gap, ms | Frames dropped | Keyframes asked | Mbps | Repaired |
|---|---|---|---|---|---|---|---|---|
| clean | before | 59 | 10.8 / 13.8–14.4 / 18 | 35 | 0 | 0 | 12.2 | |
| | after | 59 | 10.7 / 13.5–14.1 / 18–20 | 35–38 | 0 | 0 | 12.2 | |
| 1 % of pieces lost, bursts of 2 | before | 24–34 | 10 / 14 / 19 | 1,330–1,560 | 299–408 | 27–36 | 4.2–4.4 | |
| | after | 58–59 | 11.2–11.4 / 16.5–18.9 / 45 | 46–57 | 0 | 0 | 12.2 | 159–163 pieces sent again |
| 3 % lost, bursts of 3 | before | 2 | 12 / 35 / 49 | 2,330 | 446 | 51 | 7.5 | |
| | after | 59 | 11.5 / 19.5 / 60 | 60 | 0 | 0 | 12.2 | 500 sent again |
| 80 ms stall every 2 s | before | 59 | 10.3 / 15.8 / 92 | 104 | 0 | 0 | 12.2 | |
| | after | 59 | 10.9 / 15.8 / 92 | 100 | 0 | 0 | 12.2 | 17 sent again needlessly |
| 1 % lost, the 15 Hz terminal (`testwin`) | before | 8 of 14 | 12 / 19 / 22 | 2,741 | 97 | 26 | 5.0 | |
| | after | 14 | 15 / 19 / 49 | 207 | 2 | 0 | 7.6 | 94 sent again, 1 LTR refresh |
| 1 % lost, independent, parity forced (G = 8) | after | 59 | 10.9 / 13.8 / 19 | 35 | 0 | 0 | 13.9 | 176 by parity, 27 sent again |
| 1 % lost, bursts of 2, parity forced (G = 8) | after | 59 | 10.9 / 14.5 / 32 | 41 | 0 | 0 | 13.9 | 129 by parity, 51 sent again |

- **Loss no longer costs the picture.** At 1 % the frames shown went from 24–34 a second with 1.3–1.6 s freezes to 59 with nothing longer
  than 57 ms; the bitrate stays at the ceiling instead of falling to a third. The cost is the pieces sent again: 1–2 % more data at 1 % loss.
- **A stall is waited out.** The first version of the receiver gave up a frame 40 ms into a stall and asked for a refresh, then dropped what
  arrived late; now its clock stops while nothing at all arrives. 17 pieces a stall are still asked for once (the end of a frame, quiet for
  30 ms, looks the same as a lost end): about 20 KB, never again into the stall.
- **Parity** costs 14 % at G = 8 (13.9 against 12.2 Mbps, every frame, lost or not) and mends 87 % of independent losses and, interleaved, 72 %
  of bursts of 2 (43 % when groups were consecutive pieces). That's why it is off at home: NACK mends all of it for 1–2 %.
- **Frame rate.** Captured at 1/60 s, 53 of a 60 Hz scroll's 60 frames a second reached the phone; at 1/120 with a fixed 13.7 ms minimum gap,
  40 (frames 8 ms apart were dropped); deferring them instead, 59 but 2–5 ms later; with an average-rate credit (a frame may come up to half a
  frame early, the next one pays), 59 at 0.8 ms from composition to capture (p50).
- **Panning** while zoomed: 36–41 frames a second before, 44–46 after (the credit), against 59 with the view still. The rest is ScreenCaptureKit's
  crop change (§Not built 1).

## Data per hour

Measured per kind of screen (12–15 s each, after start-up), with the repairs on; the same with them off on a clean network (local: scrolling
12.2 and 12.2, agent output 3.0 and 3.0 Mbps). "Agent output" is `testwin2 agent`: a line every 66 ms for 2 s, the terminal scrolling with
it, then 3 s still, over and over. Still is still: 2–3 resends after it stops, then nothing (remote.md §What it costs; since 2026-11-11
the resends go in steps until the picture is sharp, §7, so on a screen full of text a stop costs 350–600 KB where these runs' sparse
window cost a few KB: the table below is from before that and wasn't measured again).

| Auto tier (ceiling) | Scrolling | Agent output | Still | A typical hour | An hour of nothing but scrolling |
|---|---|---|---|---|---|
| Home (12 Mbps, panel rate, phone's width) | 12.2 Mbps | 3.0 Mbps | 0 | 600 MB | 5.4 GB |
| Wi-Fi elsewhere (4 Mbps, 30 fps, 1800) | 4.0 | 1.6 | 0 | 270 MB | 1.8 GB |
| Mobile data (2 Mbps, 24 fps, 1440) | 2.0 | 1.0 | 0 | 160 MB | 0.9 GB |
| Low Data Mode / Data Saver (1 Mbps, 15 fps, 1280) | 1.0 | 0.6 | 0 | 90 MB | 0.45 GB |

A typical hour here is 70 % still (reading, thinking, an agent working where nothing changes), 25 % an agent's output streaming by, 5 %
scrolling or panning; each start of the picture adds its first keyframe (about 170 KB at home). Away from home 45 s untouched drops the
picture to 5 frames a second, so an agent's output watched hands-off costs less than the table says. So Auto stays inside the budget on
mobile data even scrolling all hour (0.9 GB), and at home it spends what the network has, since nothing there is paid by the byte. The
repairs change these numbers little: 1–2 % sent again at 1 % loss, parity 14 % only when the round trip is long and pieces are lost, and
no keyframe every 600 frames (about 1 % of a scroll's bits).

## What the best systems do, judged for this case

Mostly static text, a phone on home Wi-Fi (round trip a few ms) or away (30–150 ms), a few hundred MB to 1 GB an hour. Sources are
primary where there is one; "unverified" where there isn't.

| System / technique | What it does | For us |
|---|---|---|
| RDP graphics pipeline ([MS-RDPEGFX](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/da5c75f9-cd99-450c-98c4-014a496942b0), [AVD encoding](https://learn.microsoft.com/en-us/azure/virtual-desktop/graphics-encoding)) | Surfaces updated by rectangle; unchanged content dropped before any codec; a classifier sends text (about 80 % of session graphics, Microsoft says) through its own codecs (ClearCodec: glyph cache, palette RLE), images through RemoteFX Progressive, whose "upgrade" passes sharpen a tile already shown; video regions through AVC420/AVC444. Microsoft: full-screen H.264 "performs worse than mixed mode" when content is mostly text. Mixed mode is software only | The right model, but its text codecs have no hardware decoder on a phone. Take the two ideas a hardware codec allows: send nothing for unchanged frames (done), sharpen a still picture with resends (done: refines) |
| AVC444 ([spec](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/844018a5-d717-4bc9-bddb-8b4d6be5dd3f)) | 4:4:4 text out of two 4:2:0 streams (luma + chroma auxiliary), chroma sent later if needed | Coloured text edges are sharper; double decode on the phone. Not now: our text is legible at 4:2:0 at every zoom (remote.md) |
| Moonlight / Sunshine ([RtpVideoQueue.c](https://raw.githubusercontent.com/moonlight-stream/moonlight-common-c/master/src/RtpVideoQueue.c), [ControlStream.c](https://raw.githubusercontent.com/moonlight-stream/moonlight-common-c/master/src/ControlStream.c), [Sunshine config](https://raw.githubusercontent.com/LizardByte/Sunshine/master/docs/configuration.md)) | Reed–Solomon FEC per frame, up to 4 blocks, 20 % parity by default (what GeForce Experience used); lost frames reported as reference-frame-invalidation (RFI) ranges, IDR only when that fails; LTR acknowledgements; ping every 100 ms | Built for games on a LAN: constant motion, no budget. Its loss answer (invalidate, don't IDR) is ours (ltr). 20 % parity all the time is a cost we'd pay on every scroll for losses NACK mends in a few ms at home |
| Moonlight Android decoders ([MediaCodecHelper.java](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/master/app/src/main/java/com/limelight/binding/video/MediaCodecHelper.java)) | RFI only on allow-listed decoders; off on low-end Snapdragon above 720p; Amlogic HEVC hangs after loss | Android must fall back to keyframes per decoder (spec below) |
| Parsec ([BUD](https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007/)) | Own UDP protocol, no video buffers, lowers quality before adding delay; about 7 ms added on a LAN | Same stance as ours: never queue picture |
| WebRTC ([nack_requester.cc](https://webrtc.googlesource.com/src/+/HEAD/modules/video_coding/nack_requester.cc), [media_opt_util.h](https://webrtc.googlesource.com/src/+/HEAD/modules/video_coding/media_opt_util.h)) | NACK with RTX; a lost packet is asked for again once per round trip; **below 20 ms round trip, NACK only, no FEC**; FEC capped at 50 %; screen content: maintain resolution, drop frames first ([webrtc_video_engine.cc](https://webrtc.googlesource.com/src/+/HEAD/media/engine/webrtc_video_engine.cc)) | Exactly our split: NACK at home, parity only when the round trip is long. "Text" content hint = resolution before frame rate: RemoteRate already gives each frame at least 30 kbit |
| AV1 screen content tools (palette, intra block copy) ([libaom in libwebrtc](https://webrtc.googlesource.com/src/+/HEAD/modules/video_coding/codecs/av1/libaom_av1_encoder.cc), [IBC paper](https://www.aminer.org/pub/5b67b44817c44aac1c860193/intra-block-copy-for-screen-content-in-the-emerging-av-video-codec)) | 10–27 % fewer bits on screen content, in software encoders | No AV1 encoder on any Mac through M5 (`VTCopyVideoEncoderList`, measured); NVENC (RTX 40+), Arc and RDNA3 encode AV1 but without screen tools in hardware (unverified for NVENC). Decode: iPhone 15 Pro and later, M3 and later; most 2023+ Android flagships. Later, for Windows/Linux hosts with such GPUs; not a latency win |
| HEVC SCC ([MERL TR2015-126](https://shadow.merl.com/publications/docs/TR2015-126.pdf)) | 33–51 % fewer bits on text | No phone decodes it. Out |
| Apple High Performance Screen Sharing ([guide](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac)) | 60 fps, 4:4:4, 75 Mbps per 4K display recommended, wired | About 34 GB an hour: a reference for a cable, not for a phone. Sidecar publishes nothing |
| VideoToolbox LTR (SDK headers; [WWDC21 10158](https://developer.apple.com/videos/play/wwdc2021/10158/)) | `kVTCompressionPropertyKey_EnableLTR`, `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`, `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`, `kVTEncodeFrameOptionKey_ForceLTRRefresh` (macOS 12 / iOS 15). WWDC presented it with H.264; on this M5 Max (macOS 26.5) it works with HEVC in low-latency mode (measured below) | **Built** |
| Intra refresh / GDR | NVENC `enableIntraRefresh`, VA-API `VAConfigAttribEncIntraRefresh`, D3D12 video; **no public key in VideoToolbox** | Mac can't. Windows/Linux may later; LTR answers the same need with less steady cost |
| Dirty rects ([SCStreamFrameInfo](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo), [DXGI](https://learn.microsoft.com/en-us/windows/win32/api/DXGI1_2/nf-dxgi1_2-idxgioutputduplication-getframedirtyrects), PipeWire `SPA_META_VideoDamage`) | Which parts changed | Used today only as "anything changed?" (plus a byte compare, since SCK sends unchanged window frames as complete). A QP map from them needs an encoder that takes one: NVENC emphasis map, MF delta-QP map (Windows 11 26100+), VA-API ROI; VideoToolbox has none public |
| Frame rate on a 60 Hz phone | — | Frames past the panel's rate are never seen. On ProMotion (120 Hz) a frame waits half as long for its vsync and scrolling reads as the phone's own |
| Client presentation (Moonlight iOS [renderer](https://raw.githubusercontent.com/moonlight-stream/moonlight-ios/master/Limelight/Stream/VideoDecoderRenderer.m)) | Sample-buffer layer, display link pinned to the stream rate; "pacing" holds one frame "at the cost of 1 frame of latency" | We already show the newest frame at the next vsync and drop the rest; ProMotion needs `CADisableMinimumFrameDurationOnPhone` (set) and a display link asking for 120 |

## Spec for the other platforms

The reference is the Swift: `RemoteVideoRepair.swift` (wire, `RemoteVideoReceiver`, `RemoteVideoHistory`, `RemoteVideoFEC`) and
`RemoteScreenRepair.swift`. `tests/remote-vectors/vectors.json` → `videoRepair`, `screen_repairs`, `screen_view_repairs` pin the bytes. Each
platform can take the parts one at a time: NACK needs nothing from the encoder or decoder, parity neither, LTR needs both.

### The wire (all additive; remote-protocol.md §Repairs)

| What | Bytes | Who sends it |
|---|---|---|
| `screen.features` | `["nack","ltr","fec"]`: what the phone implements | phone |
| `screenView.features` | the subset the host uses for this stream; absent = none | host, each screenView |
| video byte 8 | flags: bit 0 keyframe, bit 1 refresh, bit 2 acknowledge. Read keyframe as `& 1` | host; bits 1–2 only with `ltr` |
| parity piece | n = min(64, ⌈count / G⌉) groups, interleaved: group g = pieces i with i mod n = g. Parity piece g: `index = count + g`, payload `[n] ∥ XOR over the group of (u16 BE len ∥ payload, zero-padded to the longest)`; groups of one piece get none | host, only with `fec` |
| kind 6 `videoFeedback` | `1` nack: (u32 frame, u16 n or 0xFFFF, n × u16)…; `2` ack: u32 newest, u32 bitmap; `3` lost: u32 last decoded | phone, datagrams |

### Host (Rust: `crates/blurt-remote/src/screen.rs`, `server.rs`, `packets.rs`, `wire.rs`)

1. `ScreenRequest.features: Option<Vec<String>>`, `ToPhone::ScreenView.features`, `Kind::VideoFeedback = 6`, `VideoPacket.refresh`,
   `.ack_requested` (flags byte), parity pieces: follow the vectors.
2. Negotiate on each `screen` request: `features = offered ∩ {nack, fec} ∪ ({ltr} if the encoder session has LTR)`. Say it in screenView.
3. **History** (nack): after `frame()` cuts a frame into pieces, keep the encoded pieces (before sealing) per frame id; drop frames older than
   1 s or past 6 MB. On a nack: for each (frame, pieces) still kept send those pieces again through the same datagram path, pieces = all if
   n = 0xFFFF. Budget per second: max(300 KB, bitrate / 16); past it, ignore.
4. **Ack / lost** (ltr): keep frame id → encoder LTR slot/token for frames the encoder marked; on ack, collect the tokens (newest, and bit i
   → newest − 1 − i) and give them to the encoder with the next frame. On lost: the next frame encoded is a refresh from an acknowledged
   reference (flag bit 1), or a keyframe if none is acknowledged or the encoder can't. If no frame is coming (still screen), encode the last
   image now, as `keyframe()` does. Without `ltr`: lost = keyframe request.
5. **Parity** (fec): every report, from the phone's `rtt` and pieces asked for / pieces sent over the last 5 reports: rtt ≥ 30 ms: > 5 % → G 4,
   > 1 % → 8, > 0.2 % → 16, else 0; rtt < 30 ms: > 10 % → 8, else 0. Send parity pieces right after the frame's pieces (in the same paced
   batches on the direct path).
6. **No periodic keyframes** when nack or ltr is in use: GOP infinite (Media Foundation `CODECAPI_AVEncMPVGOPSize` 0 / as large as the
   encoder takes, which it already asks for).
7. Capture at up to 120 when the request's fps ≥ 60 (DXGI duplication / PipeWire deliver at the display's rate anyway); frames go at the
   request's fps on average (a frame time earns a frame's credit, at most 1.5 kept; a frame may go with 0.45), and one that comes too early
   waits for its turn rather than being dropped.
8. **Crops** (Windows and Linux already crop on the GPU: the D3D11 video processor's source rectangle, the PipeWire/VA-API scaler). What to
   match: a crop applies to the next frame captured, never holds frames; a crop on a still screen (no new capture coming) re-crops the last
   captured frame at once and sends it; every frame's payload carries the crop it was really cut with. Target, as measured on the Mac: a crop
   shown on the phone 20 ms (p50) after the phone asks, 59 frames a second while panning. Keep the last captured frame at the display's own
   size while zoomed, not only the last output.
9. **Marking.** Video, the pointer's place and probe echoes (host → phone): DSCP AF41 (0x88 in the TOS byte; 34 → VI by RFC 8325 and by
   DSCP ÷ 8). Linux: `setsockopt(IP_TOS, 0x88)` and `IPV6_TCLASS` 0x88 on the session's UDP socket, plus `SO_PRIORITY` 5 so the host's own
   Wi-Fi uses VI even where its driver ignores DSCP (values 0–6 need no capability). Windows: `setsockopt(IP_TOS)` is ignored; use qWAVE:
   `QOSCreateHandle`, then `QOSAddSocketToFlow(handle, socket, destination, QOSTrafficTypeAudioVideo, QOS_NON_ADAPTIVE_FLOW, &flow)` per
   phone address (UDP needs the destination) — Microsoft's table gives AudioVideo DSCP 40 and 802.1p 5, both VI; `QOSSetFlow` with
   `QOSSetOutgoingDSCPValue` (34) needs administrator rights, so the default AudioVideo value it is. Check with Wireshark on the host (the
   IP header's DS field) and `nettop`-like per-flow views where there are any. Some networks drop or bleach marked packets: if a marked path
   delivers nothing while an unmarked probe does, send unmarked.

Encoders, what each can do for `ltr`:

| Encoder | LTR mark / use / refresh | Intra refresh | Notes |
|---|---|---|---|
| VideoToolbox (Mac) | yes: EnableLTR, tokens, ForceLTRRefresh; HEVC and H.264, low-latency mode included (measured) | no public key | built |
| Media Foundation H.264/HEVC MFT (Windows; NVENC, Quick Sync, AMF, Qualcomm behind it) | `CODECAPI_AVEncVideoLTRBufferControl` (count, trust mode 1), `CODECAPI_AVEncVideoMarkLTRFrame` (index), `CODECAPI_AVEncVideoUseLTRFrame` (bitmap of acknowledged indices); optional per MFT: query `IsSupported`, read back `MFSampleExtension_LongTermReferenceFrameInfo` on output | not in CODECAPI (D3D12 video encode has it) | mark every 4th frame into 2 slots alternately; on lost, `UseLTRFrame` with the acknowledged slot. No LTR support → answer lost with a keyframe. **Built; H.264 only** (NVIDIA HEVC ignores UseLTRFrame): §Rust host |
| NVENC SDK directly (if the Rust host ever drops MF) | `enableLTR`, `ltrNumFrames`, `ltrMarkFrame`/`ltrUseFrameBitmap`, or `NvEncInvalidateRefFrames(timestamp)` (Sunshine's RFI) | `enableIntraRefresh` | |
| Microsoft software H.264 MFT | LTR per Microsoft's H.264 encoder docs (Windows 8+) | no | |
| VA-API (Linux) | no LTR switch; the app manages references, which the GStreamer/ffmpeg VA encoders don't expose | `VAConfigAttribEncIntraRefresh` | Linux: nack + fec now, lost → keyframe |
| x264 / openh264 (software) | openh264: `iLTRRefNum` + `SLTRMarkingFeedback`/`SLTRRecoverRequest` (WebRTC uses them) | x264 `--intra-refresh` | if a software path is ever needed |

### Phone (Android: `apps/android/core` for the logic, the app for MediaCodec)

1. Port `RemoteVideoReceiver` to Kotlin as it stands (pure; its Swift tests are the test list): states, timers below, outputs frame /
   feedback / keyframe. Feed it every piece; call `tick` every 4 ms while the stream is on; `decoded` after each successful decode;
   `decoderFailed` on a codec error or `MediaCodec.CodecException`.
2. Timers (seconds; rtt = the last ping's round trip): piece asked after a later piece / later frame / max(0.03, 2 rtt) quiet; again after
   max(0.012, 1.5 rtt), at most 4 times, not while nothing at all has arrived for 0.02; patience min(0.15, max(0.04, 3 rtt + 0.02)) while
   pieces arrive, at most 0.35 regardless; lost / keyframe asked every 0.25 while broken, the first 0.3 after the stream starts only if no
   keyframe came; acks batched every ≥ 0.02. The patience counts only time with pieces arriving (nothing for 0.02 is a stall) and the
   phone running: a tick more than 0.015 after the last one (the phone itself was busy) gives no frame up, since the pieces that came
   meanwhile haven't been read yet, and when a stall ends the piece asked for gets its retry before the frame is given up (§Rust host,
   a stopped process). A frame late for 1 s of real time (hitches included) is given up regardless, so a phone whose ticks all come more
   than 0.015 apart (a busy decoder thread or main queue) still asks to start over instead of freezing.
3. Offer `features` by decoder: `nack` and `fec` always. `ltr` only on decoders known to survive a skipped frame followed by a refresh
   (Moonlight's experience: RFI hangs Amlogic HEVC before Fire OS 7 and misbehaves on some low-end Snapdragons above 720p): start with an
   allow-list of Qualcomm `c2.qti.*` / `OMX.qcom.*` on Snapdragon 8 Gen 1+, Google `c2.exynos`/Tensor, MediaTek `c2.mtk.*` Dimensity 9000+,
   tested with the made-up loss below; others get nack + fec and keyframes.
4. MediaCodec: `KEY_LOW_LATENCY = 1` (API 30+) when `FEATURE_LowLatency` is listed; vendor keys as Moonlight sets them
   (`vendor.qti-ext-dec-low-latency.enable`, `vdec-lowlatency`); render each output buffer at once (`releaseOutputBuffer(index, true)`,
   no timestamps), dropping all but the newest if several are ready.
5. Panel rate: ask for `Display.getSupportedModes()`' highest refresh at home (`Surface.setFrameRate(120f, FRAME_RATE_COMPATIBILITY_DEFAULT)`
   while frames come) and put it in `screen.fps`, as ScreenPlan does.
6. Test with a made-up network like iOS's `TestWeather` (debug builds): drop pieces at 1 % in bursts of 2, hold everything 80 ms every 2 s.
   Pass: no keyframes asked at 1 % loss, frames shown within 5 % of frames sent, no frame given up during a stall.
7. **Marking** (phone → host: pointer, probes, feedback): DSCP EF, `DatagramSocket.setTrafficClass(0xB8)` (or `IP_TOS` 0xB8 on the native
   socket). Android's Wi-Fi driver picks VO from it. Apple phones use `.interactiveVoice`, which picks VO on the phone's radio but writes no
   DSCP (§6); Android writing EF is stricter and fine.

## Android (status 2026-11-09)

Built to the spec above. Core (`apps/android/core`): the wire (`screen.features`, `screenView.features`, kind 6, the flags byte, parity
pieces) passes `videoRepair`, `screen_repairs` and `screen_view_repairs` byte for byte; `RemoteVideoRepair.kt` ports `RemoteVideoReceiver`,
`RemoteVideoHistory`, `RemoteVideoFEC` and `RemoteVideoFeedback` with every Swift test, plus a 10 s simulated run at 1 % loss (no keyframe,
no frame given up). App (`pad/ScreenStream.kt`): the receiver ticked every 4 ms on the decode thread, feedback straight to the channel's
datagram path; nack and fec always offered, ltr only where `takesRefresh` says; each decoded picture released at once, the newest of several;
`KEY_LOW_LATENCY` and the vendors' keys; the panel's top rate in `screen.fps` (`ScreenPlan(panel:)`) and asked for while frames come
(`Surface.setFrameRate` + `preferredDisplayModeId`, let go after a second without one). Debug builds take a made-up network from launch extras
(`pad/TestWeather.kt`: `blurt_test_loss`, `blurt_test_stall`, `blurt_screen_repair=0`, `blurt_screen_test` for a measured run).

**Refresh frames on Android decoders.** `RefreshDecodeTest` (androidTest) decodes what a Mac sends after a loss (VideoToolbox, low-latency,
LTR; frames 30–33 lost, 34 a refresh; `tools/refresh_stream.swift`) with every decoder on the device and compares each picture with what it
should show. On the Android 16 emulator all six take it: `c2.goldfish.hevc/h264`, `c2.android.hevc/avc`, `OMX.google.hevc/h264`: 54 dB
after the loss with the refresh, 6–8 dB without one (the same stream with the refresh left out), 0 errors. So those are allowed from Android
16; hardware decoders on phones (Snapdragon 8 Gen 1+, Tensor, Dimensity 9000+) are allowed on the spec's say-so, untested.

**Measured** on the Pixel 9 emulator (Android 16, 60 Hz panel, `c2.goldfish.hevc.decoder`) against the fake computer
(`apps/android/fakehost --scroll`: terminal text scrolling 2 px a frame, x265 at 60 fps, nack + fec, a keyframe answered by restarting the
encoder at most every 0.7 s) over the emulator's loopback, round trip 1–4 ms. 12 s a run after 3 s to settle, two runs each; "shown" counts
pictures that reached the GL surface, "longest gap" the longest time between two of them (17 ms is one frame).

| Network | Repairs | Shown / s (sent 61.7) | Longest gap, ms | Gap p99, ms | Frames dropped | Keyframes asked | Repaired |
|---|---|---|---|---|---|---|---|
| clean | on | 60.0, 60.0 | 22, 31 | 20 | 0 | 0 | |
| | off | 60.0, 60.0 | 24, 46 | 20–21 | 0 | 0 | |
| 1 % lost, bursts of 2 | on | 59.7, 59.9 | 53, 55 | 23–27 | 0 | 0 | 61, 39 pieces sent again |
| | off | 31.2, 20.8 | 1,273, 1,367 | 562–698 | 100, 178 | 28, 38 | |
| 3 % lost, bursts of 3 | on | 59.1, 58.8 | 100, 104 | 40–44 | 0 | 0 | 156, 137 sent again |
| | off | 7.2, 6.1 | 2,105, 2,084 | 2,084–2,105 | 274, 294 | 47, 49 | |
| 80 ms stall every 2 s | on | 58.2, 57.8 | 96, 113 | 39–51 | 0 | 0 | 3, 5 asked needlessly |
| | off | 56.8, 57.7 | 374, 114 | 71–79 | 4, 0 | 2, 0 | |
| 1 % lost, parity forced (G = 8) | on | 60.0 | 32 | 21 | 0 | 0 | 21 by parity, 18 sent again; 3.4 against 2.8 Mbps |
| 3 % lost, parity forced (G = 8) | on | 59.2 | 81 | 41 | 0 | 0 | 44 by parity, 126 sent again |

Age at decode (the host's capture to the phone's decoder output, clocks matched by the fastest ping): 5.0–5.5 ms p50, 7–16 ms p95 with
repairs on in every weather. The spec's pass marks hold: no keyframes asked at 1 % loss, frames shown within 5 % of the panel's 60 (the
fake host sends 61.7 a second, a little over its nominal 60; two in one vsync show as one), no frame given up during a stall. Without
repairs the same losses cost what they cost on iOS before (21–31 frames a second and 1.3 s freezes at 1 %, 6–7 and 2.1 s at 3 %).

Two faults the runs found and fixed on the way: the decoder's "fallen behind" cut (6 frames queued → drop and ask for a keyframe) fired when a
resend let a dozen held frames go together, so it is now a second's worth (60); and the fake host sent its killed encoder's last, cut-off
frame and restarted the encoder again for requests that came before the new one's first keyframe (a loop of keyframe requests), now retired
first and ignored while fresh.

Not verified on Android: a real phone and Wi-Fi; a hardware decoder taking a refresh (the allow-list beyond the emulator is judgement); the
ltr path end to end (the fake host's ffmpeg can't make refresh frames, and the Rust host's repairs weren't on the integration branch when
this was measured), so acknowledgements and `lost` were tested only in core; 120 Hz (the emulator's panel has one 60 Hz mode, so the frame
rate request and `setFrameRate` ran but changed nothing); whether `KEY_LOW_LATENCY` and the vendor keys shorten anything on a real decoder.

## Rust host (Windows, Linux; status 2026-11-09)

Built to the spec above, in `crates/blurt-remote`. The wire (`screen.features`, `screenView.features`, kind 6, the flags byte, parity
pieces) passes `videoRepair`, `screen_repairs` and `screen_view_repairs` byte for byte. `repair.rs` is the host's half (`HostRepair`:
negotiation, the 1 s / 6 MB history, the resend budget, acknowledged references, parity and its adaptive group) and a port of
`RemoteVideoReceiver` with every Swift test, which the Rust test phone uses (`phone::watch`, with a made-up network as iOS's TestWeather;
`examples/phone.rs --measure`). `screen.rs` keeps pieces before sealing, sends parity right behind a frame's pieces (in the relay's paced
batches too), answers `nack` / `ack` / `lost`, and names `ltr` only when the backend's encoder says it makes recovery frames. host.rs gained,
with defaults: `Screen::supports_recovery`, `recovery_frame` (a keyframe unless overridden), `acknowledged`; `EncodedFrame.refresh` and
`.reference`; `ScreenConfig.capture_fps` and `.repairs` (no periodic keyframes). `credit.rs` is the Mac's average-rate frame credit; the
Windows pacer and the Linux feeder use it instead of a fixed 1/fps − 3 ms gap. The session's UDP socket carries DSCP AF41 (`IP_TOS` and
`IPV6_TCLASS` 0x88) and, on Linux, `SO_PRIORITY` 5 (§Host 9); Windows needs qWAVE for that, not built. The rate needed no change: with
repairs the phone reports no lost frames, so nothing cuts it.

**Recovery frames, per encoder** (`win_smoke --recovery` on blurt-win: frames dropped for 70 ms three times, a recovery asked for, the
stream a phone would decode compared frame by frame with the lossless one):

| Encoder | Recovery frame | Measured |
|---|---|---|
| Media Foundation H.264, NVIDIA (L4) | LTR: 2 slots, trust-until; a frame marked every 4th into a slot not yet acknowledged; `UseLTRFrame` with the acknowledged slots | bit-exact after each loss (336 / 336 frames); recovery frames 25, 27, 65 KB against a 647 KB keyframe (1080p) |
| Media Foundation H.264, Microsoft software | the same (it takes the LTR controls, though its docs don't list them) | bit-exact (337 / 337); 13–302 KB at 720p |
| Media Foundation HEVC, NVIDIA | **keyframe**: it takes the controls, but its "recovery" frame still predicts from the short-term picture before it (`used_by_curr_pic_s0_flag` on the lost POC), so nothing decodes after it | `BLURT_REMOTE_LTR=hevc` turns it on to retest |
| Other MFTs (Quick Sync, AMF, Qualcomm) | LTR if they take `LTRBufferControl`, else keyframe; the output's `LongTermReferenceFrameInfo` is checked and LTR turned off if a recovery used none | untested: no such GPU here |
| GStreamer x264enc, VA, NVENC, QSV (Linux) | **keyframe**; the keyframe interval is the longest each element takes when the phone repairs (x264 2³¹−1, NVENC −1, VA 1024) | built in Docker only |
| libx264 intra refresh (`examples/host --intra-refresh 60`, an experiment) | the next frame flagged a refresh while a refresh wave runs | the iPhone's decoder took it without an error (1 refresh, 0 keyframes asked at 3 % loss), but the picture is only whole again once the wave has passed (up to a second) and the wave costs bits on every frame; so not used |

**Measured.** Loopback, `tests/realtime.rs` (the real server and the Rust test phone, a synthetic 60 fps scroll sized by the bitrate: 25 KB
a frame at 12 Mbps, a make-believe LTR encoder; every frame's bytes checked; 12 s a stage here with `BLURT_REALTIME_SECONDS=12`, 4 s by default):

| Network | | Frames shown / s | Longest gap, ms | Age p50 / p95 / max, ms | Dropped | Keyframes asked | Mbps | Rate after | Repaired |
|---|---|---|---|---|---|---|---|---|---|
| clean | after | 60 | 21 | 0.5 / 1.7 / 3 | 0 | 0 | 12.0 | 12 | |
| 1 %, bursts of 2 | before | 23 | 1,570 | 0.1 / 0.9 / 8 | 455 | 37 | 6.5 | 2.0 | |
| | after | 60 | 40 | 0.6 / 5.3 / 26 | 0 | 0 | 12.0 | 12 | 165 sent again |
| 3 %, bursts of 3 | before | 1.1 | 8,388 | 0.4 / 2.7 / 3 | 502 | 49 | 12.4 | 8.4 | |
| | after | 60 | 53 | 0.6 / 6.5 / 38 | 0 | 0 | 12.0 | 12 | 502 sent again |
| 1 %, independent | after | 60 | 43 | 0.5 / 6.1 / 25 | 0 | 0 | 12.0 | 12 | 162 sent again |
| 80 ms stall every 2 s | after | 60 | 101 | 0.7 / 2.4 / 85 | 0 | 0 | 12.1 | 12 | 40 asked needlessly |
| 3 %, bursts of 3, 60 ms round trip | after | 55 | 321 | 34 / 110 / 147 | 60 | 0 | 8.3 | 5.1 | 869 sent again, 124 by parity (1,314 parity pieces, G = 8), 4 recovery frames |

The last row is the one that doesn't hold up: a 60 ms round trip with bursts of three. A piece lost twice needs two round trips and a
retry wait (60 + 90 + 60 ms), past the 150 ms patience, so frames are given up (4 recovery frames, no keyframe) and the rate controller
reads the 60 lost frames as congestion. Parity (G = 8 at that loss) mends about a third. The same spec on the Mac would do the same; away
from home with that much loss, G = 4 sooner or a longer patience would be the knobs (not tried).

**A stopped process (CI, 2026-11-09).** The test failed twice on shared GitHub runners with code that passes on reruns: on macOS the
rate backed off to 10.5 Mbps at 3 % (the floor is 9 Mbps since), and on Linux (`desktop.yml`, run 42632247105) the stage "1 %, bursts of 2"
gave up 33 frames with a 420 ms gap, 2 refreshes and 1 lost asked. Host, encoder and phone run in one process there, and a shared runner
stops a process now and then (another VM's turn, a cgroup's quota spent). Reproduced in Docker (Ubuntu 24.04, debug build) with the test
pinned to a few cores beside `stress-ng --cpu` hogs, and under a CFS quota (`--cpus 1`), which stops the whole process for 70–80 ms at a
time as a busy runner does. Traced, the stop itself wasn't the trouble; what the phone did after it was:

- **A real slow path in the phone's receiver.** After a stop, the first piece read sets `heard_at` to now (so it doesn't look like a
  stall), then the timers run before the pieces that came during the stop are read, the resend asked for among them. The frame has been
  "late" for the whole stop, past the 40 ms patience at home, so it's given up and everything behind it dropped while its piece sits in the
  queue (traced: `GIVE UP 743 … asked {2,3,4} twice, heard 2.472` at the very tick the backlog began). A stop of 70 ms became a recovery
  frame and 4–69 frames dropped. Now a `tick` more than 15 ms after the last one gives nothing up and the time away doesn't count against
  the patience (`a_hitch_on_the_phone_gives_nothing_up`).
- **The same after a stall.** Rarer (2 runs in 30 under the quota and hogs): the last 4 pieces of a frame lost in a burst, asked for once, then
  85 ms with nothing from the host (its thread starved; to the phone, a Wi-Fi stall). Retries rightly wait out a stall, but the first piece
  after it ended the stall and the frame, "late" for 50 ms, was given up in that tick before its retry could go. The spec always said the
  patience counts "while pieces arrive"; the receiver counted the stall too. Now it counts only time with pieces arriving and the phone
  running (`after_a_stall_the_piece_asked_for_gets_its_retry`); 0.35 s late in all still gives up regardless. The spec above has both
  rules, and a frame late 1 s of real time is given up even if every tick in between came late (`a_phone_that_stays_busy_still_gives_up`).
  The Swift and Kotlin receivers have all three, with the same tests.
- **The test phone fell behind.** `phone::watch` read one piece per turn of its loop, so a backlog drained no faster than the ticks; at a
  60 ms round trip under contention it never caught up (age p50 270 ms, 4 fps, 17 recoveries). It now reads everything queued before the
  timers run, lets out what the made-up network held before what came after it, as a network keeps order, and pings when a stage starts
  (until the first pong at 1 s the patience assumed a home network, so at a 60 ms round trip the warm-up gave frames up and, nothing yet
  acknowledged, asked for keyframes).
- **The test's encoder made up missed frames.** After a stop the synthetic screen sent every frame it had missed at once (36 frames,
  900 KB after a 600 ms stop), which overflows a Linux socket's default 212 KB on loopback and the resend budget. A capture shows what's
  on screen now, so it now skips to the current frame.
- **The rest is noise, measured.** A thread in the test sleeps 1 ms at a time and notes when it wakes much later: the process was stopped.
  The longest gap may be longer by the longest stop in that stage and a quarter more (the backlog is read after it), and frames shown as
  many as the time running allows (nothing is captured while stopped); the table prints the stops. On a quiet runner both limits are what
  they were. Frames given up (≤ 2), keyframes asked, corrupt frames and the rate stay strict, so a repair that's slow again shows whatever
  the runner does.

10 runs of the whole test in a row per row (debug build, Docker on an M-series Mac, Ubuntu 24.04; `main` at a4ad6c3c with its own test
against this change with this test, side by side on separate cores):

| Contention | | Passed | Home stages: frames given up (all runs) | Recoveries asked | Longest gap, ms | Process stopped (longest, in all per 4 s) |
|---|---|---|---|---|---|---|
| 2 cores, 4 `stress-ng --cpu` hogs | main | 8 / 10 | 0 | 0 | 100 | — |
| | this change | 10 / 10 | 0 | 0 | 96 | 8 ms, 0–23 ms |
| 4 cores, `--cpus 1` quota, 2 hogs | main | 1 / 10 | 140 | 23 | 215 | — |
| | this change | 10 / 10 | 0 | 0 | 178 | 76 ms, 1.7–1.9 s |
| 4 cores, `--cpus 1` quota alone | main | 10 / 10 | ≤ 2 a stage (logs not kept) | — | < 150 | — |
| | this change | 10 / 10 | 0 | 0 | 100 | 8 ms, 0 |

`main` failed in the 60 ms round-trip stage under hogs (4 fps: its test phone fell behind) and in the home stages under the quota with hogs
(frames given up after stops). Neither hogs alone (they take turns too briefly) nor a quota alone (it leaves the test enough CPU) stops the
process the way the CI runs were stopped; the two together do. The whole test needs about 0.4 of a core (17.7 s user over 45 s). With
this change the 60 ms stage keeps the occasional recovery the table above describes (a piece lost twice), 1–2 in 10 runs, and under the
quota with hogs shows 39 fps because the process ran 55 % of the time, nothing given up.

The real iPhone app (iPhone 17 Pro simulator, iOS 27.2, its own stage report) against `examples/host --screen-test` (ffmpeg's testsrc2
through libx264 at 60 fps, 12 Mbps, 1866×1048; no recovery frames, so `fec,nack`), 12 s after 3 s to settle, `BLURT_SCREEN_REPAIR=0` for
before:

| Network | | Frames shown / s | Longest gap, ms (p99) | Frozen ms / s | Frames dropped | Keyframes asked | Mbps | Rate after | Repaired |
|---|---|---|---|---|---|---|---|---|---|
| clean | after | 61 | 39 (24) | 0 | 0 | 0 | 12.6 | 12 | |
| 1 %, bursts of 2 | before | 24 | 1,936 (1,125) | 604 | 387 | 35 | 4.4 | 1.0 Mbps | |
| | after | 61 | 110 (51) | 50 | 0 | 0 | 12.6 | 12 | 195 asked, 333 sent again |
| 3 %, bursts of 3 | before | 10 | 2,476 (1,911) | 898 | 504 | 45 | 3.8 | 1.0 Mbps | |
| | after | 61 | 81 (48) | 44 | 0 | 0 | 12.6 | 12 | 486 asked, 851 sent again |
| 80 ms stall every 2 s | after | 61 | 91 (35) | 36 | 0 | 0 | 12.6 | 12 | |

The Android app (Pixel emulator `blurt_phone`, `c2.goldfish.h264.decoder`, launch extras `blurt_test_loss`, `blurt_screen_repair=0`)
against the same host, 12 s:

| Network | | Shown / s | Longest gap, ms (p99) | Frozen ms / s | Dropped | Keyframes asked | Mbps | Repaired |
|---|---|---|---|---|---|---|---|---|
| clean | after | 59.7 | 38 (24) | 0 | 0 | 0 | 12.7 | |
| 1 %, bursts of 2 | before | 21.0 | 1,612 (846) | 378 | 389 | 36 | 4.7 | |
| | after | 59.5 | 60 (33) | 6 | 0 | 0 | 12.7 | 116 sent again |
| 3 %, bursts of 3 | before | 16.9 | 904 (846) | 483 | 531 | 41 | 4.9 | |
| | after | 58.7 | 53 (38) | 12 | 0 | 0 | 12.7 | 506 sent again |

"Rate after": without repairs the rate controller read the losses as congestion and cut it step by step to 1 Mbps (ffmpeg restarted at each);
with them it never moved. The resends cost what was lost and a little more (pieces asked for twice when the first resend is late): 2–6 %
of the pieces at 1–3 % loss.

Not verified for the Rust host: a real Windows or Linux desktop with a phone on Wi-Fi; LTR recovery frames end to end with a phone (the
Windows MFT path was checked by decoding on the Mac, the iPhone and Android apps only against the ffmpeg test host, which has none); Quick
Sync, AMF and Qualcomm MFTs; the Linux backend on a real session since these changes (it builds and its tests pass in Docker); the DSCP mark
on the wire (set on the socket, not captured); 120 Hz (the simulator and emulator panels are 60 Hz).

## Not built

In the order they'd pay off:

1. **DSCP from the Mac.** §6: the service class picks the Mac's own Wi-Fi queue but writes no DSCP, so the access point still queues the
   picture as best effort on its way to the phone. A plain UDP socket with `IP_TOS` = AF41 (0x88) for the picture and EF (0xB8) for the
   pointer's place would carry it. It means sending from a BSD socket on the session's port instead of the NWListener flow; a second socket
   on the same port must never take the phone's packets from the first. Some networks mishandle marked packets (Chrome ships DSCP off by
   default): try on the founder's network with a download running before turning it on.
2. **Crops: the frame for a new crop takes a turn.** While panning a scrolling screen, frames leave 3–5 ms later (§5). A crop could replace
   the frame waiting for its turn instead of adding one; small, not tried.
3. **The encoder's 6 ms.** The largest part of a clean path. H.264, or a stage a little smaller than the phone's pixels while scrolling, may
   halve it; neither measured.
4. **Sharpening a still picture where it isn't yet** (§7): VA-API on Linux and Quick Sync / AMF on Windows need a real machine and
   the probes (`examples/linux_sharpen_probe.rs`, `examples/win_sharpen.rs`); Windows H.264 needs its own look. Also unmeasured: the
   ladder in a live session over the relay (only encoders alone were measured), and relaxing the Mac's `DataRateLimits` while
   sharpening so a thin link's resends aren't dropped and tried again.
5. **Region-aware quality** (more bits where the screen changed or the pointer is): needs an encoder that takes a QP map: NVENC's emphasis
   map, Media Foundation's delta-QP map (Windows 11 26100+), VA-API ROI. VideoToolbox has none public. Windows/Linux only.
6. **AV1** for Windows and Linux hosts with RTX 40+, Arc or RDNA3, to phones that decode it (iPhone 15 Pro and later, recent Android
   flagships): 10–25 % fewer bits on text in software encoders; no latency gain. No Mac encodes AV1 (M5 included).
7. **A direct path that carries no whole frame** (the Linux field test, 2026-11-09): turned out to be a test phone that never asked for a
   keyframe, not the path's MTU (all sizes to 1,472 bytes arrive). With NACK a piece lost on such a path is asked for; a fallback that moves
   the picture back to the relay after 2 s without a whole frame isn't built, and no measurement asks for it yet.

## Not verified

- A real iPhone on Wi-Fi: every number above is the simulator over loopback with a made-up network. The founder's to try: Settings → Mac
  Screen → Auto at home, scroll a terminal, compare with 1.0.14.
- 120 Hz presentation: the simulator's panel ran at 60 Hz in every run (`panel_ms` 16.7), so ProMotion is reasoned, not measured.
- LTR refresh decoding on an iPhone's own decoder: measured on the Mac's decoder (the same VideoToolbox HEVC decoder family) and in the
  simulator, which decodes on the Mac.
- Parity over a real long path; the policy's thresholds are WebRTC's and Moonlight's experience, not ours yet.
