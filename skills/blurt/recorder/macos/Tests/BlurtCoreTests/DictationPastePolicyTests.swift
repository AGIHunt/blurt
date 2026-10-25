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

    func testASlowTakeNeverGoesIntoAnotherApp() {
        // dogfood: a take that took long (a cold model, the 5-minute limit) and the user moved to another app (or
        // into Blurt) — copied, never pasted there
        var x = s()
        x.appChanged = true
        XCTAssertEqual(P.decide(x), .copy(reason: "app_changed"))
        var b = s(blurt: true)
        b.appChanged = true
        XCTAssertEqual(P.decide(b), .copy(reason: "app_changed"))
        // still the app it started in: pasted as usual
        XCTAssertEqual(P.decide(s()), .paste(confirmed: true))
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
