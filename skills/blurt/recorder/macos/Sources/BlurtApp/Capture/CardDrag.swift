// One card dragged out of the app — a hanging card, or one in the Cards panel (Current or History). What is on the drag
// pasteboard follows the app under the pointer: BlurtCore DropTargets says which kind of app it is, CardPasteboard
// .drag(for:) what that kind gets (the table is in CardDropTarget.swift; the user's view of it in HangingCards' header).
// v0.8.5: a rich app (Notes, TextEdit, Mail…) gets the rich item (picture file + PNG + HTML + RTFD + RTF + the note as
// one line); every chat app (browsers, Electron apps, WeChat, QQ, anything else) and the Finder the picture alone —
// the note is pasted after the drop (Captures.takeOut → DragNoteFollowUp); a terminal both paths. The .md rides as the
// second item only for a terminal, or with record.drag_note_file on.
// v0.8.6: a voice card (its words, one item) over a chat app's window — BlurtCore VoiceCardDrop — gets our own hint
// drawn under the card in the drag image ("松手粘贴到 Claude": the app shows none for text) and doesn't fly back when
// the app refuses the drop; the caller (HangingCards / TakenPanel) then has the words pasted into that window's
// composer (voiceTarget(at:) → Snapper.takeOutVoice).
//
// How, and why this way (measured with our own stand-in apps — an NSTextView, a WKWebView page, logging pads):
//  • The items are lazily provided (NSPasteboardItemDataProvider): when an app asks for a type, we look at where the
//    pointer is — the frontmost window under NSEvent.mouseLocation in CGWindowList's z-order, skipping our own
//    windows (the cards' panel is mouse-transparent during a drag; the drop goes to what is under it) — and answer for
//    that app's class.
//  • But the pasteboard keeps the first answer for the rest of the drag, whoever asks again, and apps ask while the
//    drag is only passing over them: a web view on entering, a text view while hovering. So the first app passed over
//    (often the one under the cards) would decide for the one it lands in. Hence: when the pointer moves into an app
//    of another class with another layout (draggingSession(movedTo:)), the drag pasteboard is cleared and written
//    again, lazily, for the new class — with that class's own types, so item 2 is a .md file or inert, never a
//    declared type that comes back empty (a text view logs "Couldn't get a copy of a URL-flavored data" for every
//    such read and skips it).
//  • The number of items is fixed when the drag starts (the badge says 2); what item 2 is depends on the target.
//  • A race is still possible (an app reads before the rewrite reaches it); the drop's end compares the layout for
//    the app it landed in with the one last written: only a drop that got the chat layout gets the note pasted after
//    it (a rich layout read by mistake already had the note in it), and the toast only claims what it knows.
// v0.9 — the layout follows the app's composer too (BlurtCore DragLanding): WeChat / QQ get the rich item they put
// the picture in their composer from (the picture alone was a bare file URL to them: a file to send), and a voice
// card over Feishu / Lark carries no words when Blurt can paste them (Feishu took a text drop and put nothing in).
// BA-22 — a row of the main window's list goes out the same way (CardDrag(item:), CardPasteboard.itemDrag; it was a
// fixed file URL and a title, so WeChat got the picture alone), its uid riding on the first item for in-app drops; its
// drop ends like a card's (DragOutEnd, SmartPaste.swift). BA-54 — entering a web app's window wakes its Accessibility
// tree for the note's paste (WebAXWake), and a shot card with a note over a chat app says "Let go, then ⌘V in Claude"
// while Accessibility is missing (DragFollowUp.noteHint).
// Tests (BLURT_TEST_COMMANDS=1): `droptarget map PID=BUNDLE,…` gives our stand-in processes the bundle ids of the apps
// they stand in for (the decision still goes through the window owner's pid); BLURT_TEST_DROP_TARGET=BUNDLE (or
// `droptarget fixed BUNDLE`) does it for every window that isn't ours.

import AppKit
import ImageIO
import BlurtCore

/// The app a drag is over: who owns the window under the pointer, its class, and its kind of composer (the caret).
struct DropTarget: Equatable {
    let pid: pid_t
    let bundleID: String?
    let cls: DropClass
    let kind: ComposerKind
}

enum DropProbe {
    static let testMode = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
    /// tests: stand-in pid → the bundle id it stands in for
    static var testMap: [pid_t: String] = [:]
    /// tests: every window that isn't ours is this app
    static var testFixed: String? = testMode ? ProcessInfo.processInfo.environment["BLURT_TEST_DROP_TARGET"].flatMap { $0.isEmpty ? nil : $0 } : nil
    private static var cache: [pid_t: DropTarget] = [:]

    /// The app under the pointer (global Cocoa point `p`, default the pointer); nil when it is one of ours or nothing.
    static func target(at p: NSPoint = NSEvent.mouseLocation) -> DropTarget? {
        guard let pid = ownerPID(at: p) else { return nil }
        return target(pid: pid)
    }

    static func target(pid: pid_t) -> DropTarget {
        if testMode, let id = testMap[pid] ?? testFixed {
            return DropTarget(pid: pid, bundleID: id, cls: DropTargets.classify(bundleID: id),
                              kind: DropTargets.composer(bundleID: id, appURL: nil))
        }
        if let t = cache[pid] { return t }
        let app = NSRunningApplication(processIdentifier: pid)
        let t = DropTarget(pid: pid, bundleID: app?.bundleIdentifier, cls: DropTargets.classify(bundleID: app?.bundleIdentifier),
                           kind: DropTargets.composer(bundleID: app?.bundleIdentifier, appURL: app?.bundleURL))
        cache[pid] = t
        return t
    }

    /// The owner of the frontmost window under `p`, front to back in CGWindowList order: not ours, not the Window
    /// Server's, not invisible, not above the dragging level (the drag image, the cursor).
    static func ownerPID(at p: NSPoint) -> pid_t? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let q = CGPoint(x: p.x, y: top - p.y)
        let me = Int(getpid())
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            guard pid != me, (w[kCGWindowLayer as String] as? Int ?? 0) < 500, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (w[kCGWindowOwnerName as String] as? String) != "Window Server",
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(q) { return pid_t(pid) }
        }
        return nil
    }

    private static var names: [pid_t: String] = [:]

    /// The app's name, for the island and a voice card's drop hint ("Claude", "微信"): the running app's own name; a
    /// test stand-in's is the name of the app it stands in for, when that is installed (read from its bundle).
    static func appName(_ t: DropTarget) -> String? {
        if let n = names[t.pid] { return n }
        var n: String?
        if testMode, testMap[t.pid] != nil || testFixed != nil, let id = t.bundleID,
           let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            n = (FileManager.default.displayName(atPath: u.path) as NSString).deletingPathExtension
        }
        if n == nil { n = NSRunningApplication(processIdentifier: t.pid)?.localizedName }
        if let n = n { names[t.pid] = n }
        return n
    }

    /// `droptarget map PID=BUNDLE,… | fixed BUNDLE | clear` (test command)
    static func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "map":
            for pair in (a.count > 1 ? a[1] : "").split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, let pid = pid_t(kv[0]) { testMap[pid] = kv[1] }
            }
        case "fixed": testFixed = a.count > 1 ? a[1] : nil
        case "clear": testMap = [:]; testFixed = nil
        default: break
        }
        cache = [:]
        names = [:]
        emit(["event": "droptarget", "map": Dictionary(uniqueKeysWithValues: testMap.map { ("\($0.key)", $0.value) }),
              "fixed": testFixed ?? NSNull()])
    }
}

/// Electron's web content shown to Accessibility for the note's paste after a drop (BA-54: a card dragged into the
/// Claude desktop app left the picture alone when the pointer wasn't over its composer — Electron builds its
/// Accessibility tree only once a client sets AXManualAccessibility, so the follow-up found no composer to focus).
/// The same wake dictation does (DictationField.wakeWebAccessibility: Electron apps only, once per process, never
/// Chrome's or Safari's AXEnhancedUserInterface): asked when a drag enters a web app's window (CardDrag.moved), and
/// again by the follow-up (DragNoteFollowUp.focus), which waits what is left of `settle` after the first ask.
enum WebAXWake {
    /// how long Chromium takes to build the tree after the first ask (s)
    static let settle: CFTimeInterval = 0.15
    private static var asked: [pid_t: CFTimeInterval] = [:]

    /// Ask app `pid` to show its web content (once; Electron only, with Accessibility). Returns the seconds still to
    /// wait before its tree can be probed (0: asked long enough ago, or nothing to wake).
    @discardableResult
    static func wake(_ pid: pid_t) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        if let t = asked[pid] { return max(0, settle - (now - t)) }
        guard !DictationInsert.testMode, AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
              DictationField.isElectron(app) else { return 0 }
        DictationField.wakeWebAccessibility(app)
        asked[pid] = now
        emit(["event": "drag_web_ax", "pid": Int(pid), "bundle": app.bundleIdentifier ?? NSNull()])
        return settle
    }
}

/// A drag out of the app: its files, the pasteboard it fills, and the class that pasteboard was last written for.
/// A hanging card or a Recently Taken thumb (init(_ shot:)), or — BA-22 — one row of the main window's list
/// (ItemListController: the item's first frame, its text, its .md; CardPasteboard.itemDrag): the same per-app layout,
/// written lazily and again as the pointer crosses into another kind of app.
final class CardDrag: NSObject, NSPasteboardItemDataProvider {
    let card: CardPasteboard.Card
    /// the rich flavours (HTML, RTFD, RTF), built the first time an app asks for one
    let rich: CardRich
    /// the capture's own type (a drop on a project in the island); nil for a list row
    let tag: String?
    /// types the first item carries as they are, through every rewrite — a list row's uid (.blurtItems: the sidebar's
    /// move, the list's own drops keep working)
    let extra: [NSPasteboard.PasteboardType: String]
    /// a voice card (its words; VoiceCardDrop)
    let isVoice: Bool
    /// a list row: CardPasteboard.itemDrag's layout (its text as rich text where there is no picture)
    let isItem: Bool
    /// who it is, for the log: the card's number, or the item's uid
    let who: [String: Any]
    /// record.drag_note_file when the drag started: the .md rides along into chat apps and the Finder too
    let attachNote = CardExport.attachNoteFile
    /// the app the drag pasteboard was written for now (its class, its composer; BlurtCore DragLanding)
    private(set) var written: DragLanding
    private(set) var target: DropTarget?
    weak var session: NSDraggingSession?
    /// our lazily provided items → their index in the layout written with them
    private var index: [ObjectIdentifier: Int] = [:]
    private var live: [NSPasteboardItem] = []
    private var lastProbe: (at: NSPoint, time: CFTimeInterval) = (.zero, 0)

    /// A hanging card or a Recently Taken thumb (its files written again: the note may have changed).
    convenience init(_ s: Shot) {
        let (c, part) = CardExport.card(s)
        self.init(card: c, rich: CardRich([part]), tag: CardExport.tag(s), voice: s.kind == .voice, who: ["n": s.n])
    }

    /// One row of the main window's list (BA-22): its first frame as the picture, `text` (its title and words:
    /// ItemListController.dragText) as the note, its .md as the note file (not a legacy row's items.json), its uid on
    /// the first item (.blurtItems). nil: nothing to carry.
    convenience init?(item it: ItemRow, text: String) {
        let fm = FileManager.default
        let image = it.primaryFrame.flatMap { fm.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let md = !it.legacy && fm.fileExists(atPath: it.fileURL.path) ? it.fileURL : nil
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard image != nil || note != nil || md != nil else { return nil }
        // the picture's size in points for the HTML / RTFD: its DPI (a Retina frame says 144), else 1:1
        let dpi = image.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyDPIWidth] as? Double
        let scale = CGFloat(max(1, (dpi ?? 72) / 72))
        self.init(card: CardPasteboard.Card(image: image, note: note, noteFile: md),
                  rich: CardRich([CardRich.Part(image: image, note: note, scale: scale)]), tag: nil, extra: [.blurtItems: it.uid],
                  item: true, who: ["uid": it.uid])
    }

    init(card: CardPasteboard.Card, rich: CardRich, tag: String?, extra: [NSPasteboard.PasteboardType: String] = [:],
         voice: Bool = false, item: Bool = false, who: [String: Any]) {
        self.card = card
        self.rich = rich
        self.tag = tag
        self.extra = extra
        isVoice = voice
        isItem = item
        self.who = who
        target = DropProbe.target()
        written = DragLanding(cls: .chat)
        super.init()
        written = landing(target)
        report("card_drag_target")
    }

    /// What a drag over `t` is written for: its class and composer, and for a voice card whether Blurt pastes the words
    /// there itself (then the drag leaves them off: VoiceCardDrop.withholdsWords). Nothing under the pointer: chat.
    func landing(_ t: DropTarget?) -> DragLanding {
        guard let t else { return DragLanding(cls: .chat) }
        return DragLanding(cls: t.cls, kind: t.kind,
                           wordsWithheld: isVoice && VoiceCardDrop.withholdsWords(bundleID: t.bundleID, cls: t.cls, kind: t.kind,
                                                                                  canPaste: SmartPaste.enabled && SmartPaste.accessibility))
    }

    func layout(_ l: DragLanding) -> [CardPasteboard.Item] {
        isItem ? CardPasteboard.itemDrag(into: l, card: card, attachNote: attachNote)
               : CardPasteboard.drag(into: l, card: card, attachNote: attachNote)
    }

    /// The items for `written`, every type lazily provided, `extra` on the first as it is; at least one (the capture's
    /// tag, or `extra`) so a drag can start. Without a tag an inert item would carry nothing: it is left out.
    func pasteboardItems() -> [NSPasteboardItem] {
        index = [:]
        var items: [NSPasteboardItem] = []
        for (i, it) in layout(written).enumerated() {
            let types = CardDrag.types(it, tag: tag != nil)
            guard !types.isEmpty else { continue }
            let p = NSPasteboardItem()
            p.setDataProvider(self, forTypes: types)
            index[ObjectIdentifier(p)] = i
            items.append(p)
        }
        if items.isEmpty, tag != nil || !extra.isEmpty {
            let p = NSPasteboardItem()
            if let t = tag { p.setString(t, forType: capturePasteboardType) }
            items = [p]
        }
        for (type, s) in extra { items.first?.setString(s, forType: type) }
        live = items
        return items
    }

    /// The drag began with one writer of ours (a table row: NSTableView takes one per row): the session's pasteboard
    /// gets every item of the layout written for (a terminal's .md path, a chat app's .md with record.drag_note_file).
    func began(_ s: NSDraggingSession) {
        session = s
        guard live.count > 1 else { return }
        let pb = s.draggingPasteboard
        pb.clearContents()
        report("card_drag_target", ["rewritten": pb.writeObjects(pasteboardItems())])
    }

    static func types(_ it: CardPasteboard.Item, tag: Bool = true) -> [NSPasteboard.PasteboardType] {
        CardExport.flavours(it, copy: false, tag: tag).map(CardExport.type)
    }

    // MARK: the drop hint — a voice card's (VoiceCardDrop), a shot card's without Accessibility (DragFollowUp.noteHint)

    /// what the drag image says now ("松手粘贴到 Claude"; nil: the card alone)
    private(set) var hint: VoiceCardDrop.Hint?
    /// the drag image as it started, its frame (in `source`'s coordinates) and that view
    private var base: (image: NSImage, frame: NSRect, view: NSView)?

    /// The card's own image and frame, for the hint to be drawn under it.
    func setBase(image: NSImage, frame: NSRect, in view: NSView) { base = (image, frame, view) }

    /// A voice card over a window whose app gets the words pasted wherever it is let go of: the drag image says so (the
    /// app shows nothing for text), and a refused drop doesn't fly back to the card. A shot card with a note over a
    /// chat app while Accessibility is missing (BA-54): "Let go, then ⌘V in Claude" — the picture goes in, the note
    /// will be on the clipboard; a refused drop still flies back (nothing was used). Over Blurt, nothing or another
    /// app: the card.
    private func updateHint(_ t: DropTarget?) {
        let h: VoiceCardDrop.Hint? = t.flatMap { t in
            if isVoice {
                return VoiceCardDrop.hint(cls: t.cls, kind: t.kind, app: DropProbe.appName(t), enabled: SmartPaste.enabled,
                                          accessibility: SmartPaste.accessibility)
            }
            guard t.cls == .chat, card.image != nil, card.note != nil else { return nil }      // (no app name looked up)
            return DragFollowUp.noteHint(cls: t.cls, kind: t.kind, app: DropProbe.appName(t), card: card, enabled: SmartPaste.enabled,
                                         accessibility: SmartPaste.accessibility, copiesNote: CardExport.copyNoteAfterDrag)
        }
        guard h != hint else { return }
        hint = h
        if isVoice { session?.animatesToStartingPositionsOnCancelOrFail = h == nil }
        if let b = base, let s = session {
            let (img, frame) = CardDrag.hinted(b.image, frame: b.frame, hint: h, flipped: b.view.isFlipped)
            s.enumerateDraggingItems(options: [], for: b.view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, i, _ in
                if i == 0 { item.setDraggingFrame(frame, contents: img) }
            }
        }
        let text: String? = h.map { CardDrag.hintText($0) }
        emit(who.merging(["event": isVoice ? "voice_drag_hint" : "card_drag_hint", "hint": text ?? NSNull(), "pid": Int(t?.pid ?? 0),
                          "bundle": t?.bundleID ?? NSNull()]) { $1 })
    }

    static func hintText(_ h: VoiceCardDrop.Hint) -> String {
        switch h {
        case .paste(let app): return Loc.t("capture.voice_drop.hint_paste", table: "Capture", app)
        case .copy(let app): return Loc.t("capture.voice_drop.hint_copy", table: "Capture", app)
        }
    }

    /// The card with the hint under it: a small pill in the brand colour, the card above it as it was.
    static func hinted(_ card: NSImage, frame: NSRect, hint: VoiceCardDrop.Hint?, flipped: Bool) -> (NSImage, NSRect) {
        guard let h = hint else { return (card, frame) }
        let text = NSAttributedString(string: hintText(h), attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                         .foregroundColor: BrandColor.Island.on])
        let icon = NSImage(systemSymbolName: "text.insert", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [BrandColor.Island.on])))
        let pillH: CGFloat = 24, gap: CGFloat = 6
        let pillW = ceil(text.size().width) + 20 + (icon != nil ? 18 : 0)
        let w = max(frame.width, pillW), hgt = frame.height + gap + pillH
        let img = NSImage(size: NSSize(width: w, height: hgt), flipped: false) { _ in
            card.draw(in: NSRect(x: (w - frame.width) / 2, y: pillH + gap, width: frame.width, height: frame.height))
            let pill = NSRect(x: (w - pillW) / 2, y: 0, width: pillW, height: pillH)
            NSColor(white: 0, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: pill.offsetBy(dx: 0, dy: -1), xRadius: pillH / 2, yRadius: pillH / 2).fill()
            BrandColor.Island.fill.setFill()          // a flat mint chip, dark text: blurt is about to act for you
            NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            var x = pill.minX + 10
            if let ic = icon {
                ic.draw(in: NSRect(x: x, y: pill.midY - ic.size.height / 2, width: ic.size.width, height: ic.size.height))
                x += 18
            }
            text.draw(at: NSPoint(x: x, y: pill.midY - text.size().height / 2))
            return true
        }
        // the card stays where it was under the pointer; the pill hangs below it
        let f = NSRect(x: frame.midX - w / 2, y: flipped ? frame.minY : frame.maxY - hgt, width: w, height: hgt)
        return (img, f)
    }

    /// The pointer moved: into an app of another class, the pasteboard is written again for it.
    func moved(to p: NSPoint) {
        let now = CACurrentMediaTime()
        // a window list costs a millisecond or two: at most every 30 ms while moving, every 0.25 s while resting
        let dt = now - lastProbe.time
        guard dt > 0.25 || (dt >= 0.03 && hypot(p.x - lastProbe.at.x, p.y - lastProbe.at.y) >= 3) else { return }
        lastProbe = (p, now)
        let under = DropProbe.target(at: p)
        updateHint(under)
        guard let t = under else { return }     // over our own windows: as it was
        let changedApp = t.pid != target?.pid
        // an Electron app's composer becomes findable for the note's paste after the drop (WebAXWake, BA-54)
        if changedApp, t.kind == .web { WebAXWake.wake(t.pid) }
        target = t
        let l = landing(t)
        // the same layout for another app (chat ↔ finder): no rewrite
        guard layout(l) != layout(written), let pb = session?.draggingPasteboard else {
            if l != written { written = l }
            if changedApp { report("card_drag_target") }
            return
        }
        written = l
        pb.clearContents()
        let ok = pb.writeObjects(pasteboardItems())
        report("card_drag_target", ["rewritten": ok])
    }

    /// The drag ended at `p` over another app: the class of what it got, if we know it (nil: it read the pasteboard
    /// written for another kind of app). `noteFile`: the .md was among it.
    func delivered(at p: NSPoint) -> DropClass? {
        let t = DropProbe.target(at: p)
        let got: DropClass? = t.flatMap { layout(landing($0)) == layout(written) ? $0.cls : nil }
        emit(who.merging(["event": "card_drag_end", "bundle": t?.bundleID ?? NSNull(), "class": t?.cls.rawValue ?? NSNull(),
                          "kind": t?.kind.rawValue ?? NSNull(), "written": written.cls.rawValue,
                          "written_kind": written.kind?.rawValue ?? NSNull(), "words_withheld": written.wordsWithheld,
                          "delivered": got?.rawValue ?? NSNull(), "note_file": got.map(noteFile(_:)) ?? false]) { $1 })
        return got
    }

    /// A voice card let go of over a window whose app gets the words pasted (VoiceCardDrop.pastes) — whether or not
    /// the app took the drop: that app.
    func voiceTarget(at p: NSPoint) -> DropTarget? {
        guard isVoice, let t = DropProbe.target(at: p), VoiceCardDrop.pastes(cls: t.cls, kind: t.kind) else { return nil }
        return t
    }

    /// A voice card let go of over `t`: the drag pasteboard, as last written, carried no words for that app (Blurt
    /// pastes them itself: VoiceCardDrop.plan). Rewrites are throttled, so a quick drop can land before the words came
    /// off: then they were on the drag, and the app's answer is what counts.
    func wordsWithheld(at t: DropTarget) -> Bool { isVoice && written.wordsWithheld && landing(t) == written }

    /// The .md is in what an app of class `c` got (the layout last written, when it was written for that class).
    func noteFile(_ c: DropClass) -> Bool {
        let l = written.cls == c ? written : DragLanding(cls: c)
        return card.noteFile.map { f in layout(l).contains { $0.file == f } } ?? false
    }

    private func report(_ event: String, _ more: [String: Any] = [:]) {
        var o: [String: Any] = who
        o.merge(["event": event, "pid": Int(target?.pid ?? 0), "bundle": target?.bundleID ?? NSNull(),
                 "class": target?.cls.rawValue ?? NSNull(), "written": written.cls.rawValue,
                 "kind": target?.kind.rawValue ?? NSNull(), "words_withheld": written.wordsWithheld,
                 "items": layout(written).map { CardDrag.types($0, tag: tag != nil).map(\.rawValue) }]) { $1 }
        for (k, v) in more { o[k] = v }
        emit(o)
    }

    // MARK: NSPasteboardItemDataProvider

    /// An app asks for one of an item's types: answer for the app under the pointer now. That is the class this
    /// pasteboard was written for, unless the pointer has just crossed into another kind of app before moved(to:) saw
    /// it — then that app's layout, as far as this item's declared types go.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let i = index[ObjectIdentifier(item)] else { return }
        let now = DropProbe.target().map(landing) ?? written
        let lay = layout(now)
        guard i < lay.count else { return }
        let it = lay[i]
        var given = false
        if let f = CardExport.flavours.first(where: { CardExport.type($0) == type }),
           CardExport.flavours(it, copy: false, tag: tag != nil).contains(f),
           let d = CardExport.data(f, of: it, rich: rich, tag: tag) {
            item.setData(d, forType: type)
            given = true
        }
        emit(who.merging(["event": "card_drag_provide", "item": i + 1, "type": type.rawValue, "class": now.cls.rawValue,
                          "written": written.cls.rawValue, "given": given]) { $1 })
    }
}
