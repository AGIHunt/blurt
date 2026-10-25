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

import AppKit
import BlurtCore
import Carbon.HIToolbox
import SwiftUI

/// Click, then press the new combination. Esc cancels, ⌫ turns the hotkey off, and so does the × at the field's right
/// end. Global hotkeys are suspended meanwhile, or pressing the current one would fire it instead of being recorded.
final class ShortcutField: NSView {
    let action: HotAction
    var onSet: ((Shortcut?) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    var live = ""                       // modifiers held while recording
    var conflict = false { didSet { needsDisplay = true } }
    var monitor: Any?
    var refuse: String?                 // "needs ⌃ / ⌥ / ⌘" flash
    static let size = NSSize(width: 140, height: 24)

    init(_ a: HotAction) {
        action = a
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityRole(.button)
        setAccessibilityLabel(a.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityValue() -> Any? { Hotkeys.shared.shortcut(action)?.label ?? Loc.t("capture.keys.off", table: "Capture") }

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
        else { text = Loc.t("capture.keys.off", table: "Capture"); color = .tertiaryLabelColor }
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
        stop()
        onSet?(s)
    }

    func flash(_ msg: String) {
        NSSound.beep()
        refuse = msg
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refuse = nil; self?.needsDisplay = true }
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
        f.onSet = { [weak model] s in Hotkeys.shared.set(s, for: action); model?.refresh() }
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
        if let bad = hk.invalid[a] { return (Loc.t("capture.keys.unreadable", table: "Capture", bad), true) }
        let st = hk.states[a] ?? .ok
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
        Hotkeys.shared.restoreDefaults()
        refresh()
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
        SettingRow("shortcuts.dictation",
                   detail: Dictation.enabled ? Loc.t("dictation.mode.\(Dictation.mode.rawValue)", table: "Dictation") : nil) {
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
