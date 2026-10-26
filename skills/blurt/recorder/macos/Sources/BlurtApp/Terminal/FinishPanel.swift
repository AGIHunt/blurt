// What to do with a worktree session's branch once the agent is done (`sessions.py finish`): see the change (files,
// +/−, uncommitted work), then merge it into the base branch, open a pull request, discard it, or keep it for later.
// Nothing is pushed until the user clicks "Open Pull Request", and never a branch with no changes. Work the agent
// left uncommitted (a sandboxed agent can't commit in a worktree) is committed by Blurt first: "Commit and Merge".
// Keys: Esc cancels in every phase; ⌘Return merges — the sheet's one default — and Return alone does nothing destructive
// (an empty branch has no default; Discard's confirmation defaults to Cancel). After a merge or a PR
// the sheet's primary shows the items now waiting to be verified; after Discard they are back in To Do.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class FinishModel: ObservableObject {
    struct FileStat: Identifiable { let path: String; let added: Int; let deleted: Int; var id: String { path } }
    enum Phase: Equatable { case loading, ready, working(String), done(String), failed(String) }

    let job: String
    @Published var phase: Phase = .loading
    @Published var base = ""
    @Published var branch = ""
    @Published var files: [FileStat] = []
    @Published var uncommitted = 0
    @Published var ahead = 0
    @Published var patch: URL?
    @Published var prURL: String?
    @Published var failedCode: String?          // the sessions.py code of the last failure ("running": end the session)
    @Published var takenBack = 0                // discard: items back in To Do
    private(set) var lastAction: String?

    init(job: String) { self.job = job }

    var totals: (Int, Int) { (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.deleted }) }
    /// Nothing on the branch: no commits, nothing uncommitted.
    var empty: Bool { files.isEmpty && ahead == 0 && uncommitted == 0 }
    /// The session's items ("HS-1"), for the button that shows them after a merge.
    var items: [SessionItemLabel] { SessionsModel.shared.row(job)?.items ?? [] }

    func load() async {
        phase = .loading
        failedCode = nil
        do {
            let o = try await AgentSessions.shared.finish(job: job, action: "diff")
            base = o["base"] as? String ?? ""
            branch = o["branch"] as? String ?? ""
            uncommitted = o["uncommitted"] as? Int ?? 0
            ahead = o["ahead"] as? Int ?? 0
            patch = (o["patch"] as? String).map { URL(fileURLWithPath: $0) }
            files = (o["stat"] as? [[String: Any]] ?? []).map {
                FileStat(path: $0["path"] as? String ?? "", added: $0["added"] as? Int ?? 0, deleted: $0["deleted"] as? Int ?? 0)
            }
            phase = .ready
        } catch {
            failedCode = (error as? SessionsError)?.code
            lastAction = nil
            phase = .failed(sessionsErrorText(error))
        }
    }

    func run(_ action: String) async {
        phase = .working(action)
        lastAction = action
        failedCode = nil
        do {
            let o = try await AgentSessions.shared.finish(job: job, action: action)
            prURL = o["pr"] as? String ?? o["compare"] as? String
            takenBack = (o["taken_back"] as? [String])?.count ?? 0
            // without gh (or a host it knows) nothing was opened: say what did happen
            if action == "pr", o["pr"] as? String == nil {
                phase = .done(prURL == nil ? "pushed" : "compare")
                emit(["event": "session_finish", "job": job, "action": action, "pr": NSNull()])
                return
            }
            phase = .done(action)
            emit(["event": "session_finish", "job": job, "action": action])
        } catch {
            failedCode = (error as? SessionsError)?.code
            phase = .failed(sessionsErrorText(error))
        }
    }

    /// Merge refused because the agent is still in its window (a finished turn still waits for you): end the
    /// session (Ctrl-C, as Stop does), give the window a moment to close, then do what was asked.
    func endSessionThen(_ action: String) async {
        phase = .working(action)
        try? await AgentSessions.shared.stop(job: job, kill: false)
        for _ in 0..<10 {
            await run(action)
            guard failedCode == "running" else { return }
            phase = .working(action)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        await run(action)
    }
}

/// The sheet (HandoffKit's family): "Review Changes" over the branch and its base, the changed files in Settings' box
/// with the totals and Open Diff on the heading's line, and a footer — the rare ways out (Keep for Later, Discard…) in
/// a ⋯ menu on the left, then Cancel, Open Pull Request and the one default, Merge (⌘↩). A session or worktree that is
/// gone is not a review with an error in it: the sheet becomes a small alert that says so, with one button.
struct FinishView: View {
    @ObservedObject var m: FinishModel
    var close: () -> Void
    @State private var confirmDiscard = false

    /// sessions.py codes after which there is nothing to try again: the session or its worktree is gone.
    static let gone: Set<String> = ["no_job", "gone", "no_worktree", "bad_job"]
    /// The file list scrolls past this many rows.
    static let fileRows = 6

    var body: some View {
        Group {
            if case .failed(let why) = m.phase { failed(why) } else { review }
        }
        .animation(PanelMetrics.change, value: "\(m.phase)")
        .alert(TL("finish.discard.confirm.title"), isPresented: $confirmDiscard) {
            // Return keeps the work: Cancel is the default, Discard has to be clicked
            Button(TL("finish.discard"), role: .destructive) { Task { await m.run("discard") } }
            Button(TL("common.cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { Text(TL("finish.discard.confirm.body", m.branch)) }
        .task { await m.load() }
    }

    // MARK: the review

    var busy: String? { if case .working(let a) = m.phase { return a }; return nil }

    var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TL("finish.title")).font(.system(size: PanelMetrics.titleSize, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if !m.branch.isEmpty {
                    Text(TL("finish.subtitle", m.branch, m.base)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(TL("finish.subtitle", m.branch, m.base))
                }
            }
            switch m.phase {
            case .loading:
                PanelBox {
                    SettingsLine(padding: 10) {
                        HStack(spacing: 6) { BrandSpinnerView(size: 10); Text(TL("finish.loading")) }
                            .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, PanelMetrics.gap)
                HStack { Spacer(); Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction) }.padding(.top, 20)
            case .done(let action):
                done(action).padding(.top, PanelMetrics.gap)
            default:
                files.padding(.top, PanelMetrics.gap)
                actions.padding(.top, 20)
            }
        }
        .padding(.horizontal, PanelMetrics.side)
        .padding(.top, PanelMetrics.top)
        .padding(.bottom, PanelMetrics.bottom)
        .frame(width: PanelMetrics.width)
    }

    func doneText(_ action: String) -> String {
        if action == "discard", m.takenBack > 0 { return Loc.plural("finish.done.discard_taken_back", table: "Terminal", count: m.takenBack) }
        return TL("finish.done.\(action)")
    }

    @ViewBuilder var files: some View {
        if m.empty {
            PanelBox {
                SettingsLine(padding: 10) {
                    Text(TL("finish.no_changes")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
            }
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(m.files) { f in
                    SettingsLine(padding: 5) {
                        HStack(spacing: 10) {
                            Text(f.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading).help(f.path)
                            counts(f.added, f.deleted, size: 11.5)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                PanelBox(heading: AnyView(Text(Loc.plural("finish.files", table: "Terminal", count: m.files.count)))) {
                    if m.files.count > Self.fileRows { ScrollView { rows }.frame(height: CGFloat(Self.fileRows) * 25) } else { rows }
                } accessory: {
                    HStack(spacing: 10) {
                        counts(m.totals.0, m.totals.1, size: 12)
                        if let p = m.patch {
                            Button(TL("finish.open_patch")) { NSWorkspace.shared.open(p) }
                                .buttonStyle(.plain).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandInk)
                        }
                    }
                }
                if m.uncommitted > 0 {
                    // a sandboxed agent leaves its work uncommitted: Blurt commits it on the branch first
                    Text(Loc.plural("finish.uncommitted", table: "Terminal", count: m.uncommitted))
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsMetrics.boxInset).padding(.top, 7)
                }
            }
        }
    }

    /// "+12 −3" in tabular figures: added in the ok ink, removed in the error ink.
    func counts(_ added: Int, _ deleted: Int, size: CGFloat) -> some View {
        // one text (one element to read and measure); a count of nothing says nothing: quiet, not green or red
        let quiet = Color(nsColor: .tertiaryLabelColor)
        return (Text("+\(added)").foregroundColor(added == 0 ? quiet : AgentSessionStatus.turnDone.color)
                + Text("  −\(deleted)").foregroundColor(deleted == 0 ? quiet : AgentSessionStatus.error.color))
            .font(.system(size: size).monospacedDigit())
            .fixedSize()
    }

    var actions: some View {
        HStack(spacing: 8) {
            // the rare ways out, never a button at rest: keep it as it is, or throw it away (asks first)
            Menu {
                Button(TL("finish.keep")) { Task { await m.run("keep") } }.help(TL("finish.keep.help"))
                Divider()
                Button(TL("review.discard"), role: .destructive) { confirmDiscard = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(busy != nil)
            .help(TL("review.more"))
            .accessibilityLabel(TL("review.more"))
            PanelFootnote(text: nil, busy: busy.map { TL("finish.working.\($0)") })
            Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction).disabled(busy != nil)
            Button(TL("finish.pr")) { Task { await m.run("pr") } }.disabled(busy != nil || m.empty).help(TL("finish.pr.help"))
            // the one default — on ⌘↩, not a bare Return, since it changes the base branch
            Button(TL(m.uncommitted > 0 ? "finish.commit_merge" : "finish.merge")) { Task { await m.run("merge") } }
                .panelDefault()
                .keyboardShortcut(.return, modifiers: .command).disabled(busy != nil || m.empty)
                .help(TL("finish.help", m.base) + "  ⌘↩")
        }
    }

    func done(_ action: String) -> some View {
        let verify = ["merge", "pr", "pushed", "compare"].contains(action)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(AgentSessionStatus.turnDone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(doneText(action)).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let u = m.prURL, let url = URL(string: u) {
                        Link(u, destination: url).font(.system(size: SettingsMetrics.detailSize)).lineLimit(1).truncationMode(.middle).help(u)
                    }
                    if verify {
                        Text(TL("finish.done.verify")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.boxInset)
            HStack(spacing: 8) {
                Spacer()
                if verify, let first = m.items.first {
                    // the next step is checking the work: show the items waiting for it
                    Button(TL("common.done"), action: close).keyboardShortcut(.cancelAction)
                    Button(m.items.count == 1 ? TL("finish.show_item", first.id) : TL("finish.show_items")) {
                        close()
                        if let uid = SessionsModel.shared.row(m.job)?.job.items.first { AppEnvironment.mainWindow?.reveal(uid: uid) }
                    }
                    .panelDefault().keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.done"), action: close).panelDefault().keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: failures: a small alert

    /// The session or its worktree is gone: say so and close (Esc or ↩). Anything else may pass: the reason, Close,
    /// and Try Again — or, when the agent still sits in its window, End Session and Merge.
    func failed(_ why: String) -> some View {
        let gone = Self.gone.contains(m.failedCode ?? "")
        let title = gone ? TL("review.gone.title") : TL("review.failed.\(m.lastAction ?? "diff")")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: gone ? "questionmark.folder" : "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(gone ? Color.secondary : Color.brandAttn)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(gone ? TL("review.gone.body") : why).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer()
                if gone {
                    Button(TL("common.close"), action: close).panelDefault().keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.close"), action: close).keyboardShortcut(.cancelAction)
                    if m.failedCode == "running", let a = m.lastAction {
                        Button(TL("overlay.retry")) { Task { await m.load() } }
                        Button(TL("finish.end_and.\(a)")) { Task { await m.endSessionThen(a) } }.panelDefault().keyboardShortcut(.defaultAction)
                    } else {
                        Button(TL("overlay.retry")) { Task { await m.load() } }.panelDefault().keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 380)
    }
}

@MainActor
enum FinishPanel {
    /// The newest panel's model (self-tests).
    private(set) static weak var current: FinishModel?

    static func show(job: String, over parent: NSWindow?) {
        // one sheet per window: a second Review Changes… replaces the first instead of queueing behind it
        if let p = parent, let open = p.attachedSheet, open.contentViewController is NSHostingController<FinishView> { p.endSheet(open) }
        let m = FinishModel(job: job)
        current = m
        let w = HandoffWindow()
        w.title = TL("finish.title")
        let close: () -> Void = { [weak w, weak parent] in
            if let w = w, let p = parent, w.sheetParent === p { p.endSheet(w) } else { w?.close() }
        }
        w.onCancel = close      // Esc where no button takes it (the one Close of a gone session)
        let host = NSHostingController(rootView: FinishView(m: m, close: close))
        host.sizingOptions = [.preferredContentSize]
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }     // the content runs under the hidden title bar
        w.contentViewController = host
        if let p = parent { p.beginSheet(w) } else { w.center(); activateApp(); w.makeKeyAndOrderFront(nil) }
    }
}
