// How dictation hears its key (docs/design/dictation.md §Trigger): which listener should run, decided from what macOS
// says now. Pure, so the recreate logic is unit-tested (Tests/BlurtCoreTests/DictationListenerTests); the app
// (Capture/Dictation/DictationKeys.swift) feeds in the state and carries out the steps.
//
//   the bug this fixes   a listen-only CGEventTap created before Input Monitoring was granted is accepted by macOS,
//                        but it only gets events aimed at Blurt itself, and macOS never upgrades it after the grant.
//                        So "the tap exists" isn't "the key is heard": CGPreflightListenEventAccess() is the truth,
//                        and the tap is torn down and made again when it flips to granted.
//   the fallback         no Input Monitoring but Accessibility: NSEvent global + local monitors. AppKit documents
//                        that key events (flagsChanged and keyDown included) reach a global monitor when the app is
//                        trusted for Accessibility; they are delivered asynchronously, so they never slow typing.
//   one listener at a time, so the trigger never sees a key twice.
import Foundation

public enum DictationListenerKind: String, Equatable {
    /// nothing is listening
    case none
    /// a listen-only event tap made with Input Monitoring: every app's keys
    case tap
    /// a tap made without Input Monitoring: macOS gives it only the events aimed at Blurt (the key works while Blurt
    /// is in front)
    case tapLocal = "tap_local"
    /// NSEvent monitors on the strength of Accessibility
    case monitor

    /// The key is heard in other apps.
    public var global: Bool { self == .tap || self == .monitor }
}

public enum DictationListenerStep: String, Equatable {
    case createTap = "create_tap"
    /// tear the tap down, then create it again (Input Monitoring arrived after it was made)
    case recreateTap = "recreate_tap"
    case removeTap = "remove_tap"
    case installMonitor = "install_monitor"
    case removeMonitor = "remove_monitor"
}

public struct DictationListener: Equatable {
    /// CGPreflightListenEventAccess()
    public var inputMonitoring: Bool
    /// AXIsProcessTrusted()
    public var accessibility: Bool
    /// whether a tap exists, and whether Input Monitoring was granted when it was made
    public var tap: Bool
    public var tapMadeWithAccess: Bool
    public var monitor: Bool

    public init(inputMonitoring: Bool, accessibility: Bool, tap: Bool = false, tapMadeWithAccess: Bool = false, monitor: Bool = false) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
        self.tap = tap
        self.tapMadeWithAccess = tapMadeWithAccess
        self.monitor = monitor
    }

    public var kind: DictationListenerKind {
        if tap && tapMadeWithAccess && inputMonitoring { return .tap }      // a revoked grant: macOS stops feeding it
        if monitor { return .monitor }
        return tap ? .tapLocal : .none
    }

    /// What to do now (in order). Empty = it's right as it is. Call again after `tapFailed` when a tap couldn't be made.
    public func plan(tapFailed: Bool = false) -> [DictationListenerStep] {
        if inputMonitoring && !tapFailed {
            // the real thing: a tap that hears every app; a monitor goes once it is there
            if tap && tapMadeWithAccess { return monitor ? [.removeMonitor] : [] }
            return (monitor ? [DictationListenerStep.removeMonitor] : []) + [tap ? .recreateTap : .createTap]
        }
        if accessibility {
            // the monitor hears other apps; a Blurt-only tap next to it would deliver Blurt's own keys twice
            var steps: [DictationListenerStep] = []
            if tap { steps.append(.removeTap) }
            if !monitor { steps.append(.installMonitor) }
            return steps
        }
        if monitor { return [.removeMonitor] + (tap || tapFailed ? [] : [.createTap]) }
        // nothing granted: a tap still hears the key while Blurt is in front (and the user sees why it isn't more)
        return tap || tapFailed ? [] : [.createTap]
    }

    /// Keep checking (every few seconds and when Blurt is activated) until the key is heard everywhere by a tap.
    public var shouldPoll: Bool { kind != .tap }
}
