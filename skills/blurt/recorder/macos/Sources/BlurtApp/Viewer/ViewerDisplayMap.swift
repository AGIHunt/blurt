// The display switcher (docs/design/remote-desktop-viewer.md): a popover under the toolbar's Display button, on one solid sheet (white /
// the elevated #2A2A2A, system.md's hover-note rule: the remote picture never shows through it). On top, the host's displays as its
// display settings arrange them (the phone's RemoteDisplayMap); under them one list on the Move popover's grid (28 pt rows, glyphs 12 pt
// in, text at 36 pt): 跟着远端指针换屏 / Follow Remote Pointer first, then a row per display, its number and its name. A tile and its row
// are one target: the pointer over either lights both, a click on either shows that display here.
//
// Two states that never look alike: pinned to a display (a 2 pt accent ring and the brand tint on its tile, a check on its row) or
// following the pointer (a check on Follow, and only a small pointer on the display the remote pointer is on). Open in New Window is a
// glyph on a display's row under the pointer, its tooltip naming the display, and in the context menu of every tile and row.
import AppKit
import BlurtRemoteKit
import SwiftUI

/// What the switcher shows; the window keeps it current while it's open (and the test hooks set the pointer over a display).
final class ViewerDisplayMapModel: ObservableObject {
    @Published var displays: [RemoteDisplay]
    @Published var shown: String?
    @Published var following: Bool
    /// the display under the pointer, on its tile or its row; "follow": the Follow row
    @Published var hover: String?

    init(displays: [RemoteDisplay], shown: String?, following: Bool) {
        self.displays = displays
        self.shown = shown
        self.following = following
    }
}

struct ViewerDisplayMapView: View {
    enum Action { case show(String), follow, newWindow(String) }
    @ObservedObject var model: ViewerDisplayMapModel
    var act: (Action) -> Void

    static let width: CGFloat = 300
    private static let inset: CGFloat = 14
    /// the arrangement's box; the map is as tall as what's drawn in it
    private static let box = CGSize(width: width - inset * 2, height: 116)
    private static let rowHeight: CGFloat = 28

    /// The sheet: white in light, the elevated #2A2A2A in dark, opaque (ViewerDisplayMap paints the popover's own frame with it too).
    static let surface = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1) : .white
    }
    /// a display at rest: black 6 % / white 10 %; under the pointer 5 % more
    private static func tileFill(hover: Bool) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white.withAlphaComponent(hover ? 0.15 : 0.10)
                : .black.withAlphaComponent(hover ? 0.11 : 0.06)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            map
                .padding(.horizontal, Self.inset)
                .padding(.vertical, Self.inset)
            Divider()
            followRow
                .padding(.vertical, 4)
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { i, d in displayRow(i, d) }
            }
            .padding(.top, 4).padding(.bottom, 6)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: Self.surface))
    }

    // MARK: the arrangement

    private var pinnedShown: String? { model.following ? nil : model.shown }

    private var map: some View {
        let laid = RemoteDisplayMap.layout(model.displays, in: Self.box, gap: 10, smallest: 36)
        // as tall as the arrangement, centred both ways in the box's width: no top offset, no dead strip
        let all = laid.values.reduce(CGRect.null) { $0.union($1) }
        let top = all.isNull ? 0 : all.minY
        let height = all.isNull ? 40 : max(36, all.height)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.displays.enumerated()), id: \.element.id) { i, d in
                if let r = laid[d.id] {
                    tile(i, d)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY - top)
                }
            }
        }
        // the pinned display's ring sits 3 pt outside its tile: room for it above and below
        .frame(width: Self.box.width, height: height, alignment: .topLeading)
        .padding(.vertical, 3)
    }

    private func tile(_ i: Int, _ d: RemoteDisplay) -> some View {
        let pinned = d.id == pinnedShown
        let pointer = model.following && d.id == model.shown
        let hover = model.hover == d.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack {
            shape.fill(pinned ? Color.brandTint : Self.tileFill(hover: hover))
            // the host's main display: its menu bar, as System Settings draws it
            if d.main {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 3)
                    Spacer(minLength: 0)
                }
                .clipShape(shape)
            }
            shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            Text(verbatim: "\(i + 1)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(pinned || pointer ? Color.primary : Color.secondary)
            if pointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
                    .help(T("viewer.display.pointer"))
            }
        }
        .overlay {
            if pinned {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.brandAccent, lineWidth: 2)
                    .padding(-3)
            }
        }
        .contentShape(shape)
        .help(d.name)
        .onHover { setHover(d.id, $0) }
        .onTapGesture { act(.show(d.id)) }
        .contextMenu { Button(T("viewer.new_window")) { act(.newWindow(d.id)) } }
        .accessibilityElement()
        .accessibilityLabel("\(i + 1) \(d.name)")
        .accessibilityAddTraits(pinned ? [.isButton, .isSelected] : .isButton)
    }

    private func setHover(_ id: String, _ on: Bool) {
        if on { model.hover = id } else if model.hover == id { model.hover = nil }
    }

    // MARK: the list

    private var followRow: some View {
        row(id: "follow") {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } title: {
            Text(T("viewer.follow")).font(.system(size: 13)).lineLimit(1)
        } action: {
            EmptyView()
        } mark: {
            if model.following { check }
        }
        .help(T("viewer.follow.tip"))
        // following off pins the display shown now
        .onTapGesture { if model.following { if let s = model.shown { act(.show(s)) } } else { act(.follow) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(T("viewer.follow"))
        .accessibilityAddTraits(model.following ? [.isButton, .isSelected] : .isButton)
    }

    private func displayRow(_ i: Int, _ d: RemoteDisplay) -> some View {
        let hover = model.hover == d.id
        let pointer = model.following && d.id == model.shown
        return row(id: d.id) {
            Text(verbatim: "\(i + 1)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        } title: {
            HStack(spacing: 6) {
                Text(d.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    .help(d.name)
                if d.main {
                    Text(T("viewer.display.main")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize()
                }
            }
        } action: {
            // only under the pointer: the action names its display, nothing sits at rest
            if hover {
                Button { act(.newWindow(d.id)) } label: {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(T("viewer.new_window.named", i + 1))
                .accessibilityLabel(T("viewer.new_window.named", i + 1))
            }
        } mark: {
            if d.id == pinnedShown {
                check
            } else if pointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(T("viewer.display.pointer"))
            }
        }
        .onTapGesture { act(.show(d.id)) }
        .contextMenu { Button(T("viewer.new_window")) { act(.newWindow(d.id)) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(i + 1) \(d.name)")
        .accessibilityAddTraits(d.id == pinnedShown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: T("viewer.new_window.named", i + 1)) { act(.newWindow(d.id)) }
    }

    private var check: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.brandInk)
    }

    /// One row of the grid: a 16 pt glyph slot 12 pt in, the text at 36 pt, an action slot shown under the pointer, a 28 pt column for
    /// the check. The pointer over it washes it (neutral, inset 6 pt, r 6) and lights its tile.
    private func row<Lead: View, Title: View, Action: View, Mark: View>(id: String, @ViewBuilder lead: () -> Lead,
                                                                         @ViewBuilder title: () -> Title, @ViewBuilder action: () -> Action,
                                                                         @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 0) {
            ZStack { Color.clear; lead() }.frame(width: 16, height: Self.rowHeight)
                .padding(.leading, 12)
            title()
                .padding(.leading, 8)
            Spacer(minLength: 6)
            action()
            ZStack { Color.clear; mark() }.frame(width: 28, height: Self.rowHeight)  // kept when empty: the check never moves
                .padding(.trailing, 4)
        }
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(model.hover == id ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { setHover(id, $0) }
    }
}

/// The map in a popover, on its solid sheet.
final class ViewerDisplayMap: NSHostingController<ViewerDisplayMapView> {
    let model: ViewerDisplayMapModel
    private var painted: NSView?

    init(displays: [RemoteDisplay], shown: String?, following: Bool, act: @escaping (ViewerDisplayMapView.Action) -> Void) {
        let m = ViewerDisplayMapModel(displays: displays, shown: shown, following: following)
        model = m
        super.init(rootView: ViewerDisplayMapView(model: m, act: act))
        sizingOptions = [.preferredContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    /// The popover's own frame (its arrow too) gets the sheet's colour under its material, so nothing of the remote picture comes
    /// through: the material over a solid colour is that colour.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard painted == nil, let frame = view.window?.contentView?.superview else { return }
        let bg = SheetView(frame: frame.bounds)
        bg.autoresizingMask = [.width, .height]
        frame.addSubview(bg, positioned: .below, relativeTo: frame.subviews.first)
        painted = bg
    }

    /// a plain fill in the sheet's colour, redrawn with the appearance
    private final class SheetView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            ViewerDisplayMapView.surface.setFill()
            dirtyRect.fill()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
