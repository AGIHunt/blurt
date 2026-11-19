// Keys to Remote (按键发往远端, docs/design/remote-desktop-viewer.md): while a computer's window is in front and its keys are captured, every
// key goes to that computer, the system's own shortcuts too (⌘Tab, ⌘Space, ⌃←): a session event tap takes them before macOS acts on
// them, and they never reach this Mac. Blurt already has Accessibility for its own keys; without it, the window still gets the keys an
// app gets (an NSEvent monitor) and the system's shortcuts stay here.
//
// One window at a time: the one in front. The tap is made when capture starts and removed when it ends, so nothing listens otherwise.
import AppKit
import BlurtRemoteKit

final class ViewerKeyboard {
    static let shared = ViewerKeyboard()

    /// What a captured key does: the window's. `code`: the Mac key code; `flags`: the modifiers after it.
    struct Event {
        var code: UInt16
        var down: Bool
        var repeating: Bool
        var flags: CGEventFlags
        var modifiersOnly: Bool
    }

    private weak var owner: ViewerWindowController?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    /// the system's shortcuts are captured too (the tap is on); false: only what reaches the window
    private(set) var systemKeys = false

    var capturing: Bool { owner != nil }

    /// Capture for this window. True when the system's shortcuts come too.
    @discardableResult func capture(for w: ViewerWindowController) -> Bool {
        release()
        owner = w
        if makeTap() {
            systemKeys = true
        } else {
            systemKeys = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
                guard let self, let o = self.owner, o.window?.isKeyWindow == true else { return e }
                o.key(Event(code: e.keyCode, down: e.type == .keyDown || e.type == .flagsChanged && Self.isDown(e.keyCode, e.modifierFlags),
                            repeating: e.type == .keyDown && e.isARepeat, flags: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue)),
                            modifiersOnly: e.type == .flagsChanged))
                return nil
            }
        }
        emit(["event": "viewer_keys", "captured": true, "system": systemKeys])
        return systemKeys
    }

    func release(_ w: ViewerWindowController? = nil) {
        if let w, owner !== w { return }
        let was = owner != nil
        owner = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if was { emit(["event": "viewer_keys", "captured": false]) }
    }

    private static func isDown(_ code: UInt16, _ f: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 54, 55: f.contains(.command)
        case 56, 60: f.contains(.shift)
        case 58, 61: f.contains(.option)
        case 59, 62: f.contains(.control)
        case 63: f.contains(.function)
        case 57: f.contains(.capsLock)
        default: false
        }
    }

    private func makeTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: viewerTapCallback, userInfo: me) else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = s
        return true
    }

    /// From the tap, on the main thread: the window's, or nil to let the event go on.
    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        // only while this app's window is in front; what Blurt itself posts (a phone's keys on this Mac) goes on
        guard let o = owner, NSApp.isActive, o.window?.isKeyWindow == true,
              e.getIntegerValueField(.eventSourceUserData) != RemoteInput.marker else { return Unmanaged.passUnretained(e) }
        let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags
        let ns = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        o.key(Event(code: code, down: type == .keyDown || type == .flagsChanged && Self.isDown(code, ns),
                    repeating: type == .keyDown && e.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: flags,
                    modifiersOnly: type == .flagsChanged))
        return nil
    }
}

private func viewerTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ me: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let me else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ViewerKeyboard>.fromOpaque(me).takeUnretainedValue().handle(type, event)
}

extension RemoteModifiers {
    /// What a Mac keyboard holds, as the wire's bits (Fn apart: it travels with the keys it changes).
    init(_ f: CGEventFlags) {
        var m: RemoteModifiers = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskSecondaryFn) { m.insert(.function) }
        self = m
    }
}
