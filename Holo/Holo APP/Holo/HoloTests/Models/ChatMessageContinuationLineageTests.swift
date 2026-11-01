//
//  ChatMessageContinuationLineageTests.swift
//  HoloTests
//
//  报告追问血统章（2026-11-01 追问链路原型）：stampContinuationRoot 只增改
//  continuationRoot / continuationParentID 两个 key、既有键值原样保留，
//  用户消息与生成中占位消息盖章后 ViewData 派生立即可读。
//

import XCTest
import Combine
@testable import Holo

@MainActor
final class ChatMessageContinuationLineageTests: XCTestCase {

    override func setUp() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
    }

    override func tearDown() async throws {
        ChatMessageRepository.shared.clearAllMessages()
    }

    func testStampAnnotatesUserAndStreamingMessages() throws {
        let repo = ChatMessageRepository.shared
        let userMessageId = repo.addMessage(role: "user", content: "换成近半年再看")
        let aiMessageId = repo.addStreamingMessage(role: "assistant", parentMessageId: userMessageId)

        repo.stampContinuationRoot(
            userMessageId,
            rootQuestion: "最近30天的钱都花在哪了？",
            parentResultID: "result-123"
        )
        repo.stampContinuationRoot(
            aiMessageId,
            rootQuestion: "最近30天的钱都花在哪了？",
            parentResultID: "result-123"
        )

        let user = try XCTUnwrap(repo.messages.first(where: { $0.id == userMessageId }))
        XCTAssertEqual(user.continuationRootQuestion, "最近30天的钱都花在哪了？")
        XCTAssertEqual(user.continuationParentResultID, "result-123")

        let streaming = try XCTUnwrap(repo.messages.first(where: { $0.id == aiMessageId }))
        XCTAssertEqual(streaming.continuationRootQuestion, "最近30天的钱都花在哪了？")
        XCTAssertEqual(streaming.continuationParentResultID, "result-123")
    }

    func testStampPreservesExistingExtractedDataKeys() throws {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addMessage(role: "assistant", content: "回答")
        let existing = #"{"memoryUsedCount":"3","memoryUsedIDs":"a,b,c"}"#
        repo.updateMessageMetadata(messageId, intent: nil, extractedDataJSON: existing)

        repo.stampContinuationRoot(messageId, rootQuestion: "根问题", parentResultID: nil)

        let message = try XCTUnwrap(repo.messages.first(where: { $0.id == messageId }))
        XCTAssertEqual(message.continuationRootQuestion, "根问题")
        XCTAssertNil(message.continuationParentResultID)
        // 既有键不被血统章冲掉（记忆署名等读侧继续工作）
        XCTAssertEqual(message.memoryAttributionCount, 3)
        XCTAssertEqual(message.memoryAttributionIDs, ["a", "b", "c"])
    }

    func testUnstampedMessageHasNoLineage() throws {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addMessage(role: "user", content: "普通聊天")

        let message = try XCTUnwrap(repo.messages.first(where: { $0.id == messageId }))
        XCTAssertNil(message.continuationRootQuestion)
        XCTAssertNil(message.continuationParentResultID)
    }
}
