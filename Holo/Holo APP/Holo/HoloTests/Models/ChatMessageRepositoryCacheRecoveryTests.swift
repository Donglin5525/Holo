//
//  ChatMessageRepositoryCacheRecoveryTests.swift
//  HoloTests
//
//  验证 HoloAI 退出重进后，恢复出来的消息仍能响应确认/取消更新。
//

import XCTest
@testable import Holo

@MainActor
final class ChatMessageRepositoryCacheRecoveryTests: XCTestCase {

    override func setUp() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
    }

    override func tearDown() async throws {
        ChatMessageRepository.shared.clearAllMessages()
    }

    func testUpdateMetadataWorksAfterLightweightReloadClearsLiveCache() async throws {
        let repo = ChatMessageRepository.shared
        let messageId = repo.addMessage(role: "assistant", content: "待确认")

        let pendingBatch = makeBatch(confirmationStatus: "pending", finalText: "支出待确认")
        repo.updateMessageMetadata(
            messageId,
            intent: AIIntent.recordExpense.rawValue,
            extractedDataJSON: nil,
            executionBatchJSON: encode(pendingBatch)
        )

        await repo.loadCurrentSessionLightweightMessagesAsync(limit: 10)
        XCTAssertEqual(repo.messages.first?.id, messageId)
        XCTAssertEqual(
            repo.messages.first?.executionBatch?.items.first?.renderData?["confirmationStatus"],
            "pending"
        )

        let confirmedBatch = makeBatch(confirmationStatus: "confirmed", finalText: "已确认")
        repo.updateMessage(messageId, content: "已确认")
        repo.updateMessageMetadata(
            messageId,
            intent: AIIntent.recordExpense.rawValue,
            extractedDataJSON: nil,
            executionBatchJSON: encode(confirmedBatch)
        )

        let reloadedMessage = try XCTUnwrap(repo.messages.first(where: { $0.id == messageId }))
        XCTAssertEqual(reloadedMessage.content, "已确认")
        XCTAssertEqual(
            reloadedMessage.executionBatch?.items.first?.renderData?["confirmationStatus"],
            "confirmed"
        )
    }

    private func makeBatch(confirmationStatus: String, finalText: String) -> AIExecutionBatch {
        AIExecutionBatch(
            mode: .singleAction,
            items: [
                AIExecutionItem(
                    id: "item-1",
                    parseItemId: "parse-1",
                    intent: .recordExpense,
                    status: .skipped,
                    summaryText: finalText,
                    renderData: [
                        "amount": "18",
                        "pendingKind": "transaction",
                        "confirmationStatus": confirmationStatus
                    ],
                    linkedEntityType: nil,
                    linkedEntityId: nil,
                    errorText: nil
                )
            ],
            finalText: finalText
        )
    }

    private func encode(_ batch: AIExecutionBatch) -> String {
        let data = try! JSONEncoder().encode(batch)
        return String(data: data, encoding: .utf8)!
    }
}
