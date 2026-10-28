// What dictation reads from the text field it types into (docs/design/dictation.md §Context, §Auto-learn), read-only:
//   • at the start: ≈ 500 characters before and after the cursor, the selection, the window title and the app's name.
//     They go to polish as spelling hints; the history keeps them only with record.dictation.keep_audio (on unless
//     turned off), for the Lab and feedback reports;
//   • after the text is typed: the same field, every 1.5 s for 60 s, to see whether the user fixed a word. Only a few
//     dozen characters around the typed text are held while it is watched, then dropped; what is learned is the
//     word pair (DictationLearn → DictationVocabulary), never the text around it — once, when the watch ends (its
//     minute, the focus or the text moving away), from what was typed to what the field says then: never a state in
//     the middle of an edit.
// Password fields (AXSecureTextField, or secure input on) are skipped entirely. Accessibility is needed (it is for
// pasting anyway). Test builds never read another app: their field is the test pad, a window of this app.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import BlurtCore

/// A text field dictation types into: another app's, through Accessibility, or the test pad's text view.
final class DictationField {
    private let element: AXUIElement?
    private weak var textView: NSTextView?
    let app: String?
    let pid: pid_t?

    private init(element: AXUIElement?, textView: NSTextView?, app: String?, pid: pid_t?) {
        self.element = element; self.textView = textView; self.app = app; self.pid = pid
    }

    /// One of our own text views (a paste's landing check reads it).
    static func of(_ tv: NSTextView) -> DictationField {
        DictationField(element: nil, textView: tv, app: "Blurt", pid: ProcessInfo.processInfo.processIdentifier)
    }

    /// The field with the keyboard focus now, or nil (none, no Accessibility, a password field, an element without
    /// readable text). Test builds: the test pad, only when it is open.
    static func focused() -> DictationField? {
        if DictationInsert.testMode {
            guard let tv = DictationTestPad.textView else { return nil }
            return DictationField(element: nil, textView: tv, app: "Blurt", pid: ProcessInfo.processInfo.processIdentifier)
        }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let r = ref,
              CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        let el = r as! AXUIElement   // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(el, 0.25)
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let role = string(el, kAXRoleAttribute), sub = string(el, kAXSubroleAttribute)
        if role == "AXSecureTextField" || sub == "AXSecureTextField" { return nil }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
        return DictationField(element: el, textView: nil, app: app, pid: pid)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
    }

    /// The whole value and the selection (UTF-16), or nil when the field doesn't expose them.
    func read() -> (text: String, selection: NSRange)? {
        if let tv = textView { return (tv.string, tv.selectedRange()) }
        guard let el = element else { return nil }
        guard let text = DictationField.string(el, kAXValueAttribute) else { return nil }
        var v: CFTypeRef?
        var range = CFRange(location: (text as NSString).length, length: 0)
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let val = v,
           CFGetTypeID(val) == AXValueGetTypeID() {
            AXValueGetValue(val as! AXValue, .cfRange, &range)   // swiftlint:disable:this force_cast
        }
        return (text, NSRange(location: range.location, length: range.length))
    }

    /// Selects `range` (UTF-16) — reformat-last's replacement; true only when the field then reports that selection.
    func select(_ range: NSRange) -> Bool {
        if let tv = textView {
            guard NSMaxRange(range) <= (tv.string as NSString).length else { return false }
            tv.setSelectedRange(range)
            return tv.selectedRange() == range
        }
        guard let el = element else { return false }
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return false }
        return read()?.selection == range
    }

    /// Where the caret is (global Cocoa points), for the live transcript to stay off it: the selection's bounds, else
    /// the field itself when it is a small one (a search box, a chat line). nil: can't tell. Read-only.
    func caretRect() -> NSRect? {
        if let tv = textView {
            guard tv.window != nil else { return nil }
            let r = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            return r.isEmpty && r.origin == .zero ? nil : r.insetBy(dx: 0, dy: -2)
        }
        guard let el = element else { return nil }
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let range = v,
           CFGetTypeID(range) == AXValueGetTypeID() {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &b) == .success,
               let bv = b, CFGetTypeID(bv) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0 {   // swiftlint:disable:this force_cast
                    return toNS(CGRect(x: r.minX, y: r.minY, width: max(r.width, 2), height: r.height))
                }
            }
        }
        let f = AXProbe.frame(el)
        return f.height > 1 && f.height < 160 ? toNS(f) : nil
    }

    /// The focused window's title.
    var windowTitle: String? {
        if let tv = textView { return tv.window?.title }
        guard let p = pid else { return nil }
        let app = AXUIElementCreateApplication(p)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        return DictationField.string(win as! AXUIElement, kAXTitleAttribute)   // swiftlint:disable:this force_cast
    }

    /// Same element (the watch stops when the focus has moved to another field).
    func isFocused() -> Bool {
        if let tv = textView { return tv.window?.firstResponder === tv }
        guard let mine = element, let now = DictationField.focusedElement() else { return false }
        return CFEqual(mine, now)
    }

    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let r = ref,
              CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return (r as! AXUIElement)   // swiftlint:disable:this force_cast
    }
}

/// The text around the cursor when the dictation started: polish's spelling hints.
struct DictationContext {
    static let chars = 500
    var before = "", after = "", selection = "", title = "", app = ""

    var isEmpty: Bool { before.isEmpty && after.isEmpty && selection.isEmpty && title.isEmpty && app.isEmpty }
    var payload: [String: Any] { ["before": before, "after": after, "selection": selection, "title": title, "app": app] }
    /// For the speech model's request: the title and 300 characters each side of the cursor. Only which custom words
    /// appear in it is used (their order in the model's word list, the near-miss pass); none of it goes to the model.
    var hint: String {
        [title, String(before.suffix(300)), selection, String(after.prefix(300))].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    /// for the history, only with keep_audio (the Lab, feedback reports)
    var debugText: String { "\(title) — \(before)|\(selection.isEmpty ? "" : "[\(selection)]")\(after)" }

    static func capture() -> DictationContext? {
        guard let f = DictationField.focused() else { return titleOnly() }
        var c = DictationContext()
        c.app = f.app ?? ""
        c.title = f.windowTitle ?? ""
        if let (text, sel) = f.read() {
            let ns = text as NSString
            let lo = min(max(0, sel.location), ns.length), hi = min(ns.length, lo + max(0, sel.length))
            c.before = ns.substring(with: NSRange(location: max(0, lo - chars), length: lo - max(0, lo - chars)))
            c.selection = String(ns.substring(with: NSRange(location: lo, length: hi - lo)).prefix(chars))
            c.after = ns.substring(with: NSRange(location: hi, length: min(chars, ns.length - hi)))
        }
        return c.isEmpty ? nil : c
    }

    /// Apps whose focused element Accessibility can't read (WeChat's input box, some Electron apps): the front app's
    /// name and its focused window's title (often the chat or document name — still a spelling hint). Never Blurt,
    /// never with secure input on; test builds never read another app.
    static func titleOnly() -> DictationContext? {
        guard !DictationInsert.testMode, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var w: CFTypeRef?
        var c = DictationContext()
        c.app = front.localizedName ?? ""
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w,
           CFGetTypeID(win) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {   // swiftlint:disable:this force_cast
                c.title = (t as? String) ?? ""
            }
        }
        return c.isEmpty ? nil : c     // the app's name alone still tells the speech model what the words are about
    }
}

/// Watches the field a dictation was typed into, and learns the user's fixes of it.
final class DictationWatch {
    static let shared = DictationWatch()
    static var seconds: Double = 60
    static var every: Double = DictationInsert.testMode ? 0.5 : 1.5
    static let anchor = 40

    private var timer: Timer?
    private var field: DictationField?
    private var prefix = "", suffix = ""
    private var near = 0
    /// typed → the field's latest state of it (BlurtCore's DictationLearn.EditWatch: one diff, at the end)
    private var edit: DictationLearn.EditWatch?
    private var until = Date()
    private(set) var watching = false
    /// a fix was turned into a word (the island says so; tests read it)
    var onLearned: ((String) -> Void)?
    /// the list the take was typed as was taken apart in the field (a style-learning signal, dictation-styles.md §3.5)
    var onReverted: (() -> Void)?

    /// `location`: where the cursor was when the text went in (UTF-16), read just before pasting.
    func start(field: DictationField, inserted: String, location: Int) {
        finish("next")              // the next dictation: what the user did to the last one is learned now
        guard let (text, _) = field.read() else { return }
        let ns = text as NSString, len = (inserted as NSString).length
        // the typed text where the cursor was, else nearby (a field that trims or reflows it)
        var at = location
        if at < 0 || at + len > ns.length || ns.substring(with: NSRange(location: at, length: len)) != inserted {
            let lo = max(0, location - 200), r = ns.range(of: inserted, options: [], range: NSRange(location: lo, length: ns.length - lo))
            guard r.location != NSNotFound else { return emit(["event": "dictation_watch", "state": "not_found"]) }
            at = r.location
        }
        prefix = ns.substring(with: NSRange(location: max(0, at - DictationWatch.anchor), length: at - max(0, at - DictationWatch.anchor)))
        let end = at + len
        suffix = ns.substring(with: NSRange(location: end, length: min(DictationWatch.anchor, ns.length - end)))
        near = at
        edit = DictationLearn.EditWatch(typed: inserted)
        self.field = field
        until = Date().addingTimeInterval(DictationWatch.seconds)
        watching = true
        emit(["event": "dictation_watch", "state": "start", "seconds": DictationWatch.seconds])
        timer = Timer.scheduledTimer(withTimeInterval: DictationWatch.every, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// `why` "cleared" (the history went) and "reformat" (the text is being replaced) learn nothing.
    func stop(_ why: String? = nil) {
        timer?.invalidate()
        timer = nil
        if watching, let w = why { emit(["event": "dictation_watch", "state": "stop", "why": w]) }
        watching = false
        field = nil
        prefix = ""; suffix = ""; edit = nil                     // nothing of the document stays
    }

    /// The watch ends and learns what the user changed: its time, the focus or the text moved, the next dictation.
    private func finish(_ why: String) {
        if watching, let e = edit?.end() { learn(e.typed, e.edited) }
        stop(watching ? why : nil)
    }

    private func tick() {
        guard let f = field, let typed = edit?.typed else { return stop("gone") }
        if Date() > until { return finish("time") }
        guard f.isFocused(), let (text, _) = f.read() else { return finish("focus") }
        let maxLen = (typed as NSString).length * 3 + 200
        guard let now = DictationLearn.locate(in: text, prefix: prefix, suffix: suffix, near: near, maxLength: maxLen) else {
            return finish("moved")
        }
        // nothing is learned mid-edit: a pause while typing isn't the user's final word (Kubernetes → Kuberneetes →
        // K8s once taught "Kuberneetes" and never K8s). The watch learns once, when it ends.
        edit?.saw(now)
    }

    /// typed → the field's last state, once.
    private func learn(_ typed: String, _ edited: String) {
        if DictationReformat.reverted(typed: typed, edited: edited) { onReverted?() }
        let fixes = DictationLearn.fixes(typed: typed, edited: edited, isCommonWord: DictationLearn.isCommonWord)
        emit(["event": "dictation_watch", "state": "learn", "fixes": fixes.count])
        for fx in fixes {
            let r = DictationVocabulary.shared.learn(heard: fx.heard, fixed: fx.fixed)
            emit(["event": "dictation_learn", "heard": fx.heard, "fixed": fx.fixed, "kind": fx.kind.rawValue,
                  "result": r.map { "\($0)" } ?? "ignored"])
            if case .learned(let t)? = r { onLearned?(t) }
        }
    }
}
