import XCTest
@testable import BlurtCore

/// A take between its stop and its text (docs/design/dictation.md §Takes in flight): pastes in order, the forgotten
/// hands-free take, the first-takes tips, recognition failures.
final class DictationTakeFlowTests: XCTestCase {
    /// v0.9 dogfood: a double tap after the app changed — "Copied" replaced "not sent" in the same frame. One line now.
    func testOneLineSaysHowATakeWent() {
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: true, confirmed: true), .copiedNotSent)
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: false, confirmed: true), .copied)
        XCTAssertEqual(DictationDeliveredLine.line(result: "copied", sendAsked: false, confirmed: true), .copied)
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: true), .none)
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: false), .pastedUnsure)
        XCTAssertEqual(DictationDeliveredLine.line(result: "none", sendAsked: true, confirmed: true), .notSent)
        XCTAssertEqual(DictationDeliveredLine.line(result: "none", sendAsked: false, confirmed: true), .none)
        // a password field: not typed, not copied — the line offers Copy (also when a send was asked)
        XCTAssertEqual(DictationDeliveredLine.line(result: "held", sendAsked: true, confirmed: true), .held)
        // the focus was read and isn't a text field (the desktop, a page with nothing focused): the island keeps the text
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: false, confirmed: false,
                                                   noField: true), .noField)
        XCTAssertEqual(DictationDeliveredLine.line(result: "pasted", sendAsked: true, confirmed: false,
                                                   noField: true), .noField)
    }

    /// 2026-10-31: a take whose user switched apps is pasted into the app in front, and a double tap's Return follows
    /// it there — no ⚠ "you switched apps", no "Not sent: you switched apps". The line is any pasted take's.
    func testASwitchSaysNothing() {
        let L = DictationDeliveredLine.self
        XCTAssertEqual(L.line(result: "pasted", sendAsked: false, confirmed: true), .none)
        XCTAssertEqual(L.line(result: "pasted", sendAsked: false, confirmed: false), .pastedUnsure)
        // a pasted take whose Return wasn't pressed (pressReturn said why: secure input, Blurt in front …) is pasted
        XCTAssertEqual(L.line(result: "pasted", sendAsked: true, confirmed: true), .none)
        XCTAssertEqual(L.line(result: "pasted", sendAsked: true, confirmed: false), .pastedUnsure)
        // no field read in the new app: the island keeps the text, as for any take
        XCTAssertEqual(L.line(result: "pasted", sendAsked: true, confirmed: false, noField: true), .noField)
    }

    /// Dogfood: a double tap soon after a take that was only copied pressed Return in the app in front, where nothing
    /// was pasted.
    func testAPlainCopyIsDoneAndHoldsReturn() {
        XCTAssertTrue(DictationDeliveredLine.copied.checked)
        XCTAssertEqual(DictationDeliveredLine.copied.copyKey, "dictation.toast.copied")
        XCTAssertLessThan(DictationDeliveredLine.copied.copySeconds, DictationDeliveredLine.copiedNotSent.copySeconds)
        XCTAssertTrue(DictationCopiedGuard.holdsReturn(copiedAt: 100, keyAfter: false, now: 104))
        XCTAssertFalse(DictationCopiedGuard.holdsReturn(copiedAt: 100, keyAfter: true, now: 104))     // ⌘V, typing
        XCTAssertFalse(DictationCopiedGuard.holdsReturn(copiedAt: 100, keyAfter: false, now: 130))    // long ago
        XCTAssertFalse(DictationCopiedGuard.holdsReturn(copiedAt: nil, keyAfter: false, now: 104))    // it was typed
    }

    /// macOS 13–15, first Fn, nothing on the Mac: the island offers the small model, not the recommended 2.5 GB.
    func testTheFirstModelOfferedIsTheSmallestThatFits() {
        let rows: [(id: String, sizeMB: Double, fits: Bool)] = [("qwen3-asr-1.7b-mlx", 2468, true), ("sensevoice-small", 228, true),
                                                                 ("tiny-but-too-big-ram", 100, false), ("apple-speech", 0, true)]
        let none = DictationSpeechModels(selected: "qwen3-asr-1.7b-mlx", ready: false, selectedInstalled: false,
                                         recommended: "qwen3-asr-1.7b-mlx", recommendedInstalled: false)
        XCTAssertEqual(none.firstOffer(rows)?.id, "sensevoice-small")
        XCTAssertEqual(none.firstOffer(rows)?.sizeMB, 228)
        var vadOnly = none
        vadOnly.selectedInstalled = true
        XCTAssertNil(vadOnly.firstOffer(rows))                      // only the 0.6 MB VAD is missing
        var configured = none
        configured.configured = "qwen3-asr-1.7b-mlx"
        XCTAssertNil(configured.firstOffer(rows))                   // the user's own choice is what "Download" gets
        var ready = none
        ready.ready = true
        XCTAssertNil(ready.firstOffer(rows))
    }

    /// The founder (2026-10-30): the cloud-polish reminder once ever, after 10 takes, into a quiet island only.
    func testTheCloudReminderComesOnceAfterTenTakesIntoAQuietIsland() {
        func due(_ takes: Int, shown: Bool = false, ready: Bool = false, blurt: Bool = false, other: Bool = false, idle: Bool = true) -> Bool {
            DictationCloudReminder.due(takes: takes, shown: shown, cloudReady: ready, inBlurt: blurt, otherLine: other, islandIdle: idle)
        }
        XCTAssertFalse(due(9))
        XCTAssertTrue(due(10))
        XCTAssertFalse(due(30, shown: true))           // once, ever
        XCTAssertFalse(due(10, ready: true))
        XCTAssertFalse(due(10, blurt: true))           // the setup assistant's Try it
        XCTAssertFalse(due(10, other: true))           // a notice or a tip on this take
        XCTAssertFalse(due(10, idle: false))
        XCTAssertLessThan(DictationCloudReminder.seconds, 30)
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
