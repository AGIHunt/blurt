// Settings → Projects (Work): the folders opened in Blurt, managed like macOS's Login Items list.
//   Projects: a heading with Add Folder… at its right end, then one box, a project per row — its folder glyph in the
//   project's colour (ProjectLook, as in the main window's sidebar) in the page's icon gutter, its name, and under it its
//   folder, short ("~/…/proj/atlas-web"; the whole path, and the key its item IDs start with, in the tooltip). Nothing
//   is drawn on a row at rest: the pointer over it shows its ⋯ menu (Show in Finder, Send New Snaps Here, Remove from
//   Blurt — the same as its context menu); a click selects it (the brand tint, §3.3), a double-click shows it in the
//   Finder. Rename (the menus, or Return on the selected row) turns the name into a field in place: Return or a click
//   away keeps it, Esc puts it back; ⌘Z undoes it, as the main window's rename does. A folder that is gone says so
//   in attention ink. Unassigned's folder is in the heading's ⋯.
//   Snaps and voice notes: where new ones go — one pop-up row (a project, or Unassigned).
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

    /// A new name, at once, with ⌘Z on this window (the old name back) — the main window's rename, from here.
    func rename(_ p: Project, to raw: String, window: NSWindow?) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != p.name else { return }
        let old = p.name
        Task { @MainActor in
            do {
                try await ProjectStore.shared.update(p.id, ["name": name])
                error = nil
                emit(["event": "project_renamed", "id": p.id, "via": "settings"])
                if let um = window?.undoManager {
                    um.registerUndo(withTarget: self) { m in
                        Task { @MainActor in
                            do { try await ProjectStore.shared.update(p.id, ["name": old]) } catch { m.error = peopleText(error, context: "projects") }
                            m.reload()
                        }
                    }
                    um.setActionName(T("main.project.rename.undo_name"))
                }
            } catch { self.error = peopleText(error, context: "projects") }
            reload()
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
    /// the project whose name is a field now, and what is typed in it
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    func startRename(_ p: Project) {
        m.selected = p.id
        draft = p.name
        editing = p.id
        DispatchQueue.main.async { fieldFocused = true }
    }
    func commitRename(_ p: Project) {
        guard editing == p.id else { return }
        editing = nil
        m.rename(p, to: draft, window: NSApp.keyWindow)
    }

    var body: some View {
        SettingsPage(.projects) {
            SettingsGroup("projects.list", title: T("settings.projects.list_heading"), footer: T("settings.general.projects.hint"), content: {
                if m.projects.isEmpty {
                    SettingsLine { Text(T("settings.projects.empty")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary) }
                }
                ForEach(m.projects, id: \.id) { p in row(p) }
                // Return on the selected row renames it (Finder, the main window's sidebar)
                if editing == nil, let id = m.selected, let p = m.projects.first(where: { $0.id == id }) {
                    Button("") { startRename(p) }.keyboardShortcut(.return, modifiers: [])
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }, accessory: {
                HStack(spacing: 4) {
                    RowMenu(label: T("settings.projects.more"), visible: true) {
                        Button(T("settings.general.open_unassigned")) { m.revealUnassigned() }
                    }
                    Button(T("settings.projects.add")) { m.addFolder() }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                }
            })

            SettingsGroup("projects.capture", title: T("settings.projects.capture_heading")) {
                SettingRow("projects.capture_into", title: T("settings.projects.capture_row")) {
                    ChoicePopup(label: T("settings.general.capture_into"),
                                choices: m.projects.map { ($0.id, $0.name) } + [("inbox", T("project.inbox"))],
                                selection: Binding(get: { m.current }, set: { m.setCurrent($0) }),
                                dividers: m.projects.isEmpty ? [] : [m.projects.count])
                }
            }

            if let e = m.error {
                Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.boxInset).padding(.top, 8)
            }
        }
        .onAppear { m.reload() }
    }

    /// A project: its folder in its colour, its name, its folder's path short under it; its ⋯ only under the pointer.
    func row(_ p: Project) -> some View {
        let selected = m.selected == p.id
        let missing = !p.exists
        return SettingsLine(padding: 7) {
            HStack(spacing: 14) {
                HStack(spacing: SettingsMetrics.iconGap) {
                    Image(systemName: "folder.fill").font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: ProjectLook.color(p)).opacity(missing ? 0.4 : 1))
                        .frame(width: SettingsMetrics.iconSlot).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        if editing == p.id {
                            TextField(T("main.project.rename"), text: $draft)
                                .textFieldStyle(.roundedBorder).font(.system(size: SettingsMetrics.titleSize))
                                .focused($fieldFocused)
                                .onSubmit { commitRename(p) }
                                .onExitCommand { editing = nil }
                                .onChange(of: fieldFocused) { f in if !f { commitRename(p) } }      // a click away keeps it
                        } else {
                            Text(p.name).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(missing ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.tail)
                                .gridProbe(.iconText, p.name)
                        }
                        Text(missing ? T("settings.projects.missing") : ProjectsModel.shortPath(p.path)).font(.system(size: SettingsMetrics.detailSize))
                            .foregroundStyle(missing ? AnyShapeStyle(Color.brandAttnInk) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RowMenu(label: T("settings.projects.more"), visible: hovered == p.id || selected) { items(p) }
                    .gridProbe(.trailing, p.name)
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
        .contextMenu { items(p) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A project's actions: its ⋯ menu and its context menu alike.
    @ViewBuilder func items(_ p: Project) -> some View {
        Button(T("action.reveal_in_finder")) { m.reveal(p) }.disabled(!p.exists)
        Button(T("main.project.rename")) { startRename(p) }
        Button(T("settings.projects.make_current")) { m.setCurrent(p.id) }.disabled(m.current == p.id)
        Divider()
        Button(T("main.project.remove")) { m.remove(p, window: NSApp.keyWindow) }
    }
}
