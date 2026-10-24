// review.py's batch, reviewed in the main window (SKILL.md §3–5: record → process → review → export). review.py asks
// with a distributed notification dev.blurt.recorder.review {url, session, home}, or launches the app with
// `--review URL --review-session DIR`; the batch opens in the main window, and the app answers review.py:
//   shown       GET  <url>api/attached   review.py doesn't open the browser as well
//   confirmed   POST <url>api/done       review.py prints its summary and exits, so the agent goes on (export, fixing)
// review.py also notices batch.json turning reviewed, so a confirm still counts if this answer is lost. Only
// review.py's own address is called (ReviewLink: local http, its per-run token path) — any process can post the
// notification. A batch that couldn't be shown isn't acknowledged: review.py opens the browser then.
import AppKit
import BlurtCore

enum ReviewHandoff {
    /// session dir (canonical path) → review.py's page URL, while its review is open
    private static var pending: [String: String] = [:]

    static func show(url: String?, session: String) {
        let dir = URL(fileURLWithPath: session)
        guard let mw = AppEnvironment.mainWindow, mw.reveal(session: dir) else { return }
        guard let u = url, ReviewLink.endpoint(u, "api/attached") != nil else { return }
        pending[FixWatcher.real(dir.path)] = u
        call(u, "api/attached", post: false)
    }

    /// The page in the main window confirmed this batch.
    static func confirmed(session: URL) {
        guard let u = pending.removeValue(forKey: FixWatcher.real(session.path)) else { return }
        call(u, "api/done", post: true)
    }

    private static func call(_ base: String, _ path: String, post: Bool) {
        guard let url = ReviewLink.endpoint(base, path) else { return }
        var r = URLRequest(url: url, timeoutInterval: 5)
        if post {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("{}".utf8)
        }
        URLSession.shared.dataTask(with: r) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { emit(["event": "review_link", "path": path, "status": code, "error": err.map { "\($0)" } ?? NSNull()]) }
        }.resume()
    }
}
