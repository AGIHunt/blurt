// The review page in a native Blurt window (WKWebView on review.py's local server) instead of the browser.
// config review.open_in: "app" (default) | "browser".
//
// Ways in:
//  • the app's own processing runs review.py --open none and reads "REVIEW <url>" from its stdout (ReviewHub.openSession);
//  • review.py started by an agent in a terminal posts the distributed notification dev.blurt.recorder.review
//    {url, session, title, home} — only the instance whose BLURT_HOME matches takes it — or, when no Blurt is running,
//    launches the app with --background --review <url> [--review-session <dir>];
//  • the menu: Recent recordings → Open review.
// The page knows it's in the app (window.blurtApp) and reports back through window.webkit.messageHandlers.blurt:
// "confirmed" (完成审核 → the window closes), "title".

import AppKit
import WebKit

final class ReviewHub: NSObject {
    static let shared = ReviewHub()
    var windows: [ReviewWindow] = []
    var procs: [String: Process] = [:]          // session path → review.py the app started
    var urls: [String: URL] = [:]               // session path → its live review URL (ours or an agent's)
    var quitting = false

    var openInApp: Bool { (readConfig()["review"] as? [String: Any])?["open_in"] as? String != "browser" }

    func listen() {
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.review"), object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo, let s = info["url"] as? String, let url = URL(string: s) else { return }
            if let home = info["home"] as? String, !home.isEmpty,
               URL(fileURLWithPath: home).standardizedFileURL.path != blurtHome.standardizedFileURL.path { return }
            self?.open(url, session: (info["session"] as? String).map { URL(fileURLWithPath: $0) }, title: info["title"] as? String)
        }
    }

    /// The app's own review for a processed session: reuse a live server, else start review.py and wait for its URL.
    @discardableResult
    func openSession(_ dir: URL) -> Bool {
        if let u = urls[dir.path], alive(u) { open(u, session: dir, title: nil); return true }
        guard let skill = readConfig()["skill_dir"] as? String,
              FileManager.default.fileExists(atPath: "\(skill)/scripts/review.py"), let uv = findExecutable("uv") else { return false }
        if !openInApp {
            shell("\(shq(uv)) run -q \(shq("\(skill)/scripts/review.py")) \(shq(dir.path)) --open browser", cwd: dir,
                  log: dir.appendingPathComponent("review.log")) { _ in }
            return true
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "-q", "\(skill)/scripts/review.py", dir.path, "--open", "none"]
        p.environment = agentEnvironment()
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let logURL = dir.appendingPathComponent("review.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: logURL)
        var buf = ""
        var opened = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: chunk, as: UTF8.self)
            appendLog(logURL, s)
            buf += s
            guard !opened, let r = buf.range(of: "REVIEW "), let end = buf[r.upperBound...].firstIndex(of: "\n"),
                  let u = URL(string: String(buf[r.upperBound..<end])) else { return }
            opened = true
            DispatchQueue.main.async {
                self?.urls[dir.path] = u
                self?.open(u, session: dir, title: nil)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.procs[dir.path] = nil
                self.urls[dir.path] = nil
                for w in self.windows where w.session?.path == dir.path { w.serverGone() }
            }
        }
        do { try p.run() } catch { return false }
        procs[dir.path] = p
        return true
    }

    func alive(_ u: URL) -> Bool {
        guard let api = URL(string: "api/items", relativeTo: u) else { return false }
        var req = URLRequest(url: api, timeoutInterval: 1.5)
        req.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, r, _ in ok = (r as? HTTPURLResponse)?.statusCode == 200; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    func open(_ url: URL, session: URL?, title: String?) {
        if let s = session { urls[s.path] = url }
        if let w = windows.first(where: { $0.base.host == url.host && $0.base.port == url.port }) {
            w.show()
            return
        }
        if !openInApp { NSWorkspace.shared.open(url); return }
        let w = ReviewWindow(url: url, session: session, title: title)
        windows.append(w)
        if windows.count == 1 { becomeRegularApp(true) }
        w.show()
    }

    func closed(_ w: ReviewWindow) {
        windows.removeAll { $0 === w }
        if windows.isEmpty { becomeRegularApp(false) }
    }

    /// While a review window is open Blurt is a normal app (Dock, ⌘Tab, a menu bar with Edit / View / Window), so the
    /// window can be found again and text fields get copy / paste / undo. Back to menu-bar-only after the last one.
    func becomeRegularApp(_ on: Bool) {
        if on {
            NSApp.mainMenu = ReviewHub.mainMenu()
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let hide = item(L("隐藏口喷鸡", "Hide Blurt"), #selector(NSApplication.hide(_:)), "h")
        let quit = item(L("退出口喷鸡", "Quit Blurt"), #selector(NSApplication.terminate(_:)), "")   // no ⌘Q: it's the resident app
        sub("Blurt", [hide, .separator(), quit])
        sub(L("编辑", "Edit"), [item(L("撤销", "Undo"), Selector(("undo:")), "z"), item(L("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
                                .separator(), item(L("剪切", "Cut"), #selector(NSText.cut(_:)), "x"), item(L("拷贝", "Copy"), #selector(NSText.copy(_:)), "c"),
                                item(L("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"), item(L("全选", "Select All"), #selector(NSText.selectAll(_:)), "a")])
        sub(L("显示", "View"), [item(L("重新载入", "Reload"), #selector(ReviewWindow.reload(_:)), "r"), .separator(),
                                item(L("放大", "Zoom In"), #selector(ReviewWindow.zoomIn(_:)), "+"),
                                item(L("缩小", "Zoom Out"), #selector(ReviewWindow.zoomOut(_:)), "-"),
                                item(L("实际大小", "Actual Size"), #selector(ReviewWindow.zoomReset(_:)), "0")])
        let win = [item(L("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
                   item(L("关闭窗口", "Close Window"), #selector(NSWindow.performClose(_:)), "w")]
        sub(L("窗口", "Window"), win)
        return main
    }
}

/// Dark / light colours behind the page while it loads and in the titlebar (the page's --bg in each theme).
let reviewBackground = NSColor(name: nil) { ap in
    ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.102, green: 0.098, blue: 0.094, alpha: 1)
                                                         : NSColor(srgbRed: 0.961, green: 0.957, blue: 0.945, alpha: 1)
}

final class ReviewWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    let base: URL
    let session: URL?
    var web: WKWebView!
    var titleObs: NSKeyValueObservation?
    var confirmed = false

    init(url: URL, session: URL?, title: String?) {
        base = url
        self.session = session
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 720, height: 520)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = reviewBackground
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: w)
        w.delegate = self
        w.title = title ?? ReviewWindow.sessionTitle(session) ?? L("口喷鸡 · 审核", "Blurt · Review")
        if let s = session { w.representedURL = s }
        if !w.setFrameUsingName("BlurtReview") { w.center() }
        w.setFrameAutosaveName("BlurtReview")

        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "blurt")
        ucc.addUserScript(WKUserScript(source: "window.blurtApp={version:1};document.documentElement.classList.add('in-app');",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 12.3, *) { cfg.preferences.isElementFullscreenEnabled = true }
        cfg.websiteDataStore = .nonPersistent()          // nothing to keep: the page's state lives in items.json
        web = WKWebView(frame: w.contentLayoutRect, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = false
        web.setValue(false, forKey: "drawsBackground")   // our background until the page paints: no white flash in dark mode
        if #available(macOS 13.3, *) { web.isInspectable = ProcessInfo.processInfo.environment["BLURT_INSPECT"] != nil }
        w.contentView = web
        titleObs = web.observe(\.title, options: [.new]) { [weak self] v, _ in
            guard let t = v.title, !t.isEmpty, t != "blurt · Review" else { return }
            self?.window?.title = t
        }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "in", value: "app")]   // review.py: "the app has it"
        web.load(URLRequest(url: c.url!))
    }
    required init?(coder: NSCoder) { fatalError() }

    static func sessionTitle(_ s: URL?) -> String? {
        guard let s = s, let d = try? Data(contentsOf: s.appendingPathComponent("items.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["title"] as? String, !t.isEmpty else { return nil }
        return t
    }

    func show() {
        activateApp()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()     // macOS 14+ may refuse to activate a background app: be in front anyway
        window?.makeFirstResponder(web)
    }

    @objc func reload(_ sender: Any?) { web.reload() }
    @objc func zoomIn(_ sender: Any?) { web.pageZoom = min(2, web.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { web.pageZoom = max(0.6, web.pageZoom - 0.1) }
    @objc func zoomReset(_ sender: Any?) { web.pageZoom = 1 }

    /// review.py exited (confirmed, or killed): nothing left to save to.
    func serverGone() {
        guard window?.isVisible == true else { return }
        if confirmed { close() }
    }

    func windowWillClose(_ notification: Notification) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "blurt")
        if !confirmed, !ReviewHub.shared.quitting, let s = session, ReviewHub.shared.urls[s.path] != nil {
            (NSApp.delegate as? App)?.toast(L("审核还没完成 · 菜单「最近的录制」→ 打开审核页 可以回来", "Review not finished · Recent recordings → Open review brings it back"))
        }
        ReviewHub.shared.closed(self)
    }

    // MARK: page → app

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "confirmed":
            confirmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let w = self?.window else { return }
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.25; w.animator().alphaValue = 0 }) { self?.close() }
            }
        case "title":
            if let t = m["title"] as? String, !t.isEmpty { window?.title = t }
        default: break
        }
    }

    // MARK: navigation: our server stays in the window, everything else goes to the browser

    func isOurs(_ u: URL?) -> Bool { u?.host == base.host && u?.port == base.port }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        if u.scheme == "about" || u.scheme == "blob" || u.scheme == "data" { return decisionHandler(.allow) }
        if !isOurs(u) {
            if action.navigationType == .linkActivated || action.targetFrame == nil || action.targetFrame?.isMainFrame == true {
                NSWorkspace.shared.open(u)
                return decisionHandler(.cancel)
            }
            return decisionHandler(.allow)        // a subresource from elsewhere (none today)
        }
        if #available(macOS 11.3, *), action.shouldPerformDownload { return decisionHandler(.download) }
        if action.targetFrame?.isMainFrame == true, u.path.hasPrefix("/files/"), let local = localFile(u), action.navigationType == .linkActivated {
            NSWorkspace.shared.open(local)       // a frame / clip link: Preview / QuickTime
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disp = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if #available(macOS 11.3, *), !response.canShowMIMEType || disp.lowercased().hasPrefix("attachment") { return decisionHandler(.download) }
        decisionHandler(.allow)
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var dest = dir.appendingPathComponent(suggestedFilename)
        let stem = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        downloads[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }
    var downloads: [ObjectIdentifier: URL] = [:]
    @available(macOS 11.3, *)
    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)   // bounces the Dock stack
        (NSApp.delegate as? App)?.toast(L("已下载到「下载」：", "Saved to Downloads: ") + dest.lastPathComponent)
    }
    @available(macOS 11.3, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        (NSApp.delegate as? App)?.toast(L("下载失败：", "Download failed: ") + error.localizedDescription)
    }

    func localFile(_ u: URL) -> URL? {
        guard let s = session else { return nil }
        let rel = String(u.path.dropFirst("/files/".count))
        let f = s.appendingPathComponent(rel).standardizedFileURL
        return f.path.hasPrefix(s.standardizedFileURL.path + "/") && FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    // target=_blank and window.open
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url {
            if isOurs(u), let local = localFile(u) { NSWorkspace.shared.open(local) } else if !isOurs(u) { NSWorkspace.shared.open(u) }
            else { webView.load(action.request) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        if let w = window { a.beginSheetModal(for: w) { _ in completionHandler() } } else { a.runModal(); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: L("取消", "Cancel"))
        if let w = window { a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(a.runModal() == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func loadFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let msg = L("审核页连不上了（review.py 已经退出？）", "The review page can't be reached (did review.py exit?)")
        web.loadHTMLString("""
            <html><body style="font:14px -apple-system;color:#8d8d93;background:transparent;display:grid;place-items:center;height:90vh;text-align:center">
            <div><div style="color:#8d8d93">\(BlurtIcon.chicken.svg(size: 34))</div><p>\(msg)</p><p style="font-size:12px">\(error.localizedDescription)</p></div></body></html>
            """, baseURL: nil)
    }
}
