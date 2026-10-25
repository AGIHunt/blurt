// The agent's desktop app as a hand-off target (agents.json interactive.desktop — Claude): is it installed, open a
// hand-off's claude:// link in it, bring it forward (Go to Claude), and whether a running terminal session may
// continue there (sessions.py desktop-check, asked once per agent and kept for ten minutes).
// Blurt never sends anything in the app: the link fills in a new conversation and the user confirms the folder and
// presses Send. Under BLURT_TEST_COMMANDS nothing is opened at all — the link is checked and reported on stdout
// (event desktop_open), so test runs never reach the user's real Claude.
import AppKit
import SwiftUI
import BlurtCore

enum DesktopApp {
    static var testMode: Bool { ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" }

    static func spec(_ agent: String) -> [String: Any]? { AgentHub.shared.def(agent)?.desktop }
    static func supports(_ agent: String) -> Bool { spec(agent)?["url"] as? String != nil }
    /// What the app is called ("Claude"): "Run in Claude desktop", "Go to Claude".
    static func name(_ agent: String) -> String { spec(agent)?["name"] as? String ?? AgentNames.name(agent) }
    static func bundleID(_ agent: String) -> String? { (spec(agent)?["app"] as? [String: Any])?["macos"] as? String }
    static func appURL(_ agent: String) -> URL? {
        bundleID(agent).flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
    /// The hand-off sheet offers the desktop app only when it is installed.
    static func available(_ agent: String) -> Bool { supports(agent) && appURL(agent) != nil }

    /// The remembered choice for `agent` (config sessions.target), the terminal when its app isn't there.
    static func target(_ agent: String) -> HandoffTarget {
        HandoffTarget.resolve(Config.shared[HandoffTarget.configKey], agent: agent, available: available(agent))
    }
    static func remember(_ agent: String, _ t: HandoffTarget) {
        guard target(agent) != t else { return }
        Config.shared.set(HandoffTarget.configKey, HandoffTarget.store(Config.shared[HandoffTarget.configKey], agent: agent, target: t))
        NotificationCenter.default.post(name: targetChanged, object: agent)  // an open hand-off sheet follows Settings
    }
    static let targetChanged = Notification.Name("BlurtHandoffTargetChanged")

    /// A hand-off's link (sessions.py dispatch --runner desktop): only the app's own scheme (DesktopLink).
    static func open(_ url: URL, job: String) {
        guard DesktopLink.url(url.absoluteString) != nil else { return }
        let parts = DesktopLink.parts(url)
        emit(["event": "desktop_open", "job": job, "scheme": url.scheme ?? "", "host": url.host ?? "",
              "folder": parts.folder ?? NSNull(), "prompt_chars": parts.prompt?.count ?? 0,
              "prompt_title": parts.prompt?.split(separator: "\n").first.map(String.init) ?? NSNull(),
              "url_chars": url.absoluteString.count, "opened": !testMode])
        if !testMode { NSWorkspace.shared.open(url) }
    }

    /// Go to Claude: the app comes forward (it holds the conversation; Blurt has no link to one already started).
    static func goTo(_ agent: String) {
        emit(["event": "desktop_go", "agent": agent, "opened": !testMode])
        guard !testMode else { return }
        if let app = appURL(agent) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let s = spec(agent)?["open"] as? String, let u = DesktopLink.url(s) {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Continue in Claude Desktop

    @MainActor private static var checks: [String: (at: Date, check: DesktopContinueCheck)] = [:]
    @MainActor private static var asking: Set<String> = []
    /// Self-tests: what desktop-check answers, without asking the CLI.
    @MainActor static var checkOverride: [String: DesktopContinueCheck] = [:]
    static let checkLife: TimeInterval = 600

    /// The last answer (nil = not asked yet); asks in the background when there is none or it is old, then `changed`.
    @MainActor static func continueCheck(_ agent: String, changed: @escaping () -> Void) -> DesktopContinueCheck? {
        if let o = checkOverride[agent] { return o }
        guard supports(agent) else { return nil }
        let cur = checks[agent]
        if (cur == nil || Date().timeIntervalSince(cur!.at) > checkLife) && !asking.contains(agent) {
            asking.insert(agent)
            Task { @MainActor in
                defer { asking.remove(agent) }
                let c = (try? await AgentSessions.shared.desktopCheck(agent: agent))
                    ?? DesktopContinueCheck(available: false, reason: "unknown", version: nil)
                checks[agent] = (Date(), c)
                emit(["event": "desktop_check", "agent": agent, "available": c.available, "reason": c.reason ?? NSNull()])
                changed()
            }
        }
        return cur?.check
    }

    /// Ask again next time (the blurt MCP was just installed: the confirmation no longer warns).
    @MainActor static func forgetCheck(_ agent: String) { checks[agent] = nil }
}

/// The blurt MCP installer for `agent` (Settings → Agents: AgentsModel preview, then apply), shown from Continue in
/// Claude Desktop's confirmation. `close` once it is done, cancelled or failed.
struct MCPInstallHost: View {
    @ObservedObject var m = AgentsModel.shared
    let agent: String
    let close: () -> Void
    @State private var shown = false

    var body: some View {
        Group {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
            else { ProgressView().controlSize(.small).padding(40) }
        }
        .task {
            await m.preview(CoreAgent(id: agent, name: AgentNames.name(agent), installed: true, state: "ready"))
            if m.plan == nil { close() } else { shown = true }
        }
        .onChange(of: m.plan == nil) { gone in if gone && shown { close() } }
    }
}
