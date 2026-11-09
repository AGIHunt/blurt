// The list's sections by name: one tap jumps there, and the mark follows as the list scrolls.
import UIKit

final class PageStrip: UIView {
    var onSelect: ((Int) -> Void)?
    private var labels: [UILabel] = []
    private var current = 0
    /// false: the keys are put away (a big screen), and every tab is a way back to them, none of them the one in view
    var showsSelection = true {
        didSet { if showsSelection != oldValue { paint() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(names: [String], page: Int) {
        current = page
        if labels.map(\.text) != names.map(Optional.some) {
            labels.forEach { $0.removeFromSuperview() }
            labels = names.map { n in
                let l = UILabel()
                l.text = n
                l.textAlignment = .center
                l.adjustsFontSizeToFitWidth = true
                l.minimumScaleFactor = 0.7
                l.isAccessibilityElement = true
                l.accessibilityTraits = .button
                addSubview(l)
                return l
            }
        }
        paint()
        setNeedsLayout()
    }

    private func paint() {
        for (i, l) in labels.enumerated() {
            let on = showsSelection && i == current
            l.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
            l.textColor = on ? Theme.mark : showsSelection ? Theme.faint : Theme.caption
            l.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / CGFloat(max(labels.count, 1))
        for (i, l) in labels.enumerated() { l.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height) }
    }

    /// Where the list is now: no animation of its own, it's already moving under the thumb.
    func select(_ i: Int) {
        guard i != current, labels.indices.contains(i) else { return }
        show(names: labels.compactMap(\.text), page: i)
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let x = t.first?.location(in: self).x, !labels.isEmpty, bounds.width > 0 else { return }
        onSelect?(max(0, min(labels.count - 1, Int(x / (bounds.width / CGFloat(labels.count))))))
    }
}
