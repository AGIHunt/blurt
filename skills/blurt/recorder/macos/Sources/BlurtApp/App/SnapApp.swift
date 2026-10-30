// Menu-bar app glue for captures (K7): menu items, the voice / project hotkeys, start-up, and (BLURT_TEST_COMMANDS=1
// only) a distributed-notification command channel so scripted UI tests can drive the app without global hotkeys:
//   dev.blurt.recorder.command[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": …}
//     record · snap · snapregion x,y,w,h · commit · cancel · edit N · notes · stop · shortcuts · menu · toast TEXT …
//     menudump [FILE]         the ⌥B menu as text rows (also written to FILE), without opening it
//     cards [show|reveal|dismiss|older|hover [N]]  the cards down (peek) / to stay (= ⌥H) / Esc / "+N" clicked / as if the
//                             pointer rested on card N (no N: the pointer again); their state, every card's rect
//                             as "card" events (global top-left points)
//     cardcopy N [click|image|text] · cardmenu N · carddrag N PASTEBOARD [CLASS|BUNDLE]   a card's copies, menu, what
//                             a drag into that kind of app carries (rich chat terminal finder — or the old names web
//                             text unknown — or a bundle id: its composer counts too, WeChat / QQ get the rich item and
//                             a voice card over Feishu / Lark no words when Blurt can paste them)
//     voicedrop N PID [taken] [words] as if voice card N was let go of over process PID's window (a stand-in, `droptarget map`),
//                             refused — or taken — by it: the words pasted through the test route, or copied;
//                             `words`: the drop beat the rewrite that takes the words off over Feishu
//     takeout N [CLASS [PID]] as if card N had been dragged out and taken by that kind of app (the safety-net copy, the
//                             toast; no CLASS: not sure which); PID: it landed in that process (a stand-in mapped to a
//                             chat app gets the note pasted in after the picture, through the test route)
//     smartpaste key PID | state | set on|off | notefile on|off   smart paste (Capture/SmartPaste.swift): a ⌘V with
//                             process PID in front (its bundle from `droptarget map`); the armed copy;
//                             record.smart_paste; record.drag_note_file. Each key the sequence would post goes to PID as
//                             a dev.blurt.test.standin notification, never an event
//     followup facts K=V,… | clear   what Accessibility would say after a drop (editable=1|0, selection=N,
//                             window=same|other, secure=1): test builds read no Accessibility (DragNoteFollowUp)
//     droptarget map PID=BUNDLE,… | fixed BUNDLE | clear   stand-in windows (by owner pid) as the apps they stand in
//                             for, when a drag decides what to hand over (CardDrag.swift)
//     taken list|show|hide|rows|expire|menu   used cards (Recently Taken): the captures ("taken" events), the Cards
//                             panel on History, its tiles ("taken_row": n + the picture's rect, global top-left),
//                             housekeeping now, the island's right-click menu as text ("island_menu_dump")
//     taken putback N · taken copy N [click|image|text] · taken drag N PASTEBOARD   a used card's actions
//     taken hover [N]         History's tile of capture N as if pointed at (its wash and actions); no N: none
//     clock SECONDS           move Recently Taken's clock (Snapper.clockOffset) to see 7 days pass
//     cardnote N · cardretry N   what card N says ("card_note": text, mic, status) · = Retry Transcription
//                             (BLURT_TEST_WORDS_FAIL=N: the first N transcriptions fail)
//     hotkey ACTION           as if its keys were pressed (e.g. hotkey cards)
//     island open|close|switcher|frame   open / close the island, ⌥O, or report its frame ("island" event)
//     voice down|up|tap       ⌥V pressed / released (a tap = down + up)
//     voice keys SCRIPT | structure | earclick   key events while it listens ("shift-down@0 shift-up@120": a lone ⇧
//                             toggles Structured) · a click on the island's Structured chip · on its right ear
//     assign N PROJECT|inbox  = dropping card N (with its ⌘-click selection) on that target · aisort · deleteall
//     cardselect N,M…         a ⌘-click selection of those cards (no copy: the clipboard is left alone)
//     cardmove N PROJECT|inbox   card N's menu: Move To ▸ that project (its selection too; "card_move_menu" lists it)
//     pick PROJECT|inbox · pickrows [QUERY] · refile SESSION   the switcher's pick form ("Filed to X · Change"): choose
//                             a row / its rows after typing ("pick_rows") / the line a recording leaves as it ends
//     refilerun start|done|fail SESSION   as if SESSION were being organized: Change only notes it; done = the run's
//                             end (Refile.organized), fail = a failed run (Refile.runEnded)
//     organize (the cards → the current project, one agent run) · enrich UID,… (AI fill-in) · askproject
//     notetype TEXT · notekey esc|return|shift-return|tab · noteheard TEXT (the note bubble) · toastaction [1|2] (the island toast's / question's answer)
//     · islandclick (a click on the toast's line, not its button: opens the island, never runs its action)
//     noteclear · noteink down|move|up X,Y [shift|option] · noteundo · notestall · notestate (the note bubble: ⌘A⌫, the
//                             pen — on the frozen picture in place, else the bubble's —, ⌘Z, a mic gone, what it shows)
//     notechip open|close|type T|down|up|return|pick ID|inbox   the bubble's "Goes to X" chip and its list
//     stage [click]           the in-place markup stage's state; click = a click outside the frozen picture (done)
//     fakerecording ink · recink down|move|up X,Y [shift|option]   the recording pen (its key held) on a fake take
//     recask [off] · recmore  the recording's discard question · the open recording island's ··· menu
//     countdown N X,Y,W,H [hold] | close   the recording's countdown alone over that area (no take; hold: no ticks)
//     recwriterfail · recstreamstop CODE   a real take's writer fails (a new piece takes over) / its stream stops
//                             with ScreenCaptureKit error CODE (restartable ones restart; Capture/Recorder.swift)
//     voice stall (the voice note's mic stops) · quit (= Quit Blurt: applicationShouldTerminate)
//     project ID|inbox        switch the current project (inbox: none — captures go to Unassigned)
//     peck [to_verify|done] TITLE   the done line (Peep) · axcards  the cards' accessibility elements ("ax" event)
//     mascot CLIP [SIZE] | close    Peep playing CLIP alone in a small window ("mascot" event: its window number)
//     mascotframes DIR CLIP [dark]  the clip at 12 fps as PNGs (80 pt, 2x), in order
//     menuicon DIR            renders the menu-bar template offscreen on light and dark menu bars, 1x and 2x
//     dictation keys SCRIPT   synthetic key events into the dictation trigger, at their script times (no event tap,
//                             nothing posted to any app): "ropt-down@0 ropt-up@120" — BlurtCore DictationTrigger.parse
//     dictation polish install|cancel|use ID | state   Settings → Dictation's model rows (open the pane first)
//     dictation toggle|cancel|apply|status · dictation testpad [open|close|text] (our own window with a text view,
//                             focused: the only place a test pastes into) · dictation history [show|raw ID|item ID|delete ID|query Q]
//                             (Capture/Dictation/DictationTestHooks.swift)

import AppKit
import Carbon.HIToolbox
import WebKit
import BlurtCore

var testMenu: NSMenu?

extension App {
    func startSnapMode() {
        switch ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {   // screenshots of both themes in tests
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        snapper.syncCollector()
        guard ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" else { return }
        let channel = ProcessInfo.processInfo.environment["BLURT_TEST_CHANNEL"].map { ".\($0)" } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.command" + channel), object: nil, queue: .main) { [weak self] n in
            guard let cmd = n.userInfo?["cmd"] as? String else { return }
            self?.testCommand(cmd)
        }
    }

    /// "web" / "text" / … or a bundle id (classified as a drag would)
    func testDropClass(_ s: String) -> DropClass { DropClass(legacy: s) ?? DropTargets.classify(bundleID: s) }

    /// A drag over the app a test names: a class (rich chat terminal finder, or the old names) → that class alone; a
    /// bundle id → its class and composer (WeChat / QQ: Qt; Feishu, browsers: web), and for a voice card whether the
    /// words are kept off the drag (as smart paste and Accessibility say now).
    func testLanding(_ s: String, for shot: Shot) -> DragLanding {
        if let c = DropClass(legacy: s) { return DragLanding(cls: c) }
        return DragLanding.of(bundleID: s, kind: DropTargets.composer(bundleID: s, appURL: nil), voice: shot.kind == .voice,
                              canPaste: SmartPaste.enabled && SmartPaste.accessibility)
    }

    func testCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        emit(["event": "test_command", "cmd": cmd])
        switch parts.first ?? "" {
        case "snap": hotkey(.snap)                     // = ⌥A: the snap flow (into the take while recording)
        case "record": startRecording(useLast: true)   // = menu "录制上次的区域" (record.last_region), no picker
        case "snapregion":                              // snapregion x,y,w,h [PNG|-] [quiet] [take]: PNG stands in for the screen
            let a = arg.split(separator: " ").map(String.init)  // (- = the real screen); quiet = no note; take = ⌥A while recording
            if a.count > 1, a[1] != "-", a[1] != "quiet", a[1] != "take" { setenv("BLURT_TEST_STILL", a[1], 1) }
            let p = (a.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { return }
            snapper.rememberFrontApp()
            snapper.capture(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), withNote: !a.contains("quiet"),
                            take: a.contains("take") ? rec : nil)
        case "screentext", "screentranslate":           // screentext x,y,w,h [PNG]: ⌥C (⌥T) without the drag; PNG stands in for the screen
            let a = arg.split(separator: " ").map(String.init)
            if a.count > 1 { setenv("BLURT_TEST_STILL", a[1], 1) }
            let p = (a.first ?? "").split(separator: ",").compactMap { Double($0) }
            let tr = parts.first == "screentranslate"
            // where it would be pasted, as at a key-down: a test build's is the test pad when it is open (`dictation testpad`)
            let target = ScreenTextCopy.target()
            let read = { ScreenTextCopy.shared.read(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), via: "test", translate: tr, target: target) }
            if p.count == 4 { ScreenTextRefine.installed == nil ? ScreenTextRefine.refreshInstalled(read) : read() }
            else { ScreenTextCopy.shared.hotkey(via: "test", translate: tr) }
        case "textcard":                                // textcard TEXT (\n = a line break) | close | state | copy | esc: ⌥T's card
            ScreenTextCard.shared.testCommand(arg)
        case "cards":
            if arg == "show" { hanging.show(peek: 8) }
            if arg == "reveal" { hanging.reveal(via: "test") }      // = the ear's count (⌥H opens the Cards panel)
            if arg == "dismiss" { hanging.dismiss() }               // = Esc
            if arg == "older" || arg == "all" { hanging.openOverview() }   // = a click on the "+N" tile
            if arg.hasPrefix("hover") { hanging.testHover(n: Int(arg.dropFirst(5).trimmingCharacters(in: .whitespaces))) }  // hover N | hover
            hanging.testCommand(arg)                                // row | focus | key K | click N [2] | overview …
            emit(["event": "cards_state", "shown": hanging.isShown, "count": hanging.count, "island_open": island.open])
            emit(["event": "swing", "degrees": hanging.swing.map { Double(($0 * 100).rounded() / 100) }])
            emit(["event": "cards", "captures": snapper.cards.map { "\($0.n)@\(ObjectIdentifier($0).hashValue % 10000)/\(ObjectIdentifier($0.batch!).hashValue % 10000)" }])
            for (s, r) in hanging.cardRects() { emit(["event": "card", "n": s.n, "session": s.batch?.dir.path ?? "", "rect": [r.minX, r.minY, r.width, r.height]]) }
            if let r = NoteBubble.shared.canvasScreenRect { let c = toCG(r); emit(["event": "canvas", "rect": [c.minX, c.minY, c.width, c.height]]) }
        case "island":
            switch arg {
            case "open": island.setOpen(true, sticky: true)
            case "close": island.setOpen(false); island.closeSwitcher()
            case "switcher": island.showSwitcher()
            case "hello": island.hello()                    // the launch hello again (Peep in the ear)
            case "transcribing", "polishing":               // dictation's working ears, held 3 s for a look
                island.testWorkingEars(polishing: arg == "polishing", seconds: 3)
            case let a where a.hasPrefix("peep "):          // peep STATE [SECONDS] | peep off: Peep's ear state held for a look
                let p = a.split(separator: " ").map(String.init)
                island.testPeepEars(PeepState(rawValue: p[1]), seconds: p.count > 2 ? Double(p[2]) ?? 6 : 6)
            case let a where a.hasPrefix("filter "):        // filter TEXT: = typing TEXT into the open switcher
                island.content.query = String(a.dropFirst(7)); island.content.rebuild(); island.wake()
            default: break
            }
            let f = toCG(island.frameOnScreen)
            emit(["event": "island", "rect": [f.minX, f.minY, f.width, f.height], "open": island.open, "cards": hanging.count])
        case "voice" where arg.hasPrefix("set "):         // voice set KEY true|false|NUMBER|-: record.voice.KEY
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 3 else { return }
            var v: Any? = Double(a[2]) ?? a[2]
            if a[2] == "-" { v = nil } else if a[2] == "true" { v = true } else if a[2] == "false" { v = false }
            Config.shared.set("record.voice.\(a[1])", v)
            emit(["event": "voice_test_set", "key": a[1], "value": v.map { "\($0)" } ?? "default"])
        case "voice" where arg == "esc": captureHotkey(.voiceEsc)       // = Esc while it listens (its Carbon hotkey)
        case "voice" where arg == "stall": VoiceInput.shared.testStall()  // its mic stops delivering (a headset gone)
        case "voice" where arg.hasPrefix("keys "):     // voice keys SCRIPT: key events while it listens, as the key
            let t0 = CACurrentMediaTime()                // listener hands them over ("shift-down@0 shift-up@120"; BlurtCore
            for e in DictationTrigger.parse(String(arg.dropFirst(5))) {   // DictationTrigger.parse) — nothing is posted
                var ev = e
                if case let .flags(c, f, t) = e { ev = .flags(keyCode: c, flags: f, time: t0 + t) }
                if case let .keyDown(c, t) = e { ev = .keyDown(keyCode: c, time: t0 + t) }
                if case let .mouseDown(t) = e { ev = .mouseDown(time: t0 + t) }
                Dictation.shared.handle(ev)
            }
            emit(["event": "voice_style_state", "structured": VoiceInput.shared.structured])
        case "voice" where arg == "structure":           // = a click on the island's Structured chip
            VoiceInput.shared.toggleStructured(via: "island")
            emit(["event": "voice_style_state", "structured": VoiceInput.shared.structured])
        case "voice" where arg == "earclick":            // = a click on the right ear (the clock / list mark)
            VoiceInput.shared.toggleStructured(via: "ear")
            emit(["event": "voice_style_state", "structured": VoiceInput.shared.structured])
        case "voice" where arg == "state":
            emit(["event": "voice_state", "active": VoiceInput.shared.active, "holding": VoiceInput.shared.holding,
                  "structured": VoiceInput.shared.structured,
                  "elapsed": VoiceInput.shared.elapsed, "hint": IslandContent.voiceHint(), "live": VoiceInput.shared.liveText ?? NSNull()])
        case "voice":
            if arg != "up" { Hotkeys.shared.simulate(.voice, released: false) }
            if arg == "tap" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Hotkeys.shared.simulate(.voice, released: true) } }
            if arg == "up" { Hotkeys.shared.simulate(.voice, released: true) }
        case "cardcopy":                                // cardcopy N [click|image|text|cmd] | all: = a click / Copy Image /
            let a = arg.split(separator: " ").map(String.init)      // Copy Text / a ⌘-click / Copy All N Cards
            if a.first == "all" {
                if !hanging.copyAll() { emit(["event": "card_copied", "what": "all", "failed": true]) }
            } else if a.count > 1, a[1] == "cmd", let n = Int(a[0]) {
                _ = hanging.testPick(n: n)
                emit(["event": "card_picked", "n": n, "picked": hanging.pickedNumbers])
            } else if let n = Int(a.first ?? "") {
                let ok = hanging.testCopy(n: n, HangingCards.Copy(rawValue: a.count > 1 ? a[1] : "click") ?? .click)
                if !ok { emit(["event": "card_copied", "n": n, "what": a.count > 1 ? a[1] : "click", "failed": true]) }
            }
        case "cardmenu":                                // cardmenu N: the right-click menu's titles
            if let n = Int(arg) { emit(["event": "card_menu", "n": n, "items": hanging.testMenu(n: n)]) }
        case "cardnote":                                // cardnote N: what card N says (text, mic mark, status)
            if let n = Int(arg), let s = snapper.cards.last(where: { $0.n == n }) {        // the newest card N
                let note = s.note
                emit(["event": "card_note", "n": n, "text": note.text ?? NSNull(), "mic": note.showsMic, "status": "\(note.status)",
                      "voice": s.voice ?? NSNull(), "said": s.said ?? NSNull(), "typed": s.text ?? NSNull(),
                      "transcription": s.transcription.rawValue])
            }
        case "cardretry":                               // cardretry N: = "Retry Transcription" in card N's menu
            if let n = Int(arg), let s = snapper.cards.last(where: { $0.n == n }) { snapper.retryWords(s) }
        case "carddrag":                                // carddrag N PASTEBOARD [CLASS|BUNDLE]: what dragging card N out carries
            let a = arg.split(separator: " ").map(String.init)
            if a.count >= 2, let n = Int(a[0]) {
                let shot = snapper.cards.last(where: { $0.n == n })
                let landing = a.count > 2 ? shot.map { testLanding(a[2], for: $0) } ?? DragLanding(cls: testDropClass(a[2])) : DragLanding(cls: .chat)
                let types = hanging.testDrag(n: n, into: landing, to: NSPasteboard(name: .init(a[1])))
                emit(["event": "card_drag", "n": n, "class": landing.cls.rawValue, "kind": landing.kind?.rawValue ?? NSNull(),
                      "words_withheld": landing.wordsWithheld, "types": types])
            }
        case "takeout":                                 // takeout N [CLASS]: as if card N was dragged out and taken
            let a = arg.split(separator: " ").map(String.init)
            if let n = Int(a.first ?? ""), let s = snapper.cards.last(where: { $0.n == n }) {
                // takeout N CLASS PID: it landed in that (stand-in) process — WeChat / QQ then get the note typed in
                let landed = a.count > 2 ? pid_t(a[2]).map { DropProbe.target(pid: $0) } : nil
                let cls = a.count > 1 ? testDropClass(a[1]) : nil
                let card = CardExport.card(s).0
                let md = cls.map { c in CardPasteboard.drag(for: c, card: card, attachNote: CardExport.attachNoteFile)
                    .contains { $0.file != nil && $0.file == card.noteFile } } ?? false
                snapper.takeOut(s, delivered: cls, noteFile: md, landed: landed)
            }
        case "voicedrop":                               // voicedrop N PID [taken] [words]: as if voice card N was let go of over
            let a = arg.split(separator: " ").map(String.init)      // process PID's window (its bundle from `droptarget
            if a.count > 1, let n = Int(a[0]), let pid = pid_t(a[1]),  // map`), refused — or taken — by the app
               let s = snapper.cards.last(where: { $0.n == n }) {
                let t = DropProbe.target(pid: pid)
                let canPaste = SmartPaste.enabled && SmartPaste.accessibility
                // `… words`: the drop landed before the drag's rewrite took the words off (they were still on it)
                let withheld = s.kind == .voice && !a.contains("words")
                    && VoiceCardDrop.withholdsWords(bundleID: t.bundleID, cls: t.cls, kind: t.kind, canPaste: canPaste)
                let at = NSPoint(x: NSScreen.main?.frame.midX ?? 0, y: NSScreen.main?.frame.midY ?? 0)
                snapper.takeOutVoice(s, landed: t, at: at, accepted: a.count > 2 && a[2] == "taken", wordsWithheld: withheld)
            }
        case "droptarget": DropProbe.testCommand(arg)
        case "smartpaste": SmartPaste.shared.testCommand(arg)      // smartpaste key PID | state | set on|off | notefile on|off
        case "followup": DragNoteFollowUp.testCommand(arg)         // followup facts K=V,… | clear
        case "clock":                                   // clock SECONDS: Recently Taken's clock, moved
            Snapper.clockOffset = Double(arg) ?? 0
            emit(["event": "clock", "offset": Snapper.clockOffset])
        case "taken":
            let a = arg.split(separator: " ").map(String.init)
            let find = { (i: Int) -> Shot? in a.count > i ? Int(a[i]).flatMap { n in snapper.recentlyTaken.first { $0.n == n } } : nil }
            switch a.first ?? "list" {
            case "show": TakenPanel.shared.show()
            case "hide": TakenPanel.shared.hide()
            case "hover": CardsOverview.shared.testCommand("hover " + (a.count > 1 ? a[1] : ""))    // hover N: as if pointed at
            case "expire": emit(["event": "taken_expire", "trashed": snapper.expireTaken()])
            case "putback": if let s = find(1) { snapper.putBack(s) }
            case "copy": if let s = find(1) { TakenPanel.copy(s, HangingCards.Copy(rawValue: a.count > 2 ? a[2] : "click") ?? .click) }
            case "drag":                                // taken drag N PASTEBOARD: what dragging it out again carries
                if let s = find(1), a.count > 2 {
                    let pb = NSPasteboard(name: .init(a[2]))
                    let items = CardExport.dragItems(s, into: a.count > 3 ? testLanding(a[3], for: s) : DragLanding(cls: .chat))
                    pb.clearContents()
                    pb.writeObjects(items)
                    emit(["event": "taken_drag_items", "n": s.n, "types": items.map { $0.types.map(\.rawValue) }])
                }
            case "rows":                                // the Used segment's tiles (their pictures, screen rects)
                if TakenPanel.shared.isOpen {
                    for (n, r) in CardsOverview.shared.tileFrames {
                        let f = toCG(r)
                        emit(["event": "taken_row", "n": n, "rect": [f.minX, f.minY, f.width, f.height]])
                    }
                }
            case "menu": emit(["event": "island_menu_dump", "rows": menuDumpLines(TakenPanel.islandMenu())])
            default: break
            }
            emit(["event": "taken", "now": Snapper.now, "captures": snapper.recentlyTaken.map { s -> [String: Any] in
                ["n": s.n, "session": s.batch?.dir.path ?? "", "taken": s.taken ?? 0, "note": s.words ?? NSNull(), "kind": s.kind.rawValue]
            }, "panel": TakenPanel.shared.isOpen])
        case "hotkey":                                  // hotkey ACTION: the same path as pressing its keys
            if let act = HotAction(rawValue: arg) { Hotkeys.shared.simulate(act, released: false) }
        case "assign":                                  // assign N PROJECT: = dropping card N (with its ⌘-click selection) there
            let a = arg.split(separator: " ").map(String.init)
            if a.count == 2, let n = Int(a[0]), let s = snapper.cards.first(where: { $0.n == n }) {
                snapper.assign(hanging.withSelection(s), to: a[1])
            }
        case "cardselect":                              // cardselect N,M…: a ⌘-click selection of those cards, no copy
            hanging.testSelect(arg.split(separator: ",").compactMap { Int($0) })
            emit(["event": "card_picked", "picked": hanging.pickedNumbers])
        case "cardmove":                                // cardmove N PROJECT: card N's menu, Move To ▸ PROJECT (selection too)
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 2, let n = Int(a[0]), let s = snapper.cards.first(where: { $0.n == n }) else { return }
            let m = hanging.cardMenu(s) { _ in }
            let move = m.items.first { $0.submenu != nil }
            emit(["event": "card_move_menu", "title": move?.title ?? "", "items": move?.submenu?.items.map(\.title) ?? []])
            let target = a[1] == "inbox" ? Loc.t("project.inbox") : ProjectStore.shared.project(id: a[1])?.name
            if let i = move?.submenu?.items.first(where: { $0.title == target }) as? ClosureMenuItem { i.fire() }
        case "pick":                                    // pick PROJECT|inbox: choose a row of the island's switcher / pick form
            if let p = island.pick { island.closeSwitcher(); p.choose(arg) }
            else { MissingFolder.use(arg == "inbox" ? nil : arg, via: "test") }
        case "pickrows":                                // pickrows [QUERY]: the switcher's rows as shown, after typing QUERY
            if island.drawer != .switcher { island.showSwitcher() }
            island.content.query = arg
            island.content.rebuild()
            emit(["event": "pick_rows", "rows": island.content.rowTitles, "pick": island.pick?.title ?? NSNull()])
        case "refile":                                  // refile SESSION: the end-of-recording line for that session
            Refile.offerRecording(URL(fileURLWithPath: arg), project: ProjectStore.shared.currentID)
        case "refilerun":                               // refilerun start|done|fail SESSION: as if it were being organized
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard a.count == 2 else { return }
            let dir = URL(fileURLWithPath: a[1])
            switch a[0] {
            case "start": Refile.testRunning.insert(dir.path)
            case "done": Refile.testRunning.remove(dir.path); Refile.organized(dir)
            default: Refile.testRunning.remove(dir.path); Refile.runEnded(dir)
            }
        case "framerec": FrameCapture.start(arg)      // framerec DIR SECS X,Y,W,H [BACKDROP|-] [FPS] [cursor]
        case "mascotframes":                            // mascotframes DIR CLIP [dark]: the clip at 12 fps
            let a = arg.split(separator: " ").map(String.init)
            guard let d = a.first else { return }
            let n = PeckCard.renderFrames(to: URL(fileURLWithPath: d), clip: MascotClip(rawValue: a.count > 1 ? a[1] : "") ?? .done,
                                          dark: a.contains("dark"))
            emit(["event": "mascotframes", "frames": n])
        case "mascot":                                  // mascot CLIP [SIZE] | mascot close: Peep alone in a window
            MascotStage.show(arg)
        case "fakerecording":                           // fakerecording [stop]: the island's recording state without a capture stream
            if arg == "stop" { let r = rec; rec = nil; island.recordingStopping(r); snapper.takeEnded {}; return }
            let r = Recorder(region: CGRect(x: 360, y: 260, width: 900, height: 560))
            rec = r
            r.sessionStart = hostNow()
            opts.out = snapper.openBatch(for: ProjectStore.shared.inbox).dir.deletingLastPathComponent().appendingPathComponent("fake-rec/recording.mp4").path
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: opts.out).deletingLastPathComponent(), withIntermediateDirectories: true)
            r.snaps = RecordingSnaps(rec: r, session: URL(fileURLWithPath: opts.out).deletingLastPathComponent())
            if arg == "ink" {                           // fakerecording ink: with the pen's window and an events.jsonl
                let ev = URL(fileURLWithPath: opts.out).deletingLastPathComponent().appendingPathComponent("events.jsonl")
                FileManager.default.createFile(atPath: ev.path, contents: nil)
                r.events = try? FileHandle(forWritingTo: ev)
                r.makeInk()
                r.snaps = RecordingSnaps(rec: r, session: URL(fileURLWithPath: opts.out).deletingLastPathComponent())
                emit(["event": "fake_ink", "events": ev.path])
            }
            island.recordingStarted(r, on: NSScreen.main)
        case "failtake":                                // failtake STILL.png|- [REASON [VIDEO.mp4]]: a take whose writer
            let a = arg.split(separator: " ").map(String.init)      // failed (REASON: a RecordingFailure raw value), with a
            let t = ProjectStore.shared.captureTarget               // still and its note; "-": no still (the alert, the
                                                                    // folder goes); VIDEO: what it had written
            let dir = newSessionDir(in: t)
            takeProject = t.isInbox ? nil : t
            let shots = dir.appendingPathComponent("shots")
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            if let still = a.first, still != "-" {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: still), to: shots.appendingPathComponent("001.png"))
            }
            try? Data(#"{"n":1,"t":2.0,"file":"shots/001.png","text":"the total is cut off"}"#.utf8 + [10])
                .write(to: dir.appendingPathComponent("shots.jsonl"))
            lastSession = dir
            takeStartedAt = Date(timeIntervalSinceNow: -30)
            var ev: [String: Any] = ["event": "error", "code": "writer", "message": "writer failed (test)"]
            if a.count > 1 { ev["reason"] = a[1] }
            if a.first == "-" { try? FileManager.default.removeItem(at: dir.appendingPathComponent("shots.jsonl")) }
            if a.count > 2 {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: a[2]), to: dir.appendingPathComponent("recording.mp4"))
            }
            takeEnded(5, ev)
        case "recnotch":                                // recnotch on|off: Settings' "Don't record the notch" (a take follows at once)
            setRecordConfig(CaptureExclusion.hideNotchKey, arg == "on" ? true : nil)
            rec?.updateFilter()
            emit(["event": "recnotch", "hide_notch": OwnWindows.hideNotch])
        case "recask": island.confirmDiscard(arg != "off")       // the recording's Discard or Restart…: the question
        case "recmore": DispatchQueue.main.async { island.content.showRecordingMenu() }   // the open recording island's ··· menu
        case "aisort": snapper.handToAI()
        case "organize": snapper.handToAI(project: ProjectStore.shared.organizeTarget)     // the island's "Organize" button
        case "notetype": NoteBubble.shared.testType(arg)                            // typing into the note bubble
        case "notekey": NoteBubble.shared.testKey(arg)                              // notekey esc|return|shift-return|tab: a real key event
        case "noteheard": NoteBubble.shared.testHeard(arg)                          // noteheard TEXT[|PENDING]: the live words while it listens
        case "noteclear": NoteBubble.shared.testClear()                             // ⌘A ⌫ in the note's field
        case "noteclick": NoteBubble.shared.testClickField()                        // a click into the note's field
        case "noteink":                                 // noteink down|move|up X,Y [shift|option]: the pen on the note's
            let a = arg.split(separator: " ")           // picture (0–1): the frozen one in place, else the bubble's
            let xy = (a.count > 1 ? a[1] : "0.5,0.5").split(separator: ",").compactMap { Double($0) }
            var mods: NSEvent.ModifierFlags = []
            if a.contains("shift") { mods.insert(.shift) }
            if a.contains("option") { mods.insert(.option) }
            NoteBubble.shared.testInk(a.first.map(String.init) ?? "down", x: xy.first ?? 0.5, y: xy.count > 1 ? xy[1] : 0.5, mods: mods)
        case "noteundo": NoteBubble.shared.testUndo()                               // ⌘Z in the note bubble
        case "notehover": NoteBubble.shared.testHover(arg != "off")                 // notehover [off]: the pointer on the bubble
        case "notemic": NoteBubble.shared.testMic(arg)                              // notemic busy|gone|off: the mic's states
        case "notewords": NoteBubble.shared.testWords(arg)                          // notewords TEXT: the mic stopped, the final words came in
        case "notechip": NoteBubble.shared.testChip(arg)                            // notechip open|close|type T|down|up|return|pick ID|inbox
        case "stage":                                   // stage [click]: the in-place markup stage; click = outside the picture
            if arg == "click" { InkStage.shared.testClickOutside() }
            emit(["event": "stage_state"].merging(InkStage.shared.testState) { $1 })
        case "recink":                                  // recink down|move|up X,Y [shift|option|control]: the recording pen
            let a = arg.split(separator: " ")
            let xy = (a.count > 1 ? a[1] : "0.5,0.5").split(separator: ",").compactMap { Double($0) }
            rec?.testInk(a.first.map(String.init) ?? "down", x: xy.first ?? 0.5, y: xy.count > 1 ? xy[1] : 0.5,
                         shift: a.contains("shift"), option: a.contains("option"))
        case "pickercancel": picker?.finish(false)      // = Esc in the area picker (snap or record)
        case "pickerlegend": picker?.toggleLegend()     // = ? in the area picker: the key legend back (or away)
        case "countdown":                               // countdown N X,Y,W,H [hold] [of=T] | close: the 3-2-1 over that area
            if arg == "close" { countdownWin?.orderOut(nil); countdownWin = nil; MenuGlyph.shared.countdown = false; return }   // alone (no take); hold:
            let a = arg.split(separator: " ").map(String.init)                             // it stays at N
            let p = (a.count > 1 ? a[1] : "").split(separator: ",").compactMap { Double($0) }
            guard let n = Int(a.first ?? ""), p.count == 4 else { return }
            let of = a.first { $0.hasPrefix("of=") }.flatMap { Int($0.dropFirst(3)) }   // of=T: N's place in a T-second one
            countdown(n, over: CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), hold: a.contains("hold"), of: of) {
                emit(["event": "countdown_done"])
            }
        case "recwriterfail":                           // recwriterfail: the take's video writer fails at the next frame
            rec?.testWriterFailure()                    // (-11800 / -16341, as on 2026-10-26): a new piece takes over
        case "recstreamstop":                           // recstreamstop CODE: the stream stops with ScreenCaptureKit error CODE
            let code = Int(arg) ?? -3821                // (-3821 system stopped → restart; -3817 the user's Stop; -3801 …)
            rec?.streamStopped(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: code))
        case "recflags":                                // recflags ctl,opt,shift,cmd | none | real: what the pen's poll sees
            if arg == "real" { rec?.testFlags = nil } else {
                var f: CGEventFlags = []
                for k in arg.split(separator: ",") {
                    switch k {
                    case "ctl": f.insert(.maskControl)
                    case "opt": f.insert(.maskAlternate)
                    case "shift": f.insert(.maskShift)
                    case "cmd": f.insert(.maskCommand)
                    default: break
                    }
                }
                rec?.testFlags = f
            }
            emit(["event": "rec_pen_state", "on": rec?.inkOn ?? false, "armed": rec?.penArm.armed ?? false])
        case "noteundobtn": NoteBubble.shared.testUndoButton()                      // a click on the in-place undo button
        case "notestall": NoteBubble.shared.testStall()                             // the bubble's mic stops delivering
        case "notestate": emit(["event": "note_state"].merging(NoteBubble.shared.testState) { $1 })
        case "quit": RunLoop.main.perform { NSApp.terminate(nil) }                 // = Quit Blurt (applicationShouldTerminate)
        case "toastaction":                             // toastaction [1|2]: click the island toast's (or question's) answer
            guard let t = island.currentToast else { return }
            island.dismissToast()
            if arg == "2" { t.second?() } else { t.action?() }
        case "locatepick": MissingFolder.testPick = URL(fileURLWithPath: arg)   // locatepick PATH: the next Locate… picks it
        case "islandclick": island.testClickToastLine()   // a click on the toast's line (not its button), as mouseDown sends it
        case "askproject": Housekeeping.askAboutCarriedOverProject()
        case "enrich":                                  // enrich UID,UID…: "AI fill-in" for those items
            enrich(arg.split(separator: ",").map(String.init), project: ProjectStore.shared.currentID)
        case "deleteall": snapper.deleteAllCards()
        case "project":
            Task { try? await ProjectStore.shared.use(["inbox", "none", "auto"].contains(arg) ? nil : arg); await MainActor.run { island.projectChanged() } }
        case "commit": NoteBubble.shared.commit()
        case "cancel": NoteBubble.shared.cancel()
        case "edit":
            if let s = arg == "last" ? snapper.cards.last : Int(arg).flatMap({ n in snapper.cards.first(where: { $0.n == n }) }) {
                NoteBubble.shared.begin(s, mode: .edit)                             // edit N | edit last
            }
        case "peck":
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let state = ["to_verify", "done"].contains(a.first ?? "") ? a[0] : "to_verify"
            let title = a.count > 1 || !["to_verify", "done"].contains(a.first ?? "") ? (a.last ?? "") : "Login button does nothing"
            PeckCard.shared.play(title: title, detail: "", uid: "test", state: state)
        case "notes": island.openRecordingNotes()
        case "recsnap": island.snapWithNote()                                      // the recording island's snap button
        case "shortcuts": HotkeySettings.shared.show()
        case "raise", "lower":                          // the main window above everything for a screenshot, and back
            if let w = MainWindowController.shared.window {
                w.level = parts[0] == "raise" ? .floating : .normal
                if parts[0] == "raise" { w.orderFrontRegardless() }
            }
            if parts[0] == "raise" { HotkeySettings.shared.shortcutsWindow?.orderFrontRegardless() }
        case "js":                                      // js CODE: run in the main window's review canvas
            MainWindowController.shared.detail.web?.evaluateJavaScript(arg) { r, e in emit(["event": "js", "result": "\(r ?? e ?? "")"]) }
        case "webjs":                                   // webjs CODE: run in every blurt-app:// canvas (main window detail)
            func webViews(_ v: NSView) -> [WKWebView] { (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webViews) }
            for w in NSApp.windows { for wv in webViews(w.contentView ?? NSView()) where wv.url?.scheme == "blurt-app" {
                wv.evaluateJavaScript(arg) { r, e in emit(["event": "webjs", "window": w.windowNumber, "result": "\(r ?? e ?? "")"]) }
            } }
        case "recordkey":                               // recordkey ACTION: click that recorder field
            HotkeySettings.shared.show()
            if let a = HotAction(rawValue: arg) { HotkeySettings.shared.fields[a]?.start() }
        case "presskey", "rkey":                        // presskey SPEC|esc|delete: a real key event through the app's queue,
                                                        // to the Shortcuts window (presskey) or the main window (rkey)
            guard let w = parts[0] == "rkey" ? MainWindowController.shared.window : HotkeySettings.shared.shortcutsWindow else { return }
            if parts[0] == "rkey" {                     // key equivalents need us active with that window key
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
            var code = 0, flags: NSEvent.ModifierFlags = []
            var chars = ""
            if arg == "esc" { code = 53 } else if arg == "delete" { code = 51 }
            else if let s = Shortcut.parse(arg) {
                code = s.code
                if s.key.count == 1 { chars = s.key.lowercased() }
                if s.mods & controlKey != 0 { flags.insert(.control) }
                if s.mods & optionKey != 0 { flags.insert(.option) }
                if s.mods & shiftKey != 0 { flags.insert(.shift) }
                if s.mods & cmdKey != 0 { flags.insert(.command) }
            } else if let s = hotkeyKeyTable.first(where: { $0.name == arg.uppercased() }) { code = s.code }   // no modifiers: refused
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: UInt16(code)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (parts[0] == "rkey" ? 0.6 : 0)) { NSApp.postEvent(e, atStart: false) }
            }
        case "checkupdates":                            // [probe]: = menu "Check for Updates…"; probe = no UI, emits update_probe
            emit(["event": "updater", "available": Updater.shared.available, "can_check": Updater.shared.canCheck])
            if arg == "probe" { Updater.shared.probe() } else if arg == "silent" { Updater.shared.silentUpdate() } else { Updater.shared.checkForUpdates(nil) }
        case "sethotkey":                             // sethotkey ACTION SPEC|off: HotkeyCenter.set, emits the result
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard a.count == 2, let act = HotAction(rawValue: a[0]) else { return }
            let r = Hotkeys.shared.set(Shortcut.isOff(a[1]) ? nil : Shortcut.parse(a[1]), for: act)
            emit(["event": "sethotkey", "action": act.rawValue, "keys": Hotkeys.shared.binding(act)?.spec ?? "off", "result": "\(r)"])
        case "hotkeys":                                 // dump the state, for scripted checks
            emit(["event": "hotkeys", "keys": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, Hotkeys.shared.shortcut($0)?.spec ?? "off") }),
                  "states": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, Hotkeys.shared.states[$0].map { "\($0)" } ?? "") })])
        case "menu":                                    // menu: the ⌥B menu, popped up
            let t = NSMenu()
            menuNeedsUpdate(t)
            emit(["event": "menu", "items": t.items.count])
            testMenu = t
            // not from a GCD block: menu tracking would hold the main queue.
            // Distributed notifications don't arrive while a menu tracks, so it closes itself after 8 s.
            let close = Timer(timeInterval: 8, repeats: false) { _ in t.cancelTracking() }
            RunLoop.main.add(close, forMode: .common)
            RunLoop.main.perform { t.popUp(positioning: nil, at: NSPoint(x: 900, y: 900), in: nil) }
        case "menudump":                                // menudump [FILE]: the ⌥B menu's rows as text, without opening it
            let m = NSMenu()
            menuNeedsUpdate(m)
            let lines = menuDumpLines(m)
            if !arg.isEmpty { try? (lines.joined(separator: "\n") + "\n").write(toFile: arg, atomically: true, encoding: .utf8) }
            emit(["event": "menu_dump", "lines": lines])
        case "closemenu": testMenu?.cancelTracking()
        case "review":                                  // review DIR: the batch in the main window
            AppEnvironment.mainWindow?.reveal(session: URL(fileURLWithPath: arg))
        case "processdir":                              // processdir [AGENT ]DIR
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if a.count == 2, AgentHub.shared.def(a[0]) != nil { process(URL(fileURLWithPath: a[1]), only: a[0]) } else { process(URL(fileURLWithPath: arg)) }
        case "toast": toast(arg.replacingOccurrences(of: "\\n", with: "\n"))
        case "islandtoast":                             // islandtoast KEY|ACTION|ICON|passive|TEXT ("-" = none): one island toast
            let a = arg.components(separatedBy: "|")
            guard a.count >= 5 else { return }
            func v(_ i: Int) -> String? { a[i] == "-" || a[i].isEmpty ? nil : a[i] }
            var t = Island.Toast(text: a[4...].joined(separator: "|").replacingOccurrences(of: "\\n", with: "\n"), actionTitle: v(1), action: v(1).map { title in
                { emit(["event": "island_toast_action", "title": title]) }
            })
            t.key = v(0)
            t.icon = v(2).flatMap(BlurtIcon.init(rawValue:))
            t.passive = a[3] == "passive"
            island.toast(t)
        case "islandsent": island.dictationSent()      // the ear's "Sent" moment after a double tap
        case "islandnews": island.announceInbox(Int(arg) ?? 3)   // islandnews N: "+N" in the ear, as when N captures land
        case "toaststate":                              // what the island says now, and what waits
            emit(["event": "toast_state", "current": island.currentToast?.text ?? NSNull(), "waiting": island.waitingToasts])
        case "axcards":
            let els = hanging.accessibilityElements().map { e -> [String: Any] in
                let r = toCG(e.accessibilityFrame())
                return ["role": e.accessibilityRole()?.rawValue ?? "", "label": e.accessibilityLabel() ?? "",
                        "help": e.accessibilityHelp() ?? "", "actions": (e.accessibilityCustomActions() ?? []).map(\.name),
                        "rect": [r.minX, r.minY, r.width, r.height].map { ($0 * 10).rounded() / 10 }]
            }
            emit(["event": "ax", "elements": els])
        case "dictation": dictationCommand(arg)
        case "live": LiveTranscript.shared.testCommand(arg)          // live state | caret X,Y,W,H | caret - | set on|off
        case "perm": permCommand(arg)                  // the permission guide (Onboarding/PermissionTestHooks.swift)
        case "menuicon":
            let dir = URL(fileURLWithPath: arg.isEmpty ? NSTemporaryDirectory() : arg)
            emit(["event": "menuicon", "files": renderMenuIconPreviews(into: dir).map(\.path)])
        default: command(cmd)
        }
    }

    /// ⌥V (voice note), ⌥O (the project switcher), Esc while listening — K7.
    func captureHotkey(_ k: HK) {
        switch k {
        case .voice:
            VoiceInput.shared.pressed()
            Dictation.shared.nudge("voice_key")     // reaching for the voice: if dictation can't hear its key, say so (≈ daily)
        case .voiceEsc: if VoiceInput.shared.escCancels { VoiceInput.shared.cancel() }     // (held only while it cancels)
        case .dictationEsc: Dictation.shared.escFromHotkey()
        case .project: if resident { island.toggleSwitcher() }
        // ⌥H: the Cards panel with the keyboard — Hanging, or Used when nothing hangs; open already, it closes
        case .cards: if resident { CardsOverview.shared.toggle(via: "hotkey") }
        case .reformat: if resident { Dictation.shared.reformatLast(via: "hotkey") }      // ⌥L (dictation-styles.md)
        case .text: if resident { ScreenTextCopy.shared.hotkey(via: "hotkey") }           // ⌥C (ScreenTextCopy.swift)
        case .translateText: if resident { ScreenTextCopy.shared.hotkey(via: "hotkey", translate: true) }    // ⌥T
        case .translateEsc: ScreenTextCard.shared.close(why: "esc")                      // Esc while ⌥T's card shows
        // Esc while the cards are down on purpose (the voice note's own Esc wins while it still cancels)
        case .cardsEsc: if VoiceInput.shared.escCancels { VoiceInput.shared.cancel() } else { hanging.dismiss() }
        case .overviewEsc: CardsOverview.shared.escape()        // Esc while the pointer is on the Cards panel
        default: break
        }
    }

    func addSnapMenuItems(_ menu: NSMenu, recording: Bool) {
        @discardableResult
        func item(_ key: String, _ sel: Selector, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: Loc.t(key, table: "Capture"), action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
            return it
        }
        if recording {
            menu.addItem(.separator())
            item("capture.menu.snap", #selector(mSnap)).showHotkey(.snap)
            item("capture.menu.live_caption", #selector(mLiveCaption), on: liveCaptionOn)
            return
        }
        item("capture.menu.snap", #selector(mSnap)).showHotkey(.snap)
        item("capture.menu.text", #selector(mText)).showHotkey(.text)
        item("capture.menu.translate", #selector(mTranslate)).showHotkey(.translateText)
        item("capture.menu.voice", #selector(mVoice)).showHotkey(.voice)
    }

    /// The menu's "what waits for you" rows after Open Blurt: Show Cards (⌥H's row: the Cards panel) while a card
    /// hangs or one was used in the last 7 days, Dictation History. Counts are the rows' badges (macOS 14+), never part
    /// of their titles.
    func addWaitingMenuItems(_ menu: NSMenu) {
        if hanging.count > 0 || !snapper.recentlyTaken.isEmpty {
            let cards: NSMenuItem
            if #available(macOS 14.0, *) {
                cards = NSMenuItem(title: T("app.menu.cards"), action: #selector(mShowCards), keyEquivalent: "")
                if hanging.count > 0 { cards.badge = NSMenuItemBadge(count: hanging.count) }
            } else {
                cards = NSMenuItem(title: hanging.count > 0 ? Loc.plural("capture.menu.show_cards", table: "Capture", count: hanging.count)
                                                            : T("app.menu.cards"),
                                   action: #selector(mShowCards), keyEquivalent: "")
            }
            cards.target = self
            cards.showHotkey(.cards)
            menu.addItem(cards)
        }
        let dict = NSMenuItem(title: Loc.t("dictation.menu.history", table: "Dictation"), action: #selector(mDictationHistory), keyEquivalent: "")
        dict.target = self
        if Dictation.enabled { dict.toolTip = Loc.t("dictation.menu.history.tip", table: "Dictation", Dictation.keyInline) }
        menu.addItem(dict)
    }


    @objc func mSnap() {
        if let r = rec { r.snap(via: "menu"); return }
        // the menu is still closing: let it go before the picker takes the screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() }
    }
    @objc func mTranslate() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ScreenTextCopy.shared.hotkey(via: "menu", translate: true) } }
    @objc func mText() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ScreenTextCopy.shared.hotkey(via: "menu") } }
    @objc func mVoice() { VoiceInput.shared.toggle() }
    @objc func mDictationHistory() { MainActor.assumeIsolated { DictationHistoryWindow.shared.show() } }
    @objc func mSwitchProject() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { island.showSwitcher() } }
    /// "Show Cards" (⌥H's row): the Cards panel, as ⌥H opens it.
    @objc func mShowCards() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if !CardsOverview.shared.isOpen { CardsOverview.shared.toggle(via: "menu") } } }
    @objc func mLiveCaption() { setRecordConfig("live_caption", !liveCaptionOn) }
}

/// A menu as text for scripted checks: one row per item, submenus indented, separators as "—", the key equivalent
/// after a tab, "[on]" for an on state, "(dimmed)" when it has no action, "⌥ alt:" for an Option-key alternate and
/// " >" after a row with a submenu.
func menuDumpLines(_ menu: NSMenu, depth: Int = 0) -> [String] {
    var out: [String] = []
    let pad = String(repeating: "    ", count: depth)
    for it in menu.items {
        if it.isSeparatorItem { out.append(pad + "—"); continue }
        var key = ""
        if !it.keyEquivalent.isEmpty {
            let f = it.keyEquivalentModifierMask
            key = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
                + (f.contains(.command) ? "⌘" : "") + it.keyEquivalent.uppercased()
        }
        var title = it.attributedTitle?.string ?? it.title
        if #available(macOS 14.0, *) {
            if it.isSectionHeader { out.append(pad + "## " + title); continue }
            if let b = it.badge { title += "  [" + ((b.stringValue ?? "").isEmpty ? "\(b.itemCount)" : b.stringValue ?? "") + "]" }
        }
        if #available(macOS 14.4, *), let s = it.subtitle, !s.isEmpty { title += "  / " + s }
        var row = pad + (it.isAlternate ? "⌥ alt: " : "") + (it.state == .on ? "[on] " : "") + title
        if it.indentationLevel > 0 { row = pad + String(repeating: "  ", count: it.indentationLevel) + row.dropFirst(pad.count) }
        if !key.isEmpty { row += "\t" + key }
        if it.action == nil && it.submenu == nil { row += "  (dimmed)" }
        if let s = it.submenu { row += "  >"; out.append(row); out += menuDumpLines(s, depth: depth + 1) } else { out.append(row) }
    }
    return out
}

/// The menu-bar icon as macOS would show it, without capturing the real menu bar: the template image tinted like a
/// status item (black 85 % on a light bar, white on a dark one) on a 24 pt strip, next to an SF Symbol for scale.
func renderMenuIconPreviews(into dir: URL) -> [URL] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let icon = App.makeMenuIcon()
    let ref = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    var out: [URL] = []
    for (theme, bar, ink) in [("light", NSColor(white: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85)),
                              ("dark", NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1), NSColor.white)] {
        for scale in [1, 2] {
            let size = NSSize(width: 96, height: 24)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let g = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            g.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))   // the context is in pixels
            bar.setFill()
            NSRect(origin: .zero, size: size).fill()
            func tinted(_ im: NSImage, in r: NSRect) {
                let t = NSImage(size: r.size, flipped: false) { b in
                    im.draw(in: b)
                    ink.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                t.draw(in: r)
            }
            tinted(icon, in: NSRect(x: 14, y: 3, width: 18, height: 18))
            if let w = ref { tinted(w, in: NSRect(x: 56, y: (24 - w.size.height) / 2, width: w.size.width, height: w.size.height)) }
            NSGraphicsContext.restoreGraphicsState()
            let u = dir.appendingPathComponent("menuicon-\(theme)@\(scale)x.png")
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: u); out.append(u) }
        }
    }
    return out
}

/// Test-only stage for the mascot: one small window with a MascotView, so scripts can screen-record just that window.
enum MascotStage {
    static var window: NSWindow?

    static func show(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        window?.orderOut(nil)
        window = nil
        guard let name = a.first, name != "close", let clip = MascotClip(rawValue: name) else { return }
        let size = CGFloat(a.count > 1 ? Double(a[1]) ?? 120 : 120)
        let pad: CGFloat = 16
        let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: size + 2 * pad, height: size + 2 * pad),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .floating
        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.material = .windowBackground
        bg.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(bg)
        let v = MascotView(size: size)
        v.frame.origin = NSPoint(x: pad, y: pad)
        w.contentView?.addSubview(v)
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            v.play(clip)
            emit(["event": "mascot", "clip": clip.rawValue, "window": w.windowNumber,
                  "duration": MascotLibrary.shared.clip(clip)?.duration ?? 0])
        }
    }
}
