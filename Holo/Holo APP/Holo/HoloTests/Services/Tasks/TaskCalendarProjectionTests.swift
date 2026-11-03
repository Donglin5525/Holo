//
//  TaskCalendarProjectionTests.swift
//  HoloTests
//
//  日历投影纯规则（多视图方案 §4.2/§4.4/§11 固定样例）：演示时钟
//  2026-10-16 11:00 Asia/Shanghai；P/C/U 去重计数、占用并集、待安排、逾期、
//  半缺计划、显示已完成、计划与截止不同日两个事实。
//

import XCTest
@testable import Holo

final class TaskCalendarProjectionTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private var asOf: Date { makeDate(2026, 10, 16, 11) }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    private var day16: Date { makeDate(2026, 10, 16) }

    // MARK: - §11 固定样例

    private func snap(
        _ id: String,
        importance: TaskImportance,
        due: Date?,
        isAllDay: Bool = false,
        plannedStart: Date? = nil,
        plannedEnd: Date? = nil,
        completed: Bool = false
    ) -> TaskRecordSnapshot {
        TaskRecordSnapshot(
            id: UUID(uuidString: id)!,
            title: "任务\(id)",
            note: nil,
            importance: importance,
            urgencyMode: .auto,
            dueDate: due,
            isAllDay: isAllDay,
            completed: completed,
            completedAt: completed ? asOf : nil,
            createdAt: makeDate(2026, 10, 10),
            updatedAt: makeDate(2026, 10, 10),
            archived: false,
            deleted: false,
            listID: nil,
            listName: nil,
            listAvailable: false,
            listIsArchived: false,
            hasValidPlannedRange: {
                guard let plannedStart, let plannedEnd else { return false }
                return TodoTask.isValidPlannedRange(plannedStart, plannedEnd, calendar: calendar)
            }(),
            plannedStart: plannedStart,
            plannedEnd: plannedEnd,
            priorityRaw: 1,
            checkItems: [],
            matterLinks: []
        )
    }

    /// §11 活动任务 11 条（L 已完成不计活动）
    private func activeFixtures() -> [TaskRecordSnapshot] {
        [
            snap("00000000-0000-0000-0000-000000000001", importance: .p1,                      // A
                 due: makeDate(2026, 10, 16, 18), plannedStart: makeDate(2026, 10, 16, 9), plannedEnd: makeDate(2026, 10, 16, 10)),
            snap("00000000-0000-0000-0000-000000000002", importance: .p1,                      // B
                 due: makeDate(2026, 10, 20), isAllDay: true, plannedStart: makeDate(2026, 10, 16, 10, 30), plannedEnd: makeDate(2026, 10, 16, 12)),
            snap("00000000-0000-0000-0000-000000000003", importance: .p2,                      // C
                 due: makeDate(2026, 10, 16), isAllDay: true),
            snap("00000000-0000-0000-0000-000000000004", importance: .p3,                      // D
                 due: makeDate(2026, 10, 31), isAllDay: true),
            snap("00000000-0000-0000-0000-000000000005", importance: .p1,                      // E
                 due: nil, plannedStart: makeDate(2026, 10, 17, 14), plannedEnd: makeDate(2026, 10, 17, 15)),
            snap("00000000-0000-0000-0000-000000000006", importance: .unknown,                 // F
                 due: nil),
            snap("00000000-0000-0000-0000-000000000007", importance: .p1,                      // G
                 due: makeDate(2026, 10, 15, 17)),
            snap("00000000-0000-0000-0000-000000000008", importance: .p1,                      // H
                 due: makeDate(2026, 10, 18, 18), plannedStart: makeDate(2026, 10, 16, 10, 45), plannedEnd: makeDate(2026, 10, 16, 11, 30)),
            snap("00000000-0000-0000-0000-000000000009", importance: .unknown,                 // I
                 due: makeDate(2026, 10, 16, 17)),
            snap("00000000-0000-0000-0000-000000000010", importance: .p2,                      // J
                 due: makeDate(2026, 10, 18), isAllDay: true, plannedStart: makeDate(2026, 10, 18, 9), plannedEnd: makeDate(2026, 10, 18, 10)),
            snap("00000000-0000-0000-0000-000000000011", importance: .p1,                      // K
                 due: makeDate(2026, 10, 25), isAllDay: true)
        ]
    }

    private func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-00000000\(suffix)")!
    }

    // MARK: - C01：16 日数字与明细（不把计划+截止重复计数）

    func testDay16CountIsFiveWithDedup() {
        let count = TaskCalendarProjection.dayCount(day: day16, members: activeFixtures(), calendar: calendar)
        XCTAssertEqual(count, 5) // A/B/H 计划 + C/I 截止
    }

    func testDay16DetailOrderPlansFirstThenDueOnly() {
        let projection = TaskCalendarProjection.dayProjection(day: day16, members: activeFixtures(), now: asOf, calendar: calendar)
        XCTAssertEqual(projection.members.map(\.id), [id("0001"), id("0002"), id("0008"), id("0009"), id("0003")])
        XCTAssertEqual(projection.plannedMembers.map(\.id), [id("0001"), id("0002"), id("0008")])
        XCTAssertEqual(projection.dueOnlyMembers.map(\.id), [id("0009"), id("0003")]) // 按有效截止升序 I 17:00 < C 全天
    }

    // MARK: - C03：占用并集 150 分钟（非 195）

    func testDay16OccupiedMinutesIsUnionNotSum() {
        let projection = TaskCalendarProjection.dayProjection(day: day16, members: activeFixtures(), now: asOf, calendar: calendar)
        XCTAssertEqual(projection.occupiedMinutes, 150) // A 60 + B∪H 90
    }

    // MARK: - C04：有计划无截止 / 有截止无计划

    func testEOn17AndCInDay16AndUnplanned() {
        // E 在 17 日（计划日）
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: makeDate(2026, 10, 17), members: activeFixtures(), calendar: calendar), 1)
        // 18 日：H 截止 + J 计划与截止（同任务去重）
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: makeDate(2026, 10, 18), members: activeFixtures(), calendar: calendar), 2)
        // 20 日 B 截止
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: makeDate(2026, 10, 20), members: activeFixtures(), calendar: calendar), 1)
    }

    func testUnplannedSixMembersRegardlessOfDue() {
        let unplanned = TaskCalendarProjection.unplannedMembers(from: activeFixtures(), now: asOf, calendar: calendar)
        XCTAssertEqual(Set(unplanned.map(\.id)), [id("0003"), id("0004"), id("0006"), id("0007"), id("0009"), id("0011")])
    }

    func testOverdueContainsPlannedAndUnplanned() {
        let overdue = TaskCalendarProjection.overdueMembers(from: activeFixtures(), asOf: asOf, calendar: calendar)
        XCTAssertEqual(overdue.map(\.id), [id("0007")])
    }

    // MARK: - C05：A 改计划到 17 日 → 16 日仍 5、17 日 2

    func testMovingPlanKeepsDueFactOnOriginalDay() {
        var fixtures = activeFixtures()
        let aIndex = fixtures.firstIndex { $0.id == id("0001") }!
        fixtures[aIndex].plannedStart = makeDate(2026, 10, 17, 9)
        fixtures[aIndex].plannedEnd = makeDate(2026, 10, 17, 10)
        // A 的截止仍在 16 日：16 日 5（A 以截止事实存在 + B/H/C/I），17 日 2（E + A 计划）
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: day16, members: fixtures, calendar: calendar), 5)
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: makeDate(2026, 10, 17), members: fixtures, calendar: calendar), 2)
        // 16 日明细：A 落到截止独立项（无当日计划；按有效截止升序 I17:00 < A18:00 < C全天）
        let projection = TaskCalendarProjection.dayProjection(day: day16, members: fixtures, now: asOf, calendar: calendar)
        XCTAssertEqual(projection.dueOnlyMembers.map(\.id), [id("0009"), id("0001"), id("0003")])
    }

    // MARK: - C11：显示已完成（同范围完成任务并入同一 P/C 口径）

    func testShowsCompletedAddsSixthOn16AndOccupied180() {
        let l = snap("00000000-0000-0000-0000-000000000012", importance: .p2,
                     due: makeDate(2026, 10, 16), isAllDay: true,
                     plannedStart: makeDate(2026, 10, 16, 8), plannedEnd: makeDate(2026, 10, 16, 8, 30),
                     completed: true)
        let members = activeFixtures() + [l]
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: day16, members: members, calendar: calendar), 6)
        let projection = TaskCalendarProjection.dayProjection(day: day16, members: members, now: asOf, calendar: calendar)
        XCTAssertEqual(projection.occupiedMinutes, 180) // 150 + L 30
    }

    // MARK: - 半缺/非法计划（§4.2 末段）

    func testHalfPlannedRangeTreatedAsUnplannedButDueStillVisible() {
        // 只有开始没有结束：snap 内 hasValidPlannedRange 按 isValidPlannedRange 计算为 false
        let half = snap("00000000-0000-0000-0000-000000000013", importance: .p2,
                        due: makeDate(2026, 10, 16, 15),
                        plannedStart: makeDate(2026, 10, 16, 9))

        // 待安排包含它
        let unplanned = TaskCalendarProjection.unplannedMembers(from: [half], now: asOf, calendar: calendar)
        XCTAssertEqual(unplanned.map(\.id), [half.id])
        // 截止日仍可见（进入当日明细的截止独立项）
        XCTAssertEqual(TaskCalendarProjection.dayCount(day: day16, members: [half], calendar: calendar), 1)
    }

    // MARK: - 月计数索引（P01：一次索引不逐格全量）

    func testMonthCountsAcrossGridDays() {
        let days = (1...31).map { makeDate(2026, 10, $0) }
        let counts = TaskCalendarProjection.dayCounts(days: days, members: activeFixtures(), calendar: calendar)
        XCTAssertEqual(counts[makeDate(2026, 10, 16)], 5)
        XCTAssertEqual(counts[makeDate(2026, 10, 15)], 1) // G 截止 15 日
        XCTAssertEqual(counts[makeDate(2026, 10, 18)], 2)
        XCTAssertEqual(counts.values.reduce(0, +), 12) // 15日1 + 16日5 + 17日1 + 18日2 + 20日1 + 25日1 + 31日1
    }
}
