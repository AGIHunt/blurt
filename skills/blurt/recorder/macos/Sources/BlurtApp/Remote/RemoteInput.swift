// The phone's hands on this Mac: pointer, clicks, scrolling and keys as CGEvents (docs/design/remote.md §Input).
//
//  • everything runs on its own queue, never the main thread: a busy app must not make the pointer stutter.
//  • keys go down and up as a keyboard's would: modifiers first, then the key, then back up in reverse. Apps and macOS's own
//    shortcuts (⌘Tab, ⌃↑) read the real sequence, not just a flag on one event.
//  • what the phone holds is kept here (`heldKeys`, `heldButtons`, `stickyMods`), and `releaseAll` lets go of it: a phone
//    that drops off the Wi-Fi with ⌘ down must not leave the Mac stuck on ⌘.
//  • a scroll has phases, so apps treat it as a trackpad scroll: smooth, rubber-banding. After the fingers leave, the coast
//    runs here at 120 Hz, not on the phone, where Wi-Fi gaps would show as hitches.
//  • BLURT_TEST_COMMANDS=1: nothing is posted; each event goes to `testLog` so a test can check the sequence without
//    moving the user's real pointer. A pretend pointer moves instead (`pretendPointer`), so the screen can follow it from display
//    to display.
import AppKit
import BlurtRemoteKit
import Carbon.HIToolbox

final class RemoteInput {
    static let shared = RemoteInput()

    let queue = DispatchQueue(label: "blurt.remote.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private let testing = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
        && ProcessInfo.processInfo.environment["BLURT_TEST_REMOTE_POST"] != "1"
    /// tests: one line per event
    var testLog: ((String) -> Void)?

    private var stickyMods: RemoteModifiers = []
    private var heldKeys = Set<String>()
    private var heldChordMods: [String: RemoteModifiers] = [:]
    private var downMods: RemoteModifiers = []
    private var heldButtons = Set<Int>()

    private var lastClick: (button: RemoteMouseButton, at: CFTimeInterval, count: Int, point: CGPoint)?
    private var pointer: CGPoint?

    private var coast: DispatchSourceTimer?
    private var coastV = CGVector.zero
    private var coastLast: CFTimeInterval = 0
    private var scrolling = false
    private var scrollRest = CGVector.zero

    private static let modKeys: [(RemoteModifiers, CGKeyCode, CGEventFlags)] = [
        (.control, CGKeyCode(kVK_Control), .maskControl), (.option, CGKeyCode(kVK_Option), .maskAlternate),
        (.shift, CGKeyCode(kVK_Shift), .maskShift), (.command, CGKeyCode(kVK_Command), .maskCommand),
    ]

    private func flags(_ m: RemoteModifiers) -> CGEventFlags {
        var f = CGEventFlags()
        for (mod, _, flag) in Self.modKeys where m.contains(mod) { f.insert(flag) }
        return f
    }

    /// eventSourceUserData of everything posted here: Blurt's own dictation key listener leaves these alone, so a tap on
    /// the pad doesn't count as "a click joined in" and end a push-to-talk (only Esc still reaches it).
    static let marker: Int64 = 0x4252_4D54      // "BRMT"

    private func post(_ e: CGEvent?) {
        guard !testing else { return }
        e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e?.post(tap: .cghidEventTap)
    }

    // MARK: keys

    private func postKey(_ code: CGKeyCode, down: Bool, mods: RemoteModifiers) {
        testLog?("key \(code) \(down ? "down" : "up") mods=\(mods.glyphs)")
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags(mods).union(Self.keyFlags(code))
        post(e)
    }

    /// What a real keyboard says along with these keys. macOS's own shortcuts need it: ⌃↑ (Mission Control) and ⌃← ⌃→
    /// (desktops) do nothing without it, measured on macOS 26.
    private static func keyFlags(_ code: CGKeyCode) -> CGEventFlags {
        switch code {
        case 123...126: return [.maskNumericPad, .maskSecondaryFn]
        case 115, 116, 117, 119, 121: return .maskSecondaryFn
        default: return []
        }
    }

    /// The modifiers that should be down now, from everything holding them.
    private func syncMods(_ want: RemoteModifiers) {
        for (mod, code, _) in Self.modKeys where want.contains(mod) && !downMods.contains(mod) {
            downMods.insert(mod)
            postKey(code, down: true, mods: downMods)
        }
        for (mod, code, _) in Self.modKeys.reversed() where !want.contains(mod) && downMods.contains(mod) {
            downMods.remove(mod)
            postKey(code, down: false, mods: downMods)
        }
    }

    private var allHeldMods: RemoteModifiers { heldChordMods.values.reduce(stickyMods) { $0.union($1) } }

    func press(_ c: RemoteChord) {
        guard let k = RemoteKey.named(c.key) else {
            // modifiers alone: down and up (a lone tap)
            let keep = allHeldMods
            syncMods(keep.union(c.mods))
            syncMods(keep)
            return
        }
        let keep = allHeldMods
        syncMods(keep.union(c.mods))
        postKey(k.code, down: true, mods: downMods)
        postKey(k.code, down: false, mods: downMods)
        syncMods(keep)
    }

    func hold(_ c: RemoteChord, down: Bool) {
        let id = c.key.isEmpty ? "mods:\(c.mods.rawValue)" : c.key
        if down {
            guard !heldKeys.contains(id) else { return }
            heldKeys.insert(id)
            heldChordMods[id] = c.mods
            syncMods(allHeldMods)
            if let k = RemoteKey.named(c.key) { postKey(k.code, down: true, mods: downMods) }
        } else {
            guard heldKeys.remove(id) != nil else { return }
            heldChordMods[id] = nil
            if let k = RemoteKey.named(c.key) { postKey(k.code, down: false, mods: downMods) }
            syncMods(allHeldMods)
        }
    }

    func setSticky(_ m: RemoteModifiers) {
        stickyMods = m
        syncMods(allHeldMods)
    }

    func run(_ steps: [RemoteStep]) {
        for s in steps {
            switch s {
            case let .key(c): press(c)
            case let .wait(ms): usleep(UInt32(max(0, min(ms, 2000))) * 1000)
            case let .text(t): RemoteText.type(t, input: self)
            }
        }
    }

    func releaseAll() {
        stopCoast()
        if scrolling { endScroll() }
        for b in heldButtons { if let r = RemoteMouseButton(rawValue: b) { button(r, down: false) } }
        for k in heldKeys { if let n = RemoteKey.named(k) { postKey(n.code, down: false, mods: downMods) } }
        heldKeys.removeAll()
        heldChordMods.removeAll()
        stickyMods = []
        syncMods([])
    }

    // MARK: pointer

    private let pretendLock = NSLock()
    private var pretendAt: CGPoint?
    /// Tests that post nothing: where the pointer would be now. nil otherwise.
    var pretendPointer: CGPoint? {
        guard testing else { return nil }
        pretendLock.lock()
        defer { pretendLock.unlock() }
        return pretendAt ?? CGEvent(source: nil)?.location
    }

    private func pretend(_ p: CGPoint) {
        put(p)
        guard testing else { return }
        pretendLock.lock()
        pretendAt = p
        pretendLock.unlock()
    }

    // What the phone is told about the pointer (RemoteScreen's ticker, another queue).
    private let toldLock = NSLock()
    private var putAt: (point: CGPoint, at: Double)?
    private var phoneSeq: UInt32?

    private func put(_ p: CGPoint) {
        toldLock.lock()
        putAt = (p, CACurrentMediaTime())
        toldLock.unlock()
    }

    /// The phone's pointer instruction with this number is made (RemotePointerPacket.move, ToMac.pointerTo). Later ones count, and one
    /// far behind is a phone that started over.
    func made(_ seq: UInt32?) {
        guard let seq else { return }
        toldLock.lock()
        if let l = phoneSeq, RemoteCursor.covers(l, seq), l &- seq < 1 << 16 {} else { phoneSeq = seq }
        toldLock.unlock()
    }

    /// A new session: no numbers until this phone sends one.
    func forgetPhone() {
        toldLock.lock()
        phoneSeq = nil
        toldLock.unlock()
    }

    /// Where the pointer is, for the phone, and the newest instruction of the phone's that place includes. The system takes a moment to
    /// report a pointer just placed: until then it's where we put it, or a place said to include a move would be the one before it.
    func forPhone() -> (point: CGPoint, seq: UInt32?) {
        toldLock.lock()
        let put = putAt, seq = phoneSeq
        toldLock.unlock()
        if let pretend = pretendPointer { return (pretend, seq) }
        if let put, CACurrentMediaTime() - put.at < 0.15 { return (put.point, seq) }
        return (CGEvent(source: nil)?.location ?? .zero, seq)
    }

    private func current() -> CGPoint { pretendPointer ?? CGEvent(source: nil)?.location ?? .zero }

    /// A point on some display: a move off the edge of one lands on the edge, unless another display is there.
    private func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        let frames = ids.prefix(Int(count)).map(CGDisplayBounds)
        if frames.contains(where: { $0.contains(p) }) { return p }
        var best = p, dist = CGFloat.infinity
        for f in frames {
            let q = CGPoint(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < dist { dist = d; best = q }
        }
        return best
    }

    func move(dx: CGFloat, dy: CGFloat) {
        // fractions kept here; a real mouse moved in between takes over
        let from = here()
        let to = clamp(CGPoint(x: from.x + dx, y: from.y + dy))
        pointer = to
        pretend(to)
        let (type, button): (CGEventType, CGMouseButton) = heldButtons.contains(0) ? (.leftMouseDragged, .left)
            : heldButtons.contains(1) ? (.rightMouseDragged, .right) : (.mouseMoved, .left)
        testLog?("move \(Int(dx)),\(Int(dy))")
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.flags = flags(downMods)
        post(e)
    }

    /// The phone's view moved away from the pointer: it comes along, so what's touched next is what's in view.
    private var placedAt = 0.0
    func place(_ p: CGPoint) {
        let to = clamp(p)
        pointer = to
        pretend(to)
        placedAt = CACurrentMediaTime()
        testLog?("place \(Int(to.x)),\(Int(to.y))")
        guard let e = CGEvent(mouseEventSource: source, mouseType: heldButtons.contains(0) ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: to, mouseButton: .left) else { return }
        post(e)
    }

    /// Where the pointer is: where we put it (with its fractions), unless a real mouse has moved it since.
    private func here() -> CGPoint {
        // the system takes a moment to report a pointer just placed: a click right after it must land here, not where it was
        if let p = pointer, CACurrentMediaTime() - placedAt < 0.15 { return p }
        let c = current()
        if let p = pointer, hypot(c.x - p.x, c.y - p.y) <= 3 { return p }
        pointer = c
        return c
    }

    func dragBegin() {
        lastClick = nil
        button(.left, down: true)
    }

    func button(_ b: RemoteMouseButton, down: Bool) {
        let at = here()
        let now = CACurrentMediaTime()
        if down {
            var count = 1
            if let l = lastClick, l.button == b, now - l.at < NSEvent.doubleClickInterval, hypot(l.point.x - at.x, l.point.y - at.y) < 6 {
                count = l.count + 1
            }
            lastClick = (b, now, count, at)
            heldButtons.insert(b.rawValue)
        } else {
            heldButtons.remove(b.rawValue)
        }
        let (type, cg): (CGEventType, CGMouseButton) = switch b {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        testLog?("button \(b) \(down ? "down" : "up") count=\(lastClick?.count ?? 1) mods=\(downMods.glyphs)")
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: cg) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick?.count ?? 1))
        e.flags = flags(downMods)
        post(e)
    }

    // MARK: scroll

    /// Posted scroll events skip the system's direction setting, so it's applied here: "Natural scrolling" off flips it.
    private var scrollSign: CGFloat {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool == false ? -1 : 1
    }

    private func postScroll(dx rawX: CGFloat, dy rawY: CGFloat, phase: Int64, momentum: Int64) {
        // whole points go out, the rest waits for the next event: a slow scroll adds up, and doesn't round away to nothing
        let dx = rawX * scrollSign + scrollRest.dx, dy = rawY * scrollSign + scrollRest.dy
        scrollRest = CGVector(dx: dx - dx.rounded(.towardZero), dy: dy - dy.rounded(.towardZero))
        testLog?("scroll \(Int(dx)),\(Int(dy)) phase=\(phase) momentum=\(momentum)")
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded(.towardZero)), wheel2: Int32(dx.rounded(.towardZero)), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded(.towardZero)))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded(.towardZero)))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.location = here()     // where the pointer was just put, though the system may not say so yet: the view there takes the scroll
        e.flags = flags(downMods)
        post(e)
    }

    func scroll(dx: CGFloat, dy: CGFloat, phase: RemoteScrollPhase) {
        stopCoast()
        switch phase {
        case .began:
            scrolling = true
            postScroll(dx: dx, dy: dy, phase: 1, momentum: 0)
        case .changed:
            if !scrolling { scrolling = true; postScroll(dx: dx, dy: dy, phase: 1, momentum: 0) } else { postScroll(dx: dx, dy: dy, phase: 2, momentum: 0) }
        case .ended:
            endScroll()
        }
    }

    private func endScroll() {
        scrolling = false
        postScroll(dx: 0, dy: 0, phase: 4, momentum: 0)
    }

    func fling(vx: CGFloat, vy: CGFloat) {
        stopCoast()
        coastV = CGVector(dx: vx, dy: vy)
        guard hypot(vx, vy) > 40 else { return }
        postScroll(dx: 0, dy: 0, phase: 0, momentum: 1)
        coastLast = CACurrentMediaTime()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0 / 120, repeating: 1.0 / 120)
        t.setEventHandler { [weak self] in self?.coastStep() }
        coast = t
        t.resume()
    }

    private func coastStep() {
        let now = CACurrentMediaTime()
        let dt = now - coastLast
        coastLast = now
        // about the decay of a UIScrollView at normal speed
        let k = pow(0.998, dt * 1000)
        coastV = CGVector(dx: coastV.dx * k, dy: coastV.dy * k)
        if hypot(coastV.dx, coastV.dy) < 12 { return stopCoast() }
        postScroll(dx: coastV.dx * dt, dy: coastV.dy * dt, phase: 0, momentum: 2)
    }

    func stopCoast() {
        guard let c = coast else { return }
        c.cancel()
        coast = nil
        postScroll(dx: 0, dy: 0, phase: 0, momentum: 3)
    }
}

/// Text from the phone's keyboard. Unicode key events go straight in, but only while the Mac's input source is a plain
/// keyboard layout: an input method (Pinyin, Kana) would swallow them as raw keys. Then, and for anything long, it's pasted
/// the way a dictation is (the clipboard saved and put back).
enum RemoteText {
    private static let chunk = 16

    static var plainLayoutActive: Bool {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let t = TISGetInputSourceProperty(s, kTISPropertyInputSourceType) else { return true }
        return Unmanaged<CFString>.fromOpaque(t).takeUnretainedValue() == kTISTypeKeyboardLayout
    }

    static func type(_ text: String, input: RemoteInput) {
        guard !text.isEmpty else { return }
        input.testLog?("text \(text)")
        guard DispatchQueue.main.sync(execute: { plainLayoutActive }), text.utf16.count <= 64 else {
            // what comes after it (a Text key's Return) waits until the text is in
            let landed = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { DictationInsert.insert(text) { _ in landed.signal() } }
            _ = landed.wait(timeout: .now() + 2)
            return
        }
        var rest = Substring(text)
        while !rest.isEmpty {
            var piece = Substring()
            while let c = rest.first, c != "\n", piece.utf16.count + c.utf16.count <= chunk { piece.append(rest.removeFirst()) }
            if rest.first == "\n", piece.isEmpty { rest.removeFirst(); input.press(RemoteChord([], "Return")); continue }
            let u = Array(String(piece).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                u.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e.setIntegerValueField(.eventSourceUserData, value: RemoteInput.marker)
                if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] != "1" { e.post(tap: .cghidEventTap) }
            }
        }
    }
}
