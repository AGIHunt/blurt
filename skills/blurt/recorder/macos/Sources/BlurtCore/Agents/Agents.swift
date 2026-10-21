// Coding agents through agents.py (contract C5): the app only runs the argv / url `agents.py command` returns, with
// the login-shell environment. Nothing here builds an agent command line itself — agents.json is the one source.
//
//   Agents.shared.detect()                 → agents.py detect: order, pick, per-agent state / why / fix
//   Agents.shared.command(id, mode, …)     → agents.py command: argv | url | terminal | clipboard
//   Agents.shared.install(id, dryRun:)     → agents.py install [--dry-run] (always with the caller's full environment:
//                                            CODEX_HOME / CLAUDE_CONFIG_DIR / KIMI_CODE_HOME decide which config is written)
//   Agents.shared.fixPrompt(uids)          → agents.py prompt fix
//   Agents.shared.run(id, prompt:, repo:)  → a headless AgentRun: progress lines parsed from the agent's event stream,
//                                            $BLURT_HOME/runs/<run id>.json + .log
// The app sets `SkillCLI.shared.environment` (its agentEnvironment()) at launch.
import Foundation

// MARK: - Running the skill's scripts

/// One finished script call.
public struct CLIResult {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public var ok: Bool { status == 0 }
    /// stdout's last JSON object line (the C2/C5 CLIs print one line; transcribe.py models prints pretty JSON)
    public var json: [String: Any]? {
        if let o = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] { return o }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return o }
        }
        return nil
    }
    public func decode<T: Decodable>(_ t: T.Type) -> T? {
        if let v = try? JSONDecoder().decode(t, from: stdout) { return v }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let v = try? JSONDecoder().decode(t, from: Data(line.utf8)) { return v }
        }
        return nil
    }
    /// {"ok": false, "error": …} from stdout, else the tail of stderr
    public var errorText: String {
        if let e = json?["error"] as? String { return e }
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? "exit \(status)" : String(e.suffix(600))
    }
}

/// The skill's Python CLIs through uv: WP4's ScriptRunner for plain calls. Calls that need extra packages
/// (`uv run --with mlx-whisper …`), extra or replaced environment (BLURT_HF_MIRROR, agents.py install's full env) or
/// separate stdout / stderr streams (download progress) start `uv run -q [--with X] <script>` here, in the same
/// ShellEnv environment.
public final class SkillCLI {
    public static let shared = SkillCLI()

    /// The environment for every child (ShellEnv's login-shell environment unless replaced).
    public var environment: () -> [String: String] = { ShellEnv.agentEnvironment() }

    public init() {}

    /// uv on the user's PATH, else ~/.blurt/bin/uv (WP4's lookup).
    public var uvPath: String? { ScriptRunner.shared.uvPath }

    public func scriptURL(_ script: String) -> URL {
        script.hasPrefix("/") ? URL(fileURLWithPath: script) : BlurtPaths.scripts.appendingPathComponent(script)
    }

    /// Never throws for a non-zero exit: the CLIs report errors as JSON on stdout. Throws when uv or the script is
    /// missing, or on timeout.
    public func run(_ script: String, _ args: [String], stdin: Data? = nil, with packages: [String] = [],
                    env extra: [String: String] = [:], timeout: TimeInterval = 60) async throws -> CLIResult {
        if packages.isEmpty, extra.isEmpty, self === SkillCLI.shared {
            do {
                let out = try await ScriptRunner.shared.run(script, args, stdin: stdin, timeout: timeout)
                return CLIResult(status: 0, stdout: out, stderr: "")
            } catch ScriptError.failed(let status, let out, let err) {
                return CLIResult(status: status, stdout: out, stderr: err)
            }
        }
        let p = try makeProcess(script, args, with: packages, env: extra)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                if stdin != nil { p.standardInput = Pipe() } else { p.standardInput = FileHandle.nullDevice }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let s = stdin, let inPipe = p.standardInput as? Pipe {
                    inPipe.fileHandleForWriting.write(s)
                    try? inPipe.fileHandleForWriting.close()
                }
                var out = Data(), err = Data()
                let lock = NSLock()
                let g = DispatchGroup()
                for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
                    g.enter()
                    DispatchQueue.global().async {
                        while true {
                            let c = pipe.fileHandleForReading.availableData
                            if c.isEmpty { break }
                            lock.lock(); if isOut { out.append(c) } else { err.append(c) }; lock.unlock()
                        }
                        g.leave()
                    }
                }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning {
                    p.terminate()
                    cont.resume(throwing: ScriptError.timeout(timeout))
                    return
                }
                _ = g.wait(timeout: .now() + 2)
                lock.lock(); defer { lock.unlock() }
                cont.resume(returning: CLIResult(status: p.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self)))
            }
        }
    }

    /// A long-running script: stdout and stderr lines (on the main queue), then the exit status (main queue).
    @discardableResult
    public func spawn(_ script: String, _ args: [String], with packages: [String] = [], env extra: [String: String] = [:],
                      onLine: @escaping (String, Bool) -> Void, onExit: @escaping (Int32) -> Void) throws -> Process {
        let p = try makeProcess(script, args, with: packages, env: extra)
        p.standardInput = FileHandle.nullDevice
        streamLines(p, onLine: onLine)
        p.terminationHandler = { pr in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onExit(pr.terminationStatus) }   // let the last lines land
        }
        try p.run()
        return p
    }

    func makeProcess(_ script: String, _ args: [String], with packages: [String], env extra: [String: String]) throws -> Process {
        guard let uv = uvPath else { throw ScriptError.uvMissing }
        let url = scriptURL(script)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ScriptError.scriptMissing(url.path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "-q"] + packages.flatMap { ["--with", $0] } + [url.path] + args
        p.environment = environment().merging(extra) { _, new in new }
        return p
    }
}

/// stdout/stderr of `p` as lines on the main queue (bool = from stderr). Call before p.run().
public func streamLines(_ p: Process, onLine: @escaping (String, Bool) -> Void) {
    for isErr in [false, true] {
        let pipe = Pipe()
        if isErr { p.standardError = pipe } else { p.standardOutput = pipe }
        var buf = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; if !buf.isEmpty { let s = String(decoding: buf, as: UTF8.self); buf = Data(); DispatchQueue.main.async { onLine(s, isErr) } }; return }
            buf.append(chunk)
            // progress bars use \r; treat it as a line end too
            while let i = buf.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...i)
                if !line.isEmpty { DispatchQueue.main.async { onLine(line, isErr) } }
            }
        }
    }
}

// MARK: - C5 rows

/// One row of `agents.py detect` (C5).
public struct AgentStatus: Decodable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var installed: Bool
    public var version: String?
    public var login: String          // ok | logged_out | unknown | n/a
    public var path: String?
    public var state: String          // ready | configured | logged_out | unknown | not_installed
    public var why: String
    public var fix: String
    public var headless: Bool
    public var interactive: String?   // url | terminal | copy | nil

    enum CodingKeys: String, CodingKey { case id, name, installed, version, login, path, state, why, fix, headless, interactive }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? "unknown"
        path = try c.decodeIfPresent(String.self, forKey: .path)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? (installed ? "unknown" : "not_installed")
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix) ?? ""
        headless = try c.decodeIfPresent(Bool.self, forKey: .headless) ?? true
        interactive = try c.decodeIfPresent(String.self, forKey: .interactive)
    }
    public init(id: String, name: String, installed: Bool, state: String) {
        self.id = id; self.name = name; self.installed = installed; self.state = state
        version = nil; login = "unknown"; path = nil; why = ""; fix = ""; headless = true; interactive = nil
    }
    /// can run (or at least be tried) headless
    public var usable: Bool { headless && ["ready", "configured", "unknown"].contains(state) }
}

/// `agents.py detect`
public struct AgentDetect: Decodable {
    public var order: [String]
    public var pick: String?
    public var agents: [AgentStatus]
}

/// `agents.py command`
public struct AgentCommand: Decodable {
    public var id: String
    public var mode: String
    public var argv: [String]?
    public var cwd: String
    public var env: [String: String]
    public var url: String?
    public var events: String?
    public var terminal: Bool
    public var clipboard: String?
    public var openApp: String?
    public var retryExit: Int?
    public var promptFile: String?

    enum CodingKeys: String, CodingKey {
        case id, mode, argv, cwd, env, url, events, terminal, clipboard
        case openApp = "open_app", retryExit = "retry_exit", promptFile = "prompt_file"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        argv = try c.decodeIfPresent([String].self, forKey: .argv)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url)
        events = try c.decodeIfPresent(String.self, forKey: .events)
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        clipboard = try c.decodeIfPresent(String.self, forKey: .clipboard)
        openApp = try c.decodeIfPresent(String.self, forKey: .openApp)
        retryExit = try c.decodeIfPresent(Int.self, forKey: .retryExit)
        promptFile = try c.decodeIfPresent(String.self, forKey: .promptFile)
    }
}

/// One entry of `agents.py install` → changes
public struct InstallChange: Decodable, Hashable {
    public var action: String         // symlink | exists | conflict | run | json_merge | error | manual
    public var path: String?
    public var target: String?
    public var pointsTo: String?
    public var argv: [String]?
    public var key: [String]?
    public var ok: Bool?
    public var error: String?
    public var output: String?
    public var how: String?
    public var what: String?

    enum CodingKeys: String, CodingKey { case action, path, target, argv, key, ok, error, output, how, what, pointsTo = "points_to" }

    /// One line for the confirmation sheet.
    public var summary: String {
        switch action {
        case "symlink": return "link \(path ?? "") → \(target ?? "")"
        case "exists": return "already there: " + (path ?? argv?.joined(separator: " ") ?? "")
        case "conflict": return "\(path ?? "") is another skill (\(pointsTo ?? "?")) — left alone"
        case "run": return "run: " + (argv ?? []).joined(separator: " ")
        case "json_merge": return "add \((key ?? []).joined(separator: ".")) to \(path ?? "")"
        case "manual": return "by hand (\(what ?? "")): \(how ?? "")"
        default: return "\(action): \(error ?? path ?? "")"
        }
    }
    public var changesSomething: Bool { action == "symlink" || action == "run" || action == "json_merge" }
}

public struct InstallPlan: Decodable {
    public var changes: [InstallChange]
    public var applied: Bool
}

public struct FixPrompt: Decodable {
    public var prompt: String
    public var repo: String
    public var items: [String]
}

public enum AgentError: Error, CustomStringConvertible {
    case script(String)                   // the CLI said {"ok": false, "error": …}
    case unknownAgent(String)
    case noHeadless(String)
    public var description: String {
        switch self {
        case .script(let s): return s
        case .unknownAgent(let s): return "unknown agent \(s)"
        case .noHeadless(let s): return "\(s) has no headless mode"
        }
    }
}

// MARK: - A headless run

/// A headless agent run: progress lines parsed from its event stream, exit status at the end. The record lives in
/// $BLURT_HOME/runs/<id>.json (state, agent, repo, items, started, ended, exit, cost_usd, summary) with the raw stream
/// in <id>.log — the main window's "Agent runs" list reads these.
public final class AgentRun {
    public let id: String             // r-YYYYMMDD-HHMMSS-xxxx (also $BLURT_RUN_ID for the agent)
    public let agent: String
    public let items: [String]
    public let repo: URL
    public var process: Process?
    public var format: String?
    public private(set) var lines: [ProgressLine] = []  // human-readable progress
    public private(set) var costUSD: Double?
    public private(set) var finalText: String?
    public fileprivate(set) var exitStatus: Int32?
    public let started = Date()
    public var onLine: ((String) -> Void)?              // raw stream line
    public var onProgress: ((ProgressLine) -> Void)?    // parsed, human-readable
    public var onExit: ((Int32) -> Void)?

    public init(id: String = AgentRun.newID(), agent: String, items: [String] = [], repo: URL, process: Process? = nil) {
        self.id = id; self.agent = agent; self.items = items; self.repo = repo; self.process = process
    }

    public static func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "r-\(f.string(from: Date()))-" + String((0..<4).map { _ in chars.randomElement()! })
    }

    public static var dir: URL { BlurtPaths.home.appendingPathComponent("runs") }
    public var recordURL: URL { AgentRun.dir.appendingPathComponent("\(id).json") }
    public var logURL: URL { AgentRun.dir.appendingPathComponent("\(id).log") }
    public var isRunning: Bool { process?.isRunning == true }

    public func cancel() { process?.terminate() }

    func handle(_ raw: String) {
        onLine?(raw)
        if let fh = try? FileHandle(forWritingTo: logURL) { fh.seekToEndOfFile(); fh.write(Data((raw + "\n").utf8)); try? fh.close() }
        let ev = AgentEvents.parse(raw, format: format)
        if let c = ev.cost { costUSD = c }
        if let t = ev.final { finalText = t }
        if let s = ev.line {
            lines.append(s)
            onProgress?(s)
        }
    }

    func writeRecord(state: String) {
        var o: [String: Any] = ["id": id, "agent": agent, "repo": repo.path, "items": items, "state": state,
                                "started": started.timeIntervalSince1970, "log": logURL.path]
        if let s = exitStatus { o["exit"] = Int(s); o["ended"] = Date().timeIntervalSince1970 }
        if let c = costUSD { o["cost_usd"] = c }
        if let t = finalText { o["summary"] = String(t.prefix(2000)) }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: recordURL, options: .atomic) }
    }
}

/// One human-readable progress line of a run; the UI picks the symbol from `kind` (no glyphs in the text).
public struct ProgressLine: Hashable {
    public enum Kind: String { case say, tool, edit, done, error, log }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

/// Turns one line of an agent's machine-readable output into something a person can follow.
public enum AgentEvents {
    public struct Event { public var line: ProgressLine?; public var cost: Double?; public var final: String? }

    public static func parse(_ line: String, format: String?) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return Event(line: trimmed.isEmpty ? nil : ProgressLine(.log, String(trimmed.prefix(300))), cost: nil, final: nil)
        }
        let type = o["type"] as? String ?? ""
        // Claude Code stream-json
        if type == "assistant", let msg = o["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
            var says: [String] = [], tools: [String] = []
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String { says.append(t) }
                if c["type"] as? String == "tool_use" { tools.append(toolLine(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:])) }
            }
            if !tools.isEmpty { return Event(line: ProgressLine(.tool, oneLine(tools.joined(separator: " · "))), cost: nil, final: nil) }
            return Event(line: says.isEmpty ? nil : ProgressLine(.say, oneLine(says.joined(separator: " "))), cost: nil, final: nil)
        }
        if type == "result" {
            let t = o["result"] as? String
            let failed = o["is_error"] as? Bool == true
            return Event(line: t.map { ProgressLine(failed ? .error : .done, oneLine($0)) }, cost: o["total_cost_usd"] as? Double, final: t)
        }
        if type == "system" { return Event(line: nil, cost: nil, final: nil) }
        // Codex exec --json: {"type":"item.started|item.completed","item":{"type":"agent_message|command_execution|mcp_tool_call|file_change|reasoning",…}}
        if let item = o["item"] as? [String: Any] {
            let it = item["type"] as? String ?? ""
            let done = type.hasSuffix("completed")
            let err = (item["error"] as? [String: Any])?["message"] as? String
            switch it {
            case "agent_message":
                let t = item["text"] as? String ?? ""
                return Event(line: done && !t.isEmpty ? ProgressLine(.say, oneLine(t)) : nil, cost: nil, final: done ? t : nil)
            case "command_execution":
                return Event(line: done ? nil : ProgressLine(.tool, "$ " + oneLine(item["command"] as? String ?? "")), cost: nil, final: nil)
            case "mcp_tool_call":
                let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
                if done, let e = err { return Event(line: ProgressLine(.error, name + ": " + oneLine(e)), cost: nil, final: nil) }
                return Event(line: done ? nil : ProgressLine(.tool, name), cost: nil, final: nil)
            case "file_change":
                let files = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                    .map { ($0 as NSString).lastPathComponent }
                return Event(line: done ? ProgressLine(.edit, files.joined(separator: ", ")) : nil, cost: nil, final: nil)
            default:
                return Event(line: nil, cost: nil, final: nil)
            }
        }
        if type == "turn.failed" || type == "error" {
            let m = (o["error"] as? [String: Any])?["message"] as? String ?? o["message"] as? String ?? "error"
            return Event(line: ProgressLine(.error, oneLine(m)), cost: nil, final: nil)
        }
        // Kimi / OpenCode / others: best effort
        for k in ["text", "content", "message"] {
            if let t = o[k] as? String, !t.isEmpty { return Event(line: ProgressLine(.say, oneLine(t)), cost: nil, final: nil) }
        }
        return Event(line: nil, cost: nil, final: nil)
    }

    static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        if let c = input["command"] as? String { return "\(name): \(oneLine(c))" }
        if let p = input["file_path"] as? String { return "\(name) \((p as NSString).lastPathComponent)" }
        if let u = input["uid"] as? String { return "\(name) \(u.prefix(10))" }
        return name
    }

    static func oneLine(_ s: String) -> String {
        let l = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return l.count > 220 ? String(l.prefix(219)) + "…" : l
    }
}


// MARK: - Agents

public final class Agents {
    public static let shared = Agents()
    public init() {}

    var lang: String { BlurtLocale.lang }

    /// Every agent in the configured order (+ the ones not in it), with installed / login / why / fix.
    public func detect(login: Bool = true, repo: URL? = nil) async throws -> AgentDetect {
        var args = ["detect", "--lang", lang]
        if !login { args.append("--no-login") }
        if let r = repo { args += ["--repo", r.path] }
        let r = try await SkillCLI.shared.run("agents.py", args, timeout: 90)
        guard r.ok, let d = r.decode(AgentDetect.self) else { throw AgentError.script(r.errorText) }
        return d
    }

    /// Every registry id (agents.py detect only lists the configured order; agents left out of record.agents are
    /// still shown in Settings so they can be turned back on).
    public func detectAll(login: Bool = true) async throws -> AgentDetect {
        let ids = registryIDs()
        var args = ["detect", "--lang", lang, "--ids", ids.joined(separator: ",")]
        if !login { args.append("--no-login") }
        let r = try await SkillCLI.shared.run("agents.py", args, timeout: 90)
        guard r.ok, var d = r.decode(AgentDetect.self) else { throw AgentError.script(r.errorText) }
        // configured order first, then the rest in registry order
        let pos = Dictionary(uniqueKeysWithValues: d.order.enumerated().map { ($1, $0) })
        d.agents.sort { (pos[$0.id] ?? 1000 + (ids.firstIndex(of: $0.id) ?? 0)) < (pos[$1.id] ?? 1000 + (ids.firstIndex(of: $1.id) ?? 0)) }
        return d
    }

    /// Ids in agents.json (scripts/ of the skill, else the copy bundled in the app), plus record.agent_defs.
    public func registryIDs() -> [String] {
        var urls = [BlurtPaths.scripts.appendingPathComponent("agents.json")]
        if let u = Bundle.main.url(forResource: "agents", withExtension: "json") { urls.append(u) }
        var ids: [String] = []
        for u in urls {
            if let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = o["agents"] as? [[String: Any]] {
                ids = list.compactMap { $0["id"] as? String }
                break
            }
        }
        for k in ((Config.shared["record.agent_defs"] as? [String: Any]) ?? [:]).keys.sorted() where !ids.contains(k) { ids.append(k) }
        return ids
    }

    /// record.agents (exclusive: only these, in this order). nil = the registry default.
    public var order: [String]? {
        get {
            if let a = Config.shared["record.agents"] as? [String] { return a }
            if let s = Config.shared["record.agents"] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            return nil
        }
        set { Config.shared.set("record.agents", newValue) }
    }

    public func command(_ id: String, mode: String, prompt: String, repo: URL, vars: [String: String] = [:],
                        events: Bool = true) async throws -> AgentCommand {
        // the prompt goes through a file: no argv length limits, nothing to quote
        let pf = BlurtPaths.home.appendingPathComponent("prompts")
        try? FileManager.default.createDirectory(at: pf, withIntermediateDirectories: true)
        let f = pf.appendingPathComponent("in-\(UUID().uuidString.prefix(8)).md")
        try Data(prompt.utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        var args = ["command", id, mode, "--prompt-file", f.path, "--repo", repo.path]
        for (k, v) in vars.sorted(by: { $0.key < $1.key }) { args += ["--var", "\(k)=\(v)"] }
        if !events { args.append("--no-events") }
        let r = try await SkillCLI.shared.run("agents.py", args, timeout: 30)
        guard r.ok, let c = r.decode(AgentCommand.self) else { throw AgentError.script(r.errorText) }
        return c
    }

    /// The environment `agents.py install` runs in: the full login environment, never scrubbed of CODEX_HOME /
    /// CLAUDE_CONFIG_DIR / KIMI_CODE_HOME — those say which config gets written. Values the app itself was started with
    /// win over the login shell's (an explicit relocation, e.g. tests). BLURT_AGENT_HOME (tests) replaces HOME, so
    /// skill links under ~/.claude/skills, ~/.agents/skills… land in a scratch home.
    public func installEnvironment() -> [String: String] {
        var env = SkillCLI.shared.environment()
        let mine = ProcessInfo.processInfo.environment
        for k in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME", "XDG_CONFIG_HOME"] { if let v = mine[k] { env[k] = v } }
        if let h = mine["BLURT_AGENT_HOME"] { env["HOME"] = h }
        return env
    }

    /// `agents.py install ID [--skill] [--mcp] [--dry-run]`. Always preview with dryRun first.
    public func install(_ id: String, skill: Bool = true, mcp: Bool = true, dryRun: Bool) async throws -> InstallPlan {
        var args = ["install", id]
        if skill { args.append("--skill") }
        if mcp { args.append("--mcp") }
        if dryRun { args.append("--dry-run") }
        let env = installEnvironment()
        let saved = SkillCLI.shared.environment
        let cli = SkillCLI()
        cli.environment = { env }
        _ = saved
        let r = try await cli.run("agents.py", args, env: ["BLURT_INSTALL": "1"], timeout: 120)
        guard let plan = r.decode(InstallPlan.self) else { throw AgentError.script(r.errorText) }
        return plan
    }

    /// The fix prompt for these items (agents.py prompt fix — one place for its wording) and the repo to run in.
    public func fixPrompt(_ uids: [String], repo: URL? = nil) async throws -> FixPrompt {
        var args = ["prompt", "fix", "--items"] + uids
        if let r = repo { args += ["--repo", r.path] }
        let r = try await SkillCLI.shared.run("agents.py", args, timeout: 60)
        guard r.ok, let p = r.decode(FixPrompt.self) else { throw AgentError.script(r.errorText) }
        return p
    }

    /// Start a headless run. The agent gets $BLURT_AGENT / $BLURT_RUN_ID (agents.py command's env), so its
    /// mark_fixed / items.py fix calls are attributed to this run.
    public func run(_ id: String, prompt: String, repo: URL, items: [String] = [], runID: String = AgentRun.newID()) async throws -> AgentRun {
        let cmd = try await command(id, mode: "headless", prompt: prompt, repo: repo, vars: ["run_id": runID])
        guard let argv = cmd.argv, let exe = argv.first else { throw AgentError.noHeadless(id) }
        let run = AgentRun(id: runID, agent: id, items: items, repo: URL(fileURLWithPath: cmd.cwd.isEmpty ? repo.path : cmd.cwd))
        run.format = cmd.events
        try FileManager.default.createDirectory(at: AgentRun.dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: run.logURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = run.repo
        p.environment = SkillCLI.shared.environment().merging(cmd.env) { _, new in new }
        p.standardInput = FileHandle.nullDevice         // codex exec otherwise waits for more prompt on stdin
        streamLines(p) { [weak run] line, _ in run?.handle(line) }
        p.terminationHandler = { [weak run] pr in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let run = run else { return }
                run.exitStatus = pr.terminationStatus
                run.writeRecord(state: pr.terminationStatus == 0 ? "done" : (pr.terminationReason == .uncaughtSignal ? "cancelled" : "failed"))
                run.onExit?(pr.terminationStatus)
            }
        }
        run.process = p
        try p.run()
        run.writeRecord(state: "running")
        return run
    }

    /// What to do for an interactive fix (open a url, a terminal command, the clipboard, an app). The app performs
    /// it (AppKit) — see System/FixRunner.swift.
    public func interactive(_ id: String, prompt: String, repo: URL) async throws -> AgentCommand {
        try await command(id, mode: "interactive", prompt: prompt, repo: repo)
    }
}
