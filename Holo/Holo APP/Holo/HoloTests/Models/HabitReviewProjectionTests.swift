//
//  HabitReviewProjectionTests.swift
//  HoloTests
//
//  2026-10-07 V2 回顾投影验证（方案 §10/§13）：
//  半开区间与月归属、记录日去重、坏习惯发生计入、计数 SUM / 测量 LATEST、
//  真实 0 与缺失分开、生命周期集合规则、可见集合三态。
//

import XCTest
@testable import Holo

final class HabitReviewProjectionTests: XCTestCase {

    // 固定时钟与历法（北京时间），避免测试随时区漂移
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 2026-10-07 12:00（周三）
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
    }

    private var oct: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))! }
    private var sep: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))! }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func fact(_ habitId: UUID, _ date: Date,
                      completed: Bool = true, value: Double? = nil,
                      retroactive: Bool = false) -> HabitRecordFact {
        HabitRecordFact(id: UUID(), habitId: habitId, date: date,
                        isCompleted: completed, value: value, isRetroactive: retroactive)
    }

    private func info(_ id: UUID, kind: HabitRowKind = .checkIn,
                      bad: Bool = false, lifecycle: HabitLifecycle = .active,
                      created: Date? = nil, unit: String = "") -> HabitReviewHabitInfo {
        HabitReviewHabitInfo(id: id, name: "习惯", kind: kind,
                             isBadHabit: bad, lifecycle: lifecycle,
                             createdAt: created ?? day(2026, 8, 1), unit: unit)
    }

    private func buildData(_ facts: [HabitRecordFact]) -> HabitProjectionData {
        HabitPresentationProjector.buildData(
            records: facts, pauseWindowsByHabit: [:], now: now, calendar: calendar)
    }

    // MARK: - 范围契约（R11）

    func test_月区间半开_九月末属九月_十月零点只属十月() {
        let sepInterval = HabitReviewRange.month(sep).dateInterval(now: now, calendar: calendar)
        XCTAssertEqual(sepInterval.start, sep)
        XCTAssertEqual(sepInterval.end, oct)

        // 9月30日23:59 → 九月；10月1日00:00 → 十月（互斥）。
        // 手写半开比较：DateInterval.contains 是闭区间语义（含 end），不用于边界判定
        let sepLast = day(2026, 9, 30, hour: 23) + 3540
        XCTAssertTrue(sepLast >= sepInterval.start && sepLast < sepInterval.end)
        XCTAssertFalse(oct >= sepInterval.start && oct < sepInterval.end)

        let octInterval = HabitReviewRange.month(oct).dateInterval(now: now, calendar: calendar)
        XCTAssertTrue(oct >= octInterval.start && oct < octInterval.end)
        XCTAssertFalse(sepLast >= octInterval.start && sepLast < octInterval.end)
    }

    func test_含今天的范围钳到明天零点_未来时刻记录被投影排除() {
        let interval = HabitReviewRange.lastDays(7).dateInterval(now: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(interval.end, tomorrow)
        XCTAssertTrue(calendar.startOfDay(for: now) >= interval.start)

        // 「未来时刻排除」由投影底座的 now 过滤兜底（buildData 只收 date <= now）
        let id = UUID()
        let data = buildData([fact(id, now.addingTimeInterval(3600))])
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .lastDays(7), data: data)
        XCTAssertEqual(snapshot.recordedDayCount, 0)
    }

    func test_自定义范围含端日() {
        let start = day(2026, 10, 1)
        let end = day(2026, 10, 3)
        let interval = HabitReviewRange.custom(start: start, end: end)
            .dateInterval(now: now, calendar: calendar)
        XCTAssertTrue(day(2026, 10, 1, hour: 0) >= interval.start && day(2026, 10, 1, hour: 0) < interval.end)
        XCTAssertTrue(day(2026, 10, 3, hour: 23) >= interval.start && day(2026, 10, 3, hour: 23) < interval.end)
        XCTAssertFalse(day(2026, 10, 4, hour: 0) >= interval.start && day(2026, 10, 4, hour: 0) < interval.end)
    }

    // MARK: - 记录日去重（R08）

    func test_同习惯同日多条记录只算一个记录日() {
        let id = UUID()
        let d = day(2026, 10, 5)
        let facts = [
            fact(id, d, completed: false, value: 2),   // 取消态打卡 + 数值
            fact(id, d.addingTimeInterval(3600), completed: false, value: 3),
            fact(id, d.addingTimeInterval(7200), completed: false, value: 0), // 真实 0
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, kind: .count, unit: "杯"),
            range: .month(oct), data: buildData(facts))
        XCTAssertEqual(snapshot.recordedDayCount, 1)
        XCTAssertEqual(snapshot.countTotal, 5) // 2+3+0
    }

    func test_多习惯同日算一个整体记录日_习惯数各自去重() {
        let a = UUID(), b = UUID(), c = UUID()
        let d = day(2026, 10, 5)
        let facts = [
            fact(a, d), fact(a, d.addingTimeInterval(600)), // a 同日两条
            fact(b, d),                                     // b 同日一条
            fact(c, day(2026, 10, 6)),                      // c 次日
        ]
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(a), info(b), info(c)],
            visibleIds: nil, orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(overview.activeRecordDays, 2)     // 10-05 / 10-06
        XCTAssertEqual(overview.recordedHabitCount, 3)   // a/b/c
    }

    // MARK: - 坏习惯（R09）

    func test_坏习惯发生日计入记录天数_无记录不算成功() {
        let id = UUID()
        var facts = [fact(id, day(2026, 10, 1)),
                     fact(id, day(2026, 10, 3))]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, bad: true), range: .month(oct), data: buildData(facts))
        XCTAssertEqual(snapshot.recordedDayCount, 2) // 发生日计入

        // 全月无发生记录：0 天，不生成「控制成功」
        facts = []
        let empty = HabitReviewProjector.rangeSnapshot(
            info: info(id, bad: true), range: .month(oct), data: buildData(facts))
        XCTAssertEqual(empty.recordedDayCount, 0)
    }

    func test_坏习惯计数_发生天数与总量都来自真实记录() {
        let id = UUID()
        let facts = [
            fact(id, day(2026, 10, 1), completed: false, value: 2),
            fact(id, day(2026, 10, 1, hour: 20), completed: false, value: 4),
            fact(id, day(2026, 10, 3), completed: false, value: 1),
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, kind: .count, bad: true, unit: "支"),
            range: .month(oct), data: buildData(facts))
        XCTAssertEqual(snapshot.recordedDayCount, 2)
        XCTAssertEqual(snapshot.countTotal, 7)

        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(id, kind: .count, bad: true, unit: "支")],
            visibleIds: nil, orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(overview.rows.first?.resultText, "发生 2 天 · 共 7 支")
    }

    // MARK: - 数值聚合（R10）

    func test_测量最近值按日LATEST取范围内最后样本_真实0有效() {
        let id = UUID()
        let facts = [
            fact(id, day(2026, 10, 1), completed: false, value: 63.5),
            fact(id, day(2026, 10, 5, hour: 8), completed: false, value: 63.2),
            fact(id, day(2026, 10, 6, hour: 7), completed: false, value: 0), // 真实 0
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, kind: .measure, unit: "kg"),
            range: .month(oct), data: buildData(facts))
        XCTAssertEqual(snapshot.latestMeasure?.value, 0)     // 最近值是真实 0，不是缺失
        XCTAssertEqual(snapshot.latestMeasure?.day, calendar.startOfDay(for: day(2026, 10, 6)))
        XCTAssertEqual(snapshot.recordedDayCount, 3)
        XCTAssertNil(snapshot.countTotal) // 测量不累计
    }

    func test_缺失日不产生日值_不被补0() {
        let id = UUID()
        let facts = [
            fact(id, day(2026, 10, 1), completed: false, value: 63.5),
            fact(id, day(2026, 10, 5), completed: false, value: 63.2),
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, kind: .measure, unit: "kg"),
            range: .month(oct), data: buildData(facts))
        XCTAssertEqual(snapshot.dailyValues.count, 2) // 10-02/03/04 缺失不出现
        let mid = snapshot.day(day(2026, 10, 3), today: now, calendar: calendar)
        XCTAssertFalse(mid.isRecorded)
        XCTAssertNil(mid.dailyValue)
    }

    // MARK: - 生命周期集合规则（R12）

    func test_暂停归档习惯当月有记录仍进列表并标状态() {
        let pausedId = UUID(), archivedId = UUID()
        let facts = [fact(pausedId, day(2026, 10, 2)),
                     fact(archivedId, day(2026, 10, 3))]
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(pausedId, lifecycle: .paused),
                     info(archivedId, lifecycle: .archived)],
            visibleIds: nil, orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(overview.rows.count, 2)
        XCTAssertEqual(overview.rows.first { $0.id == pausedId }?.lifecycle, .paused)
        XCTAssertEqual(overview.rows.first { $0.id == archivedId }?.lifecycle, .archived)
        XCTAssertEqual(overview.recordedHabitCount, 2)
    }

    func test_暂停归档当月无记录不占行_活跃无记录显示该月无记录() {
        let activeId = UUID(), pausedId = UUID(), archivedId = UUID()
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(activeId), info(pausedId, lifecycle: .paused),
                     info(archivedId, lifecycle: .archived)],
            visibleIds: nil, orderedIds: [], month: oct, data: buildData([]))
        XCTAssertEqual(overview.rows.count, 1)
        XCTAssertEqual(overview.rows.first?.id, activeId)
        XCTAssertEqual(overview.rows.first?.resultText, "该月无记录")
    }

    func test_创建晚于月末的活跃习惯不生成未完成行() {
        let lateId = UUID(), earlyId = UUID()
        // late 10月15日才创建：九月不应出现
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(lateId, created: day(2026, 10, 15)),
                     info(earlyId, created: day(2026, 1, 1))],
            visibleIds: nil, orderedIds: [], month: sep, data: buildData([]))
        XCTAssertEqual(overview.rows.map(\.id), [earlyId])
    }

    func test_创建前日期不可记录_未来日期不可记录() {
        let id = UUID()
        let facts = [fact(id, day(2026, 9, 5))]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, created: day(2026, 10, 1)),
            range: .month(oct), data: buildData(facts))
        let before = snapshot.day(day(2026, 9, 5), today: now, calendar: calendar)
        XCTAssertTrue(before.isBeforeCreation)
        let future = snapshot.day(day(2026, 10, 8), today: now, calendar: calendar)
        XCTAssertTrue(future.isFuture)
    }

    // MARK: - 可见集合三态（R13）

    func test_可见集合三态_全部_全关闭_白名单() {
        let a = UUID(), b = UUID()
        let habits = [info(a), info(b)]
        let facts = [fact(a, day(2026, 10, 1)), fact(b, day(2026, 10, 1))]

        // nil = 全部
        let all = HabitReviewProjector.overviewSnapshot(
            habits: habits, visibleIds: nil, orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(all.rows.count, 2)
        XCTAssertEqual(all.activeRecordDays, 1)
        XCTAssertEqual(all.recordedHabitCount, 2)

        // [] = 全关闭：列表空 + 摘要 0（保持关闭，不回退成全部）
        let off = HabitReviewProjector.overviewSnapshot(
            habits: habits, visibleIds: [], orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(off.rows.count, 0)
        XCTAssertEqual(off.activeRecordDays, 0)
        XCTAssertEqual(off.recordedHabitCount, 0)

        // 白名单只含 a
        let whitelist = HabitReviewProjector.overviewSnapshot(
            habits: habits, visibleIds: [a], orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(whitelist.rows.map(\.id), [a])
        XCTAssertEqual(whitelist.recordedHabitCount, 1)
    }

    func test_排序_白名单覆盖优先_未覆盖按稳定ID兜底() {
        let a = UUID(), b = UUID(), c = UUID()
        let ordered = [c, a] // b 未覆盖
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(a), info(b), info(c)],
            visibleIds: nil,
            orderedIds: ordered,
            month: oct,
            data: buildData([fact(a, day(2026, 10, 1)), fact(b, day(2026, 10, 1)), fact(c, day(2026, 10, 1))]))
        XCTAssertEqual(overview.rows.map(\.id).first, c)
        XCTAssertEqual(overview.rows.map(\.id).dropFirst().first, a)
        XCTAssertEqual(overview.rows.count, 3)
    }

    // MARK: - 孤儿记录排除

    func test_孤儿记录不影响整体摘要() {
        let a = UUID()
        let orphan = UUID() // 不在 habits 集合中（父已删除）
        let facts = [fact(a, day(2026, 10, 1)), fact(orphan, day(2026, 10, 2))]
        let overview = HabitReviewProjector.overviewSnapshot(
            habits: [info(a)], visibleIds: nil, orderedIds: [], month: oct, data: buildData(facts))
        XCTAssertEqual(overview.recordedHabitCount, 1)
        XCTAssertEqual(overview.activeRecordDays, 1)
    }

    // MARK: - 单日投影字段

    func test_单日投影_暂停日_补录标记_当日聚合() {
        let id = UUID()
        let pauseStart = day(2026, 10, 4)
        let infoPaused = HabitReviewHabitInfo(
            id: id, kind: .count, unit: "杯",
            pauseWindows: [HabitPauseWindow(startDate: pauseStart, endDate: day(2026, 10, 10))])
        let facts = [
            fact(id, day(2026, 10, 5, hour: 8), completed: false, value: 1, retroactive: true),
            fact(id, day(2026, 10, 5, hour: 9), completed: false, value: 2),
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: infoPaused, range: .month(oct), data: buildData(facts))
        let d = snapshot.day(day(2026, 10, 5), today: now, calendar: calendar)
        XCTAssertTrue(d.isRecorded)
        XCTAssertTrue(d.isPaused)       // 暂停期间有记录：两个事实并存
        XCTAssertTrue(d.isRetroactive)
        XCTAssertEqual(d.dailyValue, 3) // 当日 SUM
    }
}
