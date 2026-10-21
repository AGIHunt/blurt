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
import AppKit
import SwiftTerm
import BlurtCore

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
        case "dispatch-set":            // dispatch-set mode together|parallel | worktree on|off
            guard let m = DispatchPanel.current?.model, words.count == 2 else { out(["error": "no panel"]); return }
            if words[0] == "mode" { m.mode = DispatchMode(rawValue: words[1]) ?? .together }
            if words[0] == "worktree" { m.worktree = WorktreeChoice(rawValue: words[1]) ?? .auto }
            out(["ok": true])
        case "dispatch-state":
            guard let m = DispatchPanel.current?.model else { out(["error": "no panel"]); return }
            out(["agent": m.agent, "agents": m.agents.map(\.id), "items": m.items.map { "\($0.ref) \($0.title)" },
                 "warnings": m.warnings.map(\.code), "worktree": m.worktreeOn, "branch": m.branchPreview ?? NSNull(),
                 "phase": "\(m.phase)", "can_start": m.canStart])
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
        case "finish":                  // finish merge|pr|discard|keep — what the finish panel's buttons do
            guard let m = FinishPanel.current else { out(["error": "no panel"]); return }
            Task { @MainActor in
                await m.run(arg)
                out(["action": arg, "phase": "\(m.phase)", "pr": m.prURL ?? NSNull()])
            }
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
