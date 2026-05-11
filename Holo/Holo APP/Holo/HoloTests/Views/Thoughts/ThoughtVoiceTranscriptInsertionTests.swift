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
}
