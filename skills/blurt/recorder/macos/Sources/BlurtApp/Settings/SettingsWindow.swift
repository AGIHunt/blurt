// The Settings window: a standard preferences toolbar (NSTabViewController, .toolbar style) whose panes are SwiftUI
// grouped forms (Shortcuts hosts HotkeySettings' AppKit recorder fields in one). System colours and controls only, so
// it follows light / dark and the accent colour by itself. ⌘, from the menu; blurt://settings/<pane>.
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
        case .shortcuts: vc = NSHostingController(rootView: ShortcutsPane())
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
        // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
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
                // in front even when macOS doesn't hand Blurt the focus (the permission guide brings it back from
                // System Settings without a click on Blurt)
                window?.orderFrontRegardless()
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
