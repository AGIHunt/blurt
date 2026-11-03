// What to do with a worktree session's branch once the agent is done (`sessions.py finish`): see the change (files,
// +/−, uncommitted work), then merge it into the base branch, open a pull request, discard it, or keep it for later.
// Nothing is pushed until the user clicks "Open Pull Request", and never a branch with no changes. Work the agent
// left uncommitted (a sandboxed agent can't commit in a worktree) is committed by Blurt first: "Commit and Merge".
// Keys: Esc cancels in every phase; ⌘Return merges — the sheet's one default — and Return alone does nothing destructive
// (an empty branch has no default; Discard's confirmation defaults to Cancel). After a merge or a PR
// the sheet's primary shows the items now waiting to be verified; after Discard they are back in To Do.
// Only what the user saw lands: while the agent is still in its window (a finished turn waits there) the primary is End
// Session and Review — it ends the agent and loads the diff again, and Merge comes after that; and merge / pr carry the
// review's token (`--expect`), so a worktree that changed since the diff loaded is refused (code changed: review again).
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
    /// The agent is still in its window: merging is refused, the primary ends it and reviews again.
    @Published var alive = false
    /// Its status while alive ("running" = mid-turn, not just waiting at its prompt).
    @Published var agentStatus: String?
    /// What the diff showed (sessions.py `reviewed`): merge / pr land only that.
    private(set) var reviewed: String?
    private(set) var lastAction: String?

    init(job: String) { self.job = job }

    var totals: (Int, Int) { (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.deleted }) }
    /// Nothing on the branch: no commits, nothing uncommitted.
    var empty: Bool { files.isEmpty && ahead == 0 && uncommitted == 0 }
    /// The session's items ("HS-1"), for the header and the button that shows them after a merge.
    var items: [SessionItemLabel] { SessionsModel.shared.row(job)?.items ?? [] }
    var agentName: String { SessionsModel.shared.row(job)?.agentName ?? "Agent" }
    /// The first item's kind (its icon in the header), from the index.
    var kind: String? { SessionsModel.shared.row(job)?.job.items.first.flatMap { IndexLookup.item(uid: $0)?.kind } }

    func load() async {
        phase = .loading
        failedCode = nil
        do {
            let o = try await AgentSessions.shared.finish(job: job, action: "diff")
            base = o["base"] as? String ?? ""
            branch = o["branch"] as? String ?? ""
            uncommitted = o["uncommitted"] as? Int ?? 0
            ahead = o["ahead"] as? Int ?? 0
            alive = o["alive"] as? Bool ?? false
            agentStatus = o["agent_status"] as? String
            reviewed = o["reviewed"] as? String
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
            let o = try await AgentSessions.shared.finish(job: job, action: action,
                                                          expect: ["merge", "pr"].contains(action) ? reviewed : nil)
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

    /// The agent is still in its window (a finished turn waits there): end the session (Ctrl-C, as Stop does; its
    /// window closed when that isn't enough), then load the diff again — what it changed on the way out included.
    /// Never straight on to a merge: the user merges what the sheet then shows.
    func endSessionAndReview() async {
        phase = .working("end")
        lastAction = nil
        try? await AgentSessions.shared.stop(job: job, kill: false)
        await load()
        if alive {
            try? await AgentSessions.shared.stop(job: job, kill: true)
            await load()
        }
        emit(["event": "session_finish", "job": job, "action": "end_review", "alive": alive])
    }
}

/// The sheet (HandoffKit's family): the item it is about as the header (kind icon, id, title) over the branch and its
/// base, the changed files in Settings' box (the directory dimmed, the file name in ink, only the counts that aren't
/// zero) with the total and Open Diff on the heading's line, and a footer — the rare ways out (Keep for Later,
/// Discard…) in a bordered ⋯ menu on the left, then Cancel and the one default, Merge (⌘↩), a split button whose menu
/// holds Open Pull Request. A session or worktree that is gone is not a review with an error in it: the sheet becomes a
/// small alert that says so, with one button — and the session's card behind it says the same once it closes.
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

    /// What is being reviewed: the item (its kind icon, id and title; "+1" for more), else the sheet's own name.
    var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let first = m.items.first {
                    if let k = m.kind { Image(nsImage: Look.kindImage(k, size: KindStyle.smallSize)).accessibilityLabel(Look.kindName(k)) }
                    Text(first.id).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    Text(m.items.count > 1 ? TL("session.items.more", first.title, m.items.count - 1) : first.title)
                        .font(.system(size: PanelMetrics.titleSize, weight: .semibold)).lineLimit(1).help(first.title)
                } else {
                    Text(TL("finish.title")).font(.system(size: PanelMetrics.titleSize, weight: .semibold))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !m.branch.isEmpty {
                // the branch's name in mono, the rest in the UI font
                (Text(m.branch).font(.system(size: 11.5, design: .monospaced)) + Text("  →  " + m.base).font(.system(size: SettingsMetrics.detailSize)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(TL("finish.subtitle", m.branch, m.base))
            }
        }
    }

    var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .padding(.bottom, PanelMetrics.side)
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
                            Self.path(f.path).lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading).help(f.path)
                            counts(f.added, f.deleted, size: 12)
                        }
                    }
                }
            }
            let heading = Text(Loc.plural("finish.files", table: "Terminal", count: m.files.count))
            VStack(alignment: .leading, spacing: 0) {
                PanelBox(heading: AnyView(HStack(spacing: 8) { heading; counts(m.totals.0, m.totals.1, size: 12) })) {
                    if m.files.count > Self.fileRows { ScrollView { rows }.frame(height: CGFloat(Self.fileRows) * 25) } else { rows }
                } accessory: {
                    if let p = m.patch {
                        Button(TL("finish.open_patch")) { NSWorkspace.shared.open(p) }.controlSize(.small)
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

    /// "src/auth/login.ts": the directory dimmed, the file's name in ink (GitHub Desktop's list).
    static func path(_ p: String) -> Text {
        let ns = p as NSString
        let dir = ns.deletingLastPathComponent
        let name = Text(ns.lastPathComponent).foregroundColor(.primary)
        return (dir.isEmpty ? name : Text(dir + "/").foregroundColor(.secondary) + name).font(.system(size: 13))
    }

    /// "+12 −3" in tabular figures: added in the ok ink, removed in the error ink; a count of nothing is left out.
    func counts(_ added: Int, _ deleted: Int, size: CGFloat) -> some View {
        // one text (one element to read and measure)
        let plus = added > 0 ? Text("+\(added)").foregroundColor(.brandOk) : Text("")
        let minus = deleted > 0 ? Text((added > 0 ? "  " : "") + "−\(deleted)").foregroundColor(.brandErr) : Text("")
        return (plus + minus).font(.system(size: size, weight: .regular).monospacedDigit()).fixedSize()
    }

    /// While the agent is still open: one line on what the primary does first (mid-turn: that it stops the turn).
    var aliveNote: String? {
        guard m.alive else { return nil }
        return TL(m.agentStatus == "running" ? "finish.alive.working" : "finish.alive", m.agentName)
    }

    var actions: some View {
        let mergeTitle = TL(m.alive ? "finish.end_review" : m.uncommitted > 0 ? "finish.commit_merge" : "finish.merge")
        let primaryOff = busy != nil || (m.empty && !m.alive)
        return HStack(spacing: 8) {
            // the rare ways out, never a button at rest: keep it as it is, or throw it away (asks first)
            Menu {
                Button(TL("finish.keep")) { Task { await m.run("keep") } }.help(TL("finish.keep.help"))
                Divider()
                Button(TL("review.discard"), role: .destructive) { confirmDiscard = true }
            } label: {
                // the one ⋯ of every header and panel: the circled ellipsis, borderless
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(busy != nil)
            .help(TL("review.more"))
            .accessibilityLabel(TL("review.more"))
            // the footnote gives up width first: the buttons' titles are never cut
            PanelFootnote(text: aliveNote, busy: busy.map { TL("finish.working.\($0)") }).layoutPriority(-1)
            Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction).disabled(busy != nil).fixedSize()
            if m.alive {
                // nothing to merge yet: the agent may still change the worktree. End it, then review what it left
                Button(mergeTitle) { Task { await m.endSessionAndReview() } }
                    .panelDefault().fixedSize().layoutPriority(1)
                    .keyboardShortcut(.return, modifiers: .command).disabled(primaryOff)
                    .help(TL("finish.end_review.help", m.agentName) + "  ⌘↩")
            } else {
                // the one default, split: Merge on a click (⌘↩, not a bare Return: it changes the base branch); its
                // menu holds the other way to land it, Open Pull Request (nothing is pushed until then)
                Button { Task { await m.run("merge") } } label: {
                    HStack(spacing: 8) {
                        Text(mergeTitle)
                        Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 13).accessibilityHidden(true)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                    }
                }
                .panelDefault().fixedSize().layoutPriority(1)
                    .keyboardShortcut(.return, modifiers: .command).disabled(primaryOff)
                    .help(TL("finish.help", m.base) + "  ⌘↩")
                    // the arrow's part of the button opens its menu
                    .overlay(alignment: .trailing) {
                        Menu {
                            Button(TL("finish.pr")) { Task { await m.run("pr") } }.help(TL("finish.pr.help"))
                        } label: { Rectangle().fill(Color.white.opacity(0.001)).frame(width: 26, height: 22) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: 26, height: 22)
                        .disabled(primaryOff)
                        .accessibilityHidden(true)      // the button itself carries it, as a named action
                    }
                    .accessibilityAction(named: TL("finish.pr")) { if !primaryOff { Task { await m.run("pr") } } }
            }
        }
    }

    func done(_ action: String) -> some View {
        let verify = ["merge", "pr", "pushed", "compare"].contains(action)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Color.brandOk)
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
                    // the next step is checking the work: show the items waiting for it. Close, not "Done": that
                    // is an item state here
                    Button(TL("common.close"), action: close).keyboardShortcut(.cancelAction)
                    Button(m.items.count == 1 ? TL("finish.show_item", first.id) : TL("finish.show_items")) {
                        close()
                        if let uid = SessionsModel.shared.row(m.job)?.job.items.first { AppEnvironment.mainWindow?.reveal(uid: uid) }
                    }
                    .panelDefault().keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.close"), action: close).panelDefault().keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: failures: a small alert

    /// The session or its worktree is gone: say so and close (Esc or ↩) — and the session's card and row behind say the
    /// same from then on (its folder gone: Take Back Items instead of a review). Anything else may pass: the reason,
    /// Close, and Try Again — or, when the agent still sits in its window, End Session and Review (never a Try Again
    /// that can only fail the same way); when the worktree changed after the review loaded, Review Again.
    func failed(_ why: String) -> some View {
        let code = m.failedCode ?? ""
        let gone = Self.gone.contains(code)
        let key = code == "gone" ? "review.folder_gone" : code == "no_worktree" ? "review.no_worktree" : "review.gone"
        let title = gone ? TL(key + ".title") : TL("review.failed.\(m.lastAction ?? "diff")")
        let dismiss = { close(); if gone { SessionsModel.shared.rebuild() } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: gone ? "questionmark.folder" : "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(gone ? Color.secondary : Color.brandAttn)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(gone ? TL(key + ".body") : why).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer()
                if gone {
                    Button(TL("common.close"), action: dismiss).panelDefault().keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.close"), action: close).keyboardShortcut(.cancelAction).fixedSize()
                    if m.failedCode == "running" {
                        Button(TL("finish.end_review")) { Task { await m.endSessionAndReview() } }
                            .panelDefault().fixedSize().keyboardShortcut(.defaultAction)
                    } else if m.failedCode == "changed" {
                        Button(TL("finish.review_again")) { Task { await m.load() } }
                            .panelDefault().fixedSize().keyboardShortcut(.defaultAction)
                    } else {
                        Button(TL("overlay.retry")) { Task { await m.load() } }.panelDefault().keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
        .frame(width: PanelMetrics.width)
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
        // Esc where no button takes it (the one Close of a gone session): the card behind then says it is gone too
        w.onCancel = { close(); SessionsModel.shared.rebuild() }
        let host = NSHostingController(rootView: FinishView(m: m, close: close))
        host.sizingOptions = [.preferredContentSize]
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }     // the content runs under the hidden title bar
        w.contentViewController = host
        if let p = parent { p.beginSheet(w) } else { w.center(); activateApp(); w.makeKeyAndOrderFront(nil) }
    }
}
