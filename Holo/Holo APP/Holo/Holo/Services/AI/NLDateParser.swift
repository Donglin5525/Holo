//
//  NLDateParser.swift
//  Holo
//
//  中文自然语言日期解析器
//  将"明天下午3点"、"下周一上午10点"等表达解析为 Date
//

import Foundation

/// 中文自然语言日期解析器
enum NLDateParser {

    // MARK: - Public API

    /// 解析日期文本为 Date
    /// - 优先尝试标准格式（yyyy-MM-dd, yyyy-MM-dd HH:mm）
    /// - 回退到中文自然语言解析
    static func parse(_ text: String, referenceDate: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let date = parseStandardFormat(trimmed) { return date }
        return parseChineseNL(trimmed, referenceDate: referenceDate)
    }

    /// 文本是否包含具体时间（时/分）
    /// - 中文格式: "14点45分"、"下午3点半"
    /// - 标准格式: "2026-05-16 14:45"（包含 HH:mm 部分）
    static func containsTimeComponent(_ text: String) -> Bool {
        if extractHourMinute(text) != nil { return true }
        // 标准格式 yyyy-MM-dd HH:mm 包含时间部分
        let pattern = #"^\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Standard Format

    private static func parseStandardFormat(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current

        let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Chinese Natural Language

    private static func parseChineseNL(_ text: String, referenceDate: Date) -> Date? {
        let calendar = Calendar.current

        guard let targetDay = resolveDay(text, referenceDate: referenceDate, calendar: calendar) else {
            // 无日期关键词，检查是否有纯时间表达（"下午3点" → 今天）
            guard let (hour, minute) = extractHourMinute(text) else { return nil }
            var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            components.hour = hour
            components.minute = minute
            return calendar.date(from: components)
        }

        var components = calendar.dateComponents([.year, .month, .day], from: targetDay)

        if let (hour, minute) = extractHourMinute(text) {
            components.hour = hour
            components.minute = minute
        }

        return calendar.date(from: components)
    }

    // MARK: - Day Resolution

    private static func resolveDay(_ text: String, referenceDate: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: referenceDate)

        // 相对日期（长词优先，避免"大后天"被"后天"抢先匹配）
        let relativeDays: [(keyword: String, offset: Int)] = [
            ("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1),
            ("今天", 0), ("今日", 0),
            ("昨天", -1), ("昨日", -1)
        ]
        for (keyword, offset) in relativeDays {
            if text.contains(keyword) {
                return calendar.date(byAdding: .day, value: offset, to: startOfToday)
            }
        }

        // 今晚/明晚/今早/明早 → 日期偏移 + 时间留给时间解析
        if text.contains("今晚") { return startOfToday }
        if text.contains("明晚") { return calendar.date(byAdding: .day, value: 1, to: startOfToday) }
        if text.contains("今早") { return startOfToday }
        if text.contains("明早") { return calendar.date(byAdding: .day, value: 1, to: startOfToday) }

        // 星期（长词优先）
        let weekdayMap: [(keyword: String, weekday: Int)] = [
            ("星期一", 2), ("周一", 2),
            ("星期二", 3), ("周二", 3),
            ("星期三", 4), ("周三", 4),
            ("星期四", 5), ("周四", 5),
            ("星期五", 6), ("周五", 6),
            ("星期六", 7), ("周六", 7),
            ("星期日", 1), ("周日", 1), ("星期天", 1), ("周天", 1)
        ]

        for (keyword, targetWeekday) in weekdayMap {
            if text.contains("下" + keyword) {
                return advanceToWeekday(targetWeekday, nextWeek: true, referenceDate: referenceDate, calendar: calendar)
            }
            if text.contains("这" + keyword) || text.contains(keyword) {
                return advanceToWeekday(targetWeekday, nextWeek: false, referenceDate: referenceDate, calendar: calendar)
            }
        }

        return nil
    }

    private static func advanceToWeekday(
        _ targetWeekday: Int,
        nextWeek: Bool,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let currentWeekday = calendar.component(.weekday, from: referenceDate)

        var offset = (targetWeekday - currentWeekday + 7) % 7

        if nextWeek {
            // "下周X" → 至少跨一周
            if offset == 0 { offset = 7 }
        } else {
            // "周X" / "这周X" → 最近未来，但今天是同一天则保持
            // offset == 0 表示今天，保持不变
        }

        return calendar.date(byAdding: .day, value: offset, to: startOfToday)!
    }

    // MARK: - Time Extraction

    /// 从文本中提取时间（时/分），考虑中文时段
    private static func extractHourMinute(_ text: String) -> (hour: Int, minute: Int)? {
        // 匹配: X点[Y分] 或 X点半
        let pattern = "(\\d{1,2})\\s*点(?:\\s*(\\d{1,2})\\s*分|半)?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        guard let hourRange = Range(match.range(at: 1), in: text),
              let rawHour = Int(String(text[hourRange])) else { return nil }

        var minute = 0

        if let minuteRange = Range(match.range(at: 2), in: text),
           let m = Int(String(text[minuteRange])) {
            minute = m
        }

        // "半" = 30 分钟
        if let fullRange = Range(match.range, in: text) {
            let matched = String(text[fullRange])
            if matched.contains("半") { minute = 30 }
        }

        let adjustedHour = applyPeriodAdjustment(text, hour: rawHour)

        guard adjustedHour >= 0 && adjustedHour <= 23, minute >= 0, minute <= 59 else { return nil }
        return (adjustedHour, minute)
    }

    /// 根据时段关键词调整小时数
    private static func applyPeriodAdjustment(_ text: String, hour: Int) -> Int {
        // 凌晨: 0-5 → 不调整
        if text.contains("凌晨") { return hour }

        // 上午/早上/今早: → 不调整
        if text.contains("上午") || text.contains("早上") || text.contains("今早") { return hour }

        // 中午: → 不调整（12点就是中午）
        if text.contains("中午") { return hour }

        // 下午/傍晚/晚上/今晚/明晚 等: +12 if hour < 12
        if text.contains("下午") || text.contains("傍晚") ||
           text.contains("晚上") || text.contains("夜晚") || text.contains("夜里") ||
           text.contains("今晚") || text.contains("明晚") || text.contains("昨晚") {
            return hour < 12 ? hour + 12 : hour
        }

        // 无时段: "3点" → 默认下午（任务场景中更合理）
        if hour >= 1 && hour <= 6 { return hour + 12 }

        return hour
    }
}
