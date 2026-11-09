// The keys as pages of one list, like the emoji keyboard: one section after another, each coming to rest at its top, so a key has the same
// place each time. The tabs jump to the sections and follow the list. A section that outgrows the view scrolls a row at a time. A section
// shorter than the view is followed straight away by the next, never by a blank (in landscape the letters' rows are lower than the view). Keys here are ordinary KeyCells; what's
// special is who gets a touch (KeyCell, on `committed`).
import UIKit

final class KeyList: UIScrollView, UIScrollViewDelegate {
    private(set) var cells: [KeyCell] = []
    private var sections: [KeySection] = []
    private var sectionTops: [CGFloat] = []
    private var rowTops: [CGFloat] = []
    private let editButton = UIButton(type: .system)
    private var size: CGSize = .zero
    private var laidOutWidth: CGFloat = 0
    private var laidOutTallest: CGFloat?
    /// big screens: the gap in the middle of every row, where the trackpad between the thumbs is (PadLayout.listSplit)
    private var split: (at: CGFloat, width: CGFloat)?
    var onSection: ((Int) -> Void)?
    var onEdit: (() -> Void)?
    var onCycle: ((Bool, KeyCell?) -> Void)?
    private(set) var section = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        delaysContentTouches = false
        canCancelContentTouches = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        decelerationRate = .fast
        clipsToBounds = true
        editButton.setTitle(String(localized: "Edit Keys"), for: .normal)
        editButton.tintColor = Theme.caption
        editButton.titleLabel?.font = .systemFont(ofSize: 14)
        editButton.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .touchUpInside)
        addSubview(editButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The gap between the halves isn't the list's: a touch there is the trackpad's, under it.
    override func point(inside p: CGPoint, with e: UIEvent?) -> Bool {
        if let s = split, p.x > s.at, p.x < s.at + s.width { return false }
        return super.point(inside: p, with: e)
    }

    /// A key that has acted keeps its touch; any other gives way to the scroll.
    override func touchesShouldCancel(in view: UIView) -> Bool {
        guard let c = view as? KeyCell else { return true }
        return c.givesWay
    }

    func show(_ list: [KeySection]) {
        guard list != sections else { return }
        sections = list
        section = min(section, max(0, list.count - 1))
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        for s in list {
            for slot in s.slots {
                let c = KeyCell()
                c.inList = true
                c.slot = slot
                c.onCycle = { [weak self, weak c] on in self?.cycling(on, c) }
                addSubview(c)
                cells.append(c)
            }
        }
        size = .zero
        setNeedsLayout()
    }

    private func cycling(_ on: Bool, _ c: KeyCell?) {
        isScrollEnabled = !on
        onCycle?(on, c)
    }

    /// Key sizes come from PadLayout, so every page has the same rows. A section can ask for more across: the letters, the size of the iPhone's own.
    /// In landscape narrower keys are never much taller than a phone's own (`tallest`): the letters would be strips twice as tall as wide.
    static let tallest: CGFloat = 1.4

    /// `tallest`: in landscape, no key taller than this times its width (nil: as tall as `key`). `split`: a gap down the middle, each
    /// row's columns half on each side of it (the left gets the odd one)
    func arrange(key: CGSize, gap: CGFloat, tallest: CGFloat? = nil, split: (at: CGFloat, width: CGFloat)? = nil) {
        guard key.width > 0, key != size || bounds.width != laidOutWidth || tallest != laidOutTallest
                || split?.at != self.split?.at || split?.width != self.split?.width else { return }
        size = key
        laidOutWidth = bounds.width
        laidOutTallest = tallest
        self.split = split
        let width = bounds.width
        let h = key.height
        // the view: rows of a section longer than it are stops of their own
        let page = max(h, bounds.height)
        var y: CGFloat = 0, n = 0
        sectionTops = []
        rowTops = []
        for s in sections {
            let top = y
            sectionTops.append(top)
            rowTops.append(top)
            let across = max(1, s.columns)
            let w = (width - gap * CGFloat(across - 1)) / CGFloat(across)
            let h = tallest.map { min(h, floor(w * $0)) } ?? h
            let place = Self.columns(across, width: width, gap: gap, split: split)
            var column = 0
            var rows: [CGFloat] = []
            for slot in s.slots {
                let span = min(across, max(1, slot.span ?? 1))
                if column + span > across {
                    column = 0
                    y += h + gap
                }
                if column == 0, y > top { rows.append(y) }
                if split != nil {
                    // a wide key never reaches across the gap: it ends at its side's edge
                    let first = place[column], side = column < (across + 1) / 2
                    let lastColumn = min(column + span - 1, side ? (across + 1) / 2 - 1 : across - 1)
                    cells[n].frame = CGRect(x: first.lowerBound, y: y, width: place[lastColumn].upperBound - first.lowerBound, height: h)
                } else {
                    cells[n].frame = CGRect(x: CGFloat(column) * (w + gap), y: y, width: w * CGFloat(span) + gap * CGFloat(span - 1), height: h)
                }
                n += 1
                column += span
            }
            if !s.slots.isEmpty { y += h + gap }
            // a section longer than the view: every row of it is a stop, so it scrolls a row at a time
            if y - gap - top > page { rowTops += rows }
            y = max(y, top + gap)
        }
        // by the dominant thumb's half, never across the middle
        editButton.frame = split.map { CGRect(x: $0.at + $0.width, y: y, width: width - $0.at - $0.width, height: 44) } ?? CGRect(x: 0, y: y, width: width, height: 44)
        y += 44
        // every section can come to the top
        let last = sectionTops.last ?? 0
        contentSize = CGSize(width: width, height: max(y, last + bounds.height))
        // turned the phone, or opened the keys: keys changed size, and the same section stays in view
        if sectionTops.indices.contains(section) { contentOffset.y = min(sectionTops[section], max(0, contentSize.height - bounds.height)) }
    }

    /// Where each column of a row goes, x and width: evenly across, or half each side of the split.
    static func columns(_ across: Int, width: CGFloat, gap: CGFloat, split: (at: CGFloat, width: CGFloat)?) -> [ClosedRange<CGFloat>] {
        guard let s = split else {
            let w = (width - gap * CGFloat(across - 1)) / CGFloat(across)
            return (0..<across).map { let x = CGFloat($0) * (w + gap); return x...(x + w) }
        }
        let left = (across + 1) / 2, right = across - left
        let wl = (s.at - gap * CGFloat(left - 1)) / CGFloat(left)
        let rightStart = s.at + s.width, rightW = width - rightStart
        let wr = right > 0 ? (rightW - gap * CGFloat(right - 1)) / CGFloat(right) : 0
        return (0..<across).map { c in
            if c < left { let x = CGFloat(c) * (wl + gap); return x...(x + wl) }
            let x = rightStart + CGFloat(c - left) * (wr + gap)
            return x...(x + wr)
        }
    }

    func scroll(toSection i: Int) {
        guard sectionTops.indices.contains(i) else { return }
        let top = min(sectionTops[i], max(0, contentSize.height - bounds.height))
        setContentOffset(CGPoint(x: 0, y: top), animated: true)
    }

    func scrollViewDidScroll(_ s: UIScrollView) {
        // the section at the top of the list; the last ones may never reach it, so the bottom counts too
        let y = contentOffset.y + 1
        var now = sectionTops.lastIndex { $0 <= y } ?? 0
        if contentOffset.y >= contentSize.height - bounds.height - 1, !sectionTops.isEmpty { now = max(now, sectionTops.count - 1) }
        guard now != section else { return }
        section = now
        onSection?(now)
    }

    func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity v: CGPoint, targetContentOffset t: UnsafeMutablePointer<CGPoint>) {
        let limit = max(0, contentSize.height - bounds.height)
        guard t.pointee.y < limit - 1 else { return }
        if let best = rowTops.min(by: { abs($0 - t.pointee.y) < abs($1 - t.pointee.y) }) { t.pointee.y = min(best, limit) }
    }
}
