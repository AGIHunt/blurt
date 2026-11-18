// A recording's row (BlurtCore Recordings; docs/design/capabilities.md §4): on Home's Recent (HomeViews) and at the
// top of an items' place, above the jobs section — where its organising job's row used to be (one recording, one row).
// Its glyph, its length, the first thing said in it (else 未命名录屏), its state word (N 个事项 / 未整理 / 整理中 /
// 未完成 / 仅保存视频; the why in its tooltip), its time. The click and the menu do what fits the state: play the video, show it in Finder, organise or
// retry it — or, with no agent to do it, Set Up an Agent… / copy what to say to one —, its items, Dismiss a failure.
// The Windows/Linux app's Recordings.tsx says the same in the same places.
import AppKit
import BlurtCore

@MainActor
enum RecordingLook {
    /// An agent can organise in the background (AgentHub's cached check, as Home's Recording row asks; nil: not known
    /// yet). `refresh` asks again.
    private(set) static var agent: Bool?
    static func refresh(_ done: (() -> Void)? = nil) {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let t = env["BLURT_TEST_AGENTS"] { agent = t != "none"; done?(); return }
        if env["BLURT_TEST_PROCESS"] != nil { agent = true; done?(); return }
        let hub = AgentHub.shared
        hub.check(hub.order()) { st in
            let ok = st.contains { $0.state.usable }
            DispatchQueue.main.async { MainActor.assumeIsolated { agent = ok; done?() } }
        }
    }

    /// The take being recorded now: not a recording yet.
    nonisolated static var live: URL? { JobStore.shared.active.first { $0.type == .record }?.session }

    /// The newest recordings with their state.
    static func rows(_ reader: IndexReader?, limit: Int = 40) -> [Recordings.Row] {
        guard Capability.recording.isOn, let reader else { return [] }
        return Recordings.rows(Recordings.load(reader, live: live, limit: limit), jobs: JobStore.shared.jobs)
    }

    static func length(_ r: Recordings.Row) -> String {
        r.facts.duration.map { DictationHistoryModel.duration($0) } ?? ""
    }

    /// The state word alone ("2 items", "Organizing", "Didn’t finish", "Video only", "Not organized"): what a row says,
    /// so the line beside it stays readable. The why is the row's tooltip and the detail's.
    static func stateText(_ r: Recordings.Row) -> String {
        switch r.state {
        case .items(let n): return TP("main.rec.items", n)
        case .organising: return T("main.rec.state.organising")
        case .failed: return T("main.rec.state.failed")
        case .videoOnly: return T("main.rec.state.video_only")
        case .unorganised: return T("main.rec.state.unorganised")
        }
    }

    /// What the state word leaves out (the row's tooltip): the step under way, a failure's whole sentence, the video gone.
    static func stateDetail(_ r: Recordings.Row) -> String? {
        var parts: [String] = []
        if case .organising(_, let step) = r.state, let w = step.map({ T("job.step.\($0)") }) { parts.append(w) }
        if let w = why(r) { parts.append(w) }
        if r.facts.video == nil { parts.append(T("main.rec.video_gone")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the row says: the first thing said in it, else "Untitled recording" (a take with no speech).
    static func line(_ r: Recordings.Row) -> String { r.facts.firstLine ?? T("main.rec.untitled") }

    /// A failure's reason in a few words, for the codes whose sentence is short (Recordings.shortWhy): the job error's
    /// sentence without its full stop ("The agent isn’t signed in"); the rest say only "Didn’t finish" on the row.
    static let whyKey: [String: String] = [
        "no_agent": "main.rec.why.no_agent", "auth": "main.job.error.auth", "network": "main.job.error.network",
        "quota": "main.job.error.quota", "model": "main.job.error.model", "agent_exit": "main.job.error.agent_exit",
    ]

    /// The whole sentence of a failure (the row's tooltip).
    static func why(_ r: Recordings.Row) -> String? {
        guard case .failed(let id, _) = r.state, let j = JobStore.shared.job(id) else { return nil }
        return JobLook.errorText(j)
    }

    /// "Recording · 3:12 · 2 items": Home's quiet line over the first thing said.
    static func source(_ r: Recordings.Row) -> String {
        [T("main.rec.kind"), length(r), stateText(r)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `r`: the row it's for — a failure's run is its details, not its progress.
    static func label(_ a: Recordings.Action, _ r: Recordings.Row? = nil) -> String {
        switch a {
        case .review: return T("main.rec.review")
        case .progress:
            if let r, case .failed = r.state { return T("main.rec.show_details") }
            return T("main.banner.show_progress")
        case .play: return T("main.rec.play")
        case .reveal: return T("action.reveal_in_finder")
        case .organise: return T("main.rec.organise")
        case .retry: return T("action.retry")
        case .setUpAgent: return T("home.recording.set_up_agent")
        case .copyRequest: return T("main.rec.copy_request", Loc.t("agents.request", table: "Agents"))
        case .dismiss: return T("main.job.dismiss")
        }
    }

    static func symbol(_ a: Recordings.Action) -> String? {
        switch a {
        case .play: return "play"
        case .reveal: return "folder"
        case .review: return "rectangle.stack"
        case .organise: return "sparkles"
        case .retry: return "arrow.clockwise"
        case .copyRequest: return "doc.on.doc"
        default: return nil
        }
    }

    /// The recording a process job organises, with its state (the window's list of recordings, else its folder); nil:
    /// not a recording's run (cards, AI fill-in).
    static func row(of j: Job) -> Recordings.Row? {
        guard j.type == .process, let s = j.session else { return nil }
        let path = s.standardizedFileURL.path
        let name = s.lastPathComponent
        var f = MainWindowController.shared.model.recordingFacts.first { URL(fileURLWithPath: $0.dir).standardizedFileURL.path == path }
        if f == nil, !name.hasSuffix("-shots"), !name.hasSuffix("-voice") {
            let video = s.appendingPathComponent("recording.mp4")
            let meta = (try? Data(contentsOf: s.appendingPathComponent("meta.json")))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let has = FileManager.default.fileExists(atPath: video.path)
            guard has || meta["duration"] != nil else { return nil }
            f = Recordings.Facts(dir: s.path, projectID: j.project ?? "inbox", duration: meta["duration"] as? Double,
                                 video: has ? video : nil, firstLine: Recordings.firstLine(s),
                                 videoOnly: meta["video_only"] as? Bool ?? false)
        }
        guard let f else { return nil }
        return Recordings.rows([f], jobs: JobStore.shared.jobs).first
    }

    /// A recording's run in the detail: "Recording · 3:12 · what was said first".
    static func detailTitle(_ r: Recordings.Row) -> String {
        [T("main.rec.kind"), length(r), r.facts.firstLine ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A failure's sentence in the detail, as things are now: a run that found no agent, with one usable now, says only
    /// that (the fix it named is done); the rest as the job says.
    static func failureText(_ j: Job) -> String? {
        if j.error?.code == "no_agent", agent == true { return T("main.rec.why.no_agent_then") }
        return JobLook.errorText(j)
    }

    /// A click on Home's row: a failure opens its detail (the run's words and its way forward, Play Video, Show in
    /// Finder) in its place — never Settings; the rest do their first action.
    static func homeAction(_ r: Recordings.Row, agent: Bool?) -> Recordings.Action? {
        if case .failed = r.state { return .progress }
        return Recordings.actions(r, agent: agent).first
    }

    /// Does an action (a row's click, its button, its menu).
    static func run(_ a: Recordings.Action, _ r: Recordings.Row) {
        emit(["event": "recording", "action": a.rawValue, "session": r.facts.dir, "state": r.state.name])
        let w = MainWindowController.shared
        switch a {
        case .review: w.reveal(session: r.facts.url)
        case .progress: if let j = r.state.job { w.reveal(job: j) }
        case .play: if let v = r.facts.video { NSWorkspace.shared.open(v) }
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([r.facts.video ?? r.facts.url])
        case .organise, .retry:
            // AgentHub's own entry point (one organiser per recording, whatever asks); the detail follows the new run
            // when the failed one was on show
            let project = r.facts.projectID == "inbox" ? nil : r.facts.projectID
            let shown = w.shownJob != nil && w.shownJob == r.state.job
            if let new = AppEnvironment.process?(r.facts.url, nil, project) ?? nil {
                JobStore.shared.rescan()
                if shown { w.selectJob(new) }
            }
        case .setUpAgent: AppEnvironment.settings?.show(pane: SettingsPane.agents.rawValue)
        case .copyRequest:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Loc.t("agents.request", table: "Agents"), forType: .string)
            (NSApp.delegate as? App)?.toast(T("main.rec.request_copied"), icon: .check)
        case .dismiss:
            guard let id = r.state.job, let j = JobStore.shared.job(id) else { return }
            w.jobAction("dismiss", job: j)
        }
    }

    /// The row's menu: the click's action first, Dismiss last on its own.
    static func menu(_ r: Recordings.Row, agent: Bool?) -> NSMenu {
        let m = NSMenu()
        let acts = Recordings.actions(r, agent: agent)
        for a in acts {
            if a == .dismiss, m.numberOfItems > 0 { m.addItem(.separator()) }
            let i = MenuAction(title: label(a, r)) { run(a, r) }
            if let s = symbol(a) { i.image = Look.symbol(s, label(a, r), size: 13) }
            m.addItem(i)
        }
        return m
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let go: () -> Void
    init(title: String, _ go: @escaping () -> Void) {
        self.go = go
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { go() }
}

/// The recordings at the top of an items' place: a header "Recordings 2" (a click folds them), then a row each on the
/// list's grid.
final class RecordingsSection: NSView {
    /// a row clicked: its job when it has one (the detail shows it), else its first action
    var onSelect: ((Recordings.Row) -> Void)?
    private let stack = NSStackView()
    private let header = GridLabel()
    private var rows: [String: RecordingRow] = [:]
    private var expanded = true
    private var last: [Recordings.Row] = []
    private var resizeObserver: NSObjectProtocol?

    /// the job the detail shows: its recording's row stays highlighted
    var selected: String? { didSet { rows.forEach { $0.value.selected = $0.value.row?.state.job.map { $0 == selected } ?? false } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        resizeObserver = NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stack.arrangedSubviews.forEach { $0.needsLayout = true } }
        }
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { resizeObserver.map(NotificationCenter.default.removeObserver) }

    @objc func toggle() {
        expanded.toggle()
        set(last)
    }

    override func layout() {
        super.layout()
        stack.arrangedSubviews.forEach { $0.needsLayout = true; $0.needsDisplay = true }
    }

    func set(_ recs: [Recordings.Row], showProject: Bool = true) {
        last = recs
        isHidden = recs.isEmpty
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !recs.isEmpty else { return }
        let text = NSMutableAttributedString(string: T("main.rec.section"), attributes: [.font: Look.sectionFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  " + Loc.number(recs.count), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        if let ch = Look.symbol(expanded ? "chevron.down" : "chevron.right", "", size: 9, weight: .semibold) {
            let a = NSTextAttachment()
            a.image = ch
            a.bounds = NSRect(x: 0, y: 0, width: ch.size.width, height: ch.size.height)
            text.append(NSAttributedString(string: "  "))
            text.append(NSAttributedString(attachment: a))
        }
        header.label.attributedStringValue = text
        setAccessibilityLabel(T("main.rec.section") + " " + Loc.number(recs.count))
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        var keep: [String: RecordingRow] = [:]
        for r in expanded ? recs : [] {
            let v = rows[r.facts.dir] ?? RecordingRow()
            v.set(r, project: showProject ? (r.facts.projectID == "inbox" ? T("project.inbox") : r.facts.projectName) : nil)
            v.onClick = { [weak self] in self?.onSelect?(r) }
            v.selected = r.state.job.map { $0 == selected } ?? false
            keep[r.facts.dir] = v
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rows = keep
    }
}

/// One recording on the list's grid (JobRow's): the video glyph, its length and the first thing said in the title
/// column, its state where the times start (a failure in the attention ink, with its one action), a spinner or a
/// warning in the ring's column. Right-click: its menu.
final class RecordingRow: NSView {
    var onClick: (() -> Void)?
    private(set) var row: Recordings.Row?
    private let icon = NSImageView()
    private let mark = NSImageView()
    private let spinner = TrackedSpinner(size: 14)
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let act = NSButton(title: "", target: nil, action: nil)
    private var inline: Recordings.Action?
    private var hover = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
    private var grid = ListGrid()

    init() {
        super.init(frame: .zero)
        title.font = Look.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        status.font = Look.subFont
        status.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleNone
        mark.imageScaling = .scaleNone
        act.isBordered = false
        act.font = .systemFont(ofSize: 11, weight: .semibold)
        act.contentTintColor = BrandColor.ink
        act.target = self
        act.action = #selector(tapInline)
        for v in [icon, mark, spinner, title, status, act] as [NSView] { addSubview(v) }
        heightAnchor.constraint(equalToConstant: Look.rowHeight).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ r: Recordings.Row, project: String?) {
        row = r
        let line = RecordingLook.line(r)
        let t = NSMutableAttributedString()
        let len = RecordingLook.length(r)
        if !len.isEmpty {
            t.append(NSAttributedString(string: len + "  ", attributes: [.font: Look.monoSub, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        t.append(NSAttributedString(string: line, attributes: [.font: Look.titleFont,
                                                                .foregroundColor: r.facts.firstLine == nil ? NSColor.secondaryLabelColor : NSColor.labelColor]))
        title.attributedStringValue = t
        title.toolTip = r.facts.firstLine
        let failed: Bool = { if case .failed = r.state { return true } else { return false } }()
        status.stringValue = RecordingLook.stateText(r)
        status.textColor = failed ? BrandColor.attnInk : .secondaryLabelColor
        status.toolTip = RecordingLook.stateDetail(r)
        toolTip = RecordingLook.stateDetail(r)
        // Set Up an Agent… isn't drawn on the row: its detail (the job's) has it, and so does its menu
        inline = Recordings.inline(r, agent: RecordingLook.agent).flatMap { $0 == .setUpAgent ? nil : $0 }
        act.title = inline.map { RecordingLook.label($0, r) } ?? ""
        act.isHidden = inline == nil
        icon.image = Look.symbol("video", T("main.rec.kind"), size: 13)
        icon.contentTintColor = .secondaryLabelColor
        if case .organising = r.state { spinner.startAnimation() } else { spinner.stopAnimation() }
        mark.image = failed ? Look.symbol("exclamationmark.triangle.fill", T("main.rec.state.failed"), size: 12) : nil
        mark.contentTintColor = BrandColor.attnInk
        needsLayout = true
        setAccessibilityLabel([line, status.stringValue].joined(separator: ", "))
    }

    @objc private func tapInline() {
        if let a = inline, let r = row { RecordingLook.run(a, r) }
    }

    override func layout() {
        super.layout()
        grid = ListGrid.of(self)
        let h = bounds.height
        icon.frame = NSRect(x: grid.icon, y: (h - 18) / 2, width: 18, height: 18)
        if let ring = grid.ring {
            spinner.frame = NSRect(x: ring - 7, y: (h - 14) / 2, width: 14, height: 14)
            mark.frame = NSRect(x: ring - 9, y: (h - 18) / 2, width: 18, height: 18)
        } else {
            spinner.frame = NSRect(x: grid.icon + 2, y: (h - 14) / 2, width: 14, height: 14)
            mark.frame = icon.frame
            icon.isHidden = !spinner.isHidden || mark.image != nil
        }
        let aw = act.isHidden ? 0 : ceil(act.intrinsicContentSize.width)
        act.frame = NSRect(x: grid.trailing - aw, y: (h - 18) / 2, width: aw, height: 18)
        // the state word where the times start, before the action; the line keeps at least `minTitle` (a state never
        // takes the row from what was said)
        let room = (act.isHidden ? grid.trailing : act.frame.minX - 8)
        let minTitle: CGFloat = 140
        let sw = min(ceil(status.intrinsicContentSize.width) + 4, max(0, room - grid.title - 12 - minTitle))
        let sh = status.intrinsicContentSize.height
        let sx = min(grid.time ?? .greatestFiniteMagnitude, room - sw)
        status.frame = NSRect(x: sx, y: (h - sh) / 2, width: sw, height: sh)
        let th = title.intrinsicContentSize.height
        title.frame = NSRect(x: grid.title, y: (h - th) / 2, width: max(0, status.frame.minX - 12 - grid.title), height: th)
        window?.invalidateCursorRects(for: self)
    }

    private var wash: NSRect {
        let lo = max(0, grid.washMin), hi = min(bounds.width, grid.washMax > grid.washMin ? grid.washMax : bounds.width)
        return NSRect(x: lo, y: 0, width: max(0, hi - lo), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover || selected else { return }
        let key = window?.isKeyWindow == true && NSApp.isActive || BrandRowView.testKeyLook
        (selected && key ? BrandColor.tint : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: wash, xRadius: 6, yRadius: 6).fill()
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), !act.frame.contains(p) { onClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { row.map { RecordingLook.menu($0, agent: RecordingLook.agent) } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(wash, cursor: .pointingHand) }
}
