// P4 owns MainWindow/ and WebHost/. Called once at launch by the menu-bar app: sets AppEnvironment.mainWindow
// (the menu then shows "Open Blurt").
//
// At launch: an incremental `index.py scan` in the background when an index exists (a missing or outdated index is
// offered as a scan in the window instead), and the window comes back if it was open when the app quit — only for
// background launches (login item, `--background`), never on top of a plain launch that starts a recording, and
// never because something finished (K4: nothing opens by itself). BLURT_OPEN_MAIN=1 opens it right away (tests).
// What a scan found is said once (ScanReport, ScanFindings): item files that can't be read (each named once per run,
// with Show), files that couldn't be indexed at all (Show in Finder; the error goes to the log), and a scan that
// failed (with Try Again) — never dropped on the floor.
import AppKit
import BlurtCore

enum MainWindowModule {
    static func install() {
        AppEnvironment.mainWindow = MainWindowHost()
        if Scripts.has("index.py"), FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path) {
            Scripts.indexScan { r in ScanReport.handle(r, retry: { Scripts.indexScan { ScanReport.handle($0, retry: nil) } }) }
        }
        let env = ProcessInfo.processInfo.environment
        let reopen = CommandLine.arguments.contains("--background") && MainWindowController.loadState()?.open == true
        if env["BLURT_OPEN_MAIN"] != nil || reopen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppEnvironment.mainWindow?.show() }
        }
    }
}

/// What a full scan has to tell: files it couldn't read, or that it failed. The raw details go to the log.
enum ScanReport {
    /// Files already said this run: each is named once, not on every scan.
    private static var told = ScanFindings.Told()

    static func handle(_ r: Result<[String: Any], Error>, retry: (() -> Void)?) {
        switch r {
        case .success(let o):
            for s in o["skipped"] as? [[String: Any]] ?? [] {
                NSLog("blurt index: skipped %@: %@", s["path"] as? String ?? "?", s["error"] as? String ?? "")
            }
            let fresh = ScanFindings.fresh(in: o, told: &told)
            if let first = fresh.unreadable.first {
                let n = fresh.unreadable.count
                emit(["event": "scan_unreadable", "count": n])
                let text = n == 1 ? T("main.unreadable.found", first.id ?? URL(fileURLWithPath: first.path).lastPathComponent)
                                  : T("main.unreadable.found.many", n)
                say(text, action: first.uid.map { u in (T("main.unreadable.show"), { AppEnvironment.mainWindow?.reveal(uid: u) }) })
            }
            if let first = fresh.skipped.first {   // couldn't be indexed at all: the list still shows what it had
                let n = fresh.skipped.count
                emit(["event": "scan_skipped", "count": n])
                let url = URL(fileURLWithPath: first.path)
                let text = n == 1 ? T("main.skipped.found", url.lastPathComponent) : T("main.skipped.found.many", n)
                say(text, action: (T("action.reveal_in_finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
            }
        case .failure(let e):
            NSLog("blurt index: scan failed: %@", "\(e)")
            emit(["event": "scan_failed"])
            say(T("main.scan.failed"), action: retry.map { (T("action.retry"), $0) })
        }
    }

    private static func say(_ text: String, action: (String, () -> Void)?) {
        if let island = AppEnvironment.island { island.toast(text, actionTitle: action?.0, action: action?.1) }
        else { appDelegate?.toast(text) }
    }
}

/// Creates the window on first use: nothing of the main window costs memory until it's opened.
final class MainWindowHost: MainWindowHosting {
    func show() { MainWindowController.shared.show() }
    func reveal(uid: String) { MainWindowController.shared.reveal(uid: uid) }
    func reveal(session: URL) -> Bool { MainWindowController.shared.reveal(session: session) }
    func reveal(job: String) { MainWindowController.shared.reveal(job: job) }
    func reveal(project: String) { MainWindowController.shared.reveal(project: project) }
    func showInbox() { MainWindowController.shared.showInbox() }
}
