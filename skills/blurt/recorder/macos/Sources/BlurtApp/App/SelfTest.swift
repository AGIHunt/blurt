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

    // Dictation: the trigger (right ⌥ alone, never as a modifier) and the history file (Tests/BlurtCoreTests has more)
    func trig(_ s: String, _ mode: DictationTrigger.Mode = .tap, key: DictationTrigger.Key = .rightOption) -> [DictationTrigger.Output] {
        var t = DictationTrigger(key: key, mode: mode)
        return t.run(s)
    }
    // the default: Fn, auto (a tap is hands-free, holding is push-to-talk)
    check("dictation_trigger_auto", DictationTrigger().key == .fn && DictationTrigger().mode == .auto
          && trig("fn-down@0 fn-up@120 fn-down@3000 fn-up@3100", .auto, key: .fn) == [.arm, .start, .stop]
          && trig("fn-down@0 tick@300 fn-up@2000", .auto, key: .fn) == [.arm, .start, .stop]
          && trig("fn-down@0 key:123@50 fn-up@100", .auto, key: .fn) == [.arm])
    check("dictation_trigger", trig("ropt-down@0 ropt-up@120 ropt-down@2000 ropt-up@2100") == [.arm, .start, .stop]
          && trig("ropt-down@0 key:9@50 ropt-up@100") == [.arm] && trig("shift-down@0 ropt-down@10 ropt-up@80") == []
          && trig("ropt-down@0 ropt-up@500") == [.arm] && trig("ropt-down@0 ropt-up@100 esc@600") == [.arm, .start, .cancel]
          && trig("ropt-down@0 tick@260 ropt-up@900", .hold) == [.arm, .start, .stop]
          && trig("ropt-down@0 tick@260 key:0@500 ropt-up@900", .hold) == [.arm, .start, .cancel])
    let hist = DictationHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("blurt-selftest-\(getpid())/history.jsonl"))
    let old = Date().addingTimeInterval(-40 * 86400)
    hist.append(DictationEntry(id: "d-old", time: old, app: "Notes", bundle: "com.apple.Notes", duration: 2, raw: "嗯 旧的", polished: nil,
                               text: "嗯 旧的", model: nil, fellBack: false, reason: nil, insert: "pasted"))
    hist.append(DictationEntry(id: "d-a", time: Date(), app: "Notes", bundle: nil, duration: 3, raw: "um hello", polished: "Hello.",
                               text: "Hello.", model: "qwen3.5-2b", fellBack: false, reason: nil, insert: "pasted"))
    hist.append(DictationEntry(id: "d-b", time: Date(), app: nil, bundle: nil, duration: 1, raw: "bye", polished: nil, text: "bye",
                               model: nil, fellBack: true, reason: "timeout", insert: "copied"))
    hist.delete(["d-b"])
    hist.markItem("d-a", item: "BA-1", uid: "01X")
    let before = hist.load()
    let pruned = hist.prune(days: 30)
    let after = hist.load()
    check("dictation_history", before.map(\.id) == ["d-a", "d-old"] && before.first?.item == "BA-1" && pruned == 1
          && after.map(\.id) == ["d-a"] && after.first?.item == "BA-1" && after.first?.polished == "Hello.", after.map(\.id))
    try? FileManager.default.removeItem(at: hist.url.deletingLastPathComponent())

    // Dictation's listener: a tap made before Input Monitoring is made again once it is granted; Accessibility alone → monitor
    check("dictation_listener", DictationListener(inputMonitoring: false, accessibility: false).plan() == [.createTap]
          && DictationListener(inputMonitoring: true, accessibility: false, tap: true, tapMadeWithAccess: false).plan() == [.recreateTap]
          && DictationListener(inputMonitoring: false, accessibility: true, tap: true).plan() == [.removeTap, .installMonitor]
          && DictationListener(inputMonitoring: true, accessibility: true, tap: true, tapMadeWithAccess: true, monitor: true).plan() == [.removeMonitor]
          // Fn with Accessibility: the filter tap (no Input Monitoring needed), replacing a listen-only one
          && DictationListener(inputMonitoring: false, accessibility: true, wantsFilter: true).plan() == [.createFilterTap]
          && DictationListener(inputMonitoring: true, accessibility: true, tap: true, tapMadeWithAccess: true, wantsFilter: true).plan() == [.recreateFilterTap])
    // the permission guide: the dictation walk's order, the 🌐 setting, docking next to System Settings
    let dock = HelperDock.place(panel: CGSize(width: 330, height: 200), target: CGRect(x: 400, y: 200, width: 700, height: 600),
                                screen: CGRect(x: 0, y: 0, width: 1800, height: 1100))
    check("permission_flow", PermissionPlan.steps(.dictation, satisfied: [.inputMonitoring]) == [.accessibility, .microphone, .fnKey]
          && FnUsage.from(NSNumber(value: 3)) == .startDictation && FnUsage.clashes(nil) && !FnUsage.clashes(.doNothing)
          && dock.side == .right && dock.origin.x == 1112)
    // custom words: learning a fix, the second sighting accepts it
    let vocab = DictationVocabulary(url: FileManager.default.temporaryDirectory.appendingPathComponent("blurt-selftest-\(getpid())/vocabulary.json"))
    let fx = DictationLearn.fixes(typed: "open cloud code now", edited: "open Claude Code now")
    check("dictation_vocab", fx.first?.fixed == "Claude Code" && vocab.learn(heard: "cloud code", fixed: "Claude Code") == .suggested("Claude Code")
          && vocab.learn(heard: "cloud code", fixed: "Claude Code") == .learned("Claude Code") && vocab.active().first?.soundsLike == ["cloud code"],
          fx.map { "\($0.heard)→\($0.fixed)" })
    try? FileManager.default.removeItem(at: vocab.url.deletingLastPathComponent())

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

    // Spotlight results: only our item uids (an extra hit whose id is a window number was returned once)
    check("spotlight_ids", Spotlight.isItemUID("01KAQ6N2W8C3D4E5F6G7H8J9KM") && Spotlight.isItemUID("L" + String(repeating: "a1", count: 12) + "f")
          && !Spotlight.isItemUID("12345") && !Spotlight.isItemUID("01KAQ6N2W8C3D4E5F6G7H8J9KU") && !Spotlight.isItemUID("")
          && Spotlight.ours([("01KAQ6N2W8C3D4E5F6G7H8J9KM", Spotlight.domain), ("4711", nil), ("01KAQ6N2W8C3D4E5F6G7H8J9KN", "other.domain"),
                             ("01KAQ6N2W8C3D4E5F6G7H8J9KP", nil)]) == ["01KAQ6N2W8C3D4E5F6G7H8J9KM", "01KAQ6N2W8C3D4E5F6G7H8J9KP"])

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
