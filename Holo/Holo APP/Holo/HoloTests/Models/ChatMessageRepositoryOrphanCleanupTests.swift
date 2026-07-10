//
//  ChatMessageRepositoryOrphanCleanupTests.swift
//  HoloTests
//
//  回归：HoloAI 深度分析在「发送后立马返回首页再进入」时被误判中断。
//  根因：页面进入时的孤儿清理（cleanupOrphanedStreamingMessages）在 Agent job 落盘前执行，
//       读不到关联 job → 该消息不在 preserve 集合 → 被清理成「抱歉，处理时意外中断了」。
//  修复：孤儿清理对宽限期内（对齐 Agent budget 上限）的 streaming 消息予以保留。
//

import XCTest
@testable import Holo

@MainActor
final class ChatMessageRepositoryOrphanCleanupTests: XCTestCase {

    override func setUp() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
    }

    override func tearDown() async throws {
        ChatMessageRepository.shared.clearAllMessages()
    }

    /// 近期创建、正在跑的 streaming 消息（agent job 可能尚未落盘）不应被孤儿清理误杀。
    func testRecentStreamingMessageSurvivesOrphanCleanup() {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addStreamingMessage(role: "assistant")

        // preserve 为空：模拟 Agent job 尚未落盘、syncRecoverableChatMessages 读不到的竞态。
        repo.cleanupOrphanedStreamingMessages(preserveMessageIDs: [], now: Date())

        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertNotNil(message)
        XCTAssertTrue(
            message?.isStreaming ?? false,
            "近期 streaming 消息不应被孤儿清理误杀（Agent job 可能尚未落盘，正在后台跑）"
        )
    }

    /// 超过宽限期的 streaming 消息视为真孤儿（App 崩溃残留），应被正常清理。
    func testStaleStreamingMessageIsCleanedAsOrphan() {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addStreamingMessage(role: "assistant")

        // 注入一个远超宽限期的「现在」，模拟 App 崩溃很久后重启的场景。
        let staleNow = Date().addingTimeInterval(400)
        repo.cleanupOrphanedStreamingMessages(preserveMessageIDs: [], now: staleNow)

        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.isStreaming ?? true, "超期 streaming 消息应作为真孤儿被清理")
        XCTAssertEqual(message?.content, "抱歉，处理时意外中断了")
    }

    /// 被 preserve 的消息（syncRecoverableChatMessages 读到关联 job）即使在宽限期外也不应被清理。
    func testPreservedMessageIsNeverCleaned() {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addStreamingMessage(role: "assistant")

        let staleNow = Date().addingTimeInterval(400)
        repo.cleanupOrphanedStreamingMessages(preserveMessageIDs: [messageId], now: staleNow)

        let message = repo.messages.first(where: { $0.id == messageId })
        XCTAssertTrue(message?.isStreaming ?? false, "preserve 集合内的消息不应被清理")
    }
}
