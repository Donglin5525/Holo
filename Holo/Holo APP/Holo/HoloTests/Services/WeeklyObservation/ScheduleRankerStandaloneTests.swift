//
//  ScheduleRankerStandaloneTests.swift
//  Holo
//
//  首页胶囊排序 Ranker standalone test（纯逻辑 TDD，方案 §4.4 / §5 Phase 3）
//
//  运行：
//    swiftc \
//      Holo/Services/WeeklyObservation/ScheduleRankingModels.swift \
//      HoloTests/Services/WeeklyObservation/ScheduleRankerStandaloneTests.swift \
//      -o /tmp/sr && /tmp/sr
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ScheduleRankerStandaloneTests.main()
    }
}
#endif
struct ScheduleRankerStandaloneTests {

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }()

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm)) ?? Date()
    }

    static func main() {
        testNewInsightBeatsOverdue()
        testOverdueBeatsToday()
        testTodayBeatsUpcoming()
        testTiebreakerByModule()
        testTiebreakerById()
        testEmptyReturnsNil()
        testStableOrdering()
        testProtectionWindow()
        testSingleCandidate()
        testWeeklyDeliveryRequiresAvailableUnreadTargetWeek()

        print("✅ ScheduleRankerStandaloneTests 全部通过")
    }

    // MARK: - Cases

    /// P0 新观察未读压过 P1 逾期任务（方案 §2.4）
    static func testNewInsightBeatsOverdue() {
        let newObs = ScheduleCandidate(
            id: "obs-1", urgency: .newInsight, module: .weeklyObservation,
            message: "新观察", protectionUntil: date(2026, 7, 8, 12, 0)
        )
        let overdue = ScheduleCandidate(
            id: "task-1", urgency: .overdue, module: .task,
            message: "逾期", protectionUntil: nil
        )
        let top = ScheduleRanker.topCandidate([overdue, newObs])
        expect(top?.id == "obs-1", "newInsight(P0) 压过 overdue(P1)")
    }

    static func testOverdueBeatsToday() {
        let top = ScheduleRanker.topCandidate([
            ScheduleCandidate(id: "t1", urgency: .today, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "t2", urgency: .overdue, module: .task, message: "", protectionUntil: nil)
        ])
        expect(top?.id == "t2", "overdue 压过 today")
    }

    static func testTodayBeatsUpcoming() {
        let top = ScheduleRanker.topCandidate([
            ScheduleCandidate(id: "u", urgency: .upcoming, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "t", urgency: .today, module: .task, message: "", protectionUntil: nil)
        ])
        expect(top?.id == "t", "today 压过 upcoming")
    }

    /// 同 urgency 时按 module 字典序（insight < task < weeklyObservation）
    static func testTiebreakerByModule() {
        let top = ScheduleRanker.topCandidate([
            ScheduleCandidate(id: "a", urgency: .pending, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "b", urgency: .pending, module: .insight, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "c", urgency: .pending, module: .weeklyObservation, message: "", protectionUntil: nil)
        ])
        expect(top?.id == "b", "同 urgency 时 insight 排最前（module 字典序）")
    }

    /// 同 urgency + module 时按 id 字典序
    static func testTiebreakerById() {
        let top = ScheduleRanker.topCandidate([
            ScheduleCandidate(id: "z", urgency: .pending, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "a", urgency: .pending, module: .task, message: "", protectionUntil: nil)
        ])
        expect(top?.id == "a", "同 urgency+module 时 id 字典序")
    }

    static func testEmptyReturnsNil() {
        expect(ScheduleRanker.topCandidate([]) == nil, "空数组返回 nil")
    }

    static func testSingleCandidate() {
        let only = ScheduleCandidate(id: "x", urgency: .pending, module: .insight, message: "", protectionUntil: nil)
        expect(ScheduleRanker.topCandidate([only])?.id == "x", "单候选直接返回")
    }

    /// 多次排序结果一致 + 顺序正确（稳定 tiebreaker，方案 §4.4「文案不抖动」）
    static func testStableOrdering() {
        let cs = [
            ScheduleCandidate(id: "c", urgency: .today, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "a", urgency: .overdue, module: .task, message: "", protectionUntil: nil),
            ScheduleCandidate(id: "b", urgency: .overdue, module: .task, message: "", protectionUntil: nil)
        ]
        let r1 = ScheduleRanker.rank(cs).map(\.id)
        let r2 = ScheduleRanker.rank(cs).map(\.id)
        expect(r1 == r2, "排序稳定（多次一致）")
        expect(r1 == ["a", "b", "c"], "顺序正确：overdue a/b 字典序 → today c")
    }

    /// 保护期判定（方案 §4.4 24h 保护期）
    static func testProtectionWindow() {
        let now = date(2026, 7, 7, 12, 0)
        let within = ScheduleCandidate(
            id: "x", urgency: .newInsight, module: .weeklyObservation,
            message: "", protectionUntil: date(2026, 7, 8, 12, 0)
        )
        let expired = ScheduleCandidate(
            id: "y", urgency: .newInsight, module: .weeklyObservation,
            message: "", protectionUntil: date(2026, 7, 6, 12, 0)
        )
        let none = ScheduleCandidate(
            id: "z", urgency: .pending, module: .task, message: "", protectionUntil: nil
        )
        expect(ScheduleRanker.isProtected(within, now: now), "保护期内 → true")
        expect(!ScheduleRanker.isProtected(expired, now: now), "保护期外 → false")
        expect(!ScheduleRanker.isProtected(none, now: now), "无保护期字段 → false")
    }

    static func testWeeklyDeliveryRequiresAvailableUnreadTargetWeek() {
        let targetStart = date(2026, 7, 6)
        expect(
            WeeklyObservationDeliveryPolicy.shouldDeliver(
                status: "ready", readAt: nil,
                insightPeriodStart: targetStart, targetPeriodStart: targetStart,
                calendar: cal
            ),
            "目标上周 ready 且未读可以投递"
        )
        expect(
            WeeklyObservationDeliveryPolicy.shouldDeliver(
                status: "stale", readAt: nil,
                insightPeriodStart: targetStart, targetPeriodStart: targetStart,
                calendar: cal
            ),
            "目标上周 stale 且未读可以投递"
        )
        expect(
            !WeeklyObservationDeliveryPolicy.shouldDeliver(
                status: "failed", readAt: nil,
                insightPeriodStart: targetStart, targetPeriodStart: targetStart,
                calendar: cal
            ),
            "failed 不投递"
        )
        expect(
            !WeeklyObservationDeliveryPolicy.shouldDeliver(
                status: "ready", readAt: date(2026, 7, 13),
                insightPeriodStart: targetStart, targetPeriodStart: targetStart,
                calendar: cal
            ),
            "已读不重复投递"
        )
        expect(
            !WeeklyObservationDeliveryPolicy.shouldDeliver(
                status: "ready", readAt: nil,
                insightPeriodStart: date(2026, 6, 29), targetPeriodStart: targetStart,
                calendar: cal
            ),
            "历史周未读洞察不重新投递"
        )
    }

    // MARK: - Assert helper

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ✓ \(message)")
        } else {
            print("  ✗ FAILED: \(message)")
            fatalError("断言失败：\(message)")
        }
    }
}
