# Blurt for iPhone

The iPhone as a trackpad, keys and microphone for Blurt on your computer: a Mac, or a Windows or Linux PC. The keys follow the computer: ⌘C on
a Mac, Ctrl+C on Windows and Linux. Design and decisions: [docs/design/remote.md](../../docs/design/remote.md); the wire and each computer's
default keys: [docs/design/remote-protocol.md](../../docs/design/remote-protocol.md).

## Build it yourself

It isn't on the App Store yet. You can build it onto your own iPhone with a Mac:

1. Install Xcode 16 or later from the App Store, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Clone this repository, then run:

   ```bash
   cd apps/ios
   xcodegen generate
   open BlurtRemote.xcodeproj
   ```

3. In Xcode, select the BlurtRemote target → Signing & Capabilities. Pick your own team (sign in with your Apple ID under
   Xcode → Settings → Accounts; a free account works), and change the bundle identifier to one of your own, such as
   `com.yourname.blurt`.
4. Connect your iPhone, select it as the run destination and press ⌘R. The first time, the iPhone asks you to turn on
   Developer Mode and to trust your developer certificate (Settings → General → VPN & Device Management).

With a free Apple account the app stops opening after 7 days: connect the iPhone and press ⌘R again. A paid Apple
Developer account keeps it for a year.

Then pair: Blurt on the computer (Mac, Windows or Linux) → Settings → Phone → Add Phone… shows a QR code. Scan it in
the app, or with the Camera.

## Develop

The project is generated (step 2 above; `BlurtRemote.xcodeproj` isn't committed). The wire format, crypto and key names are `BlurtRemoteKit` in `skills/blurt/recorder/macos`, shared with the Mac app.

Tests: `xcodebuild test -scheme BlurtRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and, for the protocol,
`swift test --filter BlurtRemoteKitTests` in `skills/blurt/recorder/macos`.

Testing against a Mac without touching your own: build Blurt with `BLURT_TEST_HOOKS=1` (`record.py build`; release builds ignore
the test variables) and run it with `BLURT_TEST_COMMANDS=1 BLURT_TEST_REMOTE=1`. It prints a pairing link
(`remote_pairing`) and every input event (`remote_input`) instead of posting them; open the link with `xcrun simctl openurl`.
`BLURT_TEST_REMOTE_POST=1` posts them for real. On the phone side, `SIMCTL_CHILD_BLURT_REMOTE_TEST_WAV=clip.wav` stands in for the mic, and
`SIMCTL_CHILD_BLURT_REMOTE_TEST_HOST=windows` (or `linux`, `mac`) shows that kind of computer as connected, with no connection, among three of
mixed kinds: for looking at its keys and words (debug builds only; nothing is saved).

`SIMCTL_CHILD_BLURT_REMOTE_PAIR=<link>` pairs with that code at launch, as the in-app scanner would (no tap needed), and
`SIMCTL_CHILD_BLURT_DISPLAY_TEST=1` then walks the display switcher on its own, logging each step on the computer (docs/design/remote.md
§Several displays). With nothing posted, the computer moves a pretend pointer, so following it across displays never moves yours.

Measuring the picture (docs/design/remote-realtime.md): `SIMCTL_CHILD_BLURT_SCREEN_TEST=window` runs the measured stages against a window
titled "Blurt Screen Test" and logs each (`remote_screen_phone` on the computer); `BLURT_SCREEN_STAGES=zoom1,pan2`, `_FPS`, `_BITRATE`,
`_SIZE=1800x1100` and `_SECONDS` shape the run, `BLURT_SCREEN_REPAIR=0` offers no repairs (as before 1.0.15), and a made-up bad network sits
in front of the decoder: `BLURT_TEST_LOSS=0.01:2` (pieces lost, mean burst) and `BLURT_TEST_STALL=80:2` (80 ms of nothing every 2 s). All
debug builds only, each with the `SIMCTL_CHILD_` prefix. On the Mac, `BLURT_SCREEN_FEC=8` forces parity at that group size.

Layout without a computer (debug builds): `SIMCTL_CHILD_BLURT_REMOTE_PRETEND=1` lights the keys as if connected, `=screen` also shows a
made-up desktop where the picture goes, and `SIMCTL_CHILD_BLURT_REMOTE_PRETEND_DISPLAYS=1` adds a second display for the switcher. `TEST_RUNNER_BLURT_RENDER_DIR=<folder>` makes `RenderTests` draw the main screen at every iPad
and iPhone Duo size and fold into that folder (docs/design/remote.md §iPad and iPhone Duo).
