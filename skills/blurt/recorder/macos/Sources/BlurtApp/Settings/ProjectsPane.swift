// Settings → Projects (Work): the folders opened in Blurt, managed like macOS's Login Items list.
//   Where new snaps and voice notes go: one pop-up row (a project, or Unassigned).
//   The list: one box, a project per row — its name, and under it its folder, short ("~/…/proj/atlas-web"; the whole
//   path, and the key its item IDs start with, in the tooltip). Nothing is drawn on a row at rest: the pointer over
//   it shows Show in Finder; a click selects it (the brand tint, §3.3), a double-click shows it in the Finder; its
//   context menu has Show in Finder, Send New Snaps Here and Remove from Blurt. A folder that is gone says so in
//   attention ink. Under the rows, inside the box, the list bar: + (Add Project Folder…, a sheet on this window),
//   − (removes the selected one), and ··· (Show in Finder, Show Unassigned in Finder).
//   Removing is at once — the folder and its items stay — with Undo (the island's button and ⌘Z on this window, like
//   the main window's Remove). Projects are in the sidebar's order (the user's own). Errors are said in a sentence;
//   what the script said goes to the log.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class ProjectsModel: ObservableObject {
    /// the pane's model while it is made (tests: `projectsselect N` selects a row for a screenshot)
    static weak var shown: ProjectsModel?
    @Published var projects: [Project] = []
    /// the current project's id, or "inbox": none — captures go to Unassigned
    @Published var current: String = "inbox"
    @Published var selected: String?
    @Published var error: String?

    init() {
        reload()
        Self.shown = self
    }

    func reload() {
        let s = ProjectStore.shared
        s.reload()
        projects = s.ordered
        current = s.currentID ?? "inbox"
        if let id = selected, !projects.contains(where: { $0.id == id }) { selected = nil }
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await f(); error = nil } catch { self.error = peopleText(error, context: "projects") }
            reload()
        }
    }

    func setCurrent(_ id: String) {
        run {
            try await ProjectStore.shared.use(id == "inbox" ? nil : id)
            await MainActor.run { island.projectChanged() }
        }
    }

    /// Removed at once (the folder and its items stay), with Undo — the island's button and ⌘Z on this window put it
    /// back exactly (its key, name, settings and place), as the main window's Remove does.
    func remove(_ p: Project, window: NSWindow?) {
        Task { @MainActor in
            do {
                let removed = try await ProjectStore.shared.remove(p.id)
                error = nil
                if selected == p.id { selected = nil }
                reload()
                guard !removed.isEmpty else { return }
                emit(["event": "project_removed", "id": p.id, "via": "settings"])
                var undone = false
                let undo: () -> Void = { [weak self] in
                    guard !undone else { return }
                    undone = true
                    Task { @MainActor in
                        do { try await ProjectStore.shared.restore(removed) } catch { self?.error = peopleText(error, context: "projects") }
                        emit(["event": "project_restored", "id": p.id, "via": "settings"])
                        self?.reload()
                    }
                }
                if let um = window?.undoManager {
                    um.registerUndo(withTarget: self) { _ in undo() }
                    um.setActionName(T("main.project.remove.undo_name"))
                }
                appDelegate?.toast(T("main.project.removed", p.name), undo: undo)
            } catch {
                self.error = peopleText(error, context: "projects")
                reload()
            }
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.open.message")
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            let urls = panel.urls
            self?.run { for u in urls { _ = try await ProjectStore.shared.open(folder: u) } }
        }
        // a sheet on the Settings window, not an app-wide modal panel
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: open) } else { open(panel.runModal()) }
    }

    func reveal(_ p: Project) { NSWorkspace.shared.activateFileViewerSelecting([p.path]) }
    func revealUnassigned() { NSWorkspace.shared.open(ProjectStore.shared.inbox.store) }

    /// "~/…/proj/atlas-web": the home as ~, and past the first part only the last two folders (a long path would
    /// outweigh the name; the whole one is in the tooltip).
    static func shortPath(_ u: URL) -> String {
        let t = (u.path as NSString).abbreviatingWithTildeInPath
        let parts = t.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let home = t.hasPrefix("~")
        let shown = home ? parts.dropFirst() : parts[...]
        guard shown.count > 3 else { return t }
        return (home ? "~/…/" : "/…/") + shown.suffix(2).joined(separator: "/")
    }
}

struct ProjectsPane: View {
    @StateObject var m = ProjectsModel()
    @State private var hovered: String?

    var body: some View {
        SettingsPage(.projects) {
            SettingsGroup {
                SettingRow("projects.capture_into") {
                    RowPicker(label: T("settings.general.capture_into"), selection: Binding(get: { m.current }, set: { m.setCurrent($0) }),
                              width: SettingsMetrics.controlWidth) {
                        ForEach(m.projects, id: \.id) { p in Text(p.name).tag(p.id) }
                        Divider()
                        Text(T("project.inbox")).tag("inbox")
                    }
                }
            }

            SettingsGroup("projects.list", footer: T("settings.general.projects.hint")) {
                if m.projects.isEmpty {
                    SettingsLine { Text(T("settings.projects.empty")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary) }
                }
                ForEach(m.projects, id: \.id) { p in row(p) }
                listBar
            }

            if let e = m.error {
                Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.boxInset).padding(.top, 8)
            }
        }
        .onAppear { m.reload() }
    }

    /// A project: its name, its folder short under it; Show in Finder only under the pointer.
    func row(_ p: Project) -> some View {
        let selected = m.selected == p.id
        let missing = !p.exists
        return SettingsLine(padding: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(missing ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(ProjectsModel.shortPath(p.path)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if missing {
                    Text(T("settings.projects.missing")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandAttnInk)
                } else {
                    Button { m.reveal(p) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless)
                        .help(T("action.reveal_in_finder"))
                        .accessibilityLabel(T("action.reveal_in_finder"))
                        .opacity(hovered == p.id || selected ? 1 : 0)
                }
            }
        }
        .background(
            Rectangle().fill(selected ? Color.brandTint : Color.clear)
                .padding(.horizontal, -SettingsMetrics.boxInset)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = p.id } else if hovered == p.id { hovered = nil }
        }
        .gesture(TapGesture(count: 2).onEnded { if !missing { m.reveal(p) } })
        .simultaneousGesture(TapGesture().onEnded { m.selected = p.id })
        .help([p.path.path, T("settings.projects.key_help", p.key)].joined(separator: "\n"))
        .contextMenu {
            Button(T("action.reveal_in_finder")) { m.reveal(p) }.disabled(missing)
            Button(T("settings.projects.make_current")) { m.setCurrent(p.id) }.disabled(m.current == p.id)
            Divider()
            Button(T("main.project.remove")) { m.remove(p, window: NSApp.keyWindow) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The list's own bar, inside its box: + − on the left, ··· on the right (macOS's list-bar convention).
    var listBar: some View {
        let sel = m.projects.first { $0.id == m.selected }
        return SettingsLine(padding: 3) {
            HStack(spacing: 2) {
                barButton("plus", T("settings.projects.add")) { m.addFolder() }
                barButton("minus", T("main.project.remove")) { if let p = sel { m.remove(p, window: NSApp.keyWindow) } }
                    .disabled(sel == nil)
                Spacer()
                Menu {
                    Button(T("action.reveal_in_finder")) { if let p = sel { m.reveal(p) } }.disabled(sel == nil || sel?.exists == false)
                    Button(T("settings.general.open_unassigned")) { m.revealUnassigned() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(T("settings.projects.more"))
                .accessibilityLabel(T("settings.projects.more"))
            }
            .padding(.horizontal, -6)
        }
    }

    private func barButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
