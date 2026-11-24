import Foundation

#if FINANCE_NAVIGATION_STANDALONE
enum TimeRange {
    case day, week, month, quarter, year, custom
}
#endif

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        FinanceAnalysisNavigationTests.main()
    }
}
#endif
struct FinanceAnalysisNavigationTests {
    static func main() {
        testNaturalMonthNavigation()
        testCustomMonthNavigation()
        testCustomWindowNavigation()
        testLatestLoadWins()
        print("FinanceAnalysisNavigationTests passed")
    }

    private static func testNaturalMonthNavigation() {
        let calendar = fixedCalendar()
        let start = date(2026, 8, 1, calendar: calendar)
        let end = date(2026, 9, 1, calendar: calendar)

        let previous = FinanceDateRangeNavigator.shiftedRange(
            start: start,
            end: end,
            timeRange: .month,
            direction: .previous,
            calendar: calendar
        )

        expect(previous?.start == date(2026, 7, 1, calendar: calendar), "自然月向左应进入 7 月")
        expect(previous?.end == date(2026, 8, 1, calendar: calendar), "自然月向左应保持完整月窗口")
    }

    private static func testCustomMonthNavigation() {
        let calendar = fixedCalendar()
        let start = date(2026, 8, 1, calendar: calendar)
        let end = date(2026, 9, 1, calendar: calendar)

        let next = FinanceDateRangeNavigator.shiftedRange(
            start: start,
            end: end,
            timeRange: .custom,
            direction: .next,
            calendar: calendar
        )

        expect(next?.start == date(2026, 9, 1, calendar: calendar), "自定义自然月向右应进入 9 月")
        expect(next?.end == date(2026, 10, 1, calendar: calendar), "自定义自然月应按自然月切换")
    }

    private static func testCustomWindowNavigation() {
        let calendar = fixedCalendar()
        let start = date(2026, 8, 3, calendar: calendar)
        let end = date(2026, 8, 13, calendar: calendar)

        let previous = FinanceDateRangeNavigator.shiftedRange(
            start: start,
            end: end,
            timeRange: .custom,
            direction: .previous,
            calendar: calendar
        )

        expect(previous?.start == date(2026, 7, 24, calendar: calendar), "自定义窗口应按原天数平移")
        expect(previous?.end == date(2026, 8, 3, calendar: calendar), "自定义窗口结束日期应同步平移")
    }

    private static func testLatestLoadWins() {
        var gate = FinanceAnalysisLoadGate()
        let first = gate.begin()
        let second = gate.begin()

        expect(!gate.accepts(first), "旧请求完成后不能覆盖最后一次月份选择")
        expect(gate.accepts(second), "最后一次请求应被接纳")
    }

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
    }
}
