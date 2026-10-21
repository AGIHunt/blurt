// The detail column: the shared review component in a WKWebView, hosted per contract C6 (host 'macos').
//   page   blurt-app://ui/index.html?session=<abs>&mode=item|review&item=<id>&platform=mac&theme=auto (SchemeHandler)
//   JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params})
//   native → JS   window.__blurtReply(id, result, error)
//   methods       load, poll, sendOps (→ items.py user-ops --stdin), fileUrl, reveal, quickLook, openCode, fixWithAgent,
//                 registerDragRects (→ DragOverlay)
//   switching items without a reload: window.__blurtShowItem(itemId) → true when the page could (C6, macos host)
// Today's review.html (no bridge yet) still works: SchemeHandler answers its review.py endpoints, and a small adapter
// script gives it __blurtShowItem and reports its frames for native drag-out. With WP3's build the adapter steps
// aside as soon as the page calls registerDragRects itself.
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
    func webWrote()
}

final class WebHostController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var actions: WebHostActions?
    private(set) var web: WKWebView!
    let overlay = DragOverlay()
    let schemes = SchemeHandler()
    let placeholder = EmptyStateView()
    private var loadedSession: URL?
    private var loadedMode = ""
    private var pendingItem: String?
    private var adapterOff = false
    private(set) var currentItem: ItemRow?
    private(set) var currentSession: SessionRow?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(schemes, forURLScheme: SchemeHandler.scheme)
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "blurt")
        ucc.addUserScript(WKUserScript(source: Self.bootScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.adapterScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
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
        schemes.onWrite = { [weak self] in self?.actions?.webWrote() }
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
        showNothing()
    }

    deinit { web?.configuration.userContentController.removeScriptMessageHandler(forName: "blurt") }

    /// The system accent colour and platform go in before the page's first paint (§2.4).
    static func bootScript() -> String {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let hex = String(format: "#%02X%02X%02X", Int(accent.redComponent * 255), Int(accent.greenComponent * 255), Int(accent.blueComponent * 255))
        return """
        window.blurtApp={version:2,host:'macos'};
        document.documentElement.classList.add('in-app','in-main');
        document.documentElement.dataset.platform='mac';
        document.documentElement.style.setProperty('--system-accent','\(hex)');
        """
    }

    // MARK: what to show

    func showNothing(_ count: Int = 0) {
        currentItem = nil
        currentSession = nil
        overlay.set([])
        let msg = count > 1 ? L("选中了 \(count) 条 · ⌘↩ 交给 agent，空格预览", "\(count) items selected · ⌘↩ hands them to an agent, Space previews")
                            : L("在左边选一条 · J / K 上下切换，空格预览", "Pick an item · J / K to move, Space to preview")
        placeholder.show(symbol: nil, egg: Look.egg(kind: "note", size: NSSize(width: 30, height: 39)),
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
        if loadedSession == dir, loadedMode == "item" {
            web.evaluateJavaScript("window.__blurtShowItem ? window.__blurtShowItem(\(Self.js(item.itemID))) : false") { [weak self] r, _ in
                if (r as? Bool) != true { self?.load(dir, mode: "item", item: item.itemID) }
            }
            return
        }
        load(dir, mode: "item", item: item.itemID)
    }

    func show(session s: SessionRow) {
        currentItem = nil
        currentSession = s
        if s.processing || !s.processed {
            web.isHidden = true
            overlay.isHidden = true
            if s.processing {
                placeholder.show(symbol: nil, title: L("Agent 正在整理…", "An agent is organising it…"),
                                 message: L("条目整理好以后会出现在这里。", "Items appear here as soon as they're ready."), busy: true)
            } else {
                let what = s.mode == "shots" ? L("这批截图（\(s.shotCount) 张）还没整理。", "This snap batch (\(s.shotCount) shots) hasn't been processed.")
                                             : L("这段录屏还没整理成条目。", "This recording hasn't been turned into items yet.")
                placeholder.show(symbol: nil, egg: Look.sessionEgg(s, size: NSSize(width: 30, height: 39)), title: MainModel.title(of: s),
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
        pendingItem = item
        adapterOff = false
        overlay.set([])
        schemes.session = dir
        var c = URLComponents()
        c.scheme = SchemeHandler.scheme
        c.host = "ui"
        c.path = "/index.html"
        c.queryItems = [URLQueryItem(name: "session", value: dir.path), URLQueryItem(name: "mode", value: mode),
                        URLQueryItem(name: "platform", value: "mac"), URLQueryItem(name: "theme", value: "auto"),
                        URLQueryItem(name: "in", value: "app")] + (item.map { [URLQueryItem(name: "item", value: $0)] } ?? [])
        web.load(URLRequest(url: c.url!))
    }

    static func js(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // MARK: JS → native

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if let type = m["type"] as? String {            // today's review.html
            if type == "confirmed" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.reload() }
                actions?.webWrote()
            }
            return
        }
        guard let method = m["method"] as? String else { return }
        let id = m["id"]
        let p = m["params"] as? [String: Any] ?? [:]
        call(method, p) { [weak self] result, error in
            guard let self = self, let id = id, !(id is NSNull), (id as? Int) != 0 else { return }
            let payload: [Any] = [id, result ?? NSNull(), error.map { $0 as Any } ?? NSNull()]
            guard let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) else { return }
            self.web.evaluateJavaScript("window.__blurtReply && window.__blurtReply(...\(s))")
        }
    }

    /// One C6 host method. `reply(result, error)`.
    func call(_ method: String, _ p: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        let session = loadedSession
        func file(_ rel: Any?) -> URL? { (rel as? String).flatMap { SchemeHandler.resolve($0, in: session) } }
        switch method {
        case "load", "poll":
            guard let s = session else { return reply(nil, "no session") }
            let raw = (try? Data(contentsOf: s.appendingPathComponent("items.json"))) ?? Data("{\"items\": []}".utf8)
            let tag = SchemeHandler.etag(raw)
            if method == "poll", p["etag"] as? String == tag { return reply(["etag": tag], nil) }
            let doc = (try? JSONSerialization.jsonObject(with: raw)) ?? ["items": []]
            reply(["doc": doc, "etag": tag], nil)
        case "sendOps":
            guard let s = session else { return reply(nil, "no session") }
            let ops = p["ops"] as? [[String: Any]] ?? []
            Scripts.userOps(s, ops, confirm: p["confirm"] as? Bool ?? false) { [weak self] r in
                switch r {
                case .success(let etag): reply(["ok": true, "etag": etag], nil); self?.actions?.webWrote()
                case .failure(let e): reply(["ok": false, "etag": ""], "\(e)")
                }
            }
        case "fileUrl":
            reply("blurt-app://session/" + ((p["rel"] as? String) ?? "").split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"), nil)
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
            guard let s = session else { return reply(nil, "no session") }
            let ids = p["itemIds"] as? [String] ?? []
            actions?.fixWithAgent(uids: Self.uids(of: ids, in: s))
            reply(nil, nil)
        case "registerDragRects":
            let fromAdapter = p["source"] as? String == "adapter"
            if !fromAdapter && !adapterOff {
                adapterOff = true
                web.evaluateJavaScript("window.__blurtAdapterOff = true")
            }
            if fromAdapter && adapterOff { return reply(nil, nil) }
            let rects = (p["rects"] as? [[String: Any]] ?? []).compactMap { r -> DragRect? in
                guard let f = file(r["rel"]) else { return nil }
                func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                return DragRect(rect: CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")), file: f)
            }
            overlay.set(rects)
            reply(nil, nil)
        case "capabilities":
            reply(["reveal": true, "quickLook": true, "openCode": true, "fixWithAgent": actions?.canFix() ?? false,
                   "registerDragRects": true], nil)
        default:
            reply(nil, "unknown method \(method)")
        }
    }

    /// Item ids of this session → uids (items.json uid, else the legacy uid of C1).
    static func uids(of ids: [String], in session: URL) -> [String] {
        let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: session.appendingPathComponent("items.json")))) as? [String: Any]
        let items = doc?["items"] as? [[String: Any]] ?? []
        return ids.map { id in
            if let u = items.first(where: { $0["id"] as? String == id })?["uid"] as? String, !u.isEmpty { return u }
            return legacyUID(session: session, id: id)
        }
    }

    /// C1: "L" + sha1("<session dir name>/<id>").hex[:25]
    static func legacyUID(session: URL, id: String) -> String {
        "L" + SchemeHandler.sha1Hex(Data("\(session.resolvingSymlinksInPath().lastPathComponent)/\(id)".utf8)).prefix(25)
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = pendingItem {
            pendingItem = nil
            // today's page loads its data asynchronously: wait for it, then focus the item
            web.evaluateJavaScript("""
                (function f(n){ if (window.__blurtShowItem && window.__blurtShowItem(\(Self.js(id)))) return;
                  if (n < 60) setTimeout(function(){ f(n + 1) }, 50) })(0)
                """)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        if u.scheme == SchemeHandler.scheme || u.scheme == "about" || u.scheme == "blob" || u.scheme == "data" {
            // a frame / clip link (old page: /files/…): open it natively instead of navigating away
            if action.navigationType == .linkActivated, u.host == "ui", u.path.hasPrefix("/files/"),
               let f = SchemeHandler.resolve(String(u.path.dropFirst(7)), in: loadedSession) {
                NSWorkspace.shared.open(f)
                return decisionHandler(.cancel)
            }
            if action.navigationType == .linkActivated, u.host == "session", let f = SchemeHandler.resolve(String(u.path.dropFirst()), in: loadedSession) {
                NSWorkspace.shared.open(f)
                return decisionHandler(.cancel)
            }
            return decisionHandler(.allow)
        }
        if ["vscode", "cursor", "zed", "http", "https", "mailto", "file"].contains(u.scheme ?? "") {
            NSWorkspace.shared.open(u)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url {
            if u.scheme == SchemeHandler.scheme, u.host == "ui", u.path.hasPrefix("/files/"),
               let f = SchemeHandler.resolve(String(u.path.dropFirst(7)), in: loadedSession) {
                NSWorkspace.shared.open(f)
            } else if u.scheme != SchemeHandler.scheme {
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

    // MARK: the adapter for today's review.html

    static let adapterScript = """
    (function(){
      if (window.__blurtAdapter) return; window.__blurtAdapter = true;
      var post = function(method, params){ try { webkit.messageHandlers.blurt.postMessage({id: 0, method: method, params: params}) } catch (e) {} };
      // switch items without reloading (the C6 hook; WP3's component defines its own)
      if (!window.__blurtShowItem) window.__blurtShowItem = function(id){
        try {
          if (typeof data === 'undefined' || typeof go !== 'function' || typeof loaded === 'undefined' || !loaded) return false;
          var k = data.items.findIndex(function(i){ return i.id === id }); if (k < 0) return false;
          if (typeof view !== 'undefined' && view !== 'focus' && typeof setView === 'function') setView('focus');
          go(k); return true;
        } catch (e) { return false }
      };
      var relOf = function(src){
        try { var u = new URL(src, location.href);
          if (u.protocol === 'blurt-app:' && u.host === 'session') return decodeURIComponent(u.pathname.slice(1));
          if (u.protocol === 'blurt-app:' && u.pathname.indexOf('/files/') === 0) return decodeURIComponent(u.pathname.slice(7));
        } catch (e) {}
        return null;
      };
      var last = '';
      function report(){
        if (window.__blurtAdapterOff) return;
        var rects = [];
        document.querySelectorAll('img').forEach(function(img){
          var rel = relOf(img.currentSrc || img.src); if (!rel || img.offsetParent === null) return;
          var r = img.getBoundingClientRect(); if (r.width < 24 || r.height < 24) return;
          var x = Math.max(0, r.left), y = Math.max(0, r.top), x2 = Math.min(innerWidth, r.right), y2 = Math.min(innerHeight, r.bottom);
          if (x2 - x < 8 || y2 - y < 8) return;
          var top = document.elementFromPoint((x + x2) / 2, (y + y2) / 2);
          var modal = '[role=dialog],dialog,.modal,.overlay';
          if (top && top !== img && top.closest && top.closest(modal) && !img.closest(modal)) return;   // covered by a dialog
          rects.push({x: x, y: y, w: x2 - x, h: y2 - y, rel: rel});
        });
        var s = JSON.stringify(rects); if (s === last) return; last = s;
        post('registerDragRects', {rects: rects, source: 'adapter'});
      }
      var raf = 0; var sched = function(){ if (!raf) raf = requestAnimationFrame(function(){ raf = 0; report() }) };
      addEventListener('scroll', sched, true); addEventListener('resize', sched); addEventListener('load', sched, true);
      document.addEventListener('transitionend', sched, true);
      new MutationObserver(sched).observe(document.documentElement, {subtree: true, childList: true, attributes: true,
        attributeFilter: ['src', 'class', 'style', 'hidden']});
      setInterval(report, 1000);
    })();
    """
}

/// WKUserContentController retains its handlers: don't let it retain the controller.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
