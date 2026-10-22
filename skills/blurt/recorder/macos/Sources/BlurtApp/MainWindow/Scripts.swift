// The main window's way to the skill's Python CLIs — every write goes through them (K1: only items.py writes items;
// K2: only projects.py writes projects.json; K6: handoff.py writes hand-off sheets). Runs on ScriptRunner (uv, the
// login-shell environment); results come back on the main queue. A failing CLI answers {"ok": false, "code": …};
// the UI localises `code` (K10) and only logs `error`.
import AppKit
import BlurtCore

enum Scripts {
    static var dir: URL { BlurtPaths.scripts }
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
    /// Writes are possible: the scripts are there and uv can run them.
    static var canWrite: Bool { has("items.py") && ScriptRunner.shared.uvAvailable }

    struct Failure: Error, CustomStringConvertible {
        let code: String
        let message: String
        var description: String { message }
        /// What to tell the user: the code's own sentence when there is one, else a general one.
        var localized: String {
            let k = "main.error.\(code)"
            return T(k) == k ? T("main.error.generic") : T(k)
        }
    }

    /// The last JSON object a CLI printed.
    static func json(_ d: Data) -> [String: Any]? {
        for l in String(decoding: d, as: UTF8.self).split(separator: "\n").reversed() {
            if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] { return o }
        }
        return nil
    }

    /// Runs `script args…` off the main thread; `done` gets stdout (or the error) on the main queue.
    static func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60,
                    done: @escaping (Result<Data, Error>) -> Void) {
        Task.detached {
            let r: Result<Data, Error>
            do { r = .success(try await ScriptRunner.shared.run(script, args, stdin: stdin, timeout: timeout)) } catch { r = .failure(error) }
            await MainActor.run { done(r) }
        }
    }

    /// run() for the {"ok": …} CLIs: the decoded object, or a Failure carrying the CLI's code.
    static func call(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60,
                     done: @escaping (Result<[String: Any], Failure>) -> Void) {
        run(script, args, stdin: stdin, timeout: timeout) { r in
            switch r {
            case .success(let d):
                guard let o = json(d), o["ok"] as? Bool == true else {
                    let o = json(d) ?? [:]
                    return done(.failure(Failure(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? "\(script) failed")))
                }
                done(.success(o))
            case .failure(ScriptError.failed(_, let out, let err)):
                let o = json(out) ?? [:]
                done(.failure(Failure(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? err)))
            case .failure(ScriptError.scriptMissing(let p)):
                done(.failure(Failure(code: "no_scripts", message: p)))
            case .failure(ScriptError.uvMissing):
                done(.failure(Failure(code: "no_uv", message: "uv not found")))
            case .failure(let e):
                done(.failure(Failure(code: "failed", message: "\(e)")))
            }
        }
    }

    // MARK: the writes the main window makes

    /// items.py user-ops (the review component's ops, by uid). `scope` = [SESSION] | ["--project", P].
    static func userOps(_ scope: [String], _ ops: [[String: Any]], confirm: Bool = false,
                        done: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["ops": ops]) else { return }
        call("items.py", ["user-ops"] + scope + ["--stdin"] + (confirm ? ["--confirm"] : []), stdin: body, timeout: 30, done: done)
    }

    /// items.py state REF… --action A --by user (K3: keep, done, send_back, take_back, reopen, restore, wontfix, discard —
    /// only the user does these). → {"ok", "items": [{"uid", "id", "state", "work"}]}; codes bad_transition / deleted.
    static func state(_ uids: [String], action: String, note: String? = nil, done: @escaping (Result<[String: Any], Failure>) -> Void) {
        call("items.py", ["state"] + uids + ["--action", action, "--by", "user"] + (note.map { ["--note", $0] } ?? []), timeout: 30, done: done)
    }

    /// items.py move REF… --project P|inbox --by user (the AI never moves them back).
    static func move(_ uids: [String], to project: String, done: @escaping (Result<[String: Any], Failure>) -> Void) {
        call("items.py", ["move"] + uids + ["--project", project, "--by", "user"], timeout: 30, done: done)
    }

    /// handoff.py create --items … --mark: the hand-off sheet, marked handed_off(external) — called when the user copies.
    static func handoff(_ uids: [String], done: @escaping (Result<[String: Any], Failure>) -> Void) {
        call("handoff.py", ["create", "--items"] + uids + ["--lang", Loc.isChinese ? "zh" : "en", "--to", "external", "--mark"], timeout: 30, done: done)
    }

    /// Debounced, coalescing `index.py update <paths>` for the FSEvents watcher.
    static var pendingUpdate = Set<String>()
    static var updating = false
    static func indexUpdate(_ paths: [URL], done: (() -> Void)? = nil) {
        guard has("index.py") else { return }
        pendingUpdate.formUnion(paths.map(\.path))
        guard !updating, !pendingUpdate.isEmpty else { return }
        let batch = pendingUpdate.sorted()
        pendingUpdate.removeAll()
        updating = true
        run("index.py", ["update"] + batch, timeout: 60) { _ in
            updating = false
            done?()
            if !pendingUpdate.isEmpty { indexUpdate([], done: done) }
        }
    }

    static func indexScan(done: @escaping (Result<[String: Any], Error>) -> Void) {
        run("index.py", ["scan"], timeout: 300) { r in done(r.map { json($0) ?? [:] }) }
    }
}
