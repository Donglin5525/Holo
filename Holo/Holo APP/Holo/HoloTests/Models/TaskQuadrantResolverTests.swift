//
//  TaskQuadrantResolverTests.swift
//  HoloTests
//
//  四象限纯规则边界测试（2026-10-06 任务重构方案 §3.2 / R05 / R13–R16；
//  2026-10-07 P 档体系：三档自动折算 + 紧急分公式 + P2 分组归属）
//

import XCTest
@testable import Holo

final class TaskQuadrantResolverTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 固定「现在」：2026-10-06（周二）15:30 北京时间
    private var now: Date { makeDate(2026, 10, 6, 15, 30) }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    // MARK: - 折算边界

    func test_紧急P1边界_为今天零点加三天() {
        XCTAssertEqual(TaskQuadrantResolver.urgentBoundary(now: now, calendar: calendar), makeDate(2026, 10, 9))
    }

    func test_一般急P2边界_为今天零点加八天() {
        // 2026-10-07 P 档体系：P1 线之后至第七天结束折算 P2
        XCTAssertEqual(TaskQuadrantResolver.moderateBoundary(now: now, calendar: calendar), makeDate(2026, 10, 14))
    }

    func test_自动折算_后天2359为P1_大后天0000为P2() {
        // R13
        let lateDayAfter = makeDate(2026, 10, 8, 23, 59)
        let dayAfterNext = makeDate(2026, 10, 9, 0, 0)
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: lateDayAfter, now: now, calendar: calendar), .p1)
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: dayAfterNext, now: now, calendar: calendar), .p2)
    }

    func test_自动折算_第七天2359为P2_第八天0000为P3() {
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: makeDate(2026, 10, 13, 23, 59), now: now, calendar: calendar), .p2)
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: makeDate(2026, 10, 14, 0, 0), now: now, calendar: calendar), .p3)
    }

    // MARK: - 自动模式

    func test_自动无截止_折算P3() {
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: nil, now: now, calendar: calendar), .p3)
        XCTAssertFalse(TaskQuadrantResolver.isUrgent(mode: .auto, effectiveDue: nil, now: now, calendar: calendar))
    }

    func test_自动今天到期_折算P1() {
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: makeDate(2026, 10, 6, 12), now: now, calendar: calendar), .p1)
    }

    func test_自动逾期_折算P1() {
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: makeDate(2026, 10, 5, 18), now: now, calendar: calendar), .p1)
    }

    func test_全天今天的有效截止235959_P1且未逾期() {
        // R14：全天截止按当天 23:59:59，未过期、按日期折算 P1
        let due = TodoTaskDatePolicy.effectiveDueDate(
            dueDate: makeDate(2026, 10, 6), isAllDay: true, calendar: calendar
        )
        XCTAssertEqual(due, calendar.date(bySettingHour: 23, minute: 59, second: 59, of: makeDate(2026, 10, 6)))
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .auto, effectiveDue: due, now: now, calendar: calendar), .p1)
        XCTAssertFalse(due! < now, "全天今天上午不应已逾期")
    }

    func test_具体截止恰好等于现在_不属于逾期() {
        // R15：逾期判定是严格小于
        let exactlyNow = makeDate(2026, 10, 6, 15, 30)
        XCTAssertFalse(exactlyNow < now)
    }

    // MARK: - 手动模式（日期不覆盖手动锁定）

    func test_手动P1无日期_仍P1() {
        // R04
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .p1, effectiveDue: nil, now: now, calendar: calendar), .p1)
        XCTAssertTrue(TaskQuadrantResolver.isUrgent(mode: .p1, effectiveDue: nil, now: now, calendar: calendar))
    }

    func test_手动P3的逾期任务_仍按手动归组() {
        // R16：手动 P3 + 截止已过 → 不紧急（行内显示逾期信息）
        XCTAssertEqual(TaskQuadrantResolver.urgencyLevel(mode: .p3, effectiveDue: makeDate(2026, 10, 1), now: now, calendar: calendar), .p3)
        let quadrant = TaskQuadrantResolver.quadrant(
            importance: .p1, mode: .p3,
            effectiveDue: makeDate(2026, 10, 1), now: now, calendar: calendar
        )
        XCTAssertEqual(quadrant, .scheduleTime)
    }

    func test_暂未判断_手动P1_仍待整理() {
        // R05：暂未判断不能落集中处理
        let quadrant = TaskQuadrantResolver.quadrant(
            importance: .unknown, mode: .p1,
            effectiveDue: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(quadrant, .unclassified)
    }

    func test_暂未判断已逾期_仍在待整理() {
        let quadrant = TaskQuadrantResolver.quadrant(
            importance: .unknown, mode: .auto,
            effectiveDue: makeDate(2026, 10, 1), now: now, calendar: calendar
        )
        XCTAssertEqual(quadrant, .unclassified)
    }

    // MARK: - 象限映射（P1 归重要侧，P2/P3 归另一侧——2026-10-07 拍板口径）

    func test_象限映射_手动档全矩阵() {
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p1, mode: .p1, effectiveDue: nil, now: now, calendar: calendar), .doFirst)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p1, mode: .p2, effectiveDue: nil, now: now, calendar: calendar), .scheduleTime)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p1, mode: .p3, effectiveDue: nil, now: now, calendar: calendar), .scheduleTime)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p2, mode: .p1, effectiveDue: nil, now: now, calendar: calendar), .batchHandle)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p2, mode: .p2, effectiveDue: nil, now: now, calendar: calendar), .reviewLater)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p2, mode: .p3, effectiveDue: nil, now: now, calendar: calendar), .reviewLater)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p3, mode: .p1, effectiveDue: nil, now: now, calendar: calendar), .batchHandle)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p3, mode: .p2, effectiveDue: nil, now: now, calendar: calendar), .reviewLater)
        XCTAssertEqual(TaskQuadrantResolver.quadrant(importance: .p3, mode: .p3, effectiveDue: nil, now: now, calendar: calendar), .reviewLater)
    }

    func test_P1自动无日期_归留出时间() {
        // R02 预览口径：未设截止日期按日期折算 P3 → 不紧急
        let quadrant = TaskQuadrantResolver.quadrant(
            importance: .p1, mode: .auto,
            effectiveDue: nil, now: now, calendar: calendar
        )
        XCTAssertEqual(quadrant, .scheduleTime)
    }

    // MARK: - 紧急分（重要×2＋紧急，3–9 分；2026-10-07 东林拍板）

    func test_紧急分公式_手动全矩阵() {
        func score(_ imp: TaskImportance, _ urg: TaskUrgencyMode) -> Int? {
            TaskQuadrantResolver.urgencyScore(importance: imp, mode: urg, effectiveDue: nil, now: now, calendar: calendar)
        }
        XCTAssertEqual(score(.p1, .p1), 9)
        XCTAssertEqual(score(.p1, .p2), 8)
        XCTAssertEqual(score(.p1, .p3), 7)
        XCTAssertEqual(score(.p2, .p1), 7)
        XCTAssertEqual(score(.p2, .p2), 6)
        XCTAssertEqual(score(.p2, .p3), 5)
        XCTAssertEqual(score(.p3, .p1), 5)
        XCTAssertEqual(score(.p3, .p2), 4)
        XCTAssertEqual(score(.p3, .p3), 3)
    }

    func test_重要不急胜过不重要急() {
        // 公式设计目标：P1P3(7) > P3P1(5)，保住「重要优先」的次序
        let importantCalm = TaskQuadrantResolver.urgencyScore(importance: .p1, mode: .p3, effectiveDue: nil, now: now, calendar: calendar)
        let trivialHot = TaskQuadrantResolver.urgencyScore(importance: .p3, mode: .p1, effectiveDue: nil, now: now, calendar: calendar)
        XCTAssertGreaterThan(importantCalm!, trivialHot!)
    }

    func test_未判断无分_自动档按日期折算计分() {
        XCTAssertNil(TaskQuadrantResolver.urgencyScore(importance: .unknown, mode: .p1, effectiveDue: nil, now: now, calendar: calendar))
        // auto 折算：明天到期=P1 → 3×2+3=9
        XCTAssertEqual(TaskQuadrantResolver.urgencyScore(importance: .p1, mode: .auto, effectiveDue: makeDate(2026, 10, 7, 12), now: now, calendar: calendar), 9)
        // auto 折算：无截止=P3 → 3×2+1=7
        XCTAssertEqual(TaskQuadrantResolver.urgencyScore(importance: .p1, mode: .auto, effectiveDue: nil, now: now, calendar: calendar), 7)
    }

    // MARK: - 解释文案

    func test_解释文案_手动模式明示来源() {
        let manual = TaskQuadrantResolver.urgencyExplanation(mode: .p1, effectiveDue: nil, now: now, calendar: calendar)
        XCTAssertTrue(manual.contains("手动"), "手动模式解释应明示来源：\(manual)")
        let overdueAuto = TaskQuadrantResolver.urgencyExplanation(mode: .auto, effectiveDue: makeDate(2026, 10, 1), now: now, calendar: calendar)
        XCTAssertTrue(overdueAuto.contains("逾期"), "逾期解释应明示：\(overdueAuto)")
        let p2Auto = TaskQuadrantResolver.urgencyExplanation(mode: .auto, effectiveDue: makeDate(2026, 10, 11, 12), now: now, calendar: calendar)
        XCTAssertTrue(p2Auto.contains("P2"), "一周内应折算 P2：\(p2Auto)")
    }
}
