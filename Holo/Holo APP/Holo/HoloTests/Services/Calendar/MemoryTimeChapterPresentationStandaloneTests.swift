import Foundation

@main
struct MemoryTimeChapterPresentationStandaloneTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2

        let day = date(2026, 8, 19, 0, 0, calendar: calendar)
        let dayEnd = date(2026, 8, 20, 0, 0, calendar: calendar)
        let first = date(2026, 8, 19, 15, 15, calendar: calendar)
        let last = date(2026, 8, 19, 23, 8, calendar: calendar)

        let daily = MemoryTimeChapterPresentation.make(
            scale: .day,
            focusedDate: day,
            periodStart: day,
            periodEnd: dayEnd,
            eventCount: 9,
            momentCount: 7,
            activeDayCount: 1,
            firstEventDate: first,
            lastEventDate: last,
            isCurrentPeriod: true,
            calendar: calendar
        )
        expect(daily.primaryText == "19", "日章节应以日号作为主标题")
        expect(daily.title.contains("8月"), "日章节应显示月份")
        expect(daily.evidence == "7 个记忆时刻 · 15:15—23:08", "日章节证据应包含记忆时刻与首末时间")
        expect(daily.currentBadge == "今天", "当前日应标记今天")

        let single = MemoryTimeChapterPresentation.make(
            scale: .day,
            focusedDate: day,
            periodStart: day,
            periodEnd: dayEnd,
            eventCount: 1,
            momentCount: 1,
            activeDayCount: 1,
            firstEventDate: date(2026, 8, 19, 0, 49, calendar: calendar),
            lastEventDate: date(2026, 8, 19, 0, 49, calendar: calendar),
            isCurrentPeriod: false,
            calendar: calendar
        )
        expect(single.evidence == "1 个记忆时刻 · 00:49", "首末同分钟的记录日，时间只报一次")

        let weekStart = date(2026, 8, 17, 0, 0, calendar: calendar)
        let weekEnd = date(2026, 8, 24, 0, 0, calendar: calendar)
        let weekly = MemoryTimeChapterPresentation.make(
            scale: .week,
            focusedDate: day,
            periodStart: weekStart,
            periodEnd: weekEnd,
            eventCount: 18,
            momentCount: 14,
            activeDayCount: 5,
            firstEventDate: first,
            lastEventDate: last,
            isCurrentPeriod: false,
            calendar: calendar
        )
        expect(weekly.primaryText == "17—23", "周章节应展示完整日期跨度")
        expect(weekly.title.contains("8月 · 第"), "周章节应展示月份与周次")
        expect(weekly.evidence == "5 天有记录 · 14 个记忆时刻", "周章节应展示活跃天数与记忆时刻")
        expect(weekly.currentBadge == nil, "历史周不应显示本周")

        let crossMonth = MemoryTimeChapterPresentation.make(
            scale: .week,
            focusedDate: date(2026, 9, 2, 0, 0, calendar: calendar),
            periodStart: date(2026, 8, 31, 0, 0, calendar: calendar),
            periodEnd: date(2026, 9, 7, 0, 0, calendar: calendar),
            eventCount: 1,
            momentCount: 1,
            activeDayCount: 1,
            firstEventDate: nil,
            lastEventDate: nil,
            isCurrentPeriod: true,
            calendar: calendar
        )
        expect(crossMonth.primaryText == "31—6", "跨月周仍应保持紧凑日期跨度")
        expect(crossMonth.title.contains("8月—9月"), "跨月周应同时说明两个月份")
        expect(crossMonth.currentBadge == "本周", "当前周应标记本周")

        let monthly = MemoryTimeChapterPresentation.make(
            scale: .month,
            focusedDate: day,
            periodStart: date(2026, 8, 1, 0, 0, calendar: calendar),
            periodEnd: date(2026, 9, 1, 0, 0, calendar: calendar),
            eventCount: 0,
            momentCount: 0,
            activeDayCount: 0,
            firstEventDate: nil,
            lastEventDate: nil,
            isCurrentPeriod: true,
            calendar: calendar
        )
        expect(monthly.primaryText == "8月", "月章节应以月份作为主标题")
        expect(monthly.title == "2026年", "月章节应显示年份")
        expect(monthly.evidence == "这个月还没有留下记录", "空月应使用自然的空态文案")
        expect(monthly.currentBadge == "本月", "当前月应标记本月")

        print("MemoryTimeChapterPresentationStandaloneTests passed (5 cases)")
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
