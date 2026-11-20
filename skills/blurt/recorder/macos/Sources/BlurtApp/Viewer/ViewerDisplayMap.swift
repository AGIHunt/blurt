// The display switcher (docs/design/remote-desktop-viewer.md): the host's displays drawn as its display settings arrange them. A click shows
// that one here; 跟着远端指针换屏 / Follow the Pointer goes back to following the host's pointer; 在新窗口中打开 / Open in New Window shows
// a display in a window of its own (a second session). The same map as the phone's (RemoteDisplayMap).
import AppKit
import BlurtRemoteKit
import SwiftUI

struct ViewerDisplayMapView: View {
    enum Action { case show(String), follow, newWindow(String) }
    var displays: [RemoteDisplay]
    var shown: String?
    var following: Bool
    var act: (Action) -> Void
    @State private var hover: String?

    private let box = CGSize(width: 300, height: 150)

    var body: some View {
        let map = RemoteDisplayMap.layout(displays, in: box, gap: 6, smallest: 40)
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(displays.enumerated()), id: \.element.id) { i, d in
                    if let r = map[d.id] {
                        let on = d.id == shown
                        RoundedRectangle(cornerRadius: 5)
                            .fill(on ? Color.brandAccent.opacity(0.85) : Color.primary.opacity(hover == d.id ? 0.16 : 0.09))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.brandAccent : Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Text("\(i + 1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? .white : .primary))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .help(d.name)
                            .onHover { hover = $0 ? d.id : (hover == d.id ? nil : hover) }
                            .onTapGesture { act(.show(d.id)) }
                            .contextMenu { Button(T("viewer.new_window")) { act(.newWindow(d.id)) } }
                            .accessibilityElement()
                            .accessibilityLabel(d.name)
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            // as tall as the arrangement, not the box: two side by side leave no gap under them
            .frame(width: box.width, height: max(40, map.values.map(\.maxY).max() ?? box.height), alignment: .topLeading)
            if let h = hover ?? shown, let d = displays.first(where: { $0.id == h }) {
                Text(d.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            Toggle(T("viewer.follow"), isOn: Binding(get: { following }, set: { if $0 { act(.follow) } else if let s = shown { act(.show(s)) } }))
                .toggleStyle(.checkbox)
            Button(T("viewer.new_window")) {
                if let other = displays.first(where: { $0.id != shown }) { act(.newWindow(hover ?? other.id)) }
            }
        }
        .padding(14)
        .frame(width: box.width + 28)
    }
}

/// The map in a popover.
final class ViewerDisplayMap: NSHostingController<ViewerDisplayMapView> {
    init(displays: [RemoteDisplay], shown: String?, following: Bool, act: @escaping (ViewerDisplayMapView.Action) -> Void) {
        super.init(rootView: ViewerDisplayMapView(displays: displays, shown: shown, following: following, act: act))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
