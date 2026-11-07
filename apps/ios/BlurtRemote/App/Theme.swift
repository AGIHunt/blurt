// The look: an instrument in the dark. True black, keys as slabs barely lighter than it, white marks. Mint means one
// thing, as everywhere in Blurt: it is listening (docs/design/system.md §1).
import UIKit

enum Theme {
    static let mint = UIColor(red: 0x61 / 255, green: 0xDB / 255, blue: 0xBD / 255, alpha: 1)
    static let onMint = UIColor(red: 0x04 / 255, green: 0x26 / 255, blue: 0x1E / 255, alpha: 1)
    static let slab = UIColor(white: 0.135, alpha: 1)
    static let slabPressed = UIColor(white: 0.27, alpha: 1)
    /// the key that ends things, findable at a glance: Return
    static let slabStrong = UIColor(white: 0.21, alpha: 1)
    static let edge = UIColor(white: 1, alpha: 0.07)
    static let glass = UIColor(white: 0.04, alpha: 1)
    static let slabLatched = UIColor(white: 0.88, alpha: 1)
    static let hairline = UIColor(white: 0.17, alpha: 1)
    static let mark = UIColor(white: 1, alpha: 0.9)
    static let caption = UIColor(white: 1, alpha: 0.66)
    static let faint = UIColor(white: 1, alpha: 0.42)
    static let radius: CGFloat = 16
    static let keyRadius: CGFloat = 11
    static let talkRest = UIColor(red: 0.13, green: 0.20, blue: 0.185, alpha: 1)
}
