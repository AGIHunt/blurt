// SwiftUI parts of a sessions pane: the list, the header above the terminal, the overlay for the states in which the
// terminal has nothing to show.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
protocol SessionActions: AnyObject {
    func openExternal(_ job: String, terminal: String?)
    func interrupt(_ job: String)
    func end(_ job: String)
    func review(_ job: String)
    func reconnect()
    func toggleSidebar()
    func popOut(_ job: String)
}

// MARK: - List

struct SessionsList: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    var select: (String) -> Void
    var newSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                // the terminal side tells the story; the list just says it's empty
                VStack(spacing: 4) {
                    Spacer()
                    Text(TL("list.empty.title")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(TL("list.empty.body")).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(get: { pane.job }, set: { if let j = $0 { select(j) } })) {
                    ForEach(model.groups) { g in
                        Section {
                            ForEach(g.rows) { r in AgentSessionRowView(row: r).tag(r.id) }
                        } header: {
                            Text(g.name).lineLimit(1)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack(spacing: 6) {
                Button(action: newSession) {
                    Label(TL("list.new"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help(TL("list.new.help"))
                Spacer()
                let live = model.alive.count
                if live > 0 {
                    Text(Loc.plural("list.live", table: "Terminal", count: live)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .frame(minWidth: 220)
    }
}

struct AgentSessionRowView: View {
    let row: AgentSessionRow

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            SessionStatusMark(status: row.status).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(shortAgo(row.since)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(row.alive ? row.status.title : (row.awaitsFinish ? TL("row.ready_to_review") : row.status.title))
                        .foregroundStyle(row.status == .waitingInput || row.status == .error ? row.status.color : Color.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(row.agentName).foregroundStyle(.secondary)
                    if row.agent.branch != nil {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.tertiary).accessibilityLabel(TL("header.worktree"))
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .opacity(row.alive || row.awaitsFinish ? 1 : 0.62)
        .accessibilityElement(children: .combine)
    }
}

/// "now", "4m", "2h", "3d" — compact, localized by the unit formatter.
func shortAgo(_ d: Date) -> String {
    let s = max(0, Date().timeIntervalSince(d))
    if s < 60 { return TL("time.now") }
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 1
    f.allowedUnits = s < 3600 ? [.minute] : s < 86400 ? [.hour] : [.day]
    var cal = Calendar.current
    cal.locale = Loc.locale
    f.calendar = cal
    return f.string(from: s) ?? ""
}

// MARK: - Header

struct SessionHeader: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    weak var actions: SessionActions?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { actions?.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless).help(TL(pane.listShown ? "header.hide_list" : "header.show_list"))
                    .accessibilityLabel(TL(pane.listShown ? "header.hide_list" : "header.show_list"))
                if let r = pane.job.flatMap({ model.row($0) }) {
                    SessionStatusMark(status: r.status, size: 11)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(r.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(r.projectName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Text(r.status.title).foregroundStyle(r.status == .running ? Color.secondary : r.status.color)
                            Text("·").foregroundStyle(.tertiary)
                            Text(r.agentName)
                            if let f = r.agent.finishAction, f != "keep" {
                                Text("·").foregroundStyle(.tertiary)
                                // "pr" without a pull request url = only pushed (no gh, or a host it doesn't know)
                                Text(TL(f == "pr" && r.agent.finishResult?["pr"] as? String == nil ? "finish.state.pushed" : "finish.state.\(f)"))
                            } else if let b = r.agent.branch {
                                Text("·").foregroundStyle(.tertiary)
                                Label(b, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    .help(TL("header.branch.help", b, r.agent.baseBranch ?? "HEAD"))
                            }
                            if r.isAppRunner {
                                Text("·").foregroundStyle(.tertiary)
                                Text(TL("header.app_runner")).foregroundStyle(Color.brandAttnInk).help(TL("header.app_runner.help"))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    trailing(r)
                } else {
                    Text(TL("header.none")).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 51)
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    func trailing(_ r: AgentSessionRow) -> some View {
        HStack(spacing: 8) {
            if r.awaitsFinish && !r.alive {
                Button(TL("header.review")) { actions?.review(r.id) }
                    .controlSize(.small)
                    .buttonStyle(.brand)
                    .help(TL("header.review.help"))
            }
            if r.alive && !r.isAppRunner {
                Menu {
                    ForEach(ExternalTerminals.installed, id: \.id) { t in
                        Button(t.name) { actions?.openExternal(r.id, terminal: t.id) }
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                } primaryAction: {
                    actions?.openExternal(r.id, terminal: ExternalTerminals.preferred)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .help(TL("header.open_external.help"))
                .accessibilityLabel(TL("header.open_external.help"))
            }
            Menu {
                if r.alive {
                    Button(TL("header.interrupt")) { actions?.interrupt(r.id) }
                    Button(TL("header.end")) { actions?.end(r.id) }
                    Divider()
                }
                if r.awaitsFinish && r.alive { Button(TL("header.review")) { actions?.review(r.id) } }
                Button(TL("header.pop_out")) { actions?.popOut(r.id) }
                if let wt = r.agent.worktree ?? Optional(r.agent.cwd) {
                    Button(TL("header.reveal_folder")) { NSWorkspace.shared.activateFileViewerSelecting([wt]) }
                }
                if let h = r.agent.handoff {
                    Button(TL("header.open_handoff")) {
                        NSWorkspace.shared.open(BlurtPaths.home.appendingPathComponent("handoff/\(h).md"))
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(TL("header.more"))
                .accessibilityLabel(TL("header.more"))
        }
    }
}

/// The user's terminal apps that open-external supports.
enum ExternalTerminals {
    struct App { let id: String; let name: String; let bundle: String }
    static let all = [App(id: "terminal", name: "Terminal", bundle: "com.apple.Terminal"),
                      App(id: "iterm", name: "iTerm", bundle: "com.googlecode.iterm2"),
                      App(id: "ghostty", name: "Ghostty", bundle: "com.mitchellh.ghostty"),
                      App(id: "wezterm", name: "WezTerm", bundle: "com.github.wez.wezterm"),
                      App(id: "kitty", name: "kitty", bundle: "net.kovidgoyal.kitty")]
    static var installed: [App] { all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } }
    /// config terminal.external, else the first installed in the order above after Terminal: people who installed
    /// another terminal use it.
    static var preferred: String {
        if let s = Config.shared["terminal.external"] as? String, !s.isEmpty { return s }
        return installed.first { $0.id != "terminal" }?.id ?? "terminal"
    }
}

// MARK: - Overlay

struct SessionOverlay: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    weak var actions: SessionActions?

    var body: some View {
        let row = pane.job.flatMap { model.row($0) }
        ZStack(alignment: .bottom) {
            switch pane.attach {
            case .attached:
                EmptyView()         // the pane hides this view while a terminal is attached
            case .connecting:
                card { ProgressView().controlSize(.small); Text(TL("overlay.connecting")).foregroundStyle(.secondary) }
                    .transition(.opacity)
            case .detached:
                card {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                    Text(TL("overlay.detached.title")).font(.headline)
                    Text(TL("overlay.detached.body")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(TL("overlay.reconnect")) { actions?.reconnect() }.keyboardShortcut(.defaultAction)
                }
            case .ended:
                card {
                    if let r = row { endedSummary(r) } else { Text(TL("overlay.ended.title")).font(.headline) }
                }
            case .elsewhere:
                card {
                    Text(TL("overlay.elsewhere.title")).font(.headline)
                    Text(TL("overlay.elsewhere.body")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .failed(let why):
                card {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(Color.brandAttn)
                    Text(why).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                    Button(TL("overlay.retry")) { actions?.reconnect() }
                }
            case .none:
                if !model.rows.isEmpty {
                    card { Text(TL("overlay.pick")).foregroundStyle(.secondary) }
                } else {
                    // first launch of the sessions window: the one empty state (§3.5)
                    EmptyStateContent(title: TL("overlay.empty.title"), message: TL("overlay.empty.body")) {
                        Button(TL("list.new")) { TerminalHost.shared.newSession(project: nil, items: []) }.buttonStyle(.brand)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: pane.attach)
    }

    func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 10) { c() }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    func endedSummary(_ r: AgentSessionRow) -> some View {
        SessionStatusMark(status: r.status, size: 14)
        Text(r.status == .error ? TL("overlay.ended.error", Int(r.agent.exit ?? -1)) : TL("overlay.ended.title")).font(.headline)
        if !r.items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(r.items.prefix(5), id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(i.id).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        Text(i.title).lineLimit(1)
                    }.font(.callout)
                }
            }
        }
        if r.awaitsFinish {
            Text(TL("overlay.ended.review_hint")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(TL("header.review")) { actions?.review(r.id) }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
        } else if let hint = Self.endedHint(r) {
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
    }

    /// What the session's items are waiting for now (an exit moves nothing; only the agent's report does): still in
    /// progress (it never reported back), to verify, or nothing at all when they are done.
    static func endedHint(_ r: AgentSessionRow) -> String? {
        let states = r.job.items.compactMap { IndexLookup.item(uid: $0)?.state }
        if states.contains(where: { $0 == "handed_off" || $0 == "in_progress" }) { return TL("overlay.ended.unreported_hint") }
        if states.contains("to_verify") { return TL("overlay.ended.verify_hint") }
        return nil
    }
}
