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
