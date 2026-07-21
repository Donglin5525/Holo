//
//  MarkdownTextViewNodePipelineTests.swift
//  HoloTests
//
//  观点编辑器节点管线往返一致性测试
//  验证：ContentNode[] → NSAttributedString → ContentNode[] 不丢 Markdown 标记、不丢 Token 身份
//

import XCTest
@testable import Holo

final class MarkdownTextViewNodePipelineTests: XCTestCase {

    private let tagId = UUID(uuidString: "4A02E6F1-8DB8-4A42-BD10-9821B53D41F8")!
    private let noteId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - 纯文本（Markdown）往返

    func testTextOnlyRoundTripPreservesMarkdownMarkers() {
        let markdown = "这是**加粗**和*斜体*内容"
        let nodes = RichContentSerializer.nodes(fromPlainText: markdown)

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, [.text(value: markdown)])
    }

    func testTextOnlyRoundTripPreservesNewlines() {
        let markdown = "第一行\n第二行\n第三行"
        let nodes = RichContentSerializer.nodes(fromPlainText: markdown)

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, [.text(value: markdown)])
    }

    // MARK: - 纯文本含 #标签 的往返（修复「打开后标签不高亮 / 末尾换行丢失」）

    func testPlainTextWithInlineTagRoundTripsAsToken() {
        // 用户手敲 #标签（没走候选面板）→ 保存为纯文本 → 重新打开应 Token 化
        let plain = "今天记录 #工作 的小事"
        let nodes = RichContentSerializer.nodes(fromPlainText: plain)

        // 应切分为 text + tag + text
        XCTAssertEqual(nodes.count, 3)
        guard nodes.count == 3 else { return }

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        // tag 节点身份应保留（id 不变，displayPath 还原）
        XCTAssertEqual(serialized.count, 3)
        XCTAssertEqual(serialized[0], .text(value: "今天记录 "))
        if case .tag(_, let displayPath) = serialized[1] {
            XCTAssertEqual(displayPath, "工作")
        } else {
            XCTFail("第二节点应为 tag，实际：\(serialized[1])")
        }
        XCTAssertEqual(serialized[2], .text(value: " 的小事"))

        // 派生平文本应与原文一致
        XCTAssertEqual(RichContentSerializer.plainText(from: serialized), plain)
    }

    func testPlainTextWithTrailingNewlineAfterTagPreserves() {
        // 修复「末尾换行打开后消失」：#标签\n 末尾换行应作为独立 text 节点保留
        let plain = "#工作\n"
        let nodes = RichContentSerializer.nodes(fromPlainText: plain)
        XCTAssertEqual(nodes.count, 2)

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)
        XCTAssertEqual(serialized.count, 2)
        if case .tag = serialized[0] {} else { XCTFail("首节点应为 tag") }
        XCTAssertEqual(serialized[1], .text(value: "\n"))

        XCTAssertEqual(RichContentSerializer.plainText(from: serialized), plain)
    }

    func testPlainTextWithCJKPrefixedTagTokenizes() {
        // 修复「正文#标签」：CJK 前置的 # 也应 Token 化
        let plain = "正文#标签"
        let nodes = RichContentSerializer.nodes(fromPlainText: plain)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0], .text(value: "正文"))
        if case .tag(_, let displayPath) = nodes[1] {
            XCTAssertEqual(displayPath, "标签")
        } else {
            XCTFail("第二节点应为 tag")
        }
    }

    // MARK: - Token 往返

    func testTokenRoundTripPreservesIdentity() {
        let nodes: [HoloContentNode] = [
            .text(value: "今天思考了 "),
            .tag(id: tagId, displayPath: "工作/Holo"),
            .text(value: "，参考 "),
            .reference(noteId: noteId, displayText: "标签体系设计", snapshot: "摘要快照"),
            .text(value: " 的结论")
        ]

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, nodes)
    }

    func testTokenOnlyContentRoundTrip() {
        let nodes: [HoloContentNode] = [.tag(id: tagId, displayPath: "灵感")]

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, nodes)
    }

    // MARK: - 派生平文本

    func testDerivedPlainTextContainsTokenDisplayText() {
        let nodes: [HoloContentNode] = [
            .text(value: "关联 "),
            .tag(id: tagId, displayPath: "工作/Holo"),
            .text(value: " 和 "),
            .reference(noteId: noteId, displayText: "旧想法", snapshot: "快照")
        ]

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let derived = RichContentSerializer.plainText(from: MarkdownTextView.serializeNodes(from: attributed))

        XCTAssertEqual(derived, "关联 #工作/Holo 和 @旧想法")
    }

    // MARK: - 边界

    func testEmptyAttributedTextReturnsEmptyNodes() {
        let empty = NSAttributedString(string: "")
        XCTAssertEqual(MarkdownTextView.serializeNodes(from: empty), [])
    }

    func testDegradedTokenAttributesFallBackToPlainText() {
        // Token 属性残缺（只有类型、没有实体 ID）时按普通文本处理，文字不丢
        let attrs: [NSAttributedString.Key: Any] = [
            .holoTokenType: "tag",
            .font: UIFont.systemFont(ofSize: 16)
        ]
        let attributed = NSAttributedString(string: "#残缺Token", attributes: attrs)

        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, [.text(value: "#残缺Token")])
    }
}
