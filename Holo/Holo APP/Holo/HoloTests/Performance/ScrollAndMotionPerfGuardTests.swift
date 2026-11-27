import XCTest
import CoreData
import Combine
@testable import Holo

/// 120Hz 滑动与交互动效性能根治回归测试（2026-11-27）
final class ScrollAndMotionPerfGuardTests: XCTestCase {

    // MARK: - 1. iPhone Pro 120Hz 高刷开关

    func testInfoPlistEnablesProMotion120Hz() {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool
        XCTAssertEqual(enabled, true, "Info.plist 必须开启 CADisableMinimumFrameDurationOnPhone，防止 iPhone Pro 动画锁帧")
    }

    // MARK: - 2. HoloAI 名头分组 O(N) 预计算等价性

    func testChatMessageViewDataApplyAIHeaderFlags() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var messages: [ChatMessageViewData] = [
            ChatMessageViewData(id: UUID(), role: "user", content: "你好", timestamp: t0, intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil),
            ChatMessageViewData(id: UUID(), role: "assistant", content: "第一句", timestamp: t0.addingTimeInterval(2), intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil),
            ChatMessageViewData(id: UUID(), role: "assistant", content: "连续第二句", timestamp: t0.addingTimeInterval(4), intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil),
            ChatMessageViewData(id: UUID(), role: "assistant", content: "跨时间段第三句", timestamp: t0.addingTimeInterval(600), intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil),
            ChatMessageViewData(id: UUID(), role: "assistant", content: "独立方案卡", timestamp: t0.addingTimeInterval(605), intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil, messageType: .contextPlan),
            ChatMessageViewData(id: UUID(), role: "assistant", content: "方案卡后重起名头", timestamp: t0.addingTimeInterval(610), intent: nil, extractedDataJSON: nil, isStreaming: false, parentMessageId: nil),
        ]
        messages[3].showsTimestampSeparator = true

        ChatMessageViewData.applyAIHeaderFlags(to: &messages)

        XCTAssertFalse(messages[0].showsAIHeader, "用户消息不显示 AI 名头")
        XCTAssertTrue(messages[1].showsAIHeader, "用户消息后的首条 AI 消息显示名头")
        XCTAssertFalse(messages[2].showsAIHeader, "连续普通 AI 消息并入同组，不重复显示名头")
        XCTAssertTrue(messages[3].showsAIHeader, "带时间分隔条的 AI 消息重起名头")
        XCTAssertTrue(messages[4].showsAIHeader, "独立卡片消息自成单元，显示名头")
        XCTAssertTrue(messages[5].showsAIHeader, "独立卡片之后的普通 AI 消息重起名头")
    }

    // MARK: - 3. 习惯单行增量投影与全量构建等价

    func testHabitProjectionDataUpdatingSingleHabitMatchesFullBuild() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 10, minute: 0))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let habitA = UUID()
        let habitB = UUID()

        let initialRecords = [
            HabitRecordFact(id: UUID(), habitId: habitA, date: yesterday, isCompleted: true, value: nil, isRetroactive: false),
            HabitRecordFact(id: UUID(), habitId: habitB, date: yesterday, isCompleted: true, value: 3, isRetroactive: false),
        ]

        let initialData = HabitPresentationProjector.buildData(
            records: initialRecords,
            pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [:],
            now: now,
            calendar: calendar
        )

        let newRecordA = HabitRecordFact(id: UUID(), habitId: habitA, date: now, isCompleted: true, value: nil, isRetroactive: false)
        let habitARecords = [initialRecords[0], newRecordA]

        let incremental = initialData.updatingHabit(habitA, records: habitARecords, now: now)
        let fullRebuild = HabitPresentationProjector.buildData(
            records: initialRecords + [newRecordA],
            pauseWindowsByHabit: [:],
            dayEndMinutesByHabit: [:],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(incremental.recordsByHabit[habitA], fullRebuild.recordsByHabit[habitA])
        XCTAssertEqual(incremental.completedDaysByHabit[habitA], fullRebuild.completedDaysByHabit[habitA])
        XCTAssertEqual(incremental.recordsByHabit[habitB], fullRebuild.recordsByHabit[habitB])
        XCTAssertEqual(incremental.completedDaysByHabit[habitB], fullRebuild.completedDaysByHabit[habitB])
    }

    // MARK: - 4. VisualAssetRepository 位置解析命中内存缓存（零重复 SQLite 查询）

    func testVisualAssetRepositoryResolvePlacementUsesMemoryCache() {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        let repo = VisualAssetRepository.shared
        repo.invalidatePlacementCache()
        repo.resetTestingFetchCounter()

        let ownerKey = UUID().uuidString
        let first = repo.resolvePlacement(ownerKind: "thought", ownerKey: ownerKey, slot: "hero", in: context)
        let second = repo.resolvePlacement(ownerKind: "thought", ownerKey: ownerKey, slot: "hero", in: context)

        XCTAssertEqual(first, ResolvedPlacement.none)
        XCTAssertEqual(second, ResolvedPlacement.none)
        XCTAssertEqual(repo.resolveSQLiteFetchCountForTesting, 1, "同一位置第二次解析必须命中内存缓存，不再访问 SQLite")

        repo.invalidatePlacementCache()
        _ = repo.resolvePlacement(ownerKind: "thought", ownerKey: ownerKey, slot: "hero", in: context)
        XCTAssertEqual(repo.resolveSQLiteFetchCountForTesting, 2, "缓存失效后应重新查询一次")
    }

    // MARK: - 5. HoloMotionFeedbackCenter 定向 subject 通道投递

    @MainActor
    func testHoloMotionFeedbackCenterTargetedSubjectPublisher() {
        let center = HoloMotionFeedbackCenter.shared
        let targetID = UUID()
        let expected = HoloMotionSubject(domain: .finance, id: targetID)
        var received: [HoloMotionSubject] = []
        let cancellable = center.subjectPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        center.saved(targetID, domain: .finance)
        XCTAssertTrue(received.contains(expected), "保存记录后应向 subjectPublisher 定向投递对应 subject")
    }
}
