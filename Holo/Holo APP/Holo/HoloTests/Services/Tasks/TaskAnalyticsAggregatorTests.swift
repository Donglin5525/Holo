//
//  TaskAnalyticsAggregatorTests.swift
//  HoloTests
//
//  固定样例对账（2026-10-06 任务重构方案 §14.1）：统一 asOf = 2026-10-06 15:30
//  Asia/Shanghai，周期 10-05 00:00 至 10-12 00:00（周一为首的自然周）。
//  全部指标逐条断言；输入为纯快照值，不依赖 Core Data。
//

import XCTest
@testable import Holo

final class TaskAnalyticsAggregatorTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private var asOf: Date { makeDate(2026, 10, 6, 15, 30) }

    private let holoListID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let lifeListID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// 固定样例 ID 集合快捷构造
    private func ids(_ strings: String...) -> Set<UUID> {
        Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    /// 构造一条固定样例快照（§14.1 表）
    private func snap(
        id: String,
        created: Date,
        due: Date? = nil,
        isAllDay: Bool = false,
        completedAt: Date? = nil,
        completedMissingTime: Bool = false,
        importance: TaskImportance = .p1,
        urgencyMode: TaskUrgencyMode = .auto,
        listID: UUID? = nil,
        listName: String? = nil,
        archived: Bool = false,
        deleted: Bool = false,
        hasPlannedRange: Bool = false,
        matterLinks: [TaskMatterLinkFact] = []
    ) -> TaskRecordSnapshot {
        TaskRecordSnapshot(
            id: UUID(uuidString: id)!,
            title: "任务\(id)",
            note: nil,
            importance: importance,
            urgencyMode: urgencyMode,
            dueDate: due,
            isAllDay: isAllDay,
            completed: completedAt != nil || completedMissingTime,
            completedAt: completedAt,
            createdAt: created,
            updatedAt: created,
            archived: archived,
            deleted: deleted,
            listID: listID,
            listName: listID == nil ? nil : listName,
            listAvailable: listID != nil,
            listIsArchived: false,
            hasValidPlannedRange: hasPlannedRange,
            priorityRaw: 1,
            checkItems: [],
            matterLinks: matterLinks
        )
    }

    /// 快照换绑事项链接（按事项分组测试用）
    private func withMatter(_ snapshot: TaskRecordSnapshot, _ links: [TaskMatterLinkFact]) -> TaskRecordSnapshot {
        var copy = snapshot
        copy.matterLinks = links
        return copy
    }

    /// §14.1 全表（T12 编号未使用，样例表原样）
    private func fixture() -> [TaskRecordSnapshot] {
        [
            // T01 创建10-05 09:00 截止10-05 18:00 完成10-05 17:00 重要/自动 Holo
            snap(id: "00000000-0000-0000-0000-000000000001",
                 created: makeDate(2026, 10, 5, 9),
                 due: makeDate(2026, 10, 5, 18), completedAt: makeDate(2026, 10, 5, 17),
                 importance: .p1, listID: holoListID, listName: "Holo"),
            // T02 创建09-28 截止10-05 12:00 完成10-05 13:00 不重要/自动 Holo
            snap(id: "00000000-0000-0000-0000-000000000002",
                 created: makeDate(2026, 9, 28, 9),
                 due: makeDate(2026, 10, 5, 12), completedAt: makeDate(2026, 10, 5, 13),
                 importance: .p3, listID: holoListID, listName: "Holo"),
            // T03 创建10-06 09:00 截止10-06 12:00 未完成 重要/自动 生活 无时段
            snap(id: "00000000-0000-0000-0000-000000000003",
                 created: makeDate(2026, 10, 6, 9),
                 due: makeDate(2026, 10, 6, 12),
                 importance: .p1, listID: lifeListID, listName: "生活"),
            // T04 创建10-06 10:00 截止10-06 全天 未完成 不重要/自动 生活
            snap(id: "00000000-0000-0000-0000-000000000004",
                 created: makeDate(2026, 10, 6, 10),
                 due: makeDate(2026, 10, 6), isAllDay: true,
                 importance: .p3, listID: lifeListID, listName: "生活"),
            // T05 创建10-05 11:00 无截止 完成10-06 11:00 重要/自动 收件箱
            snap(id: "00000000-0000-0000-0000-000000000005",
                 created: makeDate(2026, 10, 5, 11),
                 completedAt: makeDate(2026, 10, 6, 11),
                 importance: .p1),
            // T06 创建09-30 截止10-05 全天 完成、完成时间缺失 未判断/自动 Holo
            snap(id: "00000000-0000-0000-0000-000000000006",
                 created: makeDate(2026, 9, 30, 9),
                 due: makeDate(2026, 10, 5), isAllDay: true,
                 completedMissingTime: true,
                 importance: .unknown, listID: holoListID, listName: "Holo"),
            // T07 创建10-05 08:00 截止10-05 10:00 完成10-05 09:00 重要/自动 Holo 已归档
            snap(id: "00000000-0000-0000-0000-000000000007",
                 created: makeDate(2026, 10, 5, 8),
                 due: makeDate(2026, 10, 5, 10), completedAt: makeDate(2026, 10, 5, 9),
                 importance: .p1, listID: holoListID, listName: "Holo", archived: true),
            // T08 创建10-05 14:00 截止10-05 20:00 完成10-05 19:00 重要/自动 Holo 已删除
            snap(id: "00000000-0000-0000-0000-000000000008",
                 created: makeDate(2026, 10, 5, 14),
                 due: makeDate(2026, 10, 5, 20), completedAt: makeDate(2026, 10, 5, 19),
                 importance: .p1, listID: holoListID, listName: "Holo", deleted: true),
            // T09 创建10-06 10:00 无截止 未完成 未判断/自动 收件箱
            snap(id: "00000000-0000-0000-0000-000000000009",
                 created: makeDate(2026, 10, 6, 10),
                 importance: .unknown),
            // T10 创建10-05 12:00 截止10-10 全天 未完成 重要/自动 Holo 时段10-10 10:00–11:00
            snap(id: "00000000-0000-0000-0000-000000000010",
                 created: makeDate(2026, 10, 5, 12),
                 due: makeDate(2026, 10, 10), isAllDay: true,
                 importance: .p1, listID: holoListID, listName: "Holo", hasPlannedRange: true),
            // T11 创建09-29 截止10-05 16:00 完成10-04 18:00 重要/自动 Holo
            snap(id: "00000000-0000-0000-0000-000000000011",
                 created: makeDate(2026, 9, 29, 9),
                 due: makeDate(2026, 10, 5, 16), completedAt: makeDate(2026, 10, 4, 18),
                 importance: .p1, listID: holoListID, listName: "Holo"),
            // T13 创建09-27 截止10-05 全天 未完成 重要/手动不紧急 Holo 无时段
            snap(id: "00000000-0000-0000-0000-000000000013",
                 created: makeDate(2026, 9, 27, 9),
                 due: makeDate(2026, 10, 5), isAllDay: true,
                 importance: .p1, urgencyMode: .p3,
                 listID: holoListID, listName: "Holo")
        ]
    }

    private var period: TaskAnalyticsPeriod { .week(anchorDay: asOf) }

    private func aggregate(_ snapshots: [TaskRecordSnapshot]? = nil) -> TaskAnalyticsSnapshot {
        TaskAnalyticsAggregator.aggregate(snapshots: snapshots ?? fixture(), period: period, asOf: asOf, calendar: calendar)
    }

    // MARK: - 周期边界

    func test_周期边界_周一起始() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.start, makeDate(2026, 10, 5))
        XCTAssertEqual(snapshot.endExclusive, makeDate(2026, 10, 12))
        XCTAssertTrue(snapshot.isOngoing)
    }

    // MARK: - 新增与完成（§14.1 预期：新增7 完成4）

    func test_本期新增7项_集合逐条一致() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.createdCount, 7)
        XCTAssertEqual(Set(snapshot.createdIDs), ids("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004", "00000000-0000-0000-0000-000000000005", "00000000-0000-0000-0000-000000000007", "00000000-0000-0000-0000-000000000009", "00000000-0000-0000-0000-000000000010"))
    }

    func test_本期完成4项_归档T07保留_删除T08排除() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.completedCount, 4)
        XCTAssertEqual(Set(snapshot.completedIDs), ids("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000005", "00000000-0000-0000-0000-000000000007"))
    }

    func test_完成数不是本期新增中完成数_T02跨期计入() {
        // T02 上月创建、本周完成 → 计本周完成不计本周新增（§7.4）
        let snapshot = aggregate()
        XCTAssertTrue(snapshot.completedIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))
        XCTAssertFalse(snapshot.createdIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))
    }

    // MARK: - 按时率（成熟7 缺失1 分母6 按时3 = 50%）

    func test_按时率_成熟7排除1分母6按时3() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.onTime.denominatorCount, 6)
        XCTAssertEqual(snapshot.onTime.onTimeCount, 3)
        XCTAssertEqual(snapshot.onTime.rate, 0.5)
        XCTAssertEqual(Set(snapshot.onTime.onTimeIDs), ids("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000007", "00000000-0000-0000-0000-000000000011"))
        XCTAssertEqual(snapshot.onTime.excludedMissingTimeIDs, [
            UUID(uuidString: "00000000-0000-0000-0000-000000000006")! // T06
        ])
        // T02 延迟、T03/T13 未完成留分母
        XCTAssertEqual(Set(snapshot.onTime.lateIDs), [UUID(uuidString: "00000000-0000-0000-0000-000000000002")!])
        XCTAssertEqual(Set(snapshot.onTime.unfinishedIDs), ids("00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000013"))
    }

    func test_全天今天未成熟_不进分母_T04() {
        // T04 截止 10-06 23:59:59 > asOf 15:30 → 未成熟不进分母（R14）
        let snapshot = aggregate()
        XCTAssertFalse(snapshot.onTime.denominatorIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!))
    }

    func test_未来截止不进分母_T10() {
        let snapshot = aggregate()
        XCTAssertFalse(snapshot.onTime.denominatorIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!))
    }

    func test_零分母无数值() {
        // R43：只留 T09（无截止、未完成）→ 无分母
        let onlyNoDue = fixture().filter { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000009")! }
        let snapshot = TaskAnalyticsAggregator.aggregate(snapshots: onlyNoDue, period: period, asOf: asOf, calendar: calendar)
        XCTAssertEqual(snapshot.onTime.denominatorCount, 0)
        XCTAssertNil(snapshot.onTime.rate)
    }

    func test_缺失完成时间_全局计数1_可点开() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.missingCompletedAtIDs, [UUID(uuidString: "00000000-0000-0000-0000-000000000006")!])
    }

    // MARK: - 趋势桶（10-05 柱 4/3；10-06 截至现在柱 3/1）

    func test_趋势桶_桶合计恒等于指标() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.createdIDs.count }, snapshot.createdCount)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.completedIDs.count }, snapshot.completedCount)
    }

    func test_趋势桶_具体日期断言() {
        let snapshot = aggregate()
        let day5 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 5) }
        let day6 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 6) }
        XCTAssertEqual(day5?.createdIDs.count, 4)
        XCTAssertEqual(day5?.completedIDs.count, 3)
        XCTAssertEqual(day6?.createdIDs.count, 3)
        XCTAssertEqual(day6?.completedIDs.count, 1)
        XCTAssertEqual(day6?.isPartialToday, true)
        XCTAssertEqual(day6?.isFuture, false)
        // 未来桶（10-07 起）标未到来
        let day7 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 7) }
        XCTAssertEqual(day7?.isFuture, true)
        XCTAssertEqual(day7?.createdIDs.count, 0)
    }

    // MARK: - 清单分布（Holo 3 收件箱 1）

    func test_清单完成分布() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.listBreakdown.count, 2)
        let holo = snapshot.listBreakdown.first { $0.listID == holoListID }
        let inbox = snapshot.listBreakdown.first { $0.id == "inbox" }
        XCTAssertEqual(holo?.count, 3)
        XCTAssertEqual(inbox?.count, 1)
        XCTAssertEqual(inbox?.name, "收件箱")
        // 分布合计 == 完成数
        XCTAssertEqual(snapshot.listBreakdown.reduce(0) { $0 + $1.count }, snapshot.completedCount)
    }

    // MARK: - 当前待处理（逾期2 重要未安排2 待整理1，可重叠）

    func test_当前待处理_三组独立可重叠() {
        let snapshot = aggregate()
        XCTAssertEqual(Set(snapshot.attention.overdueIDs), ids("00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000013"))
        XCTAssertEqual(Set(snapshot.attention.importantUnscheduledIDs), ids("00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000013"))
        XCTAssertEqual(snapshot.attention.unclassifiedIDs, [UUID(uuidString: "00000000-0000-0000-0000-000000000009")!])
    }

    func test_切历史周期_当前待处理不随期间过滤() {
        // R49：换成上周，attention 仍读同一 asOf 的活动任务
        let lastWeek = TaskAnalyticsPeriod.week(anchorDay: makeDate(2026, 9, 29))
        let snapshot = TaskAnalyticsAggregator.aggregate(snapshots: fixture(), period: lastWeek, asOf: asOf, calendar: calendar)
        XCTAssertEqual(snapshot.attention.overdueIDs.count, 2)
    }

    // MARK: - 观察

    func test_期间观察_新增比完成多3项() {
        let snapshot = aggregate()
        XCTAssertTrue(snapshot.observation.contains("3"), "观察应含差值 3：\(snapshot.observation)")
    }

    // MARK: - 首页四象限（活动5 象限1/2/1/0 待整理1）

    func test_首页四象限计数与待整理() {
        let members = TaskExperienceScope.allUncompleted.activeMembers(from: fixture(), now: asOf, calendar: calendar)
        XCTAssertEqual(members.count, 5, "当前活动未完成应为 5（T03/T04/T09/T10/T13）")
        let byQuadrant = Dictionary(grouping: members) { $0.quadrant(now: asOf, calendar: calendar) }
        XCTAssertEqual(byQuadrant[.doFirst]?.count, 1)       // T03
        XCTAssertEqual(byQuadrant[.scheduleTime]?.count, 2)  // T10 + T13
        XCTAssertEqual(byQuadrant[.batchHandle]?.count, 1)   // T04
        XCTAssertEqual(byQuadrant[.reviewLater]?.count ?? 0, 0)
        XCTAssertEqual(byQuadrant[.unclassified]?.count, 1)  // T09
        // 四格 + 待整理 = 范围活动总数（计数守恒）
        let total = TaskQuadrant.overviewOrder.reduce(0) { $0 + (byQuadrant[$1]?.count ?? 0) }
            + (byQuadrant[.unclassified]?.count ?? 0)
        XCTAssertEqual(total, members.count)
    }

    func test_手动不紧急逾期任务_行内逾期可见() {
        let t13 = fixture().first { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000013")! }!
        XCTAssertEqual(t13.quadrant(now: asOf, calendar: calendar), .scheduleTime)
        XCTAssertTrue(t13.isOverdue(asOf: asOf, calendar: calendar))
    }

    // MARK: - endExclusive 边界（R42）

    func test_区间终点_exclusive_无跨期重复() {
        var rows = fixture()
        // 边界任务：创建于 10-12 00:00（本周期 endExclusive）→ 不计本周，计下周
        rows.append(snap(id: "00000000-0000-0000-0000-000000000020",
                         created: makeDate(2026, 10, 12)))
        let thisWeek = aggregate(rows)
        XCTAssertFalse(thisWeek.createdIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!))
        let nextWeek = TaskAnalyticsAggregator.aggregate(
            snapshots: rows,
            period: .week(anchorDay: makeDate(2026, 10, 13)),
            asOf: asOf, calendar: calendar
        )
        // 下一周期是未来周期：10-12 的创建晚于 asOf，不计已发生
        XCTAssertFalse(nextWeek.createdIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!))
    }

    // MARK: - 时钟异常

    func test_未来完成时间_不计已发生并留异常数量() {
        var rows = fixture()
        rows.append(snap(id: "00000000-0000-0000-0000-000000000021",
                         created: makeDate(2026, 10, 5, 9),
                         due: makeDate(2026, 10, 5, 18),
                         completedAt: makeDate(2027, 1, 1)))
        let snapshot = aggregate(rows)
        XCTAssertEqual(snapshot.futureCompletedAtIDs, [UUID(uuidString: "00000000-0000-0000-0000-000000000021")!])
        XCTAssertFalse(snapshot.completedIDs.contains(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!))
    }

    // MARK: - 对比窗口（R47：周二 15:30 只比同等已过窗口）

    func test_对比窗口_本周二与上周二同等已过窗口() {
        let snapshot = aggregate()
        // 上期窗口应为 09-28 00:00 至 09-29 15:30（同等已过窗口）
        let prevWindow = TaskAnalyticsPeriodResolver.compareWindow(
            current: TaskAnalyticsPeriodResolver.bounds(of: period, asOf: asOf, calendar: calendar),
            asOf: asOf, calendar: calendar
        )
        XCTAssertEqual(prevWindow.previousStart, makeDate(2026, 9, 28))
        XCTAssertEqual(prevWindow.previousEnd, makeDate(2026, 9, 29, 15, 30))
        // 上期窗口内创建：T02（09-28 09:00）与 T11（09-29 09:00，早于 15:30）=2 → 新增差 7-2=5
        XCTAssertEqual(snapshot.comparison.createdDelta, 5)
        XCTAssertEqual(snapshot.comparison.completedDelta, 4)
    }

    // MARK: - 到期完成率（期间 + 逐桶 + 上期环比）

    func test_到期完成率_期间_按时3迟到1分母6() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.onTime.lateCount, 1)
        XCTAssertEqual(snapshot.onTime.unfinishedCount, 2)
        XCTAssertEqual(snapshot.onTime.completionRate ?? -1, 4.0 / 6.0, accuracy: 0.0001)
    }

    func test_到期完成率_逐桶_10月5日4除5_10月6日0除1_未来桶无数值() {
        let snapshot = aggregate()
        let day5 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 5) }!
        let day6 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 6) }!
        let day7 = snapshot.buckets.first { $0.start == makeDate(2026, 10, 7) }!
        // 10-05：成熟6（T01/T02/T06/T07/T11/T13）排除T06缺时间 → 分母5，按时3迟到1未完成1
        XCTAssertEqual(day5.maturedDueCount, 6)
        XCTAssertEqual(day5.excludedDueMissingTimeCount, 1)
        XCTAssertEqual(day5.onTimeDueCount, 3)
        XCTAssertEqual(day5.lateDueCount, 1)
        XCTAssertEqual(day5.dueCompletionRate ?? -1, 4.0 / 5.0, accuracy: 0.0001)
        // 10-06：仅 T03（12:00 已成熟）进分母且未完成；T04 全天未成熟不进
        XCTAssertEqual(day6.maturedDueCount, 1)
        XCTAssertEqual(day6.onTimeDueCount, 0)
        XCTAssertEqual(day6.dueCompletionRate ?? -1, 0.0, accuracy: 0.0001)
        // 未来桶无成熟到期 → 无数值
        XCTAssertNil(day7.dueCompletionRate)
    }

    func test_到期完成率_逐桶合计等于期间口径() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.onTimeDueCount }, snapshot.onTime.onTimeCount)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.lateDueCount }, snapshot.onTime.lateCount)
        XCTAssertEqual(
            snapshot.buckets.reduce(0) { $0 + $1.maturedDueCount - $1.excludedDueMissingTimeCount },
            snapshot.onTime.denominatorCount
        )
    }

    func test_上期环比率_同等已过窗口内到期() {
        // fixture 上期窗口（09-28 00:00–09-29 15:30）内无到期 → 两率 nil
        let base = aggregate()
        XCTAssertNil(base.comparison.previousDueCompletionRate)
        XCTAssertNil(base.comparison.previousOnTimeRate)

        // 加一条上期到期且按时完成的任务 → 上期到期完成率/按时率均 100%
        var rows = fixture()
        rows.append(snap(id: "00000000-0000-0000-0000-000000000030",
                         created: makeDate(2026, 9, 27, 9),
                         due: makeDate(2026, 9, 28, 10),
                         completedAt: makeDate(2026, 9, 28, 9)))
        let withPrev = aggregate(rows)
        XCTAssertEqual(withPrev.comparison.previousDueCompletionRate ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(withPrev.comparison.previousOnTimeRate ?? -1, 1.0, accuracy: 0.0001)
    }

    // MARK: - 完成节奏（P2：热力网格 + 小时分布 + 按事项分组）

    func test_热力网格_近12周84天_含零完成日_固定窗口跨期取数() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.heatDays.count, 84)
        // 本周一（10-05）前推 11 周 = 07-20（周一）起，至 10-11（本周日）
        XCTAssertEqual(snapshot.heatDays.first?.start, makeDate(2026, 7, 20))
        XCTAssertEqual(snapshot.heatDays.last?.start, makeDate(2026, 10, 11))
        // 本周完成：10-05 三件（T01/T02/T07 归档保留）、10-06 一件（T05）
        XCTAssertEqual(snapshot.heatDays.first { $0.start == makeDate(2026, 10, 5) }?.completedCount, 3)
        XCTAssertEqual(snapshot.heatDays.first { $0.start == makeDate(2026, 10, 6) }?.completedCount, 1)
        // 窗口含上周日：T11 的 10-04 18:00 完成也计入（节奏网格固定窗口、不随档期过滤）
        XCTAssertEqual(snapshot.heatDays.first { $0.start == makeDate(2026, 10, 4) }?.completedCount, 1)
        XCTAssertEqual(snapshot.heatDays.first { $0.start == makeDate(2026, 10, 7) }?.completedCount, 0)
        // 合计 = 窗口内全部完成（本期 4 + 跨期 T11 = 5），≠ 期间完成数
        XCTAssertEqual(snapshot.heatDays.reduce(0) { $0 + $1.completedCount }, 5)
    }

    func test_小时分布_按完成时刻落24桶() {
        let snapshot = aggregate()
        XCTAssertEqual(snapshot.hourlyCompletedCounts.count, 24)
        XCTAssertEqual(snapshot.hourlyCompletedCounts.reduce(0, +), 4)
        XCTAssertEqual(snapshot.hourlyCompletedCounts[9], 1)   // T07 09:00
        XCTAssertEqual(snapshot.hourlyCompletedCounts[11], 1)  // T05 11:00
        XCTAssertEqual(snapshot.hourlyCompletedCounts[13], 1)  // T02 13:00
        XCTAssertEqual(snapshot.hourlyCompletedCounts[17], 1)  // T01 17:00
        XCTAssertEqual(snapshot.hourlyCompletedCounts[0], 0)
    }

    func test_按事项分组_多链接重复计入_未链接不出现_数量降序() {
        let matterA = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        let matterC = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000003")!
        let rows = fixture().map { snapshot -> TaskRecordSnapshot in
            switch snapshot.id.uuidString {
            case "00000000-0000-0000-0000-000000000001":  // T01 → A + C
                return withMatter(snapshot, [
                    TaskMatterLinkFact(matterID: matterA, title: "装修新家"),
                    TaskMatterLinkFact(matterID: matterC, title: "健康体检")
                ])
            case "00000000-0000-0000-0000-000000000002":  // T02 → A
                return withMatter(snapshot, [TaskMatterLinkFact(matterID: matterA, title: "装修新家")])
            default:
                return snapshot
            }
        }
        let snapshot = aggregate(rows)
        XCTAssertEqual(snapshot.matterBreakdown.count, 2)
        let a = snapshot.matterBreakdown.first { $0.id == matterA }
        XCTAssertEqual(a?.title, "装修新家")
        XCTAssertEqual(a?.count, 2)
        XCTAssertEqual(Set(a?.completedIDs ?? []), ids("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"))
        // T01 多链接 → 同时计入事项 C（重复计入，视图需注明）
        XCTAssertEqual(snapshot.matterBreakdown.first { $0.id == matterC }?.count, 1)
        // 数量降序：A（2）在前
        XCTAssertEqual(snapshot.matterBreakdown.first?.id, matterA)
        // 基线 fixture 无任何链接 → 空分布
        XCTAssertTrue(aggregate().matterBreakdown.isEmpty)
    }
}
