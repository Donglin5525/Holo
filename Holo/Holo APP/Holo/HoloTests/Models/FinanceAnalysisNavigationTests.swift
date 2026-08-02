import Foundation

#if FINANCE_NAVIGATION_STANDALONE
enum TimeRange {
    case day, week, month, quarter, year, custom
}
#endif

@main
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
        guard condition() else { fatalError(message) }
    }
}
