// What the pad says for each state of the connection (Model/LinkStatus.swift; docs/design/remote.md §Connection, "What the pad says").
// The same cases as apps/android/core/src/test/.../LinkStatusTest.kt: the two phones say the same thing.
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class LinkStatusTests: XCTestCase {
    private func banner(_ p: LinkStatus.Phase, _ change: (inout LinkStatus) -> Void = { _ in }) -> StatusBanner? {
        var s = LinkStatus(phase: p)
        change(&s)
        return StatusBanner.of(s)
    }

    func testConnectedAndWorkingSaysNothing() {
        XCTAssertNil(banner(.connected))
        XCTAssertNil(banner(.connected) { $0.hasRelay = true; $0.otherComputers = true; $0.dropped = true })
    }

    func testConnectingShowsItIsBusyAndNeedsNothing() {
        XCTAssertEqual(banner(.connecting), StatusBanner(mark: .busy, title: .connecting))
        // a session that went while in use is coming back, and says so
        XCTAssertEqual(banner(.connecting) { $0.dropped = true }, StatusBanner(mark: .busy, title: .reconnecting))
    }

    func testCantReachSaysTheOneThingToCheckAndOffersRetry() {
        XCTAssertEqual(banner(.unreachable), StatusBanner(mark: .problem, title: .cantReach, detail: .checkNetwork, action: .retry))
        // with a relay the computer can be anywhere: the network isn't the thing to check
        XCTAssertEqual(banner(.unreachable) { $0.hasRelay = true }, StatusBanner(mark: .problem, title: .cantReach, detail: .checkAwake, action: .retry))
        // another computer to try is the second thing, never the first
        XCTAssertEqual(banner(.unreachable) { $0.otherComputers = true },
                       StatusBanner(mark: .problem, title: .cantReach, detail: .checkNetwork, action: .retry, second: .another))
    }

    func testTheGoBetweenSaysWhyAndWhatFixesIt() {
        // the direct path didn't open, or the go-between couldn't carry it: a relay of one's own fixes that, whatever else is true
        XCTAssertEqual(banner(.unreachable) { $0.away = .noDirect; $0.hasRelay = true },
                       StatusBanner(mark: .problem, title: .cantReach, detail: .noDirect, action: .retry))
        XCTAssertEqual(banner(.unreachable) { $0.away = .busy; $0.otherComputers = true },
                       StatusBanner(mark: .problem, title: .cantReach, detail: .goBetweenBusy, action: .retry, second: .another))
        // connecting or connected, there's nothing to say about it yet / any more
        XCTAssertEqual(banner(.connecting) { $0.away = .noDirect }, StatusBanner(mark: .busy, title: .connecting))
        XCTAssertNil(banner(.connected) { $0.away = .busy })
        // the words, as the spec has them
        XCTAssertEqual(Words.status(.noDirect, host: .mac, name: "Mac"),
                       "Can’t connect directly. Set up your own relay on the computer.")
        XCTAssertEqual(Words.status(.goBetweenBusy, host: .windows, name: "PC"), "The public connection service has reached today’s limit. Try again later, or use your own relay.")
    }

    func testPairingStates() {
        XCTAssertEqual(banner(.unpaired), StatusBanner(mark: .code, title: .pairFirst, detail: .whereTheCodeIs, action: .scan))
        XCTAssertEqual(banner(.forgotten), StatusBanner(mark: .problem, title: .needsPairing, detail: .forgotten, action: .scan))
        XCTAssertEqual(banner(.replaced), StatusBanner(mark: .phone, title: .otherPhone, detail: .touchToTakeOver))
    }

    func testAPairingUnderWayIsSaidOverTheRest() {
        for p in [LinkStatus.Phase.unpaired, .connecting, .unreachable, .connected] {
            XCTAssertEqual(banner(p) { $0.waiting = true }, StatusBanner(mark: .busy, title: .waiting, detail: .allowOnComputer), "\(p)")
        }
        // one that didn't take: why, and never a dead end: a new code, and what there was to do about the computer gone back to
        XCTAssertEqual(banner(.unpaired) { $0.pairFailed = true }, StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan))
        XCTAssertEqual(banner(.connecting) { $0.pairFailed = true }, StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan))
        XCTAssertEqual(banner(.connected) { $0.pairFailed = true }, StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan))
        XCTAssertEqual(banner(.unreachable) { $0.pairFailed = true; $0.otherComputers = true },
                       StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan, second: .retry))
        // a code that can't be reached is still being tried: the same code again first, a new one second
        XCTAssertEqual(banner(.unreachable) { $0.pairFailed = true; $0.pairRetry = true },
                       StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .retry, second: .scan))
        // once the computer asks, its digits take the failure's place, so they can be compared
        XCTAssertEqual(banner(.unreachable) { $0.pairFailed = true; $0.pairRetry = true; $0.waiting = true },
                       StatusBanner(mark: .busy, title: .waiting, detail: .allowOnComputer))
    }

    /// Why a pairing ended is read from when, as the Mac viewer does: refused before the question, a no while it was up, or nobody
    /// answering in the computer's two minutes. A spent code is not "didn't allow", and no answer is not a no.
    func testWhyAPairingEnded() {
        let t = Date()
        XCTAssertEqual(Link.ending(asked: nil, now: t), .spent)
        XCTAssertEqual(Link.ending(asked: t.addingTimeInterval(-5), now: t), .declined)
        XCTAssertEqual(Link.ending(asked: t.addingTimeInterval(-107), now: t), .declined)
        XCTAssertEqual(Link.ending(asked: t.addingTimeInterval(-108), now: t), .unanswered)
        XCTAssertEqual(Link.ending(asked: t.addingTimeInterval(-121), now: t), .unanswered)
    }

    func testWhatAFailedPairingSays() {
        let spent = Link.failure(.spent, name: "Studio PC", hasRelay: true)
        XCTAssertEqual(spent.title, "This code has expired or was already used.")
        XCTAssertEqual(spent.help, "On Studio PC, open Add Device and scan the code it shows now.")
        XCTAssertFalse(spent.canRetry)
        XCTAssertEqual(Link.failure(.declined, name: "Studio PC", hasRelay: true).title, "Studio PC didn’t allow this iPhone.")
        XCTAssertEqual(Link.failure(.unanswered, name: "Studio PC", hasRelay: true).title, "No one answered on Studio PC in time.")
        let away = Link.failure(.unreachable, name: "Studio PC", hasRelay: true)
        XCTAssertEqual(away.title, "Can’t reach Studio PC.")
        XCTAssertEqual(away.help, "Make sure Studio PC is on and Blurt is open there.")
        XCTAssertTrue(away.canRetry)
        XCTAssertTrue(Link.failure(.unreachable, name: "Studio PC", hasRelay: false).help.contains("same network"))
        // the card says the failure itself, then what to do
        XCTAssertEqual(Words.status(.pairingFailed, host: .windows, name: "Studio PC", failed: spent), spent.title)
        XCTAssertEqual(Words.status(.whyPairingFailed, host: .windows, name: "Studio PC", failed: spent), spent.help)
        XCTAssertEqual(Words.status(.forgotten, host: .windows, name: "Studio PC"), "Studio PC removed this iPhone.")
    }

    /// Records from before 1.1 have no `removed`; one removed in a session keeps its record, marked.
    func testARemovedComputerIsKeptMarked() throws {
        let old = #"{"id":"x","deviceID":"d","name":"Old","port":1,"addresses":[]}"#
        XCTAssertNil(try JSONDecoder().decode(PairedMac.self, from: Data(old.utf8)).removed)
        var m = try JSONDecoder().decode(PairedMac.self, from: Data(old.utf8))
        m.removed = true
        let back = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.removed, true)
    }

    func testConnectedButNotWorking() {
        XCTAssertEqual(banner(.connected) { $0.canControl = false }, StatusBanner(mark: .problem, title: .cantControl, detail: .howToAllowControl))
        XCTAssertEqual(banner(.connected) { $0.screenError = "permission" }, StatusBanner(mark: .problem, title: .cantShowScreen, detail: .allowScreen))
        XCTAssertEqual(banner(.connected) { $0.screenError = "off" }, StatusBanner(mark: .problem, title: .cantShowScreen, detail: .screenIsOff))
        // the screen was just asked for: that's the one said
        XCTAssertEqual(banner(.connected) { $0.canControl = false; $0.screenError = "off" }?.detail, .screenIsOff)
        // not connected, neither matters
        XCTAssertEqual(banner(.connecting) { $0.canControl = false; $0.screenError = "off" }, StatusBanner(mark: .busy, title: .connecting))
    }

    func testEveryStateButConnectedSaysSomething() {
        for p in [LinkStatus.Phase.unpaired, .connecting, .unreachable, .forgotten, .replaced] {
            XCTAssertNotNil(banner(p), "\(p)")
        }
        // a button never without the line that says what it's for
        for p in [LinkStatus.Phase.unpaired, .connecting, .unreachable, .forgotten, .replaced, .connected] {
            for relay in [false, true] {
                for others in [false, true] {
                    guard let b = banner(p, { $0.hasRelay = relay; $0.otherComputers = others }) else { continue }
                    if b.action != nil { XCTAssertNotNil(b.detail, "\(p)") }
                    if b.second != nil { XCTAssertNotNil(b.action, "\(p)") }
                }
            }
        }
    }

    // MARK: a drop, and coming back

    func testADropInUseIsFeltAndSoIsComingBack() {
        var f = StatusFollower()
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: true))
        XCTAssertNil(f.see(.connected, computer: "a", inUse: true), "a first connection is no news to the thumb")
        XCTAssertEqual(f.see(.connecting, computer: "a", inUse: true), .dropped)
        XCTAssertTrue(f.dropped)
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: true), "once")
        XCTAssertNil(f.see(.unreachable, computer: "a", inUse: true))
        XCTAssertTrue(f.dropped, "still the same drop")
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: true), "Retry")
        XCTAssertEqual(f.see(.connected, computer: "a", inUse: true), .back)
        XCTAssertFalse(f.dropped)
        XCTAssertNil(f.see(.connected, computer: "a", inUse: true))
    }

    func testLeavingTheAppOrChoosingAnotherComputerIsNoDrop() {
        var f = StatusFollower()
        _ = f.see(.connected, computer: "a", inUse: true)
        // the app went to the background: Link lets go and will connect again
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: false))
        XCTAssertFalse(f.dropped)
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: true))
        XCTAssertNil(f.see(.connected, computer: "a", inUse: true))
        // another computer chosen: a first connection to it
        XCTAssertNil(f.see(.connecting, computer: "b", inUse: true))
        XCTAssertFalse(f.dropped)
        XCTAssertNil(f.see(.connected, computer: "b", inUse: true))
    }

    func testADropThatEndsElsewhereIsNotComingBack() {
        var f = StatusFollower()
        _ = f.see(.connected, computer: "a", inUse: true)
        XCTAssertEqual(f.see(.connecting, computer: "a", inUse: true), .dropped)
        XCTAssertNil(f.see(.forgotten, computer: "a", inUse: true))
        XCTAssertFalse(f.dropped)
        XCTAssertNil(f.see(.connecting, computer: "a", inUse: true))
        XCTAssertNil(f.see(.connected, computer: "a", inUse: true), "paired again: a first connection")
    }

    // MARK: the words

    private static let lines: [StatusBanner.Line] = [.connecting, .reconnecting, .cantReach, .checkNetwork, .checkAwake, .needsPairing, .forgotten, .otherPhone,
                                                     .touchToTakeOver, .pairFirst, .whereTheCodeIs, .waiting, .allowOnComputer, .pairingFailed,
                                                     .whyPairingFailed, .cantControl, .howToAllowControl, .cantShowScreen, .allowScreen, .screenIsOff]

    func testEveryLineHasWordsForEveryKindOfComputer() {
        for h in RemoteHost.allCases {
            for l in Self.lines {
                let t = Words.status(l, host: h, name: "Studio", check: "1234", failed: Link.failure(.declined, name: "Studio", hasRelay: false))
                XCTAssertFalse(t.isEmpty, "\(l) \(h)")
                XCTAssertFalse(t.contains("!"), "no shouting: \(t)")
                XCTAssertFalse(t.contains("%@"), t)
            }
            // no name yet: still a sentence
            XCTAssertFalse(Words.status(.cantReach, host: h, name: nil).isEmpty)
        }
        for a in [StatusBanner.Action.retry, .scan, .another] { XCTAssertFalse(Words.status(a).isEmpty) }
        XCTAssertTrue(Words.status(.connecting, host: .mac, name: "Studio").contains("Studio"))
        XCTAssertTrue(Words.status(.allowOnComputer, host: .mac, name: "Studio", check: "1234").contains("1234"))
    }

    /// The catalog itself: what the card says is there in Chinese too.
    func testTheCardsWordsAreTranslated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BlurtRemote/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no catalog beside the tests") }
        let all = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        for k in ["Connecting to %@…", "Reconnecting to %@…", "Can’t reach %@",
                  "Check that Blurt is running and both are on the same network. To connect from anywhere, set a relay in Blurt’s Settings → Remote Control on the computer.",
                  "Check that the computer isn’t asleep and Blurt is running.", "Needs pairing again", "Another phone is connected", "Touch to take over.",
                  "Pair with your computer", "Waiting for your computer", "Pairing didn’t work", "Can’t control %@", "Can’t show the screen",
                  "Retry", "Scan Code", "Try Another Computer", "Connected to %@"] {
            let zh = (((all[k] as? [String: Any])?["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let v = zh?["value"] as? String ?? ""
            XCTAssertFalse(v.isEmpty, k)
            XCTAssertFalse(v.contains("！") || v.contains("!"), v)
            XCTAssertEqual(v.contains("%@"), k.contains("%@"), k)
        }
    }

    // MARK: the card

    /// The words are read at arm's length: never smaller than body text, and they grow with the system's text size.
    @MainActor
    func testTheCardIsReadingSizeAndGrowsWithTheWords() {
        let card = StatusCard()
        card.show(.busy, StatusCard.Words(title: "Connecting to Studio…"))
        let short = card.height(width: 320)
        card.show(.problem, StatusCard.Words(title: "Can’t reach Studio", detail: "Check that Blurt is running and both are on the same network.",
                                             action: "Retry", second: "Try Another Computer"))
        let tall = card.height(width: 320)
        XCTAssertGreaterThan(tall, short + 100)
        XCTAssertGreaterThan(card.height(width: 240), tall, "narrower, the words wrap")
        let labels = card.subviews.flatMap(\.subviews).compactMap { $0 as? UILabel }
        XCTAssertEqual(labels.count, 2)
        for l in labels {
            // 17 and 15 pt at the system's standard text size, more when the user asks for more
            if UIApplication.shared.preferredContentSizeCategory == .large { XCTAssertGreaterThanOrEqual(l.font.pointSize, 15) }
            XCTAssertTrue(l.adjustsFontForContentSizeCategory)
        }
        XCTAssertFalse(card.show(.problem, card.words), "the same words again are no news")
        XCTAssertTrue(card.show(nil, nil))
    }

    /// Every card, drawn: set TEST_RUNNER_BLURT_RENDER_DIR to keep the images (as RenderTests), in the language the tests run in.
    @MainActor
    func testRenderEveryCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["BLURT_RENDER_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, LinkStatus, RemoteHost)] = [
            ("unpaired", LinkStatus(phase: .unpaired), .mac),
            ("connecting", LinkStatus(phase: .connecting), .mac),
            ("reconnecting", LinkStatus(phase: .connecting, dropped: true), .mac),
            ("unreachable", LinkStatus(phase: .unreachable), .mac),
            ("unreachable-relay-others", LinkStatus(phase: .unreachable, hasRelay: true, otherComputers: true), .windows),
            ("forgotten", LinkStatus(phase: .forgotten), .mac),
            ("replaced", LinkStatus(phase: .replaced), .mac),
            ("waiting", LinkStatus(phase: .unpaired, waiting: true), .mac),
            ("pair-failed", LinkStatus(phase: .unpaired, pairFailed: true), .mac),
            ("pair-unreachable", LinkStatus(phase: .unreachable, pairFailed: true, pairRetry: true), .mac),
            ("cant-control-mac", LinkStatus(phase: .connected, canControl: false), .mac),
            ("cant-control-windows", LinkStatus(phase: .connected, canControl: false), .windows),
            ("screen-permission", LinkStatus(phase: .connected, screenError: "permission"), .mac),
            ("screen-off", LinkStatus(phase: .connected, screenError: "off"), .linux),
        ]
        let name = "Studio Mac"
        for (file, s, host) in cases {
            guard let b = StatusBanner.of(s) else { continue }
            func say(_ l: StatusBanner.Line) -> String {
                Words.status(l, host: host, name: name, check: "4821",
                             failed: Link.failure(s.pairRetry ? .unreachable : .spent, name: name, hasRelay: s.hasRelay))
            }
            let card = StatusCard()
            card.show(b.mark, StatusCard.Words(title: say(b.title), detail: b.detail.map(say), action: b.action.map { Words.status($0) },
                                               second: b.second.map { Words.status($0) }))
            let w: CGFloat = 338, h = card.height(width: w)
            let back = UIView(frame: CGRect(x: 0, y: 0, width: w + 32, height: h + 32))
            back.backgroundColor = Theme.glass
            back.overrideUserInterfaceStyle = .dark
            card.frame = CGRect(x: 16, y: 16, width: w, height: h)
            card.alpha = 1
            card.isHidden = false
            back.addSubview(card)
            back.layoutIfNeeded()
            let f = UIGraphicsImageRendererFormat()
            f.scale = 3
            let image = UIGraphicsImageRenderer(size: back.bounds.size, format: f).image { back.layer.render(in: $0.cgContext) }
            try image.pngData()?.write(to: dir.appendingPathComponent("card-\(language)-\(file).png"))
        }
    }
}
