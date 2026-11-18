// BlurtCore/OnboardingFlow.swift: the setup assistant follows the capability switches — dictation's three steps only
// while Dictation is on, and nothing of dictation's fetched before the first run's first step is answered.
import XCTest
@testable import BlurtCore

final class OnboardingFlowTests: XCTestCase {
    func testFourStepsWithDictationOneWithout() {
        XCTAssertEqual(OnboardingFlow.steps(off: []), 4)
        XCTAssertEqual(OnboardingFlow.steps(off: [.cards, .screenText, .recording, .phone]), 4, "only Dictation on: still its three steps")
        XCTAssertEqual(OnboardingFlow.steps(off: [.dictation]), 1)
        XCTAssertEqual(OnboardingFlow.steps(off: Set(Capability.allCases)), 1)
        XCTAssertLessThanOrEqual(OnboardingFlow.allSteps, 4, "the assistant stays four steps or fewer")
    }

    func testAStepThatIsGoneBecomesTheFirst() {
        XCTAssertEqual(OnboardingFlow.clamp(2, off: []), 2)
        XCTAssertEqual(OnboardingFlow.clamp(9, off: []), 3)
        XCTAssertEqual(OnboardingFlow.clamp(-1, off: []), 0)
        // "Set Up Speech…" or a resumed first run on the models step, with Dictation switched off since
        XCTAssertEqual(OnboardingFlow.clamp(2, off: [.dictation]), 0)
    }

    func testTheLastStep() {
        XCTAssertTrue(OnboardingFlow.isLast(3, off: []))
        XCTAssertFalse(OnboardingFlow.isLast(0, off: []))
        XCTAssertTrue(OnboardingFlow.isLast(0, off: [.dictation]), "Dictation off: the first step ends the assistant")
    }

    func testNothingOfDictationsIsFetchedBeforeTheFirstStepIsAnswered() {
        // the first run, still on "what do you want to use": not yet
        XCTAssertFalse(OnboardingFlow.setsUpDictation(off: [], firstRun: true, step: 0))
        // …past it with Dictation on: now
        XCTAssertTrue(OnboardingFlow.setsUpDictation(off: [], firstRun: true, step: 1))
        // switched off there: never
        for step in 0...3 { XCTAssertFalse(OnboardingFlow.setsUpDictation(off: [.dictation], firstRun: true, step: step)) }
        XCTAssertFalse(OnboardingFlow.setsUpDictation(off: [.dictation], firstRun: false, step: 0))
        // opened again later from Settings: as before, the models are read as it opens
        XCTAssertTrue(OnboardingFlow.setsUpDictation(off: [], firstRun: false, step: 0))
    }

    func testTheCardIsTaughtOnTryItWhileCardsIsOn() {
        XCTAssertTrue(OnboardingFlow.teachesCard(off: [], step: 3))
        XCTAssertFalse(OnboardingFlow.teachesCard(off: [.cards], step: 3))
        XCTAssertFalse(OnboardingFlow.teachesCard(off: [], step: 2))
        XCTAssertFalse(OnboardingFlow.teachesCard(off: [.dictation], step: 0), "its row on the first step says it there")
    }
}
