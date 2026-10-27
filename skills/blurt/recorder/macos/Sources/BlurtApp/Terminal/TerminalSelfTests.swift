// BLURT_TEST_COMMANDS=1 only: scripted checks for the terminal package, over a distributed notification
//   dev.blurt.recorder.terminal[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": "…"}; every answer is one JSON line on stdout.
//   window [JOB]            the Sessions window, attached to JOB (or the pane's pick)
//   popout JOB              a second Sessions window on JOB
//   attach N JOB            pane N (1 = the Sessions window, 2… = popped-out windows) shows JOB
//   dispatch UID[,UID…]     the dispatch panel                      newsession   the dispatch panel with the item picker
//   review JOB              the finish panel for JOB's worktree
//   type N TEXT             TEXT typed into pane N's terminal (the key-input path: insertText); "\r" sends Return
//   state                   every pane: job, attach state, cols × rows, the visible text
//   size N W H              pane N's window content size            windowid sessions|dispatch [N]
//   dispatch-set target terminal|desktop   where the panel's hand-off runs (DesktopApp: nothing opens under tests —
//                           its link is reported as event desktop_open)
//   desktop-check AGENT yes|no|ask   what Continue in Claude Desktop's check says (yes / no: an override; ask: the CLI)
//   continue-desktop JOB    what the header's Continue in Claude Desktop does after its confirmation
//   keylook                 the hand-off panels and the Sessions window drawn as the key window (screenshots)
//   panels-close            every hand-off panel and review sheet closes, as Cancel does
import AppKit
import SwiftTerm
import BlurtCore

/// Screenshots of a test build in the background (`keylook`): a hand-off panel or the Sessions window draws as the key
/// window — its default button filled, switches in the accent — without taking the focus from the app the user is in.
/// Patches only these windows' own classes, as SettingsTestKeyLook does for Settings.
@MainActor
enum PanelKeyLook {
    private static var patched: Set<ObjectIdentifier> = []

    static func apply(_ w: NSWindow) {
        let cls: AnyClass = type(of: w)
        if patched.insert(ObjectIdentifier(cls)).inserted {
            let names = ["isKeyWindow", "isMainWindow", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "_hasKeyAppearance",
                         "_hasMainAppearance", "hasKeyAppearance", "hasMainAppearance", "_hasActiveControls"]
            for sel in names.map(NSSelectorFromString) {
                guard let m = class_getInstanceMethod(cls, sel) else { continue }
                let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
                class_replaceMethod(cls, sel, imp_implementationWithBlock(yes), method_getTypeEncoding(m))
            }
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: w)
        // the window's buttons (the traffic lights) follow the key state through their own message, not a redraw
        let changed = NSSelectorFromString("_windowChangedKeyState")
        func redraw(_ v: NSView) {
            if v.responds(to: changed) { v.perform(changed) }
            v.needsDisplay = true
            v.subviews.forEach(redraw)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if let v = w.contentView?.superview ?? w.contentView { redraw(v) } }
    }
}

@MainActor
enum TerminalSelfTests {
    static var channel: String { "dev.blurt.recorder.terminal" + (ProcessInfo.processInfo.environment["BLURT_TEST_CHANNEL"].map { ".\($0)" } ?? "") }

    static func install() {
        guard ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init(channel), object: nil, queue: .main) { n in
            guard let cmd = n.userInfo?["cmd"] as? String else { return }
            MainActor.assumeIsolated { run(cmd) }
        }
        emit(["event": "terminal_ready", "channel": channel])
    }

    static var windows: [SessionsWindowController] {
        [SessionsWindowController.shared] + NSApp.windows.compactMap { $0.windowController as? SessionsWindowController }
            .filter { $0 !== SessionsWindowController.shared }
    }
    static func pane(_ n: Int) -> SessionsPaneController? { windows.indices.contains(n - 1) ? windows[n - 1].pane : nil }

    static func run(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let words = arg.split(separator: " ").map(String.init)
        func out(_ o: [String: Any]) { emit(["event": "terminal", "cmd": parts.first ?? ""].merging(o) { _, n in n }) }
        switch parts.first ?? "" {
        case "window":
            SessionsWindowController.shared.show(job: arg.isEmpty ? nil : arg)
            out(["window": SessionsWindowController.shared.window?.windowNumber ?? -1])
        case "popout":
            SessionsWindowController.shared.show(job: arg, newWindow: true)
            out(["windows": windows.map { $0.window?.windowNumber ?? -1 }])
        case "attach":
            guard words.count == 2, let n = Int(words[0]), let p = pane(n) else { out(["error": "usage"]); return }
            p.attach(job: words[1])
            out(["pane": n, "job": words[1]])
        case "dispatch":
            DispatchPanel.show(items: arg.split(separator: ",").map(String.init))
            out(["window": DispatchPanel.windowNumber ?? -1])
        case "dispatch-set":            // dispatch-set mode together|parallel | worktree on|off | agent ID | model ID|default | options open|closed | items open|closed | chosen N
            guard let m = DispatchPanel.current?.model, words.count == 2 else { out(["error": "no panel"]); return }
            if words[0] == "mode" { m.mode = DispatchMode(rawValue: words[1]) ?? .together }
            if words[0] == "worktree" { m.worktree = WorktreeChoice(rawValue: words[1]) ?? .auto }
            if words[0] == "agent" { m.agent = words[1]; m.agentTouched = true }
            if words[0] == "model" { m.model = words[1] == "default" ? "" : words[1] }
            if words[0] == "target" { m.target = HandoffTarget(rawValue: words[1]) ?? .terminal }
            if words[0] == "options" { UserDefaults.standard.set(words[1] == "open", forKey: "handoff.optionsOpen") }   // › Options
            if words[0] == "items" { m.itemsOpen = words[1] == "open" }                 // "6 items" opened
            if words[0] == "chosen", let n = Int(words[1]) { m.chosen = Set(m.candidates.prefix(n).map(\.uid)) }   // New Session
            out(["ok": true])
        case "dispatch-state":
            guard let m = DispatchPanel.current?.model else { out(["error": "no panel"]); return }
            out(["agent": m.agent, "agents": m.agents.map(\.id), "items": m.items.map { "\($0.ref) \($0.title)" },
                 "model": m.model, "models": m.models.map(\.id), "cli_default": m.cliDefault ?? NSNull(),
                 "warnings": m.warnings.map(\.code), "worktree": m.worktreeOn, "branch": m.branchPreview ?? NSNull(),
                 "phase": "\(m.phase)", "can_start": m.canStart, "target": m.target.rawValue,
                 "desktop_available": m.desktopAvailable, "desktop_mcp": m.desktopMCP ?? NSNull()])
        case "desktop-check":
            guard words.count == 2 else { out(["error": "usage"]); return }
            switch words[1] {
            case "yes": DesktopApp.checkOverride[words[0]] = DesktopContinueCheck(available: true, reason: nil, version: "test")
            case "no": DesktopApp.checkOverride[words[0]] = DesktopContinueCheck(available: false, reason: "version", version: "test")
            case "nomcp": DesktopApp.checkOverride[words[0]] = DesktopContinueCheck(available: true, reason: nil, version: "test", mcp: false)
            default: DesktopApp.checkOverride[words[0]] = nil
            }
            SessionsModel.shared.objectWillChange.send()
            out(["agent": words[0], "check": words[1]])
        case "continue-desktop":
            guard let p = pane(1) else { out(["error": "no pane"]); return }
            p.performContinueDesktop(arg) { err in out(["job": arg, "error": err ?? NSNull()]) }
        case "continue-desktop-ask":    // the ⋯ menu's Continue in Claude Desktop…: its confirmation, on screen
            guard let p = pane(1) else { out(["error": "no pane"]); return }
            p.continueDesktop(arg)
            out(["job": arg])
        case "continue-desktop-nomcp":  // what that confirmation's Continue does when the blurt MCP isn't installed
            guard let p = pane(1) else { out(["error": "no pane"]); return }
            p.performContinueDesktop(arg, withoutMCP: true) { err in out(["job": arg, "error": err ?? NSNull()]) }
        case "dispatch-start":
            guard let c = DispatchPanel.current else { out(["error": "no panel"]); return }
            c.start()
            out(["ok": true])
        case "newsession":
            TerminalHost.shared.newSession(project: nil, items: [])
            out(["window": DispatchPanel.windowNumber ?? -1])
        case "review":
            FinishPanel.show(job: arg, over: SessionsWindowController.shared.window)
            out(["job": arg])
        case "finish":                  // finish merge|pr|discard|keep|end-merge — what the finish panel's buttons do
            guard let m = FinishPanel.current else { out(["error": "no panel"]); return }
            Task { @MainActor in
                if arg.hasPrefix("end-") { await m.endSessionThen(String(arg.dropFirst(4))) } else { await m.run(arg) }
                out(["action": arg, "phase": "\(m.phase)", "pr": m.prURL ?? NSNull()])
            }
        case "dispatch-app":            // dispatch-app REF: as on a Mac without tmux (sessions.py --runner app → AppRunner)
            Task { @MainActor in
                do {
                    let o = try await ScriptRunner.shared.json("sessions.py", ["dispatch", "--items", arg, "--worktree", "off", "--runner", "app"], timeout: 120)
                    for l in o["launch"] as? [[String: Any]] ?? [] {
                        guard let job = l["job"] as? String, let argv = l["argv"] as? [String], !argv.isEmpty else { continue }
                        AppRunner.shared.launch(AppLaunch(job: job, argv: argv, env: l["env"] as? [String: String] ?? [:],
                                                          cwd: URL(fileURLWithPath: l["cwd"] as? String ?? NSHomeDirectory())))
                        TerminalModule.reveal(job: job)
                        out(["job": job])
                    }
                } catch { out(["error": "\(error)"]) }
            }
        case "fixwatch":                // the stores FixWatcher follows and what it reads from FILE's front-matter
            let fm = arg.isEmpty ? nil : FixWatcher.frontMatter(URL(fileURLWithPath: arg))
            out(["stores": FixWatcher.stores().map(\.path), "state": fm.map(FixWatcher.state) ?? NSNull(),
                 "projects": ProjectStore.shared.projects.map(\.id)])
        case "type":
            guard words.count >= 2, let n = Int(words[0]), let t = pane(n)?.surface.term else { out(["error": "no terminal"]); return }
            let text = words.dropFirst().joined(separator: " ").replacingOccurrences(of: "\\r", with: "\r")
            t.window?.makeFirstResponder(t)
            for chunk in text.split(separator: "\r", omittingEmptySubsequences: false).enumerated() {
                if chunk.offset > 0 { t.send(txt: "\r") }
                if !chunk.element.isEmpty { t.insertText(String(chunk.element), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
            out(["pane": n, "typed": text.count])
        case "state":
            out(["panes": windows.enumerated().map { i, w -> [String: Any] in
                let p = w.pane
                var o: [String: Any] = ["pane": i + 1, "job": p.state.job ?? NSNull(), "attach": "\(p.state.attach)",
                                        "window": w.window?.windowNumber ?? -1, "visible": w.window?.isVisible ?? false]
                if let t = p.surface.term {
                    let term = t.getTerminal()
                    o["cols"] = term.cols
                    o["rows"] = term.rows
                    o["text"] = (0..<term.rows).compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
                        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    o["running"] = t.process.running
                }
                return o
            }, "sessions": SessionsModel.shared.rows.map { ["job": $0.id, "status": $0.status.rawValue, "label": $0.label,
                                                           "project": $0.projectName, "alive": $0.alive] }])
        case "size":
            guard words.count == 3, let n = Int(words[0]), let w = Double(words[1]), let h = Double(words[2]),
                  let win = windows.indices.contains(n - 1) ? windows[n - 1].window : nil else { out(["error": "usage"]); return }
            win.setContentSize(NSSize(width: w, height: h))
            out(["pane": n, "size": [w, h]])
        case "panels-close":            // every hand-off panel and review sheet closes (Cancel)
            let ws = NSApp.windows.filter { $0 is HandoffWindow && $0.isVisible }
            for w in ws { if let p = w.sheetParent { p.endSheet(w) } else { w.close() } }
            SessionsModel.shared.rebuild()      // as the gone alert's Close: the card behind says so
            out(["closed": ws.count])
        case "keylook":                 // the panels and the Sessions window drawn as key though another app has the focus
            let ws = NSApp.windows.filter { $0 is HandoffWindow || $0 is SessionsWindow }
            ws.forEach(PanelKeyLook.apply)
            out(["windows": ws.map(\.windowNumber)])
        case "windowid":
            switch words.first ?? "sessions" {
            case "dispatch": out(["window": DispatchPanel.windowNumber ?? -1])
            default:
                let n = Int(words.dropFirst().first ?? "1") ?? 1
                out(["window": windows.indices.contains(n - 1) ? windows[n - 1].window?.windowNumber ?? -1 : -1])
            }
        default: out(["error": "unknown command"])
        }
    }
}
