// The iPhone Duo's numbers, as UIKit gives them (points). Measured on the iPhone Duo simulator (Xcode 27.2, iOS 27.1 runtime) with the
// app itself: window bounds, safeAreaInsets, and UIView.reservedRegions (docs/design/remote.md §iPad and iPhone Duo).
import UIKit

enum Duo {
    static let outerShort: CGFloat = 466
    static let outerLong: CGFloat = 678
    static let innerShort: CGFloat = 626
    static let innerLong: CGFloat = 890
    /// the fold's band when partly folded, margins included
    static let foldBand: CGFloat = 24

    static let outerPortraitSafe = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 60)
    static let outerLandscapeSafe = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 60)
    static let innerSafe = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)

    /// the outer camera, a corner of the display: top right in portrait, the right end's top in landscape
    static func outerCamera(portrait: Bool, _ size: CGSize) -> CGRect {
        portrait ? CGRect(x: size.width - 60, y: 0, width: 60, height: 60) : CGRect(x: size.width - 60, y: 0, width: 60, height: 60)
    }
}
