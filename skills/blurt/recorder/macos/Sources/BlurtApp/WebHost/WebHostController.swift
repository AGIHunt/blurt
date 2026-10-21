// The detail column. Reviewing happens here — there is no separate review window and nothing opens by itself:
//   an item     the shared review component (web/packages/review → review.html) in a WKWebView, mode=item, with a
//               native banner above it when the item waits for you (to verify), is with an agent, or has a suggested
//               project;
//   a batch     the same component in review mode (the whole capture session: keep / drop / merge, then confirm);
//   a job       its step timeline (JobDetailView) and, for agent sessions, the embedded terminal (P3);
//   nothing     a quiet placeholder.
//
// Host protocol v3 (C6 + next-round.md "审核组件宿主协议 v3"):
//   page          blurt-app://ui/index.html?mode=item|review&item=<uid>&scope=<session abs | project:<id>>&platform=mac&theme=auto&lang=…
//   doc start     window.blurtHostInfo = {host: "macos", methods: [...], accent: "#rrggbb", scope: {...}}
//   JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params}); native → window.__blurtReply(id, result, error)
//   requests      load {scope?} → {doc, etag}             items.py doc SESSION | --project P
//                 poll {etag, scope?} → {etag} | {doc, etag}   items.py poll … --etag E
//                 sendOps {ops, confirm, scope?} → {ok, etag, doc}   items.py user-ops … --stdin [--confirm]
//                 handoff {uids, what} → {id, path, text}  handoff.py create --items … --mark (copied to the clipboard)
//   notifications reveal {path|rel}, quickLook {path|rel}, openCode {ref}, dispatch {uids} (fixWithAgent {itemIds} on v2
//                 pages), openSession {jobId}, registerDragRects {rects}, download {path|rel}, confirmed {}
import AppKit
import BlurtCore
import WebKit

protocol WebHostActions: AnyObject {
    func reveal(file: URL)
    func quickLook(files: [URL])
    func openCode(_ ref: String, item: ItemRow?)
    func dispatch(uids: [String])
    func handOff(uids: [String], what: String, reply: @escaping ([String: Any]?) -> Void)
    func setWork(_ state: String, uids: [String])
    func move(uids: [String], to project: String)
    func revealJob(_ id: String)
    func jobAction(_ action: String, job: Job)
    func webWrote()
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
    let jobView = JobDetailView()
    private var loadedScope: DocScope?
    private var loadedMode = ""
    private(set) var currentItem: ItemRow?
    private(set) var currentJob: Job?
    private var accentObserver: NSObjectProtocol?

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
        placeholder.onButton = { [weak self] tag in if tag == 1 { self?.actions?.webWrote() } }
        banner.onAction = { [weak self] a in self?.bannerAction(a) }
        jobView.onAction = { [weak self] a in
            guard let self = self, let j = self.currentJob else { return }
            self.actions?.jobAction(a, job: j)
        }
        for v in [banner, web!, overlay, placeholder, jobView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
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

    static func accentHex() -> String {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// The optional host methods we implement.
    var methods: [String] {
        ["reveal", "quickLook", "openCode", "registerDragRects", "download", "dispatch", "fixWithAgent", "handoff", "openSession", "fileUrl"]
    }

    private func installHostInfo(_ scope: DocScope) {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        let info: [String: Any] = ["host": "macos", "methods": methods, "accent": Self.accentHex(), "scope": scope.json,
                                   "lang": Loc.language, "inApp": true]
        let json = (try? JSONSerialization.data(withJSONObject: info)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        ucc.addUserScript(WKUserScript(source: "window.blurtHostInfo = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: what to show

    private func only(_ v: NSView?) {
        for x in [web!, overlay, placeholder, jobView] as [NSView] { x.isHidden = x !== v && !(v === web && x === overlay) }
        if v !== web { banner.set(nil); overlay.set([]) }
    }

    func showNothing(_ count: Int = 0) {
        currentItem = nil
        currentJob = nil
        let msg = count > 1 ? TP("main.detail.multi.detail", count) : T("main.detail.none.detail")
        placeholder.show(symbol: count > 1 ? "square.stack.3d.up" : "sidebar.right",
                         title: count > 1 ? TP("main.detail.multi", count) : T("main.detail.none"), message: msg)
        only(placeholder)
    }

    func show(item: ItemRow, projects: [ProjectEntry]) {
        currentItem = item
        currentJob = nil
        if item.legacy {
            placeholder.show(symbol: "clock.arrow.circlepath", title: T("main.detail.legacy"), message: T("main.detail.legacy.detail"))
            return only(placeholder)
        }
        if let e = item.parseError {
            placeholder.show(symbol: "exclamationmark.triangle", title: T("main.detail.parse_error"), message: e)
            return only(placeholder)
        }
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            placeholder.show(symbol: "questionmark.folder", title: T("main.detail.gone"), message: (item.fileURL.path as NSString).abbreviatingWithTildeInPath)
            return only(placeholder)
        }
        only(web)
        banner.set(item, suggested: item.suggestedProject.flatMap { s in projects.first { $0.id == s } })
        let scope: DocScope = item.sessionURL.map { .session($0) } ?? .project(item.projectID)
        if loadedScope == scope, loadedMode == "item" {
            web.evaluateJavaScript("window.blurtReview && window.blurtReview.setItem ? (window.blurtReview.setItem(\(Self.js(item.uid))), true) : false") { [weak self] r, _ in
                if (r as? Bool) != true { self?.load(scope, mode: "item", item: item.uid) }
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

    private func load(_ scope: DocScope, mode: String, item: String?) {
        loadedScope = scope
        loadedMode = mode
        overlay.set([])
        if case .session(let u) = scope { schemes.session = u } else { schemes.session = nil }
        installHostInfo(scope)
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
        case "done", "todo", "wontfix": actions?.setWork(a, uids: [it.uid])
        case "session": if let j = it.workJob { actions?.revealJob(j) }
        case "move": if let p = it.suggestedProject { actions?.move(uids: [it.uid], to: p) }
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

    /// One host method. `reply(result, error)`; notifications reply nil.
    func call(_ method: String, _ p: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let session = schemes.session
        func file(_ k: String = "path") -> URL? {
            ((p[k] ?? p["rel"]) as? String).flatMap { SchemeHandler.locate($0, session: session) }
        }
        switch method {
        case "load", "poll":
            guard let s = scope(p) else { return reply(nil, "no scope") }
            let args = method == "load" ? ["doc"] + s.args : ["poll"] + s.args + ["--etag", p["etag"] as? String ?? ""]
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
            Scripts.userOps(s.args, ops, confirm: p["confirm"] as? Bool ?? false) { [weak self] r in
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
        case "dispatch", "fixWithAgent":
            let ids = (p["uids"] ?? p["itemIds"]) as? [String] ?? []
            actions?.dispatch(uids: ids)
            reply(nil, nil)
        case "handoff":
            actions?.handOff(uids: p["uids"] as? [String] ?? [], what: p["what"] as? String ?? "instruction") { r in
                reply(r, r == nil ? "handoff failed" : nil)
            }
        case "openSession":
            if let j = p["jobId"] as? String { actions?.revealJob(j) }
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
        case "confirmed":
            actions?.webWrote()
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
            appDelegate?.toast(T("main.toast.downloaded", dest.lastPathComponent))
        } catch {
            appDelegate?.toast(T("main.toast.download_failed", error.localizedDescription))
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

/// The line above an item that tells you what it is waiting for, with the one or two things you can do about it:
///   to verify      "Claude Code says it's done. Check it, then mark it done."  [Reopen] [Mark as Done]
///   with an agent  "With Claude Code · Needs your input"                         [Open Session]
///   handed out     "Copied to your agent. Mark it done when it is."              [Mark as Done]
///   suggested      "Looks like it belongs in bug-agent (58%)."                  [Move]
final class ItemBanner: NSView {
    var onAction: ((String) -> Void)?
    private let icon = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var height: NSLayoutConstraint!
    private var tint: NSColor = .clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 6
        for v in [icon, text, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
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
        layer?.backgroundColor = tint.withAlphaComponent(0.1).cgColor
    }

    func set(_ it: ItemRow?, suggested: ProjectEntry? = nil) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func button(_ t: String, _ a: String, primary: Bool = false) {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.identifier = .init(a)
            b.bezelStyle = .rounded
            b.controlSize = .small
            if primary { b.bezelColor = .controlAccentColor; b.keyEquivalent = "\r"; b.keyEquivalentModifierMask = [.command, .shift] }
            buttons.addArrangedSubview(b)
        }
        guard let it = it, it.status != "deleted" else { return hide() }
        let agent = it.workAgent.flatMap { AgentHub.shared.def($0)?.name } ?? it.workAgent
        let active = it.workState == "handed_off" || it.workState == "in_progress"
        let inSession = active && (it.workTo == "session" || it.workJob != nil)
        switch active ? (inSession ? "session" : "external") : it.workState {
        case "to_verify":
            tint = StatusRing.attention
            icon.image = Look.ring("to_verify", size: 16)
            text.stringValue = agent.map { T("main.banner.to_verify", $0) } ?? T("main.banner.to_verify.anon")
            button(T("main.cmd.reopen"), "todo")
            button(T("main.cmd.mark_done"), "done", primary: true)
        case "session":
            tint = StatusRing.accent
            icon.image = Look.ring(it.workState, size: 16)
            let st = it.workJob.flatMap { JobStore.shared.job($0)?.agent?.status }.map { T("session.\($0.rawValue)") } ?? Look.workName(it.workState)
            text.stringValue = T("main.banner.with_agent", agent ?? T("main.banner.agent"), st)
            if it.workJob != nil { button(T("main.banner.open_session"), "session", primary: true) }
        case "external":
            tint = StatusRing.accent
            icon.image = Look.ring(it.workState, size: 16)
            text.stringValue = T("main.banner.external")
            button(T("main.cmd.wontfix"), "wontfix")
            button(T("main.cmd.mark_done"), "done", primary: true)
        default:
            if let s = suggested, it.projectID == "inbox" {
                tint = .controlAccentColor
                icon.image = Look.symbol("folder.badge.questionmark", "", size: 13)
                text.stringValue = T("main.banner.suggested", s.name, Loc.percent(it.suggestedConfidence ?? 0))
                button(T("main.banner.move"), "move", primary: true)
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

    @objc func tap(_ b: NSButton) { b.identifier.map { onAction?($0.rawValue) } }
}
