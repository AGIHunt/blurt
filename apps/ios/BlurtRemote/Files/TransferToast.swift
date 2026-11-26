// What Get Copied Items (or a paste from here) came to, on the pad while the Transfer sheet is away: a slab like the status card's,
// at the top of the stage, gone after a few seconds. An image copied here has Save to Photos on it, a mint-tinted capsule.
import UIKit

final class TransferToast: UIView {
    var onPhotos: (() -> Void)?
    private let title = UILabel()
    private let detail = UILabel()
    private let button = UIButton(type: .system)
    private var hide: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.slab
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.edge.cgColor
        alpha = 0
        isHidden = true
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.mark
        title.numberOfLines = 2
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = UIColor(white: 1, alpha: 0.78)
        detail.numberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        // tinted, not filled: the toast's one action, not the brightest thing on the screen
        var c = UIButton.Configuration.tinted()
        c.baseBackgroundColor = Theme.mint
        c.baseForegroundColor = Theme.mint
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        c.title = String(localized: "Save to Photos")
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .systemFont(ofSize: 13, weight: .semibold)
            return a
        }
        button.configuration = c
        button.addAction(UIAction { [weak self] _ in self?.onPhotos?() }, for: .touchUpInside)
        [title, detail, button].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: Transfers.Said) {
        title.text = s.title
        detail.text = s.detail
        detail.isHidden = s.detail == nil
        if case .image = s.kind { button.isHidden = false } else { button.isHidden = true }
        isHidden = false
        setNeedsLayout()
        superview?.setNeedsLayout()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: [s.title, s.detail].compactMap { $0 }.joined(separator: " "))
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (button.isHidden ? 4 : 8), execute: w)
    }

    func dismiss() {
        hide?.cancel()
        UIView.animate(withDuration: 0.25) { self.alpha = 0 } completion: { _ in if self.alpha == 0 { self.isHidden = true } }
    }

    /// Its height at this width.
    func height(width: CGFloat) -> CGFloat {
        let inner = width - 28 - (button.isHidden ? 0 : button.intrinsicContentSize.width + 10)
        let t = ceil(title.sizeThatFits(CGSize(width: inner, height: 100)).height)
        let d = detail.isHidden ? 0 : ceil(detail.sizeThatFits(CGSize(width: inner, height: 40)).height) + 2
        return max(44, t + d + 20)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds.insetBy(dx: 14, dy: 10)
        var inner = b.width
        if !button.isHidden {
            let s = button.intrinsicContentSize
            button.frame = CGRect(x: b.maxX - s.width, y: bounds.midY - s.height / 2, width: s.width, height: s.height)
            inner -= s.width + 10
        }
        let t = ceil(title.sizeThatFits(CGSize(width: inner, height: 100)).height)
        let d = detail.isHidden ? 0 : ceil(detail.sizeThatFits(CGSize(width: inner, height: 40)).height)
        let top = bounds.midY - (t + (d > 0 ? d + 2 : 0)) / 2
        title.frame = CGRect(x: b.minX, y: top, width: inner, height: t)
        detail.frame = CGRect(x: b.minX, y: title.frame.maxY + 2, width: inner, height: d)
    }
}
