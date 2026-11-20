// Keys to Remote (按键发往远端, docs/design/remote-desktop-viewer.md): while a computer's window is in front and its keys are captured, every
// key goes to that computer, the system's own shortcuts too (⌘Tab, ⌘Space, ⌃←): a session event tap takes them before macOS acts on
// them, and they never reach this Mac. Blurt already has Accessibility for its own keys; without it, the window still gets the keys an
// app gets (an NSEvent monitor) and the system's shortcuts stay here.
//
// One window at a time: the one in front. The tap is made when capture starts and removed when it ends, so nothing listens otherwise.
import AppKit
import BlurtRemoteKit
import Carbon

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
        plainKeys()
        // the tap sees ⌘Tab and letters only with Input Monitoring; with Accessibility alone it gets the modifiers and nothing else
        // (measured 2026-11-20: listen false, ⌘Tab stayed on this Mac). Asked for once a launch; the window says what's missing.
        // A test build asks for nothing and makes no tap: it runs beside the user's own apps
        let listen = !ViewerStore.testing && CGPreflightListenEventAccess()
        if !listen, !Self.askedListen, !ViewerStore.testing {
            Self.askedListen = true
            CGRequestListenEventAccess()
        }
        systemKeys = !ViewerStore.testing && makeTap() && listen
        // The window's own keys too, with the tap on: a key the tap took never reaches the app, so nothing goes twice. Letters can come here
        // without passing the tap at all: on this Mac (2026-11-20) only the modifiers reached it while every letter went straight to the app
        // (WindowServer: keyboard focus "viewbridge-key-window"), so the other computer got ⌃⌘ and never a letter. UU Remote takes them here.
        let kinds: NSEvent.EventTypeMask = systemKeys ? [.keyDown, .keyUp] : [.keyDown, .keyUp, .flagsChanged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] e in
            guard let self, let o = self.owner, Self.holdsKeys(o.window) else { return e }
            o.key(Event(code: e.keyCode, down: e.type == .keyDown || e.type == .flagsChanged && Self.isDown(e.keyCode, e.modifierFlags),
                        repeating: e.type == .keyDown && e.isARepeat, flags: CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue)),
                        modifiersOnly: e.type == .flagsChanged))
            return nil
        }
        // what decides whether the tap sees keys (Input Monitoring, Accessibility, another app's Secure Event Input): never a key
        emit(["event": "viewer_keys", "captured": true, "system": systemKeys, "listen": CGPreflightListenEventAccess(),
              "post": CGPreflightPostEventAccess(), "ax": AXIsProcessTrusted(), "secure_input": IsSecureEventInputEnabled()])
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
        restoreInput()
        if was { emit(["event": "viewer_keys", "captured": false]) }
    }

    // MARK: this Mac's input method

    /// The input method in use here when capture began (Sogou, Pinyin, Japanese…), put back when it ends. While keys go to the other computer
    /// this Mac types plain keys: an input method here takes letters into its own composing window (a ViewBridge window that becomes the
    /// key window), the capture never sees them, and the other computer gets nothing (2026-11-20, Sogou Wubi on this Mac, nothing typed on
    /// the M1 Max's lock screen). The other computer's own input method does the composing.
    /// The choice is the whole Mac's, so capture starts only with Blurt in front (ViewerWindowController.wantsKeys), and at the end the
    /// saved one comes back only if the plain one Blurt chose is still in use: one the user picked meanwhile stays.
    private var savedInput: InputMethod.Source?
    private var chosenPlain: String?
    private static var askedListen = false
    /// Input Monitoring is on: the system's shortcuts can go to the other computer.
    static var systemShortcuts: Bool { CGPreflightListenEventAccess() }

    private func plainKeys() {
        guard savedInput == nil, let cur = InputMethod.current(), !cur.plain else { return }   // a plain layout already (ABC, US…): left as it is
        guard let plain = InputMethod.selectPlain() else { return }
        savedInput = cur
        chosenPlain = plain
        emit(["event": "viewer_keys", "input": "plain", "was": cur.id, "now": plain])
    }

    private func restoreInput() {
        guard let saved = savedInput else { return }
        savedInput = nil
        defer { chosenPlain = nil }
        let now = InputMethod.current()?.id
        guard now == chosenPlain else {
            emit(["event": "viewer_keys", "input": "kept", "now": now ?? ""])
            return
        }
        InputMethod.select(saved)
        emit(["event": "viewer_keys", "input": "restored", "now": InputMethod.current()?.id ?? ""])
    }

    /// Blurt is the app in front. A test build can say so without being in front (`viewer active on|off`): it never takes the user's keys.
    static var appActive: Bool { testActive ?? NSApp.isActive }
    static var testActive: Bool?
    /// the window a test build counts as key (`viewer key`): an app behind others has no key window to make
    static weak var testKey: NSWindow?

    static func isKey(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        return w.isKeyWindow || ViewerStore.testing && testActive != nil && testKey === w
    }

    /// The window still has the keys: it's key, or a helper panel of this app is (an input method's, the system's accent picker) while
    /// it stays the main window.
    static func holdsKeys(_ w: NSWindow?) -> Bool {
        guard let w, appActive else { return false }
        if isKey(w) { return true }
        guard NSApp.mainWindow === w else { return false }
        guard let k = NSApp.keyWindow else { return true }
        return !(k.styleMask.contains(.titled) && k.canBecomeMain)
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
        guard let o = owner, Self.holdsKeys(o.window),
              e.getIntegerValueField(.eventSourceUserData) != RemoteInput.marker else { return Unmanaged.passUnretained(e) }
        let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        // the dictation key stays on this Mac: holding it with a computer's window in front dictates onto that computer
        if type == .flagsChanged, Dictation.enabled, Dictation.shared.trigger.key.keyCodes.contains(Int(code)) {
            return Unmanaged.passUnretained(e)
        }
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

/// This Mac's input method, by its id (TIS). A test build has a stand-in instead (`viewer input ID`), so a test never changes the user's.
enum InputMethod {
    struct Source {
        var id: String
        /// a plain keyboard layout (ABC, US, German…), not an input method
        var plain: Bool
        var tis: TISInputSource?
    }
    /// the test build's stand-in
    static var test = Source(id: "com.sogou.inputmethod.sogou.pinyin", plain: false)
    static let testPlain = "com.apple.keylayout.ABC"

    static func current() -> Source? {
        if ViewerStore.testing { return test }
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let id = Self.id(cur) else { return nil }
        var plain = false
        if let t = TISGetInputSourceProperty(cur, kTISPropertyInputSourceType) {
            plain = CFEqual(Unmanaged<CFString>.fromOpaque(t).takeUnretainedValue(), kTISTypeKeyboardLayout)
        }
        return Source(id: id, plain: plain, tis: cur)
    }

    /// The plain layout for this Mac's keyboard, selected: its id.
    static func selectPlain() -> String? {
        if ViewerStore.testing { test = Source(id: testPlain, plain: true); return testPlain }
        guard let plain = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let id = Self.id(plain),
              TISSelectInputSource(plain) == noErr else { return nil }
        return id
    }

    static func select(_ s: Source) {
        if ViewerStore.testing { test = s; return }
        if let t = s.tis { TISSelectInputSource(t) }
    }

    private static func id(_ s: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
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
