// blurt-app:// for the review canvas (C6 + the v3 host protocol of next-round.md "所有权、闸门和合并"):
//   blurt-app://ui/index.html?…    the single-file review component: Contents/Resources/web/index.html when bundled,
//                                  else <skill>/scripts/review.html (the same file)
//   blurt-app://ui/icon.png        the page's logo (relative path icon.png); ui/<path> other files of a bundled build
//   blurt-app://file/<abs path>    any file under an allowed root (percent-encoded absolute path; v3 fileUrl):
//                                  registered project stores, the inbox store, legacy recordings, the session the page
//                                  shows, $BLURT_HOME/handoff — nothing else, and never through a symlink out
//   blurt-app://session/<rel>      a file of the current session (v2 pages)
// Files are served with Range support (<video> needs 206s), at most 8 MiB per answer (ByteRange); a large file asked
// for whole is streamed from disk a chunk at a time — a file is never read into memory whole.
import AppKit
import BlurtCore
import CryptoKit
import UniformTypeIdentifiers
import WebKit

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "blurt-app"
    /// The session the page in this web view belongs to (v2 relative paths), if any.
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
        case ("ui", "/icon.png"):
            file(task, Self.iconFile)
        case ("ui", "/favicon.ico"), ("ui", "/favicon.png"), ("ui", "/peep-done.webp"), ("ui", "/peep-done-dark.webp"):
            // the page's pictures that are not inlined in it: the favicon, Peep's done pose (skills/blurt/assets)
            let name = path == "/favicon.ico" ? "favicon.png" : String(path.dropFirst())
            file(task, Self.webRoot.map { $0.appendingPathComponent(name) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? Scripts.dir.deletingLastPathComponent().appendingPathComponent("assets/\(name)"))
        case ("file", let p):
            guard let f = Self.allowed(URL(fileURLWithPath: p), session: session) else { return fail(task, 403) }
            file(task, f)
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

    static func sha1Hex(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: which files the page may load

    /// The folders a page may read from: every registered store, the inbox, legacy recordings, the handoff sheets.
    static var allowedRoots: [URL] {
        let store = ProjectStore.shared
        return store.projects.map(\.store) + [store.inbox.store, BlurtPaths.workspace.appendingPathComponent("recordings"),
                                              BlurtPaths.home.appendingPathComponent("handoff")]
    }

    /// The file, resolved (symlinks too), if it exists and lies under an allowed root or the page's session.
    static func allowed(_ f: URL, session: URL?) -> URL? {
        let real = f.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: real.path) else { return nil }
        let roots = allowedRoots + (session.map { [$0] } ?? [])
        return roots.contains { real.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") } ? real : nil
    }

    /// blurt-app://file/<abs> for an absolute path (the v3 host's fileUrl).
    static func fileURL(_ abs: String) -> String {
        "\(scheme)://file" + (abs.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? abs)
    }

    /// A session-relative path that stays inside the session and exists (v2 pages).
    static func resolve(_ rel: String, in session: URL?) -> URL? {
        guard let s = session?.standardizedFileURL, !rel.isEmpty else { return nil }
        let f = s.appendingPathComponent(rel).standardizedFileURL
        guard f.path.hasPrefix(s.path + "/"), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// What a page names a file by: an absolute path (v3) or a session-relative one (v2).
    static func locate(_ ref: String, session: URL?) -> URL? {
        ref.hasPrefix("/") ? allowed(URL(fileURLWithPath: ref), session: session) : resolve(ref, in: session)
    }

    func file(_ task: WKURLSchemeTask, _ f: URL) {
        guard let h = try? FileHandle(forReadingFrom: f) else { return fail(task, 404) }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if let range = task.request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            defer { try? h.close() }
            // at most ByteRange.cap per answer (as review.py): a player asks for the next part, and a 400 MB
            // recording never sits in memory whole because of an open-ended "bytes=0-"
            guard let r = ByteRange.plan(range, size: size) else { return respond(task, 416, Data(), mime, ["Content-Range": "bytes */\(size)"]) }
            try? h.seek(toOffset: UInt64(r.lowerBound))
            let d = h.readData(ofLength: r.count)
            return respond(task, 206, d, mime, ["Content-Range": "bytes \(r.lowerBound)-\(r.upperBound)/\(size)", "Accept-Ranges": "bytes"])
        }
        guard size > ByteRange.cap else {
            defer { try? h.close() }
            return respond(task, 200, h.readDataToEndOfFile(), mime, ["Accept-Ranges": "bytes"])
        }
        stream(task, h, size: size, mime: mime)
    }

    /// A large file without a Range: read off the main thread a chunk at a time and handed over as it goes, so
    /// only one chunk is in memory; a task the page stopped stops the reading.
    private func stream(_ task: WKURLSchemeTask, _ h: FileHandle, size: Int, mime: String) {
        guard let url = task.request.url else { try? h.close(); return }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": "\(size)", "Cache-Control": "no-store", "Accept-Ranges": "bytes"])!)
        let id = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? h.close() }
            while true {
                let chunk = autoreleasepool { h.readData(ofLength: 1 << 20) }
                let more: Bool = DispatchQueue.main.sync {
                    guard let self = self, self.live.contains(id) else { return false }
                    if chunk.isEmpty {
                        task.didFinish()
                        self.live.remove(id)
                        return false
                    }
                    task.didReceive(chunk)
                    return true
                }
                if !more { return }
            }
        }
    }

    // MARK: responses

    func respond(_ task: WKURLSchemeTask, _ code: Int, _ body: Data, _ mime: String, _ headers: [String: String] = [:]) {
        guard live.contains(ObjectIdentifier(task)), let url = task.request.url else { return }
        var h = headers
        h["Content-Type"] = mime
        h["Content-Length"] = "\(body.count)"
        h["Cache-Control"] = "no-store"
        // the page (blurt-app://ui) reads a voice note's wav with fetch to draw its waveform: another host of the
        // scheme, so it needs to be told it may (only this web view ever reaches the scheme)
        if url.host == "file" || url.host == "session" { h["Access-Control-Allow-Origin"] = "*" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: h)!)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }

    func fail(_ task: WKURLSchemeTask, _ code: Int, _ msg: String = "not found") {
        respond(task, code, Data(msg.utf8), "text/plain; charset=utf-8")
    }
}
