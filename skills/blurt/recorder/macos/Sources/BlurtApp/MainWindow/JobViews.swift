// Jobs in the main window (K4): the "Running" section above the list ("In Progress" is the items' place) — one row per
// running job on the item rows' grid (kind icon, the spinner in the state ring's column, title, how far in the time
// column; agent sessions with their status), plus organising that failed in the last week until it is retried or
// dismissed (JobFailures) — and the detail page of a job: what it does to what and when it started, one control (Stop,
// ⌘., while it runs; Try Again when it failed) with ⋯ for Show Log / Show in Finder / Dismiss, one progress bar with
// the elapsed time, its steps in an inset group with each one's time, the items written so far; its reason in words
// (JobError.reason, else the code's sentence — never the raw message), who organised it when another agent stood in.
// An agent session's detail is its title and status line, then its terminal pane (whose header carries Stop, Open in
// Terminal, Show Log…): no steps above it. Nothing here opens anything by itself: rows are clicked.
import AppKit
import BlurtCore

enum JobLook {
    /// "Organising · Pricing walkthrough", "Claude Code · BA-12, BA-13"
    static func title(_ j: Job) -> String {
        let what: String
        if j.type == .agent, let a = j.agent {
            what = AgentNames.name(a.agent)
        } else {
            what = T("job.type.\(j.type.rawValue)")
        }
        // AI fill-in: a process job without a capture batch — its own title says what it is ("Organizing · AI
        // fill-in" said it twice, and wrongly)
        if j.type == .process, j.session == nil, let t = j.title, !t.isEmpty { return t }
        let detail = j.title ?? j.agent?.windowName.map { $0.replacingOccurrences(of: ",", with: ", ") } ?? j.session.map { sessionLabel($0) }
        return detail.map { "\(what) · \($0)" } ?? what
    }

    /// The quit alert's title for one organising run: "口喷鸡还在整理「Pricing walkthrough」。", or by when it was
    /// captured ("口喷鸡还在整理今天 19:40 的内容。") — never the job's own title, which starts with "整理" again.
    static func quitTitle(_ j: Job) -> String {
        if let s = j.session, let t = batchTitle(s) { return T("app.quit.organizing.title", t) }
        if let s = j.session { return T("app.quit.organizing.title_at", sessionLabel(s)) }
        return T("app.quit.organizing.title_n", 1)
    }

    /// A session dir's batch title (batch.json, then meta.json).
    static func batchTitle(_ dir: URL) -> String? {
        for f in ["batch.json", "meta.json"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["title"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// A session dir's batch title, else its time stamp as a date.
    static func sessionLabel(_ dir: URL) -> String {
        if let t = batchTitle(dir) { return t }
        let name = dir.lastPathComponent
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        // never the folder's own name: when it was made, else just "a capture"
        let made = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.creationDate]) as? Date
        return (f.date(from: String(name.prefix(15))) ?? made).map(Loc.dateTime) ?? T("main.job.capture")
    }

    /// A failed job's reason in words, naming its agent when it has one: the detail and the failure notification say
    /// the same thing.
    static func errorText(_ j: Job) -> String? {
        j.error.map { errorText($0, agent: (j.agent?.agent ?? j.usage?.agent).map(AgentNames.name)) }
    }

    /// A failed job's reason in words: its hint, else the sentence composed when it failed (which agent, why, the fix
    /// or advice), else the code's sentence ("Claude Code isn’t signed in." when the agent is known), else a generic
    /// one. Never the raw message: that stays in the log (Show Log).
    static func errorText(_ e: JobError, agent: String?) -> String {
        if let h = e.hintKey { return T(h) }
        if let r = e.reason { return r }
        let key = Loc.has("main.job.error.\(e.code)", table: "Main") ? "main.job.error.\(e.code)" : "main.job.error.unknown"
        if let a = agent, Loc.has(key + ".named", table: "Main") { return T(key + ".named", a) }
        return T(key)
    }

    /// What it is doing now: a session in the session list's words (AgentSessionRow.stateText), else the current step.
    static func status(_ j: Job) -> String {
        if j.agent != nil { return AgentSessionRow.stateText(j) }
        if j.state == .failed { return T("job.state.failed") }
        if let s = j.currentStep { return T("job.step.\(s.id)") }
        return T("job.state.\(j.state.rawValue)")
    }

    static func statusColor(_ j: Job) -> NSColor {
        if j.state == .failed || j.agent?.status == .error { return BrandColor.err }
        if j.agent?.status == .waitingInput { return BrandColor.attnInk }
        return .secondaryLabelColor
    }

    static func symbol(_ j: Job) -> String {
        switch j.type {
        case .record: return "record.circle"
        case .snap: return "camera.viewfinder"
        case .voice: return "waveform"
        case .process: return "sparkles"
        case .route: return "arrow.triangle.branch"
        case .agent: return "apple.terminal"
        }
    }
}

extension JobLook {
    /// The steps a job shows, in order. AI fill-in has no recording to transcribe, no frames to cut, nothing to file:
    /// just prepare and write.
    static func steps(_ j: Job) -> [JobStep] {
        var s = j.steps.isEmpty ? (jobSteps[j.type] ?? []).map { JobStep(id: $0, state: .pending) } : j.steps
        if j.type == .process, j.session == nil { s = s.filter { !["transcribe", "frames", "route"].contains($0.id) } }
        return s
    }

    /// How far a running job is, 0…1: what it reports, else its steps (the running one's own share counted in). The
    /// list row and the detail say this one number. nil for an agent session or a job that isn't running.
    static func fraction(_ j: Job) -> Double? {
        guard j.isActive, j.type != .agent else { return nil }
        if let p = j.progress { return min(max(p, 0), 1) }
        let s = steps(j)
        guard !s.isEmpty else { return nil }
        let done = Double(s.filter { $0.state == .done || $0.state == .skipped }.count)
        let part = s.first { $0.state == .running }?.progress ?? 0
        return min((done + part) / Double(s.count), 1)
    }

    /// What it is doing now, as a status ("Preparing…", "正在写入条目…"): the step's name reads as a heading, this as
    /// what is happening.
    static func doing(_ j: Job) -> String {
        guard j.agent == nil, j.isActive, let s = j.currentStep else { return status(j) }
        switch s.id {
        case "prepare": return T("main.job.doing.prepare")
        case "transcribe": return T("main.job.doing.transcribe")
        case "write": return T("main.job.doing.write")
        case "frames": return T("main.job.doing.frames")
        default: return T("job.step.\(s.id)")
        }
    }

    /// The list row's right-hand text: how far (one number) while it runs, else its status.
    static func rowStatus(_ j: Job) -> String {
        if j.agent == nil, j.isActive { return fraction(j).map { Loc.percent($0) } ?? doing(j) }
        return status(j)
    }

    /// The detail's title: what the job does to what — "Organizing “Checkout walkthrough”", else the row's title.
    static func detailTitle(_ j: Job) -> String {
        if j.type == .process, let s = j.session {
            if let t = batchTitle(s) { return T("main.job.title.organizing", t) }
            return T("main.job.title.organizing_at", sessionLabel(s))
        }
        return title(j)
    }

    /// The agent organising a recording, from its meta.json (AgentHub writes it when the run starts): "Claude Code".
    static func agentName(_ j: Job) -> String? {
        guard let dir = j.session, let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["agent"] as? [String: Any], a["job"] as? String == j.id else { return nil }
        return a["name"] as? String ?? (a["id"] as? String).map(AgentNames.name)
    }

    /// A run's time as a clock: 0:42, 12:05, 1:02:03 — no leading zero on the first figure (Loc.duration pads it).
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.rounded())), h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The user stopped it (Stop in the detail): said as a stop, never as a failure.
    static func stopped(_ j: Job) -> Bool { j.state == .cancelled }

    /// When each step started and ended (the job's raw steps).
    static func stepTimes(_ j: Job) -> [String: (start: Date?, end: Date?)] {
        var out: [String: (start: Date?, end: Date?)] = [:]
        for s in j.raw["steps"] as? [[String: Any]] ?? [] {
            if let id = s["id"] as? String { out[id] = (JobFold.date(s["started"]), JobFold.date(s["ended"])) }
        }
        return out
    }
}

/// Stop for an organising run (the detail's Stop, ⌘.): the job is marked cancelled for everyone at once (an event
/// line, like any other reporter), and the agent's process group is stopped — now, or the moment it starts if the
/// run is still preparing. The run's own end then keeps it stopped (JobFold.finishing).
enum JobStop {
    private static var stopping: Set<String> = []
    private static var token: UUID?

    static func canStop(_ j: Job) -> Bool { j.isActive && (j.type == .process || j.type == .route) }

    static func stop(_ j: Job) {
        guard canStop(j) else { return }
        JobFiles.appendEvent(j.id, ["event": "stop", "state": JobState.cancelled.rawValue, "source": "user"])
        stopping.insert(j.id)
        if token == nil { token = JobStore.shared.addObserver { _ in sweep() } }
        JobStore.shared.rescan()
        sweep()
        emit(["event": "job_stop", "job": j.id])
    }

    /// Every stopped run whose agent is (still, or by now) running: stop its group. A run whose owner has closed it
    /// is done with.
    private static func sweep() {
        for id in stopping {
            guard let j = JobStore.shared.job(id), j.ended == nil else { stopping.remove(id); continue }
            guard let g = appDelegate?.organisers[id] else { continue }
            DispatchQueue.global(qos: .userInitiated).async { ProcessGroup.stop(g) }
        }
    }
}

// MARK: - The list's running section

/// Where the list's columns are, in a view's own coordinates, so a job row or a header above the table sits on the
/// item rows' grid: the kind icon, the state ring, the title, the time column, the selection's edges.
struct ListGrid {
    var icon: CGFloat = 8, ring: CGFloat? = nil, title: CGFloat = 34, trailing: CGFloat = 8
    /// where the time column's text starts (its cell sets it from the left)
    var time: CGFloat? = nil
    var washMin: CGFloat = 0, washMax: CGFloat = 0

    static func of(_ v: NSView) -> ListGrid {
        var g = ListGrid(trailing: v.bounds.width - 8, washMin: 0, washMax: v.bounds.width)
        guard let t = table(near: v) else { return g }
        func col(_ id: String) -> NSRect? {
            let i = t.column(withIdentifier: .init(id))
            guard i >= 0, !t.tableColumns[i].isHidden else { return nil }
            return t.convert(t.rect(ofColumn: i), to: v)
        }
        guard let lead = col("lead"), let title = col("title") else { return g }
        g.icon = lead.minX + 2                                  // LeadCell: the icon 2 in, 18 wide; the ring 3 after it
        g.ring = lead.width >= 40 ? lead.minX + 2 + 18 + 3 + 10 : nil
        g.title = title.minX + 2                                // TitleCell: the title 2 in
        g.trailing = (col("time") ?? col("meta")).map { $0.maxX - 2 } ?? g.trailing
        g.time = col("time").map { $0.minX + 2 }
        // the selection as the table draws it (BrandRowView): its row view, inset like the inset style's rows
        if t.numberOfRows > 0, let rv = t.rowView(atRow: 0, makeIfNecessary: false) {
            let pad: CGFloat = rv.frame.minX < 1 && abs(rv.frame.width - t.bounds.width) < 1 ? 10 : 0
            let r = t.convert(rv.frame.insetBy(dx: pad, dy: 0), to: v)
            g.washMin = r.minX
            g.washMax = r.maxX
        } else {
            g.washMin = lead.minX - 6
            g.washMax = g.trailing + 8
        }
        return g
    }

    /// The item table beside a view above it (the list's own column).
    private static func table(near v: NSView) -> NSTableView? {
        var p = v.superview
        for _ in 0..<6 {
            guard let at = p else { return nil }
            for s in at.subviews {
                if let t = (s as? NSScrollView)?.documentView as? ItemTableView { return t }
            }
            p = at.superview
        }
        return nil
    }
}

/// The running jobs above the list. Hidden when there are none; at most four rows, then "N more".
final class JobsSection: NSView {
    var onSelect: ((String) -> Void)?
    private let stack = NSStackView()
    private let header = GridLabel()
    private var rows: [String: JobRow] = [:]
    private var resizeObserver: NSObjectProtocol?
    static let maxRows = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.label.font = .systemFont(ofSize: 11, weight: .semibold)
        header.label.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        // no rule under it: the filter strip below has its own
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // a column the user resizes, or the list's layout switching: the rows follow the grid
        resizeObserver = NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.regrid() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { resizeObserver.map(NotificationCenter.default.removeObserver) }

    private func regrid() {
        for v in stack.arrangedSubviews { v.needsLayout = true; v.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        regrid()
    }

    /// "In progress · 2", "In progress · 2 · 1 failed", "Failed · 1": the failures it lists (JobFailures) aren't in
    /// progress.
    static func headerText(_ jobs: [Job]) -> String {
        let failed = jobs.filter { !$0.isActive }.count, active = jobs.count - failed
        if active == 0 { return TP("main.jobs.header.failed_only", failed) }
        return TP("main.jobs.header", active) + (failed > 0 ? " · " + TP("main.jobs.failed", failed) : "")
    }

    /// The job the detail shows: its row stays highlighted.
    var selected: String? { didSet { rows.forEach { $0.value.selected = $0.key == selected } } }

    func set(_ jobs: [Job], store: ProjectStore, showProject: Bool = true) {
        isHidden = jobs.isEmpty
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !jobs.isEmpty else { return }
        header.label.stringValue = Self.headerText(jobs)
        setAccessibilityLabel(header.label.stringValue)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // what needs the user first: an agent waiting for an answer, then failures, then the rest by age
        let ordered = jobs.sorted { a, b in
            func rank(_ j: Job) -> Int { j.agent?.status == .waitingInput ? 0 : j.state == .failed ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.created > b.created
        }
        var keep: [String: JobRow] = [:]
        for j in ordered.prefix(Self.maxRows) {
            let r = rows[j.id] ?? JobRow()
            r.set(j, project: showProject ? j.project.flatMap { store.project(id: $0) }?.name : nil)
            r.onClick = { [weak self] in self?.onSelect?(j.id) }
            r.selected = j.id == selected
            keep[j.id] = r
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rows = keep
        if jobs.count > Self.maxRows {
            let more = GridLabel()
            more.label.stringValue = TP("main.jobs.more", jobs.count - Self.maxRows)
            more.label.font = .systemFont(ofSize: 11)
            more.label.textColor = .secondaryLabelColor
            more.onTitle = true
            stack.addArrangedSubview(more)
            more.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// A line of small text on the list's grid: the section header over the kind icon, "N more" in the title column.
final class GridLabel: NSView {
    let label = NSTextField(labelWithString: "")
    var onTitle = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let g = ListGrid.of(self)
        let x = onTitle ? g.title : g.icon
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, g.trailing - x), height: h)
    }
}

/// The brand arc (BrandSpinner: the one spinner) on a faint track ring, so at row size it reads as busy, not as a
/// stray "(". The list row and the running step use this one.
final class TrackedSpinner: NSView {
    let arc: BrandSpinner
    private let track = CAShapeLayer()
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        arc = BrandSpinner(size: size)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        track.fillColor = nil
        track.lineWidth = size >= 24 ? 2.25 : 1.75
        layer?.addSublayer(track)
        arc.frame = bounds
        arc.autoresizingMask = [.width, .height]
        arc.setAccessibilityElement(false)
        addSubview(arc)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func layout() {
        super.layout()
        track.frame = bounds
        track.path = CGPath(ellipseIn: bounds.insetBy(dx: track.lineWidth, dy: track.lineWidth), transform: nil)
        restroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restroke() }
    private func restroke() {
        effectiveAppearance.performAsCurrentDrawingAppearance { track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor }
    }

    func startAnimation() { isHidden = false; arc.startAnimation() }
    func stopAnimation() { arc.stopAnimation(); isHidden = true }
}

/// A flat progress bar (§3.3: ink in light, mint in dark), drawn here so it never turns grey when the window isn't key
/// the way the system's bar does. The track is the label colour at 10 %, so it reads on any wash.
final class FlatProgressBar: NSView {
    var value: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(Loc.percent(value)) } }
    var thickness: CGFloat = 4 { didSet { invalidateIntrinsicContentSize() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: thickness) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        let rad = thickness / 2
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
        let w = r.width * CGFloat(min(max(value, 0), 1))
        guard w > 0 else { return }
        BrandColor.ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(w, thickness), height: thickness), xRadius: rad, yRadius: rad).fill()
    }
}

/// One job on the list's grid, the height of an item row: its kind icon in the kind column, the spinner (or its
/// failure mark) in the state ring's, the title in the title column, how far it is in the time column. Selected: the
/// selection wash alone; working and not selected: the 1 pt brand hairline (§4) — never both on one row.
final class JobRow: NSView {
    var onClick: (() -> Void)?
    let icon = NSImageView()
    let mark = NSImageView()
    let spinner = TrackedSpinner(size: 14)
    let title = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    private var hover = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected); updateWorking() } }
    private let working = WorkingOutline(frame: .zero)
    private var aiWorking = false
    private var grid = ListGrid()

    init() {
        super.init(frame: .zero)
        working.cornerRadius = 6
        title.font = Look.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        status.font = Look.subFont
        status.textColor = .secondaryLabelColor
        status.alignment = .left           // placed where the times start (layout)
        icon.imageScaling = .scaleNone
        mark.imageScaling = .scaleNone
        for v in [icon, mark, spinner, title, status] as [NSView] { addSubview(v) }
        heightAnchor.constraint(equalToConstant: Look.rowHeight).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ j: Job, project: String?) {
        let name = JobLook.title(j)
        let t = NSMutableAttributedString(string: name, attributes: [.font: Look.titleFont, .foregroundColor: NSColor.labelColor])
        if let p = project {
            t.append(NSAttributedString(string: "  ·  \(p)", attributes: [.font: Look.titleFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        title.attributedStringValue = t
        status.stringValue = JobLook.rowStatus(j)
        status.textColor = JobLook.statusColor(j)
        status.font = j.agent == nil && JobLook.fraction(j) != nil ? Look.monoSub : Look.subFont
        let waiting = j.agent?.status == .waitingInput
        let busy = j.state == .running && j.type != .agent
        aiWorking = busy && (j.type == .process || j.type == .route)
        if aiWorking, working.superview == nil { addSubview(working) }
        updateWorking()
        icon.image = Look.symbol(waiting ? "exclamationmark.bubble" : JobLook.symbol(j), name, size: 13)
        icon.contentTintColor = waiting ? BrandColor.attn : .secondaryLabelColor
        busy ? spinner.startAnimation() : spinner.stopAnimation()
        spinner.setAccessibilityLabel(JobLook.doing(j))
        // a failure says so in the state column too, in the error colour (the words are on the right)
        mark.image = j.state == .failed ? Look.symbol("xmark.circle.fill", T("job.state.failed"), size: 13) : nil
        mark.contentTintColor = BrandColor.err
        needsLayout = true
        setAccessibilityLabel("\(name), \(status.stringValue)")
    }

    private func updateWorking() { working.set(active: aiWorking && !selected) }

    override func layout() {
        super.layout()
        grid = ListGrid.of(self)
        let h = bounds.height
        icon.frame = NSRect(x: grid.icon, y: (h - 18) / 2, width: 18, height: 18)
        if let ring = grid.ring {
            spinner.frame = NSRect(x: ring - 7, y: (h - 14) / 2, width: 14, height: 14)
            mark.frame = NSRect(x: ring - 9, y: (h - 18) / 2, width: 18, height: 18)
            icon.isHidden = false
        } else {
            // the full table has no ring column: the spinner (or the failure mark) takes the icon's place
            spinner.frame = NSRect(x: grid.icon + 2, y: (h - 14) / 2, width: 14, height: 14)
            mark.frame = icon.frame
            icon.isHidden = !spinner.isHidden || mark.image != nil
        }
        let sw = ceil(status.intrinsicContentSize.width) + 4, sh = status.intrinsicContentSize.height
        // in the time column, where the items' times start; a longer status grows to the left
        let sx = min(grid.time ?? .greatestFiniteMagnitude, grid.trailing - sw)
        status.frame = NSRect(x: sx, y: (h - sh) / 2, width: sw, height: sh)
        let th = title.intrinsicContentSize.height
        title.frame = NSRect(x: grid.title, y: (h - th) / 2, width: max(0, status.frame.minX - 12 - grid.title), height: th)
        working.frame = wash
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
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(wash, cursor: .pointingHand) }
}

// MARK: - The detail

/// An inset group, System Settings style: r 10, a hairline round it in light, a raised surface in dark. Its rows
/// draw the rules between them.
final class GroupCard: NSView {
    let rows = NSStackView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor), rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor), rows.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ views: [NSView]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            rows.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.controlBackgroundColor).setFill()
        p.fill()
        (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.separatorColor).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

/// A row in a GroupCard: draws the rule above it (not above the first), from where its text starts.
class GroupRow: NSView {
    var ruleInset: CGFloat = 38
    var first = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard !first else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: ruleInset, y: 0, width: bounds.width - ruleInset, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
    }
}

/// The detail column for a job: what it does to what and when it started, one control (Stop while it runs, Try
/// Again when it failed) with ⋯ for the rest, how far it is (one bar, one number, the time so far), its steps in an
/// inset group with each one's time, and the items it has written so far. Agent sessions show their title and status
/// line, then the terminal (P3) below.
final class JobDetailView: NSView {
    var onAction: ((String) -> Void)?           // "log", "retry", "dismiss", "items", "item:<uid>", "stop", "external"
    private let stack = NSStackView()
    private let headerRow = NSView()
    private let header = NSTextField(labelWithString: "")
    private let controls = NSStackView()
    private let sub = NSTextField(labelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let progress = NSView()
    private let bar = FlatProgressBar()
    private let doing = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let stepsTitle = NSTextField(labelWithString: "")
    private let stepsCard = GroupCard()
    private let itemsTitle = NSTextField(labelWithString: "")
    private let itemsCard = GroupCard()
    private(set) var job: Job?
    /// The terminal pane for agent jobs (AppEnvironment.terminal), or a note that it isn't available.
    let terminalBox = NSView()
    private var terminal: TerminalPaneHosting?
    private var ticker: Timer?
    /// The running step's time label and when it started, for the ticker.
    private var runningStep: (label: NSTextField, start: Date)?
    static let maxItems = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 17, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        header.cell?.truncatesLastVisibleLine = true
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [header, controls] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; headerRow.addSubview(v) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor), header.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),
            controls.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor), controls.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 26),
        ])
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        sub.cell?.truncatesLastVisibleLine = true
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        error.isSelectable = true               // the fix in it ("run `claude` and /login") can be copied
        error.font = .systemFont(ofSize: 12)
        doing.font = .systemFont(ofSize: 12)
        doing.textColor = .secondaryLabelColor
        doing.lineBreakMode = .byTruncatingTail
        doing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsed.textColor = .secondaryLabelColor
        elapsed.alignment = .right
        for v in [bar, doing, elapsed] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; progress.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: progress.topAnchor), bar.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: progress.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 4),
            doing.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 7), doing.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            doing.trailingAnchor.constraint(lessThanOrEqualTo: elapsed.leadingAnchor, constant: -12),
            elapsed.firstBaselineAnchor.constraint(equalTo: doing.firstBaselineAnchor), elapsed.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            doing.bottomAnchor.constraint(equalTo: progress.bottomAnchor),
        ])
        for t in [stepsTitle, itemsTitle] {
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            t.textColor = .labelColor
        }
        stepsTitle.stringValue = T("main.job.steps")
        itemsTitle.stringValue = T("main.job.items")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // the title's line on the list's first line ("Running · 1"): one top under the toolbar for both columns
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 24, bottom: 16, right: 24)
        let full: [NSView] = [headerRow, sub, error, progress, stepsTitle, stepsCard, itemsTitle, itemsCard]
        for v in full { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(1, after: headerRow)
        stack.setCustomSpacing(18, after: sub)
        stack.setCustomSpacing(18, after: error)
        stack.setCustomSpacing(24, after: progress)
        stack.setCustomSpacing(8, after: stepsTitle)
        stack.setCustomSpacing(24, after: stepsCard)
        stack.setCustomSpacing(8, after: itemsTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        terminalBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(terminalBox)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalBox.topAnchor.constraint(equalTo: stack.bottomAnchor), terminalBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalBox.trailingAnchor.constraint(equalTo: trailingAnchor), terminalBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in full { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { ticker?.invalidate() }

    /// "Used about 24K tokens · gpt-6-luna" / "用了约 2.4万 token · gpt-6-luna"; "No AI · 0 tokens" for a capture filed
    /// from its note; nil when the agent didn't say (nothing to tell, so nothing shown).
    static func usageText(_ u: (tokens: Int?, agent: String?, model: String?, effort: String?)) -> String? {
        guard u.agent != nil else { return T("job.usage.none") }
        guard let n = u.tokens else { return nil }
        let compact = n.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)).locale(Loc.locale))
        return T("job.usage.tokens", compact) + (u.model.map { " · " + $0 } ?? "")
    }

    /// "由 Codex 整理（Claude Code 没登录）" for an organising run another agent took over; nil when the first one did.
    static func organizerText(_ j: Job) -> String? {
        guard let o = j.organizer else { return nil }
        return T("main.job.organized_by", AgentNames.name(o.agent), o.insteadOf.joined(separator: T("app.agent.list_sep")))
    }

    /// The line under the title: where, when it started (and how long it took), who organised it, what it cost.
    static func subtitle(_ j: Job, projectName: String?) -> String {
        var parts: [String] = []
        let start = j.started ?? j.created
        // an agent session: the pane header below carries its project, state and branch — said once, not twice
        if j.type != .agent {
            if let p = projectName { parts.append(p) }
            parts.append(T("main.job.started", Loc.relative(start)))
            if let end = j.ended, !j.isActive { parts.append(T("main.job.took", JobLook.clock(end.timeIntervalSince(start)))) }
            if let o = organizerText(j) { parts.append(o) } else if j.isActive, let a = JobLook.agentName(j) { parts.append(a) }
        }
        if let u = j.usage, let t = usageText(u) { parts.append(t) }
        return parts.joined(separator: "  ·  ")
    }

    func show(_ j: Job, projectName: String?) {
        let sameJob = job?.id == j.id
        job = j
        let agent = j.type == .agent
        header.stringValue = JobLook.detailTitle(j)
        header.toolTip = header.stringValue
        sub.stringValue = Self.subtitle(j, projectName: projectName)
        sub.isHidden = sub.stringValue.isEmpty
        stack.setCustomSpacing(agent ? 8 : 18, after: sub)

        // why it ended: the session pane says it for an agent; a stop the user made is said quietly, not in red
        if !agent, JobLook.stopped(j) {
            error.stringValue = T("main.job.stopped")
            error.textColor = .secondaryLabelColor
            error.isHidden = false
        } else if !agent, let why = JobLook.errorText(j) {
            error.stringValue = why
            error.textColor = BrandColor.err
            error.isHidden = false
        } else { error.isHidden = true }

        // how far: one bar, one number, the time so far — only while it runs
        let fraction = JobLook.fraction(j)
        progress.isHidden = agent || !j.isActive
        bar.isHidden = fraction == nil
        bar.value = fraction ?? 0
        doing.stringValue = JobLook.doing(j) + (fraction.map { "  " + Loc.percent($0) } ?? "")

        showControls(j)
        showSteps(j)
        showItems(j)
        ticker?.invalidate()
        ticker = nil
        startTicker()
        tick()
        attachTerminal(j, sameJob: sameJob)
    }

    private func startTicker() {
        guard ticker == nil, window != nil, let j = job, j.isActive, j.type != .agent else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// The live times: the run's elapsed time, the running step's.
    private func tick() {
        guard let j = job else { return }
        if window == nil || isHidden { ticker?.invalidate(); ticker = nil; return }
        elapsed.stringValue = T("main.job.elapsed", JobLook.clock(Date().timeIntervalSince(j.started ?? j.created)))
        if let r = runningStep { r.label.stringValue = JobLook.clock(Date().timeIntervalSince(r.start)) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startTicker()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startTicker()
    }

    // MARK: controls: at most two at rest — the one thing to do, and ⋯ for the rest

    private func showControls(_ j: Job) {
        controls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // an agent session: its terminal pane's header carries Stop, Open in Terminal, Show Log…
        guard j.type != .agent else { return }
        let canRetry = (j.state == .failed || JobLook.stopped(j)) && j.type == .process && (j.session != nil || !j.items.isEmpty)
        var more: [(String, String)] = []
        if JobStop.canStop(j) {
            let b = plain(T("main.job.stop"), "stop")
            b.keyEquivalent = "."
            b.keyEquivalentModifierMask = .command
            b.toolTip = T("main.job.stop.tip")
            controls.addArrangedSubview(b)
        } else if canRetry {
            let b = BrandButton(title: T("action.retry"), target: self, action: #selector(tap(_:)))
            b.identifier = .init("retry")
            b.fontSize = 12
            b.hPad = 12
            b.radius = 6
            controls.addArrangedSubview(b)
            if j.state == .failed, !j.dismissed { more.append((T("main.job.dismiss"), "dismiss")) }
        } else if j.state == .failed, !j.dismissed {
            controls.addArrangedSubview(plain(T("main.job.dismiss"), "dismiss"))
        } else if j.state == .done, !j.items.isEmpty {
            controls.addArrangedSubview(plain(TP("main.job.show_items", j.items.count), "items"))
        }
        if logURL(j) != nil { more.append((T("main.job.show_log"), "log")) }
        if j.session != nil { more.append((T("action.reveal_in_finder"), "reveal")) }
        guard !more.isEmpty else { return }
        let menu = NSMenu()
        for (title, action) in more {
            let i = NSMenuItem(title: Look.menuCase(title), action: #selector(menuTap(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = action
            menu.addItem(i)
        }
        controls.addArrangedSubview(MenuButton(menu: menu, label: T("main.job.more")))
    }

    private func plain(_ title: String, _ action: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
        b.identifier = .init(action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    /// The job's own log, else the recording's agent.log (an organising run writes there).
    private func logURL(_ j: Job) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: JobFiles.log(j.id).path) { return JobFiles.log(j.id) }
        if let s = j.session?.appendingPathComponent("agent.log"), fm.fileExists(atPath: s.path) { return s }
        return nil
    }

    // MARK: steps

    private func showSteps(_ j: Job) {
        runningStep = nil
        let show = j.type != .agent
        stepsTitle.isHidden = !show
        stepsCard.isHidden = !show
        guard show else { return }
        let times = JobLook.stepTimes(j)
        let stopped = JobLook.stopped(j)
        var rows: [NSView] = []
        for (k, s) in JobLook.steps(j).enumerated() {
            // a stopped run's step that was going says it stopped, not that it failed
            let look: StepLook = stopped && (s.state == .running || s.state == .failed) ? .stopped
                : !j.isActive && s.state == .running ? .failed : StepLook(s.state)
            let t = times[s.id]
            let r = StepRow(s, look: look, start: t?.start, end: t?.end)
            r.first = k == 0
            if look == .running, let st = t?.start { runningStep = (r.time, st) }
            rows.append(r)
        }
        stepsCard.set(rows)
    }

    // MARK: items

    private func showItems(_ j: Job) {
        let producing = j.type == .process || j.type == .route
        let show = j.type != .agent && (!j.items.isEmpty || (producing && (j.isActive || j.state == .done)))
        itemsTitle.isHidden = !show
        itemsCard.isHidden = !show
        guard show else { return }
        var rows: [GroupRow] = []
        if j.items.isEmpty {
            rows.append(NoteRow(j.isActive ? T("main.job.items.waiting") : T("main.job.items.none")))
        } else {
            let first = Array(j.items.prefix(Self.maxItems))
            let found = (try? IndexReader(url: BlurtPaths.indexDB)).flatMap { try? $0.items(uids: first) } ?? []
            let byUID = Dictionary(found.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            for uid in first {
                guard let it = byUID[uid] else { continue }
                let r = JobItemRow(it)
                r.onClick = { [weak self] in self?.onAction?("item:" + uid) }
                rows.append(r)
            }
            if rows.isEmpty { rows.append(NoteRow(TP("main.items.count", j.items.count))) }
            if j.items.count > Self.maxItems {
                let more = JobItemRow(nil, text: T("main.job.items.more", j.items.count))
                more.onClick = { [weak self] in self?.onAction?("items") }
                rows.append(more)
            }
        }
        itemsTitle.stringValue = j.items.isEmpty ? T("main.job.items") : T("main.job.items") + "  " + Loc.number(j.items.count)
        for (k, r) in rows.enumerated() { r.first = k == 0 }
        itemsCard.set(rows)
    }

    private func attachTerminal(_ j: Job, sameJob: Bool) {
        guard j.type == .agent else {
            terminal?.viewController.view.removeFromSuperview()
            terminal?.attach(job: nil)
            terminalBox.isHidden = true
            return
        }
        terminalBox.isHidden = false
        if let host = AppEnvironment.terminal {
            if terminal == nil { terminal = host.makePane() }
            guard let t = terminal else { return }
            if t.viewController.view.superview !== terminalBox {
                terminalBox.subviews.forEach { $0.removeFromSuperview() }
                let v = t.viewController.view
                v.translatesAutoresizingMaskIntoConstraints = false
                terminalBox.addSubview(v)
                NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: terminalBox.topAnchor), v.bottomAnchor.constraint(equalTo: terminalBox.bottomAnchor),
                                             v.leadingAnchor.constraint(equalTo: terminalBox.leadingAnchor), v.trailingAnchor.constraint(equalTo: terminalBox.trailingAnchor)])
            }
            if !sameJob { t.attach(job: j.id) }
        } else if terminalBox.subviews.isEmpty {
            let note = EmptyStateView()
            note.show(symbol: "apple.terminal", title: T("main.job.no_terminal"), message: T("main.job.no_terminal.detail"))
            note.translatesAutoresizingMaskIntoConstraints = false
            terminalBox.addSubview(note)
            NSLayoutConstraint.activate([note.topAnchor.constraint(equalTo: terminalBox.topAnchor), note.bottomAnchor.constraint(equalTo: terminalBox.bottomAnchor),
                                         note.leadingAnchor.constraint(equalTo: terminalBox.leadingAnchor), note.trailingAnchor.constraint(equalTo: terminalBox.trailingAnchor)])
        }
    }

    @objc func tap(_ b: NSButton) { b.identifier.map { run($0.rawValue) } }
    @objc func menuTap(_ i: NSMenuItem) { (i.representedObject as? String).map(run) }

    private func run(_ action: String) {
        guard let j = job else { return }
        switch action {
        case "log": if let u = logURL(j) { NSWorkspace.shared.open(u) }
        case "reveal": if let s = j.session { NSWorkspace.shared.activateFileViewerSelecting([s]) }
        default: onAction?(action)
        }
    }
}

/// ⋯ beside the header's button: a borderless menu button for the rarer actions (Show Log, Show in Finder, Dismiss).
final class MenuButton: NSButton {
    private let items: NSMenu
    init(menu: NSMenu, label: String) {
        items = menu
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        isBordered = false
        bezelStyle = .regularSquare
        image = Look.symbol("ellipsis.circle", label, size: 15)
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(open)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func open() { items.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self) }
}

/// A quiet line inside a group: "Items appear here as they’re written."
final class NoteRow: GroupRow {
    init(_ text: String) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), l.centerYAnchor.constraint(equalTo: centerYAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An item the job wrote, as the list shows it — kind icon, state ring, title, its id — one click opens it. Without
/// an item: a "Show all 12" line in the title's place.
final class JobItemRow: GroupRow {
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }

    init(_ it: ItemRow?, text: String? = nil) {
        super.init(frame: .zero)
        ruleInset = 12
        let title = NSTextField(labelWithString: it?.title ?? text ?? "")
        title.font = Look.titleFont
        title.textColor = it == nil ? BrandColor.ink : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let key = NSTextField(labelWithString: it?.itemID ?? "")
        key.font = Look.monoSub
        key.textColor = .secondaryLabelColor
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        let icon = NSImageView(), ring = NSImageView()
        icon.imageScaling = .scaleNone
        ring.imageScaling = .scaleNone
        if let it = it {
            icon.image = Look.kindImage(it.kind)
            icon.setAccessibilityLabel(Look.kindName(it.kind))
            ring.image = Look.ring(it.state)
            ring.toolTip = Look.stateLabel(it)
        }
        for v in [icon, ring, title, key] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let x: CGFloat = it == nil ? 12 : 12 + 18 + 3 + 20 + 6
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            ring.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3), ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([it?.itemID, title.stringValue].compactMap { $0 }.joined(separator: " "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hover else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// How a step is drawn: its state, or "stopped" for the step a stopped run was on.
enum StepLook: Equatable {
    case pending, running, done, failed, skipped, stopped
    init(_ s: StepState) {
        switch s {
        case .pending: self = .pending
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        case .skipped: self = .skipped
        }
    }
}

/// One step in the group: its marker, its name, and on the right how long it took (or has been going).
final class StepRow: GroupRow {
    let time = NSTextField(labelWithString: "")

    init(_ s: JobStep, look: StepLook, start: Date?, end: Date?, label: String? = nil) {
        super.init(frame: .zero)
        let marker = StepMarker(look: look)
        let base = label ?? T("job.step.\(s.id)")
        // a failed step says so in words, not only in red: "Transcribing · Failed"
        let name = NSTextField(labelWithString: look == .failed ? "\(base) · \(T("job.state.failed"))" : base)
        name.font = .systemFont(ofSize: 13, weight: look == .running ? .medium : .regular)
        name.textColor = look == .failed ? BrandColor.err : look == .pending ? .secondaryLabelColor : look == .skipped ? .tertiaryLabelColor : .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        switch look {
        case .running: time.stringValue = start.map { JobLook.clock(Date().timeIntervalSince($0)) } ?? ""
        case .done, .failed: time.stringValue = start.flatMap { st in end.map { JobLook.clock($0.timeIntervalSince(st)) } } ?? ""
        case .skipped: time.stringValue = T("main.job.skipped")
        case .stopped: time.stringValue = T("main.job.step_stopped")
        case .pending: time.stringValue = ""
        }
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [marker, name, time] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 16), marker.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let said: String
        switch look {
        case .pending: said = T("main.job.step_state.pending")
        case .running: said = T("main.job.step_state.running")
        case .done: said = T("main.job.step_state.done")
        case .failed: said = T("main.job.step_state.failed")
        case .skipped: said = T("main.job.step_state.skipped")
        case .stopped: said = T("main.job.step_stopped")
        }
        setAccessibilityLabel("\(name.stringValue), \(said)" + (look == .running || look == .done ? ", \(time.stringValue)" : ""))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A step's 16 pt marker, one family: done = the ok disc with a check, running = the shared spinner arc on its track,
/// pending = a hollow ring, failed = the error disc with an ×, skipped / stopped = the ring with a dash.
final class StepMarker: NSView {
    let look: StepLook

    init(look: StepLook) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        if look == .running {
            let s = TrackedSpinner(size: 16)
            s.frame = bounds
            s.autoresizingMask = [.width, .height]
            addSubview(s)
            s.startAnimation()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        switch look {
        case .done:
            BrandColor.ok.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            BrandColor.onOk.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x - 3.6, y: c.y + 0.1)); p.line(to: NSPoint(x: c.x - 1.1, y: c.y - 2.4)); p.line(to: NSPoint(x: c.x + 3.7, y: c.y + 2.6))
            p.lineWidth = 1.7; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.stroke()
        case .failed:
            BrandColor.err.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.white.setStroke()
            let p = NSBezierPath(), d: CGFloat = 2.8
            p.move(to: NSPoint(x: c.x - d, y: c.y - d)); p.line(to: NSPoint(x: c.x + d, y: c.y + d))
            p.move(to: NSPoint(x: c.x + d, y: c.y - d)); p.line(to: NSPoint(x: c.x - d, y: c.y + d))
            p.lineWidth = 1.7; p.lineCapStyle = .round
            p.stroke()
        case .running:
            break                                   // the spinner draws itself
        case .pending, .skipped, .stopped:
            NSColor.tertiaryLabelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.75, dy: 1.75))
            ring.lineWidth = 1.5
            ring.stroke()
            guard look != .pending else { return }
            (look == .stopped ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x - 3, y: c.y)); p.line(to: NSPoint(x: c.x + 3, y: c.y))
            p.lineWidth = 1.5; p.lineCapStyle = .round
            p.stroke()
        }
    }
}
