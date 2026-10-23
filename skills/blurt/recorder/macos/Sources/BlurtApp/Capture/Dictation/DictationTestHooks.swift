// Dictation's test hooks (BLURT_TEST_COMMANDS=1, the `dictation …` command of SnapApp.swift's channel). Nothing here
// posts an event to any app: the key script goes straight into DictationTrigger (the path the event tap feeds), and
// the only text view a test pastes into is the test pad — a window of this app, focused by it.
import AppKit
import BlurtCore

extension App {
    func dictationCommand(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let d = Dictation.shared
        switch parts.first ?? "" {
        case "keys":
            // each event at its scripted time from now, through the same path the event tap uses
            let base = CACurrentMediaTime()
            for e in DictationTrigger.parse(rest) {
                let (t, shifted): (Double, DictationTrigger.Event) = {
                    switch e {
                    case let .flags(c, f, t): return (t, .flags(keyCode: c, flags: f, time: base + t))
                    case let .keyDown(c, t): return (t, .keyDown(keyCode: c, time: base + t))
                    case let .mouseDown(t): return (t, .mouseDown(time: base + t))
                    case let .tick(t): return (t, .tick(time: base + t))
                    }
                }()
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { d.handle(shifted) }
            }
        case "toggle": d.toggle()
        case "set":                 // set KEY true|false|NUMBER|-: record.dictation.KEY (- = unset)
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard a.count == 2 else { return }
            var v: Any? = a[1]
            if a[1] == "-" { v = nil } else if a[1] == "true" { v = true } else if a[1] == "false" { v = false } else if let n = Double(a[1]) { v = n }
            Dictation.set(a[0], v)
            emit(["event": "dictation_test_set", "key": a[0], "value": v.map { "\($0)" } ?? "default"])
        case "stop-after":          // stop-after SECONDS: the next dictation stops (as the key-up would) at that point of the wav
            d.testStopAfter = Double(rest)
            emit(["event": "dictation_test_stop_after", "seconds": d.testStopAfter ?? NSNull()])
        case "wav":                 // wav PATH: the "microphone" for the next dictations (a file, never the real mic)
            d.testWav = rest.isEmpty ? nil : rest
            emit(["event": "dictation_test_wav", "wav": d.testWav ?? NSNull()])
        case "paste-policy":
            // paste-policy front=other|self|none secure=0|1 ax=0|1 text=yes|no|unknown: what DictationInsert would do
            var kv: [String: String] = [:]
            for p in rest.split(separator: " ") { let a = p.split(separator: "=", maxSplits: 1).map(String.init); if a.count == 2 { kv[a[0]] = a[1] } }
            let decision = DictationPastePolicy.decide(.init(
                hasFrontApp: kv["front"] != "none", frontIsBlurt: kv["front"] == "self", secureInput: kv["secure"] == "1",
                accessibility: kv["ax"] != "0", focusIsText: kv["text"] == "yes" ? true : kv["text"] == "no" ? false : nil))
            emit(["event": "dictation_paste_policy", "decision": "\(decision)"])
        case "cancel": d.cancel()
        case "apply":
            d.apply()
            d.refreshPolishModel { emit(["event": "dictation_polish_model", "model": d.polishModel ?? NSNull()]) }
        case "tap":
            // tap ok|failed: what a (simulated) tapCreate answers from now on; `apply` / the poll ask it.
            // tap disable [stuck]: the system turned the tap off (stuck: enabling it again doesn't hold → a new one)
            if rest.hasPrefix("disable") {
                DictationKeys.testTapReenables = !rest.hasSuffix("stuck")
                d.testTapDisabled()
            } else {
                DictationKeys.testTap = rest.isEmpty ? nil : rest
            }
            emit(["event": "dictation_test_tap", "tap": DictationKeys.testTap ?? NSNull()])
        case "filter":
            // filter ok|failed: what an active (Fn filter) tapCreate answers; filter-event CODE below: what it does
            DictationKeys.testFilterTap = rest.isEmpty ? nil : rest
            emit(["event": "dictation_test_filter", "filter": DictationKeys.testFilterTap ?? NSNull()])
        case "filter-event":
            // filter-event CODE: a flagsChanged of key CODE reaching the filter — dropped (kept from macOS) or passed
            let code = Int(rest) ?? 63
            emit(["event": "dictation_filter_event", "key_code": code, "dropped": d.testFilterDecision(code),
                  "filter": d.fnFiltering, "swallowed": d.fnSwallowed])
        case "im", "ax":            // im on|off, ax on|off: Input Monitoring / Accessibility as macOS would report them
            let on: Bool? = rest == "on" ? true : rest == "off" ? false : nil
            if parts[0] == "im" { DictationKeys.testInputMonitoring = on } else { DictationKeys.testAccessibility = on }
            emit(["event": "dictation_test_access", "which": parts[0], "on": on ?? NSNull()])
        case "activate": d.testRefreshListener("activate")       // what NSApplication.didBecomeActive does
        case "heard":
            // heard CODE other|self: a press and release as the listener reports them (the tap's flagsChanged path),
            // with another app in front or Blurt — what "last key heard from another app" is made of
            let a = rest.split(separator: " ").map(String.init)
            d.testHeard(keyCode: Int(a.first ?? "61") ?? 61, otherApp: (a.count > 1 ? a[1] : "other") == "other")
        case "nudge": d.nudge(rest.isEmpty ? "test" : rest)     // the island's reminder, through its once-a-day rule
        case "setup": d.openSetup()                             // what "Turn On Dictation…" does
        case "status":
            emit(["event": "dictation_status", "phase": d.phase.rawValue, "tap": d.tapInstalled, "test_mode": DictationInsert.testMode, "polish_model": d.polishModel ?? NSNull(),
                  "needs_setup": d.needsSetup, "key": Dictation.key.rawValue, "asked_version": Config.shared["app.dictation_asked_version"] ?? NSNull(),
                  "nudged_at": Config.shared["app.dictation_nudged_at"] ?? NSNull(), "prompted_flag": Config.shared["app.dictation_prompted"] ?? NSNull(),
                  "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility,
                  "listener": d.listenerKind.rawValue, "tap_generation": d.tapGeneration, "mode": Dictation.mode.rawValue,
                  "filter": d.fnFiltering, "swallowed": d.fnSwallowed,
                  "last_other_app": d.lastKeyFromOtherApp.map { $0.timeIntervalSince1970 } ?? NSNull(),
                  "history": DictationHistory.shared.load().count, "last": d.lastResult ?? NSNull()])
        case "testpad": DictationTestPad.command(rest)
        case "vocab":
            // vocab add TERM[|SOUNDS,…] | remove TERM | accept TERM | reject TERM | list — the store Settings edits
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = a.count > 1 ? a[1] : ""
            let v = DictationVocabulary.shared
            switch a.first ?? "list" {
            case "add":
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                v.add(p.first ?? "", soundsLike: p.count > 1 ? p[1].split(separator: ",").map(String.init) : [])
            case "remove": v.remove(arg)
            case "accept": v.accept(arg)
            case "reject": v.reject(arg)
            case "seed": d.seedVocabulary()
            default: break
            }
            let all = v.load()
            emit(["event": "dictation_vocab_list", "active": all.filter { $0.state == .active }.map { "\($0.term)|\($0.source.rawValue)|\($0.soundsLike.joined(separator: ","))|\($0.hits)" },
                  "suggestions": all.filter { $0.state == .suggested }.map { "\($0.term)|\($0.soundsLike.joined(separator: ","))|\($0.seen)" },
                  "other": all.filter { $0.state == .rejected || $0.state == .removed }.map { "\($0.term)|\($0.state.rawValue)" }])
        case "watch":
            // watch seconds N | status: the after-typing watch (DictationWatch) — its length, and whether it runs
            let a = rest.split(separator: " ").map(String.init)
            if a.first == "seconds", a.count > 1, let n = Double(a[1]) { DictationWatch.seconds = n }
            emit(["event": "dictation_watch_status", "watching": DictationWatch.shared.watching, "seconds": DictationWatch.seconds])
        case "context":             // what the start of a dictation would read now (counts only, never the text)
            let c = DictationContext.capture()
            emit(["event": "dictation_context_probe", "found": c != nil, "before": c?.before.count ?? 0, "after": c?.after.count ?? 0,
                  "selection": c?.selection.count ?? 0, "title": c?.title ?? NSNull(), "app": c?.app ?? NSNull()])
        case "settings-scroll": NotificationCenter.default.post(name: DictationPane.scrollRequest, object: rest)
        case "polish": NotificationCenter.default.post(name: DictationPane.polishRequest, object: rest)
        case "history":
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init)
            MainActor.assumeIsolated {
                switch a.first ?? "show" {
                // the history is a page of the main window (MainWindow/DictationPage.swift); these drive it
                case "raw": DictationHistoryWindow.shared.toggleRaw(a.count > 1 ? a[1] : nil)
                case "mode": DictationHistoryWindow.shared.setMode(a.count > 1 ? a[1] : "polished")   // polished | raw | compare
                case "item": DictationHistoryWindow.shared.makeItem(a.count > 1 ? a[1] : nil)
                case "query": DictationHistoryWindow.shared.setQuery(a.count > 1 ? a[1] : "")
                case "delete": DictationHistoryWindow.shared.delete(a.count > 1 ? a[1] : nil)
                case "select": DictationHistoryWindow.shared.testSelect((a.count > 1 ? a[1] : "").split(separator: ",").map(String.init))
                case "key": DictationHistoryWindow.shared.testKey(a.count > 1 ? a[1] : "")       // delete | cmd+c | cmd+z | cmd+f | esc | up | down
                default: DictationHistoryWindow.shared.show()
                }
            }
        default: break
        }
    }
}

/// Tests only: a plain window of ours with a text view that has the focus — what a dictation pastes into in a test
/// (never another app). `dictation testpad text` reports what it holds ("dictation_testpad" event).
enum DictationTestPad {
    static var window: NSWindow?
    static var textView: NSTextView?
    static var pasteboardBefore = ""

    /// The clipboard's types and a hash of its data — enough to tell it came back unchanged, without its content.
    static func pasteboardSignature() -> String {
        let s = DictationInsert.Saved.take()
        var h = Hasher()
        for item in s.items { for (t, d) in item { h.combine(t.rawValue); h.combine(d) } }
        return "\(s.items.count):\(h.finalize())"
    }

    static func command(_ arg: String) {
        // set TEXT: the pad holds TEXT with the cursor at its end (a document to dictate into: the context);
        // replace FROM => TO: the user's own edit after a dictation (the first FROM after the cursor's line start)
        if arg.hasPrefix("set "), let tv = textView {
            tv.string = String(arg.dropFirst(4)).replacingOccurrences(of: "\\n", with: "\n")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            return emit(["event": "dictation_testpad", "set": (tv.string as NSString).length])
        }
        if arg.hasPrefix("replace "), let tv = textView {
            let p = String(arg.dropFirst(8)).components(separatedBy: " => ")
            guard p.count == 2 else { return }
            let r = (tv.string as NSString).range(of: p[0], options: .backwards)
            if r.location != NSNotFound, tv.shouldChangeText(in: r, replacementString: p[1]) {
                tv.replaceCharacters(in: r, with: p[1])
                tv.didChangeText()
            }
            return emit(["event": "dictation_testpad", "replaced": r.location != NSNotFound, "text": tv.string])
        }
        switch arg {
        case "close":
            window?.orderOut(nil)
            window = nil
        case "text":
            emit(["event": "dictation_testpad", "text": textView?.string ?? NSNull(), "window": window?.windowNumber ?? -1,
                  "key": window?.isKeyWindow ?? false, "pasteboard_restored": pasteboardSignature() == pasteboardBefore])
        default:
            if window == nil {
                let w = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 560, height: 300),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                w.title = "Dictation test pad"
                w.isReleasedWhenClosed = false
                if let a = ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] { w.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
                let scroll = NSTextView.scrollableTextView()
                scroll.frame = w.contentView!.bounds
                scroll.autoresizingMask = [.width, .height]
                let tv = scroll.documentView as! NSTextView    // swiftlint:disable:this force_cast
                tv.font = .systemFont(ofSize: 15)
                tv.textContainerInset = NSSize(width: 10, height: 10)
                tv.isRichText = false
                w.contentView?.addSubview(scroll)
                window = w
                textView = tv
            }
            window?.orderFrontRegardless()      // shown, not activated: the user's front app keeps the focus
            if let tv = textView { window?.makeFirstResponder(tv) }
            pasteboardBefore = pasteboardSignature()     // the user's clipboard is never shown, only compared
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                emit(["event": "dictation_testpad", "window": window?.windowNumber ?? -1, "key": window?.isKeyWindow ?? false,
                      "front": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier])
            }
        }
    }
}
