// The island (K7): one component at the top centre of the screen that holds the recording controls, the current
// project, voice input, the capture counts and the work in progress. It replaces the recording HUD and the perch.
//
// Geometry — on a screen with a notch (safeAreaInsets.top > 0) the island *is* the notch: pure black, flush with the
// top edge, 10 pt bottom corners, with concave shoulders into the screen edge. When there is something live to show it
// grows "ears" (56 pt; each side wider only for its own content — IslandLayout.earNeed). Both ears grow when both have
// something to say (recording, dictation, a voice note); a standing thing alone is told across the notch as a live
// activity is — its glyph on the left, its value on the right (the cards waiting: stack | 2; captures just landed:
// tray | +3); a moment grows its own side (Peep thinking, an alert, the launch hello). At rest — nothing live — it is the
// bare notch: the inbox's backlog is the menu bar's count and the open island's Inbox row, never a standing number
// beside the notch. A short done state is said in the ears, not a toast: "✓ Sent" after a double tap, "✓ Saved 0:42"
// after a take (earMoment). A screen without a notch (an external display) gets the same island since v1.0.3: a notch
// drawn in its menu bar's row, the built-in notch's width and the menu bar's height (it was a capsule 6 pt under the
// menu bar, hidden when idle; that code is still there behind geo.notch == false). Hovering 180 ms (or a hotkey)
// opens it: 480 wide, as tall as its content (≤ 420), 22 pt corners; it closes 400 ms after the pointer leaves it and
// the hanging cards (HangingCards.swift), which drop after the same rest (CardReveal.dwell, 180 ms: a brush past the
// notch drops nothing). Resting on the cards' count opens the island after 450 ms (the cards are down by then).
//
// Collapsed (ears)        left                         right
//   idle                  cards waiting (n) — a click   Peep thinking + n processing, else an agent that
//                         brings them down to stay      waits on you (the alert dot), else "+n" for a few seconds as
//                                                       new captures land in the inbox; nothing at all otherwise
//   recording             red dot (1 Hz breath) + time  the pen while latched, else snaps (n, the snap frame), else
//                         (paused: pause bars, amber)   markers (n, a flag), else the mic level
//   voice input           Peep listening + the live     duration
//                         wave (open: the mic glyph —
//                         the row has Peep and the wave)
//   dictation             Peep talking (its beak with   clock or style chip (from 4:30 the time left, in attention
//                         your voice) + the level;      amber), dots while working or sending, then "Sent" with the
//                         Peep thinking while it works  ok check for 1.6 s after a double tap (dictationSent)
//   a done moment         Peep's peep and hop           the ok check and the words ("Sent", "Saved 0:42")
// Every ear glyph is the BlurtIcon line family at one weight; Peep is the clay character (Ears.swift).
// Each ear's content sits against the island's outer edge (BlurtCore IslandLayout.earOrigin), never centred in its ear.
// Open: IslandContent.swift (home, recording, voice, the project drawer / switcher, one-line toasts).
// Toasts: BlurtCore ToastQueue — the newest reply first, replaced by key, passive lines (launch, jobs) behind replies,
// stale ones dropped, ≥ 5 s and held while the pointer is on one (hovering a toast doesn't open the island under it;
// a click on its line does, and only its button runs its action — ToastQueue.bodyClick).
// Right-click (on the count, anywhere on it): Show N Hanging Cards · Recently Taken (N) — the cards dragged out into
// other apps in the last 7 days, each with Copy / Copy Image / Copy Note / Put Back (TakenPanel.swift).
//
// Motion: the shape is three springs (width, height, corner) — response 0.42 s, damping 0.78 — so it can be
// interrupted at any point; a bump (1.04 → 1, 0.25 s) when it swallows a capture; Reduce Motion = 0.2 s cross-fades.
// Window: a non-activating panel above the menu bar, on all spaces, never captured (sharingType none, and excluded
// from every recording by process), on the screen with the pointer; mouse-transparent except over the island itself.

import AppKit
import BlurtCore
import QuartzCore

final class IslandPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class IslandView: NSView {
    weak var island: Island?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if island?.key(e) != true { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) { island?.clicked(at: convert(e.locationInWindow, from: nil)) }
    /// Right-click (the ear's count, anywhere on the island): Show Hanging Cards, Recently Taken (N) — TakenPanel.
    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        emit(["event": "island_menu"])
        TakenPanel.islandMenu().popUp(positioning: nil, at: p, in: self)
    }
    /// The left ear's count takes its own clicks, even while the open content grows over it.
    override func hitTest(_ p: NSPoint) -> NSView? {
        if let i = island, i.earHit(convert(p, from: superview)) { return self }
        return super.hitTest(p)
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { island?.dragOver(convert(s.draggingLocation, from: nil)) ?? [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { island?.dragOver(convert(s.draggingLocation, from: nil)) ?? [] }
    override func draggingExited(_ s: NSDraggingInfo?) { _ = island?.dragOver(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        island?.drop(s.draggingPasteboard, at: convert(s.draggingLocation, from: nil)) ?? false
    }
}

final class Island: NSObject, IslandHosting {
    static let earW: CGFloat = 56
    static let openW: CGFloat = 480
    static let maxH: CGFloat = 420
    static let panelSize = CGSize(width: 640, height: 470)

    // MARK: geometry of the current screen (panel coordinates: y down from the screen's top edge)

    struct Geo {
        var notch = false
        var notchW: CGFloat = 0, notchH: CGFloat = 0
        var top: CGFloat = 0           // the island's top edge (0 with a notch, under the menu bar without)
        var row: CGFloat = 30          // height of the ears row
        var cx: CGFloat = 320          // centre x in the panel
    }

    private(set) var screen: NSScreen?
    private var geo = Geo()
    private var panel: IslandPanel?
    private var view: IslandView!
    private let shape = CAShapeLayer()
    private let ears = CALayer()
    private let left = EarSlot(), right = EarSlot()
    let content = IslandContent()
    private let clip = FlippedView()
    private var driver: MotionDriver?
    /// The listening aura (gradient.glow) under the island while dictation or a voice note listens: fades in over
    /// 200 ms (a tap-started dictation's only after the double-tap window: `Dictation.glowOn`) and out when it stops, follows the level — 60–100 % of its strength (no faster than 0.6 s). Never while recording (red
    /// owns that moment) or idle; none with Reduce Transparency; no breathing with Reduce Motion.
    private var glow: CALayer?
    private var glowAmount: CGFloat = 0
    private var glowBreath: CGFloat = 0.5

    private var w = Spring(200, response: 0.42, damping: 0.78)
    private var h = Spring(32, response: 0.42, damping: 0.78)
    private var r = Spring(10, response: 0.42, damping: 0.78)
    /// How far the shape's centre sits right of the notch's: an ear on one side only grows that side (half its width).
    private var dx = Spring(0, response: 0.42, damping: 0.78)
    private var vis = Spring(0, response: 0.3, damping: 1)       // capsule screens: shown or not
    private var bumpStart: CFTimeInterval = 0
    private var shapeMoving = false
    /// The outline last drawn (its path and shadow path are made again only when it changes).
    private var lastOutline: (rect: CGRect, radius: CGFloat, notch: Bool, lifted: Bool)?

    // MARK: state

    enum Drawer: Equatable { case switcher, drop }
    private(set) var drawer: Drawer?
    private var hoverSince: CFTimeInterval?
    private var awaySince: CFTimeInterval?
    private var hotSince: CFTimeInterval?
    private var revealed = false                 // capsule screens: brought out by the hot zone
    private var sticky = false
    private(set) var open = false
    private var confirmingDiscard = false
    private var dragActive = false
    private var dropped = false
    private(set) var cardCount = 0
    private var reviewCount = 0
    private var reviewLoaded = false
    /// New captures landed in the inbox: "+n" in the right ear until then (news, not a standing count).
    private var newsUntil: CFTimeInterval = 0
    private var newsCount = 0
    static let newsSeconds: CFTimeInterval = 4.5
    /// The widest words a done moment says in the ear (≈ "✓ Copied", "✓ 已复制"); longer lines stay toasts.
    static let earMomentMaxText: CGFloat = 96
    /// The toasts (BlurtCore ToastQueue: newest first, replaced by key, stale ones dropped, ≥ 5 s, paused while
    /// pointed at). The one showing is `toastNow`.
    private let toastQ: ToastQueue<Toast> = {
        let q = ToastQueue<Toast>()
        q.floorSeconds = Double(ProcessInfo.processInfo.environment["BLURT_TOAST_MIN_SECONDS"] ?? "") ?? 0   // tests: time to screenshot
        q.onGone = { e in
            emit(["event": "island_toast_gone", "text": e.text])
            e.payload.gone?()
        }
        return q
    }()
    private var toastNow: Toast? { toastQ.current?.payload }
    /// A short done moment in the ears ("✓ Sent" after a double tap, "✓ Saved 0:42"): the source's glyph on the left
    /// (when it has one), the ok check and the words on the right — until then. No toast for a word or two.
    private var momentUntil: CFTimeInterval = 0
    private var moment: (lead: BlurtIcon?, text: String)?
    /// The launch hello (Peep turns to you and blinks in the right ear, then goes): until then.
    private var helloUntil: CFTimeInterval = 0
    /// Tests: dictation's working ears held for a look (`testWorkingEars`).
    private var testWorking: (polishing: Bool, until: CFTimeInterval)?
    private var hatches: [Hatch] = []
    /// Captures are being organised (Peep thinks in the ear and in the menu bar).
    var organizing: Bool { hatches.contains { $0.ended == nil } }
    private var lastAgentAlert: [String: String] = [:]
    private(set) var started = false
    var watch: RecordingWatch?

    struct Toast {
        var text: String
        var actionTitle: String?
        var action: (() -> Void)?
        var art: NSView?
        /// How long it shows: at least 5 s whatever is asked (ToastQueue.minSeconds), and it waits while pointed at.
        var seconds: Double = 5
        /// Shown at once, also over the open island (an Undo for something just done on the cards under it); other
        /// toasts wait until the island closes.
        var overOpen = false
        /// What the toast is about ("Deleted · Undo"): a toast with the same key takes its place — its text and its
        /// action — instead of being dropped as a repeat, so a second delete's Undo is never lost behind the first's.
        var key: String?
        /// A project's key badge before the text ("Filed to …").
        var badge: (text: String, color: NSColor)?
        /// A small icon before the text: `.check` for a done toast (Saved, Copied), in the island's ok green (§2.3).
        var icon: BlurtIcon?
        /// A small mark before the detail line (the text after its "\n"): a peck's state — the ✓ for done, the ⚠
        /// for to verify, the same marks a toast leads with — in shape and colour.
        var detailMark: (icon: BlurtIcon, color: NSColor)?
        /// Not a reply to what the user just did (a launch message, a job that finished, a reminder): it waits behind
        /// every reply instead of taking the slot (ToastQueue).
        var passive = false
        /// It went without being acted on (expired, replaced, superseded, stale, dropped — ToastQueue.onGone): the
        /// main window's page toast answers its page "gone" here, so the page never waits on an Undo that's gone.
        var gone: (() -> Void)?
        /// A question: the text wraps, two answers under it (also over the open island). `action` is the first
        /// answer. It goes after its `seconds` like any toast (going is its "no": `gone`); only `.infinity` (Island.ask,
        /// the kept text) waits until one is chosen.
        var secondTitle: String?
        var second: (() -> Void)?
        /// A question's quoted text, under it in the quiet colour (the dictated text the island keeps)
        var quote: String?
        /// Called each time it goes up on the island (a line explained "the first couple of times" counts a showing,
        /// not a post that waited and went stale unseen).
        var onShown: (() -> Void)?
        var isQuestion: Bool { secondTitle != nil }

        init(text: String, actionTitle: String?, action: (() -> Void)?) {
            self.text = text
            self.actionTitle = actionTitle
            self.action = action
        }
    }

    /// A question in the island that stays until answered (two answers, the first is the suggested one).
    func ask(_ text: String, _ first: String, _ a: @escaping () -> Void, _ second: String, _ b: @escaping () -> Void) {
        var t = Toast(text: text, actionTitle: first, action: a)
        t.secondTitle = second
        t.second = b
        t.seconds = .infinity
        toast(t)
    }

    final class Hatch {
        let session: URL
        var captures: [Int]
        var job: String?
        let since = CACurrentMediaTime()
        let born = Date()
        var ended: (at: CFTimeInterval, ok: Bool, items: Int)?
        init(session: URL, captures: [Int]) { self.session = session; self.captures = captures }
    }

    var isRecording: Bool { rec.map { !$0.stopping } ?? false }
    var rec: Recorder? { (NSApp.delegate as? App)?.rec }

    /// The island as it is drawn now, in screen coordinates.
    var frameOnScreen: NSRect {
        guard let p = panel else {
            let s = NSScreen.main?.frame ?? .zero
            return NSRect(x: s.midX - 100, y: s.maxY - 32, width: 200, height: 32)
        }
        return NSRect(x: p.frame.minX + shapeMinX, y: p.frame.maxY - geo.top - h.value, width: w.value, height: h.value)
    }

    /// The shape's corner radius now (the hanging cards' lip joins its bottom corners).
    var cornerRadiusNow: CGFloat { r.value }

    /// The pointer is on the island (the hanging cards stay down meanwhile).
    var pointerInside: Bool { hoverSince != nil }
    /// …and has rested there CardReveal.dwell: the cards come down (brushing past the notch drops nothing).
    var pointerDwelled: Bool { CardReveal.dwelled(since: hoverSince, now: CACurrentMediaTime()) }
    private var cardsCalled = false
    /// The cards stay down whatever the pointer does: the island is open by a key or a command (until the pointer has
    /// come and gone), a drawer is open, or a card is being dragged.
    var holdsCards: Bool { (open && sticky) || dragActive || drawer != nil }

    /// The ear holding the hanging cards' count (their stack and the number together), where it is drawn now (panel
    /// coordinates): the left ear, or the right one while Peep or its news holds the left — nil when it isn't showing
    /// (no cards, recording, voice input, or the open island's content has taken the ears row).
    private var cardsEarRect: CGRect? {
        guard cardCount > 0, !isRecording, !VoiceInput.shared.active, ears.opacity > 0.3 else { return nil }
        if case .cards = left.content, left.layer.opacity > 0.5 {
            if geo.notch { return CGRect(x: geo.cx - geo.notchW / 2 - earNeed.left, y: geo.top, width: earNeed.left, height: geo.row) }
            return CGRect(x: shapeMinX, y: geo.top, width: left.width + 28, height: geo.row)
        }
        if case .cards = right.content, right.layer.opacity > 0.5 {
            if geo.notch { return CGRect(x: geo.cx + geo.notchW / 2, y: geo.top, width: earNeed.right, height: geo.row) }
            return CGRect(x: shapeMinX + w.value - right.width - 28, y: geo.top, width: right.width + 28, height: geo.row)
        }
        return nil
    }

    /// The right ear while a voice note listens (its clock, with the list mark while Structured): a click toggles
    /// Structured, as a click on the island does for dictation.
    private var rightEarRect: CGRect? {
        guard VoiceInput.shared.active, right.layer.opacity > 0.5, ears.opacity > 0.3 else { return nil }
        if geo.notch { return CGRect(x: geo.cx + geo.notchW / 2, y: geo.top, width: earNeed.right, height: geo.row) }
        return CGRect(x: shapeMinX + w.value - right.width - 28, y: geo.top, width: right.width + 28, height: geo.row)
    }

    /// A click there goes to the island itself (not to the open content growing over it): see clicked(at:).
    func earHit(_ p: NSPoint) -> Bool {
        (cardsEarRect?.contains(p) ?? false) || (rightEarRect?.contains(p) ?? false)
    }

    // MARK: setup

    func start() {
        guard !started else { return }
        started = true
        ensurePanel(on: screenWithPointer())
        JobStore.shared.start()
        // JobNotifier owns JobStore.onChange (the one listener) and re-posts every change; setting onChange here was
        // overwritten by it, so the ear never learned its job ended (it went on until the 120 s timeout)
        NotificationCenter.default.addObserver(forName: .blurtJobsChanged, object: nil, queue: .main) { [weak self] n in
            self?.jobsChanged(n.userInfo?["jobs"] as? [Job] ?? [])
        }
        ProjectStore.shared.onChange = { [weak self] in self?.refresh() }
        refreshReviewCount()
        // often enough that captures landing are news while they are new ("+3" in the ear)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshReviewCount() }
        // a click anywhere else closes the open island (its projects, the switcher): it no longer stays down over
        // the app the user went back to (v1.0.4 report). Global: a click in another app; local: another Blurt window.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.clickedElsewhere() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, e.window !== self.panel { self.clickedElsewhere() }
            return e
        }
        refresh()
        // blurt is running: a short hello in the ear once the panel is up (Alcove and NotchNook say hello too)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.hello() }
    }

    /// Tests: one of Peep's ear states held `seconds` for a look, without a microphone, a take or a job — talking
    /// (dictation, a made-up voice), listening (a voice note), thinking (organising 3), done (sorted: +5), error (sorting
    /// failed). `nil` ends it.
    func testPeepEars(_ state: PeepState?, seconds: Double) {
        testPeep = state.map { ($0, CACurrentMediaTime(), CACurrentMediaTime() + seconds) }
        if state == .hello { testPeep = nil; toastQ.dismissCurrent(); hello() }
        emit(["event": "island_test_peep", "state": state?.rawValue ?? NSNull()])
        refresh()
    }
    private var testPeep: (state: PeepState, since: CFTimeInterval, until: CFTimeInterval)?

    /// Peep's own moments across the notch: Peep left, its words or count right ("Blurt is ready", "3", "+5", "Not
    /// sorted"). False for anything else.
    private func peepAcross(_ r: EarSlot.Content) -> Bool {
        switch r {
        case .hello:
            left.set(.hello)
            right.set(.text(Loc.t("capture.island.hello", table: "Capture"), mono: false))
        case .thinking(let n):
            left.set(.peep(.thinking))
            right.set(.text(Loc.number(n), mono: true))
        case .sorted(let since, let ok, let n):
            left.set(.sorted(since: since, ok: ok, n: 0))
            right.set(.text(ok ? "+" + Loc.number(n) : Loc.t("capture.island.sort_failed", table: "Capture"), mono: ok,
                            attn: !ok))
        default: return false
        }
        return true
    }
    /// A made-up voice for the test states: words about every 0.3 s, louder and softer.
    static func testVoice(_ t: Double) -> Float {
        Float(max(0, 0.55 * sin(t * 11) + 0.35 * sin(t * 2.7 + 1) + 0.1))
    }

    /// Tests: dictation's working ears — Peep thinking and the dots — held `seconds` for a look: on a fast Mac a take's
    /// working moment lasts a tenth of a second.
    func testWorkingEars(polishing: Bool, seconds: Double) {
        testWorking = (polishing, CACurrentMediaTime() + seconds)
        refresh()
    }

    /// The launch hello: Peep turns to you and blinks in the right ear (the hello clip), then goes — the one sign at launch that blurt is
    /// there (the island is the bare notch at rest). Not over something live.
    func hello() {
        guard !isRecording, !VoiceInput.shared.active, !Dictation.shared.busy, toastNow == nil, !open, drawer == nil else { return }
        helloUntil = CACurrentMediaTime() + EarSlot.helloSeconds
        emit(["event": "island_hello", "wall": Date().timeIntervalSince1970])
        refresh()
    }

    var screenUnderPointer: NSScreen { screenWithPointer() }
    func moveTo(_ s: NSScreen) { if s != screen { ensurePanel(on: s) } }
    func clearToast() { toastQ.dismissCurrent() }

    private func screenWithPointer() -> NSScreen { pointerScreen() ?? NSScreen.main ?? NSScreen.screens[0] }

    /// The screen under the pointer. Scripted visual checks (test commands only) can pin the island instead:
    /// BLURT_ISLAND_SCREEN=notch → the screen with a notch (else the first), =plain → one without (else the first),
    /// whatever the pointer does.
    private static let pinnedScreen: String? = {
        let env = ProcessInfo.processInfo.environment
        guard env["BLURT_TEST_COMMANDS"] == "1", let s = env["BLURT_ISLAND_SCREEN"], ["notch", "plain"].contains(s) else { return nil }
        return s
    }()
    private func pointerScreen() -> NSScreen? {
        if let pin = Island.pinnedScreen {
            if #available(macOS 12.0, *), let n = NSScreen.screens.first(where: { ($0.safeAreaInsets.top > 0) == (pin == "notch") }) { return n }
            return NSScreen.screens.first
        }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
    }

    /// Scripted pointer tests (test commands only): BLURT_ISLAND_DX=-560 draws the island that far left of the screen's
    /// middle (same shape), so a test's pointer never touches another Blurt's island at the notch.
    static let testOffset: CGFloat = {
        let env = ProcessInfo.processInfo.environment
        guard env["BLURT_TEST_COMMANDS"] == "1", let dx = env["BLURT_ISLAND_DX"].flatMap(Double.init) else { return 0 }
        return CGFloat(dx)
    }()

    /// Visual checks (test commands only): BLURT_ISLAND_NOTCH=0 draws it as on a screen without a notch.
    static let testNoNotch: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_ISLAND_NOTCH"] == "0"
    }()

    /// The built-in screen's notch width, which a screen without a notch borrows (185 pt, a 14" MacBook Pro's, when no
    /// screen has one).
    static var builtInNotchWidth: CGFloat {
        if #available(macOS 12.0, *), let n = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let l = n.auxiliaryTopLeftArea, let r = n.auxiliaryTopRightArea {
            return n.frame.width - l.width - r.width
        }
        return 185
    }

    private func ensurePanel(on s: NSScreen) {
        var g = Geo()
        let menuH = max(s.frame.maxY - s.visibleFrame.maxY, 24)
        if #available(macOS 12.0, *), !Island.testNoNotch, s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea,
           let r = s.auxiliaryTopRightArea {
            g.notch = true
            g.notchW = s.frame.width - l.width - r.width
            g.notchH = s.safeAreaInsets.top
            g.top = 0
            g.row = g.notchH
            g.cx = Island.panelSize.width / 2 + ((l.maxX + r.minX) / 2 - s.frame.midX)
        } else {
            // a screen without one (an external display): the same island, drawn as a notch in its menu bar's row — as
            // wide as the built-in screen's notch, as tall as this menu bar
            g.notch = true
            g.notchW = Island.builtInNotchWidth
            g.notchH = menuH
            g.top = 0
            g.row = g.notchH
            g.cx = Island.panelSize.width / 2
        }
        let f = NSRect(x: s.frame.midX - Island.panelSize.width / 2 + Island.testOffset, y: s.frame.maxY - Island.panelSize.height,
                       width: Island.panelSize.width, height: Island.panelSize.height)
        if panel == nil {
            let p = IslandPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true          // (before the level: it resets the level to .floating)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = chromeSharing
            p.setAccessibilityTitle(Loc.t("capture.island.ax", table: "Capture"))
            let v = IslandView(frame: NSRect(origin: .zero, size: f.size))
            v.island = self
            v.wantsLayer = true
            v.registerForDraggedTypes([capturePasteboardType])
            p.contentView = v
            view = v
            panel = p
            build()
            let d = MotionDriver(view: v)
            d.tick = { [weak self] dt in self?.frame(dt) ?? false }
            // at rest the poll (pointer, hover) also keeps a resting toast's clock: a toast that just sits there needs no
            // frames; the next one (or none) wakes the shape
            d.idle = { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.poll(now)
                guard self.toastNow != nil || !self.toastQ.waiting.isEmpty else { return }
                let before = self.toastQ.current?.order
                self.tickToasts(now)
                self.content.tick(now)
                if self.toastQ.current?.order != before { self.wake() }
            }
            d.idleRate = 1.0 / 15
            driver = d
            // Peep in the ear pauses while the panel can't be seen (another space's full-screen app, a sleeping screen)
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main) { [weak self] _ in
                self?.earsSeen()
            }
        }
        let moved = screen != s
        screen = s
        geo = g
        panel?.setFrame(f, display: false)
        view.frame = NSRect(origin: .zero, size: f.size)
        if moved {
            let t = target()
            w.value = t.w; h.value = t.h; r.value = t.r; dx.value = t.dx
            w.snap(); h.snap(); r.snap(); dx.snap()
        }
        panel?.orderFrontRegardless()
        wake()
    }

    private func build() {
        guard let root = view.layer else { return }
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 8                 // flat (BA-8): enough to part the open island from the page under it
        shape.shadowOffset = CGSize(width: 0, height: 3)
        if let g = GlowLayer.make(size: CGSize(width: 240, height: 26), blur: 18) {     // under the shape: its lower part shows
            g.opacity = 0
            root.addSublayer(g)
            glow = g
        }
        root.addSublayer(shape)
        ears.addSublayer(left.layer)
        ears.addSublayer(right.layer)
        root.addSublayer(ears)
        content.island = self
        content.wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.alphaValue = 0
        clip.addSubview(content)
        view.addSubview(clip)
    }

    func orderFront() { panel?.orderFrontRegardless() }

    /// The ears row (the notch's height, or the capsule's) and the notch's width in it (0 without a notch).
    var rowHeight: CGFloat { geo.row }
    var notchGap: CGFloat { geo.notch ? geo.notchW : 0 }

    // MARK: what the island should look like now

    /// Only what is live: recording, listening, the cards waiting, processing, an agent waiting on you, captures that
    /// just landed. The inbox's backlog is not live — it is the menu bar's count and the open island's Inbox row.
    private var earsWanted: (left: Bool, right: Bool) {
        if isRecording || VoiceInput.shared.active || Dictation.shared.busy || Dictation.shared.sendQueued { return (true, true) }
        if let tw = testWorking, CACurrentMediaTime() < tw.until { return (true, true) }
        // what updateEars put there: a standing thing alone already takes both sides (glyph | value)
        return (left.content != .none, right.content != .none)
    }

    /// Each ear's width beside the notch: its own content's need, 0 when it says nothing (IslandLayout.earNeed).
    private var earNeed: (left: CGFloat, right: CGFloat) {
        let e = earsWanted
        return (IslandLayout.earNeed(content: left.width, shown: e.left), IslandLayout.earNeed(content: right.width, shown: e.right))
    }

    /// "+n" in the right ear: captures landed in the inbox in the last few seconds.
    private var inboxNews: Bool { newsCount > 0 && CACurrentMediaTime() < newsUntil }

    /// The shape's left edge in the panel (its centre is the notch's, moved by `dx` while one ear shows).
    private var shapeMinX: CGFloat { geo.cx + dx.value - w.value / 2 }

    /// The shape's target: (width, height, corner radius, centre offset). `toast`: false — what it would be without
    /// the toast showing (the live-text panel's width goes by that).
    private func target(toast: Bool = true) -> (w: CGFloat, h: CGFloat, r: CGFloat, dx: CGFloat) {
        let e = earsWanted
        let anyEar = e.left || e.right
        if open || drawer != nil {
            return (content.preferredWidth, min(Island.maxH, content.fittingHeight), 22, 0)
        }
        if toast, toastNow != nil {
            return (min(Island.openW, max(toastFloor, content.toastWidth)), content.fittingHeight, 20, 0)
        }
        if geo.notch {
            // each side as wide as its own content: "✓ Sent" widens the right ear only; a moment on one side grows that side
            let n = earNeed
            return (geo.notchW + n.left + n.right, geo.notchH, 10, IslandLayout.earShift(left: n.left, right: n.right))
        }
        var cw = max(120, (e.left ? left.width + 24 : 0) + (e.right ? right.width + 24 : 0) + (anyEar ? 8 : 0))
        // live text hangs under it: the capsule takes the panel's width family (as the notch with its ears does), so
        // the two read as one shape, not a 340 pt panel under a 120 pt pill
        if anyEar, LiveTranscript.shared.shown { cw = max(cw, IslandLayout.liveCapsuleWidth()) }
        return (anyEar || revealed ? max(cw, revealed && !anyEar ? 150 : 0) : 120, 30, 15, 0)
    }

    /// A toast's shape is never narrower than this: the notch with both ears, or the capsule's minimum — and its
    /// content spans all of it (IslandLayout.toast), so the text lines up with the island's edges.
    var toastFloor: CGFloat { IslandLayout.toastFloor(notchWidth: geo.notch ? geo.notchW : nil) }

    /// The width the island is settling to (not the spring's value now), as it is without a toast: the live-text
    /// panel goes by it, so its words don't re-wrap while the shape springs — nor when a toast (⇧'s style, "nothing
    /// heard") grows the island for a few seconds during a take.
    var restingWidth: CGFloat { target(toast: false).w }
    /// The island has a notch (its live panel's corners follow: 14 under the notch, 15 under the capsule).
    var onNotch: Bool { geo.notch }

    private var capsuleVisible: Bool {
        geo.notch || open || drawer != nil || toastNow != nil || revealed || earsWanted.left || earsWanted.right
    }

    func refresh() {
        updateEars()
        content.rebuild()
        wake()
    }

    func wake() { driver?.wake() }

    // MARK: animation

    private func frame(_ dt: CGFloat) -> Bool {
        let now = CACurrentMediaTime()
        poll(now)
        tickToasts(now)
        if isRecording || VoiceInput.shared.active || Dictation.shared.busy || dictationMoment || momentUntil > 0 {
            updateEars()        // the time, the level, the wave; the end of a done moment
        }
        if let tw = testWorking { if now < tw.until { updateEars() } else { testWorking = nil; updateEars() } }
        if let tp = testPeep { if now < tp.until { updateEars() } else { testPeep = nil; updateEars() } }
        if helloUntil > 0, now >= helloUntil {                                     // the hello is over: the bare notch
            helloUntil = 0
            updateEars()
            emit(["event": "island_hello_end", "wall": Date().timeIntervalSince1970])
        }
        if newsUntil > 0, now >= newsUntil { newsUntil = 0; newsCount = 0; updateEars() }    // the news is old: the ear goes
        let t = target()
        w.target = t.w; h.target = t.h; r.target = t.r; dx.target = t.dx
        vis.target = capsuleVisible ? 1 : 0
        let reduce = reduceMotion
        if reduce {
            w.snap(); h.snap(); r.snap(); dx.snap()
            vis.value += (vis.target - vis.value) * min(1, dt / 0.2 * 1.2)
        } else {
            _ = w.step(dt); _ = h.step(dt); _ = r.step(dt); _ = dx.step(dt); _ = vis.step(dt)
        }
        let bt = now - bumpStart
        let bump: CGFloat = reduce || bt > 0.25 ? 1 : 1 + 0.04 * (1 - Ease.outCubic(CGFloat(bt / 0.25)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(x: shapeMinX, y: geo.top, width: w.value, height: max(1, h.value))
        let lifted = h.value > geo.row + 8
        // set only what changed: a new path (and a shadow along it, so the shadow isn't found from the pixels) only
        // when the outline moves
        let outline = (rect: rect, radius: r.value, notch: geo.notch, lifted: lifted)
        if lastOutline.map({ $0 != outline }) ?? true {
            lastOutline = outline
            let p = Island.path(rect, radius: r.value, shoulders: geo.notch)
            shape.path = p
            shape.shadowPath = lifted ? p : nil
        }
        let opacity = Float(max(0, min(1, vis.value)))
        if shape.opacity != opacity { shape.opacity = opacity }
        let shadow: Float = lifted ? Float(min(0.2, (h.value - geo.row) / 200)) : 0
        if shape.shadowOpacity != shadow { shape.shadowOpacity = shadow }
        if bump != 1 {
            let c = CGPoint(x: rect.midX, y: geo.top + h.value / 2)
            var tr = CATransform3DMakeTranslation(c.x, c.y, 0)
            tr = CATransform3DScale(tr, bump, bump, 1)
            tr = CATransform3DTranslate(tr, -c.x, -c.y, 0)
            shape.transform = tr
            ears.transform = tr
        } else {
            shape.transform = CATransform3DIdentity
            ears.transform = CATransform3DIdentity
        }
        layoutEars(rect, now: now)
        updateGlow(dt, under: rect)
        // the open content: from the top of the shape (home and the drawer use the ears row, beside the notch),
        // revealed as it grows, clipped to it — only the bottom corners round
        let cw = content.preferredWidth
        let clipFrame = NSRect(x: rect.minX, y: geo.top, width: rect.width, height: rect.height)
        if clip.frame != clipFrame { clip.frame = clipFrame }
        let corner = min(r.value, rect.height / 2)
        let corners: CACornerMask = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        if let l = clip.layer, l.cornerRadius != corner || l.maskedCorners != corners {
            l.cornerRadius = corner
            l.maskedCorners = corners
        }
        // home grows from its left edge: Peep and the project lead it out as the shape widens (the right side's buttons
        // are uncovered as it reaches them), so a Peep riding over from the ear never sits on the name
        var cx0 = geo.cx - cw / 2 - rect.minX
        if content.usesRow, drawer == nil, toastNow == nil, !isRecording { cx0 = max(cx0, 0) }
        let contentFrame = NSRect(x: cx0, y: 0, width: cw, height: Island.maxH)
        if content.frame != contentFrame { content.frame = contentFrame }
        let grown = (h.value - geo.row) / max(1, content.fittingHeight - geo.row)
        let showing = open || drawer != nil || toastNow != nil
        let reveal = showing ? max(0, min(1, (grown - 0.55) / 0.35)) : 0
        clip.alphaValue = reveal * CGFloat(shape.opacity)
        // the content under a 0 alpha (closed, or a live take's ears) is hidden, not just faded: the accessibility tree
        // flattens the clip away, so VoiceOver and layoutcheck found home's Snap / Voice note / Inbox there, laid out at
        // the open width past the closed shape — outside the panel
        let unseen = clip.alphaValue <= 0.01
        if content.isHidden != unseen { content.isHidden = unseen }
        // the ears make way for the open content when it uses their row — but a riding Peep is handed over, not faded
        let riding = showing ? peepRide : nil
        content.contentSeen(!unseen, peepHeld: riding == false)
        ears.opacity = shape.opacity * Float(content.usesRow && showing && riding == nil ? 1 - reveal : 1)
        if let arrived = riding {
            if left.layer.opacity > 0 { left.layer.opacity = arrived ? 0 : 1 }
            right.layer.opacity *= Float(1 - reveal)
        }
        CATransaction.commit()
        content.tick(now)
        hanging.islandMoved()
        LiveTranscript.shared.islandMoved()
        let moving = !w.resting || !h.resting || !r.resting || !dx.resting || abs(vis.value - vis.target) > 0.01 || bt < 0.3
        // While the shape grows, AppKit draws the open content piece by piece as the clip uncovers it; the seams of
        // those pieces show through translucent fills (the Let AI sort and Finish pills). Once it rests: whole again.
        if shapeMoving && !moving { content.redrawAll() }
        shapeMoving = moving
        // the shape's springs and a fading glow at the display's rate; the ears (dots, level, clock: the mic's levels
        // come 20 times a second, Peep's frames 30) at 30 Hz. A resting toast needs no frames (the idle poll keeps its
        // clock), and with nothing at all to move the link stops.
        let small = left.animating || right.animating || isRecording
            || VoiceInput.shared.active || Dictation.shared.busy || dictationMoment || momentUntil > 0 || glowAmount > 0 || newsUntil > 0
            || helloUntil > 0 || testWorking != nil || testPeep != nil
        driver?.maxFPS = moving || (glowAmount > 0 && glowAmount < 1) ? 120 : 30
        return moving || small
    }

    /// Dictation or a voice note hears you (not while the mic is still starting, not while recording).
    private var listening: Bool {
        !isRecording && (VoiceInput.shared.active || Dictation.shared.glowOn)
    }

    /// The listening aura: centred on the island's bottom edge (inside a transaction without actions).
    private func updateGlow(_ dt: CGFloat, under rect: CGRect) {
        guard let g = glow else { return }
        let on = listening && !reduceTransparency
        let step = dt / CGFloat(BrandGradient.glowFadeIn)
        glowAmount = on ? min(1, glowAmount + step) : max(0, glowAmount - step)
        if reduceMotion {
            glowBreath = 0.5
        } else {
            let lvl = CGFloat((VoiceInput.shared.active ? VoiceInput.shared.levels.last : Dictation.shared.levels.last) ?? 0)
            glowBreath += (min(1, max(0, lvl)) - glowBreath) * min(1, dt / 0.6)
        }
        // it follows the voice (quieter in a pause), so it says "heard", not "on"
        let opacity = glowAmount * BrandGradient.glowOpacity * (0.6 + 0.4 * glowBreath)
        g.opacity = Float(opacity) * shape.opacity
        guard glowAmount > 0 else { return }
        let pad: CGFloat = 18 * 4
        g.bounds = CGRect(x: 0, y: 0, width: rect.width * 0.8 + pad, height: 22 + pad)
        g.position = CGPoint(x: rect.midX, y: rect.maxY + 4)
    }

    /// The island's outline: flush top (with small concave shoulders on a notch screen), rounded bottom corners;
    /// a capsule / rounded rect without a notch.
    static func path(_ r: CGRect, radius: CGFloat, shoulders: Bool) -> CGPath {
        let p = CGMutablePath()
        let rad = min(radius, r.height / 2, r.width / 2)
        guard shoulders else {
            p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            return p
        }
        let s: CGFloat = min(6, r.height / 3)
        p.move(to: CGPoint(x: r.minX - s, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + s), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - rad), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX + s, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }

    // MARK: ears

    /// Peep is in the left ear, where it can be seen.
    private var earShowsPeep: Bool {
        guard panel?.isVisible == true, capsuleVisible else { return false }
        switch left.content {
        case .hello, .peep, .peepLevel, .thinking, .sorted: return true
        default: return false
        }
    }

    /// Peep in the left ear while the island opens on its home (or closes from it): it rides the shape's left edge out
    /// to where the open island's Peep stands — and back — and hands over there: the open island's Peep shows only
    /// once the ear's has arrived, so it is one Peep moving, never two at once. (The ear's Peep is drawn 2 pt before
    /// its slot's leading x.)
    private func peepRidesEdge(_ x: CGFloat, _ rect: CGRect) -> CGFloat {
        peepRide = nil
        guard open || h.value > geo.row + 1, drawer == nil, toastNow == nil, !isRecording, content.usesRow else { return x }
        switch left.content {
        case .hello, .peep, .thinking, .sorted: break
        default: return x
        }
        let home = geo.cx - content.preferredWidth / 2 + IslandLayout.iconColumn - 12 + 2
        let at = max(home, min(x, rect.minX + IslandLayout.iconColumn - 12 + 2))
        peepRide = abs(at - home) < 1
        return at
    }

    /// While the ear's Peep rides to the open island's (peepRidesEdge): whether it has arrived; nil when it isn't riding.
    private var peepRide: Bool?

    /// What the open island's Peep does: thinking while the left ear's Peep thinks (captures organised, a take
    /// transcribed), else idle — the ear's one-off clips (the hello, a done hop) are the ear's alone.
    var earPeepMood: PeepState {
        switch left.content {
        case .thinking, .peep(.thinking): return .thinking
        default: return .idle
        }
    }

    /// Peep in an ear pauses while the island can't be seen (its panel covered or off, the capsule gone).
    private func earsSeen() {
        let unseen = !(panel?.occlusionState.contains(.visible) ?? false) || !capsuleVisible
        for slot in [left, right] {
            for case let m as MascotLayer in slot.layer.sublayers ?? [] where m.unseen != unseen { m.unseen = unseen }
        }
    }

    private var agentAlert: Job? {
        JobStore.shared.active.first { $0.type == .agent && $0.agent?.status == .waitingInput }
    }

    func updateEars() {
        defer {
            // the menu-bar Peep reads the same state (talking, listening, thinking); it holds still while Peep is here
            MenuGlyph.shared.held = earShowsPeep
            MenuGlyph.shared.sync()
            earsSeen()
        }
        if let done = RecordingDone.text {
            // the take just ended: the dot and time turn into the ok check and its length for 1.6 s (IslandRecording)
            left.set(.finished(done))
            right.set(.none)
        } else if let rec = rec, rec.sessionStart.isValid {
            left.set(.recording(paused: rec.isPaused, time: Island.clock(rec.elapsed())))
            // the stills taken (⌥A, the island's button) — a marker (⌥M) is its own count, with a flag
            // while the pen is latched (⌥D) it takes the clicks and Esc — or its key is held — the ear shows the pen
            let snaps = rec.snaps?.stills ?? 0, markers = rec.snaps?.markers ?? 0
            right.set(rec.penSticky || rec.inkOn ? .glyph(.pencil, pulse: false, lit: true) : snaps > 0 ? .count(icon: .snap, n: snaps, tint: nil)
                : markers > 0 ? .count(icon: .flag, n: markers, tint: nil) : rec.isPaused ? .none : .level(rec.micLevel))
        } else if VoiceInput.shared.active {
            // one live meter at a time: the open island has the big waveform, so the ear shows the mic there
            // Peep listens (eye wide, swelling) with the wave beside it; open, the row under the ears has both
            left.set(open ? .glyph(.mic, pulse: false) : .peepLevel(.listening, VoiceInput.shared.levels))
            // the clock alone: Structured is the open island's chip (one mint thing), never a second mark here; a click
            // on the clock still toggles it (clicked(at:)). For the note's first seconds, how it ends instead ("⌥V to
            // finish"): closed, the ears showed only Peep, the wave and 0:02, and a first-time user had no way out
            let v = VoiceInput.shared
            right.set(!open && v.elapsed < Island.voiceHintSeconds ? .text(IslandContent.voiceEndHint(), mono: false)
                                                                   : .text(Island.clock(v.elapsed), mono: true))
        } else if Dictation.shared.busy {
            // dictation never opens the island: ears only, so the app being typed into keeps the whole screen
            switch Dictation.shared.phase {
            case .listening where !Dictation.shared.micLive:
                // the mic is still starting (a Bluetooth headset takes ~1 s): Peep waits, not talking until audio
                // arrives, so the user knows when to start
                left.set(.peep(.idle))
                right.set(.dots)
            case .listening:
                // Peep talks: its beak follows your voice, the mirrored level beside it
                left.set(.peepLevel(.talking, Dictation.shared.levels))
                // the style chip: a list glyph while Structured, quotes while Verbatim, nothing for light (the default);
                // the translate glyph after it while the take is translated (docs/design/dictation-translate.md)
                // from 4:30 the time left before the 5-minute limit, in attention amber (not only a minus sign)
                let clock = Dictation.shared.earClock, ending = Dictation.shared.earCountdown
                let mark: BlurtIcon? = Dictation.shared.listeningStyle == .structured ? .list
                    : Dictation.shared.listeningStyle == .verbatim ? .quote : nil
                switch (mark, Dictation.shared.listeningTranslate) {
                case let (m?, true): right.set(.iconsText(m, .languages, clock, attn: ending))
                case let (m?, false): right.set(.iconText(m, clock, attn: ending))
                case (nil, true): right.set(.iconText(.languages, clock, attn: ending))
                case (nil, false): right.set(.text(clock, mono: true, attn: ending))
                }
            default:
                // transcribing, polishing: Peep thinks (its eye looks round)
                left.set(.peep(.thinking))
                right.set(.dots)
            }
        } else if let tp = testPeep, CACurrentMediaTime() < tp.until {
            let t = CACurrentMediaTime() - tp.since
            let voice = (0..<12).map { Island.testVoice(t - Double(11 - $0) * 0.05) }
            switch tp.state {
            case .talking: left.set(.peepLevel(.talking, voice)); right.set(.text(Island.clock(t + 4), mono: true))
            case .listening: left.set(.peepLevel(.listening, voice)); right.set(.text(Island.clock(t + 2), mono: true))
            case .thinking: _ = peepAcross(.thinking(n: 3))
            case .done: _ = peepAcross(.sorted(since: tp.since, ok: true, n: 5))
            case .error: _ = peepAcross(.sorted(since: tp.since, ok: false, n: 0))
            case .idle, .hello: left.set(.peep(tp.state)); right.set(.none)
            }
        } else if let tw = testWorking, CACurrentMediaTime() < tw.until, tw.until > 0 {
            left.set(.peep(.thinking))
            right.set(.dots)
        } else if Dictation.shared.sendQueued {
            // a double tap's Return waits for the paste to land (~0.6 s): sending, not idle
            left.set(.peep(.thinking))
            right.set(.dots)
        } else if let m = moment, CACurrentMediaTime() < momentUntil {
            // a done moment says itself where the user is looking, without growing the island into a toast: Peep's
            // peep and hop on the left, the ok check and the words on the right
            left.set(.peep(.done))
            right.set(.done(m.text))
        } else {
            moment = nil
            momentUntil = 0
            let processing = hatches.filter { $0.ended == nil }.reduce(0) { $0 + max(1, $1.captures.count) }
            var r: EarSlot.Content = .none
            if CACurrentMediaTime() < helloUntil {
                r = .hello
            } else if let h = hatches.first(where: { $0.ended != nil }), let end = h.ended {
                r = .sorted(since: end.at, ok: end.ok, n: end.items)
            } else if processing > 0 {
                r = .thinking(n: processing)
            } else if agentAlert != nil {
                r = .alert
            } else if inboxNews {
                // news, not a backlog: what just landed, for a few seconds — the count lives in the menu bar and the
                // open island's Inbox row
                r = .news(newsCount)
            }
            // the cards' count is one thing — their stack and the number together, never the stack on one side of
            // the notch and a bare "5" on the other. Peep and its news keep the left ear (where Peep talks and
            // listens): the count sits left when nothing else is there, else on the right
            if cardCount > 0 {
                switch r {
                case .none:
                    left.set(.cards(cardCount))
                    right.set(.none)
                default:            // Peep thinking and its count, its hop and "+n", the hello, the inbox's news
                    left.set(r)
                    right.set(.cards(cardCount))
                }
            } else if case .news(let n) = r {
                // a standing thing alone is told across the notch, as a live activity: its glyph left, its value
                // right — never one black slab hanging off one side of the notch
                left.set(.mark(.inbox))
                right.set(.text("+" + Loc.number(n), mono: true))
            } else if peepAcross(r) {
                // Peep's moments are told across the notch too: Peep on the left (where it talks and listens), the
                // words or the count on the right — it never jumps from one side to the other between states
            } else {
                left.set(.none)
                right.set(r)
            }
        }
    }

    /// Each ear's content against the island's outer edge (IslandLayout.earOrigin): a glyph keeps one leading x and a
    /// number one trailing x through every state, instead of each width being centred in its ear.
    private func layoutEars(_ rect: CGRect, now: CFTimeInterval) {
        let y = geo.top + geo.row / 2
        // a toast during a live take (dictation, a voice note) widens the island under the ears: they ride out to its
        // corners as the open recording island's do, instead of floating mid-island beside a 480 pt line
        let liveToast = !open && toastNow != nil && h.value > geo.row + 4 && (Dictation.shared.busy || VoiceInput.shared.active)
        if isRecording && (open || h.value > geo.row + 4) || liveToast {
            // the recording island open (and while it opens or closes): the ears ride the shape's edges, 14 pt in, so
            // the time stands over the pause circle and the right ear's glyph over Finish — one grid, as an expanded
            // Live Activity lines its regions up under the compact ears
            left.place(leading: CGPoint(x: rect.minX + IslandLayout.earInset, y: y), now: now)
            right.place(trailing: CGPoint(x: rect.maxX - IslandLayout.earInset, y: y), now: now)
        } else if geo.notch {
            let l = geo.cx - geo.notchW / 2, r = geo.cx + geo.notchW / 2
            // the outer edge: 56 pt out, or — while an ear grows wider for its content — the shape's edge as it springs
            // out (the content rides it rather than standing outside the black for a moment); each side measures by
            // its own content only (IslandLayout.earNeed / earReach: no glyph jumps because the other ear grew)
            let need = earNeed
            let earL = max(Island.earW, min(max(Island.earW, need.left), l - rect.minX))
            let earR = max(Island.earW, min(max(Island.earW, need.right), rect.maxX - r))
            let lo = IslandLayout.earReach(content: left.width, shape: earL), ro = IslandLayout.earReach(content: right.width, shape: earR)
            var lx = IslandLayout.earOrigin(.left, width: left.width, outer: l - lo, inner: l)
            var rx = IslandLayout.earOrigin(.right, width: right.width, outer: r + ro, inner: r)
            if open && drawer == nil && !content.usesRow {
                // the open island has a body under the ears (a voice note, a recording): the ears' content lines up with
                // its edges, as a live activity's leading and trailing regions share its body's (riding the edge out)
                lx = min(lx, rect.minX + IslandLayout.bodyInset - 2)       // (a 15 pt glyph's side bearing)
                rx = max(rx, rect.maxX - IslandLayout.bodyInset - right.width)
            }
            left.place(leading: CGPoint(x: peepRidesEdge(lx, rect), y: y), now: now)
            right.place(leading: CGPoint(x: rx, y: y), now: now)
        } else {
            let lx = IslandLayout.earOrigin(.left, width: left.width, outer: rect.minX, inner: nil)
            left.place(leading: CGPoint(x: peepRidesEdge(lx, rect), y: y), now: now)
            right.place(leading: CGPoint(x: IslandLayout.earOrigin(.right, width: right.width, outer: rect.maxX, inner: nil), y: y), now: now)
        }
        let e = earsWanted
        // ears only show while the shape is wide enough to hold them (each side its own)
        let half = Island.earW / 2
        let roomyL = geo.notch ? geo.cx - geo.notchW / 2 - rect.minX > half : w.value > 110
        let roomyR = geo.notch ? rect.maxX - (geo.cx + geo.notchW / 2) > half : w.value > 110
        left.layer.opacity = e.left && roomyL ? 1 : 0
        right.layer.opacity = e.right && roomyR ? 1 : 0
    }

    /// A voice note's closed right ear says how it ends for this long, then its clock.
    static let voiceHintSeconds: Double = 3

    /// How long a toast holds under a resting pointer before the island opens over it.
    static let toastHoverHold: CFTimeInterval = 1.2

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: pointer

    private func islandRect(margin: CGFloat) -> CGRect {
        CGRect(x: shapeMinX, y: geo.top, width: w.value, height: h.value).insetBy(dx: -margin, dy: -margin)
    }

    private func poll(_ now: CFTimeInterval) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let busyElsewhere = (NSApp.delegate as? App)?.picker != nil
        // follow the pointer to another screen while nothing is showing
        if !open && drawer == nil && toastNow == nil && !isRecording && !VoiceInput.shared.active && !Dictation.shared.busy, !dragActive,
           let s = pointerScreen(), s != screen {
            ensurePanel(on: s)
            return
        }
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let inside = islandRect(margin: geo.notch && !open ? 4 : 2).contains(local) && vis.value > 0.5
        // capsule screens: the hot zone brings the capsule out
        if !geo.notch, !capsuleVisible || (revealed && !inside && !open) {
            let hot = abs(local.x - geo.cx) < 160 && m.y >= (screen?.frame.maxY ?? 0) - 8
            if hot && !busyElsewhere { hotSince = hotSince ?? now } else { hotSince = nil }
            if let h = hotSince, now - h >= 0.25, !revealed { revealed = true; hotSince = nil; refresh() }
        }
        if inside && !busyElsewhere {
            awaySince = nil
            sticky = false                    // the pointer has arrived: from now on, leaving closes it
            if hoverSince == nil { hoverSince = now; cardsCalled = false }
            // the cards come down with the island's detail, once the pointer has rested on it (not on a brush past)
            if !cardsCalled, pointerDwelled { cardsCalled = true; hanging.islandAttention() }
            // resting on the ear's count opens it a little later, so the count can still be clicked
            let dwell = earHit(local) ? 0.45 : CardReveal.dwell
            // a toast under the pointer holds (its clock stops, its button stays) — for a moment only: resting on the
            // island longer is asking for the island, so the toast goes and it opens (a toast held until it was clicked
            // left the island unusable, v1.0.4 report)
            if !open, drawer == nil, !Dictation.shared.busy, now - hoverSince! >= dwell {
                if toastNow == nil {
                    setOpen(true)
                } else if now - hoverSince! >= dwell + Island.toastHoverHold {
                    toastQ.dismissCurrent()
                    setOpen(true)
                }
            }
        } else {
            hoverSince = nil
            // the pointer went down onto the hanging cards: the island stays open over them
            let pinned = sticky || drawer == .switcher || confirmingDiscard || dragActive || VoiceInput.shared.active
                || NoteBubble.shared.isOpen && isRecording || hanging.holdsIsland
            if pinned {
                awaySince = nil                // (counting starts when it lets go, not from before)
            } else if open || revealed {
                awaySince = awaySince ?? now
                if now - awaySince! >= 0.4 {
                    awaySince = nil
                    if drawer == .drop { drawer = nil }
                    setOpen(false)
                    if revealed { revealed = false; refresh() }
                }
            }
        }
        let interactive = inside || drawer != nil || confirmingDiscard
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    /// `sticky`: opened by a key or a command, not by hovering — it stays until the pointer has come and gone (or Esc).
    /// A click outside the island: the open island and its switcher close — not while something needs it (a recording's
    /// discard question, a card being dragged, the hanging cards held, a pick still to answer).
    func clickedElsewhere() {
        guard open || drawer == .switcher, !confirmingDiscard, !dragActive, pick == nil, !hanging.holdsIsland else { return }
        emit(["event": "island_close", "why": "click_elsewhere"])
        if drawer == .switcher { closeSwitcher() }
        if open { setOpen(false) }
    }

    /// A dictation or a voice note starting: the open island folds away, so its ears (Peep, the waveform) show.
    func foldForActivity() {
        if drawer == .switcher { closeSwitcher() }
        if open { setOpen(false) }
    }

    func setOpen(_ on: Bool, sticky: Bool = false) {
        self.sticky = on && sticky
        if on { hanging.islandAttention() }    // opening it drops the cards too
        guard on != open else { return }
        open = on
        emit(["event": "island_open", "open": on, "wall": Date().timeIntervalSince1970])
        if !on {
            if confirmingDiscard { confirmDiscard(false, rebuild: false) }
            if drawer == .switcher { closeSwitcher() }
        }
        content.rebuild()
        hanging.islandMoved()
        wake()
    }

    func clicked(at p: NSPoint) {
        // while a dictation listens the island is its style chip: the click went to Dictation as `.islandClick` (its
        // left half, Peep's: `.islandTranslateClick`), through the key listener, which sees it first — here it opens nothing
        if Dictation.shared.phase == .listening {
            if DictationInsert.testMode {   // no listener in tests
                let t = CACurrentMediaTime()
                Dictation.shared.handle(p.x < shapeMinX + w.value / 2 ? .islandTranslateClick(time: t) : .islandClick(time: t))
            }
            return
        }
        // a voice note's right ear (its clock): Structured on or off
        if let r = rightEarRect, r.contains(p) { VoiceInput.shared.toggleStructured(via: "ear"); return }
        // the left ear's count: the cards come down and stay (until the pointer has come and gone, or Esc)
        if earHit(p) { hanging.reveal(via: "ear"); return }
        // a toast's body: a line without a button (a peck's "open the item") is its own button; one with a button acts
        // only through it — a click meant to open the island never runs an Undo, forgets a word or undoes a page step
        if let t = toastNow, let a = t.action,
           ToastQueue<Toast>.bodyClick(hasButton: t.actionTitle != nil, hasAction: true) == .act {
            a()
            toastQ.dismissCurrent()
            refresh()
            return
        }
        // a click on the collapsed island (or on a toast's line) opens it right away; the toast is held meanwhile
        if !open && drawer == nil { setOpen(true) }
    }

    // MARK: drawer: switcher (⌥O) and drop targets (a card dragged in)

    /// The switcher's pick form: where one thing already captured goes ("Filed to X · Change" after a recording or a
    /// filed card). The same rows, type to filter; choosing calls `choose` with a project id or "inbox" and leaves the
    /// current project as it is.
    struct Pick {
        let title: String
        /// where it went: a project id, or "inbox"
        let current: String
        let choose: (String) -> Void
    }
    private(set) var pick: Pick?

    func showPicker(_ p: Pick) {
        showSwitcher()
        pick = p
        content.rebuild()
        wake()
        emit(["event": "island_pick", "current": p.current])
    }

    /// How many cards a drop on "Organize" would take: the dragged card's ⌘-click selection, else that one card.
    var dropCount: Int { hanging.dragging.map { hanging.withSelection($0.shot).count } ?? cardCount }

    func showSwitcher() {
        ensurePanel(on: screenWithPointer())
        pick = nil
        drawer = .switcher
        content.query = ""
        content.rebuild()
        panel?.keyable = true
        panel?.makeKey()
        panel?.makeFirstResponder(view)
        panel?.ignoresMouseEvents = false
        wake()
    }

    func closeSwitcher() {
        guard drawer == .switcher else { return }
        drawer = nil
        pick = nil
        panel?.keyable = false
        panel?.resignKey()
        content.rebuild()
        wake()
    }

    func toggleSwitcher() { drawer == .switcher ? closeSwitcher() : showSwitcher() }

    func key(_ e: NSEvent) -> Bool {
        if drawer == .switcher { return content.key(e) }
        if confirmingDiscard, e.keyCode == 36 || e.keyCode == 76 { confirmDiscard(false); return true }     // ↩: Keep Recording
        if e.keyCode == 53 { setOpen(false); return true }
        return false
    }

    func dragBegan() { dragActive = true; dropped = false; wake() }

    /// The pointer of a card drag (screen coordinates): near the island, the drawer opens and takes the drop.
    func dragMoved(to s: NSPoint) {
        guard let p = panel else { return }
        let local = NSPoint(x: s.x - p.frame.minX, y: p.frame.maxY - s.y)
        let zone = drawer == .drop ? islandRect(margin: 24) : islandRect(margin: 70)
        if zone.contains(local) {
            if drawer != .drop { drawer = .drop; content.rebuild(); wake() }
            if p.ignoresMouseEvents { p.ignoresMouseEvents = false }
            content.highlight(at: view.convert(local, to: content))
        } else if drawer == .drop {
            drawer = nil
            content.rebuild()
            wake()
        }
    }

    func dragOver(_ p: NSPoint?) -> NSDragOperation {
        guard let p = p, drawer == .drop else { content.highlight(at: nil); return [] }
        return content.highlight(at: view.convert(p, to: content)) != nil ? .move : []
    }

    func drop(_ pb: NSPasteboard, at p: NSPoint) -> Bool {
        guard let target = content.highlight(at: view.convert(p, to: content)),
              let raw = pb.string(forType: capturePasteboardType), let s = Island.shot(fromPasteboard: raw) else { return false }
        dropped = true
        content.perform(target, shot: s)
        return true
    }

    /// The drag is over: true when the island took the card.
    func dragEnded(at s: NSPoint) -> Bool {
        dragActive = false
        if !dropped, drawer == .drop, let p = panel, let card = hanging.dragging?.shot {
            // the drop landed on us without a destination callback (rare): resolve it here
            let local = NSPoint(x: s.x - p.frame.minX, y: p.frame.maxY - s.y)
            if let t = content.highlight(at: view.convert(local, to: content)) { content.perform(t, shot: card); dropped = true }
        }
        if drawer == .drop { drawer = nil }
        content.highlight(at: nil)
        content.rebuild()
        wake()
        return dropped
    }

    static func shot(fromPasteboard raw: String) -> Shot? {
        let parts = raw.split(separator: "\n").map(String.init)
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        return snapper.cards.first { $0.n == n && $0.batch?.dir.path == parts[0] }
    }

    // MARK: inputs from the rest of the app

    func cardsChanged(_ n: Int) {
        guard n != cardCount else { return }
        cardCount = n
        refresh()
        NotificationCenter.default.post(name: .blurtCardsChanged, object: nil, userInfo: ["count": n])
    }

    var hangingCount: Int { cardCount }

    /// Esc for the cards: an island opened by a key or a command goes up with them.
    func closeIfSticky() { if open && sticky { setOpen(false) } }

    func revealCards() {
        guard cardCount > 0 else { hanging.reveal(via: "main_window"); return }    // (says there are none)
        setOpen(true, sticky: true)
        hanging.reveal(via: "main_window")
    }

    /// The island swallows something (a capture pulled in, a dropped card).
    func bump() {
        bumpStart = CACurrentMediaTime()
        wake()
    }

    func recordingChanged() {
        if !isRecording, confirmingDiscard { confirmDiscard(false, rebuild: false) }
        refresh()
    }

    /// Discard's question while recording. It takes the keyboard while it shows, as the switcher does (the panel is
    /// non-activating: the app being recorded stays in front): ↩ chooses Keep Recording — the default, the safe one —
    /// and Esc closes the island, which keeps it too.
    func confirmDiscard(_ on: Bool, rebuild: Bool = true) {
        confirmingDiscard = on
        if on {
            panel?.keyable = true
            panel?.makeKey()
            panel?.makeFirstResponder(view)
        } else if drawer != .switcher {
            panel?.keyable = false
            panel?.resignKey()
        }
        guard rebuild else { return }
        content.rebuild()
        wake()
    }
    var isConfirmingDiscard: Bool { confirmingDiscard }

    // MARK: toasts (K4: one quiet line that never takes focus — BlurtCore ToastQueue has the rules)

    func toast(_ text: String, actionTitle: String?, action: (() -> Void)?) {
        toast(Toast(text: text, actionTitle: actionTitle, action: action))
    }

    /// One line about `key` (a newer one about the same thing replaces it at once), optionally with the ok check.
    func toast(_ text: String, key: String?, icon: BlurtIcon? = nil, seconds: Double = 5,
               actionTitle: String? = nil, action: (() -> Void)? = nil) {
        var t = Toast(text: text, actionTitle: actionTitle, action: action)
        t.key = key
        t.icon = icon
        t.seconds = seconds
        toast(t)
    }

    func toast(_ t: Toast) {
        // a short done line with nothing to do about it ("Copied") is a moment in the ears, like "Sent": a toast's
        // 46 pt of black isn't spent on one word
        let ear = t.icon == .check && t.action == nil && t.art == nil && t.badge == nil && !t.overOpen && !t.isQuestion
            && !t.text.contains("\n") && !t.text.contains(" · ")
            && (t.text as NSString).size(withAttributes: [.font: EarSlot.font]).width <= Island.earMomentMaxText
        emit(["event": "island_toast", "text": t.text, "key": t.key ?? NSNull(), "passive": t.passive, "ear": ear])
        if ear, earMoment(t.text, lead: nil) { return }
        let e = ToastQueue<Toast>.Entry(t, text: t.text, key: t.key, kind: t.passive ? .passive : .reply, seconds: t.seconds,
                                        actionable: t.action != nil, question: t.isQuestion)
        let shown = toastQ.current?.order
        let r = toastQ.post(e, now: CACurrentMediaTime(), canShowNow: canShowToast(t))
        if r == .shown || r == .replaced { t.onShown?() }
        if r != .queued || toastQ.current?.order != shown { content.rebuild() }
        wake()
    }

    /// The open island takes only the toasts meant to go over it (an Undo for what was just done on the cards, a
    /// question); the others wait until it closes.
    /// A take's "✓ 0:42" holds its 1.6 s before a toast (where it was filed) takes the island.
    /// No question and no passive line goes up while the user is talking (a style question popped up as a take
    /// started): they wait, and go stale if the take runs long.
    private func canShowToast(_ t: Toast) -> Bool {
        drawer == nil && (!open || t.overOpen || t.isQuestion) && (RecordingDone.text == nil || t.isQuestion)
            && (!listening || !(t.isQuestion || t.passive))
    }

    /// Forgets every toast about `key`, the one showing too (dictation's, when a new take starts).
    func dropToasts(key: String) {
        guard toastLive(key: key) else { return }
        toastQ.drop(key: key)
        content.rebuild()
        wake()
    }

    /// The "Sent" moment after a double tap (dictation): the keyboard on the left, the ok check and the word on the
    /// right for 1.6 s — no toast for one word; only the right ear widens for it (earNeed).
    func dictationSent() {
        MenuGlyph.shared.done()
        earMoment(Loc.t("dictation.toast.sent", table: "Dictation"), lead: .keyboard, seconds: 1.6)
        emit(["event": "island_sent"])
    }

    /// A short done state in the ears instead of a toast ("✓ Saved 0:42", "✓ Copied"): `lead` the source's glyph on
    /// the left (quiet), the ok check and `text` on the right. False when the ears are taken by something live (a
    /// recording, a voice note, a dictation): say it as a toast then.
    @discardableResult
    func earMoment(_ text: String, lead: BlurtIcon?, seconds: Double = 2.2) -> Bool {
        guard !isRecording, !VoiceInput.shared.active, !Dictation.shared.busy || lead == .keyboard else { return false }
        moment = (lead, text)
        momentUntil = CACurrentMediaTime() + seconds
        helloUntil = 0
        emit(["event": "island_moment", "text": text])
        refresh()
        return true
    }

    /// A take saved without processing: "✓ Saved 0:42" in the ears (the record glyph on the left), or — with the ears
    /// busy — the done toast.
    func doneMoment(_ ear: String, lead: BlurtIcon?, toast text: String) {
        MenuGlyph.shared.done()
        if earMoment(ear, lead: lead) { return }
        toast(text, key: nil, icon: .check)
    }

    /// The ears hold both sides after the work ended: dictation sending (a queued Return), a done moment ("Sent",
    /// "✓ Copied"), a take's ✓ and length (RecordingDone).
    private var dictationMoment: Bool { Dictation.shared.sendQueued || CACurrentMediaTime() < momentUntil || RecordingDone.text != nil }

    private func tickToasts(_ now: CFTimeInterval) {
        let before = toastQ.current?.order
        toastQ.tick(now: now, paused: hoverSince != nil, canShow: { [unowned self] e in self.canShowToast(e.payload) })
        if toastQ.current?.order != before {
            if let t = toastNow { emit(["event": "island_toast_shown", "text": t.text]); t.onShown?() }
            content.rebuild()
        }
    }
    var currentToast: Toast? { toastNow }
    /// Tests: what a click on the toast's line does — its leading edge, away from any button.
    func testClickToastLine() {
        clicked(at: NSPoint(x: shapeMinX + 24, y: geo.top + h.value - 23))
        emit(["event": "island_clicked", "open": open, "toast": toastNow?.text ?? NSNull()])
    }
    /// The toasts waiting, in the order they'd go up (tests).
    var waitingToasts: [String] { toastQ.waiting.map(\.text) }
    /// A toast with this key is showing or waiting to.
    func toastLive(key: String) -> Bool { toastQ.current?.key == key || toastQ.waiting.contains { $0.key == key } }

    // MARK: hatching (only for captures being processed — K7)

    /// Captures were handed to processing: Peep thinks in the ear now; the process job that picks them up takes it over.
    func expectProcess(session: URL, captures: [Int]) {
        if let h = hatches.first(where: { $0.session == session && $0.job == nil && $0.ended == nil }) {
            h.captures = Array(Set(h.captures + captures)).sorted()
        } else {
            hatches.append(Hatch(session: session, captures: captures))
        }
        refresh()
        // nothing picked it up: let it go quietly
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self = self else { return }
            self.hatches.removeAll { $0.job == nil && $0.ended == nil && CACurrentMediaTime() - $0.since > 110 }
            self.refresh()
        }
    }

    private func jobsChanged(_ changed: [Job]) {
        for j in changed where j.type == .process {
            guard let s = j.session else { continue }
            let h = hatches.first { $0.job == j.id }
                ?? hatches.first { $0.job == nil && canonicalPath($0.session) == canonicalPath(s)
                    && j.created > $0.born.addingTimeInterval(-2)       // not an older job of the same batch
                    && (j.captures.isEmpty || !Set(j.captures).isDisjoint(with: $0.captures)) }
            guard let hatch = h else { continue }
            hatch.job = j.id
            if !j.isActive, hatch.ended == nil {
                hatch.ended = (CACurrentMediaTime(), j.state == .done, j.items.count)
                // the hand-off / AI sort finished: Peep says it in the ear — a peep and a hop, or a head shake
                DispatchQueue.main.asyncAfter(deadline: .now() + (j.state == .done ? EarSlot.sortedSeconds + 1.4 : 5)) { [weak self] in
                    self?.hatches.removeAll { $0 === hatch }
                    self?.refreshReviewCount()
                    self?.refresh()
                }
            }
        }
        // a session that started waiting on you: its marker pulses once
        for j in changed where j.type == .agent {
            let st = j.agent?.status.rawValue ?? ""
            if lastAgentAlert[j.id] != st { lastAgentAlert[j.id] = st; if j.agent?.status == .waitingInput { right.pulse() } }
        }
        refresh()
    }

    var activeJobs: [Job] { Array(JobStore.shared.active.filter { $0.type != .agent }.prefix(3)) }
    var sessionsNeedingYou: [Job] {
        JobStore.shared.active.filter { $0.type == .agent && [.waitingInput, .turnDone, .error].contains($0.agent?.status ?? .running) }
    }
    var toReview: Int { reviewCount }

    private func refreshReviewCount() {
        DispatchQueue.global(qos: .utility).async {
            let n = (try? IndexReader().count(ItemQuery(inbox: true, limit: 0))) ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                defer { self.reviewLoaded = true }
                guard n != self.reviewCount else { return }
                // more than before (not the first count at launch): that many just landed — said for a moment
                if self.reviewLoaded, n > self.reviewCount { self.announceInbox(n - self.reviewCount) }
                self.reviewCount = n
                self.refresh()
            }
        }
    }

    /// "+n" with the tray in the right ear for a few seconds (a second batch within them adds to it): the inbox grew.
    func announceInbox(_ n: Int) {
        guard n > 0 else { return }
        newsCount = inboxNews ? newsCount + n : n
        newsUntil = CACurrentMediaTime() + Island.newsSeconds
        emit(["event": "island_inbox_news", "n": newsCount])
        refresh()
    }
}

let island = Island()
extension Island { static var shared: Island { island } }
