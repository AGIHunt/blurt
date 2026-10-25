// When dictation's key can't be heard (docs/design/dictation.md): the pure decisions behind the cues, so they are
// unit-testable (Tests/BlurtCoreTests/DictationAccessTests). The app (Capture/Dictation/Dictation.swift) feeds in what
// it knows and does what comes out.
//
//   the truth          the event tap. Dictation works when the tap is installed, not when a permission looks granted:
//                      a listen-only keyboard tap needs Input Monitoring, and Accessibility alone doesn't make it work
//   ask macOS          never at launch: the request APIs (the system prompt, and Blurt listed in System Settings)
//                      run when the user clicks Allow / Set Up — the permission guide (PermissionGuide.swift)
//   the island's word  "allow Input Monitoring" again when the user reaches for it (the voice-note key, Settings) or
//                      at launch, at most about once a day; the menu-bar menu's top row stays until the tap works
import Foundation

public struct DictationAccess: Equatable {
    /// Dictation is on in Settings.
    public var enabled: Bool
    /// The event tap is installed (the key is heard).
    public var tapInstalled: Bool

    public init(enabled: Bool, tapInstalled: Bool) {
        self.enabled = enabled
        self.tapInstalled = tapInstalled
    }

    /// The menu row "Turn On Dictation…", Settings → Dictation's warning: on and still deaf.
    public var needsSetup: Bool { enabled && !tapInstalled }

    /// macOS is never asked at launch (≤ 0.8 asked once per version); the user's click in the guide asks.
    public static let asksAtLaunch = false

    /// The island's toast: not more often than `every` (default 20 h — about once a day, whatever time the Mac wakes).
    public func nudge(lastNudge: Date?, now: Date, every: TimeInterval = DictationAccess.nudgeInterval) -> Bool {
        guard needsSetup else { return false }
        guard let last = lastNudge else { return true }
        return now.timeIntervalSince(last) >= every || now < last       // a clock set back doesn't silence it for good
    }

    public static let nudgeInterval: TimeInterval = 20 * 3600

    /// The tap came up after it was missing: say once that dictation works now.
    public static func confirm(before: DictationAccess, after: DictationAccess) -> Bool {
        before.needsSetup && after.enabled && after.tapInstalled
    }
}

/// What the Dictation page says stands between the user and a first dictation (its empty state and its header): the
/// one blocking step, in order — off, then the key's permission, then the speech model (v0.9 dogfood: a first run
/// without the model read "✓ Dictation is on", and Fn only then said a 2.5 GB download was needed). "Ready" only when
/// both the key and the model are.
public enum DictationPageStatus: Equatable {
    case off
    case needsPermission
    /// no speech model (or VAD) on this Mac: Download, with its size
    case noModel
    /// it is coming down: how far (MB)
    case downloading(done: Double, total: Double)
    case ready

    /// `modelReady`: nil = not known yet (not read: the page doesn't claim either way — ready, as the key does).
    public static func of(enabled: Bool, needsSetup: Bool, modelReady: Bool?, download: (done: Double, total: Double)?) -> DictationPageStatus {
        if !enabled { return .off }
        if needsSetup { return .needsPermission }
        if modelReady == false {
            if let d = download { return .downloading(done: d.done, total: d.total) }
            return .noModel
        }
        return .ready
    }
}

/// Another dictation app that also reacts to Fn (Typeless, Wispr Flow) is running while Fn is Blurt's key: both
/// dictate and the text can go in twice — which looks like Blurt's bug. Settings and the setup assistant said so, but
/// only there (v0.9 dogfood): now the island says it when it matters — a Fn take starting, or one of them launching —
/// once a day per app, with the way out (another key).
public enum DictationFnClash {
    /// The apps to mention now: Fn is the key, they run, and each wasn't mentioned today (`saidToday`).
    public static func toMention(key: DictationTrigger.Key, running: [String], saidToday: (String) -> Bool) -> [String] {
        guard key == .fn else { return [] }
        return running.filter { !saidToday($0) }
    }
}
