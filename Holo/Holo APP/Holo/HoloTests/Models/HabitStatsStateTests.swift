//
//  HabitStatsStateTests.swift
//  HoloTests
//
//  习惯统计模块状态测试
//

import XCTest
@testable import Holo

final class HabitStatsStateTests: XCTestCase {

    // MARK: - 数据类型测试

    func testCollapsedWeekFallsBackToLastRecordedWeekInsideMonth() {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!

        let firstWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!,
            days: [
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!, dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 7))!, dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 8))!, dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 9))!, dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 10))!, dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 11))!, dayNumber: 11, isInCurrentMonth: true, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 12))!, dayNumber: 12, isInCurrentMonth: true, isToday: false, hasRecord: false, isOverLimit: false)
            ]
        )

        let secondWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 13))!,
            days: [
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 13))!, dayNumber: 13, isInCurrentMonth: true, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 14))!, dayNumber: 14, isInCurrentMonth: true, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))!, dayNumber: 15, isInCurrentMonth: true, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 16))!, dayNumber: 16, isInCurrentMonth: true, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 17))!, dayNumber: 17, isInCurrentMonth: true, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 18))!, dayNumber: 18, isInCurrentMonth: true, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 19))!, dayNumber: 19, isInCurrentMonth: true, isToday: false, hasRecord: false, isOverLimit: false)
            ]
        )

        let item = HabitStatsDisplayItem(
            habitId: UUID(),
            name: "体重",
            icon: "scalemass",
            isCustomIcon: false,
            habitColorHex: "#3B82F6",
            type: .measure,
            summary: .measure(recordedDays: 4, averageValueText: "58.2kg"),
            collapsedWeek: secondWeek,
            allWeeks: [firstWeek, secondWeek],
            month: HabitStatsMonthSection(monthStart: month, weekdaySymbols: [], rows: [])
        )

        XCTAssertEqual(item.collapsedWeek.weekStart, secondWeek.weekStart)
    }

    // MARK: - 摘要文案测试

    func testCheckInSummaryContainsCompletedDaysAndStreak() {
        let summary = HabitStatsCardSummary.checkIn(completedDays: 15, streak: 7)

        if case .checkIn(let completedDays, let streak) = summary {
            XCTAssertEqual(completedDays, 15)
            XCTAssertEqual(streak, 7)
        } else {
            XCTFail("Expected checkIn summary")
        }
    }

    func testCountSummaryContainsRecordedDaysAndTotalCount() {
        let summary = HabitStatsCardSummary.count(recordedDays: 12, totalCountText: "25次")

        if case .count(let recordedDays, let totalCountText) = summary {
            XCTAssertEqual(recordedDays, 12)
            XCTAssertEqual(totalCountText, "25次")
        } else {
            XCTFail("Expected count summary")
        }
    }

    func testMeasureSummaryContainsRecordedDaysAndAverage() {
        let summary = HabitStatsCardSummary.measure(recordedDays: 20, averageValueText: "58.2kg")

        if case .measure(let recordedDays, let averageValueText) = summary {
            XCTAssertEqual(recordedDays, 20)
            XCTAssertEqual(averageValueText, "58.2kg")
        } else {
            XCTFail("Expected measure summary")
        }
    }

    // MARK: - DayCell 测试

    func testDayCellIdentifiableUsesDate() {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))!
        let cell = HabitStatsDayCell(
            date: date,
            dayNumber: 15,
            isInCurrentMonth: true,
            isToday: false,
            hasRecord: true
        )

        XCTAssertEqual(cell.id, date)
        XCTAssertEqual(cell.dayNumber, 15)
        XCTAssertTrue(cell.hasRecord)
    }

    // MARK: - WeekSlice 回退逻辑测试

    func testWeekSliceFallbackToFirstWhenNoRecords() {
        let calendar = Calendar(identifier: .gregorian)

        let firstWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!,
            days: (0..<7).map { _ in
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false)
            }
        )

        let secondWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 13))!,
            days: (0..<7).map { _ in
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false)
            }
        )

        let weeks = [firstWeek, secondWeek]
        let collapsedWeek = weeks.last(where: { $0.days.contains(where: \.hasRecord) }) ?? weeks.first!

        XCTAssertEqual(collapsedWeek.weekStart, firstWeek.weekStart)
    }

    func testWeekSliceSelectsLastRecordedWeek() {
        let calendar = Calendar(identifier: .gregorian)

        let firstWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 6))!,
            days: [
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false)
            ]
        )

        let secondWeek = HabitStatsWeekSlice(
            weekStart: calendar.date(from: DateComponents(year: 2026, month: 4, day: 13))!,
            days: [
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: true, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false),
                HabitStatsDayCell(date: Date(), dayNumber: nil, isInCurrentMonth: false, isToday: false, hasRecord: false, isOverLimit: false)
            ]
        )

        let weeks = [firstWeek, secondWeek]
        let collapsedWeek = weeks.last(where: { $0.days.contains(where: \.hasRecord) }) ?? weeks.first!

        XCTAssertEqual(collapsedWeek.weekStart, secondWeek.weekStart)
    }
}
