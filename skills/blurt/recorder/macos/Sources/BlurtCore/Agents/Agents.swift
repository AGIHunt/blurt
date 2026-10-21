// Coding agents through agents.py (contract C5): the app only runs the argv / url `agents.py command` returns, with
// the login-shell environment. Owned by WP6 (mac-settings-system); WP4-gate stub: types and signatures only.
// (BlurtApp/App/AgentHub.swift is today's in-app implementation for background processing; WP6 decides its fate.)
import Foundation

/// One line of `agents.py detect`
public struct AgentStatus: Decodable, Hashable {
    public var id: String
    public var installed: Bool
    public var version: String?
    public var login: String          // ok | logged_out | unknown
    public var path: String?
}

/// A headless run: stream-json lines as they arrive, exit status at the end.
public final class AgentRun {
    public let id: String             // r-YYYYMMDD-HHMMSS-xxxx (also $BLURT_RUN_ID for the agent)
    public let agent: String
    public var process: Process?
    public var onLine: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public init(id: String, agent: String, process: Process? = nil) { self.id = id; self.agent = agent; self.process = process }
}

public enum AgentError: Error { case notImplemented, unknownAgent(String), noHeadless(String) }

public final class Agents {
    public static let shared = Agents()
    public init() {}
    public func detect() async -> [AgentStatus] { [] }
    public func run(_ id: String, prompt: String, repo: URL) throws -> AgentRun { throw AgentError.notImplemented }
    public func openInteractive(_ id: String, prompt: String, repo: URL) throws { throw AgentError.notImplemented }
}
