// What to do with a worktree session's branch once the agent is done (`sessions.py finish`): see the change (files,
// +/−, uncommitted work), then merge it into the base branch, open a pull request, discard it, or keep it for later.
// Nothing is pushed until the user clicks "Open Pull Request", and never a branch with no changes. Work the agent
// left uncommitted (a sandboxed agent can't commit in a worktree) is committed by Blurt first: "Commit and Merge".
// Keys: Esc cancels in every phase; ⌘Return merges — the brand primary — and Return alone does nothing destructive
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
        } catch { phase = .failed(sessionsErrorText(error)) }
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

struct FinishView: View {
    @ObservedObject var m: FinishModel
    var close: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 17)).foregroundStyle(Color.brandInk)
                    .frame(width: 32, height: 32).background(Circle().fill(Color.brandTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TL("finish.title")).font(.title3.weight(.semibold))
                    if !m.branch.isEmpty {
                        Text(TL("finish.subtitle", m.branch, m.base)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            switch m.phase {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text(TL("finish.loading")).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
                HStack { Spacer(); Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Color.brandAttnInk).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(TL("common.close"), action: close).keyboardShortcut(.cancelAction)
                    if m.failedCode == "running", let a = m.lastAction {
                        Button(TL("overlay.retry")) { Task { await m.load() } }
                        Button(TL("finish.end_and.\(a)")) { Task { await m.endSessionThen(a) } }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(TL("overlay.retry")) { Task { await m.load() } }.keyboardShortcut(.defaultAction)
                    }
                }
            case .done(let action):
                Label(doneText(action), systemImage: "checkmark.circle").foregroundStyle(AgentSessionStatus.turnDone.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let u = m.prURL, let url = URL(string: u) {
                    Link(u, destination: url).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                let verify = ["merge", "pr", "pushed", "compare"].contains(action)
                if verify {
                    Text(TL("finish.done.verify")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if verify, let first = m.items.first {
                        // the next step is checking the work: show the items waiting for it
                        Button(TL("common.done"), action: close).keyboardShortcut(.cancelAction)
                        Button(m.items.count == 1 ? TL("finish.show_item", first.id) : TL("finish.show_items")) {
                            close()
                            if let uid = SessionsModel.shared.row(m.job)?.job.items.first { AppEnvironment.mainWindow?.reveal(uid: uid) }
                        }
                        .buttonStyle(.brand).keyboardShortcut(.defaultAction)
                    } else {
                        Button(TL("common.done"), action: close).keyboardShortcut(.defaultAction)
                    }
                }
            case .ready, .working:
                if m.empty {
                    Text(TL("finish.no_changes")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    stats
                }
                actions
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await m.load() }
        .alert(TL("finish.discard.confirm.title"), isPresented: $confirmDiscard) {
            // Return keeps the work: Cancel is the default, Discard has to be clicked
            Button(TL("finish.discard"), role: .destructive) { Task { await m.run("discard") } }
            Button(TL("common.cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { Text(TL("finish.discard.confirm.body", m.branch)) }
    }

    func doneText(_ action: String) -> String {
        if action == "discard", m.takenBack > 0 { return Loc.plural("finish.done.discard_taken_back", table: "Terminal", count: m.takenBack) }
        return TL("finish.done.\(action)")
    }

    var stats: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Loc.plural("finish.files", table: "Terminal", count: m.files.count)).font(.callout.weight(.medium))
                Spacer()
                Group {
                    Text("+\(m.totals.0)").foregroundStyle(AgentSessionStatus.turnDone.color)
                    Text("−\(m.totals.1)").foregroundStyle(AgentSessionStatus.error.color)
                }
                .font(.system(size: 12, design: .monospaced))
                if let p = m.patch {
                    Button(TL("finish.open_patch")) { NSWorkspace.shared.open(p) }.buttonStyle(.link).foregroundStyle(Color.brandInk).font(.callout).padding(.leading, 6)
                }
            }
            .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(m.files) { f in
                        HStack(spacing: 8) {
                            Text(f.path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("+\(f.added)").foregroundStyle(AgentSessionStatus.turnDone.color)
                            Text("−\(f.deleted)").foregroundStyle(AgentSessionStatus.error.color)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            if m.uncommitted > 0 {
                // a sandboxed agent leaves its work uncommitted: Blurt commits it on the branch first
                Text(Loc.plural("finish.uncommitted", table: "Terminal", count: m.uncommitted))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var actions: some View {
        let busy: String? = { if case .working(let a) = m.phase { return a }; return nil }()
        return VStack(alignment: .leading, spacing: 10) {
            if !m.empty {
                Text(TL("finish.help", m.base)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                // nothing to keep: discarding is the way out (it asks first) — never on a bare Return
                Button(TL("finish.discard"), role: .destructive) { confirmDiscard = true }.disabled(busy != nil)
                Button(TL("finish.keep")) { Task { await m.run("keep") } }.disabled(busy != nil).help(TL("finish.keep.help"))
                Spacer()
                if let b = busy { ProgressView().controlSize(.small).help(TL("finish.working.\(b)")) }
                Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction).disabled(busy != nil)
                Button(TL("finish.pr")) { Task { await m.run("pr") } }.disabled(busy != nil || m.empty).help(TL("finish.pr.help"))
                // the primary, drawn as one (brand) — on ⌘↩, not a bare Return, since it changes the base branch
                Button(TL(m.uncommitted > 0 ? "finish.commit_merge" : "finish.merge")) { Task { await m.run("merge") } }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.return, modifiers: .command).disabled(busy != nil || m.empty)
                    .help(TL("finish.merge.help", m.base) + "  ⌘↩")
            }
        }
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
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: FinishView(m: m, close: { [weak w, weak parent] in
            if let w = w, let p = parent, w.sheetParent === p { p.endSheet(w) } else { w?.close() }
        }))
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        if let p = parent { p.beginSheet(w) } else { w.center(); activateApp(); w.makeKeyAndOrderFront(nil) }
    }
}
