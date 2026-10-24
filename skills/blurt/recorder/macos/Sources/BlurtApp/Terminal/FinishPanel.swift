// What to do with a worktree session's branch once the agent is done (`sessions.py finish`): see the change (files,
// +/−, uncommitted work), then merge it into the base branch, open a pull request, discard it, or keep it for later.
// Nothing is pushed until the user clicks "Open Pull Request".
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
    @Published var patch: URL?
    @Published var prURL: String?
    @Published var failedCode: String?          // the sessions.py code of the last failure ("running": end the session)
    private(set) var lastAction: String?

    init(job: String) { self.job = job }

    var totals: (Int, Int) { (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.deleted }) }

    func load() async {
        phase = .loading
        do {
            let o = try await AgentSessions.shared.finish(job: job, action: "diff")
            base = o["base"] as? String ?? ""
            branch = o["branch"] as? String ?? ""
            uncommitted = o["uncommitted"] as? Int ?? 0
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
                Label(TL("finish.done.\(action)"), systemImage: "checkmark.circle").foregroundStyle(AgentSessionStatus.turnDone.color)
                if let u = m.prURL, let url = URL(string: u) {
                    Link(u, destination: url).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                if ["merge", "pr", "pushed", "compare"].contains(action) {
                    Text(TL("finish.done.verify")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack { Spacer(); Button(TL("common.done"), action: close).keyboardShortcut(.defaultAction) }
            case .ready, .working:
                stats
                if m.uncommitted > 0 {
                    Label(Loc.plural("finish.uncommitted", table: "Terminal", count: m.uncommitted), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(AgentSessionStatus.waitingInput.color)
                }
                actions
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await m.load() }
        .alert(TL("finish.discard.confirm.title"), isPresented: $confirmDiscard) {
            Button(TL("finish.discard"), role: .destructive) { Task { await m.run("discard") } }
            Button(TL("common.cancel"), role: .cancel) {}
        } message: { Text(TL("finish.discard.confirm.body", m.branch)) }
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
            if m.files.isEmpty {
                Text(TL("finish.no_changes")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
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
            }
        }
    }

    var actions: some View {
        let busy: String? = { if case .working(let a) = m.phase { return a }; return nil }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(TL("finish.help", m.base)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(TL("finish.discard"), role: .destructive) { confirmDiscard = true }.disabled(busy != nil)
                Button(TL("finish.keep")) { Task { await m.run("keep") } }.disabled(busy != nil).help(TL("finish.keep.help"))
                Spacer()
                if let b = busy { ProgressView().controlSize(.small).help(TL("finish.working.\(b)")) }
                Button(TL("finish.pr")) { Task { await m.run("pr") } }.disabled(busy != nil).help(TL("finish.pr.help"))
                Button(TL("finish.merge")) { Task { await m.run("merge") } }
                    .keyboardShortcut(.defaultAction).disabled(busy != nil || m.files.isEmpty)
                    .help(TL("finish.merge.help", m.base))
            }
        }
    }
}

@MainActor
enum FinishPanel {
    /// The newest panel's model (self-tests).
    private(set) static weak var current: FinishModel?

    static func show(job: String, over parent: NSWindow?) {
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
