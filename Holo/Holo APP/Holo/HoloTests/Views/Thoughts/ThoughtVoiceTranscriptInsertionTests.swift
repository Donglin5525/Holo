//
//  ThoughtVoiceTranscriptInsertionTests.swift
//  HoloTests
//
//  观点语音输入插入规则测试
//

import XCTest
import SwiftUI
import UIKit
@testable import Holo

final class ThoughtVoiceTranscriptInsertionTests: XCTestCase {

    func testRestoreAndUndoOnlyReplaceInsertedRangeEvenWithDuplicateText() throws {
        let prefix = "前面🙂我有点犹豫。\n"
        let polished = "我有点犹豫。"
        let original = "嗯，我现在其实有点犹豫。"
        let suffix = "\n后面的笔记"
        let document = prefix + polished + suffix
        let receipt = ThoughtVoiceReplacement(
            expectedDocument: document,
            range: NSRange(location: prefix.utf16.count, length: polished.utf16.count),
            alternate: original,
            status: .polished
        )

        let restored = try XCTUnwrap(receipt.reversing(in: document))
        XCTAssertEqual(restored.expectedDocument, prefix + original + suffix)
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(restored.reversing(in: restored.expectedDocument)?.expectedDocument, document)
        XCTAssertNil(receipt.reversing(in: document + "后续修改"))
    }

    @MainActor
    func testEditorSwapsJustTheInsertedSegmentAndRefusesAfterTyping() {
        let surrounding = "🙂前文\n\n后文"
        var boundText = surrounding
        let binding = Binding(get: { boundText }, set: { boundText = $0 })
        let coordinator = MarkdownTextView.Coordinator(
            text: binding, triggerContext: .constant(nil), selectedToken: .constant(nil)
        )
        let editor = UITextView()
        editor.attributedText = MarkdownTextView.makeAttributedText(from: surrounding)
        editor.selectedRange = NSRange(location: "🙂前文\n".utf16.count, length: 0)
        let draft = VoiceTranscriptSubmission(text: "我有点犹豫。", originalToRestore: "嗯，我有点犹豫。")
        var status: ThoughtVoiceInsertionStatus?
        coordinator.onVoiceInsertionChange = { status = $0 }
        coordinator.perform(action: .insertVoiceTranscript(draft), on: editor, markdown: binding)
        XCTAssertEqual(editor.attributedText.string, "🙂前文\n我有点犹豫。\n后文")
        XCTAssertEqual(status, .polished)

        editor.selectedRange = NSRange(location: 0, length: 0)
        coordinator.perform(action: .swapVoiceTranscript, on: editor, markdown: binding)
        XCTAssertEqual(editor.attributedText.string, "🙂前文\n嗯，我有点犹豫。\n后文")
        XCTAssertEqual(status, .restored)
        coordinator.perform(action: .swapVoiceTranscript, on: editor, markdown: binding)
        XCTAssertEqual(editor.attributedText.string, "🙂前文\n我有点犹豫。\n后文")

        editor.textStorage.append(NSAttributedString(string: "手改"))
        coordinator.textViewDidChange(editor)
        XCTAssertNil(status)
        coordinator.perform(action: .swapVoiceTranscript, on: editor, markdown: binding)
        XCTAssertEqual(editor.attributedText.string, "🙂前文\n我有点犹豫。\n后文手改")
    }

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
