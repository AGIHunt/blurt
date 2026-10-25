// The detail column. Reviewing happens here — there is no separate review window and nothing opens by itself:
//   an item     the shared review component (web/packages/review → review.html) in a WKWebView, mode=item, with a
//               native banner above it when the item is with an agent (its session live, ended without reporting
//               back, or gone — WorkSession) or is being organised (a suggested project is the page's and the row's). The banner holds the
//               item's one Open Session button (blurtHostInfo.sessionBanner: the page leaves its own out then);
//   a batch     the same component in review mode (the whole capture session: keep / drop / merge, then confirm);
//   a job       its step timeline (JobDetailView) and, for agent sessions, the embedded terminal (P3);
//   nothing     a quiet placeholder (blank while no items exist at all: the list's first-run state speaks).
//   unreadable  an item whose file doesn't parse: "can't be read" (never "gone"), Open in Editor and Show in Finder;
//               the parser's words go to the log. A folder that comes back re-shows the item even when its index row
//               didn't change. Load and download failures are said in words; the host's raw error is only logged.
//
// Host protocol v3 (C6 + next-round.md "审核组件宿主协议 v3"):
//   page          blurt-app://ui/index.html?mode=item|review&item=<uid>&scope=<session abs | project:<id>>&platform=mac&theme=auto&lang=…
//   doc start     window.blurtHostInfo = {host: "macos", methods: [...], accent: "#rrggbb", scope: {...}, sessionBanner: mode == item}
//   JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params}); native → window.__blurtReply(id, result, error)
//   requests      load {scope?} → {doc, etag}             items.py doc SESSION | --project P [--item UID: the item
//                                                          on show, listed whatever its state; also poll, sendOps]
//                 poll {etag, scope?} → {etag} | {doc, etag}   items.py poll … --etag E
//                 sendOps {ops, confirm, scope?} → {ok, etag, doc}   items.py user-ops … --stdin [--confirm]
//                 handoff {uids, what} → {id, path, text}  handoff.py create --items … --mark (copied to the clipboard)
//                 toast {msg, undo, icon, label?} → "undo" | "shown" | "gone"   the page's line goes up on the island — the main window's
//                 toasts have one place (and one timing: ≥ 5 s, held while pointed at); "undo" when its Undo is clicked
//   undo          registerUndo {label} (a page step on the window's NSUndoManager; ⌘Z calls blurtReview.undo() /
//                 redo() back), windowUndo {redo} (⌘Z on the page outside a field), undone {uid}, focusList (Esc)
//   notifications reveal {path|rel}, quickLook {path|rel}, openCode {ref}, dispatch {uids}, openSession {job} (older
//                 pages: jobId), registerDragRects {rects}, download {path|rel}, confirmed {scope} (a batch confirmed:
//                 review.py, if it asked for this batch, hears it — ReviewHandoff)
import AppKit
import BlurtCore
import WebKit

protocol WebHostActions: AnyObject {
    func reveal(file: URL)
    func quickLook(files: [URL])
    func openCode(_ ref: String, item: ItemRow?)
    func dispatch(uids: [String])
    func handOff(uids: [String], what: String, reply: @escaping ([String: Any]?) -> Void)
    func applyState(_ action: String, uids: [String])
    func move(uids: [String], to project: String)
    func revealJob(_ id: String)
    func jobAction(_ action: String, job: Job)
    func webWrote()
    /// the page undid / redid a step about this item (not necessarily the one shown): select it
    func webUndid(_ uid: String)
    /// Esc on the page with nothing left to cancel
    func focusList()
    /// "Locate…" for a project whose folder is gone
    func locateFolder(_ id: String)
}

/// What a page shows: one capture session's batch, or one project's items.
enum DocScope: Equatable {
    case session(URL)
    case project(String)
    var args: [String] {
        switch self { case .session(let u): return [u.path]; case .project(let p): return ["--project", p] }
    }
    var param: String {
        switch self { case .session(let u): return u.path; case .project(let p): return "project:" + p }
    }
    var json: [String: Any] {
        switch self { case .session(let u): return ["session": u.path]; case .project(let p): return ["project": p] }
    }
}

final class WebHostController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var actions: WebHostActions?
    private(set) var web: WKWebView!
    let overlay = DragOverlay()
    let schemes = SchemeHandler()
    let placeholder = EmptyStateView()
    let banner = ItemBanner()
    /// An item's pane: the list's own surface behind the (transparent) page, so list and detail read as one sheet
    let surface = PaneSurface()
    let jobView = JobDetailView()
    private var loadedScope: DocScope?
    private var loadedMode = ""
    private(set) var currentItem: ItemRow?
    private(set) var currentJob: Job?
    private var accentObserver: NSObjectProtocol?
    /// The project whose missing folder the placeholder offers to find.
    private var missingProject: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(schemes, forURLScheme: SchemeHandler.scheme)
        cfg.userContentController.add(WeakHandler(self), name: "blurt")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 12.3, *) { cfg.preferences.isElementFullscreenEnabled = true }
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: root.bounds, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = ProcessInfo.processInfo.environment["BLURT_INSPECT"] != nil }
        web.setAccessibilityLabel(T("main.detail.label"))
        overlay.web = web
        placeholder.onButton = { [weak self] tag in
            if tag == 1 { self?.actions?.webWrote() }
            if tag == 7, let p = self?.missingProject { self?.actions?.locateFolder(p) }
            if tag == 8, let f = self?.currentItem?.fileURL { NSWorkspace.shared.open(f) }       // the system's editor for .md
            if tag == 9, let f = self?.currentItem?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([f]) }
        }
        banner.onAction = { [weak self] a in self?.bannerAction(a) }
        jobView.onAction = { [weak self] a in
            guard let self = self, let j = self.currentJob else { return }
            self.actions?.jobAction(a, job: j)
        }
        for v in [surface, banner, web!, overlay, placeholder, jobView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: root.topAnchor), surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            web.topAnchor.constraint(equalTo: banner.bottomAnchor), web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: web.topAnchor), overlay.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: root.topAnchor), placeholder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            jobView.topAnchor.constraint(equalTo: root.topAnchor), jobView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.web.evaluateJavaScript("window.__blurtSetAccent && window.__blurtSetAccent('\(Self.accentHex())')")
        }
        showNothing()
    }

    deinit {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "blurt")
        accentObserver.map(NotificationCenter.default.removeObserver)
    }

    /// The page's focus colour: the system's (focus follows the user's accent, §1.4; with Multicolor that is the app's
    /// AccentColor asset). The focus indicator is the accent at partial alpha; only its hue is passed on.
    static func accentHex() -> String {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// The optional host methods we implement.
    var methods: [String] {
        ["reveal", "quickLook", "openCode", "registerDragRects", "download", "dispatch", "handoff", "openSession", "fileUrl",
         "toast", "registerUndo", "focusList"]
    }

    // MARK: one undo stack per window
    //
    // The page's own undoable steps (a state from the pill, a chip, a move, a field's editing session) go on the
    // window's NSUndoManager next to the list's: ⌘Z / ⇧⌘Z work wherever the focus is and the Edit menu names the step.
    // Each page load has its own target: a step of a page since replaced is dropped with it (nothing left to undo
    // there), never run against another page.

    private final class PageSteps {}
    private var pageSteps = PageSteps()

    private func registerPageStep(_ label: String, undo: Bool, on target: PageSteps) {
        guard let um = view.window?.undoManager else { return }
        um.registerUndo(withTarget: target) { [weak self] t in
            guard let self = self, t === self.pageSteps else { return }
            self.web.evaluateJavaScript("window.blurtReview && window.blurtReview.\(undo ? "undo" : "redo")()")
            self.registerPageStep(label, undo: !undo, on: t)       // inside an undo: the redo, and back
        }
        um.setActionName(label)
    }

    private func dropPageSteps() {
        view.window?.undoManager?.removeAllActions(withTarget: pageSteps)
        pageSteps = PageSteps()
    }

    /// sessionBanner only in item mode: the banner above the page exists only there, so a batch keeps the panel's own.
    private func installHostInfo(_ scope: DocScope, mode: String) {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        var waiting = false
        if case .session(let u) = scope { waiting = ReviewHandoff.waiting(u) }
        let info: [String: Any] = ["host": "macos", "methods": methods, "accent": Self.accentHex(), "scope": scope.json,
                                   "lang": Loc.language, "inApp": true, "sessionBanner": mode == "item",
                                   "agentWaiting": waiting]       // only then does confirming "hand it back"
        let json = (try? JSONSerialization.data(withJSONObject: info)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        ucc.addUserScript(WKUserScript(source: "window.blurtHostInfo = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: what to show

    private func only(_ v: NSView?) {
        for x in [web!, overlay, placeholder, jobView] as [NSView] { x.isHidden = x !== v && !(v === web && x === overlay) }
        if v !== web { banner.set(nil); overlay.set([]) }
        surface.isHidden = true
        showsNothing = false
        showsQuietNothing = false
    }

    /// What showNothing put up, until something else replaces it.
    private(set) var showsNothing = false, showsQuietNothing = false

    /// Nothing selected (or several): a quiet placeholder. `quiet`: no items exist at all yet — the pane stays blank
    /// and the list's first-run state is the one thing to look at.
    func showNothing(_ count: Int = 0, quiet: Bool = false) {
        currentItem = nil
        currentJob = nil
        if quiet {
            only(nil)
        } else {
            let msg = count > 1 ? TP("main.detail.multi.detail", count) : T("main.detail.none.detail")
            placeholder.show(symbol: count > 1 ? "square.stack.3d.up" : "sidebar.right",
                             title: count > 1 ? TP("main.detail.multi", count) : T("main.detail.none"), message: msg)
            only(placeholder)
        }
        showsNothing = true
        showsQuietNothing = quiet
    }

    func show(item: ItemRow, projects: [ProjectEntry]) {
        currentItem = item
        currentJob = nil
        if item.legacy {
            placeholder.show(symbol: "clock.arrow.circlepath", title: T("main.detail.legacy"), message: T("main.detail.legacy.detail"))
            return only(placeholder)
        }
        if let e = item.parseError {
            // never "gone": the file is there, Blurt protects it. The parser's own words go to the log only.
            NSLog("blurt main window: %@ can't be read: %@", item.fileURL.path, e)
            placeholder.show(symbol: "exclamationmark.triangle", title: T("main.detail.parse_error"),
                             message: T("main.detail.parse_error.detail"),
                             buttons: [(T("main.unreadable.open"), 8), (T("action.reveal_in_finder"), 9)])
            return only(placeholder)
        }
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            // the whole folder is gone (moved, renamed, an unplugged disk): say that, where it was on one line, and
            // offer to find it — the list's banner says the same; one missing item file keeps the plain message
            if let p = projects.first(where: { $0.id == item.projectID }), p.registered, !FileManager.default.fileExists(atPath: p.path.path) {
                placeholder.show(symbol: "questionmark.folder", title: T("main.missing.title"),
                                 message: (p.path.path as NSString).abbreviatingWithTildeInPath, oneLine: true,
                                 buttons: [(T("main.missing.locate"), 7)])
                missingProject = p.id
            } else {
                placeholder.show(symbol: "questionmark.folder", title: T("main.detail.gone"),
                                 message: (item.fileURL.path as NSString).abbreviatingWithTildeInPath, oneLine: true)
            }
            return only(placeholder)
        }
        only(web)
        surface.isHidden = false
        banner.set(item)
        let scope: DocScope = item.sessionURL.map { .session($0) } ?? .project(item.projectID)
        if loadedScope == scope, loadedMode == "item" {
            // setItem answers whether the loaded doc has the item: a discarded one (left out of its project's doc) or
            // one that moved in since needs a doc that lists it — never the item shown before
            web.evaluateJavaScript("window.blurtReview && window.blurtReview.setItem ? window.blurtReview.setItem(\(Self.js(item.uid))) === true : false") { [weak self] r, _ in
                if (r as? Bool) != true, self?.currentItem?.uid == item.uid { self?.load(scope, mode: "item", item: item.uid) }
            }
            return
        }
        load(scope, mode: "item", item: item.uid)
    }

    /// A whole capture batch, to triage (keep / drop / merge) and confirm.
    func show(session: URL) {
        currentItem = nil
        currentJob = nil
        only(web)
        if loadedScope == .session(session), loadedMode == "review" { return }
        load(.session(session), mode: "review", item: nil)
    }

    func show(job: Job, projectName: String?) {
        currentItem = nil
        currentJob = job
        jobView.show(job, projectName: projectName)
        only(jobView)
    }

    func reload() { if let s = loadedScope { load(s, mode: loadedMode, item: currentItem?.uid) } }

    /// Something was written behind the page (a list key, a move, a rename): it fetches the doc again in place — no
    /// reload, so its scroll, media, caret and undo steps stay. A page without pollNow is reloaded.
    func pollNow() {
        guard loadedScope != nil, !web.isHidden else { return }
        web.evaluateJavaScript("window.blurtReview && window.blurtReview.pollNow ? (window.blurtReview.pollNow(), true) : false") { [weak self] r, _ in
            if (r as? Bool) != true { self?.reload() }
        }
    }

    /// The index has a newer row for the item on show (its state, title, file, project): the banner follows it, and
    /// an item whose file moved (to another project, a folder renamed on disk) or came back is shown again from there.
    func refresh(item: ItemRow, projects: [ProjectEntry]) {
        guard let cur = currentItem, cur.uid == item.uid else { return }
        let wasShown = !web.isHidden
        // the folder came back (or went) with the index row unchanged: what is on show no longer matches the disk
        // (dogfood-2 W19: "can't find this folder" stayed up after the folder was restored)
        if cur == item {
            if wasShown != FileManager.default.fileExists(atPath: item.fileURL.path), item.parseError == nil, !item.legacy {
                show(item: item, projects: projects)
            }
            return
        }
        if item.fileURL != cur.fileURL || item.projectID != cur.projectID || item.sessionURL != cur.sessionURL
            || wasShown != FileManager.default.fileExists(atPath: item.fileURL.path) || item.parseError != cur.parseError {
            return show(item: item, projects: projects)
        }
        currentItem = item
        if wasShown { banner.set(item) }
    }

    /// Jobs moved on: the line above the item may say something else now.
    func refreshBanner(projects: [ProjectEntry]) {
        guard let it = currentItem, !web.isHidden else { return }
        banner.set(it)
    }

    private func load(_ scope: DocScope, mode: String, item: String?) {
        dropPageSteps()
        loadedScope = scope
        loadedMode = mode
        overlay.set([])
        if case .session(let u) = scope { schemes.session = u } else { schemes.session = nil }
        installHostInfo(scope, mode: mode)
        var c = URLComponents()
        c.scheme = SchemeHandler.scheme
        c.host = "ui"
        c.path = "/index.html"
        var q = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "scope", value: scope.param),
                 URLQueryItem(name: "platform", value: "mac"), URLQueryItem(name: "theme", value: "auto"),
                 URLQueryItem(name: "lang", value: Loc.language)]
        if case .session(let u) = scope { q.append(URLQueryItem(name: "session", value: u.path)) }
        if let i = item { q.append(URLQueryItem(name: "item", value: i)) }
        c.queryItems = q
        web.load(URLRequest(url: c.url!))
    }

    static func js(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private func bannerAction(_ a: String) {
        guard let it = currentItem else { return }
        switch a {
        case "done", "wontfix": actions?.applyState(a, uids: [it.uid])
        case "session": if let j = it.workJob { actions?.revealJob(j) }
        case "desktop":
            if let j = it.workJob, let a = JobStore.shared.job(j)?.agent { DesktopApp.goTo(a.agent) }
        case "review":
            // what the ellipsis promises: the session, and its review sheet over the window
            guard let j = it.workJob else { return }
            actions?.revealJob(j)
            FinishPanel.show(job: j, over: view.window)
        case "restart":
            guard let j = it.workJob else { return }
            SessionRecovery.restart(j) { [weak self] r in
                switch r {
                case .success(let new): if let n = new { self?.actions?.revealJob(n) }
                case .failure(let e): appDelegate?.toast(sessionsErrorText(e))
                }
            }
        case "take_back": actions?.applyState("take_back", uids: [it.uid])
        case "progress": if let j = banner.processingJob { actions?.revealJob(j) }
        default: break
        }
    }

    // MARK: JS → native

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let method = m["method"] as? String else { return }
        let id = (m["id"] as? NSNumber)?.intValue ?? 0
        let p = m["params"] as? [String: Any] ?? [:]
        call(method, p) { [weak self] result, error in
            guard let self = self, id != 0 else { return }      // id 0: a notification, no reply
            let r = (try? JSONSerialization.data(withJSONObject: ["r": result ?? NSNull()])).map { String(decoding: $0, as: UTF8.self) } ?? "{\"r\":null}"
            let e = error.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) }.map { String(decoding: $0, as: UTF8.self) } ?? "[null]"
            self.web.evaluateJavaScript("window.__blurtReply && window.__blurtReply(\(id), (\(r)).r, (\(e))[0])")
        }
    }

    /// The scope a request is about: its own (v3 pages may pass one), else the page's.
    private func scope(_ p: [String: Any]) -> DocScope? {
        if let s = p["scope"] as? [String: Any] {
            if let d = s["session"] as? String { return .session(URL(fileURLWithPath: d)) }
            if let pr = s["project"] as? String { return .project(pr) }
        }
        return loadedScope
    }

    /// The item on show is always in its doc (items.py --item), whatever a project's doc leaves out: a discarded one
    /// selected under the Discarded filter shows itself, not its neighbour.
    private func shownItemArgs(_ s: DocScope) -> [String] {
        guard loadedMode == "item", case .project = s, let it = currentItem else { return [] }
        return ["--item", it.uid]
    }

    /// One host method. `reply(result, error)`; notifications reply nil.
    func call(_ method: String, _ p: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let session = schemes.session
        func file(_ k: String = "path") -> URL? {
            ((p[k] ?? p["rel"]) as? String).flatMap { SchemeHandler.locate($0, session: session) }
        }
        switch method {
        case "load", "poll":
            guard let s = scope(p) else { return reply(nil, "no scope") }
            let args = (method == "load" ? ["doc"] + s.args : ["poll"] + s.args + ["--etag", p["etag"] as? String ?? ""]) + shownItemArgs(s)
            Scripts.run("items.py", args, timeout: 30) { r in
                switch r {
                case .success(let d):
                    guard let o = Scripts.json(d), o["ok"] as? Bool == true else { return reply(nil, "items.py \(method) failed") }
                    var out: [String: Any] = ["etag": o["etag"] ?? ""]
                    if let doc = o["doc"] { out["doc"] = doc }
                    reply(out, nil)
                case .failure(let e): reply(nil, "\(e)")
                }
            }
        case "sendOps":
            guard let s = scope(p) else { return reply(nil, "no scope") }
            let ops = p["ops"] as? [[String: Any]] ?? []
            Scripts.userOps(s.args + shownItemArgs(s), ops, confirm: p["confirm"] as? Bool ?? false) { [weak self] r in
                switch r {
                case .success(let o): reply(["ok": true, "etag": o["etag"] ?? "", "doc": o["doc"] ?? NSNull()], nil); self?.actions?.webWrote()
                case .failure(let e): reply(nil, "\(e)")
                }
            }
        case "fileUrl":
            reply((p["path"] as? String).map(SchemeHandler.fileURL), nil)
        case "reveal":
            if let f = file() { actions?.reveal(file: f) }
            reply(nil, nil)
        case "quickLook":
            if let f = file() { actions?.quickLook(files: [f]) }
            reply(nil, nil)
        case "openCode":
            if let r = p["ref"] as? String { actions?.openCode(r, item: currentItem) }
            reply(nil, nil)
        case "dispatch":
            let ids = p["uids"] as? [String] ?? []
            actions?.dispatch(uids: ids)
            reply(nil, nil)
        case "handoff":
            actions?.handOff(uids: p["uids"] as? [String] ?? [], what: p["what"] as? String ?? "instruction") { r in
                reply(r, r == nil ? "handoff failed" : nil)
            }
        case "openSession":
            if let j = ReviewHostParams.job(p) { actions?.revealJob(j) }
            reply(nil, nil)
        case "registerDragRects":
            let rects = (p["rects"] as? [[String: Any]] ?? []).compactMap { r -> DragRect? in
                guard let ref = (r["path"] ?? r["rel"]) as? String, let f = SchemeHandler.locate(ref, session: session) else { return nil }
                func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                return DragRect(rect: CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")), file: f)
            }
            overlay.set(rects)
            reply(nil, nil)
        case "download":
            if let f = file() { Self.download(f) }
            reply(nil, nil)
        case "toast":
            // one place for the main window's toasts: the island (its Undo answers the page, which undoes its step)
            let text = p["msg"] as? String ?? ""
            let undo = p["undo"] as? Bool ?? false
            let done = ["check", "copy"].contains(p["icon"] as? String ?? "")
            guard !text.isEmpty else { return reply("shown", nil) }
            guard island.started else { appDelegate?.toast(text, icon: done ? .check : nil); return reply("shown", nil) }
            // the page waits for the answer: "undo" from the button, "gone" the moment the island lets the toast go
            // (replaced, superseded, expired after a hover hold, stale) — never a click on an Undo the page gave up on
            var answered = false
            func answer(_ r: String) { if !answered { answered = true; reply(r, nil) } }
            // its Undo takes back only the step it was for (one undo stack per window): while that is still the step
            // ⌘Z would take back, the page undoes through the window's stack (windowUndo); after a later step, nothing
            let label = p["label"] as? String
            var t = Island.Toast(text: text, actionTitle: undo ? Loc.t("capture.undo", table: "Capture") : nil,
                                 action: undo ? { [weak self] in
                if let l = label, let um = self?.view.window?.undoManager, !(um.canUndo && um.undoActionName == l) {
                    NSSound.beep()
                    return answer("gone")
                }
                answer("undo")
            } : nil)
            t.key = "main.page"
            t.icon = done ? .check : nil
            t.gone = { answer("gone") }
            island.toast(t)
            if !undo { answer("shown") }
        case "registerUndo":
            registerPageStep(p["label"] as? String ?? "", undo: true, on: pageSteps)
            reply(nil, nil)
        case "windowUndo":          // ⌘Z / Z / a toast's Undo on the page, outside a text field: the window's next step
            if let um = view.window?.undoManager {
                if p["redo"] as? Bool == true { if um.canRedo { um.redo() } else { NSSound.beep() } }
                else if um.canUndo { um.undo() } else { NSSound.beep() }
            }
            reply(nil, nil)
        case "undone":
            if let uid = p["uid"] as? String { actions?.webUndid(uid) }
            reply(nil, nil)
        case "focusList":
            actions?.focusList()
            reply(nil, nil)
        case "confirmed":
            actions?.webWrote()
            if case .session(let u)? = scope(p) { ReviewHandoff.confirmed(session: u) }
            reply(nil, nil)
        default:
            reply(nil, "unknown method \(method)")
        }
    }

    /// The page's download button: a copy in Downloads, named after its batch.
    static func download(_ f: URL) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let base = f.lastPathComponent
        var dest = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((base as NSString).deletingPathExtension) \(n).\(f.pathExtension)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: f, to: dest)
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
            appDelegate?.toast(T("main.toast.downloaded", dest.lastPathComponent), icon: .check)
        } catch {
            NSLog("blurt download: %@", "\(error)")
            appDelegate?.toast(T("main.toast.download_failed"))
        }
    }

    // MARK: navigation: the page stays; links open natively

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        if u.scheme == SchemeHandler.scheme {
            if action.navigationType == .linkActivated, ["session", "file"].contains(u.host ?? ""),
               let f = u.host == "file" ? SchemeHandler.allowed(URL(fileURLWithPath: u.path), session: schemes.session)
                                         : SchemeHandler.resolve(String(u.path.dropFirst()), in: schemes.session) {
                NSWorkspace.shared.open(f)       // a frame / clip link: Preview / QuickTime
                return decisionHandler(.cancel)
            }
            return decisionHandler(.allow)
        }
        if ["about", "blob", "data"].contains(u.scheme ?? "") { return decisionHandler(.allow) }
        if ["vscode", "cursor", "zed", "windsurf", "http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url {
            if u.scheme == SchemeHandler.scheme, u.host == "file", let f = SchemeHandler.allowed(URL(fileURLWithPath: u.path), session: schemes.session) {
                NSWorkspace.shared.open(f)
            } else if u.scheme == SchemeHandler.scheme, u.host == "session", let f = SchemeHandler.resolve(String(u.path.dropFirst()), in: schemes.session) {
                NSWorkspace.shared.open(f)
            } else if ["http", "https", "mailto"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        if let w = view.window { a.beginSheetModal(for: w) { _ in completionHandler() } } else { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: T("action.ok"))
        a.addButton(withTitle: T("action.cancel"))
        if let w = view.window { a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(false) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
}

/// WKUserContentController retains its handlers: don't let it retain the controller.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// The line above an item that tells you what it is waiting for, with the things you can do about it (K3 actions;
/// the detail's state pill has the rest, and its work panel asks about an item waiting to be verified). The buttons
/// and tone come from SessionBannerPlan (BlurtCore): brand while the agent works, attn when it needs you, neutral
/// once the session is over — the first button is the primary.
/// Two buttons at most, the rest in a ⋯ menu (SessionBannerPlan.more), so the line keeps its words at a detail's width:
///   with an agent  "Handed off to Claude Code · Needs your input"                  [Open Session]
///   desktop app    "In Claude desktop · progress comes from the agent"             [Go to Claude] ⋯
///   no response    "Handed off to Codex · No response for a minute…"             [Open Session] [Restart Session] ⋯
///   failed         "Codex couldn’t start: Error: timed out …"                      [Restart Session] [Take Back] ⋯
///   with changes   "Handed off to Codex · Session ended, ready to review"          [Review Changes…] [Take Back] ⋯
///   session ended  "Handed off to Claude Code · Session ended without reporting back"
///                                                                     [Open Session] [Restart Session] ⋯
///   session gone   (the same line; nothing left to open)                         [Take Back] [Mark as Done]
///   handed out    "Copied to your agent. Mark it done when it is."              [Won't Do] [Mark as Done]
final class ItemBanner: NSView {
    var onAction: ((String) -> Void)?
    private let icon = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var height: NSLayoutConstraint!
    private var tint: NSColor = .clear
    /// The process job the "still organising" line points at.
    private(set) var processingJob: String?
    /// While the batch is still being organised (AI at work, §4): the brand arc in the icon's place. The banner's own
    /// quiet ink wash is the accent — no rim, no glow.
    private let spinner = BrandSpinner(size: 14)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        for v in [icon, spinner, text, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(tint == .labelColor ? 0.05 : 0.1).cgColor
    }

    /// (A suggested project is not a banner: the row says it — "Looks like X · Move" — and so does the page's "Where it
    /// came from"; a second, primary Move up here only repeated them.)
    func set(_ it: ItemRow?) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func button(_ t: String, _ a: String, primary: Bool = false) {
            let b: NSButton
            if primary {
                // the banner's one primary: the brand button (bezelColor can't carry the gradient)
                let p = BrandButton(title: t, target: self, action: #selector(tap(_:)))
                p.fontSize = 11.5
                p.hPad = 11
                p.radius = 6
                p.keyEquivalent = "\r"
                p.keyEquivalentModifierMask = [.command, .shift]
                b = p
            } else {
                b = NSButton(title: t, target: self, action: #selector(tap(_:)))
                b.bezelStyle = .rounded
                b.controlSize = .small
            }
            b.identifier = .init(a)
            buttons.addArrangedSubview(b)
        }
        processingJob = nil
        icon.contentTintColor = nil
        var organising = false
        defer { setWorking(organising) }
        guard let it = it, !it.discarded else { return hide() }
        let agent = it.workAgent.flatMap { AgentHub.shared.def($0)?.name } ?? it.workAgent
        let active = it.state == "handed_off" || it.state == "in_progress"
        let inSession = active && (it.workTo == "session" || it.workJob != nil)
        switch active ? (inSession ? "session" : "external") : it.state {
        case "to_verify":
            return hide()       // the detail's own work panel asks (Mark as done / Send back), next to the state pill
        case "session":
            icon.image = Look.ring(it.state, size: 16)
            let who = agent ?? T("main.banner.agent")
            let work = WorkSession.of(state: it.state, to: it.workTo ?? "session", job: it.workJob, lookup: JobStore.shared.job) ?? .gone
            let job = it.workJob.flatMap { JobStore.shared.job($0) }
            let outcome = job.map(SessionOutcome.of)
            let stalled = job?.agent?.stalled ?? false
            let desktop = job?.agent?.isDesktop ?? false
            let app = job?.agent.map { DesktopApp.name($0.agent) } ?? ""
            let reports = !(job?.agent?.desktopNeedsMarking ?? false)
            let plan = SessionBannerPlan.plan(work, outcome: outcome, stalled: stalled, desktop: desktop,
                                              worktree: job?.agent?.worktree != nil, reports: reports)
            switch plan.tone {
            case .brand: tint = BrandColor.ink
            case .attn: tint = BrandColor.attn
            case .neutral: tint = .labelColor
            }
            switch (work, outcome) {
            case (.live, _) where desktop:
                // nothing here is live: only the agent's reports move the item — and without the blurt MCP, nothing
                // does: say so instead of promising progress
                text.stringValue = T(reports ? "main.banner.desktop" : "main.banner.desktop.no_mcp", app)
            case (.live, _) where stalled:
                text.stringValue = T("main.banner.with_agent", who, T("main.banner.no_response"))
            case (.live(let st), _):
                text.stringValue = T("main.banner.with_agent", who, T("session.\(st.rawValue)"))
            case (.ended, .failed(let atStart)?):
                // it couldn't work: say why in its own words (job.error), then start again or take the items back
                let why = job.flatMap { JobLook.errorText($0) } ?? T("session.error")
                text.stringValue = T(atStart ? "main.banner.failed_start" : "main.banner.failed", who, why)
                icon.image = Look.symbol("exclamationmark.circle", "", size: 14)
                icon.contentTintColor = BrandColor.err
            case (.ended, .review?):
                text.stringValue = T("main.banner.with_agent", who, T("main.banner.ended_review"))
            default:
                text.stringValue = T("main.banner.with_agent", who, T("main.banner.ended"))
            }
            for (k, a) in plan.actions.enumerated() {
                button(a == "desktop" ? T("main.banner.go_desktop", app) : Self.title(a), a, primary: k == 0)
            }
            if !plan.more.isEmpty { moreButton(plan.more) }
        case "external":
            tint = BrandColor.ink
            icon.image = Look.ring(it.state, size: 16)
            text.stringValue = T("main.banner.external")
            button(StateMenu.title("wontfix"), "wontfix")
            button(StateMenu.title("done"), "done", primary: true)
        default:
            // the batch it came from is still being organised: the item fills in as the agent goes
            if let dir = it.sessionDir, let j = JobStore.shared.active.first(where: { $0.type == .process && $0.session?.path == dir }) {
                tint = BrandColor.ink
                icon.image = Look.symbol("sparkles", "", size: 13)
                icon.contentTintColor = BrandColor.ink
                text.stringValue = T("main.banner.organizing", JobLook.status(j))
                processingJob = j.id
                organising = true
                button(T("main.banner.show_progress"), "progress", primary: true)
            } else {
                return hide()
            }
        }
        isHidden = false
        height.constant = 44
        needsDisplay = true
        setAccessibilityLabel(text.stringValue)
    }

    private func hide() {
        isHidden = true
        height.constant = 0
    }

    private func setWorking(_ on: Bool) {
        icon.isHidden = on
        on ? spinner.startAnimation() : spinner.stopAnimation()
    }

    @objc func tap(_ b: NSButton) {
        guard let a = b.identifier?.rawValue else { return }
        if a == "restart" || a == "take_back" { b.isEnabled = false }   // once: the next set() brings it back
        onAction?(a)
    }

    /// The ⋯ menu with the plan's other actions.
    private func moreButton(_ actions: [String]) {
        let menu = NSMenu()
        for a in actions {
            let i = NSMenuItem(title: Self.title(a), action: #selector(menuTap(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = a
            menu.addItem(i)
        }
        let b = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: T("main.banner.more"))!,
                         target: self, action: #selector(showMore(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.isBordered = false
        b.toolTip = T("main.banner.more")
        b.menu = menu
        b.identifier = .init("more")
        buttons.addArrangedSubview(b)
    }

    @objc private func showMore(_ b: NSButton) {
        b.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    @objc private func menuTap(_ i: NSMenuItem) { (i.representedObject as? String).map { onAction?($0) } }

    /// The banner's actions, inline and in its menu (self-tests).
    var actionIDs: [String] {
        buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.identifier?.rawValue }.filter { $0 != "more" }
            + (buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.menu }.first?.items.compactMap { $0.representedObject as? String } ?? [])
    }

    /// A banner action's button title (SessionBannerPlan ids).
    static func title(_ action: String) -> String {
        switch action {
        case "session": return T("main.banner.open_session")
        case "review": return T("main.banner.review")
        case "restart": return T("main.banner.restart")
        default: return StateMenu.title(action)        // done, take_back, wontfix
        }
    }
}

/// The item pane's ground: the material the list column stands on (a content list's `contentBackground`: white in
/// light, the wallpaper-tinted dark in dark), so the detail isn't a second grey beside the list. The page in item
/// mode is transparent over it.
final class PaneSurface: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .contentBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
