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
            send(.text(s))
        }
        onSent?(s)
    }
}

/// The row above the keyboard: what a phone keyboard doesn't have.
final class ModifierRow: UIInputView {
    var onClose: (() -> Void)?
    private var buttons: [(UIButton, RemoteModifiers?)] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
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
        func add(_ title: String, mods: RemoteModifiers? = nil, _ act: @escaping () -> Void) {
            var c = UIButton.Configuration.filled()
            c.title = title
            c.baseBackgroundColor = Theme.slabPressed
            c.baseForegroundColor = Theme.mark
            c.contentInsets = .zero
            c.cornerStyle = .medium
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in act() })
            row.addArrangedSubview(b)
            buttons.append((b, mods))
        }
        for (m, g) in RemoteModifiers.ordered {
            add(g, mods: m) { Sticky.shared.tap(m, at: CACurrentMediaTime()); Haptics.grab() }
        }
        add("esc") { Link.shared.send(.key(RemoteChord([], "Escape"), down: nil)); Haptics.tick() }
        add("⇥") { Link.shared.send(.key(RemoteChord([], "Tab"), down: nil)); Haptics.tick() }
        add("↑") { Link.shared.send(.key(RemoteChord([], "Up"), down: nil)); Haptics.step() }
        add("↓") { Link.shared.send(.key(RemoteChord([], "Down"), down: nil)); Haptics.step() }
        add("⌄") { [weak self] in self?.onClose?() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        for (b, m) in buttons {
            guard let m else { continue }
            let on = Sticky.shared.held.isSuperset(of: m)
            var c = b.configuration
            c?.baseBackgroundColor = on ? Theme.slabLatched : Theme.slabPressed
            c?.baseForegroundColor = on ? .black : Theme.mark
            b.configuration = c
        }
    }
}
