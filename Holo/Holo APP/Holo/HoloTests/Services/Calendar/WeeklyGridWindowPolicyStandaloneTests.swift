import Foundation

private func expectWeeklyWindow(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
private struct WeeklyGridWindowPolicyStandaloneTests {
    static func main() {
        testHistoricalWeekCanReachBothEdges()
        testCurrentWeekStopsWithTodayCentered()
        testEarlyWeekStillShowsThreeColumns()
        testSundayFinalWindowFocusesToday()
        testFutureStepDoesNotMoveLogicalWindow()
        testFocusedDayDerivesStableWindow()
        print("WeeklyGridWindowPolicyStandaloneTests passed (6 cases)")
    }

    private static func testHistoricalWeekCanReachBothEdges() {
        let policy = WeeklyGridWindowPolicy(totalDayCount: 7)
        expectWeeklyWindow(policy.maximumStartIndex == 4, "历史周应能浏览到周五至周日")
        expectWeeklyWindow(policy.steppedStartIndex(from: 3, by: 1) == 4, "历史周应能前进到末屏")
        expectWeeklyWindow(policy.focusIndex(forWindowStart: 4) == 5, "末屏应以周六作为逻辑焦点")
    }

    private static func testCurrentWeekStopsWithTodayCentered() {
        let policy = WeeklyGridWindowPolicy(totalDayCount: 7, latestAllowedDayIndex: 3)
        expectWeeklyWindow(policy.maximumStartIndex == 2, "周四为今天时末屏应为周三至周五")
        expectWeeklyWindow(policy.focusIndex(forWindowStart: 2) == 3, "末屏逻辑焦点必须仍是今天")
    }

    private static func testEarlyWeekStillShowsThreeColumns() {
        let monday = WeeklyGridWindowPolicy(totalDayCount: 7, latestAllowedDayIndex: 0)
        let tuesday = WeeklyGridWindowPolicy(totalDayCount: 7, latestAllowedDayIndex: 1)
        expectWeeklyWindow(monday.maximumStartIndex == 0, "周一只能停在首屏")
        expectWeeklyWindow(monday.focusIndex(forWindowStart: 0) == 0, "周一首屏焦点不能被推到未来")
        expectWeeklyWindow(tuesday.focusIndex(forWindowStart: 0) == 1, "周二首屏应以今天为焦点")
    }

    private static func testSundayFinalWindowFocusesToday() {
        let sunday = WeeklyGridWindowPolicy(totalDayCount: 7, latestAllowedDayIndex: 6)
        expectWeeklyWindow(sunday.maximumStartIndex == 4, "周日末屏应显示周五至周日")
        expectWeeklyWindow(sunday.focusIndex(forWindowStart: 4) == 6,
                           "周日位于最右列时，逻辑焦点仍必须是今天而不是周六")
    }

    private static func testFutureStepDoesNotMoveLogicalWindow() {
        let policy = WeeklyGridWindowPolicy(totalDayCount: 7, latestAllowedDayIndex: 3)
        expectWeeklyWindow(policy.steppedStartIndex(from: 2, by: 1) == 2, "滑向未来必须弹回同一窗口")
        expectWeeklyWindow(policy.steppedStartIndex(from: 0, by: -1) == 0, "滑过周首必须弹回首屏")
    }

    private static func testFocusedDayDerivesStableWindow() {
        let historical = WeeklyGridWindowPolicy(totalDayCount: 7)
        expectWeeklyWindow(historical.startIndex(focusedIndex: 0) == 0, "周一聚焦应贴左")
        expectWeeklyWindow(historical.startIndex(focusedIndex: 3) == 2, "周四聚焦应在中列")
        expectWeeklyWindow(historical.startIndex(focusedIndex: 6) == 4, "周日聚焦应贴右")
    }
}
