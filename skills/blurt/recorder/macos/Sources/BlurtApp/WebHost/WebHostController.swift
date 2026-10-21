// The detail column: the shared review component (WP3's review.html) in a WKWebView, hosted per contract C6 (macos).
//   page          blurt-app://ui/index.html?session=<abs>&mode=item|review&item=<uid>&platform=mac&theme=auto&lang=…
//   document start window.blurtHostInfo = {host: "macos", methods: [what we implement], accent: "#rrggbb"}
//   JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params})
//   native → JS   window.__blurtReply(id, result, null) / (id, null, "message"); id 0 = notification, no reply
//   requests      load → {doc, etag}; poll {etag} → {etag} | {doc, etag}; sendOps {ops, confirm} → {ok, etag}
//                 (items.py user-ops SESSION --stdin [--confirm]; the page re-reads with poll)
//   notifications reveal {rel}, quickLook {rel}, openCode {ref}, fixWithAgent {itemIds}, registerDragRects {rects},
//                 download {rel}, confirmed {}
//   switching     window.blurtReview.setItem(id) for another item of the same session; another session reloads
//   live updates  window.__blurtSetAccent(hex) when the system accent changes
// Reference native side: web/packages/review/e2e/wkwebview/Harness.swift.
//
// Unprocessed / processing sessions and "nothing selected" are native panels, not the web view.
import AppKit
import BlurtCore
import WebKit

protocol WebHostActions: AnyObject {
    func reveal(file: URL)
    func quickLook(files: [URL])
    func openCode(_ ref: String, session: URL)
    func fixWithAgent(uids: [String])
    func process(session: URL)
    func canFix() -> Bool
    func webWrote(_ session: URL)
}

final class WebHostController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var actions: WebHostActions?
    private(set) var web: WKWebView!
    let overlay = DragOverlay()
    let schemes = SchemeHandler()
    let placeholder = EmptyStateView()
    private var loadedSession: URL?
    private var loadedMode = ""
    private var loadedCanFix = false
    private(set) var currentItem: ItemRow?
    private(set) var currentSession: SessionRow?
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
        web.setAccessibilityLabel(L("条目详情", "Item detail"))
        overlay.web = web
        placeholder.onButton = { [weak self] tag in
            guard let self = self, tag == 1, let s = self.currentSession else { return }
            self.actions?.process(session: s.url)
        }
        for v in [web!, overlay, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                         v.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        }
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            overlay.topAnchor.constraint(equalTo: web.topAnchor),
            placeholder.topAnchor.constraint(equalTo: root.topAnchor),
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

    /// The optional host methods we implement; fixWithAgent only while WP6 has set the hook.
    var methods: [String] {
        ["reveal", "quickLook", "openCode", "registerDragRects", "download"] + ((actions?.canFix() ?? false) ? ["fixWithAgent"] : [])
    }

    private func installHostInfo() {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        let methodsJSON = (try? String(data: JSONSerialization.data(withJSONObject: methods), encoding: .utf8)) ?? "[]"
        ucc.addUserScript(WKUserScript(source: """
            window.blurtHostInfo = {host: "macos", methods: \(methodsJSON), accent: "\(Self.accentHex())"};
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: what to show

    func showNothing(_ count: Int = 0) {
        currentItem = nil
        currentSession = nil
        overlay.set([])
        let msg = count > 1 ? L("选中了 \(count) 条 · ⌘↩ 交给 agent，空格预览", "\(count) items selected · ⌘↩ hands them to an agent, Space previews")
                            : L("在左边选一条 · J / K 上下切换，空格预览", "Pick an item · J / K to move, Space to preview")
        placeholder.show(symbol: nil, image: BrandIcon.image(.egg, size: 30),
                         title: count > 1 ? L("多条条目", "Multiple items") : L("没有选中条目", "No selection"), message: msg)
        web.isHidden = true
        overlay.isHidden = true
    }

    func show(item: ItemRow) {
        currentItem = item
        currentSession = nil
        let dir = item.sessionURL
        guard FileManager.default.fileExists(atPath: dir.path) else {
            placeholder.show(symbol: "questionmark.folder", title: L("会话目录不见了", "The session folder is gone"),
                             message: (dir.path as NSString).abbreviatingWithTildeInPath)
            web.isHidden = true; overlay.isHidden = true
            return
        }
        placeholder.isHidden = true
        web.isHidden = false
        overlay.isHidden = false
        if loadedSession == dir, loadedMode == "item", loadedCanFix == (actions?.canFix() ?? false) {
            web.evaluateJavaScript("window.blurtReview && window.blurtReview.setItem ? (window.blurtReview.setItem(\(Self.js(item.itemID))), true) : false") { [weak self] r, _ in
                if (r as? Bool) != true { self?.load(dir, mode: "item", item: item.itemID) }
            }
            return
        }
        load(dir, mode: "item", item: item.itemID)    // the item id: legacy items have no uid in the file
    }

    func show(session s: SessionRow) {
        currentItem = nil
        currentSession = s
        if s.processing || !s.processed {
            web.isHidden = true
            overlay.isHidden = true
            overlay.set([])
            if s.processing {
                placeholder.show(symbol: nil, title: L("Agent 正在整理…", "An agent is organising it…"),
                                 message: L("条目整理好以后会出现在这里。", "Items appear here as soon as they're ready."), busy: true)
            } else {
                let what = s.mode == "shots" ? L("这批截图（\(s.shotCount) 张）还没整理。", "This snap batch (\(s.shotCount) shots) hasn't been processed.")
                                             : L("这段录屏还没整理成条目。", "This recording hasn't been turned into items yet.")
                placeholder.show(symbol: nil, image: BrandIcon.sessionImage(s, size: 30), title: MainModel.title(of: s),
                                 message: what + " " + L("交给 agent，它会写出问题、想法和笔记，你再来审核。", "Hand it to an agent: it writes the issues, ideas and notes, then you review them."),
                                 buttons: [(L("交给 Agent 整理", "Process with Agent"), 1)])
            }
            return
        }
        placeholder.isHidden = true
        web.isHidden = false
        overlay.isHidden = false
        if loadedSession == s.url, loadedMode == "review" { return }
        load(s.url, mode: "review", item: nil)
    }

    func reload() { if let s = loadedSession { load(s, mode: loadedMode, item: currentItem?.itemID) } }

    private func load(_ dir: URL, mode: String, item: String?) {
        loadedSession = dir
        loadedMode = mode
        loadedCanFix = actions?.canFix() ?? false
        overlay.set([])
        schemes.session = dir
        installHostInfo()
        var c = URLComponents()
        c.scheme = SchemeHandler.scheme
        c.host = "ui"
        c.path = "/index.html"
        c.queryItems = [URLQueryItem(name: "session", value: dir.path), URLQueryItem(name: "mode", value: mode),
                        URLQueryItem(name: "platform", value: "mac"), URLQueryItem(name: "theme", value: "auto"),
                        URLQueryItem(name: "lang", value: opts.lang)] + (item.map { [URLQueryItem(name: "item", value: $0)] } ?? [])
        web.load(URLRequest(url: c.url!))
    }

    static func js(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
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

    /// One C6 host method. `reply(result, error)`; notifications reply nil.
    func call(_ method: String, _ p: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let session = loadedSession
        func file(_ rel: Any?) -> URL? { (rel as? String).flatMap { SchemeHandler.resolve($0, in: session) } }
        switch method {
        case "load", "poll":
            guard let s = session else { return reply(nil, "no session") }
            let (doc, tag) = SchemeHandler.document(s)
            if method == "poll", p["etag"] as? String == tag { return reply(["etag": tag], nil) }
            reply(["doc": doc, "etag": tag], nil)
        case "sendOps":
            guard let s = session else { return reply(nil, "no session") }
            let ops = p["ops"] as? [[String: Any]] ?? []
            Scripts.userOps(s, ops, confirm: p["confirm"] as? Bool ?? false) { [weak self] r in
                switch r {
                case .success(let etag): reply(["ok": true, "etag": etag], nil); self?.actions?.webWrote(s)
                case .failure(let e): reply(nil, "\(e)")
                }
            }
        case "reveal":
            if let f = file(p["rel"]) { actions?.reveal(file: f) }
            reply(nil, nil)
        case "quickLook":
            if let f = file(p["rel"]) { actions?.quickLook(files: [f]) }
            reply(nil, nil)
        case "openCode":
            if let r = p["ref"] as? String, let s = session { actions?.openCode(r, session: s) }
            reply(nil, nil)
        case "fixWithAgent":
            if let s = session { actions?.fixWithAgent(uids: Self.uids(of: p["itemIds"] as? [String] ?? [], in: s)) }
            reply(nil, nil)
        case "registerDragRects":
            let rects = (p["rects"] as? [[String: Any]] ?? []).compactMap { r -> DragRect? in
                guard let f = file(r["rel"]) else { return nil }
                func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                return DragRect(rect: CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")), file: f)
            }
            overlay.set(rects)
            reply(nil, nil)
        case "download":
            if let f = file(p["rel"]), let s = session { Self.download(f, session: s) }
            reply(nil, nil)
        case "confirmed":
            if let s = session { actions?.webWrote(s) }
            reply(nil, nil)
        default:
            reply(nil, "unknown method \(method)")
        }
    }

    /// Item ids or uids of this session → uids (items.json uid, else the legacy uid of C1).
    static func uids(of ids: [String], in session: URL) -> [String] {
        let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: session.appendingPathComponent("items.json")))) as? [String: Any]
        let items = doc?["items"] as? [[String: Any]] ?? []
        return ids.map { id in
            if items.contains(where: { $0["uid"] as? String == id }) { return id }
            if let u = items.first(where: { $0["id"] as? String == id })?["uid"] as? String, !u.isEmpty { return u }
            return id.count == 26 ? id : legacyUID(session: session, id: id)
        }
    }

    /// C1: "L" + sha1("<session dir name>/<id>").hex[:25]
    static func legacyUID(session: URL, id: String) -> String {
        "L" + SchemeHandler.sha1Hex(Data("\(session.resolvingSymlinksInPath().lastPathComponent)/\(id)".utf8)).prefix(25)
    }

    /// The page's ⤓: a copy in Downloads named after the session, like review.py's ?download=1.
    static func download(_ f: URL, session: URL) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let base = "\(session.lastPathComponent)-\(f.lastPathComponent)"
        var dest = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((base as NSString).deletingPathExtension) \(n).\(f.pathExtension)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: f, to: dest)
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
            (NSApp.delegate as? App)?.toast(L("已下载到「下载」：", "Saved to Downloads: ") + dest.lastPathComponent)
        } catch {
            (NSApp.delegate as? App)?.toast(L("下载失败：", "Download failed: ") + error.localizedDescription)
        }
    }

    // MARK: navigation: the page stays; links open natively

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        if u.scheme == SchemeHandler.scheme {
            if action.navigationType == .linkActivated, u.host == "session", let f = SchemeHandler.resolve(String(u.path.dropFirst()), in: loadedSession) {
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
            if u.scheme == SchemeHandler.scheme, u.host == "session", let f = SchemeHandler.resolve(String(u.path.dropFirst()), in: loadedSession) {
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
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: L("取消", "Cancel"))
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
