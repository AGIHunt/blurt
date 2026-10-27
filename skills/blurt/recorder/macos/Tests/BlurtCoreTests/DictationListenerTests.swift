// Which listener hears the dictation key (BlurtCore/DictationListener.swift, docs/design/dictation.md §Trigger): the
// tap made before Input Monitoring was granted is made again once it is, the Accessibility monitor stands in without
// Input Monitoring, and there is never more than one listener.
import XCTest
@testable import BlurtCore

final class DictationListenerTests: XCTestCase {
    func L(_ im: Bool, _ ax: Bool, tap: Bool = false, made: Bool = false, monitor: Bool = false, fn: Bool = false,
           filter: Bool = false) -> DictationListener {
        DictationListener(inputMonitoring: im, accessibility: ax, tap: tap, tapMadeWithAccess: made, monitor: monitor,
                          wantsFilter: fn, tapIsFilter: filter)
    }

    /// Carries out a plan on the state the way DictationKeys does; `tapWorks` = what tapCreate answers.
    func run(_ s: DictationListener, tapWorks: Bool = true, filterWorks: Bool = true) -> (DictationListener, [DictationListenerStep]) {
        var s = s
        var steps = s.plan()
        var done: [DictationListenerStep] = []
        while let step = steps.first {
            steps.removeFirst()
            done.append(step)
            var failed = false
            switch step {
            case .createTap, .recreateTap:
                s.tap = tapWorks
                s.tapIsFilter = false
                s.tapMadeWithAccess = tapWorks && s.inputMonitoring
                failed = !tapWorks
            case .createFilterTap, .recreateFilterTap:
                s.tap = filterWorks
                s.tapIsFilter = filterWorks
                s.tapMadeWithAccess = filterWorks && s.accessibility
                if !filterWorks { s.wantsFilter = false; steps = s.plan() }   // what DictationKeys does: refused, the rest
            case .removeTap: s.tap = false; s.tapMadeWithAccess = false; s.tapIsFilter = false
            case .installMonitor: s.monitor = true
            case .removeMonitor: s.monitor = false
            }
            if failed && steps.isEmpty { steps = s.plan(tapFailed: true) }
            XCTAssertLessThan(done.count, 6)
        }
        return (s, done)
    }

    func testTapMadeBeforeTheGrantIsMadeAgain() {
        // launch without Input Monitoring: macOS still hands out a tap, but it only hears Blurt
        var (s, steps) = run(L(false, false))
        XCTAssertEqual(steps, [.createTap])
        XCTAssertEqual(s.kind, .tapLocal)
        XCTAssertFalse(s.kind.global)
        XCTAssertTrue(s.shouldPoll)
        XCTAssertEqual(s.plan(), [])                        // nothing changes while nothing is granted
        // the user grants Input Monitoring: the next poll (or Blurt being activated) tears it down and makes it again
        s.inputMonitoring = true
        XCTAssertEqual(s.plan(), [.recreateTap])
        (s, steps) = run(s)
        XCTAssertEqual(s.kind, .tap)
        XCTAssertTrue(s.kind.global)
        XCTAssertFalse(s.shouldPoll)
        XCTAssertEqual(s.plan(), [])
    }

    func testGrantedAtLaunch() {
        let (s, steps) = run(L(true, false))
        XCTAssertEqual(steps, [.createTap])
        XCTAssertEqual(s.kind, .tap)
    }

    func testAccessibilityAloneUsesTheMonitor() {
        let (s, steps) = run(L(false, true))
        XCTAssertEqual(steps, [.installMonitor])
        XCTAssertEqual(s.kind, .monitor)
        XCTAssertTrue(s.kind.global)
        XCTAssertTrue(s.shouldPoll)                         // still waiting for a real tap
        // a Blurt-only tap made earlier goes: Blurt's own keys would come twice
        let (s2, steps2) = run(L(false, true, tap: true))
        XCTAssertEqual(steps2, [.removeTap, .installMonitor])
        XCTAssertFalse(s2.tap); XCTAssertTrue(s2.monitor)
        // Input Monitoring arrives: the tap takes over, the monitor goes
        var s3 = s2
        s3.inputMonitoring = true
        let (s4, steps4) = run(s3)
        XCTAssertEqual(steps4, [.removeMonitor, .createTap])
        XCTAssertEqual(s4.kind, .tap); XCTAssertFalse(s4.monitor)
    }

    func testTapRefusedFallsBackToTheMonitor() {
        let (s, steps) = run(L(true, true), tapWorks: false)
        XCTAssertEqual(steps, [.createTap, .installMonitor])
        XCTAssertEqual(s.kind, .monitor)
        let (s2, steps2) = run(L(true, false), tapWorks: false)
        XCTAssertEqual(steps2, [.createTap])
        XCTAssertEqual(s2.kind, .none)
    }

    func testPermissionsTakenAway() {
        // Accessibility revoked while the monitor ran: back to a tap that hears Blurt
        let (s, steps) = run(L(false, false, monitor: true))
        XCTAssertEqual(steps, [.removeMonitor, .createTap])
        XCTAssertEqual(s.kind, .tapLocal)
        // a tap whose grant was revoked isn't global any more (macOS stops feeding it): the cues come back, and
        // with Accessibility the monitor takes over from it
        XCTAssertEqual(L(false, false, tap: true, made: true).plan(), [])
        XCTAssertEqual(L(false, false, tap: true, made: true).kind, .tapLocal)
        XCTAssertTrue(L(false, false, tap: true, made: true).shouldPoll)
        let (s2, steps2) = run(L(false, true, tap: true, made: true))
        XCTAssertEqual(steps2, [.removeTap, .installMonitor])
        XCTAssertEqual(s2.kind, .monitor)
    }

    func testAccessGoesByTheListenerNotTheTap() {
        // the old status said "installed" for a Blurt-only tap; the access the cues use now says it needs setup
        let local = L(false, false, tap: true)
        XCTAssertTrue(DictationAccess(enabled: true, tapInstalled: local.kind.global).needsSetup)
        XCTAssertFalse(DictationAccess(enabled: true, tapInstalled: L(true, false, tap: true, made: true).kind.global).needsSetup)
        XCTAssertFalse(DictationAccess(enabled: true, tapInstalled: L(false, true, monitor: true).kind.global).needsSetup)
        XCTAssertEqual(DictationListenerKind.tapLocal.rawValue, "tap_local")
    }

    // MARK: the Fn filter (an active tap on Accessibility)

    func testFnWithAccessibilityUsesTheFilter() {
        // Fn, Accessibility only: the filter hears every app without Input Monitoring, and keeps Fn from macOS
        let (s, steps) = run(L(false, true, fn: true))
        XCTAssertEqual(steps, [.createFilterTap])
        XCTAssertEqual(s.kind, .tap)
        XCTAssertTrue(s.filtering)
        XCTAssertFalse(s.shouldPoll)
        XCTAssertEqual(s.plan(), [])
    }

    func testFilterReplacesTheMonitorAndTheListenOnlyTap() {
        let (s, steps) = run(L(false, true, monitor: true, fn: true))
        XCTAssertEqual(steps, [.removeMonitor, .createFilterTap])
        XCTAssertFalse(s.monitor)
        let (s2, steps2) = run(L(true, true, tap: true, made: true, fn: true))
        XCTAssertEqual(steps2, [.recreateFilterTap])
        XCTAssertTrue(s2.filtering)
        // a Blurt-only tap made before anything was granted: Accessibility arrives, the filter takes over
        var s3 = run(L(false, false, fn: true)).0
        XCTAssertEqual(s3.kind, .tapLocal)
        s3.accessibility = true
        XCTAssertEqual(s3.plan(), [.recreateFilterTap])
    }

    func testFilterWaitsForAccessibility() {
        // Fn without Accessibility: the usual listen-only plan (Input Monitoring), no filter
        let (s, steps) = run(L(true, false, fn: true))
        XCTAssertEqual(steps, [.createTap])
        XCTAssertEqual(s.kind, .tap)
        XCTAssertFalse(s.filtering)
    }

    func testFilterGoesWhenNotWanted() {
        // another key picked: the filter goes and the listen-only tap comes back
        let (s, steps) = run(L(true, true, tap: true, made: true, fn: false, filter: true))
        XCTAssertEqual(steps, [.removeTap, .createTap])
        XCTAssertFalse(s.filtering)
        XCTAssertEqual(s.kind, .tap)
        // Accessibility revoked under the filter: it isn't global any more, and goes; nothing else is granted
        let revoked = L(false, false, tap: true, made: true, fn: true, filter: true)
        XCTAssertEqual(revoked.kind, .tapLocal)
        XCTAssertEqual(revoked.plan(), [.removeTap, .createTap])
    }

    func testFilterRefusedFallsBack() {
        let (s, steps) = run(L(false, true, fn: true), filterWorks: false)
        XCTAssertEqual(steps, [.createFilterTap, .installMonitor])
        XCTAssertEqual(s.kind, .monitor)
        let (s2, steps2) = run(L(true, true, fn: true), filterWorks: false)
        XCTAssertEqual(steps2, [.createFilterTap, .createTap])
        XCTAssertEqual(s2.kind, .tap)
        XCTAssertFalse(s2.filtering)
    }
}
