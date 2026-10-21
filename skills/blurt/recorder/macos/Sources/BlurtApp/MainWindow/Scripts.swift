// The main window's way to the skill's Python CLIs (items.py user-ops, index.py scan / update — contracts C2, C3).
// BlurtCore's ScriptRunner is the long-term home (WP4); until it is implemented this falls back to `uv run` with the
// login-shell environment the rest of the app uses (agentEnvironment()). All writes to items.json go through here.
import AppKit
import BlurtCore

enum Scripts {
    /// <skill>/scripts: config skill_dir (record.py writes it on every run), else BlurtPaths' default.
    static var dir: URL {
        if let s = readConfig()["skill_dir"] as? String, !s.isEmpty { return URL(fileURLWithPath: s).appendingPathComponent("scripts") }
        return BlurtPaths.scripts
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    static var uv: String? {
        findExecutable("uv") ?? [blurtHome.appendingPathComponent("bin/uv").path].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// Writes are possible: the scripts are there and uv can run them.
    static var canWrite: Bool { has("items.py") && uv != nil }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Runs `script args…` off the main thread; `done` gets stdout (or the error) on the main queue.
    static func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60,
                    done: @escaping (Result<Data, Error>) -> Void) {
        Task.detached {
            let r: Result<Data, Error>
            do {
                r = .success(try await ScriptRunner.shared.run(script, args, stdin: stdin, timeout: timeout))
            } catch ScriptError.notImplemented {
                r = fallback(script, args, stdin: stdin, timeout: timeout)
            } catch {
                r = .failure(error)
            }
            await MainActor.run { done(r) }
        }
    }

    /// The last JSON line a C2/C3 CLI printed.
    static func json(_ d: Data) -> [String: Any]? {
        let lines = String(decoding: d, as: UTF8.self).split(separator: "\n")
        for l in lines.reversed() {
            if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] { return o }
        }
        return nil
    }

    private static func fallback(_ script: String, _ args: [String], stdin: Data?, timeout: TimeInterval) -> Result<Data, Error> {
        let path = script.hasPrefix("/") ? script : url(script).path
        guard FileManager.default.fileExists(atPath: path) else { return .failure(Failure(message: "\(script) not found in \(dir.path)")) }
        guard let uv = uv else { return .failure(Failure(message: "uv not found")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "-q", path] + args
        var env = agentEnvironment()
        env["BLURT_HOME"] = blurtHome.path
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return .failure(error) }
        if let s = stdin {
            DispatchQueue.global().async {
                inp.fileHandleForWriting.write(s)
                try? inp.fileHandleForWriting.close()
            }
        }
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return .failure(ScriptError.timeout(timeout))
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = (json(o)?["error"] as? String) ?? String(decoding: e, as: UTF8.self)
            return .failure(Failure(message: msg.isEmpty ? "\(script) exited \(p.terminationStatus)" : msg))
        }
        return .success(o)
    }

    // MARK: the writes the main window makes

    /// items.py user-ops (C2): the same function review.py's POST /api/items runs. `done` gets the new etag.
    static func userOps(_ session: URL, _ ops: [[String: Any]], confirm: Bool = false,
                        done: @escaping (Result<String, Error>) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["ops": ops]) else { return }
        run("items.py", ["user-ops", session.path, "--stdin"] + (confirm ? ["--confirm"] : []), stdin: body, timeout: 30) { r in
            done(r.flatMap { d in
                guard let o = json(d), o["ok"] as? Bool == true else {
                    return .failure(Failure(message: (json(d)?["error"] as? String) ?? "items.py user-ops failed"))
                }
                return .success(o["etag"] as? String ?? "")
            })
        }
    }

    /// Debounced, coalescing `index.py update <dirs>` for the FSEvents watcher.
    static var pendingUpdate = Set<String>()
    static var updating = false
    static func indexUpdate(_ dirs: [URL], done: (() -> Void)? = nil) {
        guard has("index.py") else { return }
        pendingUpdate.formUnion(dirs.map(\.path))
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
        run("index.py", ["scan"], timeout: 300) { r in
            done(r.map { json($0) ?? [:] })
        }
    }
}
