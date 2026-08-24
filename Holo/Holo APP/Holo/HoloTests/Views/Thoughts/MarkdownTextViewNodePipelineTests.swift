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

    func testTextOnlyRoundTripPreservesBlankParagraphs() {
        // 重进编辑器不能把用户连续两次回车形成的段落间距压成一次换行。
        let markdown = "第一段\n\n第二段"
        let nodes = RichContentSerializer.nodes(fromPlainText: markdown)

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        XCTAssertEqual(attributed.string, markdown)
        XCTAssertEqual(
            MarkdownTextView.serializeNodes(from: attributed),
            [.text(value: markdown)]
        )
    }

    func testListRenderingAppliesHangingIndentToVisiblePrefixes() {
        let unordered = MarkdownTextView.makeAttributedText(
            from: "• 这是一个足够长、会发生自动换行的列表项目"
        )
        let ordered = MarkdownTextView.makeAttributedText(
            from: "1. 这是一个足够长、会发生自动换行的列表项目"
        )

        let unorderedStyle = unordered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let orderedStyle = ordered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertEqual(unorderedStyle?.firstLineHeadIndent ?? -1, 0, accuracy: 0.1)
        XCTAssertEqual(unorderedStyle?.headIndent ?? -1, 24, accuracy: 0.1)
        XCTAssertEqual(orderedStyle?.firstLineHeadIndent ?? -1, 0, accuracy: 0.1)
        XCTAssertEqual(orderedStyle?.headIndent ?? -1, 24, accuracy: 0.1)
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

    func testAdjacentSameReferenceTokensRemainDistinct() {
        // 同一条笔记可以被连续引用多次；实体 ID 相同不代表是同一个行内 Token。
        let nodes: [HoloContentNode] = [
            .reference(noteId: noteId, displayText: "同一条笔记", snapshot: "摘要"),
            .reference(noteId: noteId, displayText: "同一条笔记", snapshot: "摘要")
        ]

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, nodes)
        XCTAssertEqual(MarkdownTextView.tokenRanges(in: attributed).count, 2)
    }

    func testRepeatedTaskMarksHaveDistinctSwiftUIIdentity() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstMarkerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let secondMarkerId = UUID(uuidString: "88888888-7777-6666-5555-444444444444")!

        let first = HoloContentNode.taskMark(
            id: firstMarkerId,
            taskId: taskId,
            displayText: "同一个任务",
            sourceLength: 2
        )
        let second = HoloContentNode.taskMark(
            id: secondMarkerId,
            taskId: taskId,
            displayText: "同一个任务",
            sourceLength: 2
        )

        XCTAssertNotEqual(first.id, second.id)
    }

    func testExistingReferenceTokenDoesNotBecomeNewTrigger() {
        let tokenText = MarkdownTextView.makeAttributedText(from: [
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要")
        ])
        // token 渲染为「␣@目标记录␣」（首尾空格保点击热区）；
        // 光标放在 token 文本末尾（尾部空格之前）才会形成触发上下文
        let context = TriggerDetector.detect(
            text: tokenText.string as NSString,
            cursor: tokenText.length - 1
        )

        XCTAssertNotNil(context)
        if let context {
            XCTAssertTrue(MarkdownTextView.triggerIntersectsToken(context, in: tokenText))
        }

        let ordinaryText = NSAttributedString(string: "@目标记录", attributes: MarkdownTextView.baseAttributes)
        let ordinaryContext = TriggerDetector.detect(
            text: ordinaryText.string as NSString,
            cursor: ordinaryText.length
        )
        XCTAssertNotNil(ordinaryContext)
        if let ordinaryContext {
            XCTAssertFalse(MarkdownTextView.triggerIntersectsToken(ordinaryContext, in: ordinaryText))
        }
    }

    func testTokenOnlyContentRoundTrip() {
        let nodes: [HoloContentNode] = [.tag(id: tagId, displayPath: "灵感")]

        let attributed = MarkdownTextView.makeAttributedText(from: nodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        XCTAssertEqual(serialized, nodes)
    }

    func testSplitTokenAttributeRunsSerializeAsOneReference() {
        // 富文本编辑可能把同一个 Token 拆成多个属性区间；业务节点仍只能有一条引用。
        let token = MarkdownTextView.makeTokenAttributedText(
            type: .reference,
            id: noteId,
            displayText: "目标记录",
            snapshot: "目标摘要"
        )
        let split = NSMutableAttributedString(attributedString: token)
        split.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17, weight: .bold),
            range: NSRange(location: 0, length: 2)
        )

        XCTAssertEqual(
            MarkdownTextView.serializeNodes(from: split),
            [.reference(noteId: noteId, displayText: "目标记录", snapshot: "目标摘要")]
        )
        XCTAssertEqual(
            MarkdownTextView.tokenRanges(in: split),
            [NSRange(location: 0, length: split.length)]
        )
    }

    func testTaskMarkRestoresPersistentSourceUnderline() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let source = "完成方案"
        let attributed = MarkdownTextView.makeAttributedText(from: [
            .text(value: source),
            .taskMark(id: markerId, taskId: taskId, displayText: source, sourceLength: source.utf16.count)
        ])

        XCTAssertEqual(
            attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            attributed.attribute(.holoTaskId, at: 0, effectiveRange: nil) as? String,
            taskId.uuidString
        )
    }

    func testTaskMarkContentDerivationKeepsMarkdownSource() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let sourceNodes: [HoloContentNode] = [
            .text(value: "**重要结论**"),
            .taskMark(
                id: markerId,
                taskId: taskId,
                displayText: "重要结论",
                sourceLength: "重要结论".utf16.count
            )
        ]

        let attributed = MarkdownTextView.makeAttributedText(from: sourceNodes)
        let serialized = MarkdownTextView.serializeNodes(from: attributed)

        // 详情页保存任务关系时仍应保存 Markdown 源文本，而不是把加粗结果扁平化。
        XCTAssertEqual(RichContentSerializer.plainText(from: serialized), "**重要结论**")
        XCTAssertEqual(MarkdownTextView.visiblePlainText(from: serialized), "重要结论")
    }

    func testTaskMarkSourceLengthRoundTripsAndLegacyJSONFallsBack() throws {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "重复句 后文"),
            .taskMark(id: markerId, taskId: taskId, displayText: "重复句", sourceLength: 3)
        ]

        let json = try RichContentSerializer.jsonString(from: nodes)
        XCTAssertEqual(try RichContentSerializer.nodes(fromJSONString: json), nodes)

        // 旧版本没有 sourceLength；升级时用快照 UTF-16 长度兼容读取。
        let legacyJSON = """
        [{"type":"taskMark","id":"\(markerId.uuidString)","taskId":"\(taskId.uuidString)","displayText":"重复句"}]
        """
        let legacyNodes = try RichContentSerializer.nodes(fromJSONString: legacyJSON)
        if case .taskMark(_, _, _, let sourceLength) = legacyNodes.first {
            XCTAssertEqual(sourceLength, "重复句".utf16.count)
        } else {
            XCTFail("旧 taskMark JSON 应能兼容解码")
        }
    }

    func testFormattedTextRoundTripsColorAndVisibleTextSeparately() {
        // 纯格式内容没有 Token，也必须保留可恢复的颜色语义；不能只依赖普通字符串。
        let markdown = "{color:#F46D38}橙色文字{/color}"
        let nodes = RichContentSerializer.nodes(fromPlainText: markdown)
        let attributed = MarkdownTextView.makeAttributedText(from: nodes)

        XCTAssertEqual(
            attributed.attribute(.holoColorHex, at: 0, effectiveRange: nil) as? String,
            "#F46D38"
        )
        XCTAssertEqual(
            MarkdownTextView.serializeNodes(from: attributed),
            [.text(value: markdown)]
        )
        XCTAssertEqual(
            MarkdownTextView.visiblePlainText(from: nodes),
            "橙色文字"
        )
    }

    func testFormattingAfterTaskAttachmentDoesNotWrapNewlineInMarkdownMarkers() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .bold),
            .holoBold: true
        ]
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "前文", attributes: boldAttributes))
        attributed.append(
            MarkdownTextView.makeTaskMarkAttributedText(
                id: markerId,
                taskId: taskId,
                displayText: "前文",
                sourceLength: 2
            )
        )
        attributed.append(NSAttributedString(string: "\n\n后文", attributes: boldAttributes))

        let serialized = MarkdownTextView.serializeNodes(from: attributed)
        XCTAssertEqual(
            RichContentSerializer.plainText(from: serialized),
            "**前文**\n\n**后文**"
        )
        XCTAssertFalse(
            MarkdownTextView.makeAttributedText(from: serialized).string.contains("**")
        )
    }

    func testLegacyBoundaryMarkersAreRecoveredOnRender() {
        let nodes: [HoloContentNode] = [
            // 旧版本保存过的格式区间可能从空行开始；重新打开不应把星号当正文。
            .text(value: "**\n\n历史正文**")
        ]

        let rendered = MarkdownTextView.makeAttributedText(from: nodes)
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertTrue(rendered.string.contains("历史正文"))
    }

    func testLineStartLocationsCoverMultiLineSelectionInUTF16Coordinates() {
        let text = "😀 第一行\n第二行\n第三行" as NSString
        let firstLineLength = ("😀 第一行\n" as NSString).length
        let secondLineLength = ("第二行\n" as NSString).length
        let selection = NSRange(
            location: 2,
            length: firstLineLength + secondLineLength - 2
        )

        XCTAssertEqual(
            MarkdownTextView.lineStartLocations(in: text, for: selection),
            [0, firstLineLength]
        )
    }

    func testInlineMarkersAreNotDroppedByLegacyBoundaryRepair() {
        let markdown = "**行内正文**\n\n下一段"
        let rendered = MarkdownTextView.makeAttributedText(
            from: [.text(value: markdown)]
        )

        XCTAssertEqual(rendered.string, "行内正文\n\n下一段")
        XCTAssertEqual(
            MarkdownTextView.serializeNodes(from: rendered),
            [.text(value: markdown)]
        )
    }

    func testBlackColorIsARealRoundTripValue() {
        let markdown = "{color:#000000}恢复正文{/color}"
        let attributed = MarkdownTextView.makeAttributedText(
            from: RichContentSerializer.nodes(fromPlainText: markdown)
        )

        XCTAssertEqual(
            attributed.attribute(.holoColorHex, at: 0, effectiveRange: nil) as? String,
            "#000000"
        )
        XCTAssertEqual(
            MarkdownTextView.serializeNodes(from: attributed),
            [.text(value: markdown)]
        )
    }

    func testLegacyReferenceJSONKeepsIdentityAndRecoversDisplayText() throws {
        // 旧版引用可能没有 snapshot，或 displayText 为空；不能因此整段退回普通文本。
        let legacyJSON = """
        [{"type":"reference","noteId":"\(noteId.uuidString)","displayText":"","snapshot":"@目标想法\\n正文摘要"}]
        """

        let nodes = try RichContentSerializer.nodes(fromJSONString: legacyJSON)
        XCTAssertEqual(
            nodes,
            [.reference(noteId: noteId, displayText: "目标想法", snapshot: "@目标想法\n正文摘要")]
        )

        let missingSnapshotJSON = """
        [{"type":"reference","noteId":"\(noteId.uuidString)","displayText":"目标想法"}]
        """
        let missingSnapshotNodes = try RichContentSerializer.nodes(fromJSONString: missingSnapshotJSON)
        XCTAssertEqual(
            missingSnapshotNodes,
            [.reference(noteId: noteId, displayText: "目标想法", snapshot: "")]
        )

        let emptyReferenceJSON = """
        [{"type":"reference","noteId":"\(noteId.uuidString)","displayText":"","snapshot":""}]
        """
        let emptyReferenceNodes = try RichContentSerializer.nodes(fromJSONString: emptyReferenceJSON)
        XCTAssertEqual(
            emptyReferenceNodes,
            [.reference(noteId: noteId, displayText: RichContentSerializer.unnamedReferenceDisplay, snapshot: "")]
        )
    }

    func testVisibleTaskSourceRangeSkipsExistingTaskAttachment() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "前文"),
            .taskMark(id: markerId, taskId: taskId, displayText: "前文", sourceLength: 2),
            .text(value: "后文")
        ]
        let attributed = MarkdownTextView.makeAttributedText(from: nodes)

        // 可见文本是「前文后文」，后文在存储中位于任务附件之后。
        XCTAssertEqual(MarkdownTextView.visiblePlainText(from: nodes), "前文后文")
        XCTAssertEqual(
            MarkdownTextView.storageRange(
                forVisibleRange: NSRange(location: 2, length: 2),
                in: attributed
            ),
            NSRange(location: 3, length: 2)
        )
        XCTAssertEqual(
            MarkdownTextView.visibleRange(
                forStorageRange: NSRange(location: 3, length: 2),
                in: attributed
            ),
            NSRange(location: 2, length: 2)
        )

        let newTaskId = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let marked = MarkdownTextView.attributedTextByInsertingTaskMarks(
            [TaskMarkInsertion(
                taskId: newTaskId,
                displayText: "后文",
                sourceRange: NSRange(location: 2, length: 2)
            )],
            into: attributed
        )
        XCTAssertNotNil(marked)
        if let marked {
            let serialized = MarkdownTextView.serializeNodes(from: marked)
            XCTAssertTrue(serialized.contains { node in
                if case .taskMark(_, let taskId, let title, let sourceLength) = node {
                    return taskId == newTaskId && title == "后文" && sourceLength == 2
                }
                return false
            })
        }
    }

    func testTaskScopeLookupIncludesTouchedReferenceTokenWhenReplacingIt() {
        let taskId = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let referenceId = UUID(uuidString: "ABABABAB-CDCD-EFEF-0101-232323232323")!
        let token = NSMutableAttributedString(
            attributedString: MarkdownTextView.makeTokenAttributedText(
                type: .reference,
                id: referenceId,
                displayText: "目标记录",
                snapshot: "摘要"
            )
        )
        token.addAttribute(
            .holoTaskId,
            value: taskId.uuidString,
            range: NSRange(location: 0, length: token.length)
        )

        let attributed = NSMutableAttributedString(string: "正文")
        attributed.addAttribute(
            .holoTaskId,
            value: taskId.uuidString,
            range: NSRange(location: 0, length: attributed.length)
        )
        let tokenRange = NSRange(location: attributed.length, length: token.length)
        attributed.append(token)

        // 替换范围只覆盖 Token，不能因为它不在任务 marker 前的 source span 内而丢失 taskId。
        XCTAssertEqual(
            MarkdownTextView.taskScopeIDsTouchingRange(tokenRange, in: attributed),
            Set([taskId.uuidString])
        )
    }

    func testFormattingSelectionSplitsAroundSemanticTokens() {
        let token = MarkdownTextView.makeTokenAttributedText(
            type: .reference,
            id: noteId,
            displayText: "目标记录",
            snapshot: "摘要"
        )
        let attributed = NSMutableAttributedString(string: "前文")
        attributed.append(token)
        attributed.append(NSAttributedString(string: "后文"))

        // 普通格式动作可以覆盖整段选区，但不能把引用 Token 当成普通文字重写。
        XCTAssertEqual(
            MarkdownTextView.nonTokenRanges(
                in: NSRange(location: 0, length: attributed.length),
                attributedText: attributed
            ),
            [
                NSRange(location: 0, length: 2),
                NSRange(location: 2 + token.length, length: 2)
            ]
        )
    }

    func testTrimmedRangePreservesTheSelectedDuplicateOccurrence() {
        let text = "重复句 重复句" as NSString
        let secondStart = text.range(of: "重复句", options: [], range: NSRange(location: 4, length: text.length - 4)).location
        let selected = NSRange(location: secondStart - 1, length: 4)

        XCTAssertEqual(
            MarkdownTextView.trimmedRange(selected, in: text),
            NSRange(location: secondStart, length: 3)
        )
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

    func testVisiblePlainTextOmitsMarkdownMarkersAndTaskAttachment() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "**加粗** "),
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要"),
            .taskMark(id: markerId, taskId: taskId, displayText: "目标记录", sourceLength: 1)
        ]

        XCTAssertEqual(
            MarkdownTextView.visiblePlainText(from: nodes),
            "加粗 @目标记录"
        )
    }

    func testClipboardNodesExcludeTaskAttachmentButKeepReferenceAndTag() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "正文"),
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要"),
            .tag(id: tagId, displayPath: "工作"),
            .taskMark(id: markerId, taskId: taskId, displayText: "正文", sourceLength: 2)
        ]

        XCTAssertEqual(
            MarkdownTextView.clipboardSafeNodes(from: nodes),
            [
                .text(value: "正文"),
                .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要"),
                .tag(id: tagId, displayPath: "工作")
            ]
        )
    }

    func testSelectionTaskExtractionUsesOneCandidateForTheWholeSelection() {
        let candidates = ThoughtTaskExtractionSheet.buildCandidates(
            from: "第一行\n第二行",
            defaultSelected: true
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.text, "第一行\n第二行")
        XCTAssertTrue(candidates.first?.isSelected == true)
    }

    func testWholeThoughtCandidatesCarryVisibleSourceRanges() {
        let candidates = ThoughtTaskExtractionSheet.buildCandidates(
            from: "- 第一行\n- 第二行",
            visibleSourceText: "• 第一行\n• 第二行"
        )

        XCTAssertEqual(candidates.map(\.text), ["第一行", "第二行"])
        XCTAssertEqual(candidates[0].sourceRange, NSRange(location: 2, length: 3))
        XCTAssertEqual(candidates[1].sourceRange, NSRange(location: 8, length: 3))
    }

    func testWholeThoughtCandidatesDisplayVisibleFormattingInsteadOfMarkdownMarkers() {
        let candidates = ThoughtTaskExtractionSheet.buildCandidates(
            from: "- **第一行**",
            visibleSourceText: "• 第一行"
        )

        XCTAssertEqual(candidates.map(\.text), ["第一行"])
        XCTAssertTrue(candidates.first?.isSelected == true)
        XCTAssertEqual(candidates.first?.sourceRange, NSRange(location: 2, length: 3))
    }

    func testWholeThoughtCandidateRangesKeepUTF16OffsetsAfterEmoji() {
        let candidates = ThoughtTaskExtractionSheet.buildCandidates(
            from: "😀\n- 第二行",
            visibleSourceText: "😀\n• 第二行"
        )

        XCTAssertEqual(candidates.map(\.text), ["😀", "第二行"])
        XCTAssertEqual(candidates[0].sourceRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(candidates[1].sourceRange, NSRange(location: 5, length: 3))
    }

    func testVisiblePlainTextForStandaloneReferenceClipboard() {
        let nodes: [HoloContentNode] = [
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要")
        ]

        XCTAssertEqual(MarkdownTextView.visiblePlainText(from: nodes), "@目标记录")
    }

    func testAccessibilityTextExpandsSemanticNodesWithoutAttachmentPlaceholder() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "正文"),
            .tag(id: tagId, displayPath: "工作"),
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要"),
            .taskMark(id: markerId, taskId: taskId, displayText: "执行任务", sourceLength: 2)
        ]

        let accessibilityText = MarkdownTextView.accessibilityText(from: nodes)

        XCTAssertTrue(accessibilityText.contains("标签：#工作"))
        XCTAssertTrue(accessibilityText.contains("引用：@目标记录"))
        XCTAssertTrue(accessibilityText.contains("已转为任务：执行任务"))
        XCTAssertFalse(accessibilityText.contains("\u{FFFC}"))
    }

    func testEditableAccessibilityTextPreservesTokenStorageWidth() {
        let taskId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let markerId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let nodes: [HoloContentNode] = [
            .text(value: "正文"),
            .reference(noteId: noteId, displayText: "目标记录", snapshot: "摘要"),
            .taskMark(id: markerId, taskId: taskId, displayText: "正文", sourceLength: 2)
        ]
        let attributedText = MarkdownTextView.makeAttributedText(from: nodes)
        let editableValue = MarkdownTextView.editableAccessibilityText(from: attributedText)

        // 编辑态契约：token 以单字符标记（@/#/✓）占位，坐标才不会相对编辑态存储漂移；
        // 完整标题/任务说明由 Hint 提供（展示态字符串与编辑态值天然不等长，不做等长断言）。
        XCTAssertEqual(editableValue, "正文@✓")
        XCTAssertFalse(editableValue.contains("\u{FFFC}"), "编辑态不得暴露附件占位符")
        XCTAssertEqual(
            MarkdownTextView.editableAccessibilityHint(from: nodes),
            "引用：@目标记录；已转为任务：正文"
        )
    }

    func testLineStartUsesUTF16OffsetsForEmojiAndFlagCharacters() {
        let emojiText = "😀\n• 第二行" as NSString
        let flagText = "🇨🇳\n第二行" as NSString

        XCTAssertEqual(
            MarkdownTextView.lineStart(in: emojiText, before: emojiText.length),
            3
        )
        XCTAssertEqual(
            MarkdownTextView.lineStart(in: flagText, before: flagText.length),
            5
        )
    }

    func testRemovingTokenPreservesUserFormatting() {
        let tokenAttributes: [NSAttributedString.Key: Any] = [
            .holoTokenType: HoloTokenType.reference.rawValue,
            .holoEntityId: noteId.uuidString,
            .holoTokenInstanceId: UUID().uuidString,
            .holoDisplayText: "目标记录",
            .holoBold: true,
            .holoColorHex: "#C2410C",
            .backgroundColor: UIColor.systemOrange.withAlphaComponent(0.12)
        ]

        let plainAttributes = MarkdownTextView.plainTextAttributes(
            afterRemovingToken: tokenAttributes
        )

        XCTAssertNil(plainAttributes[.holoTokenType])
        XCTAssertNil(plainAttributes[.holoEntityId])
        XCTAssertNil(plainAttributes[.holoTokenInstanceId])
        XCTAssertNil(plainAttributes[.backgroundColor])
        XCTAssertEqual(plainAttributes[.holoBold] as? Bool, true)
        XCTAssertEqual(plainAttributes[.holoColorHex] as? String, "#C2410C")
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
