// The Settings window: a standard preferences toolbar (NSTabViewController, .toolbar style) whose panes are SwiftUI
// grouped forms (Shortcuts is the AppKit recorder from HotkeySettings). System colours and controls only, so it follows
// light / dark and the accent colour by itself. ⌘, from the menu; blurt://settings/<pane>.
import AppKit
import SwiftUI
import BlurtCore

enum SettingsPane: String, CaseIterable {
    case general, shortcuts, speech, dictation, agents, export, privacy, storage

    var title: String {
        switch self {
        case .general: return T("settings.kit.general")
        case .shortcuts: return T("settings.kit.shortcuts")
        case .speech: return T("settings.kit.speech")
        case .dictation: return T("dictation.settings.tab")
        case .agents: return T("settings.kit.agents")
        case .export: return T("settings.kit.export")
        case .privacy: return T("settings.kit.privacy")
        case .storage: return T("settings.kit.storage")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .speech: return "waveform"
        case .dictation: return "character.cursor.ibeam"
        case .agents: return "wand.and.stars"
        case .export: return "square.and.arrow.up"
        case .privacy: return "hand.raised"
        case .storage: return "internaldrive"
        }
    }

    @MainActor
    func makeController() -> NSViewController {
        let vc: NSViewController
        switch self {
        case .general: vc = NSHostingController(rootView: GeneralPane())
        case .shortcuts: vc = ShortcutsPaneController()
        case .speech: vc = NSHostingController(rootView: SpeechPane())
        case .dictation: vc = NSHostingController(rootView: DictationPane())
        case .agents: vc = NSHostingController(rootView: AgentsPane())
        case .export: vc = NSHostingController(rootView: ExportPane())
        case .privacy: vc = NSHostingController(rootView: PrivacyPane())
        case .storage: vc = NSHostingController(rootView: StoragePane())
        }
        vc.title = title
        vc.preferredContentSize = NSSize(width: 660, height: 560)
        return vc
    }
}

final class SettingsController: NSObject, SettingsHosting, NSWindowDelegate {
    static let shared = SettingsController()
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    @MainActor
    private func build() {
        let tc = NSTabViewController()
        tc.tabStyle = .toolbar
        tc.transitionOptions = []
        tc.canPropagateSelectedChildViewControllerTitle = true
        for p in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: p.makeController())
            item.label = p.title
            item.identifier = p.rawValue
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
            tc.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tc)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("BlurtSettings")
        w.sharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly
        window = w
        tabs = tc
    }

    func show(pane: String?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if window == nil { build() }
                let want = pane.flatMap(SettingsPane.init(rawValue:)) ?? SettingsPane(rawValue: Config.shared["app.settings_pane"] as? String ?? "") ?? .general
                if let i = SettingsPane.allCases.firstIndex(of: want) { tabs?.selectedTabViewItemIndex = i }
                MainMenu.ensureEditKeys()       // ⌘V into its fields while the main window has never been open
                activateApp()
                if window?.isVisible != true { window?.center() }
                window?.makeKeyAndOrderFront(nil)
                emit(["event": "settings", "pane": want.rawValue])
                // dictation can't hear its key: say so (≈ daily) — not over its own pane, which shows it
                if want != .dictation { Dictation.shared.nudge("settings") }
            }
        }
    }

    var visiblePane: String? {
        guard window?.isVisible == true, let i = tabs?.selectedTabViewItemIndex, i >= 0 else { return nil }
        return SettingsPane.allCases[i].rawValue
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    /// Tests (`settingsscroll top|bottom|N`): scroll the visible pane, for a screenshot of its lower part.
    @MainActor
    func scrollPane(_ to: String) -> Bool {
        guard let tc = tabs, tc.selectedTabViewItemIndex >= 0,
              let root = tc.tabViewItems[tc.selectedTabViewItemIndex].viewController?.view else { return false }
        var queue = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let s = v as? NSScrollView, let doc = s.documentView {
                let maxY = max(0, doc.frame.height - s.contentView.bounds.height)
                let y = to == "bottom" ? maxY : to == "top" ? 0 : min(maxY, Double(to) ?? 0)
                s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : maxY - y))
                s.reflectScrolledClipView(s.contentView)
                return true
            }
            queue += v.subviews
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        ShortcutField.active?.stop()
        if let p = visiblePane { Config.shared.set("app.settings_pane", p) }
    }
}

/// Settings → Shortcuts: the recorder rows from HotkeySettings (WP4) — record-style fields, the three conflict layers
/// shown inline (our own duplicates, macOS system shortcuts, RegisterEventHotKey / another Blurt holding it).
final class ShortcutsPaneController: NSViewController {
    /// The rows are taller than the pane (every pane is 660 × 560): they scroll, like the SwiftUI forms do.
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 560))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let content = HotkeySettings.shared.makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(wrappingLabelWithString: T("settings.kit.conflicts_are_checked_three"))
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        doc.addSubview(note)
        scroll.documentView = doc
        root.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            content.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            note.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 2),
            note.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 34),
            note.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -34),
            note.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
        ])
        view = root
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        HotkeySettings.shared.refresh()
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        ShortcutField.active?.stop()
    }
}
