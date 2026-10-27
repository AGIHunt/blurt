// The review canvas in a real WKWebView with the C6 macos host: a reference implementation of the native side
// (WKURLSchemeHandler for blurt-app://ui/*, blurt-app://session/* and blurt-app://file/*, the "blurt" message bridge, items.py user-ops)
// plus an acceptance run against a fixture session. Not part of the app — WP5's WebHost implements the same contract
// (protocol v3, as WebHostController: load = items.py doc SESSION, poll = items.py poll … --etag, sendOps = items.py
// user-ops … --stdin [--confirm]; the session's items live in the Markdown store, here the scratch inbox).
//
//   BLURT_HOME=<scratch> BLURT_WORKSPACE=<scratch> swiftc -O Harness.swift -o harness && ./harness \
//       --html dist/index.html --session <copy of a fixture> --scripts skills/blurt/scripts --out <dir> [--icon icon.png] [--python python3]
// Prints one JSON line per check and a summary; exit 0 = all passed. scripts/wkwebview.mjs sets the scratch folders:
// without them items.py would file the fixture into the user's own ~/Blurt/inbox, so the harness refuses to run.

import AppKit
import UniformTypeIdentifiers
import WebKit

struct Opts {
    var html = "", session = "", scripts = "", out = "", icon = "", python = "python3"
}
var opts = Opts()
do {
    var a = CommandLine.arguments.dropFirst().makeIterator()
    while let k = a.next() {
        let v = a.next() ?? ""
        switch k {
        case "--html": opts.html = v
        case "--session": opts.session = v
        case "--scripts": opts.scripts = v
        case "--out": opts.out = v
        case "--icon": opts.icon = v
        case "--python": opts.python = v
        default: break
        }
    }
}
let sessionURL = URL(fileURLWithPath: opts.session).standardizedFileURL
let environment = ProcessInfo.processInfo.environment
guard let workspace = environment["BLURT_WORKSPACE"], environment["BLURT_HOME"] != nil else {
    FileHandle.standardError.write(Data("set BLURT_HOME and BLURT_WORKSPACE to scratch folders (scripts/wkwebview.mjs does)\n".utf8))
    exit(2)
}
let workspaceURL = URL(fileURLWithPath: workspace).standardizedFileURL

/// run a skill script; returns (exit code, stdout)
@discardableResult
func runScript(_ script: String, _ args: [String], stdin: Data? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [opts.python, "\(opts.scripts)/\(script)"] + args
    var env = ProcessInfo.processInfo.environment
    env["BLURT_NO_INDEX"] = "1"
    p.environment = env
    let out = Pipe(), inp = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = inp
    try? p.run()
    if let s = stdin { inp.fileHandleForWriting.write(s) }
    try? inp.fileHandleForWriting.close()
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    errDone.wait()
    if p.terminationStatus != 0 {
        // CI only shows this log: say why a script failed
        print("diag \(script) \(args.first ?? "") exit \(p.terminationStatus): \(String(decoding: errData, as: UTF8.self).suffix(800))")
        fflush(stdout)
    }
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// an items.py command's JSON answer (its last line)
func itemsPy(_ args: [String], stdin: Data? = nil) -> [String: Any]? {
    let (code, out) = runScript("items.py", args, stdin: stdin)
    guard code == 0, let line = out.split(separator: "\n").last else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
}
/// the session's doc, as the page gets it (every item, the discarded ones too)
func sessionDoc() -> [String: Any] {
    itemsPy(["doc", sessionURL.path])?["doc"] as? [String: Any] ?? ["items": []]
}
/// an item by the agent's draft id (I-003, kept as source.local_id) or its store id (IN-3)
func item(_ id: String) -> [String: Any]? {
    (sessionDoc()["items"] as? [[String: Any]])?.first {
        ($0["source"] as? [String: Any])?["local_id"] as? String == id || $0["id"] as? String == id
    }
}
func batchReviewed() -> Bool {
    let d = (try? Data(contentsOf: sessionURL.appendingPathComponent("batch.json"))) ?? Data()
    return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["reviewed"] as? Bool == true
}

// MARK: - blurt-app:// scheme

final class Scheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var file: URL?
        if url.host == "ui" {
            file = url.path == "/icon.png" ? URL(fileURLWithPath: opts.icon) : URL(fileURLWithPath: opts.html)
        } else if url.host == "file" {
            // protocol v3: blurt-app://file/<percent-encoded absolute path>; this harness serves its session and its
            // scratch Blurt folder (the inbox store, where the items' frames and clips are)
            let f = URL(fileURLWithPath: url.path).standardizedFileURL
            if [sessionURL, workspaceURL].contains(where: { f.path.hasPrefix($0.path + "/") }) { file = f }
        } else if url.host == "session" {
            let rel = String(url.path.dropFirst())   // URL.path is percent-decoded
            let f = sessionURL.appendingPathComponent(rel).standardizedFileURL
            if f.path.hasPrefix(sessionURL.path + "/") { file = f }    // no ../ out of the session
        }
        guard let f = file, let data = try? Data(contentsOf: f) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // <video> needs byte ranges, or WebKit won't play (or seek) a file from a custom scheme
        if let r = task.request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let parts = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let end = min(parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : data.count - 1, data.count - 1)
            let body = data.subdata(in: start..<(end + 1))
            task.didReceive(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Length": "\(body.count)", "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/\(data.count)"])!)
            task.didReceive(body)
        } else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Length": "\(data.count)", "Accept-Ranges": "bytes"])!)
            task.didReceive(data)
        }
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - the bridge: webkit.messageHandlers.blurt.postMessage({id, method, params}) → window.__blurtReply(id, result, error)

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    var notes: [[String: Any]] = []

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let method = m["method"] as? String else { return }
        let id = (m["id"] as? NSNumber)?.intValue ?? 0
        let params = m["params"] as? [String: Any] ?? [:]
        if id == 0 { notes.append(["method": method, "params": params]); return }   // fire-and-forget
        DispatchQueue.global().async { () -> Void in
            var result: Any = NSNull()
            var error: String?
            switch method {
            case "load", "poll":
                let args = method == "load" ? ["doc", sessionURL.path]
                    : ["poll", sessionURL.path, "--etag", params["etag"] as? String ?? ""]
                let o = itemsPy(args)
                if o?["ok"] as? Bool != true {
                    print("diag \(method): \(o.map { "\($0["ok"] ?? "nil") \($0["error"] ?? "")" } ?? "no JSON")"); fflush(stdout)
                }
                if let o = o, o["ok"] as? Bool == true {
                    var out: [String: Any] = ["etag": o["etag"] ?? ""]
                    if let doc = o["doc"] { out["doc"] = doc }
                    result = out
                } else { error = "items.py \(method) failed" }
            case "sendOps":
                let ops: Any = params["ops"] ?? [Any]()
                let body = try! JSONSerialization.data(withJSONObject: ["ops": ops])
                var args = ["user-ops", sessionURL.path, "--stdin"]
                if params["confirm"] as? Bool == true { args.append("--confirm") }
                if let o = itemsPy(args, stdin: body), o["ok"] as? Bool != false {
                    result = ["ok": true, "etag": o["etag"] ?? "", "doc": o["doc"] ?? NSNull()] as [String: Any]
                } else { error = "items.py user-ops failed" }
            default:
                error = "unknown method \(method)"
            }
            let r = String(decoding: try! JSONSerialization.data(withJSONObject: ["r": result]), as: UTF8.self)
            let e = error.map { String(decoding: try! JSONSerialization.data(withJSONObject: [$0]), as: UTF8.self) } ?? "[null]"
            DispatchQueue.main.async {
                self.web?.evaluateJavaScript("window.__blurtReply(\(id), (\(r)).r, (\(e))[0])")
            }
        }
    }
}

// MARK: - the run

func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1320, height: 860), styleMask: [.titled, .closable, .resizable],
                      backing: .buffered, defer: false)
window.title = "Blurt review — WKWebView harness"
let cfg = WKWebViewConfiguration()
let scheme = Scheme()
cfg.setURLSchemeHandler(scheme, forURLScheme: "blurt-app")
let bridge = Bridge()
let ucc = WKUserContentController()
ucc.add(bridge, name: "blurt")
let methods = ["reveal", "quickLook", "openCode", "dispatch", "registerDragRects", "download"]
ucc.addUserScript(WKUserScript(source: """
    window.blurtHostInfo = {host: "macos", methods: \(methods), accent: "\(hex(NSColor.controlAccentColor))"};
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
cfg.userContentController = ucc
cfg.mediaTypesRequiringUserActionForPlayback = []
let web = WKWebView(frame: window.contentLayoutRect, configuration: cfg)
if #available(macOS 13.3, *) { web.isInspectable = true }
bridge.web = web
window.contentView = web
window.orderFrontRegardless()

var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: Any = "") {
    if !ok { failures += 1 }
    let line = try! JSONSerialization.data(withJSONObject: ["check": name, "ok": ok, "detail": "\(detail)"])
    print(String(decoding: line, as: UTF8.self))
    fflush(stdout)
}

@MainActor
func js(_ src: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(src, contentWorld: .page) } catch { return "JSERROR: \(error)" }
}
@MainActor
func waitJS(_ cond: String, _ timeout: Double = 8) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await js("return !!(\(cond))") as? Bool == true { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
}
func waitFile(_ timeout: Double = 6, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
}
@MainActor
func snapshot(_ name: String) async {
    let c = WKSnapshotConfiguration()
    guard let img = try? await web.takeSnapshot(configuration: c), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
        report("snapshot \(name)", false); return
    }
    let url = URL(fileURLWithPath: opts.out).appendingPathComponent("wkwebview-\(name).png")
    try? png.write(to: url)
    report("snapshot \(name)", true, url.path)
}
func key(_ k: String, _ extra: String = "") -> String {
    "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: '\(k)', bubbles: true, cancelable: true\(extra)}));"
}

Task { @MainActor in
    try? FileManager.default.createDirectory(atPath: opts.out, withIntermediateDirectories: true)
    web.appearance = NSAppearance(named: .aqua)
    web.load(URLRequest(url: URL(string: "blurt-app://ui/index.html?session=\(sessionURL.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!))

    let loaded = await waitJS("document.querySelector('.qi') && window.blurtReview?.store.host.host === 'macos'", 20)
    report("loads over blurt-app:// with the macos host", loaded)
    if !loaded {
        // say why (CI only shows this log): what items.py answers, and what the page has
        let (code, out) = runScript("items.py", ["doc", sessionURL.path])
        print("diag items.py doc exit \(code): \(out.suffix(600))")
        let page = await js("return JSON.stringify({url: location.href, body: document.body.innerText.slice(0, 300), host: window.blurtReview?.store?.host?.host ?? null, err: window.__blurtLastError ?? null})")
        print("diag page: \(page ?? "nil")")
        fflush(stdout)
    }
    report("in-app chrome, mac platform", await js("return document.documentElement.classList.contains('in-app') && document.documentElement.dataset.platform") as? String == "mac")
    let accent = await js("return getComputedStyle(document.documentElement).getPropertyValue('--sys-accent')") as? String ?? ""
    report("system accent injected", !accent.isEmpty, accent)
    _ = await js("localStorage.setItem('blurt.view','focus'); window.blurtReview.store.setView('focus')")
    report("frame image from blurt-app://file/ (the store)", await waitJS("document.querySelector('.shot.ready img')?.naturalWidth > 0"))
    report("drag rects registered", await waitFile(3) { bridge.notes.contains { $0["method"] as? String == "registerDragRects" && (($0["params"] as? [String: Any])?["rects"] as? [Any])?.isEmpty == false } })

    func at(_ id: String) async -> Bool { await waitJS("document.querySelector('.idrow > span')?.textContent === '\(id)'") }

    // keys: the review opens on the first new item (IN-3, the agent's I-003); A keeps it (new → to do) through
    // items.py user-ops and goes on to the next new one (IN-5)
    report("opens on the first new item", await at("IN-3"))
    _ = await js(key("a"))
    report("A keeps → items.py user-ops writes the state", await waitFile { item("I-003")?["state"] as? String == "todo" })

    // typing in a field (back to IN-3), recorded as the user's
    _ = await at("IN-5")
    _ = await js(key("k") + key("k"))
    _ = await at("IN-3")
    _ = await js("""
        const el = document.querySelector('textarea[data-k="why"]'); el.focus();
        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(el, 'typed in WKWebView');
        el.dispatchEvent(new Event('input', {bubbles: true})); el.blur();
        """)
    report("field edit autosaves", await waitFile {
        let i = item("I-003"); return i?["why"] as? String == "typed in WKWebView" && (i?["_user"] as? [String: Any])?["why"] != nil })

    // IME: WebKit's committing Enter (keyCode 229) must not keep the new item it lands on (IN-5)
    _ = await js(key("j") + key("j"))
    _ = await at("IN-5")
    let keptBefore = await js("return document.querySelectorAll('.qi.keep').length") as? Int ?? -1
    _ = await js("""
        const e = new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true});
        Object.defineProperty(e, 'keyCode', {get: () => 229}); document.body.dispatchEvent(e);
        """)
    try? await Task.sleep(nanoseconds: 800_000_000)
    let keptCount = await js("return document.querySelectorAll('.qi.keep').length") as? Int
    let stayed = await at("IN-5")
    report("IME Enter (keyCode 229) does not keep", item("I-005")?["state"] as? String == "new" && keptCount == keptBefore && stayed,
           "kept rows: \(keptBefore) → \(keptCount ?? -1)")

    // the agent adds frames: shown within 3 s
    _ = await js(key("k") + key("k"))
    _ = await at("IN-3")
    let before = await js("return document.querySelectorAll('.strip .th img').length") as? Int ?? -1
    let t0 = Date()
    runScript("items.py", ["set-frames", sessionURL.path, "I-003", "frames/I-003-1.jpg@3.3", "frames/I-002-1.jpg@3.6"])
    let shown = await waitJS("document.querySelectorAll('.strip .th img').length === \(before + 1)", 3)
    report("set-frames shows up within 3 s", shown, String(format: "%.2fs", Date().timeIntervalSince(t0)))

    // the clip plays from blurt-app://file/ (range requests)
    _ = await js(key("k") + key("k"))
    _ = await at("IN-1")
    _ = await js(key("ArrowRight") + key("ArrowRight"))
    report("video loads through the scheme handler", await waitJS("document.querySelector('#mediaBox video')?.readyState >= 1", 6),
           await js("const v = document.querySelector('#mediaBox video'); return v ? v.readyState + ' ' + v.currentSrc + ' ' + (v.error && v.error.code) : 'no video'") ?? "")
    _ = await js(key("ArrowLeft") + key("ArrowLeft"))

    // native affordances appear because the host lists them
    report("Quick Look / reveal buttons present", await waitJS("document.querySelectorAll('#mediaCap button.dl').length >= 2"))
    _ = await js("document.querySelectorAll('#mediaCap button.dl')[1].click()")
    report("quickLook reaches native", await waitFile(2) { bridge.notes.contains { $0["method"] as? String == "quickLook" } })

    try? await Task.sleep(nanoseconds: 500_000_000)
    await snapshot("light")
    web.appearance = NSAppearance(named: .darkAqua)
    report("follows the system appearance", await waitJS("document.documentElement.dataset.theme === 'dark'", 3))
    try? await Task.sleep(nanoseconds: 500_000_000)
    await snapshot("dark")

    // confirm: ⌘⏎ → dialog → confirm → done; the native side is told
    _ = await js(key("Enter", ", metaKey: true"))
    _ = await waitJS("document.querySelector('#modalBg.show #mOk')")
    _ = await js("document.querySelector('#mOk').click()")
    report("confirm reaches items.py --confirm", await waitFile { batchReviewed() })
    report("done screen + confirmed notification", await waitJS("document.querySelector('#done.show')") &&
           bridge.notes.contains { $0["method"] as? String == "confirmed" })

    print("{\"summary\": true, \"failures\": \(failures)}")
    exit(failures == 0 ? 0 : 1)
}
app.run()
