import XCTest
@testable import BlurtCore

/// Joining a streamed dictation's pieces (docs/design/dictation.md §Streaming): no doubled and no lost words at the
/// seams, spaces only between Latin words.
final class DictationStitchTests: XCTestCase {
    func testJoinSpacesOnlyBetweenLatinWords() {
        XCTAssertEqual(DictationStitch.join("我们先看一下日志。", "然后再部署。"), "我们先看一下日志。然后再部署。")
        XCTAssertEqual(DictationStitch.join("open the PR", "and merge it"), "open the PR and merge it")
        XCTAssertEqual(DictationStitch.join("Open the PR.", "Then merge it."), "Open the PR. Then merge it.")
        XCTAssertEqual(DictationStitch.join("先跑一下 pytest", "然后提交"), "先跑一下 pytest然后提交")
        XCTAssertEqual(DictationStitch.join("把 MCP 的超时改成 30", "秒"), "把 MCP 的超时改成 30秒")
        XCTAssertEqual(DictationStitch.join(["", "第一段。", "", "第二段。"]), "第一段。第二段。")
        XCTAssertEqual(DictationStitch.join("  a  ", "  "), "a")
    }

    func testHardCutDropsTheWordsBothPiecesHeard() {
        // the 0.8 s overlap was heard twice: 「的时候比」 at the end of one and the start of the next
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "我觉得短句的时候比", next: "的时候比 Typeless 要快一点"),
                       "Typeless 要快一点")
        // a half-heard unit in front of the doubled words (the cut went through a syllable)
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "把 worktree 的分支名", next: "名分支名改成 fix"), "改成 fix")
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "we should open the pull", next: "the pull request today"),
                       "request today")
        // case and punctuation don't matter
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "Run it in tmux,", next: "in TMUX, then detach"), "then detach")
    }

    func testNoOverlapLeavesTheTextAlone() {
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "先检查配额", next: "然后跑评测"), "然后跑评测")
        // one shared unit isn't an overlap (的 is everywhere)
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "系统的", next: "的确如此"), "的确如此")
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "", next: "hello world"), "hello world")
        // the same words later in the next piece aren't at its start: kept
        XCTAssertEqual(DictationStitch.dropOverlap(previous: "下午三点", next: "开会，下午三点见"), "开会，下午三点见")
    }

    func testUnits() {
        XCTAssertEqual(DictationStitch.units("我们的API v2 don't").map(\.value), ["我", "们", "的", "api", "v", "2", "don't"])
    }

    func testCorrectionAtTheStartOfAPiece() {
        XCTAssertTrue(DictationStitch.startsWithCorrection("不对，是周四"))
        XCTAssertTrue(DictationStitch.startsWithCorrection("嗯，我是说下周"))
        XCTAssertTrue(DictationStitch.startsWithCorrection("No wait, the right side"))
        XCTAssertFalse(DictationStitch.startsWithCorrection("不对称的布局要改一下"))
        XCTAssertFalse(DictationStitch.startsWithCorrection("然后把 PR 合并"))
        XCTAssertFalse(DictationStitch.startsWithCorrection("sorted by date"))
    }
}
