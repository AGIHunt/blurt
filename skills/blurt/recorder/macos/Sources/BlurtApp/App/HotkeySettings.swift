// Settings → Shortcuts (and, in a build without the Settings window, the Shortcuts window from the menu): the same
// page of rows as every other pane (SettingsKit; rows from SettingsCatalog, "shortcuts.<action>") — the action on the
// left, its shortcut on the right as small keycaps that are the recorder: click (or Tab to it and press Space) and it
// listens. Four short sections (SettingsCatalog.shortcutSections):
// Capture (record, snap, voice note), While recording (pause, marker, the pen — its hold key, record.draw_key, is the
// pen row's second line, a menu), Dictation (its key, set in Settings → Dictation, where its row's link leads; reformat)
// and Open and switch (project, cards, the menu-bar menu, the main window). Restore Defaults closes the page.
//
// One cause is said once: keys another running Blurt holds (HotkeyResult.taken — every one of them, when the user's
// own Blurt is running beside this one) are one notice above the first section, with how many, where that copy runs
// from and Quit Other Copy; the rows it touches show the small "!" before their keycaps (the tooltip says why) and no
// line of their own. A conflict of the row's own (a macOS shortcut, the same keys as another action, a key macOS
// refused, a hand-edited config.json) has the same "!" and its line under the action's name, in attention ink. Keycaps
// keep their ink in every case: a key that doesn't work is marked, never faded.
//
// ⌥⇧R starts a recording and also finishes one; ⌥⇧S only finishes — it is the key a recording started from the
// chat (no menu-bar app) listens to, so it stays, listed under While recording as "Finish recording".
//
// What the recorder refuses, with the reason under the action's name: a key without ⌃ / ⌥ / ⌘, ⌘ / ⇧⌘ with a typing
// key (⌘C is Copy in every app: KeyCombo.reserved) and a macOS system shortcut. Keys another action has ask first, in
// the row itself, no sheet: the new keys stay in the recorder (brand ink on the tint), the row's second line asks
// "Swap with Voice note?" with Swap and Cancel (Return / Esc), the other action's keycaps get the "!" meanwhile —
// Swap exchanges the two actions' keys, or, when this one had none, Move takes them and leaves the other without;
// never a silent duplicate. Every change (set, clear, swap, restore) can be undone with ⌘Z. The recorder works from the keyboard: Tab reaches it (focus ring), Space or Return starts recording,
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

    /// The keys' ink at rest: `ink-2` (70 %), never under `mute` (system.md §2.4: shortcut hints are read) — a key that
    /// doesn't work here says so with the "!" disc beside it, never by fading.
    static var ink: NSColor { NSColor.labelColor.withAlphaComponent(0.7) }
    static let inkSwiftUI = Color.primary.opacity(0.7)

    /// Draws `keys` ending at `maxX`, centred on `midY`; returns where they start.
    @discardableResult
    static func draw(_ keys: [String], maxX: CGFloat, midY: CGFloat, ink: NSColor = Keycaps.ink,
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

/// A shortcut, and its recorder: one fixed-width well (Self.size) in every state, so a row never changes width. At rest:
/// the keycaps alone, flush with the row's trailing edge, with the attention "!" before them while it doesn't work here
/// (whatever the reason: the same keys elsewhere, macOS's own, another copy of Blurt — never faded caps). Unset: the
/// quiet well itself, "Record Shortcut" in it. Pointer over it (or keyboard focus): the well's faint ground and, before
/// the keycaps, the × that turns it off. Clicked (or Space / Return): it listens — a brand-ink ring on the brand tint
/// across the well (§3.4), "Type shortcut…" and an Esc keycap, centred; the modifiers held so far show as keycaps. Esc
/// cancels, ⌫ turns the shortcut off. Global hotkeys are suspended meanwhile, or pressing the current one would fire it
/// instead of being recorded. The whole well is the click target.
final class ShortcutField: NSView {
    let action: HotAction
    var onSet: ((Shortcut?) -> Void)?
    /// the row's swap question answered from the keyboard (Return: yes, Esc: no)
    var onAnswer: ((Bool) -> Void)?
    /// a refusal's reason, for the line under the action's name (nil: clear it)
    var onRefuse: ((String?) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    var live = ""                       // modifiers held while recording
    /// it doesn't work here (a conflict of its own, another copy of Blurt holding it, or the keys another row asks to
    /// swap for): the "!" before the keycaps, which keep their ink
    var warn = false { didSet { if warn != oldValue { needsDisplay = true } } }
    /// keys another action has, waiting for the row's Swap / Cancel: shown in brand ink on the tint, as while listening
    var pending: [String]? { didSet { if pending != oldValue { needsDisplay = true } } }
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
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
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

    /// Not recording: Space / Return start, Delete clears; anything else (Tab) goes on as usual. With a swap waiting
    /// in the row: Return swaps, Esc cancels.
    override func keyDown(with e: NSEvent) {
        guard !recording else { return }
        let code = Int(e.keyCode)
        guard Shortcut.carbonMods(e.modifierFlags) == 0 else { return super.keyDown(with: e) }
        if pending != nil {
            if [kVK_Return, kVK_ANSI_KeypadEnter].contains(code) { onAnswer?(true); return }
            if code == kVK_Escape { onAnswer?(false); return }
        }
        if [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(code) { start() }
        else if [kVK_Delete, kVK_ForwardDelete].contains(code) {
            if Hotkeys.shared.shortcut(action) != nil { onSet?(nil) } else { NSSound.beep() }
        } else { super.keyDown(with: e) }
    }

    /// What rests in the well: the keycaps (right to left: the keys, the "!", the × under the pointer), or nothing set.
    private var restingKeys: [String]? { Hotkeys.shared.shortcut(action).map(Keycaps.keys) }
    private static let warnD: CGFloat = 12
    private static let well: CGFloat = 6
    /// Where the keycaps start (they end at the well's right edge).
    private var keysMinX: CGFloat { bounds.maxX - (restingKeys.map(Keycaps.width) ?? 0) }
    /// The × before the keycaps (and the "!"): under the pointer or with keyboard focus, while there is a shortcut to turn off.
    private var clearRect: NSRect? {
        guard !recording, pending == nil, hovering || focused, restingKeys != nil else { return nil }
        let maxX = keysMinX - 4 - (warn ? Self.warnD + 6 : 0)
        return NSRect(x: maxX - Self.clearWidth, y: 0, width: Self.clearWidth, height: bounds.height)
    }

    private func wellPath(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: Self.well, yRadius: Self.well) }

    /// "Type shortcut…  [esc]", the keys held so far, a refusal, or the keys waiting for Swap: centred in the well.
    private func drawCentred(text: String?, keys: [String], textColor: NSColor = BrandColor.ink) {
        let a = text.map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: textColor]) }
        let tw = a.map { ceil($0.size().width) } ?? 0
        let kw = Keycaps.width(keys)
        let total = tw + (a != nil && !keys.isEmpty ? 6 : 0) + kw
        let x0 = max(4, bounds.midX - total / 2)
        if let a = a { a.draw(at: NSPoint(x: x0, y: bounds.midY - a.size().height / 2)) }
        if !keys.isEmpty {
            Keycaps.draw(keys, maxX: min(bounds.maxX - 4, x0 + total), midY: bounds.midY, ink: BrandColor.ink, fill: BrandColor.ink.withAlphaComponent(0.12))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let full = bounds.insetBy(dx: 0.75, dy: 0.75)
        if recording || pending != nil {
            // listening, or keys waiting for the row's Swap / Cancel: brand ink on the brand tint (§3.4), the whole well
            let path = wellPath(full)
            BrandColor.tint.setFill(); path.fill()
            BrandColor.ink.setStroke(); path.lineWidth = 1.5; path.stroke()
            if let k = pending, !recording { drawCentred(text: nil, keys: k); return }
            if let r = refuse { drawCentred(text: r, keys: [], textColor: BrandColor.attnInk) }
            else if !live.isEmpty { drawCentred(text: nil, keys: live.map(String.init)) }
            else { drawCentred(text: Loc.t("capture.keys.type", table: "Capture"), keys: ["esc"]) }
            return
        }
        guard let k = restingKeys else {
            // nothing set: the well itself, quiet, with what a click does
            let path = wellPath(full)
            NSColor.labelColor.withAlphaComponent(hovering || focused ? 0.08 : 0.05).setFill(); path.fill()
            let a = NSAttributedString(string: Loc.t("capture.keys.record", table: "Capture"),
                                       attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            let sz = a.size()
            a.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: midY - sz.height / 2))
            if warn { Keycaps.drawWarn(midX: 6 + Self.warnD / 2, midY: midY, d: Self.warnD) }
            return
        }
        if hovering || focused {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            wellPath(full).fill()
        }
        let start = Keycaps.draw(k, maxX: bounds.maxX, midY: midY)
        if warn { Keycaps.drawWarn(midX: start - 6 - Self.warnD / 2, midY: midY, d: Self.warnD) }
        if let c = clearRect, let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            x.draw(in: NSRect(x: c.midX - x.size.width / 2, y: c.midY - x.size.height / 2, width: x.size.width, height: x.size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let c = clearRect, c.contains(convert(event.locationInWindow, from: nil)) { onSet?(nil); return }
        recording ? stop() : start()
    }

    func start() {
        ShortcutField.active?.stop()
        HotkeySettings.shared.cancelSwap()
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
        f.onAnswer = { [weak model] yes in model?.answerSwap(yes) }
        model.fields[action] = f
        return f
    }
    func updateNSView(_ f: ShortcutField, context: Context) {
        let note = model.note(action)
        f.warn = note?.mark == true
        f.pending = model.swap?.action == action ? model.swap.map { Keycaps.keys($0.keys) } : nil
        // why it doesn't work, or how the recorder works
        let why = note?.mark == true ? note?.text : nil
        f.toolTip = why ?? Loc.t("capture.keys.field_help", table: "Capture")
        f.setAccessibilityHelp(why ?? Loc.t("capture.keys.field_ax_hint", table: "Capture"))
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
                Text(k).font(.system(size: 12, weight: .medium)).foregroundStyle(Keycaps.inkSwiftUI)
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
    /// Keys another action has, waiting in the row for Swap / Cancel (`shortcutswap yes|no` answers it in tests).
    struct PendingSwap: Equatable {
        var action: HotAction
        var keys: Shortcut
        var other: HotAction
        /// what this action gives in exchange; nil: it had none, so the keys move and the other is left without
        var mine: Shortcut?
        var window: NSWindow?
    }
    @Published private(set) var swap: PendingSwap?
    /// the question as the row says it (tests)
    var asking: String? { swap.map(swapQuestion) }

    /// A field's new keys. Keys another action has: asked in the row whether to swap — never a silent duplicate, and
    /// no sheet over the list. Every change can be undone (⌘Z): the whole record.hotkeys as it was comes back.
    func set(_ s: Shortcut?, for a: HotAction, window: NSWindow?) {
        refusals[a] = nil
        swap = nil
        guard s != Hotkeys.shared.shortcut(a) || Hotkeys.shared.states[a]?.isConflict == true else { return }
        if let s = s, let other = Hotkeys.shared.owner(of: s, except: a) {
            // an exchange when this action has keys to give; otherwise the keys move here and the other one has none
            let mine = Hotkeys.shared.shortcut(a).flatMap { $0.reserved == nil ? $0 : nil }
            swap = PendingSwap(action: a, keys: s, other: other, mine: mine, window: window)
            emit(["event": "shortcut_swap_ask", "action": a.rawValue, "keys": s.spec, "other": other.rawValue])
            return
        }
        change(window) { Hotkeys.shared.set(s, for: a) }
        emit(["event": "shortcut_set", "action": a.rawValue, "now": s?.spec ?? "off"])
    }

    /// "Swap with Voice note?" / "Move ⌥⇧V from Voice note?"
    func swapQuestion(_ p: PendingSwap) -> String {
        p.mine == nil ? Loc.t("capture.keys.move.ask", table: "Capture", p.keys.label, p.other.title)
            : Loc.t("capture.keys.swap.ask", table: "Capture", p.other.title)
    }
    /// What Swap / Move does, said whole (the question's tooltip).
    func swapOutcome(_ p: PendingSwap) -> String {
        p.mine.map { Loc.t("capture.keys.swap.detail", table: "Capture", p.action.title, p.keys.label, p.other.title, $0.label) }
            ?? Loc.t("capture.keys.move.detail", table: "Capture", p.action.title, p.keys.label, p.other.title)
    }

    /// The row's Swap (or Move) / Cancel, or Return / Esc in its recorder.
    func answerSwap(_ yes: Bool) {
        guard let p = swap else { return }
        swap = nil
        emit(["event": "shortcut_swap", "action": p.action.rawValue, "other": p.other.rawValue, "swapped": yes])
        if yes { change(p.window) { Hotkeys.shared.swap(p.keys, to: p.action) } } else { refresh() }
    }

    /// Another recorder started, or the page went: the question is dropped (nothing changed).
    func cancelSwap() { if swap != nil { answerSwap(false) } }

    /// Tests: answer the swap question as its buttons would.
    func testAnswerSwap(_ yes: Bool) { answerSwap(yes) }

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

    /// Why an action doesn't work here, or nothing. `mark`: the "!" before its keycaps — one treatment for every reason,
    /// its own conflict or another copy of Blurt holding the keys (the page's notice says that one once, for all of
    /// them, so its rows have no line of their own); `line`: said under the action's name too.
    struct Note { var text: String; var mark: Bool; var line: Bool }

    /// Test builds (BLURT_TEST_SHORTCUTS_SOLO=1 with BLURT_TEST_COMMANDS): the page as on a Mac with no other copy of
    /// Blurt running — for screenshots taken beside the user's own Blurt, which holds the real keys (the keys are not
    /// registered here either way).
    static let solo = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
        && ProcessInfo.processInfo.environment["BLURT_TEST_SHORTCUTS_SOLO"] == "1"

    func note(_ a: HotAction) -> Note? {
        let hk = Hotkeys.shared
        if let why = refusals[a] { return Note(text: why, mark: false, line: true) }
        // the keys another row asks to swap for
        if let p = swap, p.other == a { return Note(text: swapOutcome(p), mark: true, line: false) }
        if let bad = hk.invalid[a] { return Note(text: Loc.t("capture.keys.unreadable", table: "Capture", bad), mark: true, line: true) }
        let st = hk.states[a] ?? .ok
        if case .taken = st { return Self.solo ? nil : Note(text: st.text, mark: true, line: false) }
        if st == .reserved, let s = hk.shortcut(a), let r = s.reserved { return Note(text: r.reason(s), mark: true, line: true) }
        if st.isConflict { return Note(text: st.text, mark: true, line: true) }
        if st == .notHere { return Note(text: Loc.t("capture.keys.menu_bar_only", table: "Capture"), mark: false, line: true) }
        return nil
    }

    // MARK: another Blurt

    /// The actions on the page another running Blurt holds (HotkeyResult.taken), and the dictation key when another
    /// copy listens to it.
    var takenActions: [HotAction] {
        if Self.solo { return [] }
        return HotAction.allCases.filter { a in
            guard !Hotkeys.shared.disabled.contains(a), case .taken = Hotkeys.shared.states[a] ?? .ok else { return false }
            return true
        }
    }
    var dictationTaken: Bool { !Self.solo && AppEnvironment.settings != nil && Dictation.shared.deferredTo != nil }
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
            if m.takenCount > 0 { banner.padding(.top, SettingsMetrics.groupGap) }

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
        .onDisappear { ShortcutField.active?.stop(); m.cancelSwap() }
    }

    /// Another running Blurt holds some of the keys: said once, with the way to free them.
    var banner: some View {
        let n = m.takenCount
        // usually one: the user's own Blurt beside a second one (a dev build, a copy opened twice)
        let many = m.others.count > 1
        let detail = many ? Loc.t("capture.keys.taken_banner.detail_many", table: "Capture")
            : m.otherLocation.map { Loc.t("capture.keys.taken_banner.detail", table: "Capture", $0) }
                ?? Loc.t("capture.keys.taken_banner.detail_unknown", table: "Capture")
        return SettingsNotice(title: Loc.plural(many ? "capture.keys.taken_banner_many" : "capture.keys.taken_banner", table: "Capture", count: n),
                              detail: detail) {
            if !m.otherApps.isEmpty {
                // the button's number follows the title's: one copy, one "Quit Other Copy"
                Button(m.quitting ? Loc.t("capture.keys.quitting", table: "Capture")
                       : Loc.t(many ? "capture.keys.quit_others" : "capture.keys.quit_other", table: "Capture")) {
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
        let asking = m.swap?.action == a ? m.swap : nil
        return SettingRow("shortcuts.\(a.rawValue)", title: a.title, detail: line?.text,
                          detailColor: line?.mark == true || m.refusals[a] != nil ? Color.brandAttnInk : nil,
                          detailContent: asking.map { AnyView(SwapLine(m: m, p: $0)) }
                            ?? (a == .pen && line == nil ? AnyView(HoldKeyLine(m: m)) : nil)) {
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
                          detail: Dictation.enabled ? (Dictation.doubleTapSend ? mode + " · " + Loc.t("dictation.mode.send_suffix", table: "Dictation") : mode) : nil) {
            DictationKeyButton(taken: taken) { m.openDictation() }
        }
    }
}

/// The dictation key on the Shortcuts page: read-only keycaps (it is set in Settings → Dictation) in the same fixed well
/// as every recorder, flush with the trailing edge; the whole well is one button there, with the recorders' faint
/// ground under the pointer. While another copy of Blurt hears the key: the "!" before it (the page's notice says why).
struct DictationKeyButton: View {
    var taken: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if taken { WarnDisc() }
                if Dictation.enabled {
                    KeycapsView(keys: [Dictation.keyName])
                } else {
                    Text(Loc.t("capture.keys.off", table: "Capture")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 6)
                }
            }
            .frame(width: ShortcutField.size.width, height: ShortcutField.size.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(taken ? Loc.t("dictation.status.other_instance.detail", table: "Dictation") : Loc.t("capture.keys.dictation_change", table: "Capture"))
        .accessibilityLabel(Loc.t("capture.keys.dictation_change", table: "Capture"))
        .accessibilityValue(Dictation.enabled ? Dictation.keyName : Loc.t("capture.keys.off", table: "Capture"))
    }
}

/// The attention disc with its "!" (12 pt), as the recorders draw it before keys that don't work here.
struct WarnDisc: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.brandAttn)
            Capsule().fill(Color(nsColor: BrandColor.onAttn)).frame(width: 1.5, height: 4.2).offset(y: -1.2)
            Circle().fill(Color(nsColor: BrandColor.onAttn)).frame(width: 1.6, height: 1.6).offset(y: 3)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The row's swap question, as its second line, with what it does: "Swap with Voice note? It gets ⌥⇧A." in secondary
/// ink, then Swap (brand ink, the row's one action) and Cancel — Return and Esc in the recorder do the same. The amber
/// "!" stays on the other action's keycaps, where the clash is.
struct SwapLine: View {
    @ObservedObject var m: HotkeySettings
    let p: HotkeySettings.PendingSwap
    var body: some View {
        HStack(spacing: 10) {
            Text(question).foregroundStyle(.secondary).help(m.swapOutcome(p))
            Button(Loc.t(p.mine == nil ? "capture.keys.move.ok" : "capture.keys.swap.ok", table: "Capture")) { m.answerSwap(true) }
                .buttonStyle(.plain).foregroundStyle(Color.brandInk).fontWeight(.semibold)
                .accessibilityHint(m.swapOutcome(p))
            Button(Loc.t("capture.keys.swap.cancel", table: "Capture")) { m.answerSwap(false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: SettingsMetrics.detailSize))
        .fixedSize(horizontal: false, vertical: true)
    }
    var question: String {
        if let mine = p.mine { return Loc.t("capture.keys.swap.ask_outcome", table: "Capture", p.other.title, mine.label) }
        return Loc.t("capture.keys.move.ask_outcome", table: "Capture", p.keys.label, p.other.title)
    }
}
