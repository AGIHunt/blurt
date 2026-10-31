import XCTest
@testable import BlurtCore

/// Where dictated text goes (docs/design/dictation.md §Insert): ⌘V into any other app in front, like Typeless, also
/// when Accessibility can't see a text field there (WeChat); refused only for Blurt itself, secure input, no app.
final class DictationPastePolicyTests: XCTestCase {
    typealias P = DictationPastePolicy
    func s(front: Bool = true, blurt: Bool = false, secure: Bool = false, ax: Bool = true, secureField: Bool = false,
           text: Bool? = true) -> P.Situation {
        .init(hasFrontApp: front, frontIsBlurt: blurt, secureInput: secure, accessibility: ax, focusSecure: secureField, focusIsText: text)
    }

    /// The paste has landed when the field shows the text: Return may go then, and only then does the clipboard come
    /// back (a fixed 0.6 s could beat a slow app, which then pasted — and sent — the user's old clipboard).
    func testAPasteHasLandedWhenTheFieldShowsIt() {
        let L = DictationPasteLanding.self
        XCTAssertTrue(L.landed(before: "Hi ", selection: NSRange(location: 3, length: 0), now: "Hi there.", inserted: "there."))
        XCTAssertTrue(L.landed(before: "我知道你就是的。", selection: NSRange(location: 6, length: 0),
                               now: "我知道你就是从老家回来的。", inserted: "从老家回来"))
        // a selection is replaced
        XCTAssertTrue(L.landed(before: "send the old text", selection: NSRange(location: 9, length: 3), now: "send the new text",
                               inserted: "new"))
        // not yet: the field is as it was
        XCTAssertFalse(L.landed(before: "Hi ", selection: NSRange(location: 3, length: 0), now: "Hi ", inserted: "there."))
        // something else changed (the user typed): not this paste
        XCTAssertFalse(L.landed(before: "Hi ", selection: NSRange(location: 3, length: 0), now: "Hi x", inserted: "there."))
        // a field that tidies the spacing around it still has it
        XCTAssertTrue(L.landed(before: "a", selection: NSRange(location: 1, length: 0), now: "a there.", inserted: "there."))
        XCTAssertLessThan(L.restoreMargin, L.unconfirmedRestore)
        XCTAssertGreaterThan(L.unconfirmedRestore, L.unconfirmedReturn)          // the clipboard never before Return
        // Return: when seen, at 0.6 s at the latest — a field that never shows the text exactly (it converts quotes
        // or emoji) no longer holds a send 1.5 s (review)
        XCTAssertEqual(L.returnAfter(seen: 0.09), 0.09)
        XCTAssertEqual(L.returnAfter(seen: nil), 0.6)
        XCTAssertEqual(L.returnAfter(seen: 1.2), 0.6)
        XCTAssertEqual(L.restoreAfter(seen: 0.09), 0.24, accuracy: 1e-9)
        XCTAssertEqual(L.restoreAfter(seen: nil), 1.5)
        XCTAssertLessThanOrEqual(L.restoreAfter(seen: nil), L.confirmTimeout)
    }

    func testPastesIntoATextField() {
        XCTAssertEqual(P.decide(s()), .paste(confirmed: true))
    }

    func testPastesWhereAccessibilitySeesNoTextField() {
        // WeChat's input box: the focused element isn't an AX text role, or no element can be read at all
        XCTAssertEqual(P.decide(s(text: false)), .paste(confirmed: false))
        XCTAssertEqual(P.decide(s(text: nil)), .paste(confirmed: false))
    }

    func testRefusals() {
        XCTAssertEqual(P.decide(s(front: false)), .copy(reason: "no_front_app"))
        XCTAssertEqual(P.decide(s(blurt: true)), .own)
        XCTAssertEqual(P.decide(s(secure: true)), .hold(reason: "secure_input"))       // never on the clipboard by itself
        XCTAssertEqual(P.decide(s(secureField: true, text: true)), .hold(reason: "secure_input"))
        XCTAssertEqual(P.decide(s(ax: false)), .copy(reason: "no_accessibility"))
        // Blurt in front wins over everything but "no app" (its own text views get a paste: action)
        XCTAssertEqual(P.decide(s(blurt: true, secure: true)), .own)
    }

    /// 2026-10-31, the founder: people speak in A meaning to type into B. A take whose user switched apps goes into
    /// the app in front by the same rules as any take (until then: copied, with a ⚠ "you switched apps").
    func testASwitchedAppGetsTheTextByTheUsualRules() {
        for front in [true, false] { for blurt in [true, false] { for secure in [true, false] { for ax in [true, false] {
            for text in [true, false, nil] as [Bool?] {
                var x = s(front: front, blurt: blurt, secure: secure, ax: ax, text: text)
                let same = P.decide(x)
                x.appChanged = true
                XCTAssertEqual(P.decide(x), same)
            }
        } } } }
        var x = s()
        x.appChanged = true
        XCTAssertEqual(P.decide(x), .paste(confirmed: true))
        var pw = s(secureField: true)
        pw.appChanged = true
        XCTAssertEqual(P.decide(pw), .hold(reason: "secure_input"))         // a password field in the new app: held
        var b = s(blurt: true)
        b.appChanged = true
        XCTAssertEqual(P.decide(b), .own)                                    // into Blurt: its own text view, or nothing
    }

    /// A queued Return (a double tap while the take was on its way) goes only where the text went in, and never after a
    /// switch: the text is pasted, but sending into another chat can't be undone.
    func testAQueuedReturnIsHeldAfterASwitch() {
        typealias S = DictationSendPolicy
        XCTAssertEqual(S.queued(pasted: true, noField: false, appChanged: false), .press)
        XCTAssertEqual(S.queued(pasted: true, noField: false, appChanged: true), .skip(reason: "app_changed"))
        XCTAssertEqual(S.queued(pasted: true, noField: true, appChanged: false), .skip(reason: "no_field"))
        XCTAssertEqual(S.queued(pasted: false, noField: false, appChanged: true), .skip(reason: "not_pasted"))
        XCTAssertEqual(S.queued(pasted: false, noField: false, appChanged: false), .skip(reason: "not_pasted"))
    }

    /// ⌥C / ⌥T paste by the same rules (2026-10-30: WeChat only got a copy — the old check wanted an AX text role):
    /// wherever dictation pastes, except a focus Accessibility reads as no text field (the desktop: the text is on
    /// the clipboard already).
    func testScreenTextPastesByDictationsRules() {
        typealias T = ScreenTextPaste
        XCTAssertEqual(T.decide(s()), .paste)
        XCTAssertEqual(T.decide(s(text: nil)), .paste)                      // WeChat: nothing Accessibility can read
        XCTAssertEqual(T.decide(s(text: false)), .copy(reason: "no_field")) // the desktop, a page with no field
        XCTAssertEqual(T.decide(s(front: false)), .copy(reason: "no_front_app"))
        XCTAssertEqual(T.decide(s(blurt: true)), .copy(reason: "blurt_in_front"))
        XCTAssertEqual(T.decide(s(secure: true)), .copy(reason: "secure_input"))
        XCTAssertEqual(T.decide(s(secureField: true)), .copy(reason: "secure_input"))
        XCTAssertEqual(T.decide(s(ax: false)), .copy(reason: "no_accessibility"))
        var moved = s()
        moved.appChanged = true                                              // the user switched apps during the drag
        XCTAssertEqual(T.decide(moved), .copy(reason: "app_changed"))
        // every situation dictation pastes into, ⌥C pastes into too — unless the focus is read as no field
        for front in [true, false] { for blurt in [true, false] { for secure in [true, false] { for ax in [true, false] {
            for text in [true, false, nil] as [Bool?] {
                let x = s(front: front, blurt: blurt, secure: secure, ax: ax, text: text)
                if case .paste = P.decide(x) { XCTAssertEqual(T.decide(x) == .paste, text != false) } else {
                    XCTAssertNotEqual(T.decide(x), .paste)
                }
            }
        } } } }
    }

    /// "Pasted" only once the field shows it; ⌘V that can't be confirmed says the text is on the clipboard.
    func testScreenTextSaysPastedOnlyWhenSeen() {
        typealias T = ScreenTextPaste
        XCTAssertEqual(T.outcome(pasted: true, seen: true), .pasted)
        XCTAssertEqual(T.outcome(pasted: true, seen: false), .unconfirmed)
        XCTAssertEqual(T.outcome(pasted: false, seen: false), .copied)
        XCTAssertEqual(T.outcome(pasted: false, seen: true), .copied)
        XCTAssertEqual(T.lineKey(.pasted, translate: false), "capture.text.typed")
        XCTAssertEqual(T.lineKey(.pasted, translate: true), "capture.text.translation_pasted")
        XCTAssertEqual(T.lineKey(.unconfirmed, translate: false), "capture.text.copied_paste")
        XCTAssertEqual(T.lineKey(.unconfirmed, translate: true), "capture.text.copied_paste")
        XCTAssertEqual(T.lineKey(.copied, translate: false), "capture.text.copied")
        XCTAssertEqual(T.lineKey(.copied, translate: true), "capture.text.translation_copied")
        XCTAssertEqual(T.lineKey(.alreadyInTarget, translate: true), "capture.text.already")
        // every line exists in both languages
        for o in [T.Outcome.pasted, .unconfirmed, .copied, .alreadyInTarget] { for tr in [true, false] {
            for lang in Loc.languages {
                XCTAssertNotNil(Loc.string(T.lineKey(o, translate: tr), table: "Capture", language: lang), "\(o) \(tr) \(lang)")
            }
        } }
    }

    func testBuiltInMicChoice() {
        let c = DictationMicChoice.useBuiltIn
        XCTAssertTrue(c(nil, true, true))          // automatic: AirPods are the default input → the Mac's mic
        XCTAssertFalse(c(nil, false, true))        // automatic: a wired / built-in default stays
        XCTAssertFalse(c(false, true, true))       // the user said no
        XCTAssertTrue(c(true, false, true))        // the user said always
        XCTAssertFalse(c(true, true, false))       // a Mac without a mic (mini, Studio)
    }

    /// A double tap presses Return only into another app, never with secure input on, and only with Accessibility.
    func testSendPolicy() {
        typealias D = DictationSendPolicy
        XCTAssertEqual(D.decide(hasFrontApp: true, frontIsBlurt: false, secureInput: false, accessibility: true), .press)
        XCTAssertEqual(D.decide(hasFrontApp: true, frontIsBlurt: true, secureInput: false, accessibility: true), .skip(reason: "blurt_in_front"))
        XCTAssertEqual(D.decide(hasFrontApp: true, frontIsBlurt: false, secureInput: true, accessibility: true), .skip(reason: "secure_input"))
        XCTAssertEqual(D.decide(hasFrontApp: true, frontIsBlurt: false, secureInput: false, accessibility: false), .skip(reason: "no_accessibility"))
        XCTAssertEqual(D.decide(hasFrontApp: false, frontIsBlurt: false, secureInput: false, accessibility: true), .skip(reason: "no_front_app"))
    }
}
