// The pad's one card for a connection that isn't simply there: connecting, coming back, can't be reached, needs pairing, taken by another
// phone, can't control (LinkStatus.swift has which state says what). It sits in the middle of the pad, where the thumb and the eye already
// are, at reading size: this is read at arm's length from a sofa, and a 12 pt line in the corner wasn't (the founder, 2026-11-16).
//
// A slab like the keys, so the words keep their contrast over the computer's picture too: the strong line is white 90 % on it (13 : 1),
// the second line white 78 % (10 : 1), the mark amber (8 : 1) and never alone, its shape says it too. The text follows the system's text
// size up to a point where the card still fits a phone's pad.
import UIKit

final class StatusCard: UIView {
    struct Words: Equatable {
        var title: String
        var detail: String?
        var action: String?
        var second: String?
        /// what VoiceOver says when the card changes
        var spoken: String { [title, detail].compactMap { $0 }.joined(separator: " ") }
    }

    var onAction: (() -> Void)?
    var onSecond: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let glyph = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let action = UIButton(type: .system)
    private let second = UIButton(type: .system)
    private let stack = UIStackView()
    private(set) var words: Words?

    static let maxWidth: CGFloat = 340
    private static let pad = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle, most: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), maximumPointSize: most)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.slab
        layer.cornerRadius = Theme.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.edge.cgColor
        isHidden = true
        alpha = 0

        spinner.color = Theme.mark
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .vertical)

        title.font = Self.font(17, .semibold, .body, most: 26)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.mark
        title.textAlignment = .center
        title.numberOfLines = 0
        detail.font = Self.font(15, .regular, .subheadline, most: 22)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = UIColor(white: 1, alpha: 0.78)
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var a = UIButton.Configuration.filled()
        a.baseBackgroundColor = Theme.slabLatched
        a.baseForegroundColor = .black
        a.cornerStyle = .capsule
        a.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        a.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { t in
            var t = t
            t.font = Self.font(16, .semibold, .body, most: 22)
            return t
        }
        action.configuration = a
        action.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
        var b = UIButton.Configuration.plain()
        b.baseForegroundColor = Theme.mark
        b.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        b.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { t in
            var t = t
            t.font = Self.font(15, .medium, .subheadline, most: 20)
            return t
        }
        second.configuration = b
        second.addAction(UIAction { [weak self] _ in self?.onSecond?() }, for: .touchUpInside)

        stack.axis = .vertical
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [spinner, glyph, title, detail, action, second] as [UIView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(12, after: spinner)
        stack.setCustomSpacing(10, after: glyph)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(16, after: detail)
        stack.setCustomSpacing(2, after: action)
        addSubview(stack)
        let p = Self.pad
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: p.top),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.right),
            // a pad too short for it cuts the card at the bottom, never squeezes the words
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -p.bottom).with(.defaultHigh),
            spinner.heightAnchor.constraint(equalToConstant: 28),
            glyph.heightAnchor.constraint(equalToConstant: 30),
            action.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            action.widthAnchor.constraint(greaterThanOrEqualToConstant: 168),
            second.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// nil: nothing to say, the card goes. True when what it says has changed.
    @discardableResult func show(_ mark: StatusBanner.Mark?, _ w: Words?) -> Bool {
        let changed = w != words
        words = w
        guard let w, let mark else {
            spinner.stopAnimating()
            fade(false)
            return changed
        }
        switch mark {
        case .busy:
            glyph.isHidden = true
            spinner.startAnimating()
        case .problem, .phone, .code:
            spinner.stopAnimating()
            glyph.isHidden = false
            let name = mark == .problem ? "exclamationmark.triangle.fill" : mark == .phone ? "iphone" : "qrcode.viewfinder"
            glyph.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
            glyph.tintColor = mark == .problem ? Theme.attn : Theme.mark
        }
        title.text = w.title
        detail.text = w.detail
        detail.isHidden = w.detail == nil
        action.configuration?.title = w.action
        action.isHidden = w.action == nil
        second.configuration?.title = w.second
        second.isHidden = w.second == nil
        // the last thing showing has nothing under it
        stack.setCustomSpacing(w.detail == nil && w.action == nil ? 0 : 6, after: title)
        fade(true)
        return changed
    }

    private func fade(_ on: Bool) {
        if on { isHidden = false }
        guard alpha != (on ? 1 : 0) else {
            if !on { isHidden = true }
            return
        }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = on ? 1 : 0
        } completion: { _ in
            if self.words == nil { self.isHidden = true }
        }
    }

    /// As tall as its words need at this width.
    func height(width: CGFloat) -> CGFloat {
        let p = Self.pad
        let s = stack.systemLayoutSizeFitting(CGSize(width: width - p.left - p.right, height: UIView.layoutFittingCompressedSize.height),
                                              withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(s.height) + p.top + p.bottom
    }

    /// Only its buttons take touches: the pad under the words is still the pad (a touch there takes the computer back from another phone).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v is UIControl ? v : nil
    }
}

private extension NSLayoutConstraint {
    func with(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
