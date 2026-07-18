//
//  RichContentSerializerTests.swift
//  HoloTests
//
//  观点结构化内容序列化器测试
//

import XCTest
@testable import Holo

final class RichContentSerializerTests: XCTestCase {

    private let tagId = UUID(uuidString: "4A02E6F1-8DB8-4A42-BD10-9821B53D41F8")!
    private let noteId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - JSON 往返

    func testJSONRoundTripWithMixedNodes() throws {
        let nodes: [HoloContentNode] = [
            .text(value: "今天重新思考了 "),
            .tag(id: tagId, displayPath: "产品/Holo"),
            .text(value: "，和之前的 "),
            .reference(noteId: noteId, displayText: "标签体系应该如何设计", snapshot: "标签既可以由用户创建"),
            .text(value: " 有关。")
        ]

        let json = try RichContentSerializer.jsonString(from: nodes)
        let decoded = try RichContentSerializer.nodes(fromJSONString: json)

        XCTAssertEqual(decoded, nodes)
    }

    func testJSONRoundTripWithEmptyNodes() throws {
        let json = try RichContentSerializer.jsonString(from: [])
        let decoded = try RichContentSerializer.nodes(fromJSONString: json)

        XCTAssertEqual(decoded, [])
    }

    func testJSONUsesStableTypeDiscriminator() throws {
        let json = try RichContentSerializer.jsonString(from: [
            .tag(id: tagId, displayPath: "工作/Holo")
        ])

        XCTAssertTrue(json.contains("\"type\":\"tag\""))
        XCTAssertTrue(json.contains("\"displayPath\":\"工作\\/Holo\"") || json.contains("\"displayPath\":\"工作/Holo\""))
        XCTAssertTrue(json.contains(tagId.uuidString))
    }

    func testNodesFromInvalidJSONThrows() {
        XCTAssertThrowsError(try RichContentSerializer.nodes(fromJSONString: "not json"))
        XCTAssertThrowsError(try RichContentSerializer.nodes(fromJSONString: "{\"type\":\"unknown\"}"))
    }

    // MARK: - 宽松解析回退

    func testLenientParseFallsBackToPlainTextOnNilJSON() {
        let nodes = RichContentSerializer.nodes(richJSON: nil, fallbackPlainText: "存量正文")

        XCTAssertEqual(nodes, [.text(value: "存量正文")])
    }

    func testLenientParseFallsBackToPlainTextOnCorruptedJSON() {
        let nodes = RichContentSerializer.nodes(richJSON: "{broken", fallbackPlainText: "存量正文")

        XCTAssertEqual(nodes, [.text(value: "存量正文")])
    }

    func testLenientParsePrefersValidJSON() throws {
        let json = try RichContentSerializer.jsonString(from: [.text(value: "新结构")])
        let nodes = RichContentSerializer.nodes(richJSON: json, fallbackPlainText: "旧文本")

        XCTAssertEqual(nodes, [.text(value: "新结构")])
    }

    // MARK: - 存量平文本

    func testNodesFromEmptyPlainTextReturnsEmpty() {
        XCTAssertEqual(RichContentSerializer.nodes(fromPlainText: ""), [])
    }

    func testNodesFromPlainTextKeepsOriginalUntouched() {
        let legacy = "正文里的 #工作 和 @某人 都不解析"
        XCTAssertEqual(RichContentSerializer.nodes(fromPlainText: legacy), [.text(value: legacy)])
    }

    // MARK: - 派生平文本

    func testPlainTextDerivesDisplayTextForTokens() {
        let nodes: [HoloContentNode] = [
            .text(value: "今天重新思考了 "),
            .tag(id: tagId, displayPath: "产品/Holo"),
            .text(value: "，和之前的 "),
            .reference(noteId: noteId, displayText: "标签体系应该如何设计", snapshot: "快照"),
            .text(value: " 有关。")
        ]

        XCTAssertEqual(
            RichContentSerializer.plainText(from: nodes),
            "今天重新思考了 #产品/Holo，和之前的 @标签体系应该如何设计 有关。"
        )
    }

    func testPlainTextKeepsMarkdownMarkersInTextNodes() {
        let nodes: [HoloContentNode] = [.text(value: "这是**加粗**内容")]

        XCTAssertEqual(RichContentSerializer.plainText(from: nodes), "这是**加粗**内容")
    }

    // MARK: - firstLine 派生

    func testFirstLineTakesFirstNonEmptyLine() {
        let nodes: [HoloContentNode] = [.text(value: "\n\n  第一行内容  \n第二行")]

        XCTAssertEqual(RichContentSerializer.firstLine(from: nodes), "第一行内容")
    }

    func testFirstLineFromTokenOnlyContent() {
        let nodes: [HoloContentNode] = [.tag(id: tagId, displayPath: "工作/Holo")]

        XCTAssertEqual(RichContentSerializer.firstLine(from: nodes), "#工作/Holo")
    }

    func testFirstLineTruncatesLongLine() {
        let longLine = String(repeating: "长", count: 200)
        let nodes: [HoloContentNode] = [.text(value: longLine)]

        XCTAssertEqual(
            RichContentSerializer.firstLine(from: nodes).count,
            RichContentSerializer.firstLineMaxLength
        )
    }

    func testFirstLineOfEmptyNodesIsEmpty() {
        XCTAssertEqual(RichContentSerializer.firstLine(from: []), "")
    }
}
