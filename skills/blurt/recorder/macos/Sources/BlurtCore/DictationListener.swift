// How dictation hears its key (docs/design/dictation.md §Trigger): which listener should run, decided from what macOS
// says now. Pure, so the recreate logic is unit-tested (Tests/BlurtCoreTests/DictationListenerTests); the app
// (Capture/Dictation/DictationKeys.swift) feeds in the state and carries out the steps.
//
//   the bug this fixes   a listen-only CGEventTap created before Input Monitoring was granted is accepted by macOS,
//                        but it only gets events aimed at Blurt itself, and macOS never upgrades it after the grant.
//                        So "the tap exists" isn't "the key is heard": CGPreflightListenEventAccess() is the truth,
//                        and the tap is torn down and made again when it flips to granted.
//   the Fn filter        when the key is Fn and Accessibility is granted, an active (filter) tap instead of a
//                        listen-only one: macOS lets an Accessibility-trusted app filter every app's events, so it
//                        hears Fn without Input Monitoring and can keep the Fn press from reaching macOS's own 🌐
//                        action (emoji, input source, system dictation). Typeless works the same way. If macOS
//                        refuses it, the app says so (`filterRefused`) and the plan falls back to the rest.
//   the fallback         no Input Monitoring but Accessibility: NSEvent global + local monitors. AppKit documents
//                        that key events (flagsChanged and keyDown included) reach a global monitor when the app is
//                        trusted for Accessibility; they are delivered asynchronously, so they never slow typing.
//   one listener at a time, so the trigger never sees a key twice.
import Foundation

public enum DictationListenerKind: String, Equatable {
    /// nothing is listening
    case none
    /// a tap that hears every app: listen-only made with Input Monitoring, or the Fn filter made with Accessibility
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
    /// the Fn filter: an active tap (Accessibility) that hears every app and keeps Fn from macOS
    case createFilterTap = "create_filter_tap"
    /// tear a listen-only tap down and make the filter instead
    case recreateFilterTap = "recreate_filter_tap"
    case removeTap = "remove_tap"
    case installMonitor = "install_monitor"
    case removeMonitor = "remove_monitor"
}

public struct DictationListener: Equatable {
    /// CGPreflightListenEventAccess()
    public var inputMonitoring: Bool
    /// AXIsProcessTrusted()
    public var accessibility: Bool
    /// whether a tap exists, and whether its permission (Input Monitoring; Accessibility for the filter) was granted
    /// when it was made
    public var tap: Bool
    public var tapMadeWithAccess: Bool
    public var monitor: Bool
    /// the key is Fn and the user wants it kept from macOS (and macOS hasn't refused the filter)
    public var wantsFilter: Bool
    /// the tap that exists is the active Fn filter
    public var tapIsFilter: Bool

    public init(inputMonitoring: Bool, accessibility: Bool, tap: Bool = false, tapMadeWithAccess: Bool = false, monitor: Bool = false,
                wantsFilter: Bool = false, tapIsFilter: Bool = false) {
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
        self.tap = tap
        self.tapMadeWithAccess = tapMadeWithAccess
        self.monitor = monitor
        self.wantsFilter = wantsFilter
        self.tapIsFilter = tapIsFilter
    }

    public var kind: DictationListenerKind {
        // a revoked grant: macOS stops feeding it
        if tap && tapMadeWithAccess && (tapIsFilter ? accessibility : inputMonitoring) { return .tap }
        if monitor { return .monitor }
        return tap ? .tapLocal : .none
    }

    /// The Fn filter runs: macOS's own Fn action is kept out while dictation owns Fn.
    public var filtering: Bool { kind == .tap && tapIsFilter }

    /// What to do now (in order). Empty = it's right as it is. Call again after `tapFailed` when a tap couldn't be made.
    public func plan(tapFailed: Bool = false) -> [DictationListenerStep] {
        if wantsFilter && accessibility && !tapFailed {
            if tap && tapIsFilter && tapMadeWithAccess { return monitor ? [.removeMonitor] : [] }
            return (monitor ? [DictationListenerStep.removeMonitor] : []) + [tap ? .recreateFilterTap : .createFilterTap]
        }
        if tap && tapIsFilter {
            // a filter that isn't wanted any more (another key, Accessibility gone): it goes, then the usual plan
            var rest = self
            rest.tap = false
            rest.tapIsFilter = false
            rest.tapMadeWithAccess = false
            return [.removeTap] + rest.plan(tapFailed: tapFailed)
        }
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
