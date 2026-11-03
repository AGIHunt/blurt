// The permission guide's helper panel (PermissionGuide.swift): a small floating strip docked under the System
// Settings window's list while the user flips Blurt's switch there (or drags Blurt in).
//   • where: the System Settings window's frame from CGWindowListCopyWindowInfo — only its bounds, owner pid and layer
//     are read (no title, no contents) — re-read every 0.25 s so the panel follows when the window moves; placement is
//     BlurtCore's HelperDock.dock: under the window, as wide as its list (the column right of the sidebar, less the
//     list's insets) and centred on it, its notch pointing up at the list; with no room below, beside the window
//     (right, else left, else inside its lower right corner); no window = the screen's top right;
//   • what, compact: the walk's dots and the permission's name ("Accessibility · 2 of 3"), Skip and a close button
//     that stops the walk on one line; then the Blurt tile to drag into the list (an NSDraggingSource carrying the
//     app bundle's file URL) beside the headline ("Turn on Blurt in the list"), why, and the drag hint. Once the
//     permission is on, the step's check shows for a moment and the next permission opens; after the last one the
//     panel closes by itself;
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

    /// The last word ("Done — …") for a moment, then away by itself.
    func showDone(_ text: String, after: Double) {
        guard panel?.isVisible == true else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = w
        // with Restart Blurt on it: long enough to read and press (Settings keeps the same button)
        let stay = PermissionGuide.shared.finishedRestart ? HelperPanel.doneWithRestartFor : HelperPanel.doneFor
        DispatchQueue.main.asyncAfter(deadline: .now() + after + stay, execute: w)
    }

    /// How long the last "Done" stays before the panel closes by itself.
    static let doneFor: Double = 1.2
    static let doneWithRestartFor: Double = 8

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: HelperDock.sideWidth + 2 * HelperPanelView.notch, height: 120),
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
        // seen by screenshots (⌘⇧4, other apps' tools: a user reporting a problem with this step shows it, BA-48);
        // Blurt's own captures still leave it out (Snap: our windows above layer 0; Recorder: all our windows)
        p.sharingType = .readOnly
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

    /// Follows the System Settings window (or the stand-in), and fits the content's height. Docking under the list
    /// sets the card's width (and the notch's edge), which can change the height: then it measures once more.
    func reposition(animated: Bool, again: Bool = true) {
        guard let p = panel, let h = host else { return }
        let target = HelperPanel.targetFrame()
        let g = PermissionGuide.shared
        if (target == nil) != g.noWindow { g.noWindow = target == nil }
        let ns = target.map(toNS)
        let screen = (ns.flatMap { r in NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) } } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let (f, side) = HelperDock.dock(height: ceil(h.fittingSize.height), target: ns, screen: screen, notch: HelperPanelView.notch)
        let card = f.width - 2 * HelperPanelView.notch
        if side != g.dock || card != g.cardWidth {
            g.dock = side
            g.cardWidth = card
            // the view takes the new width on its next pass: measure again then, not 0.25 s later
            if again { DispatchQueue.main.async { [weak self] in self?.reposition(animated: animated, again: false) } }
        }
        let size = f.size
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
                    w.contentView = StandInView()
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

/// The stand-in's content (test builds): a sidebar and a permission list where HelperDock expects them, so a test can
/// see the panel line up with the list it points at.
final class StandInView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let list = HelperDock.listColumn(bounds)
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: list.minX, height: bounds.height).fill()
        let box = NSRect(x: list.minX + 20, y: 70, width: list.width - 40, height: 4 * 36)
        NSColor.textBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        NSColor.separatorColor.setFill()
        for (i, name) in ["App A", "App B", "App C", "App D"].enumerated() {
            (name as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + CGFloat(i) * 36 + 10), withAttributes: attrs)
            if i > 0 { NSRect(x: box.minX + 12, y: box.minY + CGFloat(i) * 36, width: box.width - 24, height: 1).fill(using: .sourceOver) }
        }
        ("Stand-in for System Settings (test build)" as NSString).draw(at: NSPoint(x: list.minX + 20, y: 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: - the content

/// The panel, compact: where you are and the way out on one line (the walk's dots, the permission's name, "2 of 3",
/// Skip, close), then what to do — the Blurt tile to drag beside the headline, why, and the drag hint. An opaque card
/// (panel / raise surfaces, §2.4) so its contrast never depends on what is behind it, with a notch on the edge that
/// faces the System Settings list (docked under it: the top edge, over the tile) instead of an arrow in the text.
struct HelperPanelView: View {
    @ObservedObject var g = PermissionGuide.shared
    static let notch: CGFloat = 8
    /// beside the window: the notch's centre from the card's top, level with the headline
    static let notchY: CGFloat = 50
    /// under the list: the notch's centre from the card's left, over the tile
    static let notchX: CGFloat = pad + tile / 2
    static let pad: CGFloat = 14
    static let tile: CGFloat = 44

    var below: Bool { g.dock == .below }
    /// the step shows the Blurt tile: only then does the notch on the top edge (docked under the list) have something to
    /// point from (the microphone step and "Done" have no tile, so the top edge stays plain)
    var showsTile: Bool { g.current.map { $0.acceptsDrop && !g.stepDone } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let k = g.current {
                stepView(k)
            } else if let f = g.finished {
                doneView(f, detail: g.finishedDetail)
                if g.finishedRestart {
                    // Screen Recording applies after a relaunch: the way to it, here as in Settings → Privacy
                    HStack {
                        Spacer()
                        Button(T("settings.perm.restart")) { SystemAccess.relaunch() }.controlSize(.small)
                    }
                    .padding(.top, 10)
                }
            }
        }
        .padding(.horizontal, HelperPanelView.pad).padding(.top, 10).padding(.bottom, 12)
        .frame(width: g.cardWidth, alignment: .leading)
        .background(NotchedCard(side: g.dock, tile: showsTile).fill(HelperPanelView.surface).padding(NotchedCard.room))
        .overlay(NotchedCard(side: g.dock, tile: showsTile).stroke(Color.primary.opacity(0.12), lineWidth: 0.5).padding(NotchedCard.room))
        // the window: the notch's room on the sides (and above, docked under the list), the hairline inside it
        .padding(.horizontal, HelperPanelView.notch).padding(.top, below ? HelperPanelView.notch : 1).padding(.bottom, 1)
    }

    /// panel white (light) / #2A2A2A (dark), as the app's popovers
    static let surface = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : .white
    })

    var header: some View {
        HStack(spacing: 8) {
            if g.steps.count > 1 && !g.mayGrow { GuideDots(g: g) }
            Text(progress).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if g.running && !g.stepDone {
                Button(T("onboarding.guide.skip")) { g.skip() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.system(size: 12))
            }
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
        // a walk that may still gain a step (Input Monitoring after Accessibility) promises no total
        return g.steps.count > 1 && !g.mayGrow ? T("onboarding.guide.progress", PermissionGuide.name(k), i + 1, g.steps.count) : PermissionGuide.name(k)
    }

    @ViewBuilder func stepView(_ k: PermissionKind) -> some View {
        if g.stepDone {
            doneView(g.headline(k), detail: nil)
        } else if k == .screen && g.reauthorize {
            readdSteps
        } else {
            HStack(alignment: .center, spacing: 12) {
                if k.acceptsDrop {
                    AppTile().frame(width: HelperPanelView.tile - 8, height: HelperPanelView.tile - 8)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .help(T("settings.perm.drag_hint"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.headline(k)).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(g.guideWhy(k)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if k.acceptsDrop {
                        Text(T("onboarding.guide.drag")).font(.system(size: 12)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // the whole card drags the app, not only its icon (BA-48): a bigger thing to grab
            .background { if k.acceptsDrop { AppTile(drawsIcon: false) } }
            .padding(.top, 10)
            if k == .screen && g.suggestRestart {
                Text(T("settings.perm.restart_hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            // what's needed only sometimes: System Settings closed, or Screen Recording's restart
            let reopen = g.noWindow && !(k == .microphone && SystemAccess.state(.microphone) == .notAsked)
            if reopen || k == .screen {
                HStack(spacing: 8) {
                    Spacer()
                    if reopen { Button(T("settings.perm.open_settings")) { g.reopenPane() }.controlSize(.small) }
                    if k == .screen {
                        Button(T("settings.perm.restart")) { g.restartForScreen() }.controlSize(.small)
                            .help(T("settings.perm.restart_hint"))
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    /// Re-adding a stale Screen Recording grant: what it is and why, then its three steps, each a card of its own —
    /// 1 remove Blurt with the list's minus button (drawn as that button, so it never reads as a dash), 2 drag Blurt
    /// back in (the tile), 3 turn it on and restart (the button).
    var readdSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("settings.perm.screen.readd_title")).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(T("settings.perm.screen.readd_why")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            readdCard(1, T("settings.perm.screen.readd_step1")) { MinusButtonGlyph() }
            readdCard(2, T("settings.perm.screen.readd_step2")) {
                AppTile().frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                    .help(T("settings.perm.drag_hint"))
            }
            .background(AppTile(drawsIcon: false))          // the whole card drags Blurt, as on the other steps
            readdCard(3, T("settings.perm.screen.readd_step3")) {
                Button(T("settings.perm.restart")) { g.restartForScreen() }.controlSize(.small)
            }
            if g.noWindow {
                HStack { Spacer(); Button(T("settings.perm.open_settings")) { g.reopenPane() }.controlSize(.small) }
            }
        }
        .padding(.top, 10)
    }

    func readdCard<Trailing: View>(_ n: Int, _ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
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
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
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

/// The card's outline: a rounded rectangle with a small notch on the edge that faces System Settings (docked under its
/// list: the top edge, over the tile, and only while the tile shows; right of its window: the left edge; left of it: the
/// right edge; inside it or with no window: none). `rect` is the card plus the notch's room (`room`) on the sides and above.
struct NotchedCard: Shape {
    var top: Bool
    /// the notch on the left edge (docked right of the window) / on the right edge (docked left of it)
    var left: Bool
    var right: Bool
    var radius: CGFloat = 12

    init(side: HelperDock.Side, tile: Bool = true) { top = side == .below && tile; left = side == .right; right = side == .left }

    /// what the shape's rect adds around the card
    static let room = EdgeInsets(top: -HelperPanelView.notch, leading: -HelperPanelView.notch, bottom: 0, trailing: -HelperPanelView.notch)

    func path(in rect: CGRect) -> Path {
        let n = HelperPanelView.notch, r = radius, y = HelperPanelView.notchY, x = HelperPanelView.notchX
        let b = CGRect(x: rect.minX + n, y: rect.minY + n, width: rect.width - 2 * n, height: rect.height - n)
        var p = Path()
        p.move(to: CGPoint(x: b.minX + r, y: b.minY))
        if top {
            p.addLine(to: CGPoint(x: b.minX + x - n, y: b.minY))
            p.addLine(to: CGPoint(x: b.minX + x, y: b.minY - n))
            p.addLine(to: CGPoint(x: b.minX + x + n, y: b.minY))
        }
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
/// `drawsIcon` false: an invisible surface behind the step's text that drags the same thing.
struct AppTile: NSViewRepresentable {
    var drawsIcon = true
    func makeNSView(context: Context) -> AppTileView { let v = AppTileView(); v.drawsIcon = drawsIcon; return v }
    func updateNSView(_ v: AppTileView, context: Context) { v.drawsIcon = drawsIcon }
}

final class AppTileView: NSView, NSDraggingSource {
    private var icon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }
    private var dragging = false
    var drawsIcon = true { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        setAccessibilityLabel(T("onboarding.guide.drag"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if drawsIcon { icon.draw(in: bounds.insetBy(dx: 2, dy: 2)) }
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
        // from the surface: the icon at its tile's size, under the pointer
        let at = convert(event.locationInWindow, from: nil)
        let frame = drawsIcon ? bounds : NSRect(x: at.x - 22, y: at.y - 22, width: 44, height: 44)
        item.setDraggingFrame(frame, contents: icon)
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

/// System Settings' minus button under a list, drawn as that button (a small bordered square with a minus symbol): in
/// a sentence a bare "−" reads as a dash.
struct MinusButtonGlyph: View {
    var body: some View {
        Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(T("settings.perm.screen.minus_button"))
    }
}
