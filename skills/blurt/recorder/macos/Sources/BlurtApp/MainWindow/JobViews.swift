// Jobs in the main window (K4): the "In progress" section above the list — one compact row per running job (what,
// which step, how far, which project; agent sessions with their status) — and the detail page's timeline of a job's
// steps while it runs. Nothing here opens anything by itself: rows are clicked.
import AppKit
import BlurtCore

enum JobLook {
    /// "Organising · Pricing walkthrough", "Claude Code · BA-12, BA-13"
    static func title(_ j: Job) -> String {
        let what: String
        if j.type == .agent, let a = j.agent {
            what = AgentHub.shared.def(a.agent)?.name ?? a.agent
        } else {
            what = T("job.type.\(j.type.rawValue)")
        }
        // AI fill-in: a process job without a capture batch — its own title says what it is ("Organizing · AI
        // fill-in" said it twice, and wrongly)
        if j.type == .process, j.session == nil, let t = j.title, !t.isEmpty { return t }
        let detail = j.title ?? j.agent?.windowName.map { $0.replacingOccurrences(of: ",", with: ", ") } ?? j.session.map { sessionLabel($0) }
        return detail.map { "\(what) · \($0)" } ?? what
    }

    /// A session dir's batch title (batch.json, then meta.json), else its time stamp as a date.
    static func sessionLabel(_ dir: URL) -> String {
        for f in ["batch.json", "meta.json"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["title"] as? String, !t.isEmpty { return t }
        }
        let name = dir.lastPathComponent
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(name.prefix(15))).map(Loc.dateTime) ?? name
    }

    /// What it is doing now: the agent's status, else the current step.
    static func status(_ j: Job) -> String {
        if j.state == .failed { return T("job.state.failed") }
        if let a = j.agent { return T("session.\(a.status.rawValue)") }
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
        case .process: return "wand.and.sparkles"
        case .route: return "arrow.triangle.branch"
        case .agent: return "apple.terminal"
        }
    }
}

/// The running jobs above the list. Hidden when there are none; at most four rows, then "N more".
final class JobsSection: NSView {
    var onSelect: ((String) -> Void)?
    private let stack = NSStackView()
    private let header = NSTextField(labelWithString: "")
    private var rows: [String: JobRow] = [:]
    static let maxRows = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The job the detail shows: its row stays highlighted.
    var selected: String? { didSet { rows.forEach { $0.value.selected = $0.key == selected } } }

    func set(_ jobs: [Job], store: ProjectStore, showProject: Bool = true) {
        isHidden = jobs.isEmpty
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !jobs.isEmpty else { return }
        header.stringValue = TP("main.jobs.header", jobs.count)
        setAccessibilityLabel(header.stringValue)
        let h = NSStackView(views: [header])
        h.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 2, right: 0)
        stack.addArrangedSubview(h)
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
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        rows = keep
        if jobs.count > Self.maxRows {
            let more = NSTextField(labelWithString: TP("main.jobs.more", jobs.count - Self.maxRows))
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            let m = NSStackView(views: [more])
            m.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            stack.addArrangedSubview(m)
        }
    }
}

/// One job: icon (a spinner while it runs), title, project, what it is doing, a thin progress bar.
final class JobRow: NSView {
    var onClick: (() -> Void)?
    let icon = NSImageView()
    let spinner = NSProgressIndicator()
    let title = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    private var hover = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
    /// While AI works on this job (processing a recording into items, auto-sort): the spinner plus one static 1 pt
    /// brand hairline round the row (design system §4) — no rim, no glow, no motion of its own.
    private let working = WorkingOutline(frame: .zero)
    private var aiWorking = false

    init() {
        super.init(frame: .zero)
        working.cornerRadius = 6
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.alignment = .right
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .mini
        bar.minValue = 0
        bar.maxValue = 1
        for v in [icon, spinner, title, status, bar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: bar.leadingAnchor, constant: -10), status.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 56),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ j: Job, project: String?) {
        title.stringValue = JobLook.title(j) + (project.map { "  ·  \($0)" } ?? "")
        status.stringValue = JobLook.status(j)
        status.textColor = JobLook.statusColor(j)
        let waiting = j.agent?.status == .waitingInput
        let busy = j.state == .running && j.type != .agent && j.state != .failed
        let ai = busy && (j.type == .process || j.type == .route)
        if ai != aiWorking {
            aiWorking = ai
            if ai, working.superview == nil { addSubview(working) }
            working.set(active: ai)
        }
        icon.image = Look.symbol(waiting ? "exclamationmark.bubble" : JobLook.symbol(j), JobLook.title(j), size: 13)
        icon.contentTintColor = waiting ? BrandColor.attn : .secondaryLabelColor
        icon.isHidden = busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        if let p = j.progress ?? j.currentStep?.progress { bar.isIndeterminate = false; bar.doubleValue = p; bar.isHidden = false }
        else { bar.isHidden = true }
        setAccessibilityLabel("\(title.stringValue), \(status.stringValue)")
    }

    override func layout() {
        super.layout()
        working.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover || selected else { return }
        (selected ? BrandColor.tint : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The detail column for a job: what it is, its steps as a vertical timeline (done, running with progress, pending,
/// failed, skipped), the error with what to do, and its items. Agent sessions add the terminal (P3) below.
final class JobDetailView: NSView {
    var onAction: ((String) -> Void)?           // "log", "retry", "open:<uid>", "terminal", "stop", "external"
    private let stack = NSStackView()
    private let header = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let steps = NSStackView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private(set) var job: Job?
    /// The terminal pane for agent jobs (AppEnvironment.terminal), or a note that it isn't available.
    let terminalBox = NSView()
    private var terminal: TerminalPaneHosting?

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 17, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 0
        error.font = .systemFont(ofSize: 12)
        error.textColor = BrandColor.err
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 16, right: 24)
        for v in [header, sub, steps, error, buttons] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(18, after: sub)
        stack.setCustomSpacing(14, after: steps)
        stack.translatesAutoresizingMaskIntoConstraints = false
        terminalBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(terminalBox)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalBox.topAnchor.constraint(equalTo: stack.bottomAnchor), terminalBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalBox.trailingAnchor.constraint(equalTo: trailingAnchor), terminalBox.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -48),
            error.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -48),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Used about 24K tokens · gpt-6-luna" / "用了约 2.4万 token · gpt-6-luna"; "No AI · 0 tokens" for a capture filed
    /// from its note.
    static func usageText(_ u: (tokens: Int?, agent: String?, model: String?, effort: String?)) -> String {
        guard let agent = u.agent else { return T("job.usage.none") }
        let model = u.model ?? T("job.usage.cli_default")
        guard let n = u.tokens else { return T("job.usage.unknown", AgentNames.name(agent)) + " · " + model }
        let compact = n.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)).locale(Loc.locale))
        return T("job.usage.tokens", compact) + " · " + model
    }

    func show(_ j: Job, projectName: String?) {
        let sameJob = job?.id == j.id
        job = j
        header.stringValue = JobLook.title(j)
        var parts = j.type == .agent ? [T("job.type.agent")] : []
        if let p = projectName { parts.append(p) }
        parts.append(Loc.relative(j.started ?? j.created))
        if let a = j.agent { parts.append(T("session.\(a.status.rawValue)")) }
        if let b = j.agent?.branch { parts.append(b) }
        if let u = j.usage { parts.append(JobDetailView.usageText(u)) }
        sub.stringValue = parts.joined(separator: "  ·  ")
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var ids = j.steps.isEmpty ? (jobSteps[j.type] ?? []).map { JobStep(id: $0, state: .pending) } : j.steps
        // AI fill-in has no recording to transcribe, no frames to cut, nothing to file: just prepare and write
        if j.type == .process, j.session == nil { ids = ids.filter { !["transcribe", "frames", "route"].contains($0.id) } }
        for (k, s) in ids.enumerated() { steps.addArrangedSubview(StepRow(s, last: k == ids.count - 1, failed: j.state == .failed)) }
        if let e = j.error {
            error.stringValue = e.hintKey.map { T($0) } ?? (T("main.job.error.\(e.code)") == "main.job.error.\(e.code)" ? e.message : T("main.job.error.\(e.code)"))
            error.isHidden = false
        } else { error.isHidden = true }
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func button(_ t: String, _ action: String) {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.identifier = .init(action)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            buttons.addArrangedSubview(b)
        }
        if j.type == .agent {
            button(T("main.job.open_terminal_app"), "external")
            if j.isActive { button(T("main.job.stop"), "stop") }
        }
        if j.state == .failed, j.type == .process, j.session != nil || !j.items.isEmpty { button(T("action.retry"), "retry") }
        if FileManager.default.fileExists(atPath: JobFiles.log(j.id).path) { button(T("main.job.show_log"), "log") }
        if !j.items.isEmpty { button(TP("main.job.show_items", j.items.count), "items") }
        buttons.isHidden = buttons.arrangedSubviews.isEmpty
        attachTerminal(j, sameJob: sameJob)
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

    @objc func tap(_ b: NSButton) { b.identifier.map { onAction?($0.rawValue) } }
}

/// One step of the timeline: a marker (check, spinner ring, hollow, x, dash) on a vertical line, its name, progress.
final class StepRow: NSView {
    init(_ s: JobStep, last: Bool, failed: Bool, label: String? = nil) {
        super.init(frame: .zero)
        let marker = StepMarker(state: s.state)
        let name = NSTextField(labelWithString: label ?? T("job.step.\(s.id)"))
        name.font = .systemFont(ofSize: 13, weight: s.state == .running ? .semibold : .regular)
        name.textColor = s.state == .pending || s.state == .skipped ? .tertiaryLabelColor : s.state == .failed ? BrandColor.err : .labelColor
        let extra = NSTextField(labelWithString: s.state == .running ? s.progress.map { Loc.percent($0) } ?? "" : s.state == .skipped ? T("main.job.skipped") : "")
        extra.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        extra.textColor = .secondaryLabelColor
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .separatorColor
        line.isHidden = last
        for v in [marker, name, extra, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30), widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor), marker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            marker.widthAnchor.constraint(equalToConstant: 14), marker.heightAnchor.constraint(equalToConstant: 14),
            line.centerXAnchor.constraint(equalTo: marker.centerXAnchor), line.topAnchor.constraint(equalTo: marker.bottomAnchor, constant: 2),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2), line.widthAnchor.constraint(equalToConstant: 1),
            name.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            extra.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8), extra.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            extra.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(name.stringValue), \(T("main.job.step_state.\(s.state.rawValue)")) \(extra.stringValue)")
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class StepMarker: NSView {
    let state: StepState
    private var ring: CAShapeLayer?
    init(state: StepState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard state == .running, ring == nil, let layer = layer else { return }
        // a quarter arc going round — the one motion on this page; still when Reduce Motion is on
        let r = CAShapeLayer()
        r.frame = bounds
        r.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        r.fillColor = nil
        effectiveAppearance.performAsCurrentDrawingAppearance { r.strokeColor = BrandColor.ink.cgColor }
        r.lineWidth = 1.75
        r.strokeStart = 0
        r.strokeEnd = 0.3
        r.lineCap = .round
        layer.addSublayer(r)
        ring = r
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 1.1
            spin.repeatCount = .infinity
            r.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            r.position = CGPoint(x: bounds.midX, y: bounds.midY)
            r.add(spin, forKey: "spin")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { ring?.strokeColor = BrandColor.ink.cgColor }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        switch state {
        case .done:
            BrandColor.ok.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            BrandColor.onOk.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 4, y: 7.2)); p.line(to: NSPoint(x: 6.2, y: 5)); p.line(to: NSPoint(x: 10.2, y: 9.2))
            p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.stroke()
        case .failed:
            BrandColor.err.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.white.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 4.6, y: 4.6)); p.line(to: NSPoint(x: 9.4, y: 9.4))
            p.move(to: NSPoint(x: 9.4, y: 4.6)); p.line(to: NSPoint(x: 4.6, y: 9.4))
            p.lineWidth = 1.6; p.lineCapStyle = .round
            p.stroke()
        case .running:
            NSColor.separatorColor.setStroke()
            let c = NSBezierPath(ovalIn: r); c.lineWidth = 1.75; c.stroke()
        case .skipped:
            NSColor.tertiaryLabelColor.setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: 4, y: 7)); p.line(to: NSPoint(x: 10, y: 7)); p.lineWidth = 1.5; p.stroke()
        case .pending:
            NSColor.tertiaryLabelColor.setStroke()
            let c = NSBezierPath(ovalIn: r); c.lineWidth = 1.5; c.stroke()
        }
    }
}
