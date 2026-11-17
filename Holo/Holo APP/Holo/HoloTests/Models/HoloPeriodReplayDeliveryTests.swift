//
//  HoloPeriodReplayDeliveryTests.swift
//  HoloTests
//
//  验证「报告生成即进聊天」（2026-11-17 东林拍板）：洞察生成完成的广播信号
//  一到，未落卡的报告立即补进聊天；用户主动回放的占位转圈卡占住同周期键，
//  不会被重复补卡。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloPeriodReplayDeliveryTests: XCTestCase {

    private var insightRepo: MemoryInsightRepository!

    override func setUp() async throws {
        await CoreDataStack.shared.waitUntilReady()
        ChatMessageRepository.shared.clearAllMessages()
        insightRepo = MemoryInsightRepository()
        // 确保 coordinator 单例已初始化（生成完成信号的监听在 init 注册）
        _ = HoloPeriodReplayCoordinator.shared
    }

    override func tearDown() async throws {
        ChatMessageRepository.shared.clearAllMessages()
    }

    // MARK: - Helpers

    /// 造一份 ready 洞察（唯一起止时间，避免与库中既有洞察撞键）。
    private func makeReadyInsight(
        periodType: MemoryInsightPeriodType = .weekly,
        title: String = "本周回顾"
    ) throws -> (insight: MemoryInsight, triple: String) {
        let start = Date(timeIntervalSinceNow: -7 * 86_400 - TimeInterval.random(in: 0...600))
        let end = start.addingTimeInterval(6 * 86_400)
        let insight = try insightRepo.saveGenerating(
            periodType: periodType,
            start: start,
            end: end,
            snapshotHash: "test-\(UUID().uuidString)"
        )
        let payload = MemoryInsightPayload(
            title: title,
            summary: "测试摘要",
            cards: [],
            suggestedQuestions: []
        )
        try insightRepo.saveReady(
            insight: insight,
            payload: payload,
            rawResponse: "{}",
            providerName: "test",
            promptVersion: 0
        )
        let triple = "\(periodType.rawValue)|\(String(start.timeIntervalSince1970))|\(String(end.timeIntervalSince1970))"
        return (insight, triple)
    }

    /// 与生产发送方同形状地广播「洞察生成完成」。
    private func postGenerationNotification(for insight: MemoryInsight) {
        NotificationCenter.default.post(
            name: .memoryInsightDidGenerate,
            object: nil,
            userInfo: [
                "insightID": insight.id.uuidString,
                "periodType": insight.insightPeriodType.rawValue,
                "periodStart": insight.periodStart,
                "periodEnd": insight.periodEnd,
                "payload": MemoryInsightPayload(
                    title: "本周回顾",
                    summary: "测试摘要",
                    cards: [],
                    suggestedQuestions: []
                )
            ]
        )
    }

    /// 轮询等待 backfill 的 @MainActor Task 跑完（信号到达 → 卡落库）。
    private func waitForCard(
        triple: String,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ChatMessageRepository.shared.periodReplayCardTriples().contains(triple) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return ChatMessageRepository.shared.periodReplayCardTriples().contains(triple)
    }

    // MARK: - Tests

    /// 洞察生成完成的信号一到，报告卡立即落进聊天（不再等深度分析完成/用户点开）。
    func testGenerationNotificationDeliversCardIntoChatImmediately() async throws {
        let (insight, triple) = try makeReadyInsight()

        postGenerationNotification(for: insight)

        let delivered = await waitForCard(triple: triple)
        XCTAssertTrue(delivered, "生成完成信号后 3 秒内报告卡应已落进聊天")
    }

    /// 用户主动回放的占位转圈卡已占住同周期键：补卡扫描不得再落重复卡。
    /// 不断言全局「未发生补卡」——库中可能残留其他未点开洞察（属正常补卡对象），
    /// 只数本周期键的消息条数（占位卡 1 条，补卡后仍应是 1 条）。
    func testPlaceholderCardPreventsDuplicateBackfill() async throws {
        let (insight, triple) = try makeReadyInsight(title: "已有占位的周期")

        // 占位 streaming 消息（用户主动回放创建，带 job json → triple 已存在）
        let job = HoloPeriodReplayJob(
            periodType: insight.insightPeriodType,
            periodStart: insight.periodStart,
            periodEnd: insight.periodEnd
        )
        let placeholderId = ChatMessageRepository.shared.addStreamingMessage(
            role: "assistant",
            parentMessageId: nil,
            messageType: .periodReplay,
            extractedDataJSON: job.json
        )
        XCTAssertNotNil(placeholderId)
        XCTAssertEqual(countReplayMessages(triple: triple), 1, "占位卡应已占住本周期键")

        _ = HoloPeriodReplayCoordinator.shared.backfillUnopenedInsightCards()

        XCTAssertEqual(
            countReplayMessages(triple: triple),
            1,
            "占位卡周期不应被重复补卡"
        )
    }

    /// 数本周期键（periodType|start|end，秒粒度）对应的 assistant 回放消息条数。
    private func countReplayMessages(triple: String) -> Int {
        let request = NSFetchRequest<ChatMessage>(entityName: "ChatMessage")
        request.predicate = NSPredicate(
            format: "messageType == %@ AND role == %@ AND deletedAt == nil",
            ChatMessageType.periodReplay.rawValue, "assistant"
        )
        let rows = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
        return rows.filter { message in
            guard let json = message.extractedDataJSON,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data),
                  dict["kind"] == HoloPeriodReplayJob.payloadKind else { return false }
            let key = "\(dict["periodType"] ?? "")|\(dict["periodStart"] ?? "")|\(dict["periodEnd"] ?? "")"
            return key == triple
        }.count
    }
}
