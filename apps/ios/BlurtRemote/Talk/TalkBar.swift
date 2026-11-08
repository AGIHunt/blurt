// The talk key is the Mac's dictation key, in the corner by the thumb. It behaves as the key does there: tap to start and tap
// to stop, hold to talk, double tap to send. Mint while it listens, the only mint on the screen.
import BlurtRemoteKit
import UIKit

final class TalkBar: UIView {
    private let fillLayer = CALayer()
    private let levelLayer = CAGradientLayer()
    private let icon = UIImageView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var phase = RemoteDictationPhase.idle
    private var down = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.talkRest
        layer.cornerRadius = Theme.keyRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        fillLayer.backgroundColor = Theme.mint.cgColor
        fillLayer.opacity = 0
        layer.addSublayer(fillLayer)
        levelLayer.colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.45).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        levelLayer.startPoint = CGPoint(x: 0, y: 0.5)
        levelLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(levelLayer)
        icon.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        icon.contentMode = .center
        icon.tintColor = Theme.mint
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textAlignment = .center
        label.textColor = Theme.mark
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        spinner.color = Theme.mark
        spinner.hidesWhenStopped = true
        for v in [icon, label, spinner] as [UIView] { addSubview(v) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        show(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillLayer.frame = bounds
        let h = bounds.height
        // the mic and its word together in the middle, as on the keys beside it
        let top = (h - 37) / 2
        icon.frame = CGRect(x: 0, y: top, width: bounds.width, height: 24)
        spinner.center = icon.center
        label.frame = CGRect(x: 2, y: top + 24, width: bounds.width - 4, height: 13)
    }

    func show(_ p: RemoteDictationPhase) {
        phase = p
        let on = p == .listening
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        fillLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        icon.tintColor = on ? Theme.onMint : Theme.mint
        if !on { levelLayer.frame = .zero }
        label.textColor = on ? Theme.onMint : p == .unavailable ? Theme.faint : Theme.mark
        icon.isHidden = p == .transcribing || p == .polishing
        if p == .transcribing || p == .polishing { spinner.startAnimating() } else { spinner.stopAnimating() }
        label.text = switch p {
        case .listening: String(localized: "Listening")
        case .transcribing, .polishing: String(localized: "Writing")
        case .unavailable: String(localized: "Off")
        case .idle: String(localized: "Talk")
        }
        accessibilityLabel = label.text
        setNeedsLayout()
    }

    /// The level moves the fill a little, so a glance says the mic hears you.
    func level(_ l: Float) {
        guard phase == .listening else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // from the middle outward, like a level
        let w = bounds.width * CGFloat(max(0, min(1, l)))
        levelLayer.frame = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        CATransaction.commit()
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        down = true
        if phase != .listening { backgroundColor = Theme.slabPressed }
        Haptics.grab()
        // the system's question takes the touch away: the first press asks, the next one talks
        if Prefs.shared.micOnPhone {
            switch MicStream.shared.access {
            case .undetermined:
                down = false
                backgroundColor = Theme.talkRest
                return MicStream.shared.ask()
            case .denied: return denied()
            case .granted:
                if !MicStream.shared.start() {
                    down = false
                    backgroundColor = Theme.talkRest
                    Link.shared.send(.hud(String(localized: "iPhone microphone unavailable")))
                    return
                }
            @unknown default: return
            }
        }
        Link.shared.send(.dictationKey(down: true))
    }

    /// The mic is off for this app, and that isn't something to fail at silently while looking at another screen.
    var onMicDenied: (() -> Void)?
    private func denied() {
        down = false
        backgroundColor = Theme.talkRest
        onMicDenied?()
    }

    private func up() {
        guard down else { return }
        down = false
        backgroundColor = Theme.talkRest
        Haptics.release()
        Link.shared.send(.dictationKey(down: false))
        MicStream.shared.released()
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { up() }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { up() }
}
