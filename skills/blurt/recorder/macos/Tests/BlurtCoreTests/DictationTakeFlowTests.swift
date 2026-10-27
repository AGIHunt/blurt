import XCTest
@testable import BlurtCore

/// A take between its stop and its text (docs/design/dictation.md §Takes in flight): pastes in order, the forgotten
/// hands-free take, the first-takes tips, recognition failures.
final class DictationTakeFlowTests: XCTestCase {
    /// v0.9 dogfood: a double tap after the app changed — "Copied" replaced "not sent" in the same frame. One line now.
    func testOneLineSaysHowATakeWent() {
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: true, confirmed: true, appChanged: true), .copiedNotSent)
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: false, confirmed: true, appChanged: true), .copied(appChanged: true))
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: false, confirmed: true, appChanged: false), .copied(appChanged: false))
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: true, appChanged: false), .none)
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: false, appChanged: false), .pastedUnsure)
        XCTAssertEqual(DictationDeliveredLine.line(result: "none", sendAsked: true, confirmed: true, appChanged: false), .notSent)
        XCTAssertEqual(DictationDeliveredLine.line(result: "none", sendAsked: false, confirmed: true, appChanged: false), .none)
        // a password field: not typed, not copied — the line offers Copy (also when a send was asked)
        XCTAssertEqual(DictationDeliveredLine.line(result: "held", sendAsked: true, confirmed: true, appChanged: false), .held)
        // the focus was read and isn't a text field (the desktop, a page with nothing focused): the island keeps the text
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: false, appChanged: false,
                                                   noField: true), .noField)
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: true, confirmed: false, appChanged: false,
                                                   noField: true), .noField)
    }

    func testTheKeptTextIsItsStart() {
        XCTAssertEqual(DictationKeptText.preview("  short\nline  "), "short line")
        let zh = String(repeating: "这是一段很长的话", count: 12) + "，最后几个字"
        let p = DictationKeptText.preview(zh)
        XCTAssertTrue(p.hasSuffix("…"))
        XCTAssertLessThanOrEqual(p.count, DictationKeptText.limit + 1)
        // a break near the end: cut there, not mid-word
        let en = String(repeating: "word ", count: 30)
        XCTAssertEqual(DictationKeptText.preview(en), String(repeating: "word ", count: 16).trimmingCharacters(in: .whitespaces) + "…")
    }

    func testPastesGoInTheOrderTheyWereSaid() {
        var q = DictationPasteQueue<String>()
        q.add("a")
        q.add("b")                       // a tap while "a" was still being structured started "b"
        q.markReady("b")                 // the short second take is done first
        XCTAssertNil(q.next())           // …but waits for the first
        q.markReady("a")
        XCTAssertEqual(q.next(), "a")
        XCTAssertNil(q.next())           // one paste at a time
        q.delivered("a")
        XCTAssertEqual(q.next(), "b")
        q.delivered("b")
        XCTAssertTrue(q.isEmpty)
    }

    func testADroppedTakeLetsTheNextOneGo() {
        var q = DictationPasteQueue<Int>()
        q.add(1); q.add(2)
        q.markReady(2)
        q.drop(1)                        // nothing heard / cancelled / failed
        XCTAssertEqual(q.next(), 2)
        XCTAssertEqual(q.last, 2)
        q.add(2)                         // never twice
        XCTAssertEqual(q.count, 1)
    }

    func testForgottenTakeIsRemindedAndCountedDown() {
        var r = DictationRunaway()
        var notices: [DictationRunaway.Notice] = []
        var t = 0.0
        // 6 s of speech, then silence until the limit (the dogfood repro)
        while t < 300 {
            if let n = r.feed(elapsed: t, speaking: t < 6, handsFree: true) { notices.append(n) }
            t += 0.5
        }
        XCTAssertEqual(notices, [.stillListening, .endsSoon])          // once each: no nagging every 20 s
        // speech again resets the quiet stretch: another reminder only after 20 more quiet seconds
        var s = DictationRunaway()
        XCTAssertNil(s.feed(elapsed: 19, speaking: false, handsFree: true))
        XCTAssertEqual(s.feed(elapsed: 20, speaking: false, handsFree: true), .stillListening)
        XCTAssertNil(s.feed(elapsed: 30, speaking: true, handsFree: true))
        XCTAssertNil(s.feed(elapsed: 49, speaking: false, handsFree: true))
        XCTAssertEqual(s.feed(elapsed: 50, speaking: false, handsFree: true), .stillListening)
        // push-to-talk: no reminder (the key is held), the countdown still comes
        var p = DictationRunaway()
        XCTAssertNil(p.feed(elapsed: 60, speaking: false, handsFree: false))
        XCTAssertEqual(p.feed(elapsed: 271, speaking: true, handsFree: false), .endsSoon)
    }

    func testEarClockCountsDownFromFourThirty() {
        XCTAssertEqual(DictationRunaway.clock(elapsed: 0).text, "0:00")
        XCTAssertEqual(DictationRunaway.clock(elapsed: 269.9).text, "4:29")
        XCTAssertFalse(DictationRunaway.clock(elapsed: 269.9).countdown)
        XCTAssertEqual(DictationRunaway.clock(elapsed: 270).text, "\u{2212}0:30")
        XCTAssertTrue(DictationRunaway.clock(elapsed: 270).countdown)
        XCTAssertEqual(DictationRunaway.clock(elapsed: 299.2).text, "\u{2212}0:01")
        XCTAssertEqual(DictationRunaway.clock(elapsed: 300).text, "\u{2212}0:00")
    }

    func testTipsAfterTheFirstTakes() {
        typealias T = DictationTip
        // chat apps: double-tap to send, five times, never right after the user sent
        XCTAssertEqual(T.next(chat: true, sendOn: true, sent: false, shown: [:]), .send)
        XCTAssertEqual(T.next(chat: true, sendOn: true, sent: false, shown: ["send": 4]), .send)
        XCTAssertNil(T.next(chat: true, sendOn: true, sent: false, shown: ["send": 5]))
        XCTAssertNil(T.next(chat: true, sendOn: true, sent: true, shown: [:]))
        XCTAssertNil(T.next(chat: true, sendOn: false, sent: false, shown: [:]))
        // elsewhere: from the very first take, ⇧ for a list once, ⌥⇧L once, then quiet
        XCTAssertEqual(T.next(chat: false, sendOn: true, sent: false, shown: [:]), .list)
        XCTAssertEqual(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 1]), .list)
        XCTAssertEqual(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 2, "list": 1]), .reformat)
        XCTAssertNil(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 3, "list": 1, "reformat": 1]))
    }

    func testRecognitionFailures() {
        XCTAssertEqual(DictationASRFailure(code: "model_missing"), .noModel)
        XCTAssertEqual(DictationASRFailure(code: "timeout"), .timedOut)
        XCTAssertEqual(DictationASRFailure(code: nil), .failed("error"))
        XCTAssertEqual(DictationASRFailure(code: "network").code, "network")
        // the server's time scales with the audio: a hung server is given up on in proportion, not after a flat minute
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 0), 15)
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 20), 45)
    }

    // MARK: the speech model a take needs (review: VAD missing, a cloud model outside the rows)

    func testReadyComesFromTheCLINotTheRows() {
        // a cloud model: not one of the rows, but ready (its key is set)
        let cloud = DictationSpeechModels(["selected": "openai-compatible", "recommended": "qwen3-asr-0.6b-mlx",
                                           "ready": true, "selected_installed": true, "missing": [String](),
                                           "models": [["id": "qwen3-asr-0.6b-mlx", "installed": false]]])!
        XCTAssertTrue(cloud.ready)
        XCTAssertFalse(cloud.recommendedInstalled)
        // the model is there, the VAD isn't: not ready, and what to say is the VAD
        let vad = DictationSpeechModels(["selected": "qwen3-asr-0.6b-mlx", "recommended": "qwen3-asr-0.6b-mlx",
                                         "ready": false, "selected_installed": true, "missing": ["silero-vad"],
                                         "models": [["id": "qwen3-asr-0.6b-mlx", "installed": true]]])!
        XCTAssertFalse(vad.ready)
        XCTAssertTrue(vad.onlyVADMissing)
        // Download… then runs the selected model's setup (which brings the VAD) without changing the choice
        XCTAssertEqual(vad.toGet?.id, "qwen3-asr-0.6b-mlx")
        XCTAssertEqual(vad.toGet?.choose, false)
        // an older CLI without `ready`: the rows, as before
        let old = DictationSpeechModels(["selected": "a", "recommended": "a", "models": [["id": "a", "installed": true]]])!
        XCTAssertTrue(old.ready)
        XCTAssertNil(DictationSpeechModels(["models": []]))
    }

    func testWhatDownloadGets() {
        typealias M = DictationSpeechModels
        // nothing: the recommended one, chosen
        let none = M(selected: "sv", ready: false, selectedInstalled: false, recommended: "q17", recommendedInstalled: false,
                     missing: ["silero-vad", "sv"])
        XCTAssertEqual(none.toGet?.id, "q17")
        XCTAssertEqual(none.toGet?.choose, true)
        XCTAssertFalse(none.onlyVADMissing)
        // the user picked a model that isn't there: that one, not the recommended one
        let picked = M(selected: "sv", ready: false, selectedInstalled: false, recommended: "q17", recommendedInstalled: false,
                       configured: "turbo", configuredInstalled: false, missing: ["sv"])
        XCTAssertEqual(picked.toGet?.id, "turbo")
        // ready with the recommended one: nothing to get
        XCTAssertNil(M(selected: "q", ready: true, selectedInstalled: true, recommended: "q", recommendedInstalled: true).toGet)
    }

    func testWeakerModelNoticeNotForTheUsersOwnChoice() {
        typealias M = DictationSpeechModels
        let auto = M(selected: "sv", ready: true, selectedInstalled: true, recommended: "q17", recommendedInstalled: false)
        XCTAssertTrue(auto.weakerModelRan("sv"))
        XCTAssertFalse(auto.weakerModelRan("q17"))
        XCTAssertFalse(auto.weakerModelRan(nil))
        let chosen = M(selected: "sv", ready: true, selectedInstalled: true, recommended: "q17", recommendedInstalled: false,
                       configured: "sv", configuredInstalled: true)
        XCTAssertFalse(chosen.weakerModelRan("sv"))
        // the chosen one isn't what ran (it fell back): said
        XCTAssertTrue(chosen.weakerModelRan("ct2"))
        let have = M(selected: "q17", ready: true, selectedInstalled: true, recommended: "q17", recommendedInstalled: true)
        XCTAssertFalse(have.weakerModelRan("sv"))
    }

    // MARK: ⌥⇧L while a take is on its way (review: it ran for a later take)

    func testReformatAfterPasteIsBoundToItsTake() {
        var q = DictationPasteQueue<String>()
        var r = DictationReformatAfterPaste<String>()
        q.add("A")
        XCTAssertEqual(r.request(last: q.last, via: "hotkey"), "A")
        // A is cancelled (Esc), fails, or hears nothing: the request goes with it
        r.forget("A")
        q.drop("A")
        q.add("B")
        q.markReady("B")
        XCTAssertEqual(q.next(), "B")
        XCTAssertNil(r.delivered("B"), "B never asked for a reformat")
        // asked for B, B pasted: used once
        XCTAssertEqual(r.request(last: "B", via: "hotkey"), "B")
        XCTAssertNil(r.delivered("C"))
        XCTAssertEqual(r.delivered("B"), "hotkey")
        XCTAssertNil(r.delivered("B"))
        // several on their way: the one said last
        q = DictationPasteQueue<String>()
        q.add("X"); q.add("Y")
        XCTAssertEqual(r.request(last: q.last, via: "hotkey"), "Y")
        XCTAssertNil(r.delivered("X"))
        XCTAssertEqual(r.delivered("Y"), "hotkey")
        // nothing on its way: no request
        XCTAssertNil(r.request(last: nil, via: "hotkey"))
        XCTAssertNil(r.pending)
    }

    // MARK: the hung server (review: the given-up minute held for a fresh server)

    func testAFreshServerIsUsedAtOnce() {
        XCTAssertTrue(DictationServerGiveUp.stillGivenUp(givenUp: 100, now: 100))
        XCTAssertFalse(DictationServerGiveUp.stillGivenUp(givenUp: 100, now: 200))
        XCTAssertTrue(DictationServerGiveUp.stillGivenUp(givenUp: 100, now: nil))
        XCTAssertTrue(DictationServerGiveUp.stillGivenUp(givenUp: nil, now: 200))
    }

    // MARK: the aura on a send (finding #10)

    func testTheAuraWaitsOutTheDoubleTapWindow() {
        XCTAssertEqual(DictationGlow.delay(pushToTalk: false, doubleTapSend: true, window: 0.4), 0.4)
        XCTAssertEqual(DictationGlow.delay(pushToTalk: true, doubleTapSend: true, window: 0.4), 0)
        XCTAssertEqual(DictationGlow.delay(pushToTalk: false, doubleTapSend: false, window: 0.4), 0)
    }
}
