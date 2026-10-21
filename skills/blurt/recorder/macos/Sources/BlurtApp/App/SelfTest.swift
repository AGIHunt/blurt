// `blurt-recorder --selftest [SESSION_DIR]`: checks BlurtCore without a GUI (no XCTest with the Command Line Tools
// alone), prints one JSON object and exits 0 when every check passed. Used by tests/test_mac_shell.py and CI.
//   • ScriptRunner: uv found, `items.py get SESSION I-001` (C2) parses, stdin reaches the script, timeout works,
//     a missing script / a failing script are reported as errors;
//   • ShellEnv: agent-session variables stripped, the user's config locators kept;
//   • KeyCombo grammar round trip; Config dotted keys.
import Foundation
import BlurtCore

func runSelfTest(_ args: [String]) -> Never {
    var checks: [String: Any] = [:]
    var ok = true
    func check(_ name: String, _ pass: Bool, _ detail: Any? = nil) {
        checks[name] = detail.map { ["ok": pass, "detail": $0] } ?? pass
        if !pass { ok = false }
    }

    // ShellEnv
    check("env_strips_session", ShellEnv.isAgentSessionVar("CLAUDECODE") && ShellEnv.isAgentSessionVar("CLAUDE_CODE_SIMPLE")
          && ShellEnv.isAgentSessionVar("ANTHROPIC_BASE_URL") && ShellEnv.isAgentSessionVar("CODEX_SANDBOX"))
    check("env_keeps_config", !ShellEnv.isAgentSessionVar("CODEX_HOME") && !ShellEnv.isAgentSessionVar("CLAUDE_CONFIG_DIR")
          && !ShellEnv.isAgentSessionVar("KIMI_CODE_HOME") && !ShellEnv.isAgentSessionVar("PATH"))
    let env = ShellEnv.agentEnvironment()
    check("env_blurt_app", env["BLURT_APP"] == "1" && env["CLAUDECODE"] == nil)
    if let h = ProcessInfo.processInfo.environment["CODEX_HOME"] { check("env_codex_home_passed", env["CODEX_HOME"] == h) }

    // KeyCombo / Config
    let kc = KeyCombo.parse("⌥⇧R")
    check("keycombo", kc?.spec == "opt+shift+R" && KeyCombo.parse("ctrl+F5")?.label == "⌃F5" && KeyCombo.parse("shift+A") == nil
          && KeyCombo.parse("off") == nil)
    let cfg = Config(url: FileManager.default.temporaryDirectory.appendingPathComponent("blurt-selftest-\(getpid()).json"))
    cfg.set("record.hotkeys.snap", "off")
    check("config_dotted", (cfg["record.hotkeys"] as? [String: Any])?["snap"] as? String == "off")
    cfg.set("record.hotkeys.snap", nil)
    check("config_prunes", cfg.all.isEmpty)
    try? FileManager.default.removeItem(at: cfg.url)

    // blurt:// routes (C7 + blurt://open, which the Tauri app and the docs use for the main window)
    check("url_routes", URLRouter.route(URL(string: "blurt://open")!) == .open
          && URLRouter.route(URL(string: "blurt://item/01ABC")!) == .item("01ABC")
          && URLRouter.route(URL(string: "blurt://settings/agents")!) == .settings("agents")
          && URLRouter.route(URL(string: "blurt://record")!) == .shell("record")
          && URLRouter.route(URL(string: "blurt://nope")!) == .unknown)

    // ScriptRunner
    let r = ScriptRunner.shared
    check("uv", r.uvAvailable, r.uvPath ?? "missing")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        if let session = args.first {
            do {
                let o = try await r.json("items.py", ["get", session, "I-001"], timeout: 120)
                let item = o["item"] as? [String: Any]
                check("items_get", o["ok"] as? Bool == true && (item?["uid"] as? String)?.isEmpty == false, item?["uid"] ?? o)
            } catch { check("items_get", false, "\(error)") }
            do {
                _ = try await r.run("items.py", ["get", session, "I-999"], timeout: 120)
                check("items_error", false, "no error")
            } catch ScriptError.failed(let st, let out, _) {
                check("items_error", st == 1 && String(decoding: out, as: UTF8.self).contains("\"ok\": false"), st)
            } catch { check("items_error", false, "\(error)") }
        }
        // stdin + timeout through an ad-hoc script (no skill needed)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let echo = dir.appendingPathComponent("echo.py"), slow = dir.appendingPathComponent("slow.py")
        try? "import sys\nsys.stdout.write(sys.stdin.read().upper())\n".write(to: echo, atomically: true, encoding: .utf8)
        try? "import time\ntime.sleep(30)\n".write(to: slow, atomically: true, encoding: .utf8)
        do {
            let d = try await r.run(echo.path, [], stdin: Data("hello".utf8), timeout: 60)
            check("stdin", String(decoding: d, as: UTF8.self) == "HELLO", String(decoding: d, as: UTF8.self))
        } catch { check("stdin", false, "\(error)") }
        let t0 = Date()
        do { _ = try await r.run(slow.path, [], timeout: 2); check("timeout", false, "returned") } catch ScriptError.timeout {
            check("timeout", Date().timeIntervalSince(t0) < 10, Date().timeIntervalSince(t0))
        } catch { check("timeout", false, "\(error)") }
        do { _ = try await r.run("no-such-script.py", []); check("missing_script", false) } catch ScriptError.scriptMissing {
            check("missing_script", true)
        } catch { check("missing_script", false, "\(error)") }
        try? FileManager.default.removeItem(at: dir)
        sem.signal()
    }
    sem.wait()
    if let d = try? JSONSerialization.data(withJSONObject: ["ok": ok, "checks": checks], options: [.sortedKeys]) {
        FileHandle.standardOutput.write(d + Data("\n".utf8))
    }
    exit(ok ? 0 : 1)
}
