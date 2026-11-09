// The fold and the cameras, from UIKit (iOS 27.1, `UIView.reservedRegions`), for PadLayout. Only what the system reports: no device names,
// no accelerometer guessing at how the phone is held. Built with an older SDK (Xcode 26) this is empty, and the layout goes by size alone.
//
// The fold is read with `.includeInactive`: fully open it's still there, inactive, so the keys are laid out clear of it already and
// folding moves nothing but the stage (Apple: "keep your layout from jumping when the region becomes active"). A hinge interaction
// asks for a new layout whenever the hinge moves, in case the regions change without a size change.
import UIKit

enum Surroundings {
    /// UIKit 9127.0.85 is the iOS 27.1 SDK's (Xcode 27.1), the first with reserved regions and the hinge.
    static func read(_ v: UIView) -> PadSurround {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            var s = PadSurround()
            // the widest division is the fold; there's only one on the Duo
            let folds = v.reservedRegions(kind: .division, options: .includeInactive)
            if let f = folds.max(by: { max($0.frame.width, $0.frame.height) < max($1.frame.width, $1.frame.height) }) {
                // flat, it can be a line with no width: two points, so it still has a side
                var r = f.frame
                if r.width < 2, r.height >= r.width { r = r.insetBy(dx: (r.width - 2) / 2, dy: 0) }
                if r.height < 2, r.width > r.height { r = r.insetBy(dx: 0, dy: (r.height - 2) / 2) }
                s.fold = r
                s.foldActive = f.isActive
            }
            s.occlusions = v.reservedRegions(kind: .occlusion).map(\.frame).filter { !$0.isEmpty }
            return s
        }
        #endif
        return .none
    }

    /// Asks `layout` again whenever the hinge moves. Nothing on a device without one.
    static func watchHinge(_ v: UIView, layout: @escaping () -> Void) {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            v.addInteraction(UIHingeInteraction { _, u in
                #if DEBUG
                NSLog("%@", "BLURT_HINGE status=\(u.hinge.map { "\($0.status.rawValue)" } ?? "none") angle=\(u.hinge.map { "\($0.angle)" } ?? "-")")
                #endif
                layout()
            })
        }
        #endif
    }

    #if DEBUG
    /// Everything UIKit says about the room, for the log: where the Duo's numbers in the tests come from.
    static func describe(_ v: UIView) -> String {
        let scene = v.window?.windowScene
        var s = "size=\(v.bounds.size) safe=\(v.safeAreaInsets) scale=\(v.traitCollection.displayScale) sizeClass=\(v.traitCollection.horizontalSizeClass.rawValue)/\(v.traitCollection.verticalSizeClass.rawValue) orientation=\(scene?.effectiveGeometry.interfaceOrientation.rawValue ?? -1) screen=\(scene?.screen.bounds.size ?? .zero) active=\(scene?.activationState.rawValue ?? -1)"
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            for k in [UIView.ReservedRegion.Kind.division, .occlusion] {
                for r in v.reservedRegions(kind: k, options: .includeInactive) {
                    s += " \(k == .division ? "division" : "occlusion")=\(r.frame) margins=\(r.margins) active=\(r.isActive)"
                }
            }
        }
        #endif
        return s
    }
    #endif
}

extension PadLayout {
    /// What the computer should send, in pixels: enough for the stage when a zoomed picture fills it. Its shape is the screen's, so a
    /// tall stage needs the picture's width at the stage's height (docs/design/remote.md §iPad and iPhone Duo).
    static func outputPixels(stage: CGSize, aspect: CGFloat, scale: CGFloat) -> CGSize {
        guard stage.width > 0, stage.height > 0, aspect > 0 else { return .zero }
        let w = max(stage.width, stage.height * aspect), h = max(stage.width / aspect, stage.height)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}
