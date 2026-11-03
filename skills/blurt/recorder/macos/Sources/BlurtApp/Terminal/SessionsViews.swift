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
    /// out of the list for good (its folder was gone and nothing is left with it)
    func remove(_ job: String)
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
    var toggle: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // the column's own strip of the title bar (Mail's, Notes'): hide the list and compose, clear of the
            // traffic lights, at the header's height
            HStack(spacing: 4) {
                Spacer()
                SessionsChromeButtons(listShown: true, toggle: toggle, newSession: newSession)
            }
            .padding(.trailing, 10)
            .frame(height: SessionHeader.height)
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
            // what the rows show, counted by the same marks: "1 working · 1 waiting on you"
            if let c = countText {
                Divider()
                Text(c).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
            }
        }
        .frame(minWidth: 220)
        // one surface under the list and its count: the sidebar material, as the list draws it
        .background(SidebarMaterial().ignoresSafeArea())
    }

    var countText: String? {
        let working = model.rows.filter { $0.mark == .working }.count
        let waiting = model.rows.filter { $0.mark == .waiting }.count
        let parts = [working > 0 ? TL("list.count.working", working) : nil, waiting > 0 ? TL("list.count.waiting", waiting) : nil]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Show / hide the list and New Session: in the list's own title-bar strip while it shows, at the header's leading
/// edge while it is hidden — never both.
struct SessionsChromeButtons: View {
    var listShown: Bool
    var toggle: () -> Void
    var newSession: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) { Image(systemName: "sidebar.left").frame(width: 24, height: 22) }
                .buttonStyle(.borderless).help(TL(listShown ? "header.hide_list" : "header.show_list"))
                .accessibilityLabel(TL(listShown ? "header.hide_list" : "header.show_list"))
            // New Session sits with the window's chrome (Mail's, Notes' compose button), not in a footer bar
            Button(action: newSession) { Image(systemName: "square.and.pencil").frame(width: 24, height: 22) }
                .buttonStyle(.borderless).help(TL("list.new.help"))
                .accessibilityLabel(TL("list.new"))
        }
        .foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: 9) {
            SessionStatusMark(mark: row.mark).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    // when it started, in the item list's words ("2 min. ago", "2分钟前")
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Loc.relative(row.since)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                // the first item's title, never cut: a long one wraps to a second line; the rest as "+1"
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text(row.stateText).foregroundStyle(row.stateColor)
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
        .opacity(row.alive || row.needsYou ? 1 : 0.62)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header

/// Above the terminal: the session's mark and title, its state on the line under it, and on the right one stable set
/// in every state — the Open in Terminal split button (its menu: the other terminal apps) and ⋯. Show / hide the list
/// and New Session are the list's own (its title-bar strip) while it shows. With no sessions at all there is no header:
/// the empty state is the whole window.
struct SessionHeader: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState
    weak var actions: SessionActions?

    static let height: CGFloat = 52

    var body: some View {
        if model.rows.isEmpty {
            Color(nsColor: .windowBackgroundColor)      // one ground with the empty state under it: no title-bar band
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // embedded in the main window, its own list is the In Progress place: no second sidebar toggle
                    // or compose button next to the item's key
                    if !pane.listShown && !pane.embedded {
                        SessionsChromeButtons(listShown: false, toggle: { actions?.toggleSidebar() },
                                              newSession: { TerminalHost.shared.newSession(project: nil, items: []) })
                            .padding(.trailing, 4)
                    }
                    if let r = pane.job.flatMap({ model.row($0) }) {
                        SessionStatusMark(mark: r.mark, size: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(r.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(r.projectName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            HStack(spacing: 5) {
                                // a desktop session's card says where it is: not again here
                                if !r.inDesktop {
                                    Text(r.stateText).foregroundStyle(r.stateColor)
                                    Text("·").foregroundStyle(.tertiary)
                                }
                                Text(r.agentName)
                                if r.agent.finishAction == nil, let b = r.agent.branch {
                                    Text("·").foregroundStyle(.tertiary)
                                    // the words of the branch (blurt/ and the item's key are said elsewhere), cut at
                                    // the end; the whole name in the tooltip
                                    Label(Self.branchWords(b, items: r.items.map(\.id)), systemImage: "arrow.triangle.branch")
                                        .labelStyle(.titleAndIcon)
                                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
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
                        Text(TL("header.none")).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.leading, pane.headerLead)
                .frame(height: Self.height - 1)
                Divider()
            }
            .background(.bar)
        }
    }

    /// "blurt/aw-12-create-hello" → "create-hello": without the blurt/ prefix and the item key it repeats; the name as
    /// it is when nothing would be left.
    static func branchWords(_ b: String, items: [String]) -> String {
        var s = Substring(b)
        if s.hasPrefix("blurt/") { s = s.dropFirst(6) }
        for id in items where !id.isEmpty {
            let k = id.lowercased()
            if s.lowercased().hasPrefix(k + "-") { s = s.dropFirst(k.count + 1); break }
        }
        return s.isEmpty ? b : String(s)
    }

    @ViewBuilder
    func trailing(_ r: AgentSessionRow) -> some View {
        let live = r.alive && !r.isAppRunner && !r.agent.isDesktop
        let preferred = ExternalTerminals.installed.first { $0.id == ExternalTerminals.preferred }?.name ?? "Terminal"
        HStack(spacing: 8) {
            // the ended card has the primary Review Changes…; while its output is shown instead, a plain one here
            if r.awaitsFinish && !r.alive && pane.attach == .attached {
                Button(TL("header.review")) { actions?.review(r.id) }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    .help(TL("header.review.help"))
            }
            // one control, split: the click opens it in the preferred terminal app, the arrow lists the others. Only
            // while there is a live window to open: an ended session has nothing there (not a greyed-out button)
            if live {
                Menu {
                    ForEach(ExternalTerminals.installed, id: \.id) { t in
                        Button(t.name) { actions?.openExternal(r.id, terminal: t.id) }
                    }
                } label: {
                    Text(TL("header.open_in", preferred))
                } primaryAction: {
                    actions?.openExternal(r.id, terminal: ExternalTerminals.preferred)
                }
                .menuStyle(.button).controlSize(.small).fixedSize()
                .help(TL("header.open_external.help"))
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

/// One plain line under the header while the agent waits at a startup question its terminal shows (sessions.py
/// agent.waiting_hint): what the question is and what to answer. Nothing otherwise (no height).
struct SessionHintBar: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var pane: PaneState

    var body: some View {
        if let r = pane.job.flatMap({ model.row($0) }), let h = r.job.waitingHint, Self.known.contains(h) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(TL("hint.\(h)", r.agentName)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(TL("hint.\(h)", r.agentName))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    static let known: Set<String> = ["trust", "hooks"]
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
                            // the flow's one primary style: the native default in the sheet accent, as the panel it opens
                            Button(TL("list.new")) { TerminalHost.shared.newSession(project: nil, items: []) }
                                .panelDefault().controlSize(.large).keyboardShortcut(.defaultAction)
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

    /// The ended card: its mark in the state's colour at 24 pt, how it ended as a sentence ("Ready to review"), the
    /// items under it as the list draws them, one line on what waits, and the one next step as the native default (the
    /// sheet it opens has the same). Its folder gone: says so, and offers Take Back Items (or Remove Session) instead of
    /// a review that would fail.
    @ViewBuilder
    func endedSummary(_ r: AgentSessionRow) -> some View {
        let outcome = r.outcome
        SessionStatusMark(mark: r.mark, size: 24).padding(.bottom, 2)
        Text(Self.endedTitle(r)).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
        if !r.items.isEmpty { itemLines(r) }
        if case .failed = outcome, let why = JobLook.errorText(r.job), !r.agent.lastOutput.contains(why) {
            Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .failed = outcome, !r.agent.lastOutput.isEmpty { lastOutput(r.agent.lastOutput) }
        // too old to start here: the update command, copyable (Restart checks the version before anything starts)
        if case .failed = outcome, let fix = (r.job.raw["error"] as? [String: Any])?["fix"] as? String, !fix.isEmpty {
            CommandText(text: fix)
        }
        if let hint = Self.endedHint(r) {
            Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
        }
        let output = r.hasOutput
        let inFlight = recovering.contains(r.id)     // a Restart / Take Back already on its way: not twice
        HStack(spacing: 8) {
            if r.folderGone {
                if Self.itemsWithIt(r) {
                    Button(TL("overlay.gone.take_back")) { actions?.takeBack(r.id) }
                        .panelDefault().keyboardShortcut(.defaultAction).disabled(inFlight)
                } else {
                    Button(TL("overlay.gone.remove")) { actions?.remove(r.id) }
                        .panelDefault().keyboardShortcut(.defaultAction)
                }
            } else {
            switch outcome {
            case .review:
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
                Button(TL("header.review")) { actions?.review(r.id) }.panelDefault().keyboardShortcut(.defaultAction)
            case .failed, .noChanges, .ended:
                if Self.itemsWithIt(r) { Button(TL("overlay.take_back")) { actions?.takeBack(r.id) }.disabled(inFlight) }
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
                if Self.itemsWithIt(r) {
                    if case .failed = outcome {
                        Button(TL("overlay.restart")) { actions?.restart(r.id) }.panelDefault().keyboardShortcut(.defaultAction)
                            .disabled(inFlight)
                    } else {
                        Button(TL("overlay.restart")) { actions?.restart(r.id) }.disabled(inFlight)
                    }
                }
                if inFlight { BrandSpinnerView() }
            case .finished(let f) where ["merge", "pr"].contains(f) && !Self.toVerify(r).isEmpty:
                // merged: the next step is checking the work — show it, or mark the one item done from here
                let waiting = Self.toVerify(r)
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
                if waiting.count == 1 {
                    Button(StateMenu.title("done")) { Self.markDone(waiting) }
                    Button(TL("finish.show_item", Self.itemID(waiting[0], r))) { AppEnvironment.mainWindow?.reveal(uid: waiting[0]) }
                        .panelDefault().keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("finish.show_items")) { AppEnvironment.mainWindow?.reveal(uid: waiting[0]) }
                        .panelDefault().keyboardShortcut(.defaultAction)
                }
            case .finished, .live:
                if output { Button(TL("overlay.show_output")) { actions?.showOutput(r.id) } }
            }
            }
        }
        .controlSize(.large)
        .padding(.top, 6)
    }

    /// A session's items as the list draws them: kind icon, id in tabular secondary, title (five at most).
    func itemLines(_ r: AgentSessionRow) -> some View {
        let kinds = r.job.items.map { IndexLookup.item(uid: $0)?.kind ?? "issue" }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(r.items.prefix(5).enumerated()), id: \.offset) { n, i in
                HStack(spacing: 8) {
                    Image(nsImage: Look.kindImage(kinds.indices.contains(n) ? kinds[n] : "issue", size: KindStyle.smallSize))
                    Text(i.id).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Text(i.title).font(.system(size: 13)).lineLimit(1)
                }
            }
        }
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
        if !r.items.isEmpty { itemLines(r) }
        HStack(spacing: 8) {
            if r.agent.worktree != nil { Button(TL("header.review")) { actions?.review(r.id) } }
            Button(TL("header.go_desktop", app)) { actions?.goToDesktop(r.id) }.panelDefault().keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.top, 6)
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

    /// "Ready to review", "Codex couldn’t start", "Ended with no changes", "Merged"… — a sentence, never a log line.
    static func endedTitle(_ r: AgentSessionRow) -> String {
        if r.folderGone { return TL("overlay.gone.title") }
        switch r.outcome {
        case .failed where r.job.stoppedAtTrust: return TL("overlay.stopped_trust.title", r.agentName)
        case .failed(let atStart): return TL(atStart ? "overlay.failed_start.title" : "overlay.failed.title", r.agentName)
        case .review: return TL("overlay.review.title")
        case .noChanges: return TL("overlay.no_changes.title")
        case .ended, .live: return TL("overlay.ended.title")
        case .finished: return r.stateText
        }
    }

    /// Its items waiting to be verified (after a merge or a pull request).
    static func toVerify(_ r: AgentSessionRow) -> [String] {
        r.job.items.filter { IndexLookup.item(uid: $0)?.state == "to_verify" }
    }

    static func itemID(_ uid: String, _ r: AgentSessionRow) -> String {
        IndexLookup.item(uid: uid)?.itemID ?? r.items.first?.id ?? ""
    }

    /// Mark as Done from the merged card: the user checked the work (items.py state --action done --by user).
    static func markDone(_ uids: [String]) {
        Scripts.state(uids, action: "done") { r in
            if case .failure(let f) = r { NSLog("blurt mark done: %@", "\(f)") }
            Scripts.indexUpdate(uids.compactMap { IndexLookup.item(uid: $0).map { URL(fileURLWithPath: $0.path) } })
            JobStore.shared.rescan()
        }
    }

    /// Some of its items are still with this session (handed off or in progress): Take Back and Restart apply.
    static func itemsWithIt(_ r: AgentSessionRow) -> Bool {
        r.job.items.contains { uid in IndexLookup.item(uid: uid).map { ["handed_off", "in_progress"].contains($0.state) } ?? true }
    }

    /// What the session's items are waiting for now (an exit moves nothing; only the agent's report does): the
    /// review, still in progress (it never reported back), to verify, or nothing at all when they are done.
    static func endedHint(_ r: AgentSessionRow) -> String? {
        if r.folderGone { return TL("overlay.gone.body") }
        if r.outcome == .review { return TL("overlay.ended.review_hint") }
        if case .failed = r.outcome { return nil }
        // merged / pull request: what waits now, where the user is ("Merged into main · AW-12 is waiting for you to
        // verify")
        if case .finished(let f) = r.outcome, ["merge", "pr"].contains(f) {
            let waiting = toVerify(r)
            guard !waiting.isEmpty else { return nil }
            let who = waiting.count == 1 ? itemID(waiting[0], r) : TL("finish.items_n", waiting.count)
            return f == "merge" ? TL("overlay.merged.verify_hint", r.agent.baseBranch ?? "main", who)
                                : TL("overlay.pr.verify_hint", who)
        }
        // restarted, discarded…: its items went on elsewhere (a new session, To Do) — nothing to say here
        if case .finished(let f) = r.outcome, f != "keep" { return nil }
        let states = r.job.items.compactMap { IndexLookup.item(uid: $0)?.state }
        if states.contains(where: { $0 == "handed_off" || $0 == "in_progress" }) { return TL("overlay.ended.unreported_hint") }
        if states.contains("to_verify") { return TL("overlay.ended.verify_hint") }
        return nil
    }
}
