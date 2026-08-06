//
//  ThoughtTagNormalizerTests.swift
//  HoloTests
//
//  标签归一化测试：验证 key 计算的空格折叠、大小写/全半角回归、路径段独立归一。
//

import XCTest
@testable import Holo

final class ThoughtTagNormalizerTests: XCTestCase {

    // MARK: - 删空格（本次改动核心）

    /// 段内中间空格应折叠：「AI 能力」≡「AI能力」
    func testWhitespaceFolding_中间空格折叠() {
        XCTAssertEqual(ThoughtTagNormalizer.key("AI 能力"), ThoughtTagNormalizer.key("AI能力"))
    }

    /// 首尾 + 段内空格都应折叠
    func testWhitespaceFolding_首尾段内空格() {
        XCTAssertEqual(ThoughtTagNormalizer.key("  AI 能力  "), ThoughtTagNormalizer.key("AI能力"))
    }

    /// 全角空格 U+3000 应折叠
    func testWhitespaceFolding_全角空格() {
        XCTAssertEqual(ThoughtTagNormalizer.key("AI\u{3000}能力"), ThoughtTagNormalizer.key("AI能力"))
    }

    /// Tab / 换行应折叠
    func testWhitespaceFolding_制表符换行() {
        XCTAssertEqual(ThoughtTagNormalizer.key("AI\t能力"), ThoughtTagNormalizer.key("AI能力"))
        XCTAssertEqual(ThoughtTagNormalizer.key("AI\n能力"), ThoughtTagNormalizer.key("AI能力"))
    }

    /// 英文短语连写（已确认接受：标签以中文为主）
    func testWhitespaceFolding_英文短语连写() {
        XCTAssertEqual(ThoughtTagNormalizer.key("machine learning"), ThoughtTagNormalizer.key("machinelearning"))
    }

    // MARK: - 回归：现有归一行为不被破坏

    func testCaseInsensitive() {
        XCTAssertEqual(ThoughtTagNormalizer.key("AI能力"), ThoughtTagNormalizer.key("ai能力"))
        XCTAssertEqual(ThoughtTagNormalizer.key("Holo"), ThoughtTagNormalizer.key("HOLO"))
    }

    func testWidthInsensitive() {
        XCTAssertEqual(ThoughtTagNormalizer.key("ＡＩ能力"), ThoughtTagNormalizer.key("AI能力"))
        // 全角斜杠由 displayPath 归一为半角
        XCTAssertEqual(ThoughtTagNormalizer.key("工作／Holo"), ThoughtTagNormalizer.key("工作/Holo"))
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(ThoughtTagNormalizer.key("café"), ThoughtTagNormalizer.key("cafe"))
    }

    // MARK: - 多级路径

    func testPathSegmentIndependence() {
        XCTAssertEqual(ThoughtTagNormalizer.key("工作/AI 能力"), ThoughtTagNormalizer.key("工作/AI能力"))
        XCTAssertEqual(ThoughtTagNormalizer.key("工作 / holo"), ThoughtTagNormalizer.key("工作/Holo"))
    }

    func testParentKeyUsesFoldedKey() {
        XCTAssertEqual(ThoughtTagNormalizer.parentKey("工作/AI 能力/深度"), "工作/ai能力")
    }

    // MARK: - 展示层（displayPath）不应删段内空格

    func testDisplayPreservesSpaces() {
        // 展示名保留段内空格——key 折叠和展示归一是两层分离的设计
        XCTAssertEqual(ThoughtTagNormalizer.displayPath("AI 能力"), "AI 能力")
        XCTAssertEqual(ThoughtTagNormalizer.displayPath("工作 / Holo"), "工作/Holo")
    }

    // MARK: - 边界

    func testEmptyAndEdgeCases() {
        XCTAssertEqual(ThoughtTagNormalizer.key(""), "")
        // 纯空格折叠后为空
        XCTAssertEqual(ThoughtTagNormalizer.key("   "), "")
        XCTAssertEqual(ThoughtTagNormalizer.key("#AI能力"), ThoughtTagNormalizer.key("AI能力"))
        XCTAssertEqual(ThoughtTagNormalizer.displayPath("#工作"), "工作")
    }
}
