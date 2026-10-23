// The dictation key (right ⌥ / Fn / either ⌥) from a listen-only CGEventTap: modifier-only keys can't be Carbon
// hotkeys. Listen-only = we never block, delay or change an event. A listen-only keyboard tap needs Input Monitoring
// (kTCCServiceListenEvent): without it tapCreate returns nil, and Accessibility being granted doesn't change that.
// So whether dictation works is `installed` (the tap is there), never a permission check. flagsChanged / keyDown /
// mouse-down go to DictationTrigger (BlurtCore) as events.
import AppKit
import BlurtCore

final class DictationKeys {
    var onEvent: ((DictationTrigger.Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// test builds: a tap that "came up" (BLURT_TEST_DICTATION_TAP=ok) — nothing is installed
    private var simulated = false

    /// The tap is there, so the key is heard: the one thing that says dictation works.
    var installed: Bool { tap != nil || simulated }

    /// Input Monitoring as macOS reports it: for Settings and the logs only (see `installed`).
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Test builds only: what tapCreate "answers", "ok" or "failed" (BLURT_TEST_DICTATION_TAP, or the test hook
    /// `dictation tap ok|failed`). nil = no tap and no waiting for one. Never a real tap either way.
    static var testTap: String? = DictationInsert.testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_DICTATION_TAP"] : nil

    /// Creates the tap; false when macOS refuses (no Input Monitoring). Safe to call again.
    @discardableResult
    func start() -> Bool {
        if installed { return true }
        // test builds (test channel on, or not the real bundle id) feed the trigger through their hook only: a real
        // tap there would hear the user's own keyboard (a test app started from a terminal inherits its grants)
        if DictationInsert.testMode {
            simulated = DictationKeys.testTap == "ok"
            return simulated
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
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        simulated = false
    }

    fileprivate func received(_ type: CGEventType, _ e: CGEvent) {
        let now = CACurrentMediaTime()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .flagsChanged:
            onEvent?(.flags(keyCode: Int(e.getIntegerValueField(.keyboardEventKeycode)), flags: e.flags.rawValue, time: now))
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
