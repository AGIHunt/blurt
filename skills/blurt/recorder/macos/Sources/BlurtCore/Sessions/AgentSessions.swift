// K5: agent sessions in tmux (private socket `tmux -L $BLURT_TMUX_SOCKET`, default "blurt"), driven through
// sessions.py — Swift never builds tmux or agent command lines itself.
//
// G0 (docs/design/next-round.md "所有权、闸门和合并"): the shared interface, written by P4 so the packages compile
// against it; P3 owns this file from here on.
import Foundation

public enum DispatchMode: String { case together, parallel }
public enum WorktreeChoice: String { case on, off, auto }

public struct DispatchWarning {
    public let code: String          // concurrent_edit | no_git | no_tmux | draft_confirmed
    public let jobs: [String]
    public let items: [String]
    public init(code: String, jobs: [String], items: [String]) { self.code = code; self.jobs = jobs; self.items = items }
}

public struct DispatchResult {
    public let jobs: [String]
    public let warnings: [DispatchWarning]
    public init(jobs: [String], warnings: [DispatchWarning]) { self.jobs = jobs; self.warnings = warnings }
}

public enum SessionsError: Error, CustomStringConvertible {
    case cli(code: String, message: String)
    public var code: String { switch self { case .cli(let c, _): return c } }
    public var description: String { switch self { case .cli(let c, let m): return "\(c): \(m)" } }
}

public final class AgentSessions {
    public static let shared = AgentSessions()
    public init() {}

    public var tmuxAvailable: Bool { ShellEnv.findExecutable("tmux") != nil }

    private func cli(_ args: [String], timeout: TimeInterval = 60) async throws -> [String: Any] {
        do {
            let o = try await ScriptRunner.shared.json("sessions.py", args, timeout: timeout)
            guard o["ok"] as? Bool == true else { throw SessionsError.cli(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? "") }
            return o
        } catch ScriptError.failed(_, let out, let err) {
            let line = String(decoding: out, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? "{}"
            let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
            throw SessionsError.cli(code: j["code"] as? String ?? "failed", message: j["error"] as? String ?? err)
        } catch ScriptError.scriptMissing(let p) {
            throw SessionsError.cli(code: "no_scripts", message: p)
        }
    }

    public func dispatch(items: [String], agent: String?, mode: DispatchMode, worktree: WorktreeChoice, dryRun: Bool) async throws -> DispatchResult {
        var args = ["dispatch", "--items"] + items + ["--mode", mode.rawValue, "--worktree", worktree.rawValue,
                                                      "--lang", Loc.language == "zh-Hans" ? "zh" : "en"]
        if let a = agent { args += ["--agent", a] }
        if dryRun { args.append("--dry-run") }
        let o = try await cli(args)
        let jobs = (o["jobs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let warnings = (o["warnings"] as? [[String: Any]] ?? []).map {
            DispatchWarning(code: $0["code"] as? String ?? "", jobs: $0["jobs"] as? [String] ?? [], items: $0["items"] as? [String] ?? [])
        }
        return DispatchResult(jobs: jobs, warnings: warnings)
    }

    public func attachCommand(job: String) async throws -> (argv: [String], env: [String: String]) {
        let o = try await cli(["attach-cmd", job])
        return (o["argv"] as? [String] ?? [], o["env"] as? [String: String] ?? [:])
    }

    public func openExternal(job: String, terminal: String?) async throws {
        _ = try await cli(["open-external", job] + (terminal.map { ["--terminal", $0] } ?? []))
    }

    public func send(job: String, text: String, enter: Bool) async throws {
        _ = try await cli(["send", job, "--text", text] + (enter ? ["--enter"] : []))
    }

    public func stop(job: String, kill: Bool) async throws {
        _ = try await cli(["stop", job] + (kill ? ["--kill"] : []))
    }

    public func finish(job: String, action: String) async throws -> [String: Any] {
        try await cli(["finish", job, "--action", action], timeout: 300)
    }
}
