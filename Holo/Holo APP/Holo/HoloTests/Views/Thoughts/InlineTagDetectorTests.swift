//
//  InlineTagDetectorTests.swift
//  HoloTests
//
//  内联标签检测器（路径化 + 触发条件收紧）与标签归一化测试
//

import XCTest
@testable import Holo

final class InlineTagDetectorTests: XCTestCase {

    // MARK: - 路径提取

    func testExtractsSingleLevelTag() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "今天记录 #产品 的进展"), ["产品"])
    }

    func testExtractsMultiLevelPath() {
        XCTAssertEqual(
            InlineTagDetector.extractTags(from: "设计 #工作/Holo/编辑器 方案"),
            ["工作/Holo/编辑器"]
        )
    }

    func testExtractsMultipleTagsAndDeduplicates() {
        let tags = InlineTagDetector.extractTags(from: "#工作 和 #灵感，再提 #工作")
        XCTAssertEqual(tags, ["工作", "灵感"])
    }

    func testExtractDeduplicatesByNormalizedKey() {
        let tags = InlineTagDetector.extractTags(from: "#工作/Holo 与 #工作/holo")
        XCTAssertEqual(tags, ["工作/Holo"])
    }

    // MARK: - 触发条件收紧

    func testDoesNotExtractTagAfterLetter() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "abc#产品"), [])
    }

    func testDoesNotExtractTagInURL() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "https://example.com/#page"), [])
    }

    func testExtractsTagAtTextStart() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "#产品 计划"), ["产品"])
    }

    func testExtractsTagAfterChinesePunctuation() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "记录一下，#产品"), ["产品"])
    }

    func testExtractsTagAfterNewline() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "第一行\n#产品"), ["产品"])
    }

    func testDoesNotExtractHashFollowedByNumber() {
        XCTAssertEqual(InlineTagDetector.extractTags(from: "#123"), [])
    }

    // MARK: - 光标检测

    func testCursorInsidePathTagReturnsPartialPath() {
        let content = "记录 #工作/Ho"
        let cursor = (content as NSString).length
        XCTAssertEqual(InlineTagDetector.currentTagAtCursor(content: content, cursorPosition: cursor), "工作/Ho")
    }

    func testCursorAfterLetterPrefixedHashReturnsNil() {
        let content = "abc#产品"
        let cursor = (content as NSString).length
        XCTAssertNil(InlineTagDetector.currentTagAtCursor(content: content, cursorPosition: cursor))
    }

    func testCursorOutsideTagReturnsNil() {
        XCTAssertNil(InlineTagDetector.currentTagAtCursor(content: "普通文本", cursorPosition: 2))
    }
}

final class ThoughtTagNormalizerTests: XCTestCase {

    func testDisplayPathTrimsSegmentsAndDropsEmpty() {
        XCTAssertEqual(ThoughtTagNormalizer.displayPath("#工作 / Holo／编辑器 "), "工作/Holo/编辑器")
    }

    func testKeyIsSegmentWiseNormalized() {
        XCTAssertEqual(ThoughtTagNormalizer.key("工作 /Holo"), ThoughtTagNormalizer.key("工作/holo"))
    }

    func testSingleNameKeyUnchanged() {
        XCTAssertEqual(ThoughtTagNormalizer.key("产品"), "产品")
    }

    func testParentKey() {
        XCTAssertEqual(ThoughtTagNormalizer.parentKey("工作/Holo/编辑器"), "工作/holo")
        XCTAssertNil(ThoughtTagNormalizer.parentKey("工作"))
    }

    func testLastSegment() {
        XCTAssertEqual(ThoughtTagNormalizer.lastSegment("工作/Holo/编辑器"), "编辑器")
        XCTAssertEqual(ThoughtTagNormalizer.lastSegment("工作"), "工作")
    }
}
