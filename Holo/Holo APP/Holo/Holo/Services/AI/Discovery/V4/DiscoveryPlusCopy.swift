import Foundation

// 「一个发现」Plus 分层文案工具（2026-11-21 I4b）。文案真源：01-产品方案与文案真源.md。
enum DiscoveryPlusCopy {
    /// 与后端 HOLO_DISCOVERY_INSIGHT_PLUS_WEEKLY 默认值同步；免费用户拿不到 Plus 上限时用于文案。
    static let plusWeeklyLimit = 5
    /// 与后端 HOLO_DISCOVERY_INSIGHT_FREE_WEEKLY 默认值同步。
    static let freeWeeklyLimit = 1

    /// {resetText}：今天 HH:mm 之后 / 明天 / M 月 d 日（EEE） / 下周。
    static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "下周" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: date)) 之后"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天"
        }
        formatter.dateFormat = "M 月 d 日（EEE）"
        return formatter.string(from: date)
    }

    /// 往期发现分组标题：本周 →「这周」，其余「M 月 d 日 – M 月 d 日」（周一为一周开始）。
    static func weekTitle(for date: Date, now: Date = Date(), calendar baseCalendar: Calendar = .current) -> String {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return "" }
        if calendar.isDate(now, equalTo: date, toGranularity: .weekOfYear) { return "这周" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M 月 d 日"
        let end = week.end.addingTimeInterval(-1)
        return "\(formatter.string(from: week.start)) – \(formatter.string(from: end))"
    }
}
