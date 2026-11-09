// The iPhone Duo's numbers, as UIKit gives them (points). The closed display's are read from the app itself on the iPhone Duo simulator
// (Xcode 27.2, iOS 27.2 runtime 24B91016s; a debug build logs `BLURT_ROOM` with the bounds, safeAreaInsets and every
// UIView.reservedRegions region). The open display's size is its panel (2007×2853 px at 3×); the simulator couldn't be opened here, so
// its safe area and the fold's band when partly folded are still estimates (docs/design/remote.md §iPad and iPhone Duo).
import UIKit

enum Duo {
    // closed: measured
    static let outerShort: CGFloat = 466
    static let outerLong: CGFloat = 678
    /// portrait: the system keeps a band down the right for the bars it puts there, and the home indicator's
    static let outerPortraitSafe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
    /// turned (landscapeLeft): the same insets
    static let outerLandscapeSafe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)

    /// the outer camera: the lens, and the region kept clear around it. Top right in portrait, bottom right turned left
    static func outerCamera(portrait: Bool, _ size: CGSize) -> [CGRect] {
        portrait ? [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 82)]
            : [CGRect(x: size.width - 66.33, y: size.height - 66.33, width: 37, height: 37), CGRect(x: size.width - 84, y: size.height - 82, width: 84, height: 82)]
    }

    // open: the panel's size; which way up the UI stands when open, its safe area and the fold's band are not yet read
    static let innerShort: CGFloat = 669
    static let innerLong: CGFloat = 951
    /// the fold's band when partly folded, margins included (estimate)
    static let foldBand: CGFloat = 24
    static let innerSafe = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
}
