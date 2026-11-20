// Home (docs/design/capabilities.md): the main window's first page. Top to bottom:
//
//   the five capabilities   one box, always all five in the same order (dictation, cards, screen text, recording,
//                           phone). A row: the capability's glyph and name, one line under it — what it does, or the
//                           one thing standing in its way with the button that fixes it —, its keys, its switch. An
//                           off row keeps its place: dimmed, no keys, the switch off.
//   waiting for you         one quiet line each: new items and items to verify (Recording on), cards hanging under the
//                           notch (Cards on).
//   recent                  one timeline of what was made with the capabilities that are on (BlurtCore HomeFeed):
//                           dictations, cards, text from the screen (⌥C / ⌥T), recordings with their state (BlurtCore
//                           Recordings, RecordingViews), items, newest first under their days. Nothing made yet: Peep and the
//                           one thing to try per capability.
//
// The facts in the rows are read from where the rest of the app reads them (SpeechSetup.menuRow as the menu-bar menu,
// DictationHistoryModel.pageStatus as the Dictation page, HotkeyCenter's states, AgentHub's check, PhoneStatus), never
// checked a second way here.
//
// The keyboard (HomeKeyView is the page's first responder; BlurtCore HomeFeed.Walk decides where a key goes):
//   ↑ ↓      line by line through the page          ← →   along a capability's line: its row, its fix, its switch
//   Tab ⇧Tab every row, fix and switch, the links, the timeline as one stop
//   ↩ Space  the stop's action (a row: its place; a switch: flips it) — in the timeline ↩ is the row's main action
//            (a dictation, a card or a screen text is copied, an item opens) and ⌘C copies
//   Esc      lets go of the selection
//
// Test commands (`home …` on the shell channel): state | show | toggle <capability> | key <down|up|left|right|tab|
// backtab|return|space|esc|copy> | point <stop>|off | select <stop> | act <entry id> | scroll <y> | focus [off] | press <key>. Each ends with a `home_state` event.
import AppKit
import Combine
import SwiftUI
import BlurtCore

final class HomePage: FullPage {
    let model: HomeModel = MainActor.assumeIsolated { HomeModel() }
    lazy var viewController: NSViewController = MainActor.assumeIsolated { HomeViewController(model: model) }

    func didShow() { MainActor.assumeIsolated { model.didShow() } }
    func didHide() { MainActor.assumeIsolated { model.didHide() } }

    /// `home …` (SnapApp.testCommand).
    static func testCommand(_ arg: String) {
        MainActor.assumeIsolated {
            guard let p = MainWindowController.shared.fullPage(.home) as? HomePage else { return }
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = a.count > 1 ? a[1] : ""
            let m = p.model
            switch a.first ?? "state" {
            case "show": MainWindowController.shared.showHome()
            case "toggle": if let c = Capability(rawValue: rest) { m.set(c, on: !c.isOn) }
            case "key": m.testKey(rest)
            case "point": m.pointed = rest == "off" || rest.isEmpty ? nil : HomeModel.stop(named: rest)
            case "select": m.select(HomeModel.stop(named: rest), keyboard: false)
            case "act": m.primary(rest)
            case "press":           // press K: a real key event through the window (menus first, then its first responder)
                let codes: [String: (UInt16, NSEvent.ModifierFlags, String)] = [
                    "down": (125, [], ""), "up": (126, [], ""), "left": (123, [], ""), "right": (124, [], ""), "tab": (48, [], "\t"),
                    "backtab": (48, [.shift], "\t"), "return": (36, [], "\r"), "space": (49, [], " "), "esc": (53, [], "\u{1b}"),
                    "copy": (8, [.command], "c")]
                if let (code, flags, chars) = codes[rest], let w = m.keyView?.window,
                   let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    // ⌘C is Edit ▸ Copy: its action goes down the key window's responders; a scratch app that isn't
                    // in front has no key window, so the same action is tried on this window's responders
                    var menu = false
                    if flags.contains(.command) {
                        menu = w.isKeyWindow ? (NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false)
                            : (w.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) ?? false)
                    }
                    if !menu { w.sendEvent(e) }
                    emit(["event": "home_press", "key": rest, "menu": menu, "first_responder": w.firstResponder.map { String(describing: type(of: $0)) } ?? ""])
                }
            case "focus": m.focused = rest != "off"          // as if the window were key with the keyboard on the page (screenshots)
            case "scroll":          // scroll Y: the column scrolled to Y points from its top (screenshots)
                if let v = m.keyView, let sv = HomeKeyView.scrollView(in: v), let doc = sv.documentView, let y = Double(rest) {
                    // (the column starts under the toolbar: the scroll view's top inset)
                    let inset = sv.contentInsets.top
                    let top = max(-inset, min(CGFloat(y) - inset, doc.bounds.height - sv.contentView.bounds.height))
                    sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? top : doc.bounds.height - sv.contentView.bounds.height - top))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            default: break
            }
            m.refresh()
            emit(m.state)
        }
    }
}

// MARK: - what the page shows

/// One key of a capability, as caps: "⌥A" → ["⌥", "A"].
struct HomeKey: Equatable {
    var caps: [String]
    /// what the key does (the caps' tooltip and VoiceOver label)
    var tip: String
    /// the key is there but what it does can't run yet (⌥T without a model to translate with): drawn quietly, `tip` says why
    var dim = false
}

/// A capability's row.
struct HomeRow: Equatable, Identifiable {
    enum Tone: String { case what, note, trouble }
    let capability: Capability
    var on: Bool
    /// what the line under the name is: what the capability does, a quiet fact (a phone is connected, a download
    /// runs), or the one thing standing in its way (attention ink)
    var tone = Tone.what
    var text: String
    /// the one button after the line, and what it does (HomeModel.fix)
    var fix: String?
    var fixKind: String?
    var keys: [HomeKey] = []
    /// more about the line (a taken key: by what), as its tooltip
    var tip: String?

    var id: String { capability.rawValue }
    var name: String { T("feature.\(capability.rawValue)") }
    /// the sidebar's symbols (SidebarController.rebuild, Settings' panes)
    var glyph: String {
        switch capability {
        case .dictation: return "character.cursor.ibeam"
        case .cards: return "rectangle.stack"
        case .screenText: return "text.viewfinder"
        case .recording: return "record.circle"
        case .phone: return "laptopcomputer.and.iphone"
        }
    }
    /// its Settings pane (one that isn't there yet opens General: SettingsController.show)
    var pane: String {
        switch capability {
        case .dictation: return "dictation"
        case .cards: return "cards"
        case .screenText: return "screentext"
        case .recording: return "recording"
        case .phone: return "remote"
        }
    }
}

/// A line under the box: something waiting for the user, and where it is.
struct HomeWaiting: Equatable, Identifiable {
    var id: String
    var glyph: String
    /// the count of new items, in the mint pill (system.md §3.3: the one "new" mark)
    var pill: Int?
    var text: String
    var link: String
}

/// The empty state's line for a capability: the one thing to try, its key inside the sentence — or, when the
/// capability can't run yet, the row's own fix.
struct HomeTry: Equatable, Identifiable {
    var id: String
    var before = ""
    var caps: [String] = []
    var after = ""
    var trouble: String?
    var fix: String?
    var capability: Capability
}

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var rows: [HomeRow] = []
    @Published private(set) var waiting: [HomeWaiting] = []
    @Published private(set) var feed = HomeFeed.Feed()
    @Published private(set) var days: [HomeFeed.Day] = []
    /// where the keyboard is; a timeline row here is the selection (a click selects too)
    @Published private(set) var cursor: HomeFeed.Stop?
    /// the cursor was moved with the keyboard: rows, switches and links show the focus ring
    @Published private(set) var keyboard = false
    /// the page has the keyboard (its key view is the first responder of the key window)
    @Published var focused = false
    /// what the pointer is over (rows and timeline rows report it; tests set it: `home point …`)
    @Published var pointed: HomeFeed.Stop?
    /// the timeline row just copied: its button shows the check for 1.2 s
    @Published private(set) var copied: String?
    /// a stop to bring into view (the keyboard moved there); `seq` so the same stop can be asked for twice
    @Published private(set) var reveal: (stop: HomeFeed.Stop, seq: Int)?

    private(set) var dictations: [String: DictationEntry] = [:]
    private(set) var shots: [String: Shot] = [:]
    private(set) var items: [String: ItemRow] = [:]
    /// the recordings on the timeline, by folder
    private(set) var recordings: [String: Recordings.Row] = [:]
    private(set) var screenTexts: [String: ScreenTextEntry] = [:]
    /// dictations that weren't recognised, recording kept (DictationRetry.onHome): the row offers Retry
    private(set) var failed: Set<String> = []
    /// a failed row whose Retry is running: "Recognizing…" until the history has its text
    @Published private(set) var retrying: Set<String> = []

    /// a coding agent can take a recording (AgentHub's cached check; nil: not known yet — nothing is claimed)
    private var agentReady: Bool?
    /// the same, for a recording's row (Organize, or Set Up an Agent…)
    var recAgent: Bool? { agentReady }
    private var shown = false
    private var timer: Timer?
    private var watching = false
    private var bag = Set<AnyCancellable>()
    private var indexVersion = -1
    private var feedDue = false
    weak var keyView: NSView?

    // MARK: life

    /// The page came on show: everything is read again, and it follows what changes while it shows.
    func didShow() {
        shown = true
        watch()
        DictationModels.shared.loadIfNeeded()
        checkAgent()
        refresh()
        timer?.invalidate()
        // what has no notification of its own (the key's permission, the index): looked at every 2 s while the page
        // shows; nothing runs while it is hidden
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func didHide() {
        shown = false
        timer?.invalidate()
        timer = nil
        pointed = nil
    }

    private func watch() {
        guard !watching else { return }
        watching = true
        let nc = NotificationCenter.default
        let facts: [Notification.Name] = [Capability.didChange, HotkeyCenter.didChange, Dictation.settingsChanged, Dictation.translateConfigChanged,
                                          RemoteServer.statusChanged, RemoteServer.devicesChanged]
        for n in facts {
            // (a switch changes what the timeline lists; the others only the rows)
            let feed = n == Capability.didChange
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.changed(feed: feed) } }
        }
        let made: [Notification.Name] = [DictationHistory.changed, .blurtCardsChanged, .blurtTakenChanged, .blurtJobsChanged,
                                         .blurtScreenTextChanged]
        for n in made { nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.changed(feed: true) } } }
        // the speech model, its download and the permissions are observable objects: their changes redraw the rows
        DictationModels.shared.objectWillChange.sink { [weak self] _ in self?.changed(feed: false) }.store(in: &bag)
        ModelDownloads.shared.objectWillChange.sink { [weak self] _ in self?.changed(feed: false) }.store(in: &bag)
        PermissionGuide.shared.objectWillChange.sink { [weak self] _ in self?.changed(feed: false) }.store(in: &bag)
    }

    /// Something changed: read again on the next turn of the run loop (once for a burst), only while on show.
    private func changed(feed: Bool) {
        guard shown else { return }
        if feed { feedDue = true }
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                guard self.shown else { return }
                if self.feedDue { self.refresh() } else { self.refreshFacts() }
            }
        }
    }
    private var refreshQueued = false

    private func tick() {
        guard shown else { return }
        let v = Capability.recording.isOn ? MainWindowController.shared.model.reader?.dataVersion ?? 0 : 0
        if v != indexVersion { refresh() } else { refreshFacts() }
    }

    /// Everything: the rows, the lines under them and the timeline.
    func refresh() {
        feedDue = false
        refreshFacts()
        reloadFeed()
    }

    /// The rows and the lines under them (cheap: no file is read).
    func refreshFacts() {
        let r = Capability.allCases.map(row)
        if r != rows { rows = r }
        let w = makeWaiting()
        if w != waiting { waiting = w }
        keepCursor()
    }

    // MARK: the rows

    private func what(_ c: Capability) -> String {
        // (the key's short name, as Settings → General writes the same sentence)
        c == .dictation ? T("feature.dictation.what", Dictation.keyShort) : T("feature.\(c.rawValue).what")
    }

    private func key(_ a: HotAction, unavailable: String? = nil) -> HomeKey? {
        let label = hk(a)
        guard !label.isEmpty else { return nil }
        return HomeKey(caps: KeyCaps.split(label), tip: unavailable ?? a.title, dim: unavailable != nil)
    }

    /// The shown keys that don't work (taken by another app or another Blurt, a macOS shortcut, set twice): the
    /// row says so with the way to Settings → Shortcuts.
    private func conflict(_ actions: [HotAction], into r: inout HomeRow) {
        let bad = actions.filter { Hotkeys.shared.state($0).isConflict }
        guard let first = bad.first else { return }
        let labels = bad.map { hk($0) }.filter { !$0.isEmpty }
        guard !labels.isEmpty else { return }
        r.tone = .trouble
        // (a row shows two keys at most: "⌥A and ⌥V")
        r.text = labels.count == 1 ? T("home.keys.taken", labels[0])
            : T("home.keys.taken_many", labels.dropFirst().reduce(labels[0]) { T("home.keys.and", $0, $1) })
        // what the capability does stays one hover away (the line now says what's in its way)
        r.tip = [what(r.capability), Hotkeys.shared.state(first).text].filter { !$0.isEmpty }.joined(separator: "\n")
        r.fix = T("home.keys.change")
        r.fixKind = "keys"
    }

    private func row(_ c: Capability) -> HomeRow {
        var r = HomeRow(capability: c, on: c.isOn, text: what(c))
        guard r.on else { return r }
        switch c {
        case .dictation:
            r.keys = [HomeKey(caps: [Dictation.keyShort.trimmingCharacters(in: .whitespaces)], tip: T("feature.dictation"))]
            let dm = DictationModels.shared
            // the menu-bar menu's first row, word for word the same decision (AppDelegate.menuNeedsUpdate)
            switch SpeechSetup.menuRow(enabled: true, deferred: Dictation.shared.deferredTo != nil,
                                       needsPermissions: Dictation.shared.needsSetup, ready: dm.dictationReady,
                                       readable: !dm.asrUnreadable, downloading: ModelDownloads.shared.active) {
            case .turnOn?:
                r.tone = .trouble; r.text = T("main.dictation.banner.permission")
                r.tip = T("dictation.menu.turn_on.tip", Dictation.keyInline)
                r.fix = T("dictation.menu.turn_on"); r.fixKind = "permission"
            case .setUp?:
                r.tone = .trouble; r.text = T("dictation.menu.set_up.subtitle")
                r.fix = T("dictation.menu.set_up"); r.fixKind = "speech"
            case .getModel?:
                r.tone = .trouble; r.text = T("main.dictation.banner.no_model")
                if let j = dm.offerJob {
                    r.fix = T("dictation.toast.no_model.action_size", modelSize(j.sizeMB)); r.fixKind = "model"
                } else {
                    r.fix = T("dictation.toast.no_model.settings"); r.fixKind = "choose_model"
                }
            case nil:
                // another copy of Blurt hears the key (menuRow says nothing then): said here as the ⌥ rows say theirs,
                // the key quiet, with the Dictation page's way out — not "Press Fn" (dogfood 2026-11-21)
                if Dictation.shared.deferredTo != nil, !HotkeySettings.solo {
                    let key = Dictation.keyShort.trimmingCharacters(in: .whitespaces)
                    let keys = HotkeySettings.shared
                    r.keys = [HomeKey(caps: [key], tip: T("dictation.status.other_instance_key", Dictation.keyInline), dim: true)]
                    r.tone = .trouble
                    r.text = T("home.keys.taken", key)
                    r.tip = T("dictation.status.other_instance_key", Dictation.keyInline)
                    if keys.otherApps.isEmpty {
                        r.fix = T("home.keys.change"); r.fixKind = "dictation_settings"
                    } else {
                        r.fix = Loc.t(keys.others.count > 1 ? "capture.keys.quit_others" : "capture.keys.quit_other", table: "Capture")
                        r.fixKind = "quit_other"
                    }
                    break
                }
                // its model is on its way: how far, quietly (the Dictation page's banner says the same)
                if case let .downloading(done, total) = DictationHistoryModel.pageStatus(enabled: true, needsSetup: false) {
                    r.tone = .note; r.text = T("home.dictation.downloading", modelSize(done), modelSize(total))
                    r.fix = T("dictation.toast.model_downloading.action"); r.fixKind = "download"
                    break
                }
                // dictation works: a download that runs (the first run starts one without asking) is said here with
                // Stop, quietly — the menu row's numbers; stopped or never fetched, the more accurate set is offered
                // (BlurtCore ModelDownloadNotice.home)
                betterModels(dm, into: &r)
            }
        case .cards:
            r.keys = [key(.snap), key(.voice)].compactMap { $0 }
            conflict([.snap, .voice], into: &r)
        case .screenText:
            // copying needs nothing; translating needs a model (ScreenTextCopy.needsModel: no cloud model and no
            // local one) — said on its key, not as trouble: ⌥C works
            let noModel = ScreenTextCopy.translateCloud == nil && Dictation.shared.polishModel == nil
            r.keys = [key(.text), key(.translateText, unavailable: noModel ? Loc.t("capture.text.translate_needs_model", table: "Capture") : nil)].compactMap { $0 }
            conflict([.text, .translateText], into: &r)
        case .recording:
            r.keys = [key(.toggleRecord)].compactMap { $0 }
            if agentReady == false {
                // no agent CLI to organize in the background: said quietly with the other way to do it (asking an
                // agent that has the skill, in its chat) — recording itself works
                r.tone = .note; r.text = T("home.recording.no_agent")
                r.fix = T("home.recording.set_up_agent"); r.fixKind = "agent"
            } else {
                conflict([.toggleRecord], into: &r)
            }
        case .phone:
            // the Phone page's own words (PhoneStatus): who is connected, or that nobody is; no phone paired yet:
            // what the capability does, and the way to add one; paired but this Mac can't be controlled: that
            if let line = PhoneStatus.line {
                if PhoneStatus.needsAttention {
                    r.tone = .trouble; r.text = T("home.phone.needs_access")
                    r.fix = T("home.phone.look"); r.fixKind = "phone"
                } else {
                    r.tone = .note; r.text = line
                }
            } else {
                r.fix = T("phone.menu.add"); r.fixKind = "phone"
            }
        }
        return r
    }

    /// Dictation's line about this Mac's more accurate models while dictation already works: the download with Stop,
    /// the offer after a Stop, or the retry after it broke off.
    private func betterModels(_ dm: DictationModels, into r: inout HomeRow) {
        let dl = ModelDownloads.shared
        let better = dm.recommendedASR
        let betterMissing = better.map { !$0.installed && $0.builtin != true } ?? false
        // the polish model, offered on its own once the recogniser is in (the assistant brings only the recogniser):
        // while polish picks its model by itself and no cloud key polishes
        let polish = dm.polishAuto && !DictationCloud.ready ? dm.recommendedPolish.flatMap { $0.installed ? nil : $0 } : nil
        let offered = betterMissing ? better?.id : polish?.id
        let line = ModelDownloadNotice.home(ready: dm.dictationReady, downloading: dl.active, unpacking: dl.isUnpacking(dl.current ?? ""),
                                            progress: dl.progress, automatic: dm.asrAuto, betterMissing: betterMissing,
                                            missingMB: better?.sizeMB ?? 0, polishMB: polish?.sizeMB ?? 0,
                                            failed: offered.map { dl.failed[$0] != nil } ?? false)
        switch line {
        case .usual: return
        case .downloading(let done, let total):
            let polishing = dl.queue.pending.first { $0.id == dl.current }?.kind == .polish
            r.text = T(polishing ? "home.dictation.polish_downloading" : "home.dictation.better_downloading", modelSize(done), modelSize(total))
            r.fix = T("app.models.stop"); r.fixKind = "stop_download"
        case .unpacking:
            r.text = T("app.models.menu_unpacking")
            r.fix = T("app.models.stop"); r.fixKind = "stop_download"
        case .interrupted:
            r.text = T("onboarding.models.failed_toast")
            r.fix = T("onboarding.models.retry"); r.fixKind = "better_models"
        case .offer(let mb):
            // the line is the offer itself, in link ink
            r.text = ""
            r.fix = T("home.dictation.better_offer", modelSize(mb)); r.fixKind = "better_models"
        case .offerPolish(let mb):
            r.text = ""
            r.fix = T("home.dictation.polish_offer", modelSize(mb)); r.fixKind = "better_models"
        }
        r.tone = .note
    }

    /// Is any coding agent usable (what Snapper.agentReady asks before handing cards over: AgentHub's cached check;
    /// tests: BLURT_TEST_AGENTS=none|ready, a stubbed process counts as ready)?
    private func checkAgent() {
        guard Capability.recording.isOn else { return }
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let t = env["BLURT_TEST_AGENTS"] { agentReady = t != "none"; return }
        if env["BLURT_TEST_PROCESS"] != nil { agentReady = true; return }
        let hub = AgentHub.shared
        hub.check(hub.order()) { [weak self] st in
            let ok = st.contains { $0.state.usable }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.agentReady = ok; self?.changed(feed: false) } }
        }
    }

    private func makeWaiting() -> [HomeWaiting] {
        var out: [HomeWaiting] = []
        if Capability.recording.isOn {
            let c = MainWindowController.shared.model.counts
            if c.new > 0 || c.toVerify > 0 {
                // the window's own words ("6 new · 2 to verify": MainWindowController.needsYou), the new count as the pill
                let parts = (c.new > 0 ? [T("home.waiting.new")] : []) + (c.toVerify > 0 ? [T("main.inbox.verify", c.toVerify)] : [])
                out.append(HomeWaiting(id: "inbox", glyph: "tray", pill: c.new > 0 ? c.new : nil, text: parts.joined(separator: " · "),
                                       link: T("home.waiting.open_inbox")))
            }
        }
        if Capability.cards.isOn, let n = AppEnvironment.island?.hangingCount, n > 0 {
            out.append(HomeWaiting(id: "cards", glyph: "rectangle.stack", pill: nil, text: TP("home.waiting.cards", n), link: T("home.waiting.show")))
        }
        return out
    }

    /// The try-line for a capability whose key is taken: what its row says about it, with the same fix.
    private func taken(_ a: HotAction, _ r: HomeRow) -> HomeTry? {
        guard Hotkeys.shared.state(a).isConflict, r.tone == .trouble else { return nil }
        return HomeTry(id: r.capability.rawValue, trouble: r.text, fix: r.fix, capability: r.capability)
    }

    /// The empty state's lines: per capability that is on, the one thing to try.
    var tries: [HomeTry] {
        rows.filter(\.on).compactMap { r in
            let c = r.capability
            func line(_ key: String, _ caps: [String]) -> HomeTry? {
                guard !caps.isEmpty else { return nil }
                let parts = Loc.string(key, table: table(of: key)).components(separatedBy: "%@")     // (the raw sentence: the key is drawn in the gap).map { $0.trimmingCharacters(in: .whitespaces) }
                return HomeTry(id: c.rawValue, before: parts.first ?? "", caps: caps, after: parts.count > 1 ? parts[1] : "", capability: c)
            }
            switch c {
            case .dictation:
                // it can't run yet: the fix, not a promise
                if r.tone == .trouble { return HomeTry(id: c.rawValue, trouble: r.text, fix: r.fix, capability: c) }
                return line("home.try.dictation", r.keys.first?.caps ?? [])
            // a key that is taken would be a dead promise: the row's own "⌥A is taken · Change Key…" instead
            case .cards: return taken(.snap, r) ?? line("home.try.cards", KeyCaps.split(hk(.snap)))
            case .screenText: return taken(.text, r) ?? line("home.try.screen_text", KeyCaps.split(hk(.text)))
            case .recording: return taken(.toggleRecord, r) ?? line("home.try.recording", KeyCaps.split(hk(.toggleRecord)))
            case .phone:
                guard PhoneStatus.line == nil else { return nil }        // a phone is paired already
                return HomeTry(id: c.rawValue, before: T("home.try.phone"), capability: c)
            }
        }
    }

    // MARK: the timeline

    static func cardKey(_ s: Shot) -> String { "\(s.batch?.dir.path ?? "")#\(s.n)" }

    private func reloadFeed() {
        var ds: [HomeFeed.Entry] = [], cs: [HomeFeed.Entry] = [], sts: [HomeFeed.Entry] = [], rs: [HomeFeed.Entry] = [], its: [HomeFeed.Entry] = []
        dictations = [:]; shots = [:]; items = [:]; screenTexts = [:]; failed = []; thumbs = [:]; recordings = [:]
        if Capability.dictation.isOn {
            for e in DictationHistory.shared.load() where DictationRetry.onHome(e, audioKept: App.audioKept) {
                dictations[e.id] = e
                let isFailed = DictationRetry.failed(e)
                if isFailed { failed.insert(e.id) } else { retrying.remove(e.id) }
                ds.append(.init(kind: .dictation, key: e.id, time: e.time,
                                source: AppNames.display(name: e.app, bundle: e.bundle) ?? T("main.dictation.unknown_app"),
                                text: isFailed ? T("home.entry.failed", DictationHistoryModel.duration(e.duration))
                                               : DictationEntry.preview(e.finalText)))
            }
        }
        if Capability.cards.isOn {
            for s in snapper.cards + snapper.recentlyTaken {
                let k = HomeModel.cardKey(s)
                shots[k] = s
                let name = s.ref != nil ? T("home.entry.file") : T(s.kind == .voice ? "home.entry.voice" : "home.entry.snap")
                let words = s.words?.replacingOccurrences(of: "\n", with: " ")
                    ?? (s.kind == .voice ? HangingCards.statusText(s.note.status) : s.refURL?.lastPathComponent) ?? ""
                cs.append(.init(kind: .card, key: k, time: Date(timeIntervalSince1970: s.wall), source: name, text: words))
            }
        }
        if Capability.screenText.isOn {
            for e in ScreenTextHistory.shared.load().prefix(HomeFeed.limit) {
                screenTexts[e.id] = e
                sts.append(.init(kind: .screenText, key: e.id, time: e.time, source: ScreenTextPage.source(e),
                                 text: ScreenTextEntry.preview(e.text)))
            }
        }
        if Capability.recording.isOn, let reader = MainWindowController.shared.model.reader {
            indexVersion = reader.dataVersion
            var q = ItemQuery()
            q.sort = "created"
            q.limit = 10
            // every recording, with its state word: "Recording · 3:12 · 2 items" over the first thing said in it (else
            // "Untitled recording")
            for r in RecordingLook.rows(reader) {
                recordings[r.facts.dir] = r
                rs.append(.init(kind: .recording, key: r.facts.dir, time: Date(timeIntervalSince1970: r.facts.created ?? 0),
                                source: RecordingLook.source(r), text: RecordingLook.line(r)))
            }
            for it in (try? reader.items(q)) ?? [] {
                items[it.uid] = it
                let project = it.projectID == "inbox" ? T("project.inbox") : it.projectName
                its.append(.init(kind: .item, key: it.uid, time: Date(timeIntervalSince1970: it.created),
                                 source: it.itemID.isEmpty ? project : it.itemID + " · " + project, text: it.title))
            }
        } else {
            indexVersion = 0
        }
        let f = HomeFeed.merge(dictations: ds, cards: cs, screenTexts: sts, recordings: rs, items: its, off: Capability.off)
        if f != feed {
            feed = f
            days = HomeFeed.days(f.entries)
        }
        keepCursor()
    }

    func entry(_ id: String) -> HomeFeed.Entry? { feed.entries.first { $0.id == id } }

    private var thumbs: [String: CGImage] = [:]
    /// A snap's picture for its row: cut to the row's 56 × 40 from its top-left corner, as a tile of the Cards panel
    /// (CardTile.topLeading: a window's title stays in view). nil: a voice note, or no picture.
    func thumb(_ key: String) -> CGImage? {
        if let t = thumbs[key] { return t }
        guard let s = shots[key], s.kind == .shot, let img = s.markedThumb ?? s.thumb else { return nil }
        let t = CardTile.topLeading(img, box: HomeMetrics.thumb)
        thumbs[key] = t
        return t
    }

    /// The links that close the timeline: one per kind that has anything ("Show all dictation").
    /// Recordings have no page of their own: no link of theirs.
    var closing: [(id: String, title: String)] {
        feed.kinds.compactMap { k in
            switch k {
            case .dictation: return ("all.dictation", T("home.all.dictation"))
            case .card: return ("all.cards", T("home.all.cards"))
            case .screenText: return ("all.screen_text", T("home.all.screen_text"))
            case .recording: return nil
            case .item: return ("all.items", T("home.all.items"))
            }
        }
    }

    // MARK: the keyboard's walk

    var walk: HomeFeed.Walk {
        HomeFeed.Walk(on: rows.filter(\.on).map(\.capability), fixes: rows.filter { $0.fix != nil }.map(\.capability),
                      waiting: waiting.map(\.id), entries: feed.entries.map(\.id), closing: closing.map(\.id))
    }

    private func keepCursor() {
        let k = walk.keep(cursor)
        if k != cursor { cursor = k }
        if let p = pointed, !walk.contains(p) { pointed = nil }
    }

    /// Puts the keyboard on a stop (`keyboard`: moved there with a key — the ring shows and it scrolls into view).
    func select(_ s: HomeFeed.Stop?, keyboard k: Bool) {
        if let s, !walk.contains(s) { return }
        cursor = s
        keyboard = k && s != nil
        if k, let s { reveal = (s, (reveal?.seq ?? 0) + 1) }
        takeFocus()
    }

    func takeFocus() {
        guard let v = keyView, let w = v.window, w.firstResponder !== v else { return }
        w.makeFirstResponder(v)
    }

    /// A key the page takes; false: not ours (the window goes on with it).
    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(e.keyCode), mods) {
        case (125, []): return key("down")
        case (126, []): return key("up")
        case (123, []): return key("left")
        case (124, []): return key("right")
        case (48, []): return key("tab")
        case (48, [.shift]): return key("backtab")
        case (36, []), (76, []): return key("return")
        case (49, []): return key("space")
        case (53, []): return key("esc")
        case (8, [.command]): return key("copy")
        default: return false
        }
    }

    @discardableResult
    func key(_ name: String) -> Bool {
        let w = walk
        switch name {
        case "down", "up": select(w.vertical(from: cursor, down: name == "down"), keyboard: true)
        case "left", "right":
            guard cursor?.capability != nil else { return false }
            select(w.horizontal(from: cursor, right: name == "right"), keyboard: true)
        case "tab", "backtab": select(w.tab(from: cursor, forward: name == "tab"), keyboard: true)
        case "return", "space":
            switch cursor {
            case .row(let c)?: open(c)
            case .toggle(let c)?: set(c, on: !c.isOn)
            case .fix(let c)?: fix(c)
            case .link(let id)?: link(id)
            case .entry(let id)?:
                guard name == "return" else { return false }
                primary(id)
            case nil: return false
            }
        case "esc":
            guard cursor != nil else { return false }
            select(nil, keyboard: false)
        case "copy":
            guard case .entry(let id)? = cursor else { return false }
            copy(id)
        default: return false
        }
        return true
    }

    func testKey(_ name: String) { emit(["event": "home_key", "key": name, "taken": key(name)]) }

    /// A stop by its test name: "row:cards", "toggle:phone", "fix:dictation", "link:inbox", or an entry's id.
    static func stop(named s: String) -> HomeFeed.Stop {
        let p = s.split(separator: ":", maxSplits: 1).map(String.init)
        if p.count == 2, let c = Capability(rawValue: p[1]) {
            switch p[0] {
            case "row": return .row(c)
            case "toggle": return .toggle(c)
            case "fix": return .fix(c)
            default: break
            }
        }
        if p.count == 2, p[0] == "link" { return .link(p[1]) }
        return .entry(s)
    }

    static func name(of s: HomeFeed.Stop?) -> String {
        switch s {
        case .row(let c)?: return "row:" + c.rawValue
        case .toggle(let c)?: return "toggle:" + c.rawValue
        case .fix(let c)?: return "fix:" + c.rawValue
        case .link(let id)?: return "link:" + id
        case .entry(let id)?: return id
        case nil: return ""
        }
    }

    // MARK: what the stops do

    /// A capability's row: its place.
    func open(_ c: Capability) {
        guard c.isOn else { return select(.toggle(c), keyboard: true) }      // an off row only points at its switch
        emit(["event": "home", "action": "open", "capability": c.rawValue])
        let w = MainWindowController.shared
        switch c {
        case .dictation: w.showDictation()
        case .cards: w.go(.cards)
        case .screenText: w.go(.screenText)
        case .recording: w.go(.inbox)
        case .phone: w.go(.phone)
        }
    }

    func settings(_ r: HomeRow) {
        emit(["event": "home", "action": "settings", "pane": r.pane])
        AppEnvironment.settings?.show(pane: r.pane)
    }

    func set(_ c: Capability, on: Bool) {
        guard c.isOn != on else { return }
        let ok = Capability.set(c, on: on)
        emit(["event": "home", "action": "set", "capability": c.rawValue, "on": on, "ok": ok])
        if on, c == .recording { agentReady = nil; checkAgent() }
        refresh()                 // (CapabilityWatch's notice follows on the next turn: the switch answers now)
    }

    /// Home's offer, one model at a time with its own size: this Mac's recogniser while it is missing, then its
    /// polish model (the download manager first checks it fits on the disk).
    private func downloadBetter() {
        let dm = DictationModels.shared
        if let a = dm.recommendedASR, !a.installed, a.builtin != true {
            ModelDownloads.shared.download([.init(id: a.id, kind: .dictation, name: a.name ?? a.id, sizeMB: a.sizeMB)], via: "home")
        } else if let p = dm.recommendedPolish, !p.installed {
            ModelDownloads.shared.download([.init(id: p.id, kind: .polish, name: p.name, sizeMB: p.sizeMB)], via: "home")
        }
    }

    /// The one button of a row's line.
    func fix(_ c: Capability) {
        guard let kind = rows.first(where: { $0.capability == c })?.fixKind else { return }
        emit(["event": "home", "action": "fix", "capability": c.rawValue, "kind": kind])
        switch kind {
        case "permission": Dictation.shared.openSetup(from: "home")
        case "speech": Onboarding.shared.show(step: 2)
        case "model": Dictation.getSpeechModel(from: "home")
        case "choose_model": SpeechPane.showDictationModels()
        case "download": ModelDownloads.showProgress()
        case "stop_download": ModelDownloads.shared.stop()
        case "quit_other": HotkeySettings.shared.quitOthers()
        case "dictation_settings": AppEnvironment.settings?.show(pane: SettingsPane.dictation.rawValue)
        case "better_models": downloadBetter()
        case "agent": AppEnvironment.settings?.show(pane: SettingsPane.agents.rawValue)
        case "keys": AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue)
        case "phone": MainWindowController.shared.go(.phone)
        default: break
        }
    }

    func link(_ id: String) {
        emit(["event": "home", "action": "link", "id": id])
        let w = MainWindowController.shared
        switch id {
        case "inbox": w.go(.inbox)
        case "cards": w.go(.cards)
        case "all.dictation": w.showDictation()
        case "all.cards": w.go(.cards)
        case "all.screen_text": w.go(.screenText)
        case "all.items": w.go(.all)
        default: break
        }
    }

    /// A timeline row's main action (double-click, ↩, its button): a dictation's text is copied, a card is copied as a
    /// click on its tile in the Cards panel copies it, an item opens in its place.
    func primary(_ id: String) {
        guard let e = entry(id) else { return }
        if failed.contains(e.key) { return retry(e.key) }
        if e.kind == .recording, let r = recordings[e.key] {
            if let a = RecordingLook.homeAction(r, agent: agentReady) { RecordingLook.run(a, r) }
            return
        }
        if e.kind == .item {
            emit(["event": "home", "action": "open_item", "uid": e.key])
            MainWindowController.shared.reveal(uid: e.key)
        } else {
            copy(id)
        }
    }

    /// A failed dictation's Retry: the recording again, the text onto the clipboard (DictationRetry).
    func retry(_ key: String) {
        guard !retrying.contains(key) else { return }
        emit(["event": "home", "action": "retry", "id": key])
        retrying.insert(key)
        Dictation.shared.retry(key, via: "home", copy: true)
        // a retry that fails again leaves the row as it was
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            MainActor.assumeIsolated { _ = self?.retrying.remove(key) }
        }
    }

    /// ⌘C: the dictation's text, the screen text (the translation, for one), the card (picture and note, HangingCards.copyShot), the item's id and title.
    func copy(_ id: String) {
        guard let e = entry(id) else { return }
        var ok = true
        switch e.kind {
        case .dictation:
            if failed.contains(e.key) { return retry(e.key) }       // nothing to copy yet: Retry gives it
            DictationInsert.copy(dictations[e.key]?.finalText ?? e.text)
        case .card: ok = shots[e.key].map { HangingCards.copyShot($0, .click) } ?? false
        case .screenText: DictationInsert.copy(screenTexts[e.key]?.text ?? e.text)
        case .item: DictationInsert.copy(items[e.key].map { $0.itemID.isEmpty ? $0.title : $0.itemID + " " + $0.title } ?? e.text)
        case .recording:
            guard !e.text.isEmpty else { return }
            DictationInsert.copy(e.text)
        }
        emit(["event": "home", "action": "copy", "id": id, "ok": ok])
        guard ok else { return }
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { if self?.copied == id { self?.copied = nil } }
        }
    }

    // MARK: tests

    var state: [String: Any] {
        ["event": "home_state",
         "rows": rows.map { r -> [String: Any] in
             ["id": r.id, "on": r.on, "tone": r.tone.rawValue, "text": r.text, "fix": r.fix ?? NSNull(), "fix_kind": r.fixKind ?? NSNull(),
              "keys": r.keys.map { $0.caps.joined() + ($0.dim ? "?" : "") }]
         },
         "waiting": waiting.map { ["id": $0.id, "pill": $0.pill ?? NSNull(), "text": $0.text, "link": $0.link] as [String: Any] },
         "feed": feed.entries.prefix(8).map { ["id": $0.id, "source": $0.source, "text": String($0.text.prefix(60)),
                                              "time": DictationHistoryModel.time($0.time)] },
         "count": feed.entries.count, "ids": feed.entries.map(\.id),
         "days": days.map { DictationHistoryModel.dayTitle($0.day) + " (\($0.rows.count))" },
         "kinds": feed.kinds.map(\.rawValue), "cut": feed.cut.map(\.rawValue).sorted(),
         "tries": feed.isEmpty ? tries.map { $0.trouble ?? $0.before + $0.caps.joined() + $0.after } : [],
         "cursor": HomeModel.name(of: cursor), "keyboard": keyboard, "focused": focused, "copied": copied ?? NSNull()]
    }
}

// MARK: - the page's views in AppKit: the keyboard

/// The page: the SwiftUI column in a view that has the keyboard (the window's first responder while Home shows —
/// MainWindowController.focusList), so every key has one place to go whatever was clicked last.
final class HomeViewController: NSViewController {
    let model: HomeModel
    init(model: HomeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = HomeKeyView(model: model)
        let host = HomeHost(rootView: HomeView(m: model))
        host.frame = v.bounds
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { host.sizingOptions = [] }       // the window sizes the page
        v.addSubview(host)
        model.keyView = v
        view = v
    }
}

/// The SwiftUI column never takes the keyboard itself: a click on it leaves the page's key view the first responder.
final class HomeHost: NSHostingView<HomeView> {
    override var acceptsFirstResponder: Bool { false }
    required init(rootView: HomeView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

final class HomeKeyView: NSView {
    let model: HomeModel
    private var keyObservers: [NSObjectProtocol] = []

    init(model: HomeModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        focusRingType = .none            // the stop under the keyboard draws its own ring
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        model.focused = window?.isKeyWindow ?? false
        return true
    }
    override func resignFirstResponder() -> Bool {
        model.focused = false
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window else { return }
                    self.model.focused = w.isKeyWindow && w.firstResponder === self
                }
            })
        }
    }

    override func keyDown(with e: NSEvent) {
        if model.key(e) { return }
        // the keys that scroll a page, for the column's scroll view
        if let s = HomeKeyView.scrollView(in: self), let doc = s.documentView {
            let clip = s.contentView, page = clip.bounds.height - 40
            var y: CGFloat?
            switch Int(e.keyCode) {
            case 116: y = clip.bounds.minY + (doc.isFlipped ? -page : page)        // Page Up
            case 121: y = clip.bounds.minY + (doc.isFlipped ? page : -page)        // Page Down
            case 115: y = doc.isFlipped ? 0 : doc.bounds.height                    // Home
            case 119: y = doc.isFlipped ? doc.bounds.height : 0                    // End
            default: break
            }
            if let y {
                let top = max(0, min(y, doc.bounds.height - clip.bounds.height))
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
                s.reflectScrolledClipView(clip)
                return
            }
        }
        super.keyDown(with: e)
    }

    static func scrollView(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = scrollView(in: c) { return s } }
        return nil
    }

    /// Edit ▸ Copy (⌘C): the selected timeline row.
    @objc func copy(_ sender: Any?) { model.key("copy") }
    override func responds(to sel: Selector!) -> Bool {
        if sel == #selector(copy(_:)) { if case .entry? = model.cursor { return true } else { return false } }
        return super.responds(to: sel)
    }

    override func isAccessibilityElement() -> Bool { false }
}
