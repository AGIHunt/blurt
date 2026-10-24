// Picture, then note — two pastes — into every chat app (v0.8.4 for WeChat / QQ; v0.8.5 everywhere it helps;
// BlurtCore CardSmartPaste.swift has the why and the model, CardDropTarget.swift the table). Browsers, Electron apps,
// WeChat and QQ take one thing per paste or drop — the picture wins, as an upload or an inline image — so Blurt
// pastes twice:
//
//  • SmartPaste: a card copy (CardExport.copy) is armed for 2 minutes. While it is, and only then, an active event tap
//    (Accessibility; on its own thread, keyDown only) looks at ⌘V. In a chat app (DropTargets.classify == .chat: not a
//    rich text app, a terminal, the Finder or Blurt), with the card copy still on the clipboard, it keeps that ⌘V from
//    the app and runs the sequence instead (PasteRunner): each step — a picture alone (PNG + TIFF), a note alone — goes
//    on the clipboard as its own lazily provided item, a ⌘V is posted, and the next step follows once the app has
//    asked for the data (or after 1.5 s); then the card copy is written back and armed again. Any other ⌘V, any other
//    app, or anything copied since: the event passes untouched. If the main thread then finds it shouldn't run after
//    all (the clipboard changed a moment ago), the ⌘V is posted again as it was, so the user's paste is never lost.
//    The island says "图 + 文已粘贴".
//  • DragNoteFollowUp: a card dropped into a chat app brought its picture as the only file; the app is brought
//    forward at the window it landed on (Accessibility: raise that window, make the app frontmost); the composer that
//    received the drop gets the focus if it hasn't (the editable text under the drop point, else the nearest one in
//    that window: ComposerPick — a chat page's drop zone is often all of it); FollowUpFocus decides whether to paste
//    and how to put the caret after the picture (WeChat / QQ ⌘↓; a selection →; a caret nothing; can't tell ⌘↓); the
//    note goes in as one paste — the user's clipboard is saved first and put back after. It counts only if the app
//    read the note. Can't (no Accessibility, setting off, secure input, the app didn't come forward, the focus is in
//    another window, an unknown native app without a text focus, the note never read): the drag_copy_note safety net
//    instead — the note on the clipboard, "⌘V to paste the note".
// The posted events carry a marker (eventSourceUserData) so the tap lets them through.
//
// Test builds (DictationInsert.testMode) never install a tap, never post an event and read no Accessibility:
// `smartpaste key PID` stands in for the user's ⌘V with process PID in front (its bundle as `droptarget map` says),
// every ⌘V / ⌘↓ / → the sequence would post goes to that process as a distributed notification
// (dev.blurt.test.standin {pid, do, pasteboard}) — our own stand-in app pastes from the private test pasteboard — and
// `followup facts …` says what Accessibility would have found. No app is activated.

import AppKit
import ApplicationServices
import BlurtCore
import Carbon.HIToolbox

/// Where a sequence's keys go: ⌘V / ⌘↓ posted at the HID level (the frontmost app), or — test builds — to a stand-in.
enum PasteKeys {
    /// eventSourceUserData of every event Blurt posts here: the smart-paste tap lets them through
    static let marker: Int64 = 0x426C_7572_7453_5021     // "BlurtSP!"
    static let standInNote = Notification.Name("dev.blurt.test.standin")

    enum Key: String {
        case paste, end, right
        init(_ c: CaretKey) { self = c == .end ? .end : .right }
    }

    static func post(_ k: Key, to pid: pid_t?, pasteboard: NSPasteboard) {
        emit(["event": "paste_key", "key": k.rawValue, "pid": Int(pid ?? 0), "test": DictationInsert.testMode])
        if DictationInsert.testMode {
            guard let pid else { return }
            DistributedNotificationCenter.default().postNotificationName(
                standInNote, object: nil, userInfo: ["pid": Int(pid), "do": k.rawValue, "pasteboard": pasteboard.name.rawValue],
                deliverImmediately: true)
            return
        }
        let code = CGKeyCode(k == .paste ? kVK_ANSI_V : k == .end ? kVK_DownArrow : kVK_RightArrow)
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = k == .right ? [] : .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }
}

/// One step on the clipboard: its types promised, its data given when the app asks — which is how the runner knows
/// the app has read it. Marked transient (clipboard managers skip it).
final class PasteStepProvider: NSObject, NSPasteboardItemDataProvider {
    let step: PasteStep
    var onRead: (() -> Void)?
    init(_ step: PasteStep) { self.step = step }

    var types: [NSPasteboard.PasteboardType] {
        switch step {
        case .image: return [.png, .tiff]
        case .text: return [.string]
        }
    }

    func item() -> NSPasteboardItem {
        let it = NSPasteboardItem()
        it.setDataProvider(self, forTypes: types)
        it.setData(Data(), forType: DictationInsert.transient)
        it.setData(Data(), forType: DictationInsert.autoGenerated)
        return it
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        var d: Data?
        switch step {
        case .image(let u):
            let png = try? Data(contentsOf: u)
            d = type == .tiff ? png.flatMap { NSBitmapImageRep(data: $0)?.tiffRepresentation(using: .lzw, factor: 0) } : png
        case .text(let s):
            d = Data(s.utf8)
        }
        if let d { item.setData(d, forType: type) }
        emit(["event": "paste_step_read", "type": type.rawValue, "given": d != nil])
        let f = onRead
        onRead = nil
        f?()
    }
}

/// Runs a PasteRun (BlurtCore) on the clipboard: put, ⌘V, wait for the read, next; then give the clipboard back.
final class PasteRunner {
    static let readTimeout: TimeInterval = 1.5
    /// after the first read: the app may still ask for the step's other type
    static let grace: TimeInterval = 0.15
    static let restoreAfter: TimeInterval = 0.6

    let pb: NSPasteboard
    let pid: pid_t?
    let restore: () -> Void
    var done: ((PasteRun) -> Void)?
    private(set) var model: PasteRun
    private var written = 0
    private var token = 0
    private var provider: PasteStepProvider?

    init(steps: [PasteStep], pasteboard: NSPasteboard, pid: pid_t?, restore: @escaping () -> Void) {
        model = PasteRun(steps: steps)
        pb = pasteboard
        self.pid = pid
        self.restore = restore
    }

    /// `prelude`: keys first (a drag's follow-up: ⌘↓ or →, the caret after the picture).
    func start(prelude: [PasteKeys.Key] = []) {
        for k in prelude { PasteKeys.post(k, to: pid, pasteboard: pb) }
        let go = { [self] in perform(model.start()) }
        if prelude.isEmpty { go() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: go) }
    }

    private func perform(_ actions: [PasteRun.Action]) {
        for a in actions {
            switch a {
            case .put(let step):
                let p = PasteStepProvider(step)
                provider = p
                token += 1
                let t = token
                p.onRead = { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + PasteRunner.grace) { self?.event(.read, token: t) }
                }
                pb.clearContents()
                pb.writeObjects([p.item()])
                written = pb.changeCount
                emit(["event": "paste_step", "step": PasteRunner.describe(step)])
            case .paste:
                PasteKeys.post(.paste, to: pid, pasteboard: pb)
                let t = token
                DispatchQueue.main.asyncAfter(deadline: .now() + PasteRunner.readTimeout) { [weak self] in self?.event(.timeout, token: t) }
            case .restore:
                restore()
            }
        }
        if model.state == .restoring {
            token += 1
            let t = token
            DispatchQueue.main.asyncAfter(deadline: .now() + PasteRunner.restoreAfter) { [weak self] in self?.event(.restoreDue, token: t) }
        }
        if model.finished {
            emit(["event": "paste_run", "state": "\(model.state)", "read": model.read, "unconfirmed": model.unconfirmed])
            done?(model)
            done = nil
        }
    }

    private func event(_ e: PasteRun.Event, token t: Int) {
        guard t == token, !model.finished else { return }
        provider?.onRead = nil
        // someone else wrote the clipboard (the user copied): stop, and put nothing back over it
        perform(model.handle(pb.changeCount != written ? .clobbered : e))
    }

    static func describe(_ s: PasteStep) -> String {
        switch s {
        case .image(let u): return "image:" + u.lastPathComponent
        case .text(let t): return "text:\(t.count)"
        }
    }
}

// MARK: - smart paste (⌘V after a copy)

/// What the tap's thread may read: kept under a lock, written on the main thread.
final class SmartPasteGate {
    private let lock = NSLock()
    private var armed = false
    private var front: String?
    private var running = false

    func set(armed a: Bool? = nil, front f: String?? = nil, running r: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let a { armed = a }
        if let f { front = f }
        if let r { running = r }
    }

    /// The tap's quick check: armed, a chat app in front (not Blurt), no sequence running.
    func intercepts() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return armed && !running && front != SmartPasteGate.me && SmartPastePolicy.sequences(frontBundle: front)
    }
    static let me = Bundle.main.bundleIdentifier
}

final class SmartPaste {
    static let shared = SmartPaste()

    /// record.smart_paste (on by default): smart paste after a copy, and the note pasted in after a drop.
    static var enabled: Bool { recordConfig()["smart_paste"] as? Bool ?? true }
    static var accessibility: Bool { DictationKeys.accessibility }
    static var now: Double { Snapper.now }

    let gate = SmartPasteGate()
    private(set) var arm: SmartPasteArm?
    /// writes the armed card copy again (after a sequence)
    private var rewrite: (() -> Bool)?
    private var count = 0
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var runner: PasteRunner?
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var pasteboard: NSPasteboard { capturePasteboard }

    // MARK: arming

    /// A card copy was written to the clipboard (`cards`, in order); `rewrite` writes it again.
    func armed(cards: [CardPasteboard.Card], rewrite: @escaping () -> Bool) {
        let steps = CardPasteSequence.steps(cards)
        guard SmartPaste.enabled, CardPasteSequence.needsSequence(steps) else {
            disarm(SmartPaste.enabled ? "one_thing" : "off")
            return
        }
        arm = SmartPasteArm(changeCount: pasteboard.changeCount, steps: steps, now: SmartPaste.now)
        self.rewrite = rewrite
        count = cards.count
        gate.set(armed: true, front: .some(NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
        startWatching()
        emit(["event": "smart_paste_armed", "steps": steps.map(PasteRunner.describe), "seconds": SmartPasteArm.window,
              "tap": tap != nil, "accessibility": SmartPaste.accessibility])
    }

    func disarm(_ why: String) {
        let was = arm != nil
        arm = nil
        rewrite = nil
        gate.set(armed: false)
        stopWatching()
        if was { emit(["event": "smart_paste_disarmed", "why": why]) }
    }

    private func startWatching() {
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        }
        if activation == nil {
            activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.gate.set(front: .some(app?.bundleIdentifier))
            }
        }
        installTap()
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
        if let a = activation { NSWorkspace.shared.notificationCenter.removeObserver(a); activation = nil }
        removeTap()
    }

    /// Every 0.5 s while armed: the window passed, or something else was copied → disarmed.
    private func check() {
        guard let a = arm, runner == nil else { return }
        if SmartPaste.now >= a.until { return disarm("expired") }
        if pasteboard.changeCount != a.changeCount { return disarm("clipboard_changed") }
        if !SmartPaste.enabled { return disarm("off") }
        if tap == nil { installTap() }          // Accessibility granted since
    }

    // MARK: the tap (Accessibility; only while armed)

    private func installTap() {
        guard tap == nil, !DictationInsert.testMode, SmartPaste.accessibility else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: smartPasteTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            emit(["event": "smart_paste_tap", "made": false])
            return
        }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        let loop = FilterThread.shared.loop
        CFRunLoopAddSource(loop, s, .commonModes)
        CFRunLoopWakeUp(loop)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = s
        emit(["event": "smart_paste_tap", "made": true])
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(FilterThread.shared.loop, s, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: a ⌘V the tap kept from the app

    /// On the main thread, for a ⌘V the tap kept (or a test's `smartpaste key`): the sequence, or the ⌘V as it was.
    func userPasted(frontPID: pid_t?, frontBundle: String?) {
        let decision = SmartPastePolicy.decide(.init(
            enabled: SmartPaste.enabled, arm: arm, now: SmartPaste.now, changeCount: pasteboard.changeCount, frontBundle: frontBundle,
            accessibility: SmartPaste.accessibility, secureInput: !DictationInsert.testMode && IsSecureEventInputEnabled(),
            running: runner != nil, frontIsBlurt: frontPID == getpid()))
        emit(["event": "smart_paste_key", "bundle": frontBundle ?? NSNull(), "decision": "\(decision)"])
        guard decision == .sequence, let a = arm else {
            PasteKeys.post(.paste, to: frontPID, pasteboard: pasteboard)       // the user's own paste, as it was
            return
        }
        gate.set(running: true)
        let r = PasteRunner(steps: a.steps, pasteboard: pasteboard, pid: frontPID) { [weak self] in self?.putCopyBack() }
        runner = r
        let n = count
        r.done = { [weak self] run in
            guard let self else { return }
            self.runner = nil
            self.gate.set(running: false)
            if run.state == .aborted { return self.disarm("clipboard_changed") }
            island.toast(n > 1 ? Loc.plural("capture.smart_paste.done_n", table: "Capture", count: n)
                               : Loc.t("capture.smart_paste.done", table: "Capture"), actionTitle: nil, action: nil)
        }
        r.start()
    }

    /// The card copy back on the clipboard, armed again for another ⌘V.
    private func putCopyBack() {
        guard let a = arm, rewrite?() == true else { return disarm("restore_failed") }
        arm = a.rearmed(changeCount: pasteboard.changeCount, now: SmartPaste.now)
        emit(["event": "smart_paste_restored", "change_count": pasteboard.changeCount])
    }

    // MARK: tests

    /// `smartpaste key PID | state | set on|off | notefile on|off`
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "key":
            // the tap's view first (a ⌘V reaching it with that app in front), then the main thread's decision
            let pid = a.count > 1 ? pid_t(a[1]) : nil
            let bundle = pid.map { DropProbe.target(pid: $0).bundleID } ?? nil
            gate.set(front: .some(bundle))
            let chord = PasteChord.isPaste(keyCode: PasteChord.vKeyCode, characters: "v", flags: PasteChord.command, autorepeat: false)
            let kept = chord && gate.intercepts()
            emit(["event": "smart_paste_tap_test", "pid": Int(pid ?? 0), "bundle": bundle ?? NSNull(), "kept": kept])
            if kept { userPasted(frontPID: pid, frontBundle: bundle) } else { PasteKeys.post(.paste, to: pid, pasteboard: pasteboard) }
        case "set":
            setRecordConfig("smart_paste", a.count > 1 ? a[1] == "on" : nil)
            emit(["event": "smart_paste_set", "on": SmartPaste.enabled])
        case "notefile":
            setRecordConfig("drag_note_file", a.count > 1 && a[1] == "on" ? true : nil)
            emit(["event": "drag_note_file_set", "on": CardExport.attachNoteFile])
        default:
            emit(["event": "smart_paste_state", "armed": arm != nil, "steps": arm?.steps.map(PasteRunner.describe) ?? [],
                  "left": arm.map { max(0, $0.until - SmartPaste.now) } ?? 0,
                  "live": arm?.isLive(now: SmartPaste.now, changeCount: pasteboard.changeCount) ?? false,
                  "enabled": SmartPaste.enabled])
        }
    }
}

/// The smart-paste tap, on FilterThread: a quick look at each key press; only a ⌘V into a chat app while a card copy
/// is armed is kept (and handed to the main thread). Everything else — and our own posted events — passes at once.
private func smartPasteTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let r = refcon else { return Unmanaged.passUnretained(event) }
    let sp = Unmanaged<SmartPaste>.fromOpaque(r).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { if let t = sp.tap { CGEvent.tapEnable(tap: t, enable: true) } }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != PasteKeys.marker else { return Unmanaged.passUnretained(event) }
    var len = 0
    var chars = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
    let s = len > 0 ? String(utf16CodeUnits: chars, count: len) : nil
    guard PasteChord.isPaste(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), characters: s,
                             flags: event.flags.rawValue, autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0),
          sp.gate.intercepts() else { return Unmanaged.passUnretained(event) }
    DispatchQueue.main.async {
        let front = NSWorkspace.shared.frontmostApplication
        sp.userPasted(frontPID: front?.processIdentifier, frontBundle: front?.bundleIdentifier)
    }
    return nil
}

// MARK: - the note after a drop

enum DragNoteFollowUp {
    /// tests: what Accessibility would have said (`followup facts editable=1,selection=0,window=same,secure=0`)
    static var testFacts: [String: String] = [:]

    /// Bring the app forward at the drop point, find the composer, put the caret after the picture, paste the note,
    /// give the clipboard back. `done(true)`: pasted, and the app read it.
    static func run(note: String, target t: DropTarget, at p: NSPoint, done: @escaping (Bool) -> Void) {
        // the drop has to finish in the app first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            bringForward(pid: t.pid, at: p) { ok, window in
                guard ok else {
                    emit(["event": "drag_note_follow_up", "result": "not_front"])
                    return done(false)
                }
                focus(target: t, at: p, window: window) { facts in
                    let decision = FollowUpFocus.decide(facts)
                    emit(["event": "drag_note_focus", "kind": t.kind.rawValue, "front": facts.frontIsTarget,
                          "same_window": facts.sameWindow.map { $0 as Any } ?? NSNull(),
                          "editable": facts.editable.map { $0 as Any } ?? NSNull(),
                          "selection": facts.selection.map { $0 as Any } ?? NSNull(), "decision": "\(decision)"])
                    guard case .paste(let caret) = decision else { return done(false) }
                    let pb = capturePasteboard
                    let saved = DictationInsert.Saved.take(pb)
                    // (the runner restores only while the clipboard still holds its own step: nothing copied since)
                    var r: PasteRunner? = PasteRunner(steps: [.text(note)], pasteboard: pb, pid: t.pid) { saved.restore(pb) }
                    r?.done = { run in
                        emit(["event": "drag_note_follow_up", "result": "\(run.state)", "read": run.read])
                        done(run.state == .done && run.read > 0)
                        r = nil
                    }
                    r?.start(prelude: caret.map(PasteKeys.Key.init))
                }
            }
        }
    }

    /// The window under `p` raised and its app frontmost (Accessibility), then wait until it is (up to 1.2 s); `then`
    /// gets that window too. Test builds activate nothing: the stand-in is told what to do by notification.
    static func bringForward(pid: pid_t, at p: NSPoint, _ then: @escaping (Bool, AXUIElement?) -> Void) {
        if DictationInsert.testMode {
            emit(["event": "drag_note_activate", "pid": Int(pid), "test": true])
            return then(true, nil)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let window = AXProbe.element(app, at: p).flatMap { AXProbe.element($0, kAXWindowAttribute) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if let w = window {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        let start = CACurrentMediaTime()
        func wait() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // a moment for its window to take the key focus
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then(true, window) }
            }
            guard CACurrentMediaTime() - start < 1.2 else { return then(false, window) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait)
        }
        wait()
    }

    /// What has the focus now, after giving it to the composer that received the drop if it isn't there: the
    /// editable text under the drop point, else (the focus isn't editable text in that window) the nearest editable
    /// text area in the window (ComposerPick). WeChat / QQ: nothing is moved (the drop went into their composer, and
    /// Qt's Accessibility can't say). Test builds: `testFacts`.
    static func focus(target t: DropTarget, at p: NSPoint, window: AXUIElement?, _ then: @escaping (FollowUpFocus.Facts) -> Void) {
        var f = FollowUpFocus.Facts(kind: t.kind)
        if DictationInsert.testMode {
            let x = testFacts
            func flag(_ k: String) -> Bool? { x[k].map { ["1", "true", "yes"].contains($0) } }
            f.editable = flag("editable")
            f.selection = x["selection"].flatMap { Int($0) }
            f.sameWindow = x["window"].map { $0 == "same" }
            f.focusSecure = flag("secure") ?? false
            f.frontIsTarget = x["front"].map { $0 != "other" } ?? true
            return then(f)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        f.frontIsBlurt = front == getpid()
        f.frontIsTarget = front == t.pid
        f.secureInput = IsSecureEventInputEnabled()
        guard AXIsProcessTrusted(), f.frontIsTarget, t.kind != .qt else { return then(f) }
        let app = AXUIElementCreateApplication(t.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let read = { (moved: Bool) -> FollowUpFocus.Facts in
            var g = f
            guard let el = AXProbe.element(app, kAXFocusedUIElementAttribute) else { return g }
            let a = AXProbe.Focus(el)
            g.editable = a.editable
            g.focusSecure = a.secure
            // a composer we just focused: its old caret may be anywhere — "can't tell" puts it at the end
            g.selection = moved ? nil : a.selection
            if let w = window, let fw = AXProbe.element(el, kAXWindowAttribute) { g.sameWindow = CFEqual(w, fw) }
            return g
        }
        let now = read(false)
        let atDrop = AXProbe.element(app, at: p).flatMap(AXProbe.composer)
        var target: AXUIElement?
        if let c = atDrop {
            if let el = AXProbe.element(app, kAXFocusedUIElementAttribute), AXProbe.same(el, c) { return then(now) }
            target = c
        } else if now.editable != true || now.sameWindow == false, let w = window {
            target = AXProbe.nearestComposer(in: w, to: p)
        }
        guard let c = target else { return then(now) }
        AXUIElementSetAttributeValue(c, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        emit(["event": "drag_note_composer", "role": AXProbe.string(c, kAXRoleAttribute) ?? NSNull(), "at_drop": atDrop != nil])
        // web content takes the focus asynchronously
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then(read(true)) }
    }

    /// `followup facts K=V,… | clear`
    static func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "facts":
            testFacts = [:]
            for kv in (a.count > 1 ? a[1] : "").split(separator: ",") {
                let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if p.count == 2 { testFacts[p[0]] = p[1] }
            }
        default: testFacts = [:]
        }
        emit(["event": "followup_facts", "facts": testFacts])
    }
}

/// Small Accessibility reads for the follow-up (another app's elements; every call bounded by the app element's
/// messaging timeout).
enum AXProbe {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let r = v,
              CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)     // swiftlint:disable:this force_cast
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
    }

    /// The element of `app` at a global Cocoa point.
    static func element(_ app: AXUIElement, at p: NSPoint) -> AXUIElement? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(top - p.y), &el) == .success else { return nil }
        return el
    }

    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// `el` as a composer: a text area / field itself, or the editable root it is inside (a web contenteditable).
    static func composer(_ el: AXUIElement) -> AXUIElement? {
        if textRoles.contains(string(el, kAXRoleAttribute) ?? "") { return el }
        return element(el, "AXHighestEditableAncestor") ?? element(el, "AXEditableAncestor")
    }

    /// The focused element as the follow-up sees it.
    struct Focus {
        var editable = false
        var secure = false
        var selection: Int?
        init(_ el: AXUIElement) {
            let role = AXProbe.string(el, kAXRoleAttribute)
            let sub = AXProbe.string(el, kAXSubroleAttribute)
            secure = role == "AXSecureTextField" || sub == "AXSecureTextField"
            var range: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let r = range,
               CFGetTypeID(r) == AXValueGetTypeID() {
                var cf = CFRange()
                if AXValueGetValue(r as! AXValue, .cfRange, &cf) { selection = cf.length }     // swiftlint:disable:this force_cast
            }
            editable = AXProbe.textRoles.contains(role ?? "") || AXProbe.element(el, "AXEditableAncestor") != nil
                || (selection != nil && role != "AXStaticText" && role != "AXWebArea")
        }
    }

    /// The editable text area nearest to `p` in `window`: web areas are asked for their text fields (the search
    /// predicate Chromium and WebKit answer for VoiceOver), the rest is walked breadth-first — at most 200 elements and
    /// 0.4 s, never into a web area's own tree.
    static func nearestComposer(in window: AXUIElement, to p: NSPoint) -> AXUIElement? {
        let start = CACurrentMediaTime()
        var found: [AXUIElement] = []
        var queue = [window]
        var seen = 0
        while !queue.isEmpty, seen < 200, CACurrentMediaTime() - start < 0.4 {
            let el = queue.removeFirst()
            seen += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) { found.append(el); continue }
            if role == "AXWebArea" { found += search(el); continue }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] {
                queue += k
            }
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frames = found.map(frame)
        return ComposerPick.nearest(frames, to: CGPoint(x: p.x, y: top - p.y)).map { found[$0] }
    }

    /// A web area's editable text fields (AXUIElementsForSearchPredicate, AXTextFieldSearchKey).
    static func search(_ web: AXUIElement) -> [AXUIElement] {
        let q: [String: Any] = ["AXSearchKey": "AXTextFieldSearchKey", "AXResultsLimit": 20, "AXDirection": "AXDirectionNext",
                                "AXVisibleOnly": true]
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, q as CFDictionary, &v) == .success,
              let list = v as? [AXUIElement] else { return [] }
        return list.compactMap(composer)
    }

    /// An element's frame, top-left screen coordinates.
    static func frame(_ el: AXUIElement) -> CGRect {
        var pos = CGPoint.zero, size = CGSize.zero
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, let r = v,
           CFGetTypeID(r) == AXValueGetTypeID() { AXValueGetValue(r as! AXValue, .cgPoint, &pos) }      // swiftlint:disable:this force_cast
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let r = v,
           CFGetTypeID(r) == AXValueGetTypeID() { AXValueGetValue(r as! AXValue, .cgSize, &size) }      // swiftlint:disable:this force_cast
        return CGRect(origin: pos, size: size)
    }
}
