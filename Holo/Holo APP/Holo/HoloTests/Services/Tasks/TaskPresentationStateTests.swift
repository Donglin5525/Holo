//
//  TaskPresentationStateTests.swift
//  HoloTests
//
//  多视图会话状态纯规则（多视图方案 §3.2/§5.1-4 / 验收 V01/C09）：
//  默认日历、冷启动今天、月份导航夹末日、周导航、异常值回日历、独立偏好键。
//

import XCTest
@testable import Holo

@MainActor
final class TaskPresentationStateTests: XCTestCase {

    /// MainActor 会话对象在测试进程 teardown 阶段析构会踩已释放内存
    ///（踩坑录 retain 解）：静态强引用把实例生命周期拉过进程清理阶段
    private static var retainedSessions: [TaskPresentationSession] = []

    private func makeSession(_ y: Int, _ m: Int, _ d: Int) -> TaskPresentationSession {
        let session = TaskPresentationSession(now: date(y, m, d))
        Self.retainedSessions.append(session)
        return session
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TaskCalendarMode.preferenceKey)
        UserDefaults.standard.removeObject(forKey: "taskPresentation.v1.calendarShowsCompleted")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TaskCalendarMode.preferenceKey)
        UserDefaults.standard.removeObject(forKey: "taskPresentation.v1.calendarShowsCompleted")
        super.tearDown()
    }

    // MARK: - V01：新会话默认日历 + 今天

    func testNewSessionDefaultsToCalendarAndToday() {
        let session = makeSession(2026, 10, 16)
        XCTAssertEqual(session.viewMode, .calendar)
        XCTAssertTrue(session.isTodaySelected)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 16)
    }

    // MARK: - C09：月份导航保持日号夹到月末（1/31 → 2/28；闰年 2/29）

    func testMonthShiftClampsDayToEndOfMonth() {
        let session = makeSession(2026, 1, 31)
        session.shiftMonth(direction: 1)
        XCTAssertEqual(calendar.component(.month, from: session.selectedDay), 2)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 28) // 2026 平年
        session.shiftMonth(direction: -1)
        XCTAssertEqual(calendar.component(.month, from: session.selectedDay), 1)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 28) // 保留 28 日而非回到 31
    }

    func testMonthShiftClampsLeapYearFebruary() {
        let session = makeSession(2028, 1, 31)
        session.shiftMonth(direction: 1)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 29) // 2028 闰年
    }

    func testMonthShiftCrossesYearBoundary() {
        let session = makeSession(2026, 12, 15)
        session.shiftMonth(direction: 1)
        XCTAssertEqual(calendar.component(.year, from: session.selectedDay), 2027)
        XCTAssertEqual(calendar.component(.month, from: session.selectedDay), 1)
    }

    // MARK: - 周导航（§5.2-2）

    func testWeekShiftAddsSevenDaysAndSyncsMonth() {
        let session = makeSession(2026, 10, 28) // 周三
        session.shiftWeek(direction: 1)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 4) // 11-04
        XCTAssertEqual(calendar.component(.month, from: session.selectedDay), 11)
        session.shiftWeek(direction: -1)
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 28)
    }

    // MARK: - 今天

    func testGoTodayReturnsToRealToday() {
        let session = makeSession(2026, 10, 16)
        session.selectDay(date(2026, 9, 1))
        session.goToday()
        XCTAssertEqual(calendar.component(.day, from: session.selectedDay), 16)
    }

    // MARK: - 异常值与偏好隔离

    func testInvalidRawViewModeFallsBackToCalendar() {
        XCTAssertEqual(TaskViewMode.safe("gantt"), .calendar)
        XCTAssertEqual(TaskViewMode.safe(nil), .calendar)
        XCTAssertEqual(TaskViewMode.safe("list"), .list)
    }

    func testCalendarModePreferenceRoundTrip() {
        UserDefaults.standard.set("day", forKey: TaskCalendarMode.preferenceKey)
        XCTAssertEqual(TaskCalendarMode.loadPreferred(), .day)
        UserDefaults.standard.set("month", forKey: TaskCalendarMode.preferenceKey)
        XCTAssertEqual(TaskCalendarMode.loadPreferred(), .month)
        UserDefaults.standard.removeObject(forKey: TaskCalendarMode.preferenceKey)
        XCTAssertEqual(TaskCalendarMode.loadPreferred(), .month) // 首次默认月览
    }

    func testShowsCompletedDefaultsOff() {
        let session = makeSession(2026, 10, 16)
        XCTAssertFalse(session.calendarShowsCompleted)
        session.calendarShowsCompleted = true
        // 偏好持久化到独立键
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "taskPresentation.v1.calendarShowsCompleted"), true)
    }

    // MARK: - 选择日期同步月份

    func testSelectDaySyncsDisplayedMonth() {
        let session = makeSession(2026, 10, 16)
        session.selectDay(date(2026, 11, 20))
        XCTAssertEqual(calendar.component(.month, from: session.displayedMonth), 11)
        XCTAssertFalse(session.isTodaySelected)
    }
}
