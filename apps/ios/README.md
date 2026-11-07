# Blurt Remote

The iPhone as a trackpad, keys and microphone for Blurt on your Mac. Design and decisions: [docs/design/remote.md](../../docs/design/remote.md).

```bash
cd apps/ios
xcodegen generate
open BlurtRemote.xcodeproj
```

The wire format, crypto and key names are `BlurtRemoteKit` in `skills/blurt/recorder/macos`, shared with the Mac app.

Pair: Blurt → Settings → iPhone shows a QR code. Scan it in the app, or with the Camera.

Tests: `xcodebuild test -scheme BlurtRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and, for the protocol,
`swift test --filter BlurtRemoteKitTests` in `skills/blurt/recorder/macos`.

Testing against a Mac without touching your own: run Blurt with `BLURT_TEST_COMMANDS=1 BLURT_TEST_REMOTE=1`. It prints a pairing link
(`remote_pairing`) and every input event (`remote_input`) instead of posting them; open the link with `xcrun simctl openurl`.
`BLURT_TEST_REMOTE_POST=1` posts them for real. On the phone side, `SIMCTL_CHILD_BLURT_REMOTE_TEST_WAV=clip.wav` stands in for the mic.
