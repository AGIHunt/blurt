// Settings → Agents → Dragging Cards → Edit…: which apps are agents that get the picture's path and the note
// (BlurtCore AgentWindow / AgentDropList, v1.0.26: one list with the agents). Every agents.json entry with a `drop`
// for macOS, each with a switch (record.agent_drop.<id> = false: off), and the apps the user added (a record.agent_defs
// entry of their own: a card-drag target only), each with Remove; Add App… picks any app from /Applications. The
// first change moves v1.0.21's record.agent_apps to these keys (AgentDropList.migrate). A list, not rules on app names:
// a name doesn't say whether an app reads this Mac's files (Kimi / Kimi Code, 豆包 / 豆包工作).
import AppKit
import SwiftUI
import BlurtCore

/// An app's icon and its installed name, by bundle id; and the note for the apps that are agents only in some windows.
enum AgentApps {
    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    static func url(_ a: DropAgent) -> URL? { a.ids.lazy.compactMap(url).first }

    static func icon(_ a: DropAgent) -> NSImage? { url(a).map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// "Only in Codex mode" / "Only in the Code tab"
    static func note(_ a: DropAgent) -> String? {
        if a.ids.contains(AgentWindow.codex) { return T("settings.general.agent_apps.codex_note") }
        if a.ids.contains(AgentWindow.claude) { return T("settings.general.agent_apps.claude_note") }
        return nil
    }

    /// The list as it stands (registry + config).
    static func targets() -> [DropAgent] {
        AgentDropList.targets(registry: AgentDropList.loadRegistry() ?? [], record: recordConfig())
    }

    /// The first change: v1.0.21's record.agent_apps moved to record.agent_drop / record.agent_defs.
    static func migrateIfNeeded() {
        guard let patch = AgentDropList.migrate(registry: AgentDropList.loadRegistry() ?? [], record: recordConfig()) else { return }
        for (k, v) in patch { setRecordConfig(k, v is NSNull ? nil : v) }
        emit(["event": "agent_apps_migrated"])
    }

    static func setOn(_ agent: String, _ on: Bool) {
        migrateIfNeeded()
        var off = recordConfig()["agent_drop"] as? [String: Any] ?? [:]
        off[agent] = on ? nil : false
        setRecordConfig("agent_drop", off.isEmpty ? nil : off)
        emit(["event": "agent_drop", "agent": agent, "on": on])
    }

    static func remove(_ agent: String) {
        migrateIfNeeded()
        var defs = recordConfig()["agent_defs"] as? [String: Any] ?? [:]
        defs[agent] = nil
        setRecordConfig("agent_defs", defs.isEmpty ? nil : defs)
        emit(["event": "agent_drop_removed", "agent": agent])
    }

    static func add(bundleID: String, name: String) {
        migrateIfNeeded()
        let all = AgentDropList.definitions(registry: AgentDropList.loadRegistry() ?? [], record: recordConfig())
        if let d = all.first(where: { AgentDropList.appIDs($0).contains(bundleID) }), let id = d["id"] as? String {
            setOn(id, true)     // already listed (a built-in): switched on rather than added twice
            return
        }
        var defs = recordConfig()["agent_defs"] as? [String: Any] ?? [:]
        let id = AgentDropList.customID(name, taken: Set(all.compactMap { $0["id"] as? String }))
        defs[id] = AgentDropList.customDef(name: name, bundleID: bundleID)
        setRecordConfig("agent_defs", defs)
        emit(["event": "agent_drop_added", "agent": id, "app": bundleID])
    }
}

struct AgentAppsSheet: View {
    var close: () -> Void
    @State private var rows = AgentApps.targets()

    /// the user's own first, then the built-in ones (installed first, then by name)
    private var ordered: [DropAgent] {
        let builtIn = rows.filter { !$0.custom }.sorted { a, b in
            let ia = AgentApps.url(a) != nil, ib = AgentApps.url(b) != nil
            return ia != ib ? ia : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let mine = rows.filter(\.custom).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return mine + builtIn
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
                    ForEach(ordered) { a in
                        row(a)
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

    @ViewBuilder private func row(_ a: DropAgent) -> some View {
        let installed = AgentApps.url(a) != nil
        HStack(spacing: 10) {
            Group {
                if let i = AgentApps.icon(a) { Image(nsImage: i).resizable() } else { Image(systemName: "app.dashed").resizable() }
            }
            .frame(width: 22, height: 22).opacity(installed ? 1 : 0.4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).foregroundStyle(installed ? .primary : .secondary)
                if let n = AgentApps.note(a) {
                    Text(n).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                } else if !installed {
                    Text(T("settings.general.agent_apps.not_installed")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if a.custom {
                Button(T("settings.general.agent_apps.remove")) { AgentApps.remove(a.agent); reload() }
            } else {
                Toggle("", isOn: Binding(get: { a.on }, set: { AgentApps.setOn(a.agent, $0); reload() }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel(a.name)
            }
        }
        .padding(.vertical, 7)
    }

    private func reload() {
        rows = AgentApps.targets()
        NotificationCenter.default.post(name: AgentApps.changed, object: nil)
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
                guard let id = Bundle(url: u)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                let name = (FileManager.default.displayName(atPath: u.path) as NSString).deletingPathExtension
                AgentApps.add(bundleID: id, name: name)
            }
            reload()
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }
}

extension AgentApps {
    /// the list was edited (the pane's one line names the apps that are on)
    static let changed = Notification.Name("dev.blurt.agent-apps-changed")
}
