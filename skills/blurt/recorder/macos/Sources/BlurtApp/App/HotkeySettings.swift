// The Shortcuts window (menu → 快捷键… / Shortcuts…): a recorder field per action, ⌫ / × = off, restore defaults,
// the pen's hold key (record.draw_key), and each action's conflict state inline (Hotkeys.swift works them out).

import AppKit
import BlurtCore
import Carbon.HIToolbox

/// Click, then press the new combination. Esc cancels, ⌫ turns the hotkey off. Global hotkeys are suspended
/// meanwhile, or pressing the current one would fire it instead of being recorded.
final class ShortcutField: NSView {
    let action: HotAction
    var onSet: ((Shortcut?) -> Void)?
    var recording = false { didSet { needsDisplay = true } }
    var live = ""                       // modifiers held while recording
    var conflict = false { didSet { needsDisplay = true } }
    var monitor: Any?
    var refuse: String?                 // "needs ⌃ / ⌥ / ⌘" flash

    init(_ a: HotAction) {
        action = a
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        setAccessibilityRole(.button)
        setAccessibilityLabel(a.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : conflict ? NSColor.systemOrange : NSColor.separatorColor).setStroke()
        path.lineWidth = recording || conflict ? 1.5 : 1
        path.stroke()
        let s = Hotkeys.shared.shortcut(action)
        let text: String
        let color: NSColor
        if let r = refuse { text = r; color = .systemOrange }
        else if recording { text = live.isEmpty ? Loc.t("capture.keys.type", table: "Capture") : live; color = .controlAccentColor }
        else if let s = s { text = s.label; color = .labelColor }
        else { text = Loc.t("capture.keys.off", table: "Capture"); color = .tertiaryLabelColor }
        let font = recording || s == nil || refuse != nil ? NSFont.systemFont(ofSize: 12, weight: .medium)
                                                          : NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        a.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }

    override func mouseDown(with event: NSEvent) { recording ? stop() : start() }

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

/// A read-only key field in the Shortcuts list (dictation's key, which Settings → Dictation sets): drawn like a
/// ShortcutField; a click opens Settings → Dictation.
final class DictationKeyField: NSView {
    var text: String?                   // nil = dictation is off

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Loc.t("dictation.settings.tab", table: "Dictation"))
        toolTip = Loc.t("capture.keys.dictation_change", table: "Capture")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityValue() -> Any? { text ?? Loc.t("capture.keys.off", table: "Capture") }
    override func accessibilityPerformPress() -> Bool { HotkeySettings.shared.openDictation(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let a = NSAttributedString(string: text ?? Loc.t("capture.keys.off", table: "Capture"), attributes: [
            .font: text == nil ? NSFont.systemFont(ofSize: 12, weight: .medium) : NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: text == nil ? NSColor.tertiaryLabelColor : NSColor.labelColor])
        let sz = a.size()
        a.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }

    override func mouseDown(with event: NSEvent) { HotkeySettings.shared.openDictation() }
}

final class HotkeySettings: NSObject, NSWindowDelegate {
    static let shared = HotkeySettings()
    var window: NSWindow?
    var fields: [HotAction: ShortcutField] = [:]
    var notes: [HotAction: NSTextField] = [:]
    var clears: [HotAction: NSButton] = [:]
    /// Dictation's key lives in Settings → Dictation; this row shows it and leads there.
    var dictationField: DictationKeyField?
    var dictationNote: NSTextField?
    var drawPopup: NSPopUpButton?
    weak var content: NSView?

    func show() {
        if window == nil { build() }
        refresh()
        activateApp()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = Loc.t("capture.keys.title", table: "Capture")
        w.isReleasedWhenClosed = false
        w.delegate = self
        // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
        let content = makeContent()
        w.contentView = content
        w.setContentSize(content.fittingSize)
        window = w
    }

    /// The whole Shortcuts UI (rows, the pen's hold key, restore) as a view another window can host — Settings →
    /// Shortcuts (WP6). The latest content made is the one fields / refresh() drive.
    func makeContent() -> NSView {
        fields = [:]
        notes = [:]
        clears = [:]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func header(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)     // the same look as the Settings forms' section headers
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            t.textColor = .labelColor
            return t
        }
        func row(_ a: HotAction) -> NSView {
            let title = NSTextField(labelWithString: a.title)
            title.font = .systemFont(ofSize: 13)
            title.alignment = .right
            title.translatesAutoresizingMaskIntoConstraints = false
            title.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let f = ShortcutField(a)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 150).isActive = true
            f.heightAnchor.constraint(equalToConstant: 26).isActive = true
            f.onSet = { [weak self] s in Hotkeys.shared.set(s, for: a); self?.refresh() }
            fields[a] = f
            let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: Loc.t("capture.keys.off", table: "Capture")) ?? NSImage(),
                                 target: self, action: #selector(clear(_:)))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.identifier = NSUserInterfaceItemIdentifier(a.rawValue)
            clear.toolTip = Loc.t("capture.keys.turn_off", table: "Capture")
            clears[a] = clear
            let note = NSTextField(labelWithString: "")
            note.font = .systemFont(ofSize: 11.5)
            note.lineBreakMode = .byTruncatingTail
            note.translatesAutoresizingMaskIntoConstraints = false
            note.widthAnchor.constraint(equalToConstant: 210).isActive = true
            notes[a] = note
            let r = NSStackView(views: [title, f, clear, note])
            r.spacing = 10
            r.alignment = .centerY
            return r
        }

        stack.addArrangedSubview(header(Loc.t("capture.keys.anytime", table: "Capture")))
        for a in [HotAction.toggleRecord, .snap, .voice, .project, .cards, .openMenu] + (AppEnvironment.mainWindow == nil ? [] : [.openMain]) {
            stack.addArrangedSubview(row(a))
        }
        if AppEnvironment.settings != nil { stack.addArrangedSubview(dictationRow()) }
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(header(Loc.t("capture.keys.while_recording", table: "Capture")))
        for a in [HotAction.pause, .marker, .pen, .finish] { stack.addArrangedSubview(row(a)) }

        // the pen's hold-to-draw modifier (record.draw_key)
        let dTitle = NSTextField(labelWithString: Loc.t("capture.keys.hold_draw", table: "Capture"))
        dTitle.font = .systemFont(ofSize: 13)
        dTitle.alignment = .right
        dTitle.translatesAutoresizingMaskIntoConstraints = false
        dTitle.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        for (k, t) in [("control", Loc.t("capture.keys.control", table: "Capture")), ("option", Loc.t("capture.keys.option", table: "Capture")),
                       ("fn", Loc.t("capture.keys.fn", table: "Capture")), ("off", Loc.t("capture.keys.off", table: "Capture"))] {
            pop.addItem(withTitle: t)
            pop.lastItem?.representedObject = k
        }
        pop.target = self
        pop.action = #selector(drawKey(_:))
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.widthAnchor.constraint(equalToConstant: 150).isActive = true
        drawPopup = pop
        let dNote = NSTextField(labelWithString: Loc.t("capture.keys.draw_note", table: "Capture"))
        dNote.font = .systemFont(ofSize: 11.5)
        dNote.textColor = .secondaryLabelColor
        let dRow = NSStackView(views: [dTitle, pop, dNote])
        dRow.spacing = 10
        dRow.alignment = .centerY
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(dRow)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: dRow)
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -52).isActive = true

        let reset = NSButton(title: Loc.t("capture.keys.restore", table: "Capture"), target: self, action: #selector(restore))
        reset.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: Loc.t("capture.keys.hint", table: "Capture"))
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [reset, spacer, hint])
        bottom.alignment = .centerY
        bottom.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -52).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.content = content
        Hotkeys.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
        return content
    }

    /// Dictation: its key (right ⌥ / fn, tap or hold) — set in Settings → Dictation, where the click leads.
    func dictationRow() -> NSView {
        let title = NSTextField(labelWithString: Loc.t("dictation.settings.tab", table: "Dictation"))
        title.font = .systemFont(ofSize: 13)
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let f = DictationKeyField(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 150).isActive = true
        f.heightAnchor.constraint(equalToConstant: 26).isActive = true
        dictationField = f
        let go = NSButton(image: NSImage(systemSymbolName: "arrow.right.circle.fill",
                                         accessibilityDescription: Loc.t("capture.keys.dictation_change", table: "Capture")) ?? NSImage(),
                          target: self, action: #selector(openDictation))
        go.isBordered = false
        go.contentTintColor = .tertiaryLabelColor
        go.toolTip = Loc.t("capture.keys.dictation_change", table: "Capture")
        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 210).isActive = true
        dictationNote = note
        let r = NSStackView(views: [title, f, go, note])
        r.spacing = 10
        r.alignment = .centerY
        return r
    }

    @objc func openDictation() {
        ShortcutField.active?.stop()
        AppEnvironment.settings?.show(pane: "dictation")
    }

    func refresh() {
        guard content != nil else { return }
        if let f = dictationField {
            f.text = Dictation.enabled ? Dictation.keyName : nil
            f.needsDisplay = true
            dictationNote?.stringValue = Dictation.enabled
                ? Loc.t("dictation.mode.\(Dictation.mode.rawValue)", table: "Dictation") : ""
            dictationNote?.toolTip = dictationNote?.stringValue
        }
        let hk = Hotkeys.shared
        for a in HotAction.allCases {
            let st = hk.states[a] ?? .ok
            fields[a]?.conflict = st.isConflict
            fields[a]?.needsDisplay = true
            clears[a]?.isHidden = hk.shortcut(a) == nil      // nothing to turn off
            guard let n = notes[a] else { continue }
            if let bad = hk.invalid[a] {
                n.stringValue = Loc.t("capture.keys.unreadable", table: "Capture", bad)
                n.textColor = .systemOrange
            } else if st.isConflict {
                n.attributedStringValue = BlurtIcon.warning.label(st.text, font: n.font ?? .systemFont(ofSize: 11), color: .systemOrange,
                                                                  preferSymbol: true)
                n.textColor = .systemOrange
            } else if st == .notHere {
                n.stringValue = Loc.t("capture.keys.menu_bar_only", table: "Capture")
                n.textColor = .tertiaryLabelColor
            } else if st == .off {
                n.stringValue = ""
            } else {
                n.stringValue = a.defaultCombo == hk.shortcut(a) ? "" : Loc.t("capture.keys.custom", table: "Capture")
                n.textColor = .tertiaryLabelColor
            }
            n.toolTip = n.stringValue
        }
        let dk = recordConfig()["draw_key"] as? String ?? "control"
        if let i = drawPopup?.itemArray.firstIndex(where: { $0.representedObject as? String == dk }) { drawPopup?.selectItem(at: i) }
    }

    @objc func clear(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let a = HotAction(rawValue: id) else { return }
        ShortcutField.active?.stop()
        Hotkeys.shared.set(nil, for: a)
        refresh()
    }
    @objc func restore() {
        ShortcutField.active?.stop()
        Hotkeys.shared.restoreDefaults()
        refresh()
    }
    @objc func drawKey(_ p: NSPopUpButton) {
        let k = p.selectedItem?.representedObject as? String ?? "control"
        setRecordConfig("draw_key", k == "control" ? nil : k)
    }

    func windowWillClose(_ notification: Notification) { ShortcutField.active?.stop() }
}
