// Settings → Shortcuts (and, in a build without the Settings window, the Shortcuts window from the menu): the same
// page of rows as every other pane (SettingsKit; rows from SettingsCatalog, "shortcuts.<action>"), every row one even
// height (SettingsMetrics.evenRow) — the action on the left, its shortcut on the right as small keycaps that are the
// recorder: click (or Tab to it and press Space) and it listens. Four short sections (SettingsCatalog.shortcutSections):
// Capture (record, snap, voice note), While recording (pause, marker, the pen — its hold key, record.draw_key, is the
// pen row's second line, a menu), Dictation (its key, set in Settings → Dictation, where its row's link leads; reformat)
// and Open and switch (project, cards, the menu-bar menu, the main window). Restore Defaults closes the page.
//
// One cause is said once: keys another running Blurt holds (HotkeyResult.taken — every one of them, when the user's
// own Blurt is running beside this one) are one banner under the page's title, with how many, where that copy runs
// from and Quit Other Copy; each row it touches only gets the small "!" before its keycaps (the tooltip says why). A
// conflict of the row's own (a macOS shortcut, the same keys as another action, a key macOS refused, a hand-edited
// config.json) keeps its line under the action's name, in attention ink, besides the "!".
//
// ⌥⇧R starts a recording and also finishes one; ⌥⇧S only finishes — it is the key a recording started from the
// chat (no menu-bar app) listens to, so it stays, listed under While recording as "Finish recording".
//
// What the recorder refuses, with the reason under the action's name: a key without ⌃ / ⌥ / ⌘, ⌘ / ⇧⌘ with a typing
// key (⌘C is Copy in every app: KeyCombo.reserved) and a macOS system shortcut. Keys another action has ask first — a
// sheet on this window: "Swap" exchanges the two actions' keys, or, when this one had none, "Move Here" moves them
// and leaves the other without — never a silent duplicate. Every change (set, clear, swap, restore) can be undone
// with ⌘Z. The recorder works from the keyboard: Tab reaches it (focus ring), Space or Return starts recording,
// Delete clears it.

import AppKit
import BlurtCore
import Carbon.HIToolbox
import SwiftUI

/// Keycaps: one small rounded grey chip per key, in Apple's order (⌃ ⌥ ⇧ ⌘ then the key), right-aligned — the
/// recorder's resting look and the dictation key's read-only one.
enum Keycaps {
    static let height: CGFloat = 20
    static let gap: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// "⌥⇧R" → ["⌥", "⇧", "R"]; a named key ("Space", "F5") stays whole.
    static func keys(_ s: Shortcut) -> [String] {
        var k: [String] = []
        if s.mods & controlKey != 0 { k.append("⌃") }
        if s.mods & optionKey != 0 { k.append("⌥") }
        if s.mods & shiftKey != 0 { k.append("⇧") }
        if s.mods & cmdKey != 0 { k.append("⌘") }
        return k + [hotkeyKeyTable.first { $0.name == s.key }?.glyph ?? s.key]
    }

    static func width(_ key: String) -> CGFloat {
        let w = (key as NSString).size(withAttributes: [.font: font]).width
        return max(height, ceil(w) + 10)
    }
    static func width(_ keys: [String]) -> CGFloat {
        keys.isEmpty ? 0 : keys.map(width).reduce(0, +) + gap * CGFloat(keys.count - 1)
    }

    /// Draws `keys` ending at `maxX`, centred on `midY`; returns where they start.
    @discardableResult
    static func draw(_ keys: [String], maxX: CGFloat, midY: CGFloat, ink: NSColor = .secondaryLabelColor,
                     fill: NSColor = NSColor.labelColor.withAlphaComponent(0.07)) -> CGFloat {
        var x = maxX - width(keys)
        let start = x
        for k in keys {
            let w = width(k)
            let r = NSRect(x: x, y: midY - height / 2, width: w, height: height)
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            let a = NSAttributedString(string: k, attributes: [.font: font, .foregroundColor: ink])
            let sz = a.size()
            a.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            x += w + gap
        }
        return start
    }

    /// The attention disc with its "!" (StatusDot .warn, §1.5's shape twin), `d` across, centred at (midX, midY).
    static func drawWarn(midX: CGFloat, midY: CGFloat, d: CGFloat = 12) {
        let r = NSRect(x: midX - d / 2, y: midY - d / 2, width: d, height: d)
        BrandColor.attn.setFill()
        NSBezierPath(ovalIn: r).fill()
        BrandColor.onAttn.setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        // flipped = false: y grows upwards — the bar above, the dot below
        p.move(to: NSPoint(x: r.midX, y: r.maxY - d * 0.25)); p.line(to: NSPoint(x: r.midX, y: r.midY - d * 0.06))
        p.move(to: NSPoint(x: r.midX, y: r.minY + d * 0.25)); p.line(to: NSPoint(x: r.midX, y: r.minY + d * 0.255))
        p.stroke()
    }
}

/// A shortcut, and its recorder. At rest: the keycaps alone, right-aligned (an unset one says "Record Shortcut" in
/// secondary ink), with the attention "!" before them while it doesn't work here. Pointer over it (or keyboard focus):
/// a faint ground behind them and the × that turns it off. Clicked (or Space / Return): it listens — a brand-ink ring
/// on the brand tint across the whole cell (§3.4), "Type shortcut…" and an Esc keycap; the modifiers held so far show
/// as keycaps. Esc cancels, ⌫ turns the shortcut off. Global hotkeys are suspended meanwhile, or pressing the current
/// one would fire it instead of being recorded. The whole cell is the click target.
final class ShortcutField: NSView {
    let action: HotAction
    var onSet: ((Shortcut?) -> Void)?
    /// a refusal's reason, for the line under the action's name (nil: clear it)
    var onRefuse: ((String?) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    var live = ""                       // modifiers held while recording
    /// it doesn't work here (another Blurt holds it, or a conflict of its own): the "!" before the keycaps
    var warn = false { didSet { if warn != oldValue { needsDisplay = true } } }
    var monitor: Any?
    var refuse: String?                 // "needs ⌃ / ⌥ / ⌘" flash
    /// the last refusal (tests read it)
    private(set) var lastRefusal: String?
    private var refuseGeneration = 0
    private(set) var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    static let size = NSSize(width: 140, height: 24)
    static let clearWidth: CGFloat = 20

    init(_ a: HotAction) {
        action = a
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityRole(.button)
        setAccessibilityLabel(a.title)
        setAccessibilityHelp(Loc.t("capture.keys.field_ax_hint", table: "Capture"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func accessibilityValue() -> Any? { Hotkeys.shared.shortcut(action)?.label ?? Loc.t("capture.keys.record", table: "Capture") }
    override func accessibilityPerformPress() -> Bool { recording ? stop() : start(); return true }

    // the system focus ring, around what is drawn (Tab moves through the recorders)
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let r = recording ? bounds : groundRect
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
    }
    override func becomeFirstResponder() -> Bool { focused = true; noteFocusRingMaskChanged(); return true }
    override func resignFirstResponder() -> Bool {
        if recording { stop() }
        focused = false
        noteFocusRingMaskChanged()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Tests: the pointer over it, for a screenshot of the hover state.
    func testHover(_ on: Bool) { hovering = on }

    /// Not recording: Space / Return start, Delete clears; anything else (Tab) goes on as usual.
    override func keyDown(with e: NSEvent) {
        guard !recording else { return }
        let code = Int(e.keyCode)
        guard Shortcut.carbonMods(e.modifierFlags) == 0 else { return super.keyDown(with: e) }
        if [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(code) { start() }
        else if [kVK_Delete, kVK_ForwardDelete].contains(code) {
            if Hotkeys.shared.shortcut(action) != nil { onSet?(nil) } else { NSSound.beep() }
        } else { super.keyDown(with: e) }
    }

    /// The × at the right end: under the pointer or with keyboard focus, while there is a shortcut to turn off.
    private var clearRect: NSRect? {
        guard !recording, hovering || focused, Hotkeys.shared.shortcut(action) != nil else { return nil }
        return NSRect(x: bounds.maxX - Self.clearWidth, y: 0, width: Self.clearWidth, height: bounds.height)
    }

    /// What rests in the cell, right to left: the × (when shown), the keycaps or "Record Shortcut", the "!".
    private var restingKeys: [String]? { Hotkeys.shared.shortcut(action).map(Keycaps.keys) }
    private var placeholder: NSAttributedString {
        NSAttributedString(string: Loc.t("capture.keys.record", table: "Capture"),
                           attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
    private var contentMaxX: CGFloat { bounds.maxX - (clearRect == nil ? 6 : Self.clearWidth + 2) }
    private var contentWidth: CGFloat { restingKeys.map(Keycaps.width) ?? ceil(placeholder.size().width) }
    private static let warnD: CGFloat = 12
    /// The faint ground under the pointer: hugs what is drawn, not the whole cell.
    private var groundRect: NSRect {
        let minX = contentMaxX - contentWidth - 6 - (warn ? Self.warnD + 6 : 0)
        return NSRect(x: max(0, minX), y: 0, width: bounds.maxX - max(0, minX), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        if recording {
            // listening for keys: brand ink on the brand tint (§3.4), the whole cell
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            BrandColor.tint.setFill(); path.fill()
            BrandColor.ink.setStroke(); path.lineWidth = 1.5; path.stroke()
            if let r = refuse {
                let a = NSAttributedString(string: r, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                   .foregroundColor: BrandColor.attnInk])
                let sz = a.size()
                a.draw(at: NSPoint(x: max(6, bounds.maxX - 8 - sz.width), y: midY - sz.height / 2))
            } else if !live.isEmpty {
                Keycaps.draw(live.map(String.init), maxX: bounds.maxX - 4, midY: midY, ink: BrandColor.ink,
                             fill: BrandColor.ink.withAlphaComponent(0.12))
            } else {
                // "Type shortcut…  [esc]": what to do, and the way out
                let x = Keycaps.draw(["esc"], maxX: bounds.maxX - 4, midY: midY, ink: BrandColor.ink, fill: BrandColor.ink.withAlphaComponent(0.12))
                let a = NSAttributedString(string: Loc.t("capture.keys.type", table: "Capture"),
                                           attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: BrandColor.ink])
                let sz = a.size()
                a.draw(at: NSPoint(x: max(6, x - 6 - sz.width), y: midY - sz.height / 2))
            }
            return
        }
        if hovering || focused {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: groundRect, xRadius: 6, yRadius: 6).fill()
        }
        let start: CGFloat
        if let k = restingKeys {
            start = Keycaps.draw(k, maxX: contentMaxX, midY: midY)
        } else {
            let a = placeholder, sz = a.size()
            start = contentMaxX - ceil(sz.width)
            a.draw(at: NSPoint(x: start, y: midY - sz.height / 2))
        }
        if warn { Keycaps.drawWarn(midX: start - 6 - Self.warnD / 2, midY: midY, d: Self.warnD) }
        if let c = clearRect, let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            x.draw(in: NSRect(x: c.midX - x.size.width / 2 - 1, y: c.midY - x.size.height / 2, width: x.size.width, height: x.size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let c = clearRect, c.contains(convert(event.locationInWindow, from: nil)) { onSet?(nil); return }
        recording ? stop() : start()
    }

    func start() {
        ShortcutField.active?.stop()
        ShortcutField.active = self
        recording = true
        live = ""
        Hotkeys.shared.suspended = true
        window?.makeFirstResponder(self)
        noteFocusRingMaskChanged()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] e in
            guard let self = self else { return e }
            switch e.type {
            case .flagsChanged:
                self.live = Shortcut(mods: Shortcut.carbonMods(e.modifierFlags), key: "A")?.label.dropLast().description ?? ""
                self.needsDisplay = true
                return nil
            case .keyDown:
                self.key(e)
                return nil
            default:
                if e.window != self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) { self.stop() }
                return e
            }
        }
    }

    func key(_ e: NSEvent) {
        let mods = Shortcut.carbonMods(e.modifierFlags)
        if Int(e.keyCode) == kVK_Escape && mods == 0 { stop(); return }
        if (Int(e.keyCode) == kVK_Delete || Int(e.keyCode) == kVK_ForwardDelete) && mods == 0 { stop(); onSet?(nil); return }
        guard let s = Shortcut(mods: mods, code: Int(e.keyCode)) else { flash(Loc.t("capture.keys.bad_key", table: "Capture")); return }
        guard s.isAcceptable else { flash(Loc.t("capture.keys.needs_mod", table: "Capture")); return }
        // a macOS shortcut would go to macOS (⇧⌘3 is the screenshot, named as macOS's — checked first); ⌘C would take
        // Copy away from every app: say why, keep listening
        if Hotkeys.shared.systemShortcuts().contains(s) {
            flash(Loc.t("capture.keys.system_short", table: "Capture"), reason: Loc.t("capture.keys.system_refused", table: "Capture", s.label))
            return
        }
        if let r = s.reserved { flash(r.short(s), reason: r.reason(s)); return }
        stop()
        onSet?(s)
    }

    /// A refusal: a short word inside the field for a moment, the whole reason under the action's name a while longer.
    func flash(_ msg: String, reason: String? = nil) {
        NSSound.beep()
        refuse = msg
        lastRefusal = reason ?? msg
        refuseGeneration += 1
        let g = refuseGeneration
        needsDisplay = true
        if let r = reason { onRefuse?(r) }
        emit(["event": "shortcut_refused", "action": action.rawValue, "why": reason ?? msg])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.refuse = nil; self?.needsDisplay = true }
        if reason != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self = self, self.refuseGeneration == g else { return }
                self.onRefuse?(nil)
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        if ShortcutField.active === self { ShortcutField.active = nil }
        Hotkeys.shared.suspended = false
        noteFocusRingMaskChanged()
    }

    static weak var active: ShortcutField?
}

/// A ShortcutField in a SwiftUI form. The field registers itself in HotkeySettings.fields (the test hooks press it).
struct ShortcutRecorder: NSViewRepresentable {
    let action: HotAction
    @ObservedObject var model: HotkeySettings

    func makeNSView(context: Context) -> ShortcutField {
        let f = ShortcutField(action)
        f.onSet = { [weak model, weak f] s in model?.set(s, for: action, window: f?.window) }
        f.onRefuse = { [weak model] why in model?.refusals[action] = why }
        model.fields[action] = f
        return f
    }
    func updateNSView(_ f: ShortcutField, context: Context) {
        let note = model.note(action)
        f.warn = note?.mark == true
        // why it doesn't work, or how the recorder works
        f.toolTip = note?.mark == true ? note?.text : Loc.t("capture.keys.field_help", table: "Capture")
        f.setAccessibilityHelp(note?.mark == true ? note?.text : Loc.t("capture.keys.field_ax_hint", table: "Capture"))
        f.needsDisplay = true
    }
    /// Its own size, so the row stays one line high with the recorder beside the name.
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutField, context: Context) -> CGSize? { ShortcutField.size }
}

/// Read-only keycaps (the dictation key: set in Settings → Dictation), drawn like the recorder's resting ones.
struct KeycapsView: View {
    var keys: [String]
    var body: some View {
        HStack(spacing: Keycaps.gap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: Keycaps.height, minHeight: Keycaps.height)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The pens's hold key, as the pen row's second line: "Or hold ⌃ Control to draw" in secondary ink; the pointer over it
/// shows that it opens a menu (Control, Option, fn, Off).
struct HoldKeyLine: View {
    @ObservedObject var m: HotkeySettings
    @State private var hover = false

    static let choices = ["control", "option", "fn", "off"]
    static func name(_ k: String) -> String {
        switch k {
        case "option": return Loc.t("capture.keys.option", table: "Capture")
        case "fn": return Loc.t("capture.keys.fn", table: "Capture")
        case "off": return Loc.t("capture.keys.off", table: "Capture")
        default: return Loc.t("capture.keys.control", table: "Capture")
        }
    }

    var body: some View {
        let line = m.drawKey == "off" ? Loc.t("capture.keys.hold_off", table: "Capture")
            : Loc.t("capture.keys.hold_line", table: "Capture", Self.name(m.drawKey))
        Button(action: pop) {
            HStack(spacing: 3) {
                Text(line).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .opacity(hover ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(Loc.t("capture.keys.hold_draw", table: "Capture"))
        .accessibilityLabel(Loc.t("capture.keys.hold_draw", table: "Capture"))
        .accessibilityValue(m.drawKey == "off" ? Self.name("off") : Self.name(m.drawKey))
    }

    private func pop() {
        let menu = NSMenu()
        for k in Self.choices {
            let i = NSMenuItem(title: Self.name(k), action: #selector(HotkeySettings.pickDrawKey(_:)), keyEquivalent: "")
            i.target = m
            i.representedObject = k
            i.state = m.drawKey == k ? .on : .off
            if k == "off" { menu.addItem(.separator()) }
            menu.addItem(i)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The pane's state: it redraws when a binding or a conflict changes (Hotkeys.onChange) and keeps the fields for the
/// test hooks. Also the standalone Shortcuts window (no Settings window in that build).
final class HotkeySettings: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HotkeySettings()
    var window: NSWindow?
    /// The recorder fields on screen now, by action (`shortcut` / `recordkey` test hooks).
    var fields: [HotAction: ShortcutField] = [:]
    /// The window the pane shows in: Settings, or the standalone one in a build without it.
    var shortcutsWindow: NSWindow? { fields.values.compactMap(\.window).first ?? window }
    @Published var drawKey = "control"
    /// why the field just refused a key ("⌘C is Copy in every app — add ⌥ or ⌃"), shown under the action's name
    @Published var refusals: [HotAction: String] = [:]
    /// Quit Other Copy was pressed: the banner's button waits for that copy to go
    @Published var quitting = false
    /// the swap question on screen (tests answer it: `shortcutswap yes|no`)
    private(set) var asking: NSAlert?

    /// A field's new keys. Keys another action has: ask on this window whether to swap — never a silent duplicate.
    /// Every change can be undone (⌘Z): the whole record.hotkeys as it was comes back.
    func set(_ s: Shortcut?, for a: HotAction, window: NSWindow?) {
        refusals[a] = nil
        guard s != Hotkeys.shared.shortcut(a) || Hotkeys.shared.states[a]?.isConflict == true else { return }
        if let s = s, let other = Hotkeys.shared.owner(of: s, except: a) {
            return askSwap(s, to: a, from: other, window: window)
        }
        change(window) { Hotkeys.shared.set(s, for: a) }
        emit(["event": "shortcut_set", "action": a.rawValue, "now": s?.spec ?? "off"])
    }

    private func askSwap(_ s: Shortcut, to a: HotAction, from other: HotAction, window: NSWindow?) {
        let alert = NSAlert()
        // an exchange when this action has keys to give; otherwise the keys move here and the other one has none
        let mine = Hotkeys.shared.shortcut(a).flatMap { $0.reserved == nil ? $0 : nil }
        alert.messageText = Loc.t("capture.keys.swap.title", table: "Capture", s.label, other.title)
        alert.informativeText = mine.map { Loc.t("capture.keys.swap.detail", table: "Capture", a.title, s.label, other.title, $0.label) }
            ?? Loc.t("capture.keys.move.detail", table: "Capture", a.title, s.label, other.title)
        alert.addButton(withTitle: Loc.t(mine == nil ? "capture.keys.move.ok" : "capture.keys.swap.ok", table: "Capture"))
        alert.addButton(withTitle: Loc.t("capture.keys.swap.cancel", table: "Capture"))
        asking = alert
        emit(["event": "shortcut_swap_ask", "action": a.rawValue, "keys": s.spec, "other": other.rawValue])
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self = self else { return }
            self.asking = nil
            let yes = r == .alertFirstButtonReturn
            emit(["event": "shortcut_swap", "action": a.rawValue, "other": other.rawValue, "swapped": yes])
            if yes { self.change(window) { Hotkeys.shared.swap(s, to: a) } }
            self.refresh()
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Tests: answer the swap question as its buttons would.
    func testAnswerSwap(_ yes: Bool) {
        guard let a = asking, let w = a.window.sheetParent else { return }
        w.endSheet(a.window, returnCode: yes ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    /// Runs `apply`, with undo (⌘Z) back to record.hotkeys as it was before.
    private func change(_ window: NSWindow?, _ apply: () -> Void) {
        let before = Config.shared["record.hotkeys"]
        apply()
        registerUndo(window?.undoManager, restoring: before)
        refresh()
    }

    private func registerUndo(_ um: UndoManager?, restoring config: Any?) {
        guard let um = um else { return }
        let now = Config.shared["record.hotkeys"]
        um.registerUndo(withTarget: self) { me in
            me.restoreConfig(config)
            me.registerUndo(um, restoring: now)       // redo
        }
        um.setActionName(Loc.t("capture.keys.undo_set", table: "Capture"))
    }

    private func restoreConfig(_ c: Any?) {
        ShortcutField.active?.stop()
        Config.shared.set("record.hotkeys", c)
        Hotkeys.shared.load()
        Hotkeys.shared.apply()
        emit(["event": "shortcut_undo"])
        refresh()
    }

    override init() {
        super.init()
        Hotkeys.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        drawKey = recordConfig()["draw_key"] as? String ?? "control"
        if quitting && others.isEmpty { quitting = false }
        objectWillChange.send()
    }

    /// Settings → Shortcuts — the one place to change keys. The standalone window is only for a build without the
    /// Settings window (there it is the same pane).
    func show() {
        if let s = AppEnvironment.settings {
            s.show(pane: SettingsPane.shortcuts.rawValue)
            return
        }
        if window == nil {
            let host = NSHostingController(rootView: ShortcutsPane())
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 620, height: 640))
            w.title = Loc.t("capture.keys.title", table: "Capture")
            w.isReleasedWhenClosed = false
            w.delegate = self
            // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
            window = w
        }
        refresh()
        activateApp()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Why an action doesn't work here, or nothing. `mark`: the "!" before its keycaps (it doesn't work); `line`: said
    /// under the action's name too — everything but another Blurt's keys, which the page's banner says once for all.
    struct Note { var text: String; var mark: Bool; var line: Bool }

    func note(_ a: HotAction) -> Note? {
        let hk = Hotkeys.shared
        if let why = refusals[a] { return Note(text: why, mark: false, line: true) }
        if let bad = hk.invalid[a] { return Note(text: Loc.t("capture.keys.unreadable", table: "Capture", bad), mark: true, line: true) }
        let st = hk.states[a] ?? .ok
        if case .taken = st { return Note(text: st.text, mark: true, line: false) }
        if st == .reserved, let s = hk.shortcut(a), let r = s.reserved { return Note(text: r.reason(s), mark: true, line: true) }
        if st.isConflict { return Note(text: st.text, mark: true, line: true) }
        if st == .notHere { return Note(text: Loc.t("capture.keys.menu_bar_only", table: "Capture"), mark: false, line: true) }
        return nil
    }

    // MARK: another Blurt

    /// The actions on the page another running Blurt holds (HotkeyResult.taken), and the dictation key when another
    /// copy listens to it.
    var takenActions: [HotAction] {
        HotAction.allCases.filter { a in
            guard !Hotkeys.shared.disabled.contains(a), case .taken = Hotkeys.shared.states[a] ?? .ok else { return false }
            return true
        }
    }
    var dictationTaken: Bool { AppEnvironment.settings != nil && Dictation.shared.deferredTo != nil }
    /// How many shortcuts on the page another copy holds.
    var takenCount: Int { takenActions.count + (dictationTaken ? 1 : 0) }

    /// The other copies holding them, by pid.
    var others: [pid_t] {
        var p: [pid_t] = takenActions.compactMap { if case .taken(let pid) = Hotkeys.shared.states[$0] ?? .ok { return pid } else { return nil } }
        if let d = Dictation.shared.deferredTo, dictationTaken { p.append(d) }
        var seen = Set<pid_t>()
        return p.filter { seen.insert($0).inserted }
    }
    /// The running apps among them (the button can only quit an app).
    var otherApps: [NSRunningApplication] { others.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isTerminated } }

    /// Where the other copy runs from, "~/Applications" (one copy that is an app; nil otherwise).
    var otherLocation: String? {
        let apps = otherApps
        guard apps.count == 1, let u = apps[0].bundleURL else { return nil }
        // a deep folder (a build somewhere under the project) by its last part, so the banner keeps to two lines
        let dir = u.deletingLastPathComponent()
        let p = (dir.path as NSString).abbreviatingWithTildeInPath
        return p.count <= 32 ? p : "…/" + dir.lastPathComponent
    }

    /// Quit Other Copy: an ordinary quit (that copy finishes or asks as it would from its own menu); the keys come over
    /// here when it has gone (Hotkeys applies again when an instance quits).
    func quitOthers() {
        let apps = otherApps
        emit(["event": "shortcut_quit_other", "pids": apps.map { Int($0.processIdentifier) }])
        guard !apps.isEmpty else { return }
        quitting = true
        apps.forEach { $0.terminate() }
        // it may ask first (a recording in progress) or refuse: the button comes back
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.quitting = false }
    }

    func setDrawKey(_ k: String) {
        drawKey = k
        setRecordConfig("draw_key", k == "control" ? nil : k)
        emit(["event": "draw_key_set", "key": k])
    }

    @objc func pickDrawKey(_ sender: NSMenuItem) {
        if let k = sender.representedObject as? String { setDrawKey(k) }
    }

    func restore() {
        ShortcutField.active?.stop()
        refusals = [:]
        change(fields.values.compactMap(\.window).first ?? window) { Hotkeys.shared.restoreDefaults() }
        emit(["event": "shortcut_restore"])
    }

    @objc func openDictation() {
        ShortcutField.active?.stop()
        AppEnvironment.settings?.show(pane: "dictation")
    }

    func windowWillClose(_ notification: Notification) { ShortcutField.active?.stop() }
}

struct ShortcutsPane: View {
    @ObservedObject var m = HotkeySettings.shared

    var body: some View {
        SettingsPage(.shortcuts) {
            if m.takenCount > 0 { banner.padding(.top, 18) }

            SettingsGroup("shortcuts.capture") {
                ForEach([HotAction.toggleRecord, .snap, .voice], id: \.self) { row($0) }
            }
            SettingsGroup("shortcuts.recording") {
                ForEach([HotAction.pause, .marker, .pen, .finish], id: \.self) { row($0) }
            }
            if AppEnvironment.settings != nil {
                SettingsGroup("shortcuts.dictation") {
                    dictationRow
                    row(.reformat)          // ⌥⇧L: the last dictation in another style
                }
            }
            SettingsGroup("shortcuts.open") {
                ForEach([HotAction.project, .cards, .openMenu] + (AppEnvironment.mainWindow == nil ? [] : [.openMain]), id: \.self) { row($0) }
            }

            SettingsPageButton("shortcuts.restore", title: Loc.t("capture.keys.restore", table: "Capture"),
                               help: Loc.t("capture.keys.restore.help", table: "Capture")) { m.restore() }
        }
        .onAppear { m.refresh() }
        .onDisappear { ShortcutField.active?.stop() }
    }

    /// Another running Blurt holds some of the keys: said once, with the way to free them.
    var banner: some View {
        let n = m.takenCount
        // usually one: the user's own Blurt beside a second one (a dev build, a copy opened twice)
        let many = m.others.count > 1
        let detail = many ? Loc.t("capture.keys.taken_banner.detail_many", table: "Capture")
            : m.otherLocation.map { Loc.t("capture.keys.taken_banner.detail", table: "Capture", $0) }
                ?? Loc.t("capture.keys.taken_banner.detail_unknown", table: "Capture")
        return AttentionBanner(title: Loc.plural(many ? "capture.keys.taken_banner_many" : "capture.keys.taken_banner", table: "Capture", count: n),
                               detail: detail) {
            if !m.otherApps.isEmpty {
                Button(m.quitting ? Loc.t("capture.keys.quitting", table: "Capture")
                       : Loc.t(m.otherApps.count > 1 ? "capture.keys.quit_others" : "capture.keys.quit_other", table: "Capture")) {
                    m.quitOthers()
                }
                .disabled(m.quitting)
            }
        }
        .id("shortcuts.taken")
    }

    /// An action: its name (and, for a conflict of its own, why — in attention ink; its description otherwise) on the
    /// left, its keycaps on the right. The pen's row says its hold key on its second line.
    func row(_ a: HotAction) -> some View {
        let note = m.note(a)
        let line = note?.line == true ? note : nil
        return SettingRow("shortcuts.\(a.rawValue)", title: a.title, detail: line?.text,
                          detailColor: line?.mark == true || m.refusals[a] != nil ? Color.brandAttnInk : nil,
                          height: SettingsMetrics.evenRow,
                          detailContent: a == .pen && line == nil ? AnyView(HoldKeyLine(m: m)) : nil) {
            ShortcutRecorder(action: a, model: m)
                .frame(width: ShortcutField.size.width, height: ShortcutField.size.height)
        }
    }

    /// Dictation's key: set in Settings → Dictation; shown here as read-only keycaps, with the way there.
    var dictationRow: some View {
        // "Tap or hold · double-tap to send": the double tap presses Return, so it is said wherever the key is
        let mode = Loc.t("dictation.mode.\(Dictation.mode.rawValue)", table: "Dictation")
        let taken = m.dictationTaken
        return SettingRow("shortcuts.dictation_key",
                          detail: Dictation.enabled ? (Dictation.doubleTapSend ? mode + " · " + Loc.t("dictation.mode.send_suffix", table: "Dictation") : mode) : nil,
                          height: SettingsMetrics.evenRow) {
            HStack(spacing: 12) {
                // a text button in brand ink (§3.3 links), not the system's blue
                Button(Loc.t("capture.keys.dictation_change", table: "Capture")) { m.openDictation() }
                    .buttonStyle(.plain)
                    .font(.system(size: SettingsMetrics.detailSize))
                    .foregroundStyle(Color.brandInk)
                HStack(spacing: 6) {
                    if taken {
                        StatusDot(tone: .warn, diameter: 12)
                            .help(Loc.t("dictation.status.other_instance", table: "Dictation"))
                    }
                    if Dictation.enabled {
                        KeycapsView(keys: [Dictation.keyName])
                    } else {
                        Text(Loc.t("capture.keys.off", table: "Capture")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 6)          // the recorders' keycaps end 6 pt in from the cell's edge
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Loc.t("dictation.settings.tab", table: "Dictation"))
            }
        }
    }
}
