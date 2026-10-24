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

    // MARK: a seam is a pause, not a sentence end (synthetic sentences shaped like the user's reports)

    typealias S = DictationStitch

    func testABreathLeavesNoFullStop() {
        XCTAssertEqual(S.joinPieces(["我刚才看了一下日志，好像是因为。", "网络断开以后没有重新连接。", "所以后面的请求都失败了。"],
                                    pauses: [0.7, 0.8]),
                       "我刚才看了一下日志，好像是因为网络断开以后没有重新连接所以后面的请求都失败了。")
        // a comma the cut made goes too (polish puts back the ones that belong)
        XCTAssertEqual(S.joinPieces(["这个新功能确实挺顺手，", "出门的时候不用带电脑了。"], pauses: [0.6]),
                       "这个新功能确实挺顺手出门的时候不用带电脑了。")
        // a question mark the cut made, too; the last piece keeps its ending: the dictation ended there
        XCTAssertEqual(S.joinPieces(["你是不是为了让速度更快？", "所以一边录一边处理的？"], pauses: [0.7]),
                       "你是不是为了让速度更快所以一边录一边处理的？")
        // not known (still quiet when the next piece was transcribed): a breath
        XCTAssertEqual(S.joinPieces(["我们先开个短会。", "把内容再过一遍。"], pauses: [nil]), "我们先开个短会把内容再过一遍。")
        // mixed Chinese and English
        XCTAssertEqual(S.joinPieces(["我在 Claude Code 里面。", "让它写了一个 Python 脚本。"], pauses: [0.8]),
                       "我在 Claude Code 里面让它写了一个 Python 脚本。")
    }

    func testALongPauseAfterAWholeSentenceEndsIt() {
        XCTAssertEqual(S.joinPieces(["回到办公室以后再慢慢整理也来得及。", "下午我们再开会。"], pauses: [1.4]),
                       "回到办公室以后再慢慢整理也来得及。下午我们再开会。")
        XCTAssertEqual(S.joinPieces(["The report looks good overall.", "Thanks for your help."], pauses: [1.5]),
                       "The report looks good overall. Thanks for your help.")
        // long, but the sentence isn't whole: a comma (when there was punctuation), never a full stop
        XCTAssertEqual(S.joinPieces(["最好在设置页面里也。", "加上一个开关。"], pauses: [1.5]), "最好在设置页面里也，加上一个开关。")
        XCTAssertEqual(S.joinPieces(["但是呢。", "它识别出来的文字有问题。"], pauses: [1.3]), "但是呢，它识别出来的文字有问题。")
        XCTAssertEqual(S.joinPieces(["The only problem is.", "That the page is old."], pauses: [1.4]),
                       "The only problem is, that the page is old.")
        // exactly the threshold counts as long; just under it doesn't
        XCTAssertEqual(S.joinPieces(["我们明天上午十点开会。", "下午修问题。"], pauses: [S.longPause]), "我们明天上午十点开会。下午修问题。")
        XCTAssertEqual(S.joinPieces(["我们明天上午十点开会。", "下午修问题。"], pauses: [1.19]), "我们明天上午十点开会下午修问题。")
    }

    func testEnglishLosesTheCapitalTheCutGaveIt() {
        XCTAssertEqual(S.joinPieces(["I tried the new build this morning.", "And it was a lot faster.", "Than the old one."],
                                    pauses: [0.7, 0.8]),
                       "I tried the new build this morning and it was a lot faster than the old one.")
        // names, acronyms and "I" keep theirs
        XCTAssertEqual(S.joinPieces(["We should move the meeting to.", "Thursday afternoon."], pauses: [0.7]),
                       "We should move the meeting to Thursday afternoon.")
        XCTAssertEqual(S.joinPieces(["Yesterday,", "I fixed the login bug."], pauses: [0.7]), "Yesterday I fixed the login bug.")
        XCTAssertEqual(S.decapitalize("API keys rotate daily"), "API keys rotate daily")
        XCTAssertEqual(S.decapitalize("GitHub is down"), "GitHub is down")
        XCTAssertEqual(S.decapitalize("I'm on it"), "I'm on it")
        XCTAssertEqual(S.decapitalize("Than the old one"), "than the old one")
        XCTAssertEqual(S.decapitalize("Don't merge yet"), "don't merge yet")
        XCTAssertEqual(S.decapitalize("Send it"), "send it")
        XCTAssertEqual(S.decapitalize("Send it", names: ["Send"]), "Send it")        // a custom word
        XCTAssertEqual(S.decapitalize("下午再说"), "下午再说")
    }

    func testPlausiblyFinal() {
        XCTAssertTrue(S.plausiblyFinal("回到办公室以后再整理也来得及", end: "。"))
        XCTAssertTrue(S.plausiblyFinal("你能帮我看一下这个问题吗", end: "？"))
        XCTAssertTrue(S.plausiblyFinal("The report looks good overall", end: "."))
        XCTAssertTrue(S.plausiblyFinal("I will add it to the shared folder, myself", end: "."))   // the sentence counts
        XCTAssertFalse(S.plausiblyFinal("这个功能确实很顺手。但是呢", end: "。"))               // only the last sentence
        XCTAssertFalse(S.plausiblyFinal("回到办公室以后再整理也来得及", end: "，"))     // a comma isn't an end
        XCTAssertFalse(S.plausiblyFinal("回到办公室以后再整理也来得及", end: ""))
        XCTAssertFalse(S.plausiblyFinal("我们出门的时候", end: "。"))                   // a time clause waits for more
        XCTAssertFalse(S.plausiblyFinal("好像它是", end: "。"))
        XCTAssertFalse(S.plausiblyFinal("如果是这样的话", end: "。"))
        XCTAssertFalse(S.plausiblyFinal("但是呢", end: "。"))                           // a stub
        XCTAssertFalse(S.plausiblyFinal("所以说呢", end: "。"))
        XCTAssertFalse(S.plausiblyFinal("I think the problem is", end: "."))
        XCTAssertFalse(S.plausiblyFinal("and then", end: "."))
        XCTAssertFalse(S.plausiblyFinal("it was faster than the", end: "."))
    }

    func testCommitSplitKeepsTheUnfinishedClause() {
        var r = S.commitSplit("明天上午开个短会，把内容再过一遍。下午的时间")
        XCTAssertEqual(r.commit, "明天上午开个短会，把内容再过一遍。")
        XCTAssertEqual(r.carry, "下午的时间")
        XCTAssertEqual(r.end, "")
        // a comma inside the window was decided with both sides in view: committed; the clause after it is carried
        r = S.commitSplit("我刚才看了一下日志，好像是因为网络断开")
        XCTAssertEqual(r.commit, "我刚才看了一下日志，")
        XCTAssertEqual(r.carry, "好像是因为网络断开")
        // only sentence ends, when asked
        r = S.commitSplit("我刚才看了一下日志，好像是因为网络断开", atClauses: false)
        XCTAssertEqual(r.commit, "")
        XCTAssertEqual(r.carry, "我刚才看了一下日志，好像是因为网络断开")
        // the window's own ending was a pause: carried, its full stop kept aside
        r = S.commitSplit("我们先开个短会。")
        XCTAssertEqual(r.commit, "")
        XCTAssertEqual(r.carry, "我们先开个短会")
        XCTAssertEqual(r.end, "。")
        r = S.commitSplit("The report looks good. But the numbers in v2.5 don't match.")
        XCTAssertEqual(r.commit, "The report looks good.")
        XCTAssertEqual(r.carry, "But the numbers in v2.5 don't match")
        XCTAssertEqual(r.end, ".")
        r = S.commitSplit("It costs 1,000 dollars at 10:30, and then we")
        XCTAssertEqual(r.commit, "It costs 1,000 dollars at 10:30,")
        XCTAssertEqual(r.carry, "and then we")
        r = S.commitSplit("他说：“好的。”然后就走了，")
        XCTAssertEqual(r.commit, "他说：“好的。”")
        XCTAssertEqual(r.carry, "然后就走了")
        XCTAssertEqual(r.end, "，")
        XCTAssertEqual(S.commitSplit("").commit, "")
    }

    // MARK: the fixture shared with scripts/dictation_stitch.py (the Dictation Lab's replay of the windows)

    func testSharedSeamFixture() throws {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        let rows = try String(contentsOf: u.appendingPathComponent("tests/fixtures/dictation_seams.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertGreaterThanOrEqual(rows.count, 30)
        for r in rows {
            let fn = r["fn"] as! String
            let pauses = (r["pauses"] as? [Any])?.map { $0 as? Double }
            switch fn {
            case "joinPieces":
                XCTAssertEqual(S.joinPieces(r["texts"] as! [String], pauses: pauses!), r["want"] as? String, "\(r)")
            case "joinPiecesForFallback":
                XCTAssertEqual(S.joinPiecesForFallback(r["texts"] as! [String], pauses: pauses!), r["want"] as? String, "\(r)")
            case "fallbackSeam":
                XCTAssertEqual(S.fallbackSeam(r["previous"] as! String, r["next"] as! String, pause: r["pause"] as? Double,
                                              heardEnd: r["heard"] as! String), r["want"] as? String, "\(r)")
            case "commaJoin":
                XCTAssertEqual(S.commaJoin(r["a"] as! String, r["b"] as! String), r["want"] as? String, "\(r)")
            case "commitSplit":
                let s = S.commitSplit(r["text"] as! String)
                XCTAssertEqual([s.commit, s.carry, s.end], r["want"] as? [String], "\(r)")
            case "decapitalize":
                XCTAssertEqual(S.decapitalize(r["text"] as! String), r["want"] as? String, "\(r)")
            case "midSentence":
                XCTAssertEqual(S.midSentence(r["text"] as! String), r["want"] as? Bool, "\(r)")
            case "startsWithCorrection":
                XCTAssertEqual(S.startsWithCorrection(r["text"] as! String), r["want"] as? Bool, "\(r)")
            case "endsWithCorrection":
                XCTAssertEqual(S.endsWithCorrection(r["text"] as! String), r["want"] as? Bool, "\(r)")
            case "keepCase":
                XCTAssertEqual(S.keepCase(input: r["input"] as! String, output: r["output"] as! String), r["want"] as? String, "\(r)")
            default:
                XCTFail("unknown fn \(fn)")
            }
        }
    }

    func testAFallBackSeamGetsAComma() {
        // the bug: a refused window typed 「…跑完第二，…」
        XCTAssertEqual(S.fallbackSeam("第一，把测试全部跑完", "第二把文档更新一下", pause: 0.7, heardEnd: "。"),
                       "第一，把测试全部跑完，第二把文档更新一下")
        XCTAssertEqual(S.fallbackSeam("我们把", "测试跑完", pause: 0.7, heardEnd: "，"), "我们把测试跑完")   // 把 binds
        XCTAssertTrue(S.binds("send it to the"))
        XCTAssertFalse(S.binds("把测试全部跑完"))
    }

    func testTerminatorFollowsTheScript() {
        XCTAssertEqual(S.terminator(".", after: "我们下午开会"), "。")
        XCTAssertEqual(S.terminator("？", after: "Can you check"), "?")
        XCTAssertEqual(S.terminator("", after: "Done"), ".")
    }
}
