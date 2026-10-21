// Runs the skill's Python CLIs (items.py, index.py, agents.py, live.py, transcribe.py — contract C2/C3/C5) with uv,
// in the user's login-shell environment (what a new terminal has, minus variables a coding-agent session leaked
// into ours). WP4 gate: signatures only; the implementation follows in the next WP4 commit.
import Foundation

public enum ScriptError: Error, CustomStringConvertible {
    case uvMissing                                   // no uv on PATH or in ~/.blurt/bin
    case scriptMissing(String)                       // <skill>/scripts/<name> not found
    case failed(status: Int32, stdout: Data, stderr: String)   // non-zero exit; C2 CLIs still print {"ok":false,…}
    case timeout(TimeInterval)
    case notImplemented

    public var description: String {
        switch self {
        case .uvMissing: return "uv not found"
        case .scriptMissing(let s): return "script not found: \(s)"
        case .failed(let st, _, let err): return "exit \(st): \(err.suffix(500))"
        case .timeout(let t): return "timed out after \(Int(t)) s"
        case .notImplemented: return "not implemented"
        }
    }
}

public final class ScriptRunner {
    public static let shared = ScriptRunner()

    /// `script` is a file name in BlurtPaths.scripts ("items.py") or an absolute path. Returns stdout.
    public func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> Data {
        throw ScriptError.notImplemented
    }

    /// Long-running script (live.py, agents): stdout+stderr lines on the main queue. The caller owns the Process.
    public func spawn(_ script: String, _ args: [String], onLine: @escaping (String) -> Void) throws -> Process {
        throw ScriptError.notImplemented
    }

    public var uvAvailable: Bool { false }
}
