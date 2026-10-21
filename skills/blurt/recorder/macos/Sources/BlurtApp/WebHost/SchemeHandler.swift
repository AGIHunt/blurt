// blurt-app:// for the review canvas (contract C6, macos host):
//   blurt-app://ui/index.html?session=<abs>&mode=item|review&item=<id|uid>&platform=mac&theme=auto&lang=en|zh
//        the single-file review component: Contents/Resources/web/index.html when bundled, else
//        <skill>/scripts/review.html (the same file, committed by WP3)
//   blurt-app://ui/icon.png        the page's logo (relative path icon.png)
//   blurt-app://ui/<path>          other files of a bundled multi-file build
//   blurt-app://session/<rel>      a file of the current session, with Range support (<video> needs 206s); never
//                                  outside the session dir
import AppKit
import BlurtCore
import CryptoKit
import UniformTypeIdentifiers
import WebKit

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "blurt-app"
    /// The session the page in this web view belongs to.
    var session: URL?
    private var live = Set<ObjectIdentifier>()

    static var webRoot: URL? {
        guard let b = Bundle.main.resourceURL?.appendingPathComponent("web"),
              FileManager.default.fileExists(atPath: b.appendingPathComponent("index.html").path) else { return nil }
        return b
    }
    static var pageFile: URL { webRoot?.appendingPathComponent("index.html") ?? Scripts.url("review.html") }
    static var iconFile: URL {
        webRoot.map { $0.appendingPathComponent("icon.png") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Scripts.dir.deletingLastPathComponent().appendingPathComponent("assets/icon.png")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        live.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return fail(task, 400) }
        let path = url.path      // percent-decoded
        switch (url.host, path) {
        case ("ui", "/"), ("ui", "/index.html"):
            guard let d = try? Data(contentsOf: Self.pageFile) else { return fail(task, 404, "the review page is missing: \(Self.pageFile.path)") }
            respond(task, 200, d, "text/html; charset=utf-8")
        case ("ui", "/icon.png"), ("ui", "/favicon.ico"):
            file(task, Self.iconFile)
        case ("session", let p):
            guard let f = Self.resolve(String(p.dropFirst()), in: session) else { return fail(task, 404) }
            file(task, f)
        case ("ui", let p):
            guard let root = Self.webRoot else { return fail(task, 404) }
            let f = root.appendingPathComponent(String(p.dropFirst())).standardizedFileURL
            guard f.path.hasPrefix(root.standardizedFileURL.path + "/") else { return fail(task, 404) }
            file(task, f)
        default:
            fail(task, 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }

    // MARK: documents (C6: as review.py serves them)

    static func sha1Hex(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    /// _common.file_etag: the ETag review.py's GET /api/items and items.py user-ops both give
    static func etag(_ raw: Data) -> String { "\"" + sha1Hex(raw).prefix(16) + "\"" }

    /// items.json as-is plus `_video` (whether source_video exists; false for shots sessions), and its etag.
    static func document(_ session: URL) -> (doc: [String: Any], etag: String) {
        let raw = (try? Data(contentsOf: session.appendingPathComponent("items.json"))) ?? Data("{\"items\": []}".utf8)
        var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? ["items": [Any]()]
        if let v = obj["source_video"] as? String, !v.isEmpty {
            obj["_video"] = FileManager.default.fileExists(atPath: session.appendingPathComponent(v).path)
        } else {
            obj["_video"] = false
        }
        return (obj, etag(raw))
    }

    // MARK: session files

    /// A session-relative path that stays inside the session and exists.
    static func resolve(_ rel: String, in session: URL?) -> URL? {
        guard let s = session?.standardizedFileURL, !rel.isEmpty else { return nil }
        let f = s.appendingPathComponent(rel).standardizedFileURL
        guard f.path.hasPrefix(s.path + "/"), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    func file(_ task: WKURLSchemeTask, _ f: URL) {
        guard let h = try? FileHandle(forReadingFrom: f) else { return fail(task, 404) }
        defer { try? h.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if let range = task.request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            var start = Int(parts.first ?? "") ?? 0
            var end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1]) ?? size - 1 : size - 1
            if parts.first?.isEmpty == true, let suffix = parts.count > 1 ? Int(parts[1]) : nil {   // bytes=-N
                start = max(0, size - suffix); end = size - 1
            }
            end = min(end, size - 1)
            guard start < size, end >= start else { return respond(task, 416, Data(), mime, ["Content-Range": "bytes */\(size)"]) }
            try? h.seek(toOffset: UInt64(start))
            let d = h.readData(ofLength: end - start + 1)
            return respond(task, 206, d, mime, ["Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"])
        }
        respond(task, 200, h.readDataToEndOfFile(), mime, ["Accept-Ranges": "bytes"])
    }

    // MARK: responses

    func respond(_ task: WKURLSchemeTask, _ code: Int, _ body: Data, _ mime: String, _ headers: [String: String] = [:]) {
        guard live.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        var h = headers
        h["Content-Type"] = mime
        h["Content-Length"] = "\(body.count)"
        h["Cache-Control"] = "no-store"
        task.didReceive(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: h)!)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }

    func fail(_ task: WKURLSchemeTask, _ code: Int, _ msg: String = "not found") {
        respond(task, code, Data(msg.utf8), "text/plain; charset=utf-8")
    }
}
