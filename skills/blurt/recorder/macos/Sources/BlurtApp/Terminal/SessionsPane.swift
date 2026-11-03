// The view P4 embeds in the main window (AppEnvironment.terminal.makePane()): the sessions list on the left (grouped by
// project, live status, New Session), the selected session's terminal on the right under a header with its project,
// items, agent, branch and actions. Each pane attaches on its own (two panes never move each other's window) and
// remembers what it showed in $BLURT_HOME/ui/terminal.json, so a relaunched app reattaches to the same session.
// In the main window (pane "main") the item list already picks the session, so the sessions list starts hidden
// (the header's sidebar button shows it). A session that ends shows its ended card (SessionsViews), not the dead
// window; Show Output attaches to what the agent left on screen. A session in the agent's desktop app has no terminal:
// its card says so (Go to Claude, Review Changes…); Continue in Claude Desktop moves a terminal session there, asking
// first — and, without the blurt MCP installed for Claude, saying the items then need marking by hand, with Install….
import AppKit
import Combine
import SwiftUI
import BlurtCore

@MainActor
final class PaneState: ObservableObject {
    @Published var job: String?
    @Published var attach: AttachState = .none
    @Published var listShown = true
    /// In the main window's detail (TerminalHost.makePane), whose In Progress place is the session list: the header
    /// draws no list toggle or compose button of its own.
    @Published var embedded = false
    /// the header's extra leading inset (clear of the traffic lights while the list is hidden)
    @Published var headerLead: CGFloat = 0
    @Published var finishing: String?           // job whose worktree result is being reviewed (sheet)
    /// The ended session whose output the user asked to see (Show Output): its dead window stays attached.
    var outputShown: String?
}

/// The list | detail split: no divider line while the list is hidden (the empty state, the main window's pane).
final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { arrangedSubviews.first?.isHidden == true ? 0 : super.dividerThickness }
}

@MainActor
final class SessionsPaneController: NSViewController, @preconcurrency TerminalPaneHosting {
    let state = PaneState()
    let model = SessionsModel.shared
    let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    private let split = PaneSplitView()
    private var listHost: NSHostingView<SessionsList>!
    private weak var overlay: NSView?
    private var token: UUID?
    private var rowsWatch: AnyCancellable?
    let paneID: String

    init(paneID: String = "main") {
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
        state.listShown = paneID != "main"
    }
    required init?(coder: NSCoder) { fatalError() }

    var viewController: NSViewController { self }

    override func loadView() {
        model.start()
        listHost = NSHostingView(rootView: SessionsList(model: model, pane: state, select: { [weak self] in self?.attach(job: $0) },
                                                        newSession: { TerminalHost.shared.newSession(project: nil, items: []) },
                                                        toggle: { [weak self] in self?.toggleList() }))
        let detail = NSView()
        let header = NSHostingView(rootView: SessionHeader(model: model, pane: state, actions: self))
        let overlay = NSHostingView(rootView: SessionOverlay(model: model, pane: state, actions: self))
        self.overlay = overlay
        // under the header, as tall as its one line while the agent waits at a startup question, else nothing
        let hint = NSHostingView(rootView: SessionHintBar(model: model, pane: state))
        hint.sizingOptions = [.intrinsicContentSize]
        hint.setContentHuggingPriority(.required, for: .vertical)
        // its one line truncates: never a minimum width for the pane (or the window)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [header, hint, surface, overlay] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            hint.topAnchor.constraint(equalTo: header.bottomAnchor),
            hint.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            // the terminal runs to the window's edges (its own margin is inside it, in its own colour)
            surface.topAnchor.constraint(equalTo: hint.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: header.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        // the pane takes whatever size its host gives it: SwiftUI's ideal sizes must not shrink the window
        listHost.sizingOptions = []
        if #available(macOS 13.3, *) { listHost.safeAreaRegions = [] }   // its own strip of the title bar, at the header's height
        header.sizingOptions = []
        if #available(macOS 13.3, *) { header.safeAreaRegions = [] }     // lines up with a 52 pt unified title bar
        overlay.sizingOptions = []
        detail.wantsLayer = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listHost)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        listHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        listHost.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: paneID == "main" ? 360 : 420).isActive = true
        listHost.isHidden = !state.listShown || model.rows.isEmpty
        listVisibilityChanged()
        view = split
        // no sessions: the list column steps aside, the detail's empty state is the one story; it comes back with the
        // first session (where the user keeps it shown)
        rowsWatch = model.$rows.map(\.isEmpty).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] empty in
            guard let self = self, self.state.listShown, self.listHost.isHidden != empty else { return }
            self.listHost.isHidden = empty
            self.listVisibilityChanged()
            self.split.adjustSubviews()
            if !empty { self.split.setPosition(250, ofDividerAt: 0); self.growIfCompact() }
        }
        surface.onState = { [weak self] s in
            self?.state.attach = s
            self?.overlay?.isHidden = s == .attached       // out of the way of the terminal's clicks and scrolling
        }
        token = JobStore.shared.addObserver { [weak self] changed in
            MainActor.assumeIsolated { self?.jobsChanged(changed) }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // setting the divider shows a hidden list again: only when it is meant to be seen
        if state.listShown && !model.rows.isEmpty { split.setPosition(250, ofDividerAt: 0) }
        if state.job == nil { attach(job: nil) }
    }

    /// The Sessions window opened compact on its empty state: the first session brings it to its working size, its
    /// top-left corner kept.
    private func growIfCompact() {
        guard let w = view.window as? SessionsWindow, w.frame.width < SessionsWindowController.compact.width + 40 else { return }
        let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        w.setContentSize(SessionsWindowController.full)
        w.setFrameTopLeftPoint(top)
    }

    /// Without the list the header starts at the window's left edge: in a window of its own (not the main window's
    /// pane) it keeps clear of the traffic lights.
    private func listVisibilityChanged() {
        state.headerLead = paneID != "main" && listHost.isHidden ? 80 : 0
    }

    deinit { if let t = token { JobStore.shared.removeObserver(t) } }

    // MARK: TerminalPaneHosting

    /// nil = the session this pane showed last (if it is still listed), else the one that needs you, else the newest.
    func attach(job: String?) {
        _ = view
        let pick = job ?? PaneMemory.last(paneID).flatMap { model.row($0)?.id } ?? model.preferred?.id
        if pick != state.job { state.outputShown = nil }
        state.job = pick
        surface.attach(pick, output: pick != nil && state.outputShown == pick)
        if let p = pick { PaneMemory.set(paneID, p) }
        if pick != nil { view.window?.makeFirstResponder(surface) }
    }

    func reattach() { surface.attach(state.job, force: true, output: state.job != nil && state.outputShown == state.job) }

    func toggleList() {
        state.listShown.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            listHost.isHidden = !state.listShown || model.rows.isEmpty
            listVisibilityChanged()
            split.adjustSubviews()
            if state.listShown { split.setPosition(250, ofDividerAt: 0) }
        }
    }

    private func jobsChanged(_ changed: [Job]) {
        guard let cur = state.job else {
            if model.preferred != nil { attach(job: nil) }      // the first session appeared
            return
        }
        guard let j = changed.first(where: { $0.id == cur }) else { return }
        // it moved to the desktop app (Continue in Claude Desktop): the terminal it had is gone
        if j.isActive, j.agent?.isDesktop == true, state.attach != .desktop {
            surface.attach(cur, force: true)
            return
        }
        // The agent ended: say how (the ended card: its reason, Review Changes… or Restart), not tmux's dead window.
        // The window stays readable (remain-on-exit) behind Show Output — until it is gone (merged, discarded,
        // restarted, ended with --kill), when a grouped view session would slide onto another session's window.
        let windowGone = j.state == .cancelled || ["merge", "discard", "restart", "take_back"].contains(j.agent?.finishAction ?? "")
        if !j.isActive, state.outputShown != cur || windowGone, state.attach != .ended {
            if windowGone { state.outputShown = nil }
            surface.attach(cur, force: true)        // → .ended without a client
        }
    }
}

extension SessionsPaneController: SessionActions {
    func openExternal(_ job: String, terminal: String?) {
        Task { @MainActor in
            do { try await AgentSessions.shared.openExternal(job: job, terminal: terminal) }
            catch { presentError(sessionsErrorText(error)) }
        }
    }

    func interrupt(_ job: String) {
        Task { @MainActor in
            do { try await AgentSessions.shared.stop(job: job, kill: false) } catch { presentError(sessionsErrorText(error)) }
        }
    }

    func end(_ job: String) {
        let a = NSAlert()
        // in the desktop app the conversation goes on: Blurt only stops following it here
        let ag = JobStore.shared.job(job)?.agent
        let desktop = ag?.isDesktop == true
        a.messageText = desktop ? TL("end_desktop.title") : TL("end.title")
        a.informativeText = desktop ? TL("end_desktop.body", DesktopApp.name(ag?.agent ?? "")) : TL("end.body")
        a.addButton(withTitle: TL(desktop ? "end_desktop.confirm" : "end.confirm"))
        a.addButton(withTitle: TL("common.cancel"))
        a.buttons.first?.hasDestructiveAction = true
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do { try await AgentSessions.shared.stop(job: job, kill: true) } catch { self.presentError(sessionsErrorText(error)) }
            }
        }
    }

    func review(_ job: String) { FinishPanel.show(job: job, over: view.window) }

    func goToDesktop(_ job: String) {
        guard let a = JobStore.shared.job(job)?.agent else { return }
        DesktopApp.goTo(a.agent)
    }

    /// Continue in Claude Desktop: say first what changes (the terminal here closes, live status stops, progress comes
    /// from the agent), then move it. Without the blurt MCP installed for the app (the terminal session may have had it
    /// through --mcp-config, which the app doesn't get) nothing would report from there: the confirmation says the
    /// items then need marking by hand, and offers Install (the Settings → Agents installer, previewed first).
    func continueDesktop(_ job: String) {
        guard let a = JobStore.shared.job(job)?.agent, let w = view.window else { return }
        let app = DesktopApp.name(a.agent)
        let noMCP = DesktopApp.continueCheck(a.agent) {}?.mcp == false
        let alert = NSAlert()
        alert.messageText = TL("continue_desktop.title", app)
        alert.informativeText = TL(noMCP ? "continue_desktop.body_nomcp" : "continue_desktop.body", app)
        alert.addButton(withTitle: TL("continue_desktop.confirm"))
        if noMCP { alert.addButton(withTitle: TL("dispatch.desktop.install")) }
        alert.addButton(withTitle: TL("common.cancel"))
        emit(["event": "continue_desktop_confirm", "job": job, "no_mcp": noMCP])
        alert.beginSheetModal(for: w) { r in
            switch r {
            case .alertFirstButtonReturn:
                self.performContinueDesktop(job, withoutMCP: noMCP) { err in if let e = err { self.presentError(e) } }
            case .alertSecondButtonReturn where noMCP:
                self.installMCP(a.agent)
            default: break
            }
        }
    }

    /// The existing installer (AgentsModel: preview, then apply), as a sheet here; afterwards Continue asks again.
    func installMCP(_ agent: String) {
        guard let w = view.window else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(MCPInstallHost(agent: agent) { [weak host] in
            DesktopApp.forgetCheck(agent)
            if let h = host { self.dismiss(h) }
        })
        presentAsSheet(host)
    }

    func performContinueDesktop(_ job: String, withoutMCP: Bool = false, done: @escaping (String?) -> Void) {
        Task { @MainActor in
            do {
                try await AgentSessions.shared.continueInDesktop(job: job, withoutMCP: withoutMCP)
                emit(["event": "session_continue_desktop", "job": job])
                JobStore.shared.rescan()
                done(nil)
            } catch { done(sessionsErrorText(error)) }
        }
    }

    func restart(_ job: String) {
        SessionRecovery.restart(job) { [weak self] r in
            switch r {
            // the main window's pane belongs to its job detail: the new job is shown there, not only attached
            case .success(let new):
                guard let n = new, let self = self else { return }
                if self.paneID == "main" { TerminalModule.reveal(job: n) } else { self.attach(job: n) }
            case .failure(let e): self?.presentError(sessionsErrorText(e))
            }
        }
    }

    func takeBack(_ job: String) { SessionRecovery.takeBack(job) { [weak self] e in self?.presentError(e) } }

    func remove(_ job: String) {
        PaneMemory.remove(job)
        model.rebuild()
        if state.job == job { attach(job: model.preferred?.id) }
    }

    func showOutput(_ job: String) {
        state.outputShown = job
        surface.attach(job, force: true, output: true)
    }
    func reconnect() { reattach() }
    func toggleSidebar() { toggleList() }
    func popOut(_ job: String) { SessionsWindowController.shared.show(job: job, newWindow: true) }

    func presentError(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.alertStyle = .warning
        if let w = view.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}

/// What a pane showed last, per pane id ($BLURT_HOME/ui/terminal.json — not UserDefaults: test builds share the
/// bundle id with the real app).
enum PaneMemory {
    static var url: URL { BlurtPaths.home.appendingPathComponent("ui/terminal.json") }
    static func read() -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    static func last(_ pane: String) -> String? { (read()["panes"] as? [String: String])?[pane] }
    /// Sessions the user removed from the list (Remove Session, once its folder was gone): never listed again.
    static func removed() -> Set<String> { Set(read()["removed"] as? [String] ?? []) }
    static func remove(_ job: String) {
        var o = read()
        o["removed"] = Array(removed().union([job])).sorted()
        write(o)
    }
    private static func write(_ o: [String: Any]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
    static func set(_ pane: String, _ job: String) {
        var o = read()
        var p = o["panes"] as? [String: String] ?? [:]
        guard p[pane] != job else { return }
        p[pane] = job
        o["panes"] = p
        write(o)
    }
}
