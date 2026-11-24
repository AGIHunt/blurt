// Over the computer keyboard: which of the two keyboards this is, and what's held, with one tap that lets go of all of it.
import BlurtRemoteKit
import UIKit

enum KeyboardKind: String, CaseIterable { case text, computer }

final class KeyboardSwitch: UIView {
    var onPick: ((KeyboardKind) -> Void)?
    private let choice = UISegmentedControl(items: [String(localized: "keyboard.text", defaultValue: "Text"), String(localized: "Computer")])
    private let clear = UIButton(type: .system)
    /// room for both at once; otherwise what's held takes the choice's place while it is
    private var roomy: Bool { bounds.width >= 300 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        choice.selectedSegmentIndex = 1
        choice.overrideUserInterfaceStyle = .dark
        choice.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let k: KeyboardKind = self.choice.selectedSegmentIndex == 0 ? .text : .computer
            self.choice.selectedSegmentIndex = 1
            if k == .text { self.onPick?(k) }
        }, for: .valueChanged)
        clear.addAction(UIAction { _ in Haptics.tick(); Sticky.shared.letGo() }, for: .touchUpInside)
        addSubview(choice)
        addSubview(clear)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let s = Sticky.shared, h = RemoteHost.shown
        var names = h.modifierOrder.filter { s.once.union(s.locked).isSuperset(of: $0) }.map { h.name($0) }
        if s.altGrOnce || s.altGrLocked { names.append("AltGr") }
        var c = UIButton.Configuration.filled()
        c.title = names.joined(separator: h == .mac ? "" : " ")
        c.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        c.imagePlacement = .trailing
        c.imagePadding = 8
        c.cornerStyle = .capsule
        c.baseBackgroundColor = Theme.slabLatched
        c.baseForegroundColor = .black
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .systemFont(ofSize: 16, weight: .semibold)
            return a
        }
        clear.configuration = c
        clear.accessibilityLabel = String(localized: "Let Go of \(names.joined(separator: " "))")
        clear.isHidden = names.isEmpty
        choice.isHidden = !roomy && !names.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(bounds.height, 34), y = (bounds.height - h) / 2
        choice.frame = CGRect(x: 4, y: y, width: min(bounds.width - 8, 190), height: h)
        let w = min(clear.sizeThatFits(CGSize(width: 300, height: h)).width, roomy ? bounds.width - 202 : bounds.width - 8)
        clear.frame = CGRect(x: roomy ? bounds.width - w - 4 : 4, y: y, width: max(0, w), height: h)
        choice.isHidden = !roomy && !clear.isHidden
    }
}
