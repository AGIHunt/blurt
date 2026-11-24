// The line where one finger scrolls (docs/design/remote.md §Trackpad). Always there, and lit while it scrolls: a strip that shows only
// while it's used has to be known about first. Over the picture it's see-through with a dark rim, so it reads on a white page and a black one.
import UIKit

final class EdgeMark: UIView {
    /// the computer's screen is under it
    var overPicture = false { didSet { paint() } }
    /// a finger is scrolling along it now
    var lit = false {
        didSet {
            guard lit != oldValue else { return }
            UIView.animate(withDuration: lit ? 0.08 : 0.3, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { self.paint() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 2
        layer.borderColor = UIColor(white: 0, alpha: 0.45).cgColor
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func paint() {
        backgroundColor = UIColor(white: 1, alpha: lit ? 0.9 : overPicture ? 0.5 : 0.28)
        layer.borderWidth = overPicture ? 0.5 : 0
    }
}
