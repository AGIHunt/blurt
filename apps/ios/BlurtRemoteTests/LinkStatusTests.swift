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
                       "Can’t connect directly. Try another network, or set up your own relay on the computer.")
        XCTAssertEqual(Words.status(.goBetweenBusy, host: .windows, name: "PC"), "The public connection service has reached today’s limit. Try again later, or use your own relay.")
    }

    func testPairingStates() {
        XCTAssertEqual(banner(.unpaired), StatusBanner(mark: .code, title: .pairFirst, detail: .whereTheCodeIs, action: .scan))
        XCTAssertEqual(banner(.forgotten), StatusBanner(mark: .problem, title: .needsPairing, detail: .forgotten, action: .scan))
        // a button, never any touch: a phone in a pocket doesn't take the computer back
        XCTAssertEqual(banner(.replaced), StatusBanner(mark: .phone, title: .otherPhone, action: .takeOver))
        XCTAssertEqual(banner(.ended), StatusBanner(mark: .phone, title: .endedThere, action: .reconnect))
    }

    func testMeetingOnThePublicServiceIsNotConnectedYet() {
        XCTAssertEqual(banner(.connecting) { $0.meeting = true }, StatusBanner(mark: .busy, title: .connectingDirect))
        XCTAssertEqual(banner(.connecting) { $0.meeting = true; $0.dropped = true }?.title, .connectingDirect)
    }

    func testAPhoneWithNoNetworkSaysSoFirst() {
        let b = StatusBanner(mark: .problem, title: .noNetwork, detail: .turnOnNetwork)
        XCTAssertEqual(banner(.connecting) { $0.offline = true }, b)
        XCTAssertEqual(banner(.unreachable) { $0.offline = true; $0.away = .noDirect; $0.hasRelay = true }, b)
        XCTAssertNil(banner(.connected) { $0.offline = true }, "a session over something else goes on")
    }

    func testWhyItCantBeReachedFromItsRelay() {
        XCTAssertEqual(banner(.unreachable) { $0.hasRelay = true; $0.presence = .asleep }?.detail, .asleepSince)
        XCTAssertEqual(banner(.unreachable) { $0.hasRelay = true; $0.presence = .lastOnline }?.detail, .lastOnline)
        XCTAssertEqual(banner(.unreachable) { $0.hasRelay = true; $0.presence = .asleep; $0.away = .noDirect }?.detail, .noDirect, "the reason that's known wins")
        XCTAssertEqual(banner(.unreachable) { $0.localDenied = true },
                       StatusBanner(mark: .problem, title: .cantReach, detail: .localNetworkOff, action: .openSettings, second: .retry))
        XCTAssertEqual(banner(.unreachable) { $0.localDenied = true; $0.hasRelay = true }?.detail, .checkAwake, "a relay needs no local network")
    }

    func testALockedScreenIsSaidWhileThePictureIsOn() {
        XCTAssertEqual(banner(.connected) { $0.locked = true; $0.showing = true; $0.canControl = false },
                       StatusBanner(mark: .problem, title: .locked, detail: .unlockFirst))
        XCTAssertNil(banner(.connected) { $0.locked = true })
    }

    func testAPairingUnderWayIsSaidOverTheRest() {
        // the digits first: this side says they're the same (anyone with a photo of the code can answer as the computer), then the computer
        for p in [LinkStatus.Phase.unpaired, .connecting, .unreachable, .connected] {
            XCTAssertEqual(banner(p) { $0.waiting = true },
                           StatusBanner(mark: .code, title: .checkDigits, detail: .pairIfSame, action: .pair, second: .cancelPairing), "\(p)")
            XCTAssertEqual(banner(p) { $0.waiting = true; $0.digitsConfirmed = true }, StatusBanner(mark: .busy, title: .waiting, detail: .allowOnComputer), "\(p)")
        }
        // one that didn't take: why, and never a dead end: a new code, and what there was to do about the computer gone back to
        // until it's read: OK
        for p in [LinkStatus.Phase.unpaired, .connecting, .connected, .unreachable] {
            XCTAssertEqual(banner(p) { $0.pairFailed = true; $0.otherComputers = true },
                           StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan, second: .dismiss), "\(p)")
        }
        // a code that can't be reached is still being tried: the same code again first, a new one second
        XCTAssertEqual(banner(.unreachable) { $0.pairFailed = true; $0.pairRetry = true },
                       StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .retry, second: .scan))
        // once the computer asks, its digits take the failure's place, so they can be compared
        XCTAssertEqual(banner(.unreachable) { $0.pairFailed = true; $0.pairRetry = true; $0.waiting = true },
                       StatusBanner(mark: .code, title: .checkDigits, detail: .pairIfSame, action: .pair, second: .cancelPairing))
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
        XCTAssertEqual(Link.failure(.unanswered, name: "Studio PC", hasRelay: true).title, "Studio PC didn’t answer in time.")
        let away = Link.failure(.unreachable, name: "Studio PC", hasRelay: true)
        XCTAssertEqual(away.title, "Can’t reach Studio PC.")
        XCTAssertEqual(away.help, "Make sure Studio PC is on and Blurt is open there, or scan the new code.")
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
        XCTAssertEqual(banner(.connected) { $0.screenError = "stopped" }, StatusBanner(mark: .problem, title: .cantShowScreen, detail: .pictureStopped, action: .showScreen))
        // a picture that came on by itself and can't: still a trackpad, nothing to say
        XCTAssertNil(banner(.connected) { $0.screenError = "off"; $0.screenAsked = false })
        // the screen was just asked for: that's the one said
        XCTAssertEqual(banner(.connected) { $0.canControl = false; $0.screenError = "off" }?.detail, .screenIsOff)
        // not connected, neither matters
        XCTAssertEqual(banner(.connecting) { $0.canControl = false; $0.screenError = "off" }, StatusBanner(mark: .busy, title: .connecting))
    }

    /// The public relay has no picture lease free: the card under "Can't show the screen" says so and offers nothing (the picture comes by
    /// itself), even for a picture that came on by itself; it goes when the picture comes (Link clears the error at screenView).
    func testThePublicRelayBusyCardSaysTheRestWorksAndHasNoButton() {
        let busy = StatusBanner(mark: .problem, title: .cantShowScreen, detail: .publicBusy)
        XCTAssertEqual(banner(.connected) { $0.screenError = RemotePublicRelay.busy }, busy)
        XCTAssertEqual(banner(.connected) { $0.screenError = "busy"; $0.screenAsked = false; $0.showing = true }, busy)
        XCTAssertNil(banner(.connected) { $0.screenError = nil; $0.showing = true })
        // not connected: the connection's card, not the picture's
        XCTAssertEqual(banner(.connecting) { $0.screenError = "busy" }, StatusBanner(mark: .busy, title: .connecting))
        XCTAssertEqual(Words.status(.cantShowScreen, host: .linux, name: "PC"), "Can’t show the screen")
        XCTAssertEqual(Words.status(.publicBusy, host: .mac, name: "Studio"),
                       "The public connection service is busy, so there’s no picture for now. The pointer and keys still work.")
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
                    if b.action != nil, b.action != .takeOver { XCTAssertNotNil(b.detail, "\(p)") }
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
                                                     .connectingDirect, .noNetwork, .turnOnNetwork, .asleepSince, .lastOnline, .localNetworkOff, .endedThere,
                                                     .pictureStopped, .locked, .unlockFirst, .pairFirst, .whereTheCodeIs, .waiting, .allowOnComputer, .checkDigits, .pairIfSame, .pairingFailed,
                                                     .whyPairingFailed, .cantControl, .howToAllowControl, .cantShowScreen, .allowScreen, .screenIsOff,
                                                     .publicBusy]

    func testEveryLineHasWordsForEveryKindOfComputer() {
        for h in RemoteHost.allCases {
            for l in Self.lines {
                let t = Words.status(l, host: h, name: "Studio", check: "1234", failed: Link.failure(.declined, name: "Studio", hasRelay: false), since: Date())
                XCTAssertFalse(t.isEmpty, "\(l) \(h)")
                XCTAssertFalse(t.contains("!"), "no shouting: \(t)")
                XCTAssertFalse(t.contains("%@"), t)
            }
            // no name yet: still a sentence
            XCTAssertFalse(Words.status(.cantReach, host: h, name: nil).isEmpty)
        }
        for a in [StatusBanner.Action.retry, .scan, .another, .takeOver, .reconnect, .dismiss, .openSettings, .showScreen, .pair, .cancelPairing] {
            XCTAssertFalse(Words.status(a).isEmpty)
        }
        XCTAssertTrue(Words.status(.connecting, host: .mac, name: "Studio").contains("Studio"))
        // the digits are on the card the user compares and says yes to; the computer's yes is asked for after
        XCTAssertTrue(Words.status(.pairIfSame, host: .mac, name: "Studio", check: "123456").contains("123456"))
        XCTAssertTrue(Words.status(.allowOnComputer, host: .mac, name: "Studio", check: "123456").contains("Studio"))
    }

    /// The catalog itself: what the card says is there in Chinese too.
    func testTheCardsWordsAreTranslated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BlurtRemote/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no catalog beside the tests") }
        let all = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        for k in ["Connecting to %@…", "Reconnecting to %@…", "Can’t reach %@",
                  "Check that Blurt is running and both are on the same network. To connect from anywhere, set a relay in Blurt’s Settings → Remote Control on the computer.",
                  "Check that the computer isn’t asleep and Blurt is running.", "Needs pairing again", "Another phone is connected", "Take Over", "Reconnect", "OK", "Open Settings",
                  "Connecting directly to %@…", "No network", "Turn on Wi-Fi or mobile data to reconnect.",
                  "Asleep since %@. Wake the computer to reconnect.", "%@ is locked", "The picture comes back once it’s unlocked.",
                  "Last online %@. Check that the computer isn’t asleep and Blurt is running.",
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
            ("check-digits", LinkStatus(phase: .unpaired, waiting: true), .mac),
            ("waiting", LinkStatus(phase: .unpaired, waiting: true, digitsConfirmed: true), .mac),
            ("pair-failed", LinkStatus(phase: .unpaired, pairFailed: true), .mac),
            ("pair-unreachable", LinkStatus(phase: .unreachable, pairFailed: true, pairRetry: true), .mac),
            ("cant-control-mac", LinkStatus(phase: .connected, canControl: false), .mac),
            ("cant-control-windows", LinkStatus(phase: .connected, canControl: false), .windows),
            ("screen-permission", LinkStatus(phase: .connected, screenError: "permission"), .mac),
            ("screen-off", LinkStatus(phase: .connected, screenError: "off"), .linux),
            ("no-direct", LinkStatus(phase: .unreachable, hasRelay: true, away: .noDirect), .mac),
            ("no-network", LinkStatus(phase: .unreachable, offline: true), .mac),
            ("asleep", LinkStatus(phase: .unreachable, hasRelay: true, presence: .asleep), .mac),
            ("last-online", LinkStatus(phase: .unreachable, hasRelay: true, presence: .lastOnline), .mac),
            ("connecting-direct", LinkStatus(phase: .connecting, meeting: true), .windows),
            ("ended", LinkStatus(phase: .ended), .windows),
            ("locked", LinkStatus(phase: .connected, showing: true, locked: true), .mac),
            ("picture-stopped", LinkStatus(phase: .connected, screenError: "stopped"), .windows),
            ("local-network-off", LinkStatus(phase: .unreachable, localDenied: true), .mac),
        ]
        let name = "Studio Mac"
        for (file, s, host) in cases {
            guard let b = StatusBanner.of(s) else { continue }
            func say(_ l: StatusBanner.Line) -> String {
                Words.status(l, host: host, name: name, check: "4821",
                             failed: Link.failure(s.pairRetry ? .unreachable : .spent, name: name, hasRelay: s.hasRelay), since: Date())
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
