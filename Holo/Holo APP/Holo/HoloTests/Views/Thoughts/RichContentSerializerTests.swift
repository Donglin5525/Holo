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

    func testNodesFromPlainTextTokenizesInlineTags() {
        // 纯文本加载时 #标签 会被 Token 化（修复「打开后标签不再高亮 / 重新保存后丢失身份」）
        let nodes = RichContentSerializer.nodes(fromPlainText: "正文里的 #工作 标签")
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[0], .text(value: "正文里的 "))
        if case .tag(_, let displayPath) = nodes[1] {
            XCTAssertEqual(displayPath, "工作")
        } else {
            XCTFail("第二个节点应为 tag，实际：\(nodes[1])")
        }
        XCTAssertEqual(nodes[2], .text(value: " 标签"))
    }

    func testNodesFromPlainTextKeepsTrailingNewline() {
        // 修复「末尾换行打开后消失」：换行作为独立 text 节点保留
        let nodes = RichContentSerializer.nodes(fromPlainText: "#工作\n")
        XCTAssertEqual(nodes.count, 2)
        if case .tag = nodes[0] {} else { XCTFail("首节点应为 tag") }
        XCTAssertEqual(nodes[1], .text(value: "\n"))
    }

    func testNodesFromPlainTextPreservesCJKPrefixedTag() {
        // 修复「正文#标签」：CJK 前置的 # 也被 Token 化
        let nodes = RichContentSerializer.nodes(fromPlainText: "正文#标签")
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0], .text(value: "正文"))
        if case .tag(_, let displayPath) = nodes[1] {
            XCTAssertEqual(displayPath, "标签")
        } else {
            XCTFail("第二节点应为 tag，实际：\(nodes[1])")
        }
    }

    func testPlainTextRoundTripFromLegacyText() {
        // 往返一致性：纯文本 → 节点 → 派生平文本，#标签 还原为 #displayPath
        let legacy = "今天记录 #工作 的小事\n明天继续 #工作/Holo"
        let nodes = RichContentSerializer.nodes(fromPlainText: legacy)
        let derived = RichContentSerializer.plainText(from: nodes)
        XCTAssertEqual(derived, legacy)
    }

    func testNodesFromPlainTextLeavesReferenceUnchanged() {
        // @引用 纯文本加载时不 Token 化（无身份信息），整段保持为文本
        let legacy = "参考 @某人 的意见"
        let nodes = RichContentSerializer.nodes(fromPlainText: legacy)
        XCTAssertEqual(nodes, [.text(value: legacy)])
    }

    func testPlainTextTokenIdsAreDeterministic() {
        // 同一标签名跨多次加载应得到相同 UUID（避免每次打开都生成新身份）
        let plain = "今天 #工作 很忙"
        let nodes1 = RichContentSerializer.nodes(fromPlainText: plain)
        let nodes2 = RichContentSerializer.nodes(fromPlainText: plain)
        XCTAssertEqual(nodes1, nodes2, "纯文本 Token 化的 tag UUID 应确定性稳定")

        // 不同标签名应得到不同 UUID
        let otherPlain = "今天 #生活 很忙"
        let otherNodes = RichContentSerializer.nodes(fromPlainText: otherPlain)
        if case .tag(let id1, _) = nodes1[1], case .tag(let id2, _) = otherNodes[1] {
            XCTAssertNotEqual(id1, id2, "不同标签名应有不同 UUID")
        }
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

    // MARK: - @ 显示文字截断

    func testTruncatedReferenceDisplayKeepsShortTitle() {
        XCTAssertEqual(RichContentSerializer.truncatedReferenceDisplay("短标题"), "短标题")
    }

    func testTruncatedReferenceDisplayTruncatesLongTitleWithEllipsis() {
        let long = String(repeating: "长", count: 40)
        let result = RichContentSerializer.truncatedReferenceDisplay(long)

        XCTAssertEqual(result.count, RichContentSerializer.referenceDisplayMaxLength + 1)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testFirstLineOfEmptyNodesIsEmpty() {
        XCTAssertEqual(RichContentSerializer.firstLine(from: []), "")
    }
}
