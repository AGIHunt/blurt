// The permission guide's helper panel (PermissionGuide.swift): a small floating panel docked next to the System
// Settings window while the user flips Blurt's switch there.
//   • where: the System Settings window's frame from CGWindowListCopyWindowInfo — only its bounds, owner pid and layer
//     are read (no title, no contents) — re-read every 0.25 s so the panel follows when the window moves; placement is
//     BlurtCore's HelperDock (right of it, else left, else inside its lower right corner; no window = top right);
//   • what: the walk's dots and the permission's name ("Accessibility · 2 of 3"), one headline ("Turn on Blurt in
//     the list"), one line of why, a Blurt icon to drag into the list when Blurt isn't listed (an NSDraggingSource
//     carrying the app bundle's file URL), Skip, and a close button that stops the walk; a notch on the card's edge
//     points at the System Settings window (no arrow in the text);
//   • a non-activating panel: clicking it never takes the focus from System Settings, and it stays up while Blurt
//     isn't the active app.
// Test builds can dock it to a stand-in window of their own (`perm standin …`) instead of System Settings.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class HelperPanel {
    static let shared = HelperPanel()
    private var panel: NSPanel?
    private var host: NSHostingView<HelperPanelView>?
    private var lastSize: NSSize?
    private var follow: Timer?
    private(set) var lastTarget: CGRect?
    private var hideWork: DispatchWorkItem?

    /// the card (314) and the notch's room on each side (HelperPanelView.notch)
    static let width: CGFloat = 330

    var isShown: Bool { panel?.isVisible == true }
    var frame: NSRect? { panel?.frame }
    var windowNumber: Int? { panel?.windowNumber }

    func show() {
        hideWork?.cancel()
        if panel == nil { build() }
        reposition(animated: false)
        panel?.orderFrontRegardless()
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(animated: true) }
        }
    }

    func hide() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        emit(["event": "perm_panel", "shown": false])
    }

    /// The last word ("Done — …") for a moment, then away.
    func showDone(_ text: String, after: Double) {
        guard panel?.isVisible == true else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 1.6, execute: w)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: HelperPanel.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.sharingType = chromeSharing
        p.title = T("settings.perm.panel_title")
        // an opaque card drawn by the view itself (HelperPanelView: the surface, the hairline, the notch); the window
        // is clear around it and its shadow follows the card's shape
        let h = NSHostingView(rootView: HelperPanelView())
        h.wantsLayer = true
        h.layer?.backgroundColor = .clear
        p.contentView = h
        panel = p
        host = h
    }

    /// Follows the System Settings window (or the stand-in), and fits the content's height.
    func reposition(animated: Bool) {
        guard let p = panel, let h = host else { return }
        let size = NSSize(width: HelperPanel.width, height: ceil(h.fittingSize.height))
        let target = HelperPanel.targetFrame()
        let g = PermissionGuide.shared
        if (target == nil) != g.noWindow { g.noWindow = target == nil }
        let ns = target.map(toNS)
        let screen = (ns.flatMap { r in NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) } } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let (o, side) = HelperDock.place(panel: size, target: ns, screen: screen)
        if side != g.dock { g.dock = side }
        let f = NSRect(origin: o, size: size)
        if f.integral != p.frame.integral {
            p.setFrame(f, display: true, animate: false)
            if size != lastSize { lastSize = size; p.invalidateShadow() }
            if target != lastTarget || !animated {
                emit(["event": "perm_panel", "shown": true, "side": side.rawValue,
                      "frame": [toCG(f).minX, toCG(f).minY, f.width, f.height].map { Double(Int($0)) },
                      "target": target.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double(Int($0)) } } ?? NSNull()])
            }
        }
        lastTarget = target
    }

    // MARK: the System Settings window

    /// Its frame (CG coordinates, top left origin): the largest on-screen layer-0 window owned by System Settings.
    /// Only bounds, owner and layer are read.
    static func targetFrame() -> CGRect? {
        if let s = StandIn.window { return s.isVisible ? toCG(s.frame) : nil }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: CGRect?
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            if r.width * r.height > (best.map { $0.width * $0.height } ?? 0) { best = r }
        }
        return best
    }

    /// Tests: a window of ours standing in for System Settings (`perm standin show [x,y,w,h] | move x,y | hide | off`).
    @MainActor
    enum StandIn {
        static var window: NSWindow?
        static func command(_ arg: String) {
            let a = arg.split(separator: " ").map(String.init)
            let nums = (a.count > 1 ? a[1] : "").split(separator: ",").compactMap { Double($0) }
            switch a.first ?? "show" {
            case "off":
                window?.orderOut(nil)
                window = nil
            case "hide": window?.orderOut(nil)
            case "move":
                if nums.count >= 2, let w = window {
                    let cg = CGRect(x: nums[0], y: nums[1], width: w.frame.width, height: w.frame.height)
                    w.setFrame(toNS(cg), display: true)
                }
            default:
                if window == nil {
                    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620), styleMask: [.titled, .closable],
                                     backing: .buffered, defer: false)
                    w.title = "System Settings (stand-in)"
                    w.isReleasedWhenClosed = false
                    let label = NSTextField(labelWithString: "Stand-in for the System Settings window (test build)")
                    label.frame = NSRect(x: 24, y: 560, width: 600, height: 20)
                    label.textColor = .secondaryLabelColor
                    w.contentView?.addSubview(label)
                    window = w
                }
                if nums.count == 4 { window?.setFrame(toNS(CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])), display: true) }
                window?.orderFrontRegardless()
            }
            let f = window.map { toCG($0.frame) }
            emit(["event": "perm_standin", "window": window?.windowNumber ?? -1,
                  "frame": f.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()])
        }
    }
}

// MARK: - the content

/// The panel: where you are (the walk's dots, the permission's name, "2 of 3"), what to do (one headline, one line of
/// why), the thing to drag when Blurt isn't listed, and the way out (Skip). An opaque card (panel / raise surfaces,
/// §2.4) so its contrast never depends on what is behind it, with a notch on the edge that faces the System Settings
/// window instead of an arrow in the text.
struct HelperPanelView: View {
    @ObservedObject var g = PermissionGuide.shared
    static let notch: CGFloat = 8
    /// the notch's centre, from the card's top: level with the headline
    static let notchY: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let k = g.current {
                stepView(k)
            } else if let f = g.finished {
                doneView(f, detail: g.finishedDetail)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        .frame(width: HelperPanel.width - 2 * HelperPanelView.notch, alignment: .leading)
        .background(NotchedCard(side: g.dock).fill(HelperPanelView.surface).padding(.horizontal, -HelperPanelView.notch))
        .overlay(NotchedCard(side: g.dock).stroke(Color.primary.opacity(0.12), lineWidth: 0.5).padding(.horizontal, -HelperPanelView.notch))
        .padding(.horizontal, HelperPanelView.notch).padding(.vertical, 1)      // the hairline inside the window
    }

    /// panel white (light) / #2A2A2A (dark), as the app's popovers
    static let surface = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : .white
    })

    var header: some View {
        HStack(spacing: 8) {
            if g.steps.count > 1 { GuideDots(g: g) }
            Text(progress).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { g.running ? g.cancel() : HelperPanel.shared.hide() } label: {
                Image(nsImage: BlurtIcon.x.symbolImage(pointSize: 10, weight: .semibold))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(T(g.running ? "onboarding.guide.stop" : "settings.perm.close"))
            .accessibilityLabel(T(g.running ? "onboarding.guide.stop" : "settings.perm.close"))
        }
    }

    private var progress: String {
        guard let k = g.current, let i = g.steps.firstIndex(of: k) else { return T("settings.perm.panel_title") }
        return g.steps.count > 1 ? T("onboarding.guide.progress", PermissionGuide.name(k), i + 1, g.steps.count) : PermissionGuide.name(k)
    }

    @ViewBuilder func stepView(_ k: PermissionKind) -> some View {
        if g.stepDone {
            doneView(g.headline(k), detail: nil)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(g.headline(k)).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(g.guideWhy(k)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            // re-adding a stale Screen Recording grant: the tile is its second step, not a "not in the list?" aside
            let readd = k == .screen && g.reauthorize
            if k.acceptsDrop {
                HStack(spacing: 12) {
                    AppTile().frame(width: 36, height: 36)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .help(T("settings.perm.drag_hint"))
                    VStack(alignment: .leading, spacing: 2) {
                        if readd {
                            Text(T("settings.perm.screen.readd_drag")).font(.system(size: 12, weight: .medium))
                            Text(T("settings.perm.screen.readd_drag_detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(T("onboarding.guide.drag")).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 14)
            }
            if k == .screen && g.suggestRestart && !readd {
                Text(T("settings.perm.restart_hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            Divider().padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 8) {
                if g.noWindow && !(k == .microphone && SystemAccess.state(.microphone) == .notAsked) {
                    Button(T("settings.perm.open_settings")) { g.reopenPane() }.controlSize(.small)
                }
                if k == .screen {
                    Button(T("settings.perm.restart")) { g.restartForScreen() }.controlSize(.small)
                        .help(T("settings.perm.restart_hint"))
                }
                Spacer()
                Button(T("onboarding.guide.skip")) { g.skip() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }

    /// The step or the walk done: the ok disc (16 pt, the same check as everywhere) and one line, a quieter one under it.
    func doneView(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: .good).scaleEffect(16 / StatusDot.size).frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let d = detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

/// The walk as dots, one per step: done the ok disc with its check, now a brand-ink disc, still to come a hollow
/// ring — shapes, not only colours. Each says its name and state to the pointer and to VoiceOver.
struct GuideDots: View {
    @ObservedObject var g: PermissionGuide
    var body: some View {
        HStack(spacing: 4) {
            ForEach(g.steps, id: \.self) { s in
                let ok = g.satisfiedNow.contains(s)
                Group {
                    if ok { StatusDot(tone: .good) }
                    else if s == g.current { Circle().fill(Color.brandInk).frame(width: StatusDot.size, height: StatusDot.size) }
                    else { StatusDot(tone: .off) }
                }
                .help(PermissionGuide.name(s) + " · " + (ok ? T("settings.kit.allowed") : s == g.current ? T("onboarding.guide.now") : T("settings.kit.not_set")))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.steps.map { s in
            PermissionGuide.name(s) + " " + (g.satisfiedNow.contains(s) ? T("settings.kit.allowed") : s == g.current ? T("onboarding.guide.now") : T("settings.kit.not_set"))
        }.joined(separator: ", "))
    }
}

/// The card's outline: a rounded rectangle with a small notch on the edge that faces System Settings (docked right of
/// its window: the left edge; docked left: the right edge; inside it or with no window: none). `rect` includes the
/// notch's room on both sides.
struct NotchedCard: Shape {
    /// the notch on the left edge (docked right of the window) / on the right edge (docked left of it)
    var left: Bool
    var right: Bool
    var radius: CGFloat = 12

    init(side: HelperDock.Side) { left = side == .right; right = side == .left }

    func path(in rect: CGRect) -> Path {
        let n = HelperPanelView.notch, r = radius, y = HelperPanelView.notchY
        let b = rect.insetBy(dx: n, dy: 0)
        var p = Path()
        p.move(to: CGPoint(x: b.minX + r, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY + r), radius: r)
        if right {
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY + y - n))
            p.addLine(to: CGPoint(x: b.maxX + n, y: b.minY + y))
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY + y + n))
        }
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.maxX - r, y: b.maxY), radius: r)
        p.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX, y: b.maxY - r), radius: r)
        if left {
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + y + n))
            p.addLine(to: CGPoint(x: b.minX - n, y: b.minY + y))
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + y - n))
        }
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX + r, y: b.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Blurt's icon, to drag into a System Settings list (the "+" lists accept an app dropped on them).
struct AppTile: NSViewRepresentable {
    func makeNSView(context: Context) -> AppTileView { AppTileView() }
    func updateNSView(_ v: AppTileView, context: Context) {}
}

final class AppTileView: NSView, NSDraggingSource {
    private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        setAccessibilityLabel(T("onboarding.guide.drag"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds.insetBy(dx: 2, dy: 2))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    /// What the drag carries: the app bundle's file URL (as Finder's own drag of an app does).
    static func pasteboardWriter() -> NSPasteboardWriting { Bundle.main.bundleURL as NSURL }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: AppTileView.pasteboardWriter())
        item.setDraggingFrame(bounds, contents: icon)
        emit(["event": "perm_drag", "op": "begin"])
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        emit(["event": "perm_drag", "op": "end", "operation": Int(operation.rawValue)])
        // a drop into the list usually grants nothing yet (the switch is off): look again now anyway
        Task { @MainActor in PermissionGuide.shared.poll() }
    }
}
