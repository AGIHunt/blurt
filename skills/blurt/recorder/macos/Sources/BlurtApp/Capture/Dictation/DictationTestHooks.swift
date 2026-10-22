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
        case "cancel": d.cancel()
        case "apply":
            d.apply()
            d.refreshPolishModel { emit(["event": "dictation_polish_model", "model": d.polishModel ?? NSNull()]) }
        case "status":
            emit(["event": "dictation_status", "phase": d.phase.rawValue, "tap": d.tapInstalled, "test_mode": DictationInsert.testMode, "polish_model": d.polishModel ?? NSNull(),
                  "input_monitoring": DictationKeys.allowed, "accessibility": AXIsProcessTrusted(),
                  "history": DictationHistory.shared.load().count, "last": d.lastResult ?? NSNull()])
        case "testpad": DictationTestPad.command(rest)
        case "settings-scroll": NotificationCenter.default.post(name: DictationPane.scrollRequest, object: rest)
        case "polish": NotificationCenter.default.post(name: DictationPane.polishRequest, object: rest)
        case "history":
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init)
            MainActor.assumeIsolated {
                switch a.first ?? "show" {
                case "raw": DictationHistoryWindow.shared.toggleRaw(a.count > 1 ? a[1] : nil)
                case "item": DictationHistoryWindow.shared.makeItem(a.count > 1 ? a[1] : nil)
                case "query": DictationHistoryWindow.shared.setQuery(a.count > 1 ? a[1] : "")
                case "delete": DictationHistoryWindow.shared.delete(a.count > 1 ? a[1] : nil)
                case "select": DictationHistoryWindow.shared.testSelect((a.count > 1 ? a[1] : "").split(separator: ",").map(String.init))
                case "key": DictationHistoryWindow.shared.testKey(a.count > 1 ? a[1] : "")       // delete | cmd+c | cmd+z | cmd+f | esc
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
