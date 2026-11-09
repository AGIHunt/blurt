// The one screen. UIKit, not SwiftUI, for exact geometry and touches that never wait for anything; the sheets around it are
// SwiftUI.
import BlurtRemoteKit
import Combine
import SwiftUI
import UIKit

final class PadWindow: UIWindow {
    override func sendEvent(_ e: UIEvent) {
        super.sendEvent(e)
        guard e.type == .touches, let c = rootViewController as? PadViewController else { return }
        c.touching = e.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
    }
}

final class PadViewController: UIViewController {
    private let pad = TrackpadView()
    /// big screens: the trackpad between the thumbs, under the keys' halves
    private let thumbPad = TrackpadView()
    /// the fold and the cameras, as UIKit reports them (iOS 27.1)
    private var surround = PadSurround.none
    /// the stage's size in pixels the stream was last told about
    private var askedPixels: CGSize?
    /// the stage and the thumb pad's outline, when they're one glass
    private let glassOutline = CAShapeLayer()
    #if DEBUG
    /// Pretend: a made-up desktop where the picture would be
    private let standIn = CALayer()
    #endif
    private let talk = TalkBar()
    private let list = KeyList()
    private var dockCells = (0..<Deck.dockCount).map { _ in KeyCell() }
    private let arrowCell = KeyCell()
    /// landscape: with the keys away there's still a picture to leave
    private let appsCell = KeyCell()
    private var allCells: [KeyCell] { dockCells + [arrowCell, appsCell] + list.cells }
    private let strip = PageStrip()
    private let chips = UIStackView()
    private let keyboardButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let header = UILabel()
    private let screenButton = UIButton(type: .system)
    private let findButton = UIButton(type: .system)
    private let drawerButton = UIButton(type: .system)
    /// landscape: the keys are out. Out for the trackpad, put away when there's a picture to see
    private var drawerOpen = true
    /// the pad has the Mac's shape and shows its screen
    private var showing = false
    private let edgeMark = UIView()
    private let liveText = UILabel()
    /// over the picture, the words need something behind them
    private let liveBack = UIView()
    private let message = UILabel()
    private let action = UIButton(type: .system)
    private let dim = UIView()
    private let field = TypeField(frame: .zero, textContainer: nil)
    private let modRow = ModifierRow()

    private var deck = Deck.load(for: Link.shared.host)
    /// a finger is down anywhere: PadWindow says so
    var touching = false {
        didSet {
            guard touching != oldValue else { return }
            setNeedsUpdateOfSupportedInterfaceOrientations()
            if touching { touched() }
        }
    }
    private var keyboardHeight: CGFloat = 0
    /// the key a cycle is running on, while it runs
    private weak var cycleKey: KeyCell?
    private var idle: Timer?
    private var pace: Timer?
    private var bag = Set<AnyCancellable>()
    private var layout: PadLayout?

    /// long enough that it never happens in use: this only protects a phone left on the desk
    private static let idleDim = 300.0
    private static let idlePace = 45.0

    override var prefersStatusBarHidden: Bool { true }
    /// iOS's own three-finger undo and copy gestures would take the touches from the pad
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // leaning back mustn't rotate the screen under a thumb. Otherwise every way Info.plist allows (an iPad: all four)
        guard touching, let o = view.window?.windowScene?.interfaceOrientation else { return .all }
        switch o {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    // MARK: a keyboard on the iPad

    override var canBecomeFirstResponder: Bool { true }

    private lazy var claimedKeys = HardwareKeys.commands(action: #selector(claimedKey(_:)))
    /// not while the system keyboard's field is typing: its arrows and Tab are its own
    override var keyCommands: [UIKeyCommand]? { field.isFirstResponder || presentedViewController != nil ? nil : claimedKeys }
    @objc private func claimedKey(_ c: UIKeyCommand) {
        touched()
        HardwareKeys.shared.command(c)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        // what the system keyboard's field didn't take (a lone ⌘, say) mustn't be held on the computer while it types
        guard !field.isFirstResponder else { return super.pressesBegan(presses, with: e) }
        let rest = presses.filter { !HardwareKeys.shared.began($0) }
        if rest.count < presses.count { touched() }
        if !rest.isEmpty { super.pressesBegan(rest, with: e) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        let rest = presses.filter { !HardwareKeys.shared.ended($0) }
        if !rest.isEmpty { super.pressesEnded(rest, with: e) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with e: UIPressesEvent?) {
        let rest = presses.filter { !HardwareKeys.shared.ended($0) }
        if !rest.isEmpty { super.pressesCancelled(rest, with: e) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true

        glassOutline.fillColor = nil
        glassOutline.strokeColor = Theme.hairline.cgColor
        glassOutline.lineWidth = 1
        glassOutline.isHidden = true
        view.addSubview(pad)
        view.addSubview(thumbPad)
        view.layer.addSublayer(glassOutline)
        thumbPad.isStage = false
        thumbPad.isHidden = true
        thumbPad.accessibilityLabel = String(localized: "Trackpad")
        thumbPad.stageMiddle = { [weak self] in
            guard let b = self?.pad.bounds else { return .zero }
            return CGPoint(x: b.midX, y: b.midY)
        }
        pad.layer.insertSublayer(ScreenStream.shared.stage, at: 0)
        #if DEBUG
        standIn.contentsGravity = .resize
        standIn.isHidden = true
        pad.layer.insertSublayer(standIn, at: 1)
        #endif
        for v in [header, liveBack, liveText, message, action, edgeMark] as [UIView] { pad.addSubview(v) }
        liveBack.backgroundColor = UIColor(white: 0, alpha: 0.72)
        liveBack.layer.cornerRadius = 12
        liveBack.layer.cornerCurve = .continuous
        liveBack.isUserInteractionEnabled = false
        edgeMark.backgroundColor = Theme.hairline
        edgeMark.layer.cornerRadius = 1.5
        edgeMark.isUserInteractionEnabled = false
        screenButton.layer.cornerRadius = Theme.keyRadius
        screenButton.layer.cornerCurve = .continuous
        screenButton.addAction(UIAction { [weak self] _ in self?.toggleScreen() }, for: .touchUpInside)
        drawerButton.setImage(UIImage(systemName: "square.grid.3x3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        drawerButton.tintColor = Theme.mark
        drawerButton.backgroundColor = Theme.slab
        drawerButton.layer.cornerRadius = Theme.keyRadius
        drawerButton.isHidden = true
        drawerButton.accessibilityLabel = String(localized: "Keys")
        drawerButton.addAction(UIAction { [weak self] _ in self?.toggleDrawer() }, for: .touchUpInside)
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = Theme.faint
        liveText.font = .systemFont(ofSize: 15, weight: .regular)
        liveText.textColor = Theme.mark
        liveText.numberOfLines = 3
        liveText.lineBreakMode = .byWordWrapping
        liveText.isUserInteractionEnabled = false
        message.textAlignment = .center
        message.numberOfLines = 0
        message.font = .systemFont(ofSize: 15)
        message.textColor = Theme.caption
        message.isUserInteractionEnabled = false
        action.tintColor = Theme.mark
        action.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        action.addAction(UIAction { [weak self] _ in self?.primaryAction() }, for: .touchUpInside)

        view.addSubview(list)
        list.onCycle = { [weak self] on, c in self?.cycling(on, by: c) }
        list.onEdit = { [weak self] in self?.showEditor() }
        list.onSection = { [weak self] i in self?.strip.select(i) }
        for c in dockCells {
            view.addSubview(c)
            c.onCycle = { [weak self, weak c] on in self?.cycling(on, by: c) }
        }
        arrowCell.slot = KeySlot(.arrows, hint: String(localized: "Arrows"))
        view.addSubview(arrowCell)
        appsCell.slot = Deck.appsKey(for: Link.shared.host)
        appsCell.onCycle = { [weak self] on in self?.cycling(on, by: self?.appsCell) }
        view.addSubview(appsCell)
        view.addSubview(talk)
        view.addSubview(drawerButton)
        view.addSubview(screenButton)
        strip.onSelect = { [weak self] i in self?.tab(i) }
        view.addSubview(strip)
        chips.axis = .horizontal
        chips.distribution = .fillEqually
        chips.spacing = 6
        chips.isHidden = true
        view.addSubview(chips)
        chip(String(localized: "Cancel")) { Link.shared.send(.blurt(.dictationCancel)) }
        chip(String(localized: "Structured")) { Link.shared.send(.blurt(.dictationStructured)) }
        chip(String(localized: "Translate")) { Link.shared.send(.blurt(.dictationTranslate)) }

        for (b, s) in [(keyboardButton, "keyboard"), (settingsButton, "slider.horizontal.3"), (findButton, "scope")] {
            b.setImage(UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            b.tintColor = Theme.caption
            view.addSubview(b)
        }
        keyboardButton.accessibilityLabel = String(localized: "Keyboard")
        settingsButton.accessibilityLabel = String(localized: "Settings")
        findButton.accessibilityLabel = String(localized: "Find Pointer")
        findButton.addAction(UIAction { _ in Haptics.tick(); Link.shared.send(.system(.findCursor)) }, for: .touchUpInside)
        keyboardButton.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .touchUpInside)
        settingsButton.addAction(UIAction { [weak self] _ in self?.showSettings() }, for: .touchUpInside)

        view.addSubview(field)
        field.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        field.inputAccessoryView = modRow
        field.onSent = { [weak self] _ in self?.touched() }      // the keyboard's touches don't come through the window
        modRow.onClose = { [weak self] in self?.field.resignFirstResponder() }

        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        view.addSubview(dim)

        for p in [pad, thumbPad] {
            p.onViewEnd = { [weak self] in self?.viewSettled() }
            p.onHaptic = { h in
                switch h {
                case .tap: Haptics.tick()
                case .grab: Haptics.grab()
                case .release: Haptics.release()
                case .step: Haptics.step()
                }
            }
            p.onClick = { Sticky.shared.used() }
        }
        Surroundings.watchHinge(view) { [weak self] in self?.view.setNeedsLayout() }
        talk.onMicDenied = { [weak self] in self?.micDenied() }
        Sticky.shared.onChange = { [weak self] in
            self?.allCells.forEach { $0.refresh() }
            self?.modRow.refresh()
        }
        applyPrefs()
        showDeck()
        observe()
        Haptics.prepare()
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            self?.keyboardChanged(n)
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.becomeFirstResponder() }      // a keyboard on the iPad is the computer's again
            self?.keyboardHeight = 0
            self?.view.setNeedsLayout()
            UIView.animate(withDuration: 0.25) { self?.view.layoutIfNeeded() }
        }
        // turned end over end the size stays the same, but the Dynamic Island has changed sides
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.view.setNeedsLayout() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pad.letGo()
            self?.thumbPad.letGo()
            HardwareKeys.shared.letGo()
            Sticky.shared.clear()
        }
        touched()
        #if DEBUG
        if Pretend.screen { setShowing(true) }
        #endif
    }

    private func chip(_ title: String, _ act: @escaping () -> Void) {
        var c = UIButton.Configuration.filled()
        c.title = title
        c.baseBackgroundColor = UIColor(white: 0, alpha: 0.72)
        c.baseForegroundColor = Theme.mint
        c.cornerStyle = .capsule
        c.contentInsets = .zero
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .systemFont(ofSize: 13, weight: .medium)
            return a
        }
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in Haptics.tick(); act() })
        chips.addArrangedSubview(b)
    }

    private func applyPrefs() {
        let p = Prefs.shared
        for t in [pad, thumbPad] {
            // closer in, the same stroke crosses less of the Mac's screen
            t.engine.curve = RemotePointerCurve().scaled(Float(p.pointerSpeed) / max(1, Float(ScreenStream.shared.port.zoom).squareRoot()))
            t.engine.scrollGain = 2.4 * CGFloat(p.scrollSpeed)
            t.showing = showing
        }
        pad.engine.touchMode = showing && p.tapWhereTouched
        thumbPad.engine.touchMode = false     // between the thumbs it's always a trackpad: the picture is out of reach
        view.setNeedsLayout()
    }

    private func observe() {
        let l = Link.shared
        Publishers.CombineLatest3(l.$state, l.$current, l.$canControl).receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.status() } }.store(in: &bag)
        Publishers.CombineLatest(l.$macs, l.$current).receive(on: RunLoop.main).sink { [weak self] macs, current in
            self?.macMenu(macs, current)
        }.store(in: &bag)
        // another kind of computer: its own keys, named its way
        l.$host.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] h in
            guard let self else { return }
            self.deck = Deck.load(for: h)
            self.appsCell.slot = Deck.appsKey(for: h)
            self.showDeck()
            self.allCells.forEach { $0.refresh() }
            self.modRow.refresh()
        }.store(in: &bag)
        // the picture was of the Mac just left
        l.$current.map { $0?.deviceID }.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.setShowing(false) }.store(in: &bag)
        Publishers.CombineLatest(l.$waitingForMac, l.$pairFailed).receive(on: RunLoop.main).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.status() }
        }.store(in: &bag)
        Publishers.CombineLatest(l.$route, l.$displayAspect).receive(on: RunLoop.main).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.status() }
        }.store(in: &bag)
        l.$screenError.receive(on: RunLoop.main).sink { [weak self] e in
            guard e != nil else { return }
            self?.setShowing(false)
            self?.status()
        }.store(in: &bag)
        l.$offered.receive(on: RunLoop.main).sink { [weak self] p in
            if let p { self?.confirmPairing(p) }
        }.store(in: &bag)
        l.$dictation.receive(on: RunLoop.main).sink { [weak self] p in
            self?.talk.show(p)
            self?.chips.isHidden = p != .listening
            self?.view.setNeedsLayout()
            self?.status()
        }.store(in: &bag)
        Publishers.CombineLatest(l.$liveFinal, l.$live).receive(on: RunLoop.main).sink { [weak self] f, p in
            guard let self else { return }
            // the newest words: three lines' worth from the end
            let room = max(40, Int(min(self.pad.bounds.width - 32, 420) / 14.5) * 3 - 2)
            let cut = max(0, f.count + p.count - room)
            let t = NSMutableAttributedString(string: cut > 0 ? "…" : "", attributes: [.foregroundColor: Theme.caption])
            t.append(NSAttributedString(string: String(f.dropFirst(cut)), attributes: [.foregroundColor: Theme.mark]))
            t.append(NSAttributedString(string: String(p.dropFirst(max(0, cut - f.count))), attributes: [.foregroundColor: Theme.caption]))
            self.liveText.attributedText = t
            self.view.setNeedsLayout()
            self.touched()
        }.store(in: &bag)
        l.$level.receive(on: RunLoop.main).sink { [weak self] v in self?.talk.level(v) }.store(in: &bag)
        Prefs.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            DispatchQueue.main.async { self?.applyPrefs() }
        }.store(in: &bag)
    }

    /// What the pad says, in the few states where it should say anything.
    private func status() {
        let l = Link.shared
        var text: String?, button: String?
        switch l.state {
        case .unpaired:
            text = Words.whereTheCodeIs
            button = String(localized: "Scan Code")
        case .forgotten:
            text = String(localized: "\(l.current?.title ?? String(localized: "This computer")) no longer knows this iPhone.")
            button = String(localized: "Scan Code")
        case .unreachable:
            let n = l.current?.title ?? String(localized: "the computer")
            text = l.current?.relayAddress == nil ? String(localized: "Can’t reach \(n). Check that Blurt is running and both are on the same network.")
                : String(localized: "Can’t reach \(n). Check that it’s awake and Blurt is running.")
            if l.macs.count > 1 { button = String(localized: "Try Another Computer") }
        case .connecting: break
        case .replaced:
            text = String(localized: "Another iPhone is connected. Touch to take over.")
        case .connected:
            let n = l.current?.title ?? ""
            if !l.canControl { text = Words.cantControl(l.host, n) }
            if l.screenError == "permission" { text = Words.noScreenPermission(l.host, n) }
            if l.screenError == "off" { text = Words.screenOff(l.host, n) }
        }
        if l.waitingForMac {
            text = String(format: String(localized: "Allow this iPhone in Blurt’s Settings on your computer. Check that it shows %@."), l.pairCheck ?? "")
            button = nil
        }
        if let f = l.pairFailed { text = f }
        var ready = l.state == .connected
        #if DEBUG
        if Pretend.connected { text = nil; button = nil; ready = true }
        #endif
        message.text = text
        message.isHidden = text == nil
        action.setTitle(button, for: .normal)
        action.isHidden = button == nil
        let name = l.current?.title ?? ""
        let via = l.route == .relay ? String(localized: "\(name) · Internet") : l.route == .direct ? String(localized: "\(name) · Direct") : name
        header.text = showing && l.state == .connected ? nil : l.state == .connected ? via : l.state == .connecting ? String(localized: "Connecting to \(name)…") : nil
        talk.alpha = ready ? 1 : 0.35
        if cycleKey == nil { allCells.forEach { $0.alpha = ready ? 1 : 0.35 } }
        view.setNeedsLayout()
    }

    private func primaryAction() {
        switch Link.shared.state {
        case .unreachable: showSettings()
        default: showPairing()
        }
    }

    private func confirmPairing(_ p: RemotePairing) {
        let a = UIAlertController(title: String(localized: "Pair with \(p.macName)?"),
                                  message: Link.shared.macs.contains { $0.id == p.macID } ? String(localized: "This iPhone is already paired with this computer. This replaces that pairing.")
                                      : String(localized: "This computer will receive what you type and say here. Only pair with your own computer."), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in Link.shared.offered = nil })
        a.addAction(UIAlertAction(title: String(localized: "Pair"), style: .default) { _ in
            Link.shared.offered = nil
            Link.shared.pair(p)
        })
        // from whatever is on top (Settings, perhaps), past a sheet on its way out
        var top: UIViewController = self
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(a, animated: true)
    }

    // MARK: the Mac's screen

    private func toggleScreen() {
        // the measured run has the stream to itself
        guard ProcessInfo.processInfo.environment["BLURT_SCREEN_TEST"] == nil else { return }
        Haptics.tick()
        Link.shared.screenError = nil
        setShowing(!showing)
    }

    private func setShowing(_ on: Bool) {
        guard on != showing else { return }
        showing = on
        drawerOpen = !on
        keysPutAway()
        pad.engine.pinchZoomsView = on
        thumbPad.engine.pinchZoomsView = on
        pad.backgroundColor = on ? .black : Theme.glass
        // a rounded corner on the picture is a piece of the screen not seen
        pad.layer.cornerRadius = on ? 6 : 22
        pad.layer.borderWidth = on ? 0 : 1
        ScreenStream.shared.resetView()
        applyPrefs()
        if on { ScreenStream.shared.start() } else { ScreenStream.shared.stop() }
        status()
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
    }

    private func toggleDrawer() {
        Haptics.tick()
        drawerOpen.toggle()
        keysPutAway()
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
    }

    /// Landscape, the keys put away: the modifiers went with them, so none stays held on the Mac out of sight. (Big screens keep the dock out.)
    private func keysPutAway() {
        guard !drawerOpen, PadLayout.mode(for: view.bounds.size) == .landscape, !Sticky.shared.held.isEmpty else { return }
        Sticky.shared.release(Sticky.shared.held)
    }

    /// The fingers lifted: pointer speed follows how close the view now is.
    private func viewSettled() {
        applyPrefs()
    }

    private func micDenied() {
        let a = UIAlertController(title: String(localized: "Microphone Access Is Off"),
                                  message: Words.micDenied(Link.shared.host), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: Words.useComputerMic(Link.shared.host), style: .default) { _ in
            Prefs.shared.micOnPhone = false
            Link.shared.send(.setMicOnPhone(false))
        })
        a.addAction(UIAlertAction(title: String(localized: "Open Settings"), style: .default) { _ in
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        })
        a.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(a, animated: true)
    }

    // MARK: layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surround = Surroundings.read(view)
        #if DEBUG
        if let s = Pretend.surround { surround = s }
        #endif
        let size = view.bounds.size
        // which end has the camera, on its side: where UIKit says the camera is; before iOS 27.1, from the way the phone is turned
        // (UIKit's landscapeRight has the home side on the right, so the island on the left)
        var islandLeft = view.window?.windowScene?.interfaceOrientation == .landscapeRight
        if let c = surround.occlusions.first(where: { $0.midX < size.width * 0.3 || $0.midX > size.width * 0.7 }) {
            islandLeft = c.midX < size.width / 2
        }
        let l = PadLayout(size: size, safe: Self.safeInsets(view), lefty: Prefs.shared.lefty, islandLeft: islandLeft, drawerOpen: drawerOpen,
                          surround: surround, aspect: Link.shared.displayAspect)
        layout = l
        let typing = keyboardHeight > 0
        var padFrame = l.pad
        if typing {
            let top = l.landscape ? max(view.safeAreaInsets.top, 8) : l.pad.minY
            padFrame = CGRect(x: l.landscape ? max(view.safeAreaInsets.left, 12) : l.pad.minX, y: top,
                              width: l.landscape ? view.bounds.width - max(view.safeAreaInsets.left, 12) * 2 : l.pad.width,
                              height: view.bounds.height - keyboardHeight - top - 8)
        }
        pad.frame = padFrame
        thumbPad.isHidden = typing || l.thumbPad == nil
        // with no picture the stage and the pad between the thumbs are one glass: joined, one outline, so it reads as one trackpad
        // reaching down to the thumbs. With the picture they're two things, a screen and a trackpad
        let joined = !typing && !showing && l.mode == .big && l.halves.count == 2 && !(surround.laptop) && l.thumbPad != nil
        if joined, let t = l.thumbPad {
            thumbPad.frame = CGRect(x: t.minX, y: padFrame.maxY, width: t.width, height: t.maxY - padFrame.maxY)
            // the thumb pad's rounded top tucked inside the stage, so the two meet in square inner corners
            let reach = CGRect(x: t.minX, y: padFrame.maxY - 30, width: t.width, height: t.maxY - padFrame.maxY + 30)
            glassOutline.path = UIBezierPath(roundedRect: padFrame, cornerRadius: 22).cgPath.union(UIBezierPath(roundedRect: reach, cornerRadius: 22).cgPath)
        } else {
            thumbPad.frame = l.thumbPad ?? .zero
        }
        glassOutline.isHidden = !joined
        thumbPad.layer.borderWidth = joined ? 0 : 1
        thumbPad.layer.maskedCorners = joined ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        if !showing { pad.layer.borderWidth = joined ? 0 : 1 }
        thumbPad.engine.scrollEdge = l.thumbScrollEdge
        talk.frame = l.talk
        talk.isHidden = typing
        let railed = l.rail != nil
        let keysOut = !typing && l.keysOut
        list.isHidden = !keysOut
        list.frame = l.list
        list.arrange(key: l.keySize, gap: PadLayout.gap, tallest: l.mode != .portrait ? KeyList.tallest : nil, split: l.listSplit)
        for (i, c) in dockCells.enumerated() {
            c.isHidden = typing || !(keysOut || PadLayout.staysOut(i) || l.mode == .big)
            c.frame = l.dock[i]
        }
        arrowCell.isHidden = typing
        arrowCell.frame = l.arrowKey
        appsCell.isHidden = typing || l.appsKey.isEmpty
        appsCell.frame = l.appsKey
        // the keyboard may have changed it
        pad.engine.scrollEdge = typing ? PadLayout.scrollEdge(width: padFrame.width, lefty: Prefs.shared.lefty) : l.scrollEdge
        pad.engine.scrollEdgeY = typing ? nil : l.scrollEdgeY
        drawerButton.frame = l.drawerButton
        drawerButton.isHidden = !railed || typing
        drawerButton.tintColor = drawerOpen ? .black : Theme.mark
        drawerButton.backgroundColor = drawerOpen ? Theme.slabLatched : Theme.slab
        screenButton.frame = l.screenButton
        screenButton.isHidden = typing
        screenButton.backgroundColor = railed ? Theme.slab : .clear
        // lit while it's on, as a modifier is: a crossed-out eye over a live picture reads as off
        screenButton.setImage(UIImage(systemName: "display", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
        screenButton.tintColor = showing ? .black : railed ? Theme.mark : Theme.caption
        if showing { screenButton.backgroundColor = Theme.slabLatched }
        screenButton.accessibilityLabel = showing ? String(localized: "Hide Screen") : String(localized: "Show Screen")
        for b in [keyboardButton, settingsButton, findButton] {
            b.layer.cornerRadius = Theme.keyRadius
            b.backgroundColor = railed ? Theme.slab : .clear
        }
        view.bringSubviewToFront(dim)
        strip.frame = l.strip
        // big screens: the tabs stay with the keys put away, and bring them back
        strip.isHidden = typing || !(keysOut || (l.mode == .big && !l.strip.isEmpty))
        strip.showsSelection = keysOut
        keyboardButton.frame = l.keyboardButton
        settingsButton.frame = l.settingsButton
        findButton.frame = l.findButton
        keyboardButton.isHidden = typing
        settingsButton.isHidden = typing
        findButton.isHidden = typing
        dim.frame = view.bounds

        ScreenStream.shared.layout(pad.bounds, alignY: l.stageAlignY)
        #if DEBUG
        if Pretend.screen {
            // the whole picture, where ViewPort puts it: fitted, near the keys
            let a = Link.shared.displayAspect, b = pad.bounds
            let w = min(b.width, b.height * a), h = w / a
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if standIn.contents == nil { standIn.contents = Pretend.desktop(aspect: a).cgImage }
            standIn.frame = CGRect(x: (b.width - w) / 2, y: (b.height - h) * l.stageAlignY, width: w, height: h)
            standIn.isHidden = !showing
            CATransaction.commit()
        }
        #endif
        // the output follows the stage (not the keyboard's moment), asked again only when it changes by more than a little
        let want = PadLayout.outputPixels(stage: l.pad.size, aspect: Link.shared.displayAspect, scale: traitCollection.displayScale)
        if want.width > 0, askedPixels.map({ abs($0.width - want.width) > $0.width * 0.08 || abs($0.height - want.height) > $0.height * 0.08 }) ?? true {
            askedPixels = want
            ScreenStream.shared.stagePixels = want
        }

        // what's said on the stage stays clear of the fold, on the thumb's side
        let hint = typing ? pad.bounds : l.hintArea
        let chipsW = min(hint.width - 16, 300)
        chips.frame = CGRect(x: padFrame.minX + hint.midX - chipsW / 2, y: padFrame.minY + hint.maxY - 8 - 32, width: chipsW, height: 32)
        edgeMark.isHidden = showing
        let edge = pad.engine.scrollEdge ?? (0...0), ys = pad.engine.scrollEdgeY ?? (0...pad.bounds.height)
        edgeMark.frame = CGRect(x: edge.lowerBound < 1 ? 7 : pad.bounds.maxX - 10, y: (ys.lowerBound + ys.upperBound) / 2 - 34, width: 3, height: 68)
        let inset = hint.insetBy(dx: 16, dy: 12)
        header.frame = CGRect(x: 16, y: 12, width: pad.bounds.width - 32, height: 16)
        // above the chips, nearest the thumb; the newest words stay in view
        let wordsW = min(hint.width - 32, 420)
        let chipsTop = hint.maxY - 8 - 32 - 8
        let fit = ceil(liveText.sizeThatFits(CGSize(width: wordsW, height: .greatestFiniteMagnitude)).height)
        let hasWords = !(liveText.text ?? "").isEmpty
        liveText.frame = CGRect(x: hint.midX - wordsW / 2, y: chipsTop - 6 - fit, width: wordsW, height: fit)
        liveBack.frame = liveText.frame.insetBy(dx: -10, dy: -6)
        liveBack.isHidden = !hasWords
        let tall = sizeForMessage(inset.width)
        message.frame = CGRect(x: inset.minX + 8, y: hint.midY - tall / 2 - 20, width: inset.width - 16, height: tall)
        let actionW = min(inset.width, 280)
        action.frame = CGRect(x: hint.midX - actionW / 2, y: message.frame.maxY + 8, width: actionW, height: 44)
    }

    /// The safe area, and on iPadOS 26 a window's controls too: the stage's top corner stays clear of them.
    private static func safeInsets(_ v: UIView) -> UIEdgeInsets {
        var s = v.safeAreaInsets
        if #available(iOS 26.0, *) {
            let w = v.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
            s.top = max(s.top, w.top)
        }
        return s
    }

    private func sizeForMessage(_ w: CGFloat) -> CGFloat {
        ceil((message.text as NSString? ?? "").boundingRect(with: CGSize(width: w - 16, height: 400), options: .usesLineFragmentOrigin,
                                                           attributes: [.font: message.font as Any], context: nil).height)
    }

    /// A turn, a window resized, the Duo opened or closed: the same session goes on. Touches in flight end cleanly (a drag lets go,
    /// a scroll ends); latched modifiers stay held; the zoomed view keeps its middle (ViewPort.reshape). The keys go back to how they
    /// start only when the layout changes kind, not at every step of a window being dragged bigger.
    override func viewWillTransition(to size: CGSize, with c: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: c)
        if PadLayout.mode(for: size) != PadLayout.mode(for: view.bounds.size) { drawerOpen = !showing }
        pad.letGo()
        thumbPad.letGo()
    }

    // MARK: keys

    private func showDeck() {
        list.show(deck.sections)
        strip.show(names: deck.sections.map(\.name), page: list.section)
        for (i, c) in dockCells.enumerated() { c.slot = deck.dock[i] }
        status()
    }

    /// A tab. On a big screen with the keys put away it brings them back at that page; the page already showing puts them away.
    private func tab(_ n: Int) {
        guard let l = layout, l.mode == .big, l.drawerMatters else { return go(n) }
        if !drawerOpen {
            drawerOpen = true
            go(n)
            view.setNeedsLayout()
            UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
        } else if n == list.section {
            toggleDrawer()
        } else {
            go(n)
        }
    }

    private func go(_ n: Int) {
        list.scroll(toSection: n)
        strip.select(n)
        Haptics.step()
    }

    /// A slide across the keys while a cycle key is held: the rest are out of play, and look it.
    private func cycling(_ on: Bool, by c: KeyCell?) {
        cycleKey = on ? c : nil
        let rest: CGFloat = on ? 0.3 : Link.shared.state == .connected ? 1 : 0.35
        for x in allCells where x !== c {
            x.isUserInteractionEnabled = !on
            x.alpha = rest
        }
    }

    // MARK: touches, dimming

    /// The screen dims when nothing happens and comes back with any touch, which still does its job.
    func touched() {
        // back from a sheet: a keyboard on the iPad is the computer's again
        if !isFirstResponder, !field.isFirstResponder, presentedViewController == nil { becomeFirstResponder() }
        Link.shared.touched()
        ScreenStream.shared.setIdle(false)
        watchIdle()
        if dim.alpha > 0 { UIView.animate(withDuration: 0.15) { self.dim.alpha = 0 } }
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: Self.idleDim, repeats: false) { [weak self] _ in
            guard let self else { return }
            // never while typing or talking
            guard self.keyboardHeight == 0, Link.shared.dictation == .idle else { return self.touched() }
            UIView.animate(withDuration: 0.6) { self.dim.alpha = 0.6 }
        }
    }

    /// Nobody's touching it: over the mobile network, the picture slows down until someone does.
    private func watchIdle() {
        pace?.invalidate()
        pace = Timer.scheduledTimer(withTimeInterval: Self.idlePace, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard !self.touching, self.keyboardHeight == 0, Link.shared.dictation == .idle else { return self.watchIdle() }
            ScreenStream.shared.setIdle(true)
        }
    }

    // MARK: keyboard

    private func toggleKeyboard() {
        Haptics.tick()
        if field.isFirstResponder { field.resignFirstResponder() } else { field.becomeFirstResponder() }
    }

    private func keyboardChanged(_ n: Notification) {
        guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let inView = view.convert(f, from: nil)
        let h = max(0, view.bounds.height - inView.minY)
        keyboardHeight = field.isFirstResponder && h > 120 ? h : 0
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    // MARK: sheets

    private func present<V: View>(_ v: V) {
        let c = UIHostingController(rootView: v.preferredColorScheme(.dark).tint(Color(red: 0.102, green: 0.643, blue: 0.529)))
        c.view.backgroundColor = UIColor(white: 0.07, alpha: 1)
        present(c, animated: true)
    }

    private func showPairing() { present(PairSheet()) }

    /// Hold the settings button: with more than one Mac, the fastest way to the other.
    private func macMenu(_ macs: [PairedMac], _ current: PairedMac?) {
        guard macs.count > 1 else { settingsButton.menu = nil; return }
        settingsButton.menu = UIMenu(title: String(localized: "Switch Computer"), children: macs.map { m in
            UIAction(title: m.title, state: m.id == current?.id ? .on : .off) { _ in
                guard m.id != Link.shared.current?.id else { return }
                Link.shared.choose(m)
            }
        })
    }

    private func showSettings() {
        present(SettingsSheet(onDeck: { [weak self] d in self?.setDeck(d) }))
    }

    private func showEditor() {
        present(NavigationStack { KeyEditor(deck: self.deck) { [weak self] d in self?.setDeck(d) } })
    }

    private func setDeck(_ d: Deck) {
        deck = d
        d.save(for: Link.shared.host)
        showDeck()
        view.setNeedsLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !field.isFirstResponder { becomeFirstResponder() }
        #if DEBUG
        Pretend.turn(view.window?.windowScene)
        #endif
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        status()
    }
}
