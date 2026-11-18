// Settings → General → Cards → "Dragging a card into an agent" → Agents…: which apps are agents that get the picture's
// path and the note (BlurtCore AgentWindow, v1.0.21). The built-in list, each with a switch (record.agent_apps: an app
// switched off is stored as false), and the apps the user added (stored as true), each with a remove button; Add
// App… picks any app from /Applications. A list, not rules on app names: a name doesn't say whether an app reads this
// Mac's files (Kimi / Kimi Code, 豆包 / 豆包工作), and the built-in list still grows with Blurt.
import AppKit
import SwiftUI
import BlurtCore

/// The built-in agents' names (the installed app's own name when it is there) and, for the apps that are agents only
/// in some windows, which ones.
enum AgentApps {
    static let names: [String: String] = [
        AgentWindow.codex: "Codex", AgentWindow.claude: "Claude Code",
        "com.tencent.workbuddy.mac": "WorkBuddy", "com.qoder.work": "QoderWork", "com.qoder.ide": "Qoder",
        "com.kimi.code.desktop": "Kimi Code", "com.work.pc.doubao": "豆包工作 DoubaoWork",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf", "com.trae.app": "Trae",
        "cn.trae.app": "Trae CN", "com.google.antigravity": "Antigravity", "dev.kiro.desktop": "Kiro",
    ]

    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String {
        if let n = names[id] { return n }
        if let u = url(id) { return (FileManager.default.displayName(atPath: u.path) as NSString).deletingPathExtension }
        return id
    }

    static func icon(_ id: String) -> NSImage? { url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// "Only in Codex mode" / "Only in the Code tab"
    static func note(_ id: String) -> String? {
        switch id {
        case AgentWindow.codex: return T("settings.general.agent_apps.codex_note")
        case AgentWindow.claude: return T("settings.general.agent_apps.claude_note")
        default: return nil
        }
    }
}

struct AgentAppsSheet: View {
    var close: () -> Void
    @State private var changes = AgentProbe.changes

    /// built-in first (installed ones first, then by name), then the user's own
    private var builtIn: [String] {
        AgentWindow.builtIn.sorted { a, b in
            let ia = AgentApps.url(a) != nil, ib = AgentApps.url(b) != nil
            return ia != ib ? ia : AgentApps.name(a).localizedStandardCompare(AgentApps.name(b)) == .orderedAscending
        }
    }
    private var added: [String] {
        changes.filter { $0.value && !AgentWindow.builtIn.contains($0.key) }.keys
            .sorted { AgentApps.name($0).localizedStandardCompare(AgentApps.name($1)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("settings.general.agent_apps.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(T("settings.general.agent_apps.note"))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(added + builtIn, id: \.self) { id in
                        row(id)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(height: 320)
            .padding(.top, 12)
            HStack(spacing: 10) {
                Button(T("settings.general.agent_apps.add")) { addApps() }
                Spacer()
                Button(T("settings.general.agent_apps.done")) { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 460)
    }

    @ViewBuilder private func row(_ id: String) -> some View {
        let isBuiltIn = AgentWindow.builtIn.contains(id)
        let installed = AgentApps.url(id) != nil
        HStack(spacing: 10) {
            Group {
                if let i = AgentApps.icon(id) { Image(nsImage: i).resizable() } else { Image(systemName: "app.dashed").resizable() }
            }
            .frame(width: 22, height: 22).opacity(installed ? 1 : 0.4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentApps.name(id)).foregroundStyle(installed ? .primary : .secondary)
                if let n = AgentApps.note(id) {
                    Text(n).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                } else if !installed {
                    Text(T("settings.general.agent_apps.not_installed")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isBuiltIn {
                Toggle("", isOn: Binding(get: { AgentWindow.list(changes).contains(id) }, set: { set(id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel(AgentApps.name(id))
            } else {
                Button(T("settings.general.agent_apps.remove")) { set(id, false) }
            }
        }
        .padding(.vertical, 7)
    }

    private func set(_ id: String, _ on: Bool) {
        changes = AgentWindow.changing(changes, id, on: on)
        setRecordConfig("agent_apps", changes.isEmpty ? nil : changes)
        emit(["event": "agent_apps", "app": id, "on": on])
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = T("settings.general.agent_apps.add_prompt")
        let done: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK else { return }
            for u in panel.urls {
                if let id = Bundle(url: u)?.bundleIdentifier, id != Bundle.main.bundleIdentifier { set(id, true) }
            }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }
}
