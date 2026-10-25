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
        XCTAssertEqual(P.decide(s(secure: true)), .copy(reason: "secure_input"))
        XCTAssertEqual(P.decide(s(secureField: true, text: true)), .copy(reason: "secure_input"))
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
