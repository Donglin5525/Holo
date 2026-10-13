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

    // MARK: - 日历显示月派生（2026-10-09 真机实锤：切「上月」后日历仍画本月）

    func test_月范围显示月恒为范围月_不落翻月状态() {
        let staleCalendarMonth = oct // 翻月状态停在十月（切「上月」前的残留）
        let display = HabitReviewRange.month(sep)
            .calendarDisplayMonth(fallback: staleCalendarMonth)
        XCTAssertEqual(display, sep)
    }

    func test_跨月范围显示月用翻月状态() {
        let panned = day(2026, 9, 1)
        XCTAssertEqual(HabitReviewRange.lastDays(30).calendarDisplayMonth(fallback: panned), panned)
        XCTAssertEqual(HabitReviewRange.all.calendarDisplayMonth(fallback: panned), panned)
    }

    // MARK: - 界日记录归属（rangeSnapshot 过滤必须半开）

    func test_次月零点整记录不漏进本月范围() {
        let id = UUID()
        let facts = [
            fact(id, oct),                       // 10/1 00:00 整（界日）
            fact(id, day(2026, 9, 15)),
        ]
        let data = buildData(facts)
        // 九月快照：只认 9/15，界日记录不算九月
        let sepSnapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .month(sep), data: data)
        XCTAssertEqual(sepSnapshot.recordedDayCount, 1)
        XCTAssertTrue(sepSnapshot.containsDay(day(2026, 9, 15), calendar: calendar))
        XCTAssertFalse(sepSnapshot.containsDay(oct, calendar: calendar))
        // 十月快照：界日记录归十月
        let octSnapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .month(oct), data: data)
        XCTAssertEqual(octSnapshot.recordedDayCount, 1)
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

    // MARK: - 周走势（方案A 2026-10-12：打卡型第一次有走势图）

    /// now=10/7（周三）：本月范围首桶周一=9/28，但只从范围首日 10/1 起数
    func test_周走势_分桶周一首界_范围前不计分母() {
        let id = UUID()
        let facts = [
            fact(id, day(2026, 10, 1)), fact(id, day(2026, 10, 2)),
            fact(id, day(2026, 10, 5)), fact(id, day(2026, 10, 6)), fact(id, day(2026, 10, 7)),
        ]
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .month(oct), data: buildData(facts))
        let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: buildData(facts))
        XCTAssertEqual(trend.mode, .completionRate)
        XCTAssertEqual(trend.bars.count, 2)
        // 桶1（10/1-10/4，4 个有效天，记 2 天）
        XCTAssertEqual(trend.bars[0].weekStart, calendar.startOfDay(for: day(2026, 9, 28)))
        XCTAssertEqual(trend.bars[0].days, 4)
        XCTAssertEqual(trend.bars[0].recordedDays, 2)
        XCTAssertEqual(trend.bars[0].fraction ?? -1, 0.5, accuracy: 0.001)
        // 桶2（10/5-10/7 到今天，3 个有效天，记 3 天）
        XCTAssertEqual(trend.bars[1].days, 3)
        XCTAssertEqual(trend.bars[1].recordedDays, 3)
        XCTAssertEqual(trend.bars[1].fraction ?? -1, 1.0, accuracy: 0.001)
    }

    func test_周走势_创建前与暂停日不计入分母() {
        let id = UUID()
        let habitInfo = HabitReviewHabitInfo(
            id: id, kind: .checkIn, createdAt: day(2026, 10, 2),
            pauseWindows: [HabitPauseWindow(startDate: day(2026, 10, 5), endDate: day(2026, 10, 6))])
        let facts = [fact(id, day(2026, 10, 3))]
        let data = buildData(facts)
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: habitInfo, range: .month(oct), data: data)
        let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: data)
        // 桶1（10/1-10/4）：10/1 创建前剔除 → 3 个有效天；只记了 10/3
        XCTAssertEqual(trend.bars[0].days, 3)
        XCTAssertEqual(trend.bars[0].recordedDays, 1)
        // 桶2（10/5-10/7）：暂停窗剔 10/5、10/6 → 1 个有效天
        XCTAssertEqual(trend.bars[1].days, 1)
        XCTAssertEqual(trend.bars[1].recordedDays, 0)
    }

    func test_周走势_坏习惯与周月习惯用每周天数模式() {
        let badId = UUID()
        let badSnapshot = HabitReviewProjector.rangeSnapshot(
            info: info(badId, bad: true), range: .month(oct), data: buildData([fact(badId, day(2026, 10, 1))]))
        XCTAssertEqual(HabitReviewProjector.weeklyTrend(snapshot: badSnapshot, data: buildData([fact(badId, day(2026, 10, 1))])).mode,
                       .weeklyDays)

        let weeklyId = UUID()
        let weeklyInfo = HabitReviewHabitInfo(id: weeklyId, kind: .checkIn, frequency: .weekly)
        let weeklySnapshot = HabitReviewProjector.rangeSnapshot(
            info: weeklyInfo, range: .month(oct), data: buildData([]))
        XCTAssertEqual(HabitReviewProjector.weeklyTrend(snapshot: weeklySnapshot, data: buildData([])).mode,
                       .weeklyDays)
    }

    func test_周走势_超长范围只保留最近12周() {
        let id = UUID()
        let start = day(2026, 7, 10)
        let end = day(2026, 10, 6)
        let data = buildData([])
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .custom(start: start, end: end), data: data)
        let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: data)
        XCTAssertEqual(trend.bars.count, 12)
    }

    // MARK: - 「全部」范围不卡死（2026-10-13 真机点「全部」闪退实锤，两闸门均漏）

    /// 「全部」的范围首日是 distantPast：分桶必须被封底在 maxWeeks 周内，
    /// 从公元逐周迭代会卡死主线程被 watchdog 杀掉
    func test_周走势_全部范围封底12桶_不起死循环() {
        let id = UUID()
        let facts = [fact(id, now)]  // 只有今天一条
        let data = buildData(facts)
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .all, data: data)
        let started = Date()
        let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: data)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0, "全部范围分桶应在秒级完成")
        XCTAssertLessThanOrEqual(trend.bars.count, 12)
        XCTAssertFalse(trend.bars.isEmpty)
        // 末桶=今天所在周（以当天零点起算）
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(trend.bars.last?.weekStart,
                       calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7),
                                     to: today))
    }

    /// 「全部」没有「再往前一段」的语义：不比上期；等长上期窗口（约74万天）逐日循环同样卡死
    func test_上期对比_全部范围不比上期() {
        let id = UUID()
        let data = buildData([fact(id, now)])
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .all, data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        XCTAssertNil(comparison.previous)
        XCTAssertNil(comparison.previousStart)
    }

    func test_上期对比_超长自定义范围钳制不比上期() {
        let id = UUID()
        let data = buildData([fact(id, now)])
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id),
            range: .custom(start: day(2024, 1, 1), end: day(2026, 10, 6)),
            data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        XCTAssertNil(comparison.previous)
    }

    // MARK: - 本期 vs 上期对比（方案A：等长窗口 + 完成率归一）

    func test_上期对比_月范围上期为紧邻等长窗口() {
        let id = UUID()
        // 本期 10/1-10/7（7 天）记 5 天；上期 9/24-9/30（7 天）记 2 天
        let facts = [
            fact(id, day(2026, 10, 1)), fact(id, day(2026, 10, 2)), fact(id, day(2026, 10, 3)),
            fact(id, day(2026, 10, 4)), fact(id, day(2026, 10, 5)),
            fact(id, day(2026, 9, 24)), fact(id, day(2026, 9, 25)),
        ]
        let data = buildData(facts)
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id), range: .month(oct), data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        XCTAssertEqual(comparison.current.recordedDays, 5)
        XCTAssertEqual(comparison.current.validDays, 7)
        XCTAssertEqual(comparison.previous?.recordedDays, 2)
        XCTAssertEqual(comparison.previous?.validDays, 7)
        XCTAssertEqual(comparison.previousLabel, "上月同期")
        XCTAssertEqual(comparison.previousStart, calendar.startOfDay(for: day(2026, 9, 24)))
    }

    func test_上期对比_上期全在创建前不比() {
        let id = UUID()
        // 创建日 10/1：上期窗口 9/24-9/30 全在创建前，没有可比基线
        let data = buildData([fact(id, day(2026, 10, 1))])
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, created: day(2026, 10, 1)), range: .month(oct), data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        XCTAssertNil(comparison.previous)
        XCTAssertEqual(comparison.current.recordedDays, 1)
    }

    func test_上期对比_暂停日从有效天剔除() {
        let id = UUID()
        let habitInfo = HabitReviewHabitInfo(
            id: id, kind: .checkIn, createdAt: day(2026, 8, 1),
            pauseWindows: [HabitPauseWindow(startDate: day(2026, 9, 24), endDate: day(2026, 9, 25))])
        let facts = [fact(id, day(2026, 10, 1)), fact(id, day(2026, 9, 26))]
        let data = buildData(facts)
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: habitInfo, range: .month(oct), data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        // 上期 9/24-9/30（7 天）中 9/24、9/25 暂停剔除 → 5 个有效天，记 1 天
        XCTAssertEqual(comparison.previous?.validDays, 5)
        XCTAssertEqual(comparison.previous?.recordedDays, 1)
    }

    func test_上期对比_测量均值口径() {
        let id = UUID()
        let facts = [
            fact(id, day(2026, 10, 1), completed: false, value: 74),
            fact(id, day(2026, 10, 2), completed: false, value: 75),
            fact(id, day(2026, 9, 24), completed: false, value: 76),
            fact(id, day(2026, 9, 25), completed: false, value: 78),
        ]
        let data = buildData(facts)
        let snapshot = HabitReviewProjector.rangeSnapshot(
            info: info(id, kind: .measure, unit: "kg"), range: .month(oct), data: data)
        let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
        XCTAssertEqual(comparison.current.measureAverage ?? -1, 74.5, accuracy: 0.001)
        XCTAssertEqual(comparison.previous?.measureAverage ?? -1, 77.0, accuracy: 0.001)
    }

    // MARK: - 全范围×全类型矩阵（2026-10-13 东林「不想再发生下一次」总闸：任何组合不许卡死）

    /// 六种习惯形态 × 六个范围档全部组合：统计计算须在时限内完成、结果有界。
    /// 「点全部闪退」这类缺陷的根因是某个组合没被测过——此用例保证没有漏网组合。
    func test_全范围全类型矩阵_计算有界不卡死() {
        let calendar = self.calendar
        // 记录铺开：昨天 / 7天前 / 40天前 / 100天前 / 300天前（覆盖所有范围的窗口）
        let offsets = [1, 7, 40, 100, 300]
        func fixtures(_ id: UUID, kind: HabitRowKind) -> [HabitRecordFact] {
            offsets.compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
                if kind == .checkIn {
                    return fact(id, day)
                }
                return fact(id, day, completed: false, value: Double(offset % 9 + 1))
            }
        }

        let ids = (
            checkInDaily: UUID(), checkInDailyBad: UUID(), checkInWeekly: UUID(),
            checkInMonthly: UUID(), count: UUID(), measure: UUID()
        )
        let habits: [(String, HabitReviewHabitInfo)] = [
            ("打卡·每日·好", info(ids.checkInDaily)),
            ("打卡·每日·坏", info(ids.checkInDailyBad, bad: true)),
            ("打卡·每周", HabitReviewHabitInfo(id: ids.checkInWeekly, kind: .checkIn, frequency: .weekly)),
            ("打卡·每月", HabitReviewHabitInfo(id: ids.checkInMonthly, kind: .checkIn, frequency: .monthly)),
            ("计数", info(ids.count, kind: .count, unit: "次")),
            ("测量", info(ids.measure, kind: .measure, unit: "kg")),
        ]
        let ranges: [(String, HabitReviewRange)] = [
            ("本月", .month(oct)),
            ("过去月", .month(sep)),
            ("近30天", .lastDays(30)),
            ("近90天", .lastDays(90)),
            ("全部", .all),
            ("超长自定义", .custom(start: day(2024, 1, 1), end: day(2026, 10, 6))),
        ]

        for (typeName, habitInfo) in habits {
            let data = buildData(fixtures(habitInfo.id, kind: habitInfo.kind))
            for (rangeName, range) in ranges {
                let snapshot = HabitReviewProjector.rangeSnapshot(info: habitInfo, range: range, data: data)
                let started = Date()
                let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: data)
                let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
                let elapsed = Date().timeIntervalSince(started)
                XCTAssertLessThan(elapsed, 1.0,
                                  "\(typeName)×\(rangeName) 统计超时（\(elapsed)s）——卡死回归")
                XCTAssertLessThanOrEqual(trend.bars.count, 12,
                                          "\(typeName)×\(rangeName) 周桶超界")
                if comparison.previous != nil {
                    XCTAssertNotNil(comparison.previousLabel)
                    XCTAssertFalse(comparison.previousLabel.isEmpty)
                }
            }
        }
    }

    /// 空记录习惯 × 全范围：不崩、不出负数、不出荒谬完成率
    func test_空记录习惯全范围_空态有界() {
        let emptyId = UUID()
        let data = buildData([])
        for range in [HabitReviewRange.month(oct), .lastDays(30), .lastDays(90), .all,
                      .custom(start: day(2024, 1, 1), end: day(2026, 10, 6))] {
            let snapshot = HabitReviewProjector.rangeSnapshot(
                info: info(emptyId), range: range, data: data)
            let trend = HabitReviewProjector.weeklyTrend(snapshot: snapshot, data: data)
            let comparison = HabitReviewProjector.periodComparison(snapshot: snapshot, data: data)
            XCTAssertFalse(trend.bars.contains { ($0.fraction ?? 0) < 0 || ($0.fraction ?? 0) > 1 },
                           "空记录出现越界完成率")
            if let completion = comparison.current.completion {
                XCTAssertGreaterThanOrEqual(completion, 0)
                XCTAssertLessThanOrEqual(completion, 1)
            }
        }
    }
}
