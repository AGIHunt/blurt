// The keys as one list, like the emoji keyboard: it scrolls, and comes to rest on a row, so a key has the same place each time. The tabs
// jump to its sections and follow it. Keys here are ordinary KeyCells; what's special is who gets a touch (KeyCell, on `committed`).
import UIKit

final class KeyList: UIScrollView, UIScrollViewDelegate {
    private(set) var cells: [KeyCell] = []
    private var headers: [UILabel] = []
    private var sections: [KeySection] = []
    private var sectionTops: [CGFloat] = []
    private var rowTops: [CGFloat] = []
    private let editButton = UIButton(type: .system)
    private var size: CGSize = .zero
    var onSection: ((Int) -> Void)?
    var onEdit: (() -> Void)?
    var onCycle: ((Bool, KeyCell?) -> Void)?
    private(set) var section = 0

    private static let headerHeight: CGFloat = 24

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
        headers.forEach { $0.removeFromSuperview() }
        cells = []
        headers = []
        for (i, s) in list.enumerated() {
            let h = UILabel()
            h.text = s.name
            h.font = .systemFont(ofSize: 11, weight: .medium)
            h.textColor = Theme.faint
            h.isHidden = i == 0     // the first screen is keys and nothing else
            addSubview(h)
            headers.append(h)
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

    /// Key sizes come from PadLayout, so the list and the dock line up. A section of plain keys is the size of the iPhone's own: as many across
    /// as it asks for, or seven where the list is narrow.
    func arrange(key: CGSize, gap: CGFloat) {
        guard key.width > 0, key != size else { return }
        size = key
        let width = bounds.width
        var y: CGFloat = 0, n = 0
        sectionTops = []
        rowTops = []
        for (i, s) in sections.enumerated() {
            if i > 0 {
                headers[i].frame = CGRect(x: 2, y: y + 4, width: width - 4, height: Self.headerHeight - 6)
                sectionTops.append(y)
                rowTops.append(y)
                y += Self.headerHeight
            } else {
                sectionTops.append(0)
            }
            let plain = s.columns > Deck.columns
            let across = plain && (width - gap * CGFloat(s.columns - 1)) / CGFloat(s.columns) < 26 ? 7 : s.columns
            let w = plain ? (width - gap * CGFloat(across - 1)) / CGFloat(across) : key.width
            let h = plain ? min(44, key.height) : key.height
            for j in s.slots.indices {
                if j % across == 0 {
                    if j > 0 { y += h + gap }
                    if j > 0 || i == 0 { rowTops.append(y) }
                }
                cells[n].frame = CGRect(x: CGFloat(j % across) * (w + gap), y: y, width: w, height: h)
                n += 1
            }
            if !s.slots.isEmpty { y += h + gap }
        }
        editButton.frame = CGRect(x: 0, y: y, width: width, height: 44)
        y += 44
        // every section can come to the top
        let last = sectionTops.last ?? 0
        contentSize = CGSize(width: width, height: max(y, last + bounds.height))
        // turned the phone, or opened the keys: keys changed size, and the same section stays in view
        if sectionTops.indices.contains(section) { contentOffset.y = min(sectionTops[section], max(0, contentSize.height - bounds.height)) }
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
