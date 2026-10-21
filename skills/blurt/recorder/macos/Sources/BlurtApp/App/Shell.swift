import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Launching the user's agent CLI (claude / codex) and other tools

// The environment logic lives in BlurtCore (ShellEnv, shared with ScriptRunner); these are the app's old names for it.

func runCapture(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: Double) -> (status: Int32?, out: Data) {
    ShellEnv.runCapture(exe, args, env: env, timeout: timeout)
}
func isAgentSessionVar(_ k: String) -> Bool { ShellEnv.isAgentSessionVar(k) }
var inheritedEnv: [String: String] { ShellEnv.inherited }
var loginShellEnv: [String: String] { ShellEnv.loginShell }
var userPATH: String { ShellEnv.path }
func agentEnvironment() -> [String: String] { ShellEnv.agentEnvironment() }
func findExecutable(_ name: String) -> String? { ShellEnv.findExecutable(name) }

func shell(_ cmd: String, cwd: URL, log: URL, append: Bool = false, done: @escaping (Int32) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.environment = agentEnvironment()
    p.standardInput = FileHandle.nullDevice   // codex exec otherwise waits for more prompt on stdin
    p.currentDirectoryURL = cwd
    if !append || !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    let fh = try? FileHandle(forWritingTo: log)
    fh?.seekToEndOfFile()
    p.standardOutput = fh
    p.standardError = fh
    p.terminationHandler = { pr in DispatchQueue.main.async { done(pr.terminationStatus) } }
    try? p.run()
}

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
