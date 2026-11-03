// uv, the tool every Python script runs through (polish, local models, recordings' transcription), installed quietly
// (docs/design/first-minute-speech.md §4.1; the founder, 2026-10-29: silently, and not when one is already there).
// Dictation works without it (macOS's recogniser), so nothing waits on it: at launch and when the setup assistant
// opens, a uv that answers `uv --version` — on the login shell's PATH, ~/.local/bin, Homebrew's, ~/.blurt/bin
// (ShellEnv.path) — is used as it is; only when there is none does the official installer put one in ~/.blurt/bin
// (no shell profile is touched: UV_NO_MODIFY_PATH). One install at a time; a failed one is tried again at the next
// launch (or the setup assistant's Install uv). Test builds never install anything.
import Foundation
import BlurtCore

enum UVSetup {
    static let installCommand = "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=\"$HOME/.blurt/bin\" UV_NO_MODIFY_PATH=1 sh"
    /// posted on the main thread when an install ended (object: the uv path, or nil when it failed)
    static let finished = Notification.Name("BlurtUVSetupFinished")

    private static let lock = NSLock()
    private static var running = false
    static var installing: Bool { lock.withLock { running } }

    /// A uv that runs (the path), else nil.
    static func usable() -> String? {
        guard let p = ScriptRunner.shared.uvPath else { return nil }
        let r = ShellEnv.runCapture(p, ["--version"], timeout: 5)
        return r.status == 0 ? p : nil
    }

    /// uv there, or installed now in the background. `via`: launch | onboarding | button.
    static func ensure(via: String) {
        if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { return }
        DispatchQueue.global(qos: .utility).async {
            if let p = usable() {
                return emit(["event": "uv_setup", "result": "present", "path": p, "via": via])
            }
            install(via: via)
        }
    }

    private static func install(via: String) {
        let start = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard start else { return }
        let t0 = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var env = ShellEnv.agentEnvironment()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        // ~/.blurt/bin follows BLURT_HOME, like everything else
        p.arguments = ["-c", installCommand.replacingOccurrences(of: "$HOME/.blurt", with: BlurtPaths.home.path)]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let path = usable()
            lock.withLock { running = false }
            emit(["event": "uv_setup", "result": path == nil ? "failed" : "installed", "status": Int(proc.terminationStatus),
                  "via": via, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: finished, object: path)
                // the scripts can run now: dictation's model list and polish model are read again
                if path != nil { Dictation.shared.refreshSpeechModels(); Dictation.shared.refreshPolishModel() }
            }
        }
        do {
            try p.run()
            emit(["event": "uv_setup", "result": "installing", "via": via])
        } catch {
            lock.withLock { running = false }
            emit(["event": "uv_setup", "result": "failed", "error": "\(error)", "via": via])
            DispatchQueue.main.async { NotificationCenter.default.post(name: finished, object: nil) }
        }
    }
}
