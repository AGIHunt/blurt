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

Then pair: Blurt on the Mac → Settings → iPhone → Add iPhone…, or on Windows and Linux Blurt → Settings → Phone, shows a QR code. Scan it in
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

Layout without a computer (debug builds): `SIMCTL_CHILD_BLURT_REMOTE_PRETEND=1` lights the keys as if connected, `=screen` also shows a
made-up desktop where the picture goes. `TEST_RUNNER_BLURT_RENDER_DIR=<folder>` makes `RenderTests` draw the main screen at every iPad
and iPhone Duo size and fold into that folder (docs/design/remote.md §iPad and iPhone Duo).
