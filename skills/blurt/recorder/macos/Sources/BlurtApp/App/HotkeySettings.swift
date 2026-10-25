// Settings → Shortcuts (and, in a build without the Settings window, the Shortcuts window from the menu): the same
// page of rows as every other pane (SettingsKit; rows from SettingsCatalog, "shortcuts.<action>") — the action on the
// left, its recorder field on the right with the × that turns it off inside the field, and each action's conflict
// state under its name (Hotkeys.swift works them out). Two groups: Anytime (record, snap, voice note, switch project,
// hanging cards, the menu, the main window, dictation's key — set in Settings → Dictation, where its row leads — and
// reformat) and While recording (pause, marker, pen, finish, and the pen's hold key, record.draw_key). Restore
// defaults at the bottom; how to record a key under the page's title.
//
// ⌥⇧R starts a recording and also finishes one; ⌥⇧S only finishes — it is the key a recording started from the
// chat (no menu-bar app) listens to, so it stays, listed under While recording as "Finish recording".
//
// What the field refuses, with the reason under the action's name: a key without ⌃ / ⌥ / ⌘, ⌘ / ⇧⌘ with a typing key
// (⌘C is Copy in every app: KeyCombo.reserved) and a macOS system shortcut. Keys another action has ask first — a
// sheet on this window: "Swap" exchanges the two actions' keys, or, when this one had none, "Move Here" moves them
// and leaves the other without — never a silent duplicate. Every change
// (set, clear, swap, restore) can be undone with ⌘Z. The field works from the keyboard: Tab reaches it (focus ring),
// Space or Return starts recording, Delete clears it.

import AppKit
import BlurtCore
import Carbon.HIToolbox
import SwiftUI

/// Click (or Space / Return), then press the new combination. Esc cancels, ⌫ turns the hotkey off, and so does the ×
/// at the field's right end. Global hotkeys are suspended meanwhile, or pressing the current one would fire it instead
/// of being recorded.
final class ShortcutField: NSView {
    let action: HotAction
    var onSet: ((Shortcut?) -> Void)?
    /// a refusal's reason, for the line under the action's name (nil: clear it)
    var onRefuse: ((String?) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    var live = ""                       // modifiers held while recording
    var conflict = false { didSet { needsDisplay = true } }
    var monitor: Any?
    var refuse: String?                 // "needs ⌃ / ⌥ / ⌘" flash
    /// the last refusal (tests read it)
    private(set) var lastRefusal: String?
    private var refuseGeneration = 0
    static let size = NSSize(width: 140, height: 24)

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
    override func accessibilityValue() -> Any? { Hotkeys.shared.shortcut(action)?.label ?? Loc.t("capture.keys.none", table: "Capture") }
    override func accessibilityPerformPress() -> Bool { recording ? stop() : start(); return true }

    // the system focus ring, shaped like the field (Tab moves through the fields)
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill() }
    override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override func resignFirstResponder() -> Bool {
        if recording { stop() }
        noteFocusRingMaskChanged()
        return true
    }

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

    /// The × at the right end, shown while there is a shortcut to turn off (and not while recording).
    private var clearRect: NSRect? {
        guard !recording, Hotkeys.shared.shortcut(action) != nil else { return nil }
        return NSRect(x: bounds.maxX - 22, y: 0, width: 22, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        // listening for keys: brand ink on the brand tint; a conflict: attention (§3.4)
        (recording ? BrandColor.tint : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? BrandColor.ink : conflict ? BrandColor.attnInk : NSColor.separatorColor).setStroke()
        path.lineWidth = recording || conflict ? 1.5 : 1
        path.stroke()
        let s = Hotkeys.shared.shortcut(action)
        let text: String
        let color: NSColor
        if let r = refuse { text = r; color = BrandColor.attnInk }
        else if recording { text = live.isEmpty ? Loc.t("capture.keys.type", table: "Capture") : live; color = BrandColor.ink }
        else if let s = s { text = s.label; color = .labelColor }
        else { text = Loc.t("capture.keys.none", table: "Capture"); color = .tertiaryLabelColor }
        let font = recording || s == nil || refuse != nil ? NSFont.systemFont(ofSize: 12, weight: .medium)
                                                          : NSFont.systemFont(ofSize: 13, weight: .semibold)
        let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        a.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
        if let c = clearRect, let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.tertiaryLabelColor]))) {
            x.draw(in: NSRect(x: c.midX - x.size.width / 2, y: c.midY - x.size.height / 2, width: x.size.width, height: x.size.height))
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
        f.conflict = Hotkeys.shared.states[action]?.isConflict ?? false
        f.needsDisplay = true
    }
    /// Its own size, so the form row stays one line high with the field beside the name.
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutField, context: Context) -> CGSize? { ShortcutField.size }
}

/// The pane's state: it redraws when a binding or a conflict changes (Hotkeys.onChange) and keeps the fields for the
/// test hooks. Also the standalone Shortcuts window (no Settings window in that build).
final class HotkeySettings: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HotkeySettings()
    var window: NSWindow?
    /// The recorder fields on screen now, by action (`shortcut` / `recordkey` test hooks).
    var fields: [HotAction: ShortcutField] = [:]
    @Published var drawKey = "control"
    /// why the field just refused a key ("⌘C is Copy in every app — add ⌥ or ⌃"), shown under the action's name
    @Published var refusals: [HotAction: String] = [:]
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
        objectWillChange.send()
    }

    func show() {
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

    /// Under an action's name: why it doesn't work, a config entry that couldn't be read, or nothing.
    func note(_ a: HotAction) -> (text: String, warn: Bool)? {
        let hk = Hotkeys.shared
        if let why = refusals[a] { return (why, true) }
        if let bad = hk.invalid[a] { return (Loc.t("capture.keys.unreadable", table: "Capture", bad), true) }
        let st = hk.states[a] ?? .ok
        if st == .reserved, let s = hk.shortcut(a), let r = s.reserved { return (r.reason(s), true) }
        if st.isConflict { return (st.text, true) }
        if st == .notHere { return (Loc.t("capture.keys.menu_bar_only", table: "Capture"), false) }
        return nil
    }

    func setDrawKey(_ k: String) {
        drawKey = k
        setRecordConfig("draw_key", k == "control" ? nil : k)
    }

    func restore() {
        ShortcutField.active?.stop()
        refusals = [:]
        change(fields.values.compactMap(\.window).first ?? window) { Hotkeys.shared.restoreDefaults() }
    }

    @objc func openDictation() {
        ShortcutField.active?.stop()
        AppEnvironment.settings?.show(pane: "dictation")
    }

    func windowWillClose(_ notification: Notification) { ShortcutField.active?.stop() }
}

struct ShortcutsPane: View {
    @ObservedObject var m = HotkeySettings.shared

    var anytime: [HotAction] {
        [.toggleRecord, .snap, .voice, .project, .cards, .openMenu] + (AppEnvironment.mainWindow == nil ? [] : [.openMain])
    }

    var body: some View {
        SettingsPage(.shortcuts, subtitle: Loc.t("capture.keys.hint", table: "Capture")) {
            SettingsGroup("shortcuts.anytime") {
                ForEach(anytime, id: \.self) { row($0) }
                if AppEnvironment.settings != nil {
                    dictationRow
                    row(.reformat)          // ⌥⇧L: the last dictation in another style
                }
            }

            SettingsGroup("shortcuts.recording") {
                ForEach([HotAction.pause, .marker, .pen, .finish], id: \.self) { row($0) }
                SettingRow("shortcuts.draw_key") {
                    RowPicker(label: Loc.t("capture.keys.hold_draw", table: "Capture"), selection: Binding(get: { m.drawKey }, set: { m.setDrawKey($0) })) {
                        Text(Loc.t("capture.keys.control", table: "Capture")).tag("control")
                        Text(Loc.t("capture.keys.option", table: "Capture")).tag("option")
                        Text(Loc.t("capture.keys.fn", table: "Capture")).tag("fn")
                        Text(Loc.t("capture.keys.off", table: "Capture")).tag("off")
                    }
                }
            }

            SettingsGroup {
                SettingRow("shortcuts.restore") {
                    Button(T("settings.shortcuts.restore")) { m.restore() }
                }
            }
        }
        .onAppear { m.refresh() }
        .onDisappear { ShortcutField.active?.stop() }
    }

    /// An action: its name (and why it doesn't work, when it doesn't — in attention ink for a conflict) on the left,
    /// its recorder field on the right.
    func row(_ a: HotAction) -> some View {
        let note = m.note(a)
        return SettingRow("shortcuts.\(a.rawValue)", title: a.title, detail: note?.text,
                          detailColor: note?.warn == true ? Color.brandAttnInk : nil) {
            ShortcutRecorder(action: a, model: m)
                .frame(width: ShortcutField.size.width, height: ShortcutField.size.height)
        }
    }

    /// Dictation's key: set in Settings → Dictation; shown here like the others, with the way there.
    var dictationRow: some View {
        // "Tap or hold · double-tap to send": the double tap presses Return, so it is said wherever the key is
        let mode = Loc.t("dictation.mode.\(Dictation.mode.rawValue)", table: "Dictation")
        return SettingRow("shortcuts.dictation",
                   detail: Dictation.enabled ? (Dictation.doubleTapSend ? mode + " · " + Loc.t("dictation.mode.send_suffix", table: "Dictation") : mode) : nil) {
            HStack(spacing: 10) {
                // a text button in brand ink (§3.3 links), not the system's blue
                Button(Loc.t("capture.keys.dictation_change", table: "Capture")) { m.openDictation() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandInk)
                Text(Dictation.enabled ? Dictation.keyName : Loc.t("capture.keys.off", table: "Capture"))
                    .font(.system(size: Dictation.enabled ? 13 : 12, weight: Dictation.enabled ? .semibold : .medium))
                    .foregroundStyle(Dictation.enabled ? .primary : .tertiary)
                    .frame(width: ShortcutField.size.width, height: ShortcutField.size.height)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    .accessibilityLabel(Loc.t("dictation.settings.tab", table: "Dictation"))
            }
        }
    }
}
