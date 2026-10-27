// One embedded terminal (SwiftTerm) showing one agent session.
//   tmux runner: runs `sessions.py attach-cmd JOB`'s argv in a pty — a tmux client on the private socket, attached to a
//     grouped view session of its own (destroy-unattached), so every pane picks its window independently and closing
//     the pane or the app only ends that client; the agent keeps running and the next attach shows it again.
//   app runner (no tmux): the session's pty belongs to AppRunner for the session's whole life; the surface borrows its
//     view while it is shown.
//   desktop (the agent's desktop app): nothing to attach — the pane shows the desktop card (state .desktop).
import AppKit
import SwiftUI
import SwiftTerm
import BlurtCore

typealias SwiftTermColor = SwiftTerm.Color

/// LocalProcessTerminalView with Blurt's type, colours and behaviour.
final class BlurtTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = TerminalTheme.font
        optionAsMetaKey = true
        bellStyle = .none                    // the session's status (and SessionNotifier) says when it needs you
        allowMouseReporting = true           // tmux: mouse on (scroll, select a pane)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let p = TerminalTheme.palette(for: effectiveAppearance)
        nativeForegroundColor = p.foreground
        nativeBackgroundColor = p.background
        caretColor = p.caret
        selectedTextBackgroundColor = p.selection
        installColors(TerminalTheme.swiftTermColors(p))
        layer?.backgroundColor = p.background.cgColor
    }

    /// Links the agent prints (file paths, PR urls) open in their apps — http(s) and file only.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let u = URL(string: link), ["http", "https", "file"].contains(u.scheme ?? "") else { return }
        NSWorkspace.shared.open(u)
    }
}

/// What a pane's terminal is doing, for its header and overlay.
enum AttachState: Equatable {
    case none                    // nothing selected (no sessions)
    case connecting
    case attached
    case detached                // the tmux client ended while the session lives on
    case ended                   // the session itself is over
    case elsewhere               // an app-runner session already shown in another pane
    case desktop                 // it runs in the agent's desktop app: no terminal here
    case failed(String)
}

@MainActor
final class TerminalSurface: NSView, LocalProcessTerminalViewDelegate {
    private(set) var job: String?
    private(set) var state: AttachState = .none { didSet { if state != oldValue { onState?(state) } } }
    var onState: ((AttachState) -> Void)?
    private(set) var term: BlurtTerminalView?
    private var borrowed = false               // term belongs to AppRunner
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.palette(for: effectiveAppearance).background.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = TerminalTheme.palette(for: effectiveAppearance).background.cgColor
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let t = term { return window?.makeFirstResponder(t) ?? false }
        return true
    }

    /// Show `job` (nil = nothing). Re-attaching the job already shown is a no-op unless it detached. A session that
    /// has ended shows its ended card (state .ended); `output` attaches to what it left on screen instead.
    func attach(_ job: String?, force: Bool = false, output: Bool = false) {
        if job == self.job, !force, [.attached, .connecting, .elsewhere].contains(state) { return }
        detach()
        self.job = job
        guard let job = job else { state = .none; return }
        guard let j = JobStore.shared.job(job), let a = j.agent else { state = .failed(TL("error.no_job")); return }
        if a.isDesktop, j.isActive { state = .desktop; return }
        if !j.isActive, !output { state = .ended; return }
        if a.runner == "app" {
            guard let v = AppRunner.shared.view(for: job) else { state = j.isActive ? .failed(TL("error.app_runner_lost")) : .ended; return }
            guard v.superview == nil || v.superview === self else { state = .elsewhere; return }
            install(v, borrowed: true)
            state = AppRunner.shared.isRunning(job) ? .attached : .ended
            return
        }
        let windowGone = j.state == .cancelled || ["merge", "discard", "take_back"].contains(a.finishAction ?? "")
        guard j.isActive || (a.tmuxWindow != nil && !windowGone) else { state = .ended; return }
        state = .connecting
        generation += 1
        let gen = generation
        Task { @MainActor in
            do {
                let cmd = try await AgentSessions.shared.attachCommand(job: job)
                guard gen == self.generation, self.job == job else { return }
                let t = BlurtTerminalView(frame: self.bounds)
                t.processDelegate = self
                self.install(t, borrowed: false)
                t.startProcess(executable: Self.resolve(cmd.argv[0]), args: Array(cmd.argv.dropFirst()),
                               environment: Self.environment(cmd.env), execName: nil, currentDirectory: NSHomeDirectory())
                self.state = .attached
                self.window?.makeFirstResponder(t)
            } catch {
                guard gen == self.generation else { return }
                let ended = !(JobStore.shared.job(job)?.isActive ?? false)
                self.state = ended ? .ended : .failed(sessionsErrorText(error))
            }
        }
    }

    /// End this pane's tmux client (the session keeps running) or hand an app-runner view back.
    func detach() {
        generation += 1
        if let t = term {
            if borrowed {
                t.removeFromSuperview()
            } else {
                t.processDelegate = nil
                if t.process.running { t.terminate() }
                t.removeFromSuperview()
            }
        }
        term = nil
        borrowed = false
    }

    /// The text's margin inside the surface (the surface itself runs to the window's edges in the terminal's colour).
    static let margin = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)

    private func install(_ t: BlurtTerminalView, borrowed: Bool) {
        term = t
        self.borrowed = borrowed
        let m = Self.margin
        t.frame = NSRect(x: m.left, y: m.bottom, width: max(0, bounds.width - m.left - m.right),
                         height: max(0, bounds.height - m.top - m.bottom))
        t.autoresizingMask = [.width, .height]
        addSubview(t)
        // tmux keeps the scrollback (the mouse scrolls it): SwiftTerm's own scroller would only be a still track at the
        // edge. A borrowed app-runner view keeps it — its scrollback is SwiftTerm's.
        if !borrowed { for case let sc as NSScroller in t.subviews { sc.isHidden = true } }
    }

    /// The pty's environment: the user's login environment plus what attach-cmd asked for, in a UTF-8 locale (tmux
    /// replaces anything non-ASCII with "_" otherwise) with a 256-colour / true-colour terminal.
    static func environment(_ extra: [String: String]) -> [String] {
        var env = ShellEnv.agentEnvironment().merging(extra) { _, n in n }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Blurt"
        let utf8 = ["LC_ALL", "LC_CTYPE", "LANG"].contains { (env[$0] ?? "").uppercased().contains("UTF-8") || (env[$0] ?? "").uppercased().contains("UTF8") }
        if !utf8 { env["LC_CTYPE"] = "UTF-8"; env["LANG"] = env["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8" }
        env.removeValue(forKey: "TMUX")         // never nest inside a tmux the app itself was started from
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// "tmux" → /opt/homebrew/bin/tmux (forkpty + exec doesn't search PATH).
    static func resolve(_ exe: String) -> String {
        exe.hasPrefix("/") ? exe : (ShellEnv.findExecutable(exe) ?? exe)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, source === self.term else { return }
                let alive = self.job.flatMap { JobStore.shared.job($0) }?.isActive ?? false
                self.state = alive ? .detached : .ended
            }
        }
    }
}

// MARK: - App runner

/// Sessions sessions.py could not put in tmux (`--runner app`, no tmux): the app runs the agent in its own pty and
/// reports the exit back. They end when the app quits — the UI says so.
@MainActor
final class AppRunner: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = AppRunner()
    private var views: [String: BlurtTerminalView] = [:]
    private var exited = Set<String>()

    func view(for job: String) -> BlurtTerminalView? { views[job] }
    func isRunning(_ job: String) -> Bool { views[job] != nil && !exited.contains(job) }
    var hasLive: Bool { views.keys.contains { !exited.contains($0) } }

    func launch(_ l: AppLaunch) {
        let t = BlurtTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        t.processDelegate = self
        views[l.job] = t
        var env = TerminalSurface.environment(l.env)
        env.append("BLURT_RUNNER=app")
        t.startProcess(executable: TerminalSurface.resolve(l.argv[0]), args: Array(l.argv.dropFirst()), environment: env,
                       execName: nil, currentDirectory: l.cwd.path)
    }

    func terminateAll() {
        for (_, t) in views where t.process.running { t.terminate() }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let (job, _) = self.views.first(where: { $0.value === source }) else { return }
                self.exited.insert(job)
                Task { await AgentSessions.shared.reportExit(job: job, status: exitCode ?? -1) }
            }
        }
    }
}
