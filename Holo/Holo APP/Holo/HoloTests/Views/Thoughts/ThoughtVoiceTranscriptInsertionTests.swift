//
//  ThoughtVoiceTranscriptInsertionTests.swift
//  HoloTests
//
//  观点语音输入插入规则测试
//

import XCTest
@testable import Holo

final class ThoughtVoiceTranscriptInsertionTests: XCTestCase {

    func testInsertionTextKeepsTranscriptWhenContentIsEmpty() {
        let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: "今天开始练习更诚实地表达想法",
            currentContent: "",
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result, "今天开始练习更诚实地表达想法")
    }

    func testInsertionTextKeepsTranscriptInsideSentence() {
        let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: "更像是长期节奏问题",
            currentContent: "我以为只是拖延但其实需要拆开看",
            selectedRange: NSRange(location: 7, length: 0)
        )

        XCTAssertEqual(result, "更像是长期节奏问题")
    }

    func testInsertionTextTrimsOuterWhitespaceFromTranscript() {
        let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: "  所以先记录下来\n",
            currentContent: "今天有个判断：",
            selectedRange: NSRange(location: 7, length: 0)
        )

        XCTAssertEqual(result, "所以先记录下来")
    }

    func testInsertionTextAddsParagraphBreaksForLongTranscript() {
        let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: "我今天突然意识到自己不是不想做这件事，而是每次开始之前都会把目标想得太大，结果还没动手就已经觉得累了。所以后面我可能要把第一步拆得更小一点，先让自己进入状态，再考虑完整计划。这样至少不会一直停在准备阶段。",
            currentContent: "",
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(
            result,
            """
            我今天突然意识到自己不是不想做这件事，而是每次开始之前都会把目标想得太大，结果还没动手就已经觉得累了。

            所以后面我可能要把第一步拆得更小一点，先让自己进入状态，再考虑完整计划。

            这样至少不会一直停在准备阶段。
            """
        )
    }

    func testInsertionTextKeepsShortTranscriptAsSingleParagraph() {
        let result = ThoughtVoiceTranscriptInsertion.makeInsertionText(
            transcript: "今天先记一个判断，问题不是拖延，而是入口太重。",
            currentContent: "",
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result, "今天先记一个判断，问题不是拖延，而是入口太重。")
    }
}
