// One card dragged out of the app — a hanging card, or a picture in Recently Taken (v0.8.2). What is on the drag
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
// Tests (BLURT_TEST_COMMANDS=1): `droptarget map PID=BUNDLE,…` gives our stand-in processes the bundle ids of the apps
// they stand in for (the decision still goes through the window owner's pid); BLURT_TEST_DROP_TARGET=BUNDLE (or
// `droptarget fixed BUNDLE`) does it for every window that isn't ours.

import AppKit
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

/// A card's drag: its files, the pasteboard it fills, and the class that pasteboard was last written for.
final class CardDrag: NSObject, NSPasteboardItemDataProvider {
    let shot: Shot
    let card: CardPasteboard.Card
    /// the rich flavours (HTML, RTFD, RTF), built the first time an app asks for one
    let rich: CardRich
    let tag: String?
    /// record.drag_note_file when the drag started: the .md rides along into chat apps and the Finder too
    let attachNote = CardExport.attachNoteFile
    /// the class the drag pasteboard holds now
    private(set) var written: DropClass
    private(set) var target: DropTarget?
    weak var session: NSDraggingSession?
    /// our lazily provided items → their index in the layout written with them
    private var index: [ObjectIdentifier: Int] = [:]
    private var live: [NSPasteboardItem] = []
    private var lastProbe: (at: NSPoint, time: CFTimeInterval) = (.zero, 0)

    init(_ s: Shot) {
        shot = s
        let (c, part) = CardExport.card(s)
        card = c
        rich = CardRich([part])
        tag = CardExport.tag(s)
        target = DropProbe.target()
        written = target?.cls ?? .chat
        super.init()
        report("card_drag_target")
    }

    func layout(_ c: DropClass) -> [CardPasteboard.Item] { CardPasteboard.drag(for: c, card: card, attachNote: attachNote) }

    /// The items for `written`, every type lazily provided; at least one (the capture's tag) so a drag can start.
    func pasteboardItems() -> [NSPasteboardItem] {
        index = [:]
        let items = layout(written).enumerated().map { i, it -> NSPasteboardItem in
            let p = NSPasteboardItem()
            p.setDataProvider(self, forTypes: CardDrag.types(it, tag: tag != nil))
            index[ObjectIdentifier(p)] = i
            return p
        }
        if items.isEmpty, let t = tag {
            let p = NSPasteboardItem()
            p.setString(t, forType: capturePasteboardType)
            return [p]
        }
        live = items
        return items
    }

    static func types(_ it: CardPasteboard.Item, tag: Bool = true) -> [NSPasteboard.PasteboardType] {
        CardExport.flavours(it, copy: false, tag: tag).map(CardExport.type)
    }

    // MARK: a voice card's own drop hint (VoiceCardDrop)

    var isVoice: Bool { shot.kind == .voice }
    /// what the drag image says now ("松手粘贴到 Claude"; nil: the card alone)
    private(set) var hint: VoiceCardDrop.Hint?
    /// the drag image as it started, its frame (in `source`'s coordinates) and that view
    private var base: (image: NSImage, frame: NSRect, view: NSView)?

    /// The card's own image and frame, for the hint to be drawn under it.
    func setBase(image: NSImage, frame: NSRect, in view: NSView) { base = (image, frame, view) }

    /// Over a window whose app gets the words pasted wherever it is let go of: the drag image says so (the app shows
    /// nothing for text), and a refused drop doesn't fly back to the card. Over Blurt, nothing or another app: the card.
    private func updateHint(_ t: DropTarget?) {
        guard isVoice else { return }
        let h = t.flatMap {
            VoiceCardDrop.hint(cls: $0.cls, kind: $0.kind, app: DropProbe.appName($0), enabled: SmartPaste.enabled,
                               accessibility: SmartPaste.accessibility)
        }
        guard h != hint else { return }
        hint = h
        session?.animatesToStartingPositionsOnCancelOrFail = h == nil
        if let b = base, let s = session {
            let (img, frame) = CardDrag.hinted(b.image, frame: b.frame, hint: h, flipped: b.view.isFlipped)
            s.enumerateDraggingItems(options: [], for: b.view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, i, _ in
                if i == 0 { item.setDraggingFrame(frame, contents: img) }
            }
        }
        let text: String? = h.map { CardDrag.hintText($0) }
        emit(["event": "voice_drag_hint", "n": shot.n, "hint": text ?? NSNull(), "pid": Int(t?.pid ?? 0), "bundle": t?.bundleID ?? NSNull()])
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
                                                                         .foregroundColor: NSColor.white])
        let icon = NSImage(systemSymbolName: "text.insert", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.white])))
        let pillH: CGFloat = 24, gap: CGFloat = 6
        let pillW = ceil(text.size().width) + 20 + (icon != nil ? 18 : 0)
        let w = max(frame.width, pillW), hgt = frame.height + gap + pillH
        let img = NSImage(size: NSSize(width: w, height: hgt), flipped: false) { _ in
            card.draw(in: NSRect(x: (w - frame.width) / 2, y: pillH + gap, width: frame.width, height: frame.height))
            let pill = NSRect(x: (w - pillW) / 2, y: 0, width: pillW, height: pillH)
            NSColor(white: 0, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: pill.offsetBy(dx: 0, dy: -1), xRadius: pillH / 2, yRadius: pillH / 2).fill()
            accent.setFill()
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
        target = t
        // the same layout for another class (chat ↔ finder): no rewrite
        guard layout(t.cls) != layout(written), let pb = session?.draggingPasteboard else {
            if t.cls != written { written = t.cls }
            if changedApp { report("card_drag_target") }
            return
        }
        written = t.cls
        pb.clearContents()
        let ok = pb.writeObjects(pasteboardItems())
        report("card_drag_target", ["rewritten": ok])
    }

    /// The drag ended at `p` over another app: the class of what it got, if we know it (nil: it read the pasteboard
    /// written for another kind of app). `noteFile`: the .md was among it.
    func delivered(at p: NSPoint) -> DropClass? {
        let t = DropProbe.target(at: p)
        let got: DropClass? = t.flatMap { layout($0.cls) == layout(written) ? $0.cls : nil }
        emit(["event": "card_drag_end", "n": shot.n, "bundle": t?.bundleID ?? NSNull(), "class": t?.cls.rawValue ?? NSNull(),
              "kind": t?.kind.rawValue ?? NSNull(), "written": written.rawValue, "delivered": got?.rawValue ?? NSNull(),
              "note_file": got.map(noteFile(_:)) ?? false])
        return got
    }

    /// A voice card let go of over a window whose app gets the words pasted (VoiceCardDrop.pastes) — whether or not
    /// the app took the drop: that app.
    func voiceTarget(at p: NSPoint) -> DropTarget? {
        guard isVoice, let t = DropProbe.target(at: p), VoiceCardDrop.pastes(cls: t.cls, kind: t.kind) else { return nil }
        return t
    }

    /// The .md is in the layout for `c`.
    func noteFile(_ c: DropClass) -> Bool { card.noteFile.map { f in layout(c).contains { $0.file == f } } ?? false }

    private func report(_ event: String, _ extra: [String: Any] = [:]) {
        var o: [String: Any] = ["event": event, "n": shot.n, "pid": Int(target?.pid ?? 0), "bundle": target?.bundleID ?? NSNull(),
                                "class": target?.cls.rawValue ?? NSNull(), "written": written.rawValue,
                                "items": layout(written).map { CardDrag.types($0, tag: tag != nil).map(\.rawValue) }]
        for (k, v) in extra { o[k] = v }
        emit(o)
    }

    // MARK: NSPasteboardItemDataProvider

    /// An app asks for one of an item's types: answer for the app under the pointer now. That is the class this
    /// pasteboard was written for, unless the pointer has just crossed into another kind of app before moved(to:) saw
    /// it — then that app's layout, as far as this item's declared types go.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let i = index[ObjectIdentifier(item)] else { return }
        let now = DropProbe.target()?.cls ?? written
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
        emit(["event": "card_drag_provide", "n": shot.n, "item": i + 1, "type": type.rawValue, "class": now.rawValue,
              "written": written.rawValue, "given": given])
    }
}
