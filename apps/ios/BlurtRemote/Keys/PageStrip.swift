// The list's sections by name: one tap jumps there, and the mark follows as the list scrolls. On a big screen the row is as tall as the
// arrow key (88 pt), and one line of names in the middle of it was small text in an empty box: there they go two by two, larger.
import UIKit

final class PageStrip: UIView {
    var onSelect: ((Int) -> Void)?
    private var labels: [UILabel] = []
    private var current = 0
    /// one size for every tab: what fits them all with a gap between, at most 13. Each shrunk on its own, a long name came out smaller
    /// than its neighbours and touching them ("LettersSymbols")
    private var size: CGFloat = 13
    static let minGap: CGFloat = 10
    /// lines of names, where the strip is tall enough for more than one
    private(set) var rows = 1
    /// a line takes at least this much height; under two of these the strip is one line, as on a phone
    static let minLine: CGFloat = 28
    /// the names' size where there's the height
    static let tallSize: CGFloat = 17
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

    /// The names' widths at a size, at the weight the current one has.
    private func widths(_ s: CGFloat) -> [CGFloat] {
        labels.map { ceil(($0.text ?? "" as String).size(withAttributes: [.font: UIFont.systemFont(ofSize: s, weight: .semibold)]).width) }
    }

    /// How many lines, and the one size that fits them all: the largest there is. Fewer lines where two arrangements come out the same.
    static func arrange(count: Int, in size: CGSize, widest: (CGFloat) -> CGFloat) -> (rows: Int, size: CGFloat) {
        var best: (rows: Int, size: CGFloat) = (1, 0)
        for rows in 1...max(1, min(count, Int(size.height / minLine))) {
            let columns = (count + rows - 1) / rows
            let room = size.width / CGFloat(columns) - minGap
            let natural = widest(tallSize)
            let fit = natural > room ? floor(tallSize * room / natural * 2) / 2 : tallSize
            if fit > best.size { best = (rows, fit) }
        }
        return (best.rows, max(10, best.size))
    }

    /// One line: each tab as wide as its name, the room left shared out evenly around them. More: a grid, so the columns line up.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !labels.isEmpty else { return }
        let n = labels.count
        var lines = 1, fit: CGFloat
        if bounds.height >= Self.minLine * 2 {
            (lines, fit) = Self.arrange(count: n, in: bounds.size) { widths($0).max() ?? 0 }
        } else {
            let room = bounds.width - Self.minGap * CGFloat(n), natural = widths(13).reduce(0, +)
            fit = natural > room ? max(10, floor(13 * room / natural * 2) / 2) : 13
        }
        if fit != size { size = fit; paint() }
        rows = lines
        guard lines == 1 else {
            let columns = (n + lines - 1) / lines
            let cell = CGSize(width: bounds.width / CGFloat(columns), height: bounds.height / CGFloat(lines))
            for (i, l) in labels.enumerated() {
                l.frame = CGRect(x: CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * cell.height, width: cell.width, height: cell.height)
            }
            return
        }
        let w = widths(size), gap = max(0, (bounds.width - w.reduce(0, +)) / CGFloat(n))
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
        guard let p = t.first?.location(in: self), let i = tab(at: p) else { return }
        onSelect?(i)
    }

    /// The frames tile the strip: the one under the finger, or the nearest.
    func tab(at p: CGPoint) -> Int? {
        func away(_ r: CGRect) -> CGFloat { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }
        return labels.indices.min { away(labels[$0].frame) < away(labels[$1].frame) }
    }
}
