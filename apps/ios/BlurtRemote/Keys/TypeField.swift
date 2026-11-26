// The phone's keyboard as the Mac's. Letters go across as they are committed, so a Chinese input method composes here and
// only the chosen words reach the Mac. Delete with nothing here deletes there, Return is Return, and with ⌘ held a letter is
// a shortcut, not text. Corrections and suggestions are off: what's typed is what lands.
import BlurtRemoteKit
import UIKit

final class TypeField: UITextView, UITextViewDelegate {
    var onSent: ((String) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        returnKeyType = .default
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func deleteBackward() {
        if text.isEmpty {
            Haptics.step()
            send(.key(RemoteChord([], "Delete"), down: nil))
        } else {
            super.deleteBackward()
        }
    }

    private func send(_ m: ToMac) {
        Link.shared.send(m)
        Sticky.shared.used()
    }

    func textView(_ v: UITextView, shouldChangeTextIn r: NSRange, replacementText t: String) -> Bool {
        if t == "\n", markedTextRange == nil {
            send(.key(RemoteChord([], "Return"), down: nil))
            return false
        }
        return true
    }

    func textViewDidChange(_ v: UITextView) {
        guard markedTextRange == nil, !text.isEmpty else { return }
        let s = text ?? ""
        text = ""
        let held = Sticky.shared.held
        if !held.isEmpty, s.count == 1, let k = RemoteKey.named(s.uppercased()) {
            send(.key(RemoteChord(held, k.name), down: nil))
        } else {
            Link.shared.type(s)
            Sticky.shared.used()
        }
        onSent?(s)
    }
}

/// The row above the keyboard: what a phone keyboard doesn't have. Eight places, not eleven (founder, 2026-11-27: crowded): ↑ and ↓
/// left it, since the pad's arrow key is one tap on ⌄ away and the computer keyboard has all four. The way to the computer keyboard says
/// so in words, the same words as the switch over it, where a laptop icon read as the screen button and switched keyboards by surprise.
/// Paste from this device is drawn the size of the letters beside it, not larger.
final class ModifierRow: UIInputView {
    var onClose: (() -> Void)?
    /// the computer's keyboard instead
    var onComputer: (() -> Void)?
    /// the modifiers as the dock has them, so ⌘ and ⇧ don't swap places between keyboards; the computer's own order otherwise
    var order: () -> [RemoteModifiers] = { [] }
    private var mods: [RemoteModifiers] {
        let o = order()
        return o.count == 4 ? o : RemoteHost.shown.modifierOrder
    }
    private var buttons: [(UIButton, RemoteModifiers?)] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        func style(_ title: String) -> UIButton.Configuration {
            var c = UIButton.Configuration.filled()
            c.title = title
            c.baseBackgroundColor = Theme.slabPressed
            c.baseForegroundColor = Theme.mark
            c.contentInsets = .zero
            c.cornerStyle = .medium
            // one line: "Shift" in a tenth of a phone's width was "Shif / t"
            c.titleLineBreakMode = .byClipping
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = .systemFont(ofSize: 13, weight: .medium)
                return a
            }
            return c
        }
        var first: UIButton?
        func add(_ title: String, mods: RemoteModifiers? = nil, _ act: @escaping () -> Void) {
            let b = UIButton(configuration: style(title), primaryAction: UIAction { _ in act() })
            row.addArrangedSubview(b)
            if let f = first { b.widthAnchor.constraint(equalTo: f.widthAnchor).isActive = true } else { first = b }
            buttons.append((b, mods))
        }
        // in the dock's order, with the names of the computer in hand, set in refresh
        for i in 0..<4 {
            add("", mods: []) { [weak self] in
                guard let self else { return }
                Sticky.shared.tap(self.mods[i], at: CACurrentMediaTime())
                Haptics.grab()
            }
        }
        add("esc") { Link.shared.send(.key(RemoteChord([], "Escape"), down: nil)); Haptics.tick() }
        // the same icon as Tab in the dock; ⇥ as text at 13 pt was a speck
        add("") { Link.shared.send(.key(RemoteChord([], "Tab"), down: nil)); Haptics.tick() }
        if let b = buttons.last?.0 {
            b.configuration?.image = UIImage(systemName: "arrow.right.to.line", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .small))
            b.accessibilityLabel = RemoteHost.shown.keyName("Tab")
        }
        add("") {
            Haptics.tick()
            // an image copied here goes as the clipboard's content, and the computer pastes it (docs/design/remote-files.md); text is typed
            if Transfers.shared.pasteImage() { return }
            if let t = UIPasteboard.general.string, !t.isEmpty { Link.shared.type(t) }
        }
        if let b = buttons.last?.0 {
            b.configuration?.image = UIImage(systemName: "doc.on.clipboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .small))
            b.accessibilityLabel = String(localized: "Paste from This Device")
        }
        add("") { [weak self] in self?.onClose?() }
        if let b = buttons.last?.0 {
            b.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .small))
            b.accessibilityLabel = String(localized: "Hide Keyboard")
        }
        // the way to the computer keyboard, first, where the switch is on that keyboard; as wide as its words
        var c = style(String(localized: "Computer"))
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        let computer = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in Haptics.tick(); self?.onComputer?() })
        computer.setContentHuggingPriority(.required, for: .horizontal)
        computer.setContentCompressionResistancePriority(.required, for: .horizontal)
        computer.accessibilityLabel = String(localized: "Computer Keyboard")
        row.insertArrangedSubview(computer, at: 0)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tapped for the next key: an outline. Locked: filled. As the dock draws them, so the two can't be told apart only here.
    func refresh() {
        let h = RemoteHost.shown, s = Sticky.shared, order = mods
        for (i, (b, m)) in buttons.filter({ $0.1 != nil }).enumerated() {
            guard m != nil else { continue }
            let m = order[i]
            let locked = s.locked.isSuperset(of: m), once = s.held.isSuperset(of: m) && !locked
            var c = b.configuration
            c?.title = h.name(m)
            c?.baseBackgroundColor = locked ? Theme.slabLatched : Theme.slabPressed
            c?.baseForegroundColor = locked ? .black : Theme.mark
            c?.background.strokeColor = once ? Theme.slabLatched : nil
            c?.background.strokeWidth = once ? 1.5 : 0
            b.configuration = c
        }
    }
}
