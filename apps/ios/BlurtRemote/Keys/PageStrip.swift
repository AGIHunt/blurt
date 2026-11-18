// The list's sections by name: one tap jumps there, and the mark follows as the list scrolls.
import UIKit

final class PageStrip: UIView {
    var onSelect: ((Int) -> Void)?
    private var labels: [UILabel] = []
    private var current = 0
    /// one size for every tab: what fits them all with a gap between, at most 13. Each shrunk on its own, a long name came out smaller
    /// than its neighbours and touching them ("LettersSymbols")
    private var size: CGFloat = 13
    static let minGap: CGFloat = 10
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
            l.font = .systemFont(ofSize: size, weight: on ? .semibold : .regular)
            l.textColor = on ? Theme.mark : showsSelection ? Theme.faint : Theme.caption
            l.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    /// Each tab as wide as its name, the room left shared out evenly around them.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !labels.isEmpty else { return }
        func widths(_ s: CGFloat) -> [CGFloat] {
            labels.map { ceil(($0.text ?? "" as String).size(withAttributes: [.font: UIFont.systemFont(ofSize: s, weight: .semibold)]).width) }
        }
        let n = CGFloat(labels.count), room = bounds.width - Self.minGap * n
        let natural = widths(13).reduce(0, +)
        let fit = natural > room ? max(10, floor(13 * room / natural * 2) / 2) : 13
        if fit != size { size = fit; paint() }
        let w = widths(size), gap = max(0, (bounds.width - w.reduce(0, +)) / n)
        var x = gap / 2
        for (i, l) in labels.enumerated() {
            l.frame = CGRect(x: x - gap / 2, y: 0, width: w[i] + gap, height: bounds.height)
            x += w[i] + gap
        }
    }

    /// Where the list is now: no animation of its own, it's already moving under the thumb.
    func select(_ i: Int) {
        guard i != current, labels.indices.contains(i) else { return }
        show(names: labels.compactMap(\.text), page: i)
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let x = t.first?.location(in: self).x, !labels.isEmpty, bounds.width > 0 else { return }
        // the frames tile the strip: the one under the finger, or the nearer end
        onSelect?(labels.firstIndex { $0.frame.minX <= x && x < $0.frame.maxX } ?? (x < bounds.midX ? 0 : labels.count - 1))
    }
}
