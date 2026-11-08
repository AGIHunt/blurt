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

    private var deck = Deck.load()
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
        // leaning back mustn't rotate the screen under a thumb
        guard touching, let o = view.window?.windowScene?.interfaceOrientation else { return [.portrait, .landscapeLeft, .landscapeRight] }
        return o == .portrait ? .portrait : o == .landscapeLeft ? .landscapeLeft : .landscapeRight
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true

        view.addSubview(pad)
        pad.layer.insertSublayer(ScreenStream.shared.stage, at: 0)
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
        appsCell.slot = KeySlot(.chord(RemoteChord(.command, "Tab"), cycle: true), glyph: "mark:apps", caption: "", hint: String(localized: "Apps"))
        appsCell.onCycle = { [weak self] on in self?.cycling(on, by: self?.appsCell) }
        view.addSubview(appsCell)
        view.addSubview(talk)
        view.addSubview(drawerButton)
        view.addSubview(screenButton)
        strip.onSelect = { [weak self] i in self?.go(i) }
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

        pad.onViewEnd = { [weak self] in self?.viewSettled() }
        pad.onHaptic = { h in
            switch h {
            case .tap: Haptics.tick()
            case .grab: Haptics.grab()
            case .release: Haptics.release()
            case .step: Haptics.step()
            }
        }
        pad.onClick = { Sticky.shared.used() }
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
            Sticky.shared.clear()
        }
        touched()
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
        // closer in, the same stroke crosses less of the Mac's screen
        pad.engine.curve = RemotePointerCurve().scaled(Float(p.pointerSpeed) / max(1, Float(ScreenStream.shared.port.zoom).squareRoot()))
        pad.engine.scrollGain = 2.4 * CGFloat(p.scrollSpeed)
        pad.engine.touchMode = showing && p.tapWhereTouched
        view.setNeedsLayout()
    }

    private func observe() {
        let l = Link.shared
        Publishers.CombineLatest3(l.$state, l.$current, l.$canControl).receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in DispatchQueue.main.async { self?.status() } }.store(in: &bag)
        Publishers.CombineLatest(l.$macs, l.$current).receive(on: RunLoop.main).sink { [weak self] macs, current in
            self?.macMenu(macs, current)
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
            text = String(localized: "On your Mac, open Blurt’s Settings and choose iPhone.")
            button = String(localized: "Scan Code")
        case .forgotten:
            text = String(localized: "\(l.current?.title ?? "This Mac") no longer knows this iPhone.")
            button = String(localized: "Scan Code")
        case .unreachable:
            let n = l.current?.title ?? "Mac"
            text = l.current?.relayAddress == nil ? String(localized: "Can’t reach \(n). Check that Blurt is running and both are on the same network.")
                : String(localized: "Can’t reach \(n). Check that it’s awake and Blurt is running.")
            if l.macs.count > 1 { button = String(localized: "Try Another Mac") }
        case .connecting: break
        case .replaced:
            text = String(localized: "Another iPhone is connected. Touch to take over.")
        case .connected:
            if !l.canControl { text = String(localized: "On your Mac, allow Accessibility for Blurt.") }
            if l.screenError == "permission" { text = String(localized: "On your Mac, allow Screen Recording for Blurt.") }
            if l.screenError == "off" { text = String(localized: "Showing the screen is off in Blurt’s Settings on your Mac.") }
        }
        if l.waitingForMac {
            text = String(format: String(localized: "Allow this iPhone in Blurt’s Settings on your Mac. Check that it shows %@."), l.pairCheck ?? "")
            button = nil
        }
        if let f = l.pairFailed { text = f }
        message.text = text
        message.isHidden = text == nil
        action.setTitle(button, for: .normal)
        action.isHidden = button == nil
        let name = l.current?.title ?? ""
        let via = l.route == .relay ? String(localized: "\(name) · Internet") : l.route == .direct ? String(localized: "\(name) · Direct") : name
        header.text = showing && l.state == .connected ? nil : l.state == .connected ? via : l.state == .connecting ? String(localized: "Connecting to \(name)…") : nil
        let ready = l.state == .connected
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
                                  message: Link.shared.macs.contains { $0.id == p.macID } ? String(localized: "This iPhone is already paired with this Mac. This replaces that pairing.")
                                      : String(localized: "This Mac will receive what you type and say here. Only pair with your own Mac."), preferredStyle: .alert)
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

    /// Landscape, the keys put away: the modifiers went with them, so none stays held on the Mac out of sight.
    private func keysPutAway() {
        guard !drawerOpen, view.bounds.width > view.bounds.height, !Sticky.shared.held.isEmpty else { return }
        Sticky.shared.release(Sticky.shared.held)
    }

    /// The fingers lifted: pointer speed follows how close the view now is.
    private func viewSettled() {
        applyPrefs()
    }

    private func micDenied() {
        let a = UIAlertController(title: String(localized: "Microphone Access Is Off"),
                                  message: String(localized: "Turn it on in Settings, or dictate through your Mac’s microphone."), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: String(localized: "Use Mac Microphone"), style: .default) { _ in
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
        // UIKit's landscapeRight has the home side on the right, so the island on the left
        let islandLeft = view.window?.windowScene?.interfaceOrientation == .landscapeRight
        let l = PadLayout(size: view.bounds.size, safe: view.safeAreaInsets, lefty: Prefs.shared.lefty, islandLeft: islandLeft, drawerOpen: drawerOpen)
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
        talk.frame = l.talk
        talk.isHidden = typing
        let railed = l.rail != nil
        let keysOut = !typing && (!railed || drawerOpen)
        list.isHidden = !keysOut
        list.frame = l.list
        list.arrange(key: l.keySize, gap: PadLayout.gap, tallest: l.landscape ? KeyList.tallest : nil)
        for (i, c) in dockCells.enumerated() {
            c.isHidden = typing || !(keysOut || PadLayout.staysOut(i))
            c.frame = l.dock[i]
        }
        arrowCell.isHidden = typing
        arrowCell.frame = l.arrowKey
        appsCell.isHidden = typing || !railed
        appsCell.frame = l.appsKey
        pad.engine.scrollEdge = PadLayout.scrollEdge(width: padFrame.width, lefty: Prefs.shared.lefty)   // the keyboard may have changed it
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
        strip.isHidden = typing || !keysOut
        // over the bottom of the pad, not over keys that are still in use while talking
        let chipsW = min(padFrame.width - 16, 300)
        chips.frame = CGRect(x: padFrame.midX - chipsW / 2, y: padFrame.maxY - 8 - 32, width: chipsW, height: 32)
        keyboardButton.frame = l.keyboardButton
        settingsButton.frame = l.settingsButton
        findButton.frame = l.findButton
        keyboardButton.isHidden = typing
        settingsButton.isHidden = typing
        findButton.isHidden = typing
        dim.frame = view.bounds

        ScreenStream.shared.layout(pad.bounds, alignY: l.landscape ? 0.5 : 1)
        edgeMark.isHidden = showing
        edgeMark.frame = CGRect(x: Prefs.shared.lefty ? 7 : pad.bounds.maxX - 10, y: pad.bounds.midY - 34, width: 3, height: 68)
        let inset = pad.bounds.insetBy(dx: 16, dy: 12)
        header.frame = CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 16)
        // above the chips, nearest the thumb; the newest words stay in view
        let wordsW = min(pad.bounds.width - 32, 420)
        let chipsTop = pad.bounds.maxY - 8 - 32 - 8
        let fit = ceil(liveText.sizeThatFits(CGSize(width: wordsW, height: .greatestFiniteMagnitude)).height)
        let hasWords = !(liveText.text ?? "").isEmpty
        liveText.frame = CGRect(x: pad.bounds.midX - wordsW / 2, y: chipsTop - 6 - fit, width: wordsW, height: fit)
        liveBack.frame = liveText.frame.insetBy(dx: -10, dy: -6)
        liveBack.isHidden = !hasWords
        let tall = sizeForMessage(inset.width)
        message.frame = CGRect(x: inset.minX + 8, y: pad.bounds.midY - tall / 2 - 20, width: inset.width - 16, height: tall)
        action.frame = CGRect(x: inset.minX, y: message.frame.maxY + 8, width: inset.width, height: 44)
    }

    private func sizeForMessage(_ w: CGFloat) -> CGFloat {
        ceil((message.text as NSString? ?? "").boundingRect(with: CGSize(width: w - 16, height: 400), options: .usesLineFragmentOrigin,
                                                           attributes: [.font: message.font as Any], context: nil).height)
    }

    override func viewWillTransition(to size: CGSize, with c: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: c)
        drawerOpen = !showing
        pad.letGo()
    }

    // MARK: keys

    private func showDeck() {
        list.show(deck.sections)
        strip.show(names: deck.sections.map(\.name), page: list.section)
        for (i, c) in dockCells.enumerated() { c.slot = deck.dock[i] }
        status()
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
        settingsButton.menu = UIMenu(title: String(localized: "Switch Mac"), children: macs.map { m in
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
        d.save()
        showDeck()
        view.setNeedsLayout()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        status()
    }
}
