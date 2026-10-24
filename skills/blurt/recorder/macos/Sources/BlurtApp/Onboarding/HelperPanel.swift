// The permission guide's helper panel (PermissionGuide.swift): a small floating panel docked next to the System
// Settings window while the user flips Blurt's switch there.
//   • where: the System Settings window's frame from CGWindowListCopyWindowInfo — only its bounds, owner pid and layer
//     are read (no title, no contents) — re-read every 0.25 s so the panel follows when the window moves; placement is
//     BlurtCore's HelperDock (right of it, else left, else inside its lower right corner; no window = top right);
//   • what: the step's one line ("Turn on Blurt here"), an arrow toward the list, why it's needed, a Blurt tile to drag
//     into the list when Blurt isn't listed (an NSDraggingSource carrying the app bundle's file URL), every step of
//     the walk with its live state, Skip, and a close button;
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
    private var follow: Timer?
    private(set) var lastTarget: CGRect?
    private var hideWork: DispatchWorkItem?

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
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        let h = NSHostingView(rootView: HelperPanelView())
        h.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: fx.leadingAnchor), h.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            h.topAnchor.constraint(equalTo: fx.topAnchor), h.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        p.contentView = fx
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

struct HelperPanelView: View {
    @ObservedObject var g = PermissionGuide.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(progress).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { g.running ? g.cancel() : HelperPanel.shared.hide() } label: {
                    Image(nsImage: BlurtIcon.x.symbolImage(pointSize: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(T("settings.perm.close")).accessibilityLabel(T("settings.perm.close"))
            }
            if let k = g.current {
                stepView(k)
            } else if let f = g.finished {
                HStack(spacing: 8) {
                    Image(nsImage: BlurtIcon.check.symbolImage(pointSize: 15, weight: .semibold)).foregroundStyle(Color.brandOk)
                    Text(f).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
            }
            if g.steps.count > 1 { checklist }
        }
        .padding(14)
        .frame(width: HelperPanel.width, alignment: .leading)
    }

    private var progress: String {
        guard let k = g.current, let i = g.steps.firstIndex(of: k) else { return T("settings.perm.panel_title") }
        return g.steps.count > 1 ? T("settings.perm.progress", i + 1, g.steps.count, PermissionGuide.name(k)) : PermissionGuide.name(k)
    }

    @ViewBuilder func stepView(_ k: PermissionKind) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if g.stepDone {
                Image(nsImage: BlurtIcon.check.symbolImage(pointSize: 15, weight: .semibold)).foregroundStyle(Color.brandOk)
            } else if (g.dock == .right || g.dock == .left) && !(k == .microphone && SystemAccess.state(.microphone) == .notAsked) {
                // toward the list in the System Settings window
                Image(nsImage: BlurtIcon.arrowLeft.symbolImage(pointSize: 15, weight: .semibold))
                    .rotationEffect(.degrees(g.dock == .left ? 180 : 0))
                    .foregroundStyle(Color.brandInk)
                    .accessibilityHidden(true)
            }
            Text(g.headline(k)).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
        Text(PermissionGuide.why(k)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !g.stepDone && k.acceptsDrop {
            HStack(spacing: 10) {
                AppTile().frame(width: 52, height: 52)
                    .help(T("settings.perm.drag_hint"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("settings.perm.drag")).font(.callout.weight(.medium))
                    Text(T("settings.perm.drag_detail")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
        }
        if !g.stepDone {
            HStack(spacing: 8) {
                if g.noWindow && !(k == .microphone && SystemAccess.state(.microphone) == .notAsked) {
                    Button(T("settings.perm.open_settings")) { g.reopenPane() }.controlSize(.small)
                }
                if k == .screen {
                    Button(T("settings.perm.restart")) { g.restartForScreen() }.controlSize(.small)
                        .help(T("settings.perm.restart_hint"))
                }
                Spacer()
                Button(T("settings.perm.skip")) { g.skip() }.controlSize(.small).buttonStyle(.link)
            }
            if k == .screen && g.suggestRestart {
                Text(T("settings.perm.restart_hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var checklist: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(g.steps, id: \.self) { s in
                HStack(spacing: 6) {
                    let ok = g.satisfiedNow.contains(s)
                    StatusDot(tone: ok ? .good : s == g.current ? .warn : .off)
                    Text(PermissionGuide.name(s)).font(.caption).foregroundStyle(s == g.current ? .primary : .secondary)
                    Spacer()
                    // Input Monitoring satisfied without the grant: the Fn filter hears the key on Accessibility
                    Text(ok ? (s == .inputMonitoring && !SystemAccess.granted(.inputMonitoring) ? T("settings.perm.not_needed") : T("settings.kit.allowed"))
                         : s == g.current ? T("settings.perm.now") : T("settings.kit.not_set"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 2)
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
        setAccessibilityLabel(T("settings.perm.drag"))
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
