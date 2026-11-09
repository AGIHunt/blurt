# Blurt for Android

The phone as trackpad, keys, microphone and screen for Blurt on your Mac, Windows or Linux computer. Phones, tablets and foldables, Android 8
and later. No Google services are needed: it works on phones without Google Play, and nothing is downloaded at run time.

How it's meant to feel and why: [docs/design/remote.md](../../docs/design/remote.md). What's Android's own: [docs/design/remote-android.md](../../docs/design/remote-android.md).

## Build it yourself

Until it's in an app store, you build it, or install an APK someone built.

**With Android Studio:** open `apps/android` (not the repository root), wait for Gradle to sync, plug in your phone with USB debugging on
(Settings → About phone → tap Build number seven times → Developer options → USB debugging), and press Run.

**From a terminal** (JDK 17 and the Android SDK; Android Studio installs both):

```sh
cd apps/android
./gradlew :app:installDebug          # builds and installs on the phone that's plugged in
./gradlew :app:assembleDebug         # or only builds: app/build/outputs/apk/debug/app-debug.apk
```

If Gradle can't find the SDK, put its path in `apps/android/local.properties`: `sdk.dir=/Users/you/Library/Android/sdk`.

**Sideloading an APK:** copy `app-debug.apk` to the phone and open it; Android asks once to allow installs from the app you opened it with
(Files, a browser). Or with the phone plugged in: `adb install -r app-debug.apk`.

A release build (`./gradlew :app:assembleRelease`) is smaller and faster; it's signed with the debug key unless you add your own signing
config.

## Pair

1. On the computer, open Blurt's Settings and choose **Phone** (on a Mac: **iPhone**). It shows a code.
2. On the phone, open Blurt and tap **Scan Code**, then point the camera at the code. The camera app works too: it opens Blurt, which asks
   before pairing.
3. Both show the same six digits; say yes on the computer.

From then on the phone connects by itself whenever the app opens, on the same network, or anywhere once the computer has a relay
(Settings → Phone → Relay Address on the computer). Several computers: Settings → Add Computer on the phone; hold the settings button on the
main screen to switch.

No camera, or the code won't read: copy the pairing link shown under the code on the computer and paste it into the field under the camera.

## Using it

- **Pad:** one finger moves the pointer, tap clicks, tap then drag drags, hold then lift right-clicks; one finger along the edge by your thumb
  scrolls; two fingers scroll, pinch zooms; three fingers change desktop or show all windows. Settings → Gestures lists them all.
- **Keys:** four pages (常用 Main, 字母 Letters, 符号 Symbols, 更多 More) and a dock that's always there. ⌘ ⇧ ⌥ ⌃ (Ctrl, Alt, Win on a PC) stay
  held for the next key; tap twice to lock. Hold ⌘Tab (Alt+Tab) and slide to step through apps. Edit Keys is at the end of the list.
- **Talk:** the mic key is your computer's dictation key: tap to start and stop, hold to talk, double tap to send.
- **Screen:** the display button shows the computer's screen on the pad; pinch to zoom in, as on a photo.
- **Tablet:** a keyboard or mouse connected to the tablet works the computer too. Click on the pad once to hand the mouse over; touch the
  screen to take it back.
- **Foldable:** half-fold it like a small laptop (tabletop): the picture goes up top, the pad and keys below.

## Developing

- `core/` is the protocol and the phone's logic in plain Kotlin, tested on its own: `cd core && gradle test`.
- `fakehost/` is a fake computer: `./gradlew :fakehost:run --args="--platform windows --picture some.png"`. It prints a pairing link
  (also in `build/fakehost-pairing.txt`) and everything the phone sends. An emulator reaches it at 10.0.2.2:
  `adb shell am start -a android.intent.action.VIEW -d "$(cat build/fakehost-pairing.txt)"`.
- `./gradlew :app:assembleDebug :app:testDebugUnitTest lint` is what has to pass.
- Icons are Material Symbols Rounded (Apache 2.0), cut down to the ones the app uses by `tools/symbols.py`.
