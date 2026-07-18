//
//  TriggerDetectorTests.swift
//  HoloTests
//
//  编辑器 #/@ 触发检测器测试
//

import XCTest
@testable import Holo

final class TriggerDetectorTests: XCTestCase {

    private func detect(_ text: String, cursor: Int? = nil) -> EditorTriggerContext? {
        let nsText = text as NSString
        return TriggerDetector.detect(text: nsText, cursor: cursor ?? nsText.length)
    }

    // MARK: - # 标签触发

    func testBareHashAtTextStartTriggers() {
        guard case .tag(_, let query) = detect("#") else {
            return XCTFail("文首 # 应触发标签搜索")
        }
        XCTAssertEqual(query, "")
    }

    func testHashAfterSpaceTriggers() {
        guard case .tag(_, let query) = detect("今天记录 #") else {
            return XCTFail("空格后 # 应触发")
        }
        XCTAssertEqual(query, "")
    }

    func testHashWithQuery() {
        guard case .tag(_, let query) = detect("今天记录 #产品") else {
            return XCTFail("应触发")
        }
        XCTAssertEqual(query, "产品")
    }

    func testHashWithPathQuery() {
        guard case .tag(_, let query) = detect("#工作/Ho") else {
            return XCTFail("路径关键词应触发")
        }
        XCTAssertEqual(query, "工作/Ho")
    }

    func testHashAfterChinesePunctuationTriggers() {
        guard case .tag = detect("记录一下，#产品") else {
            return XCTFail("中文标点后 # 应触发")
        }
    }

    // MARK: - @ 引用触发

    func testAtMentionTriggers() {
        guard case .reference(_, let query) = detect("这个想法和 @标签") else {
            return XCTFail("@ 应触发引用搜索")
        }
        XCTAssertEqual(query, "标签")
    }

    // MARK: - 不触发场景

    func testHashAfterLetterDoesNotTrigger() {
        XCTAssertNil(detect("abc#产品"))
    }

    func testHashInURLDoesNotTrigger() {
        XCTAssertNil(detect("https://example.com/#page"))
    }

    func testHashFollowedByNumberDoesNotTrigger() {
        XCTAssertNil(detect("#123"))
    }

    func testNoTriggerInPlainText() {
        XCTAssertNil(detect("普通文本"))
    }

    func testSpaceEndsTrigger() {
        XCTAssertNil(detect("#产品 后"))
    }

    func testNewlineEndsTrigger() {
        XCTAssertNil(detect("#产品\n后"))
    }

    // MARK: - 光标位置

    func testCursorAwayFromTriggerReturnsNil() {
        // 光标在「后」字后（已离开 # 片段）
        let text = "#产品 后"
        XCTAssertNil(detect(text, cursor: (text as NSString).length))
    }

    func testCursorInsideTriggerQuery() {
        let text = "#工作/Holo"
        let cursor = 4 // 「/」之后
        guard case .tag(let range, let query) = detect(text, cursor: cursor) else {
            return XCTFail("光标在关键词中间应触发")
        }
        XCTAssertEqual(query, "工作/")
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, cursor)
    }
}
