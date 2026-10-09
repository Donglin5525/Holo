import Foundation

/// 后台 AI 任务的谷时段判定——DeepSeek 峰谷计费口径（2026-10-09 降本两件套之一）。
///
/// 高峰（北京时间，工作日）：09:00–12:00、14:00–18:00；其余时段谷价，周六周日全天谷价
/// （官方 2026-08-23 更新：周末不再区分峰谷）。谷价约为高峰一半，把可延迟的后台任务
/// （记忆萃取/核验、想法主题分类、想法整理、回放摘要、BGTask 洞察）压进谷时段执行。
///
/// 时区语义：上游按北京时间计费，这里必须钉 `Asia/Shanghai`，与各调度器频控跟随
/// 设备本地日历（Calendar.current）的「用户的一天」语义是两类正确差异，不要合并。
enum HoloAIWindowPolicy {
    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// 测试时钟注入点：生产恒为真实时钟，仅测试替换以脱离真实峰谷时段。
    nonisolated(unsafe) static var nowProvider: () -> Date = { Date() }

    /// 工作日高峰小时（9–12、14–18，左闭右开）。
    private static let peakHourRanges: [Range<Int>] = [9..<12, 14..<18]

    static func beijingCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        return calendar
    }

    /// 当前是否谷时段。周末（周六/周日）全天为谷。
    static func isValleyWindow(at date: Date? = nil, calendar: Calendar = beijingCalendar()) -> Bool {
        let date = date ?? nowProvider()
        let weekday = calendar.component(.weekday, from: date) // 1=周日 7=周六
        if weekday == 1 || weekday == 7 { return true }
        let hour = calendar.component(.hour, from: date)
        return !peakHourRanges.contains { $0.contains(hour) }
    }

    /// 下一个谷时段的起点：当前已是谷则返回自身；工作日高峰内分别为当日 12:00 / 18:00。
    /// 供延迟调度使用（retryAt / nextAttemptAt / BGTask earliestBeginDate）。
    static func nextValleyStart(after date: Date? = nil, calendar: Calendar = beijingCalendar()) -> Date {
        let date = date ?? nowProvider()
        if isValleyWindow(at: date, calendar: calendar) { return date }
        let hour = calendar.component(.hour, from: date)
        let valleyHour = (9..<12).contains(hour) ? 12 : 18
        return calendar.date(bySettingHour: valleyHour, minute: 0, second: 0, of: date) ?? date
    }
}
