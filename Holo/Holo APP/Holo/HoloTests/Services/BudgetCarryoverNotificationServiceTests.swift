//
//  BudgetCarryoverNotificationServiceTests.swift
//  HoloTests
//
//  严格预算模式 · 结转回执一期纯函数单测（2026-09-27 方案）
//  覆盖：回执触发时刻推算 / 排期周期戳 / 结转指纹稳定性 / 已读标记读写
//

import XCTest
@testable import Holo

final class BudgetCarryoverNotificationServiceTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 下一个 1 号 09:00

    func testNextFireDate_FromMidMonth_SchedulesNextFirst() {
        let fire = BudgetCarryoverNotificationService.nextCarryoverFireDate(
            after: date(2026, 9, 27), calendar: calendar
        )
        XCTAssertEqual(fire, date(2026, 10, 1, 9))
    }

    func testNextFireDate_MonthEndLateNight_SchedulesNextMorningFirst() {
        let fire = BudgetCarryoverNotificationService.nextCarryoverFireDate(
            after: date(2026, 9, 30, 23, 30), calendar: calendar
        )
        XCTAssertEqual(fire, date(2026, 10, 1, 9))
    }

    func testNextFireDate_OnFirstBeforeNine_SchedulesSameDay() {
        let fire = BudgetCarryoverNotificationService.nextCarryoverFireDate(
            after: date(2026, 10, 1, 8), calendar: calendar
        )
        XCTAssertEqual(fire, date(2026, 10, 1, 9))
    }

    func testNextFireDate_OnFirstAfterNine_SchedulesNextMonth() {
        let fire = BudgetCarryoverNotificationService.nextCarryoverFireDate(
            after: date(2026, 10, 1, 10), calendar: calendar
        )
        XCTAssertEqual(fire, date(2026, 11, 1, 9))
    }

    // MARK: - 排期周期戳

    func testMonthStamp_FormatIsYearMonth() {
        XCTAssertEqual(
            BudgetCarryoverNotificationService.monthStamp(for: date(2026, 10, 1), calendar: calendar),
            "2026-10"
        )
        XCTAssertEqual(
            BudgetCarryoverNotificationService.monthStamp(for: date(2027, 1, 1), calendar: calendar),
            "2027-01"
        )
    }

    // MARK: - 结转指纹

    func testFingerprint_NoCarryoverEntries_ReturnsNil() {
        let id = UUID()
        XCTAssertNil(BudgetCarryoverNotificationService.carryoverFingerprint([]))
        XCTAssertNil(BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: id, periodStart: date(2026, 10, 1), deduction: Decimal(0))
        ]))
    }

    func testFingerprint_EntryOrderIrrelevant() {
        let a = UUID(), b = UUID()
        let first = BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: a, periodStart: date(2026, 10, 1), deduction: Decimal(326)),
            (id: b, periodStart: date(2026, 10, 1), deduction: Decimal(120))
        ])
        let second = BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: b, periodStart: date(2026, 10, 1), deduction: Decimal(120)),
            (id: a, periodStart: date(2026, 10, 1), deduction: Decimal(326))
        ])
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    func testFingerprint_NewPeriodOrAmount_Changes() {
        let id = UUID()
        let original = BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: id, periodStart: date(2026, 10, 1), deduction: Decimal(326))
        ])
        // 新周期（结转重新生效）→ 指纹变化，横幅重新展示
        let newPeriod = BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: id, periodStart: date(2026, 11, 1), deduction: Decimal(326))
        ])
        // 同周期结转额变化 → 指纹变化
        let newAmount = BudgetCarryoverNotificationService.carryoverFingerprint([
            (id: id, periodStart: date(2026, 10, 1), deduction: Decimal(500))
        ])
        XCTAssertNotEqual(original, newPeriod)
        XCTAssertNotEqual(original, newAmount)
    }

    // MARK: - 已读标记

    func testReceiptRead_MarkThenRead_MatchesSameFingerprintOnly() throws {
        let suiteName = "BudgetCarryoverReadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fingerprint = "fp-1"
        XCTAssertFalse(BudgetCarryoverNotificationService.isReceiptRead(fingerprint, defaults: defaults))
        BudgetCarryoverNotificationService.setReceiptRead(fingerprint, defaults: defaults, cloudSync: false)
        XCTAssertTrue(BudgetCarryoverNotificationService.isReceiptRead(fingerprint, defaults: defaults))
        // 新周期指纹 ≠ 已读指纹：横幅重新出现
        XCTAssertFalse(BudgetCarryoverNotificationService.isReceiptRead("fp-2", defaults: defaults))
    }
}
