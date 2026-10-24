// The dictation key (Fn / right ⌥ / either ⌥): modifier-only keys can't be Carbon hotkeys, so something has to listen
// to the keyboard. Which listener runs is BlurtCore's DictationListener (unit-tested); this file carries it out:
//   • the Fn filter (the key is Fn, record.dictation.fn_capture on, Accessibility granted): an active CGEventTap on a
//     thread of its own. macOS lets an Accessibility-trusted app filter every app's events, so it hears Fn without
//     Input Monitoring, and it drops the Fn press itself (flagsChanged of kVK_Function) so macOS's own 🌐 action
//     (emoji, input source, system dictation) doesn't run as well. Every other event passes untouched and at once:
//     the callback only copies the key code and flags and hands them to the main thread. If macOS refuses it, the
//     listen-only tap or the monitor below takes over (`filterRefused`, until Accessibility or the key changes);
//   • a listen-only CGEventTap (Input Monitoring). Listen-only = we never block, delay or change an event. A tap made
//     before Input Monitoring was granted hears only events aimed at Blurt and macOS never upgrades it, so
//     CGPreflightListenEventAccess() is the truth and the tap is made again when it flips to granted (a poll every
//     3 s while it isn't, whenever Blurt is activated, and at once from the permission guide);
//   • NSEvent global + local monitors when Input Monitoring is missing but Accessibility is granted (AppKit delivers
//     key events, flagsChanged included, to a global monitor of an Accessibility-trusted app);
//   • a tap the system disabled (tapDisabledByTimeout / ByUserInput) is enabled again, and made again if that fails.
// flagsChanged / keyDown / mouse-down go to DictationTrigger (BlurtCore) as events, each with the time it happened
// (the event's own timestamp, DictationTrigger.eventTime — not when the main thread got to it: the double-tap window
// is a few hundred ms and the main thread can be late). The key heard while another app is in front is remembered
// (`lastOtherApp`): Settings shows it, and only the user can make it happen. What the filter's thread reads (drop Fn,
// keep a lone ⇧) is behind a lock (`filterState`); the main thread sets it.
// The filter keeps keyDown and mouse-down in its mask on purpose: they must reach the trigger in the order they
// happened relative to the Fn change (Fn-← is a shortcut, not a tap), which a second listener can't promise. The
// callback only reads the key code and flags and lets them through at once.
// Test builds never install a tap or a monitor: BLURT_TEST_DICTATION_TAP (ok | failed: what tapCreate answers),
// BLURT_TEST_FILTER_TAP (ok | failed, default: the same), BLURT_TEST_INPUT_MONITORING / BLURT_TEST_ACCESSIBILITY
// (1 | 0) and the `dictation tap|filter|im|ax …` hooks simulate macOS.
import AppKit
import BlurtCore
import os

final class DictationKeys {
    var onEvent: ((DictationTrigger.Event) -> Void)?
    /// the listener changed (kind, or a tap was made again)
    var onChange: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var sourceLoop: CFRunLoop?
    private var tapMadeWithAccess = false
    private var tapIsFilter = false
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
    var watchedKeyCodes: Set<Int> = [63]
    /// The key is Fn and the user wants it kept from macOS (Dictation.apply sets it).
    var wantsFilter = false {
        didSet { if wantsFilter != oldValue { filterRefused = false } }
    }
    /// macOS refused the filter tap: not asked again until Accessibility or the key changes.
    private var filterRefused = false
    private var filterRefusedWithAX = false
    /// What the filter's thread decides by, set from the main thread: behind one lock.
    struct FilterState {
        var swallowFn = false
        var swallowShift = false
        var shiftKept = false
    }
    fileprivate let filterState = OSAllocatedUnfairLock(initialState: FilterState())
    /// Read on the filter's thread: drop Fn presses (true while the filter runs for dictation).
    fileprivate var swallowFn: Bool {
        get { filterState.withLock { $0.swallowFn } }
        set { filterState.withLock { $0.swallowFn = newValue } }
    }
    /// Read on the filter's thread: while a dictation listens (or its key is down), a lone ⇧ is Blurt's style toggle
    /// (docs/design/dictation-styles.md §3.2) and is kept from the app in front too — an input method would otherwise
    /// switch between Chinese and English on it. Only ⇧ changes with no other modifier held, and a release only when
    /// its press was kept (the app never sees half of a ⇧).
    var swallowShift: Bool {
        get { filterState.withLock { $0.swallowShift } }
        set { filterState.withLock { $0.swallowShift = newValue } }
    }
    /// How many Fn presses / releases the filter kept from macOS (tests and Settings).
    fileprivate(set) var swallowed = 0

    // MARK: what macOS says (simulated in test builds)

    /// Test builds only: what tapCreate "answers", "ok" or "failed" (BLURT_TEST_DICTATION_TAP, or the hook
    /// `dictation tap ok|failed`). nil = no simulated tap and no waiting for one. Never a real tap either way.
    static var testTap: String? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_DICTATION_TAP"] : nil
    /// Test builds: what an active (filter) tapCreate answers; nil = the same as `testTap`.
    static var testFilterTap: String? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_FILTER_TAP"] : nil
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
                          tap: tap != nil || simTap, tapMadeWithAccess: tapMadeWithAccess, monitor: globalMonitor != nil || simMonitor,
                          wantsFilter: wantsFilter && !filterRefused, tapIsFilter: tapIsFilter)
    }
    var kind: DictationListenerKind { state.kind }
    /// The key is heard in other apps: what "dictation works" means.
    var installed: Bool { kind.global }
    /// The Fn filter runs: macOS's own Fn action is kept out.
    var filtering: Bool { state.filtering }

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
        let ax = DictationKeys.accessibility
        if filterRefused && ax != filterRefusedWithAX { filterRefused = false }     // Accessibility changed: try again
        let before = kind
        var steps = state.plan()
        var failed = false
        var done: [String] = []
        while let step = steps.first {
            steps.removeFirst()
            done.append(step.rawValue)
            switch step {
            case .createTap: failed = !makeTap(filter: false)
            case .recreateTap: removeTap(); failed = !makeTap(filter: false)
            case .createFilterTap, .recreateFilterTap:
                if step == .recreateFilterTap { removeTap() }
                failed = !makeTap(filter: true)
                if failed {
                    filterRefused = true
                    filterRefusedWithAX = ax
                    steps = state.plan()           // without the filter: the listen-only tap or the monitor
                    failed = false
                }
            case .removeTap: removeTap()
            case .installMonitor: installMonitor()
            case .removeMonitor: removeMonitor()
            }
            if failed && steps.isEmpty { steps = state.plan(tapFailed: true) }    // no tap after all: the fallback
            if done.count > 8 { break }
        }
        swallowFn = tapIsFilter && wantsFilter
        schedulePoll()
        if !done.isEmpty || before != kind {
            emit(["event": "dictation_listener", "via": via, "kind": kind.rawValue, "steps": done, "generation": tapGeneration,
                  "filter": filtering, "filter_refused": filterRefused,
                  "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility])
            onChange?()
        }
    }

    private func schedulePoll() {
        // the Fn filter waits for Accessibility the same way
        guard state.shouldPoll || (wantsFilter && !filterRefused && !tapIsFilter) else { poll?.invalidate(); poll = nil; return }
        guard poll == nil else { return }
        let every = DictationInsert.testMode ? 0.5 : 3
        poll = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.refresh(via: "poll") }
    }

    // MARK: the tap

    private func makeTap(filter: Bool) -> Bool {
        let withAccess = filter ? DictationKeys.accessibility : DictationKeys.inputMonitoring
        // test builds (test channel on, or not the real bundle id) feed the trigger through their hook only: a real
        // tap there would hear the user's own keyboard (a test app started from a terminal inherits its grants)
        if DictationInsert.testMode {
            let answer = filter ? (DictationKeys.testFilterTap ?? DictationKeys.testTap) : DictationKeys.testTap
            // an active tap needs Accessibility
            guard answer == "ok", !filter || DictationKeys.accessibility else { return false }
            simTap = true
            tapIsFilter = filter
            tapMadeWithAccess = withAccess
            tapGeneration += 1
            return true
        }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let t: CFMachPort?
        if filter {
            // at the HID level, ahead of everything else, so the Fn press is gone before any app or macOS sees it
            t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: dictationFilterCallback, userInfo: me)
        } else {
            t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: dictationTapCallback, userInfo: me)
        }
        guard let t else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        // the filter holds every key press until its callback returns: never on the main thread, which can be busy
        let loop = filter ? FilterThread.shared.loop : CFRunLoopGetMain()
        CFRunLoopAddSource(loop, s, .commonModes)
        CFRunLoopWakeUp(loop)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = s
        sourceLoop = loop
        tapIsFilter = filter
        tapMadeWithAccess = withAccess
        tapGeneration += 1
        return true
    }

    private func removeTap() {
        swallowFn = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source, let l = sourceLoop { CFRunLoopRemoveSource(l, s, .commonModes) }
        tap = nil
        source = nil
        sourceLoop = nil
        simTap = false
        tapIsFilter = false
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
        emit(["event": "dictation_tap_disabled", "why": why, "reenabled": back, "filter": tapIsFilter])
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

    /// Test builds: what the filter does with a key change (`dictation filter-event CODE`): dropped or passed.
    func testFilterDecision(keyCode: Int) -> Bool {
        // a ⇧ press then its release, as the filter sees them: kept while a dictation listens (`swallowShift`)
        if keyCode == 56 || keyCode == 60 { return swallowFn && swallowShift }
        let drop = swallowFn && keyCode == 63
        if drop { swallowed += 1 }
        return drop
    }

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
        // when it happened (monitors deliver asynchronously, on the main thread)
        let at = DictationTrigger.eventTime(seconds: e.timestamp, now: CACurrentMediaTime())
        switch e.type {
        // the CGEvent's flags keep the device bits (left / right ⌥) the trigger needs
        case .flagsChanged: flags(Int(e.keyCode), e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue), otherApp: otherApp, at: at)
        case .keyDown: onEvent?(.keyDown(keyCode: Int(e.keyCode), time: at))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: onEvent?(.mouseDown(time: at))
        default: break
        }
    }

    /// mach_absolute_time ticks → ns (CGEventTimestamp is in ticks on Apple Silicon)
    static let ticksToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()
    /// A CGEvent's own time on CACurrentMediaTime's clock.
    static func time(_ event: CGEvent) -> CFTimeInterval {
        DictationTrigger.eventTime(raw: event.timestamp, now: CACurrentMediaTime(), ticksToNs: ticksToNs)
    }

    // MARK: events

    /// A modifier changed — from a tap, a monitor or a test (`dictation heard …`). Two listeners can overlap for a
    /// moment while one replaces the other: the same change twice within 30 ms counts once.
    func flags(_ code: Int, _ raw: UInt64, otherApp: Bool, at: CFTimeInterval? = nil) {
        let now = at ?? CACurrentMediaTime()
        if let l = lastFlags, l.code == code, l.flags == raw, abs(now - l.at) < 0.03 { return }
        lastFlags = (code, raw, now)
        if otherApp && watchedKeyCodes.contains(code) {
            lastOtherApp = Date()
            emit(["event": "dictation_key_other_app", "key_code": code])
        }
        onEvent?(.flags(keyCode: code, flags: raw, time: now))
    }

    /// From the listen-only tap (main thread) or the filter (handed over from its thread): type, key code, flags.
    fileprivate func received(_ type: CGEventType, code: Int, flags raw: UInt64, at now: CFTimeInterval) {
        switch type {
        case .tapDisabledByTimeout: tapDisabled("timeout")
        case .tapDisabledByUserInput: tapDisabled("user_input")
        case .flagsChanged:
            let pid = ProcessInfo.processInfo.processIdentifier
            let other = NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier != pid } ?? false
            flags(code, raw, otherApp: other, at: now)
        case .keyDown:
            onEvent?(.keyDown(keyCode: code, time: now))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onEvent?(.mouseDown(time: now))
        default: break
        }
    }
}

private func dictationTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let r = refcon {
        Unmanaged<DictationKeys>.fromOpaque(r).takeUnretainedValue()
            .received(type, code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags.rawValue,
                      at: DictationKeys.time(event))
    }
    return Unmanaged.passUnretained(event)
}

/// The Fn filter, on FilterThread: decide at once (drop an Fn change, pass everything else), handle on the main thread.
private func dictationFilterCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let r = refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<DictationKeys>.fromOpaque(r).takeUnretainedValue()
    let now = DictationKeys.time(event)
    let code = type == .flagsChanged || type == .keyDown ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : 0
    let raw = event.flags.rawValue
    // one short critical section: the main thread only ever sets these flags
    let drop = keys.filterState.withLock { s -> Bool in
        var drop = type == .flagsChanged && code == 63 && s.swallowFn
        if type == .flagsChanged, code == 56 || code == 60, s.swallowFn {
            let down = raw & 0x2_0000 != 0
            let others: UInt64 = 0x10_0000 | 0x4_0000 | 0x8_0000       // ⌘ ⌃ ⌥ (Fn is the dictation key itself)
            if down, !s.shiftKept, s.swallowShift, raw & others == 0 { s.shiftKept = true; drop = true }
            else if !down, s.shiftKept { s.shiftKept = false; drop = true }
        }
        return drop
    }
    DispatchQueue.main.async {
        if drop { keys.swallowed += 1 }
        keys.received(type, code: code, flags: raw, at: now)
    }
    return drop ? nil : Unmanaged.passUnretained(event)
}

/// A thread with its own run loop for the filter tap (an active tap stalls every key press while its callback waits) —
/// and for smart paste's ⌘V tap (Capture/SmartPaste.swift), which runs only while a card copy is armed.
final class FilterThread: Thread {
    static let shared: FilterThread = {
        let t = FilterThread()
        t.name = "blurt.dictation.fn-filter"
        t.qualityOfService = .userInteractive
        t.start()
        t.ready.wait()
        return t
    }()
    private let ready = DispatchSemaphore(value: 0)
    private(set) var loop: CFRunLoop!

    override func main() {
        loop = CFRunLoopGetCurrent()
        // a source that never fires keeps the run loop alive while no tap is attached
        var ctx = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &ctx)
        CFRunLoopAddSource(loop, keepAlive, .commonModes)
        ready.signal()
        while true { CFRunLoopRunInMode(.defaultMode, 3600, false) }
    }
}
