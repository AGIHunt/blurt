// blurt-app:// for the review canvas (contract C6, macos host):
//   blurt-app://ui/index.html?session=<abs>&mode=item|review&item=<id>&platform=mac&theme=auto
//        the web UI: Contents/Resources/web/ (a bundled web/dist), else <skill>/scripts/review.html (single file)
//   blurt-app://ui/<path>          other files of a bundled multi-file build
//   blurt-app://session/<rel>      a file of the current session (Range requests, for video seeking)
// Plus, so today's review.html (written for review.py's HTTP API) runs unchanged until WP3's build lands, the same
// endpoints review.py serves, answered natively: GET /api/items (ETag / 304, "_video"), POST /api/items {ops} and
// POST /api/confirm {ops} → `items.py user-ops` (the same apply_user_ops review.py runs), /files/<rel>.
import AppKit
import BlurtCore
import CryptoKit
import UniformTypeIdentifiers
import WebKit

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "blurt-app"
    /// The session the page in this web view belongs to.
    var session: URL?
    /// After a write through the shim: the host reloads the list etc.
    var onWrite: (() -> Void)?
    private var live = Set<ObjectIdentifier>()

    static var webRoot: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("web")
        if let b = bundled, FileManager.default.fileExists(atPath: b.appendingPathComponent("index.html").path) { return b }
        return nil
    }
    static var pageFile: URL { webRoot?.appendingPathComponent("index.html") ?? Scripts.url("review.html") }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        live.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return fail(task, 400) }
        let path = url.path.removingPercentEncoding ?? url.path
        let method = task.request.httpMethod ?? "GET"
        switch (url.host, path) {
        case ("ui", "/"), ("ui", "/index.html"):
            guard let d = try? Data(contentsOf: Self.pageFile) else { return fail(task, 404, "the review page is missing: \(Self.pageFile.path)") }
            respond(task, 200, d, "text/html; charset=utf-8")
        case ("ui", "/api/items") where method == "GET":
            items(task, ifNoneMatch: task.request.value(forHTTPHeaderField: "If-None-Match"))
        case ("ui", "/api/items"), ("ui", "/api/confirm"):
            post(task, confirm: path == "/api/confirm")
        case ("ui", "/icon.png"), ("ui", "/favicon.ico"):
            let icon = Scripts.dir.deletingLastPathComponent().appendingPathComponent("assets/icon.png")
            if let d = try? Data(contentsOf: icon) { respond(task, 200, d, "image/png") } else { fail(task, 404) }
        case ("ui", let p) where p.hasPrefix("/files/"):
            file(task, rel: String(p.dropFirst("/files/".count)))
        case ("session", let p):
            file(task, rel: String(p.dropFirst()))
        case ("ui", let p):
            guard let root = Self.webRoot else { return fail(task, 404) }
            let f = root.appendingPathComponent(String(p.dropFirst())).standardizedFileURL
            guard f.path.hasPrefix(root.standardizedFileURL.path + "/"), let d = try? Data(contentsOf: f) else { return fail(task, 404) }
            respond(task, 200, d, Self.mime(f))
        default:
            fail(task, 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }

    // MARK: the review.py endpoints

    static func sha1Hex(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    /// _common.file_etag: the ETag review.py's GET /api/items and items.py user-ops both give
    static func etag(_ raw: Data) -> String { "\"" + sha1Hex(raw).prefix(16) + "\"" }

    /// items.json as review.py's GET /api/items serves it.
    static func document(_ session: URL) -> (Data, String) {
        let raw = (try? Data(contentsOf: session.appendingPathComponent("items.json"))) ?? Data("{\"items\": []}".utf8)
        var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? ["items": []]
        if let v = obj["source_video"] as? String, !v.isEmpty {
            obj["_video"] = FileManager.default.fileExists(atPath: session.appendingPathComponent(v).path)
        } else {
            obj["_video"] = false
        }
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? raw
        return (body, etag(raw))
    }

    func items(_ task: WKURLSchemeTask, ifNoneMatch: String?) {
        guard let s = session else { return fail(task, 404) }
        let (body, tag) = Self.document(s)
        if ifNoneMatch == tag { return respond(task, 304, Data(), "application/json", ["ETag": tag]) }
        respond(task, 200, body, "application/json", ["ETag": tag])
    }

    func post(_ task: WKURLSchemeTask, confirm: Bool) {
        guard let s = session else { return fail(task, 404) }
        let body = task.request.httpBody ?? task.request.httpBodyStream.map(Self.read) ?? Data()
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let ops = obj["ops"] as? [[String: Any]] else {
            return fail(task, 409, "the app saves edits as ops only")    // review.py's whole-document path (hand-written files)
        }
        Scripts.userOps(s, ops, confirm: confirm) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success:
                self.onWrite?()
                if confirm { self.respond(task, 200, Data("{\"ok\":true}".utf8), "application/json") }
                else { self.items(task, ifNoneMatch: nil) }
            case .failure(let e):
                self.fail(task, 500, "\(e)")
            }
        }
    }

    static func read(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }

    // MARK: session files

    /// A session-relative path, inside the session, that exists.
    static func resolve(_ rel: String, in session: URL?) -> URL? {
        guard let s = session?.standardizedFileURL else { return nil }
        let f = s.appendingPathComponent(rel).standardizedFileURL
        guard f.path.hasPrefix(s.path + "/"), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    func file(_ task: WKURLSchemeTask, rel: String) {
        guard let f = Self.resolve(rel, in: session), let h = try? FileHandle(forReadingFrom: f) else { return fail(task, 404) }
        defer { try? h.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let mime = Self.mime(f)
        if let range = task.request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let reqEnd = parts.count > 1 ? Int(parts[1]) : nil
            let end = min(reqEnd ?? size - 1, start + 8 * 1024 * 1024, size - 1)
            guard start < size, end >= start else { return respond(task, 416, Data(), mime, ["Content-Range": "bytes */\(size)"]) }
            try? h.seek(toOffset: UInt64(start))
            let d = h.readData(ofLength: end - start + 1)
            return respond(task, 206, d, mime, ["Content-Range": "bytes \(start)-\(end)/\(size)", "Accept-Ranges": "bytes"])
        }
        respond(task, 200, h.readDataToEndOfFile(), mime, ["Accept-Ranges": "bytes"])
    }

    static func mime(_ f: URL) -> String {
        UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: responses

    func respond(_ task: WKURLSchemeTask, _ code: Int, _ body: Data, _ mime: String, _ headers: [String: String] = [:]) {
        guard live.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        var h = headers
        h["Content-Type"] = mime
        h["Content-Length"] = "\(body.count)"
        h["Cache-Control"] = "no-store"
        let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: h)!
        task.didReceive(r)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }

    func fail(_ task: WKURLSchemeTask, _ code: Int, _ msg: String = "not found") {
        respond(task, code, Data(msg.utf8), "text/plain; charset=utf-8")
    }
}
