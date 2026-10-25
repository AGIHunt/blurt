// The view P4 embeds in the main window (AppEnvironment.terminal.makePane()): the sessions list on the left (grouped by
// project, live status, New Session), the selected session's terminal on the right under a header with its project,
// items, agent, branch and actions. Each pane attaches on its own (two panes never move each other's window) and
// remembers what it showed in $BLURT_HOME/ui/terminal.json, so a relaunched app reattaches to the same session.
// In the main window (pane "main") the item list already picks the session, so the sessions list starts hidden
// (the header's sidebar button shows it). A session that ends shows its ended card (SessionsViews), not the dead
// window; Show Output attaches to what the agent left on screen.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class PaneState: ObservableObject {
    @Published var job: String?
    @Published var attach: AttachState = .none
    @Published var listShown = true
    @Published var finishing: String?           // job whose worktree result is being reviewed (sheet)
    /// The ended session whose output the user asked to see (Show Output): its dead window stays attached.
    var outputShown: String?
}

@MainActor
final class SessionsPaneController: NSViewController, @preconcurrency TerminalPaneHosting {
    let state = PaneState()
    let model = SessionsModel.shared
    let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    private let split = NSSplitView()
    private var listHost: NSHostingView<SessionsList>!
    private weak var overlay: NSView?
    private var token: UUID?
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
                                                        newSession: { TerminalHost.shared.newSession(project: nil, items: []) }))
        let detail = NSView()
        let header = NSHostingView(rootView: SessionHeader(model: model, pane: state, actions: self))
        let overlay = NSHostingView(rootView: SessionOverlay(model: model, pane: state, actions: self))
        self.overlay = overlay
        for v in [header, surface, overlay] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            surface.topAnchor.constraint(equalTo: header.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 10),
            surface.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -4),
            surface.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -6),
            overlay.topAnchor.constraint(equalTo: header.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        // the pane takes whatever size its host gives it: SwiftUI's ideal sizes must not shrink the window
        listHost.sizingOptions = []
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
        listHost.isHidden = !state.listShown
        view = split
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
        if state.listShown { split.setPosition(250, ofDividerAt: 0) }
        if state.job == nil { attach(job: nil) }
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
            listHost.isHidden = !state.listShown
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
        // The agent ended: say how (the ended card: its reason, Review Changes… or Restart), not tmux's dead window.
        // The window stays readable (remain-on-exit) behind Show Output — until it is gone (merged, discarded,
        // restarted, ended with --kill), when a grouped view session would slide onto another session's window.
        let windowGone = j.state == .cancelled || ["merge", "discard", "restart"].contains(j.agent?.finishAction ?? "")
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
        a.messageText = TL("end.title")
        a.informativeText = TL("end.body")
        a.addButton(withTitle: TL("end.confirm"))
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
    static func set(_ pane: String, _ job: String) {
        var o = read()
        var p = o["panes"] as? [String: String] ?? [:]
        guard p[pane] != job else { return }
        p[pane] = job
        o["panes"] = p
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
}
