// SwiftUI parts of a sessions pane: the list, the header above the terminal, the overlay for the states in which the
// terminal has nothing to show — above all the card a session ends on: how it ended in words (SessionOutcome), what
// the agent said last when it failed, and the one next step (Review Changes…, Restart Session), with Take Back and
// Show Output beside it. A dead window is never the first thing shown; Show Output opens it. A session in the agent's
// desktop app shows its desktop card instead of a terminal: it isn't live here, progress comes from the agent.
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
    /// the same items, agent and model in a fresh session (SessionRecovery.restart)
    func restart(_ job: String)
    /// its items back to To Do
    func takeBack(_ job: String)
    /// the ended session's terminal, as the agent left it
    func showOutput(_ job: String)
    /// the agent's desktop app comes forward (Go to Claude)
    func goToDesktop(_ job: String)
    /// a terminal session moves to the agent's desktop app (asks first)
    func continueDesktop(_ job: String)
}

// MARK: - List

struct SessionsList: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    var select: (String) -> Void
    var newSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // no sessions: the list column steps aside (SessionsPaneController) and the detail's empty state is the
            // one story; nothing is said here
            if model.rows.isEmpty {
                Spacer()
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
            // the live count only (New Session is the header's compose button): a footer while there is one to show
            let live = Job.runningHere(model.alive.map(\.job))  // a desktop one runs elsewhere
            if live > 0 {
                Divider()
                Text(Loc.plural("list.live", table: "Terminal", count: live)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
            }
        }
        .frame(minWidth: 220)
        // one surface under the list and its count: the sidebar material, as the list draws it
        .background(SidebarMaterial())
    }
}

/// The source-list material behind the whole sessions column (the count under the list included).
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct AgentSessionRowView: View {
    let row: AgentSessionRow

    var body: some View {
        let outcome = row.outcome
        let needsYou: Bool = { if case .failed = outcome { return true }; return row.status == .waitingInput }()
        HStack(alignment: .top, spacing: 9) {
            SessionStatusMark(status: row.status, elsewhere: row.inDesktop).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    // when it started, in the item list's words ("2 min. ago", "2分钟前")
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Loc.relative(row.since)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(row.stateText).foregroundStyle(needsYou ? row.status.color : Color.secondary)
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
        .opacity(row.alive || row.awaitsFinish || needsYou ? 1 : 0.62)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header

struct SessionHeader: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    weak var actions: SessionActions?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !model.rows.isEmpty {
                    Button { actions?.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).help(TL(pane.listShown ? "header.hide_list" : "header.show_list"))
                        .accessibilityLabel(TL(pane.listShown ? "header.hide_list" : "header.show_list"))
                }
                // New Session sits with the window's chrome (Mail's, Notes' compose button), not in a footer bar
                Button { TerminalHost.shared.newSession(project: nil, items: []) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help(TL("list.new.help"))
                    .accessibilityLabel(TL("list.new"))
                if let r = pane.job.flatMap({ model.row($0) }) {
                    SessionStatusMark(status: r.status, size: 11, elsewhere: r.inDesktop)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(r.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(r.projectName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            // the user's own decision (merged, restarted…) is past news: no status colour
                            // a desktop session's card says where it is: not again here
                            if !r.inDesktop {
                                Text(r.stateText).foregroundStyle(r.status == .running || r.agent.finishAction != nil ? Color.secondary : r.status.color)
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text(r.agentName)
                            if r.agent.finishAction == nil, let b = r.agent.branch {
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
                    Spacer(minLength: 8)
                    trailing(r).layoutPriority(1)       // the actions keep their size; the title truncates
                } else {
                    // "No session selected" only where there are sessions to select
                    if !model.rows.isEmpty { Text(TL("header.none")).font(.system(size: 13)).foregroundStyle(.secondary) }
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.leading, pane.headerLead)
            .frame(height: 51)
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    func trailing(_ r: AgentSessionRow) -> some View {
        HStack(spacing: 8) {
            // the ended card has the primary Review Changes…; while its output is shown instead, a plain one here
            if r.awaitsFinish && !r.alive && pane.attach == .attached {
                Button(TL("header.review")) { actions?.review(r.id) }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    .help(TL("header.review.help"))
            }
            if r.alive && !r.isAppRunner && !r.agent.isDesktop {
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
                    // the desktop card has Go to Claude as its primary; the menu has it too
                    if r.agent.isDesktop { Button(TL("header.go_desktop", DesktopApp.name(r.agent.agent))) { actions?.goToDesktop(r.id) } }
                    else { Button(TL("header.interrupt")) { actions?.interrupt(r.id) } }
                    Button(TL(r.agent.isDesktop ? "header.end_desktop" : "header.end")) { actions?.end(r.id) }
                    if DesktopContinue.offered(r.agent, alive: r.alive, supported: DesktopApp.supports(r.agent.agent),
                                               check: DesktopApp.continueCheck(r.agent.agent) { model.objectWillChange.send() }) {
                        Button(TL("header.continue_desktop", DesktopApp.name(r.agent.agent))) { actions?.continueDesktop(r.id) }
                    }
                    // no response for a minute (the watchdog): start it again from here
                    if r.agent.stalled { Button(TL("overlay.restart")) { actions?.restart(r.id) } }
                    Divider()
                } else if pane.attach != .attached, r.hasOutput {
                    Button(TL("overlay.show_output")) { actions?.showOutput(r.id) }
                    Divider()
                }
                if r.awaitsFinish && r.alive { Button(TL("header.review")) { actions?.review(r.id) } }
                if !r.job.items.isEmpty, let first = r.job.items.first {
                    Button(TL("header.show_items")) { AppEnvironment.mainWindow?.reveal(uid: first) }
                }
                Button(TL("header.pop_out")) { actions?.popOut(r.id) }
                if let wt = r.agent.worktree ?? Optional(r.agent.cwd) {
                    Button(TL("header.reveal_folder")) { NSWorkspace.shared.activateFileViewerSelecting([wt]) }
                }
                if let h = r.agent.handoff {
                    Button(TL("header.open_handoff")) {
                        NSWorkspace.shared.open(BlurtPaths.home.appendingPathComponent("handoff/\(h).md"))
                    }
                }
                if FileManager.default.fileExists(atPath: JobFiles.log(r.id).path) {
                    Button(TL("header.show_log")) { NSWorkspace.shared.open(JobFiles.log(r.id)) }
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
    @ObservedObject var recovering = SessionRecovery.busy
    weak var actions: SessionActions?

    var body: some View {
        let row = pane.job.flatMap { model.row($0) }
        ZStack(alignment: .bottom) {
            switch pane.attach {
            case .attached:
                EmptyView()         // the pane hides this view while a terminal is attached
            case .connecting:
                card { BrandSpinnerView(); Text(TL("overlay.connecting")).foregroundStyle(.secondary) }
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
            case .desktop:
                card {
                    if let r = row { desktopCard(r) }
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
                    // first launch of the sessions window: the one empty state (§3.5), its middle at about 40 % of the
                    // pane (the space above two thirds of the space below)
                    GeometryReader { g in
                        EmptyStateContent(title: TL("overlay.empty.title"), message: TL("overlay.empty.body")) {
                            Button(TL("list.new")) { TerminalHost.shared.newSession(project: nil, items: []) }.buttonStyle(.brand)
                        }
                        .padding(.bottom, g.size.height * 0.2)
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
        let outcome = r.outcome
        SessionStatusMark(status: r.status, size: 14, elsewhere: r.inDesktop)
        Text(Self.endedTitle(r)).font(.headline).multilineTextAlignment(.center)
        if case .failed = outcome, let why = JobLook.errorText(r.job), !r.agent.lastOutput.contains(why) {
            Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .failed = outcome, !r.agent.lastOutput.isEmpty { lastOutput(r.agent.lastOutput) }
        if !r.items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(r.items.prefix(5), id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(i.id).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Text(i.title).lineLimit(1)
                    }.font(.callout)
                }
            }
        }
        if let hint = Self.endedHint(r) {
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
        }
        let output = r.hasOutput
        let inFlight = recovering.contains(r.id)     // a Restart / Take Back already on its way: not twice
        HStack(spacing: 8) {
            switch outcome {
            case .review:
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
                Button(TL("header.review")) { actions?.review(r.id) }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
            case .failed, .noChanges, .ended:
                if Self.itemsWithIt(r) { Button(TL("overlay.take_back")) { actions?.takeBack(r.id) }.disabled(inFlight) }
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
                if Self.itemsWithIt(r) {
                    if case .failed = outcome {
                        Button(TL("overlay.restart")) { actions?.restart(r.id) }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
                            .disabled(inFlight)
                    } else {
                        Button(TL("overlay.restart")) { actions?.restart(r.id) }.disabled(inFlight)
                    }
                }
                if inFlight { BrandSpinnerView() }
            case .finished, .live:
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
            }
        }
        .padding(.top, 4)
    }

    /// A session in the agent's desktop app: nothing live here. Its items, what moves them (the agent's reports), and
    /// the way there; its worktree's changes can be reviewed and merged as usual.
    @ViewBuilder
    func desktopCard(_ r: AgentSessionRow) -> some View {
        let app = DesktopApp.name(r.agent.agent)
        Image(systemName: "macwindow").font(.system(size: 22, weight: .light)).foregroundStyle(Color.brandInk)
        Text(TL("overlay.desktop.title", app)).font(.headline)
        // without the blurt MCP there nothing reports: the user marks the items (the same words as the hand-off sheet)
        Text(TL(r.agent.desktopNeedsMarking ? "overlay.desktop.body_nomcp"
                : r.agent.continuedFrom != nil ? "overlay.desktop.body_continued" : "overlay.desktop.body", app))
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
        if !r.items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(r.items.prefix(5), id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(i.id).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Text(i.title).lineLimit(1)
                    }.font(.callout)
                }
            }
        }
        HStack(spacing: 8) {
            if r.agent.worktree != nil { Button(TL("header.review")) { actions?.review(r.id) } }
            Button(TL("header.go_desktop", app)) { actions?.goToDesktop(r.id) }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    /// What the agent said last, as it left its window: the reason in its own words.
    func lastOutput(_ lines: [String]) -> some View {
        ScrollView {
            Text(lines.suffix(8).joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(maxWidth: 460, maxHeight: 140)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// "Codex couldn’t start", "Session ended · no changes", "Merged"…
    static func endedTitle(_ r: AgentSessionRow) -> String {
        switch r.outcome {
        case .failed(let atStart): return TL(atStart ? "overlay.failed_start.title" : "overlay.failed.title", r.agentName)
        case .review: return TL("overlay.review.title")
        case .noChanges: return TL("overlay.no_changes.title")
        case .ended, .live: return TL("overlay.ended.title")
        case .finished: return r.stateText
        }
    }

    /// Some of its items are still with this session (handed off or in progress): Take Back and Restart apply.
    static func itemsWithIt(_ r: AgentSessionRow) -> Bool {
        r.job.items.contains { uid in IndexLookup.item(uid: uid).map { ["handed_off", "in_progress"].contains($0.state) } ?? true }
    }

    /// What the session's items are waiting for now (an exit moves nothing; only the agent's report does): the
    /// review, still in progress (it never reported back), to verify, or nothing at all when they are done.
    static func endedHint(_ r: AgentSessionRow) -> String? {
        if r.outcome == .review { return TL("overlay.ended.review_hint") }
        if case .failed = r.outcome { return nil }
        // restarted, merged, discarded…: its items went on elsewhere (a new session, To Do) — nothing to say here
        if case .finished(let f) = r.outcome, f != "keep" { return nil }
        let states = r.job.items.compactMap { IndexLookup.item(uid: $0)?.state }
        if states.contains(where: { $0 == "handed_off" || $0 == "in_progress" }) { return TL("overlay.ended.unreported_hint") }
        if states.contains("to_verify") { return TL("overlay.ended.verify_hint") }
        return nil
    }
}
