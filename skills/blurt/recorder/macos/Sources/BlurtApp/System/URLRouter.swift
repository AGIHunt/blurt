// blurt:// URLs (C7), handed over by AppDelegate (AppEnvironment.openURL):
//   blurt://item/<uid>                     → the item in the main window, else its file in Finder
//   blurt://session/<abs-path-encoded>     → the batch in the main window, else its folder in Finder
//   blurt://settings[/<pane>[/<row>]]      → Settings (general, dictation, speech, shortcuts, agents, export, privacy,
//                                            storage); a row or section of the pane (SettingsCatalog id without the
//                                            pane, e.g. speech/dictation, general/login) is scrolled to and flashed
//   blurt://onboarding                     → the setup assistant
//   blurt://open                           → the main window (same as the menu's "Open Blurt"; the Tauri app has it too)
//   blurt://record, blurt://snap           → not handled here (false): the shell starts them — from a link (Blurt not
//                                            in front) only after one click on the island's question (App.confirmFromURL)
// Anything that would start an agent or change data is deliberately not reachable from a URL: any web page can open
// one.
import AppKit
import BlurtCore

enum URLRouter {
    /// Parsed route, for handling and for tests.
    enum Route: Equatable {
        case item(String)
        case session(URL)
        case settings(String?)
        case onboarding
        case open
        case shell(String)          // record / snap — the shell's
        case unknown
    }

    static func route(_ u: URL) -> Route {
        guard u.scheme == "blurt" else { return .unknown }
        let host = u.host ?? ""
        // path after the host, percent-decoded; "blurt://item/ABC" → "ABC"
        var rest = u.path
        if rest.hasPrefix("/") { rest.removeFirst() }
        rest = rest.removingPercentEncoding ?? rest
        switch host {
        case "item":
            return rest.isEmpty ? .unknown : .item(rest)
        case "session":
            // blurt://session/%2FUsers%2Fx%2F… (encoded) or blurt://session//Users/x/… — both end up absolute
            let raw = (u.absoluteString.components(separatedBy: "://session/").last ?? "")
            let p = raw.removingPercentEncoding ?? raw
            guard p.hasPrefix("/") else { return .unknown }
            return .session(URL(fileURLWithPath: p))
        case "settings": return .settings(rest.isEmpty ? nil : rest)
        case "onboarding": return .onboarding
        case "open": return .open
        case "record", "snap": return .shell(host)
        default: return .unknown
        }
    }

    static func handle(_ u: URL) -> Bool {
        let r = route(u)
        emit(["event": "url", "url": u.absoluteString, "route": "\(r)"])
        switch r {
        case .item(let uid):
            if let mw = AppEnvironment.mainWindow { mw.show(); mw.reveal(uid: uid); return true }
            if let it = IndexLookup.item(uid: uid) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]); return true }
            appDelegate?.toast(T("app.url.no_item", String(uid.prefix(12))))
            return true
        case .session(let dir):
            guard FileManager.default.fileExists(atPath: dir.path) else {
                appDelegate?.toast(T("app.url.no_session", (dir.path as NSString).abbreviatingWithTildeInPath))
                return true
            }
            if let mw = AppEnvironment.mainWindow { mw.show(); mw.reveal(session: dir); return true }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            return true
        case .settings(let pane):
            AppEnvironment.settings?.show(pane: pane)
            return true
        case .onboarding:
            Onboarding.shared.show()
            return true
        case .open:
            guard let mw = AppEnvironment.mainWindow else { return false }
            mw.show()
            return true
        case .shell, .unknown:
            return false
        }
    }

}

var appDelegate: App? { NSApp.delegate as? App }
