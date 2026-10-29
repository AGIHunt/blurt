// BlurtRecorder — native macOS recorder for blurt (ScreenCaptureKit + AVAssetWriter).
//
// Flow: region picker (drag / click a window / F = full screen) → 3-2-1 countdown → recording with a floating
// control bar (timer, mic level, pause, pen, stop) that is never captured. Output: H.264/AAC mp4 + events.jsonl
// (pauses, markers, clicks, cursor samples, pen strokes). Built on first use by record.py with `swiftc`.
// Pen: hold ⌃ and drag to circle / underline / point at things — the ink is in the video and in events.jsonl.
//
// Control: HUD buttons, global hotkeys (defaults ⌥P pause/resume, ⌥A snap, ⌥M marker (+ snap), ⌥D pen on/off,
// ⌥S stop; configurable, Hotkeys.swift),
// stdin lines ("pause" | "resume" | "toggle" | "snap" | "marker" | "stop"), or SIGTERM/SIGINT (= stop).
// Snap mode, the island and notes live in Capture/ (Snap.swift, Island/, NoteBubble.swift); Peep, the mascot, in
// Icons/Mascot.swift (frames from Resources/Peep) and the menu-bar glyph in App/MenuGlyph.swift.
// stdout: one JSON object per line: ready, selected, countdown, recording, paused, resumed, marker, level?, stopped,
// cancelled, error.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement
import BlurtCore


// macOS's speech recognition for transcribe.py's `apple` backend (Capture/AppleSpeech.swift): answers and exits.
switch CommandLine.arguments.dropFirst().first {
case "--speech": AppleSpeech.runCLI(Array(CommandLine.arguments.dropFirst(2)))
case "--speech-status": AppleSpeech.runCLI(["--status"] + Array(CommandLine.arguments.dropFirst(2)))
default: break
}

var opts = Options.parse()
if let l = opts.lang { Loc.setting = l }
Loc.applyToSystemStrings()

if CommandLine.arguments.dropFirst().first == "--selftest" { runSelfTest(Array(CommandLine.arguments.dropFirst(2))) }

// A second copy of the app (double-click while it's running) just asks the running one to start recording.
// Only for plain launches — `--process`, `--background` etc. are explicit instructions for this process.
let plainLaunch = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") && !$0.hasPrefix("--lang") }
if opts.standalone, plainLaunch, ProcessInfo.processInfo.environment["BLURT_ALLOW_MULTI"] == nil,
   NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blurt.recorder")
       .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(.init("dev.blurt.recorder.start"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
// Blurt's own dictation is Fn: AppKit's Edit → Start Dictation (macOS's) would be a second one in the same menu.
// Emoji & Symbols stays. In-memory defaults only — nothing is written to the user's preferences.
UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
