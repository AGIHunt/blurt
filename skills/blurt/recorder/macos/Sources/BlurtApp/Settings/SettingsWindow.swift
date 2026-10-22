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
            }
        }
    }

    var visiblePane: String? {
        guard window?.isVisible == true, let i = tabs?.selectedTabViewItemIndex, i >= 0 else { return nil }
        return SettingsPane.allCases[i].rawValue
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    func windowWillClose(_ notification: Notification) {
        ShortcutField.active?.stop()
        if let p = visiblePane { Config.shared.set("app.settings_pane", p) }
    }
}

/// Settings → Shortcuts: the recorder rows from HotkeySettings (WP4) — record-style fields, the three conflict layers
/// shown inline (our own duplicates, macOS system shortcuts, RegisterEventHotKey / another Blurt holding it).
final class ShortcutsPaneController: NSViewController {
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 560))
        let content = HotkeySettings.shared.makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(wrappingLabelWithString: T("settings.kit.conflicts_are_checked_three"))
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(note)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            note.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
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
