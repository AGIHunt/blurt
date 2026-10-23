// The dictation key (right ⌥ / Fn / either ⌥): modifier-only keys can't be Carbon hotkeys, so something has to listen
// to the keyboard. Which listener runs is BlurtCore's DictationListener (unit-tested); this file carries it out:
//   • a listen-only CGEventTap (Input Monitoring). Listen-only = we never block, delay or change an event. A tap made
//     before Input Monitoring was granted hears only events aimed at Blurt and macOS never upgrades it, so
//     CGPreflightListenEventAccess() is the truth and the tap is made again when it flips to granted (a poll every
//     3 s while it isn't, and whenever Blurt is activated);
//   • NSEvent global + local monitors when Input Monitoring is missing but Accessibility is granted (AppKit delivers
//     key events, flagsChanged included, to a global monitor of an Accessibility-trusted app);
//   • a tap the system disabled (tapDisabledByTimeout / ByUserInput) is enabled again, and made again if that fails.
// flagsChanged / keyDown / mouse-down go to DictationTrigger (BlurtCore) as events. The right ⌥ heard while another app
// is in front is remembered (`lastOtherApp`): Settings shows it, and only the user can make it happen.
// Test builds never install a tap or a monitor: BLURT_TEST_DICTATION_TAP (ok | failed: what tapCreate answers),
// BLURT_TEST_INPUT_MONITORING / BLURT_TEST_ACCESSIBILITY (1 | 0) and the `dictation tap|im|ax …` hooks simulate macOS.
import AppKit
import BlurtCore

final class DictationKeys {
    var onEvent: ((DictationTrigger.Event) -> Void)?
    /// the listener changed (kind, or a tap was made again)
    var onChange: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapMadeWithAccess = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// test builds: what exists, simulated (nothing is installed)
    private var simTap = false
    private var simMonitor = false
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var lastFlags: (code: Int, flags: UInt64, at: CFTimeInterval)?

    /// How many taps were made (tests: a recreate is visible as a new generation).
    private(set) var tapGeneration = 0
    /// When the dictation key was last heard while another app was in front (from the listener itself).
    private(set) var lastOtherApp: Date?
    /// The keys whose presses count for `lastOtherApp` (Dictation sets them from the chosen key).
    var watchedKeyCodes: Set<Int> = [61]

    // MARK: what macOS says (simulated in test builds)

    /// Test builds only: what tapCreate "answers", "ok" or "failed" (BLURT_TEST_DICTATION_TAP, or the hook
    /// `dictation tap ok|failed`). nil = no simulated tap and no waiting for one. Never a real tap either way.
    static var testTap: String? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_DICTATION_TAP"] : nil
    /// Test builds: Input Monitoring / Accessibility as a test says (default: Input Monitoring when the tap is "ok").
    static var testInputMonitoring: Bool? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_INPUT_MONITORING"].map { $0 == "1" } : nil
    static var testAccessibility: Bool? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_ACCESSIBILITY"].map { $0 == "1" } : nil

    static var inputMonitoring: Bool {
        if DictationInsert.testMode { return testInputMonitoring ?? (testTap == "ok") }
        return CGPreflightListenEventAccess()
    }
    static var accessibility: Bool {
        if DictationInsert.testMode { return testAccessibility ?? false }
        return AXIsProcessTrusted()
    }

    /// Test builds wait for a simulated macOS only when a test says something about it.
    private var simulating: Bool { DictationKeys.testTap != nil || DictationKeys.testInputMonitoring != nil || DictationKeys.testAccessibility != nil }

    var state: DictationListener {
        DictationListener(inputMonitoring: DictationKeys.inputMonitoring, accessibility: DictationKeys.accessibility,
                          tap: tap != nil || simTap, tapMadeWithAccess: tapMadeWithAccess, monitor: globalMonitor != nil || simMonitor)
    }
    var kind: DictationListenerKind { state.kind }
    /// The key is heard in other apps: what "dictation works" means.
    var installed: Bool { kind.global }

    // MARK: start / stop / refresh

    /// Brings the listener in line with what macOS allows now, and keeps checking until it is a real tap.
    func start() {
        if activation == nil {
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.refresh(via: "activate") }
        }
        refresh(via: "start")
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        if let a = activation { NotificationCenter.default.removeObserver(a); activation = nil }
        removeTap()
        removeMonitor()
    }

    /// Re-reads Input Monitoring / Accessibility and carries out DictationListener's plan.
    func refresh(via: String) {
        if DictationInsert.testMode && !simulating { return }      // a test build that says nothing about macOS
        let before = kind
        var steps = state.plan()
        var failed = false
        var done: [String] = []
        while let step = steps.first {
            steps.removeFirst()
            done.append(step.rawValue)
            switch step {
            case .createTap: failed = !makeTap()
            case .recreateTap: removeTap(); failed = !makeTap()
            case .removeTap: removeTap()
            case .installMonitor: installMonitor()
            case .removeMonitor: removeMonitor()
            }
            if failed && steps.isEmpty { steps = state.plan(tapFailed: true) }    // no tap after all: the fallback
            if done.count > 8 { break }
        }
        schedulePoll()
        if !done.isEmpty || before != kind {
            emit(["event": "dictation_listener", "via": via, "kind": kind.rawValue, "steps": done, "generation": tapGeneration,
                  "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility])
            onChange?()
        }
    }

    private func schedulePoll() {
        guard state.shouldPoll else { poll?.invalidate(); poll = nil; return }
        guard poll == nil else { return }
        let every = DictationInsert.testMode ? 0.5 : 3
        poll = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.refresh(via: "poll") }
    }

    // MARK: the tap

    private func makeTap() -> Bool {
        let withAccess = DictationKeys.inputMonitoring
        // test builds (test channel on, or not the real bundle id) feed the trigger through their hook only: a real
        // tap there would hear the user's own keyboard (a test app started from a terminal inherits its grants)
        if DictationInsert.testMode {
            guard DictationKeys.testTap == "ok" else { return false }
            simTap = true
            tapMadeWithAccess = withAccess
            tapGeneration += 1
            return true
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: dictationTapCallback, userInfo: me) else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = s
        tapMadeWithAccess = withAccess
        tapGeneration += 1
        return true
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        simTap = false
        tapMadeWithAccess = false
    }

    /// The system turned the tap off (it was slow, or secure input): on again, or a new one when that doesn't hold.
    func tapDisabled(_ why: String) {
        var back = false
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: true)
            back = CGEvent.tapIsEnabled(tap: t)
        } else if simTap {
            back = DictationKeys.testTapReenables
        }
        emit(["event": "dictation_tap_disabled", "why": why, "reenabled": back])
        if !back {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.removeTap()
                self.refresh(via: "disabled")
            }
        }
    }
    /// test builds: whether a simulated disabled tap comes back on when enabled again (`dictation tap disable stuck`)
    static var testTapReenables = true

    // MARK: the monitor (Accessibility)

    private func installMonitor() {
        if DictationInsert.testMode { simMonitor = true; return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.received(e, otherApp: true) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.received(e, otherApp: false)
            return e
        }
    }

    private func removeMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        simMonitor = false
    }

    private func received(_ e: NSEvent, otherApp: Bool) {
        switch e.type {
        // the CGEvent's flags keep the device bits (left / right ⌥) the trigger needs
        case .flagsChanged: flags(Int(e.keyCode), e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue), otherApp: otherApp)
        case .keyDown: onEvent?(.keyDown(keyCode: Int(e.keyCode), time: CACurrentMediaTime()))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: onEvent?(.mouseDown(time: CACurrentMediaTime()))
        default: break
        }
    }

    // MARK: events

    /// A modifier changed — from the tap, a monitor or a test (`dictation heard …`). Two listeners can overlap for a
    /// moment while one replaces the other: the same change twice within 30 ms counts once.
    func flags(_ code: Int, _ raw: UInt64, otherApp: Bool) {
        let now = CACurrentMediaTime()
        if let l = lastFlags, l.code == code, l.flags == raw, now - l.at < 0.03 { return }
        lastFlags = (code, raw, now)
        if otherApp && watchedKeyCodes.contains(code) {
            lastOtherApp = Date()
            emit(["event": "dictation_key_other_app", "key_code": code])
        }
        onEvent?(.flags(keyCode: code, flags: raw, time: now))
    }

    fileprivate func received(_ type: CGEventType, _ e: CGEvent) {
        let now = CACurrentMediaTime()
        switch type {
        case .tapDisabledByTimeout: tapDisabled("timeout")
        case .tapDisabledByUserInput: tapDisabled("user_input")
        case .flagsChanged:
            let pid = ProcessInfo.processInfo.processIdentifier
            let other = NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier != pid } ?? false
            flags(Int(e.getIntegerValueField(.keyboardEventKeycode)), e.flags.rawValue, otherApp: other)
        case .keyDown:
            onEvent?(.keyDown(keyCode: Int(e.getIntegerValueField(.keyboardEventKeycode)), time: now))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onEvent?(.mouseDown(time: now))
        default: break
        }
    }
}

private func dictationTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let r = refcon { Unmanaged<DictationKeys>.fromOpaque(r).takeUnretainedValue().received(type, event) }
    return Unmanaged.passUnretained(event)
}
