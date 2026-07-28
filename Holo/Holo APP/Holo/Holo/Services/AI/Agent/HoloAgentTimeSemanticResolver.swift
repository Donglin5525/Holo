//
//  HoloAgentTimeSemanticResolver.swift
//  Holo
//
//  HoloAI Agent V3.1 — 确定性时间语义解析。
//

import Foundation

nonisolated enum HoloAgentTimeSemanticKind: String, Equatable, Sendable {
    case currentMonth
    case previousMonth
    case currentWeek
    case previousWeek
    case recentDays
    case explicitMonth
    case explicitYear
    case currentYear
    case previousYear
}

nonisolated struct HoloAgentResolvedTimeScope: Equatable, Sendable {
    var kind: HoloAgentTimeSemanticKind
    var matchedText: String
    var timeRange: HoloAgentTimeRange
}

/// 对比类问题的双时间窗解析结果（本期 + 对比期）。
/// 当问题同时包含“这个月/本月”与“上个月/上月”等配对词时返回，否则为 nil（回退单窗语义）。
nonisolated struct HoloAgentResolvedComparison: Equatable, Sendable {
    var current: HoloAgentResolvedTimeScope
    var baseline: HoloAgentResolvedTimeScope
}

/// 历史事实工具的时间截断结果。用户可以询问完整自然年，但“已发生统计”只能算到
/// 本地快照日结束；未来分期、未来任务等计划记录不得混入历史事实。
nonisolated struct HoloAgentHistoricalRangeResolution: Equatable, Sendable {
    var effectiveRange: HoloAgentTimeRange?
    var wasCapped: Bool
    var isEntirelyFuture: Bool
}

nonisolated enum HoloAgentHistoricalTimePolicy {

    static func resolve(
        _ range: HoloAgentTimeRange?,
        asOf: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> HoloAgentHistoricalRangeResolution {
        guard let range,
              let requestedStart = range.start,
              let requestedEnd = range.end else {
            return HoloAgentHistoricalRangeResolution(
                effectiveRange: range,
                wasCapped: false,
                isEntirelyFuture: false
            )
        }
        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: asOf)
        let cutoff = calendar.date(byAdding: .day, value: 1, to: today) ?? asOf

        guard requestedStart < cutoff else {
            return HoloAgentHistoricalRangeResolution(
                effectiveRange: nil,
                wasCapped: true,
                isEntirelyFuture: true
            )
        }
        guard requestedEnd > cutoff else {
            return HoloAgentHistoricalRangeResolution(
                effectiveRange: range,
                wasCapped: false,
                isEntirelyFuture: false
            )
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let label = "\(range.label)（截至\(formatter.string(from: today))）"
        return HoloAgentHistoricalRangeResolution(
            effectiveRange: HoloAgentTimeRange(
                label: label,
                start: requestedStart,
                end: cutoff
            ),
            wasCapped: true,
            isEntirelyFuture: false
        )
    }
}

nonisolated enum HoloAgentTimeSemanticResolver {

    static func resolve(_ text: String, referenceDate: Date = Date(), calendar inputCalendar: Calendar = .current) -> HoloAgentResolvedTimeScope? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: referenceDate)

        if let lexical = earliestLexicalMatch(in: normalized) {
            return resolveLexical(lexical, today: today, calendar: calendar)
        }

        if let explicitMonth = resolveExplicitMonth(in: normalized, today: today, calendar: calendar) {
            return explicitMonth
        }

        if let explicitYear = resolveExplicitYear(in: normalized, calendar: calendar) {
            return explicitYear
        }

        return nil
    }

    /// 解析对比类问题（如“这个月比上个月消费多在哪”“今年比去年”）。
    /// 当问题同时命中 current/baseline 词法配对时返回双窗；否则返回 nil，调用方回退到 `resolve` 的单窗语义。
    /// 这是所有对比类问题的公共基础设施——不枚举具体问法，只按词法 kind 配对。
    static func resolveComparison(_ text: String, referenceDate: Date = Date(), calendar inputCalendar: Calendar = .current) -> HoloAgentResolvedComparison? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: referenceDate)

        let matches = allLexicalMatches(in: normalized)
        // 按 kind 归类，同一 kind 可能多次出现，取第一个即可。
        var kindToScope: [HoloAgentTimeSemanticKind: HoloAgentResolvedTimeScope] = [:]
        for match in matches {
            if let resolved = resolveLexical(match, today: today, calendar: calendar),
               kindToScope[resolved.kind] == nil {
                kindToScope[resolved.kind] = resolved
            }
        }

        // 按优先级匹配对比配对：月 → 周 → 年。
        let pairs: [(current: HoloAgentTimeSemanticKind, baseline: HoloAgentTimeSemanticKind)] = [
            (.currentMonth, .previousMonth),
            (.currentWeek, .previousWeek),
            (.currentYear, .previousYear)
        ]
        for pair in pairs {
            if let current = kindToScope[pair.current],
               let baseline = kindToScope[pair.baseline] {
                return HoloAgentResolvedComparison(current: current, baseline: baseline)
            }
        }
        return nil
    }

    private static func resolveLexical(_ match: LexicalMatch, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        switch match.kind {
        case .currentMonth:
            guard let range = calendar.dateInterval(of: .month, for: today) else { return nil }
            return scope(kind: .currentMonth, matchedText: match.phrase, label: "本月", start: range.start, end: range.end)

        case .previousMonth:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: today),
                  let range = calendar.dateInterval(of: .month, for: previous) else { return nil }
            return scope(kind: .previousMonth, matchedText: match.phrase, label: "上月", start: range.start, end: range.end)

        case .currentWeek:
            guard let range = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
            return scope(kind: .currentWeek, matchedText: match.phrase, label: "本周", start: range.start, end: range.end)

        case .previousWeek:
            guard let current = calendar.dateInterval(of: .weekOfYear, for: today),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start) else { return nil }
            return scope(kind: .previousWeek, matchedText: match.phrase, label: "上周", start: start, end: current.start)

        case .recentWeek:
            return recentDaysScope(days: 7, matchedText: match.phrase, today: today, calendar: calendar)

        case .recentMonth:
            return recentDaysScope(days: 30, matchedText: match.phrase, today: today, calendar: calendar)

        case .recentDays(let days):
            return recentDaysScope(days: days, matchedText: match.phrase, today: today, calendar: calendar)

        case .currentYear:
            guard let range = calendar.dateInterval(of: .year, for: today) else { return nil }
            return scope(kind: .currentYear, matchedText: match.phrase, label: "今年", start: range.start, end: range.end)

        case .previousYear:
            guard let previous = calendar.date(byAdding: .year, value: -1, to: today),
                  let range = calendar.dateInterval(of: .year, for: previous) else { return nil }
            return scope(kind: .previousYear, matchedText: match.phrase, label: "去年", start: range.start, end: range.end)

        case .explicitMonthMarker:
            return nil
        }
    }

    private static func recentDaysScope(days: Int, matchedText: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        guard days > 0,
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return scope(kind: .recentDays, matchedText: matchedText, label: "近\(days)天", start: start, end: end)
    }

    private static func resolveExplicitMonth(in text: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        if let yearMonth = firstYearMonth(in: text) {
            return explicitMonthScope(year: yearMonth.year, month: yearMonth.month, matchedText: yearMonth.matchedText, calendar: calendar)
        }
        if let numeric = firstNumericMonth(in: text) {
            return explicitMonthScope(month: numeric.month, matchedText: numeric.matchedText, today: today, calendar: calendar)
        }
        if let chinese = firstChineseMonth(in: text) {
            return explicitMonthScope(month: chinese.month, matchedText: chinese.matchedText, today: today, calendar: calendar)
        }
        return nil
    }

    private static func explicitMonthScope(year: Int, month: Int, matchedText: String, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        guard (1...12).contains(month),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }

        let label = "\(year)年\(month)月"
        return scope(kind: .explicitMonth, matchedText: matchedText, label: label, start: start, end: end)
    }

    private static func explicitMonthScope(month: Int, matchedText: String, today: Date, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        guard (1...12).contains(month) else { return nil }

        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)
        let year = month <= currentMonth ? currentYear : currentYear - 1
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }

        let label = "\(month)月"
        return scope(kind: .explicitMonth, matchedText: matchedText, label: label, start: start, end: end)
    }

    /// 裸年份（无月份）：如「2026年体重趋势」。必须排在 explicitMonth 之后，
    /// 避免吃掉「2026年7月」；负向断言保证后面不紧跟月份。
    private static func resolveExplicitYear(in text: String, calendar: Calendar) -> HoloAgentResolvedTimeScope? {
        let pattern = #"((?:19|20)\d{2})年(?!(?:1[0-2]|[1-9])月)"#
        guard let match = firstRegexMatch(pattern: pattern, in: text),
              let yearText = match.captures.first,
              let year = Int(yearText),
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
        return scope(kind: .explicitYear, matchedText: match.matchedText, label: "\(year)年", start: start, end: end)
    }

    private static func firstYearMonth(in text: String) -> (year: Int, month: Int, matchedText: String)? {
        let pattern = #"((?:19|20)\d{2})年(1[0-2]|[1-9])月份?(?!\d)"#
        guard let match = firstRegexMatch(pattern: pattern, in: text),
              match.captures.count >= 2,
              let year = Int(match.captures[0]),
              let month = Int(match.captures[1]) else { return nil }
        return (year, month, match.matchedText)
    }

    private static func firstNumericMonth(in text: String) -> (month: Int, matchedText: String)? {
        let pattern = #"(?<!\d)(1[0-2]|[1-9])月份?(?!\d)"#
        guard let match = firstRegexMatch(pattern: pattern, in: text),
              let month = Int(match.captures.first ?? "") else { return nil }
        return (month, match.matchedText)
    }

    private static func firstChineseMonth(in text: String) -> (month: Int, matchedText: String)? {
        let monthMap: [(String, Int)] = [
            ("十二月", 12), ("十一月", 11), ("十月", 10),
            ("九月", 9), ("八月", 8), ("七月", 7), ("六月", 6),
            ("五月", 5), ("四月", 4), ("三月", 3), ("二月", 2), ("一月", 1)
        ]
        let matches = monthMap.compactMap { phrase, month -> LexicalMatch? in
            guard let range = text.range(of: phrase) else { return nil }
            return LexicalMatch(kind: .explicitMonthMarker, phrase: phrase, location: text.distance(from: text.startIndex, to: range.lowerBound), month: month)
        }
        guard let first = matches.sorted(by: { $0.location < $1.location }).first,
              let month = first.month else { return nil }
        return (month, first.phrase)
    }

    private static func scope(kind: HoloAgentTimeSemanticKind, matchedText: String, label: String, start: Date, end: Date) -> HoloAgentResolvedTimeScope {
        HoloAgentResolvedTimeScope(
            kind: kind,
            matchedText: matchedText,
            timeRange: HoloAgentTimeRange(label: label, start: start, end: end)
        )
    }

    private static func normalize(_ text: String) -> String {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "０", with: "0")  // 全角数字归一
            .replacingOccurrences(of: "１", with: "1")
            .replacingOccurrences(of: "２", with: "2")
            .replacingOccurrences(of: "３", with: "3")
            .replacingOccurrences(of: "４", with: "4")
            .replacingOccurrences(of: "５", with: "5")
            .replacingOccurrences(of: "６", with: "6")
            .replacingOccurrences(of: "７", with: "7")
            .replacingOccurrences(of: "８", with: "8")
            .replacingOccurrences(of: "９", with: "9")
        return Self.normalizeChineseYearAndMonth(cleaned)
    }

    /// 把紧跟在「年」「月」「月份」前的中文数字序列归一为阿拉伯数字。
    /// 只处理时间语境（年/月），不误伤「一个月」「第一天」等日常表达。
    /// 例：「二零二六年」→「2026年」、「二零二六年七月」→「2026年7月」。
    private static func normalizeChineseYearAndMonth(_ text: String) -> String {
        let digitMap: [Character: Character] = [
            "零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
            "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"
        ]
        // 匹配「连续中文数字 + 年 或 月 或 月份」。
        let pattern = #"([零〇一二三四五六七八九]{1,6})(年|月份?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let mutable = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // 倒序替换：保证未处理 match 的 NSRange 仍指向原始位置（后面的替换只影响更靠后的偏移）。
        let matches = regex.matches(in: mutable as String, range: fullRange).reversed()
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let numerals = mutable.substring(with: match.range(at: 1))
            let suffix = mutable.substring(with: match.range(at: 2))
            // 逐字映射：「二零二六」→「2026」。（不处理「十/百」，年份/月份场景不需要。）
            let arabic = numerals.map { digitMap[$0].map(String.init) ?? String($0) }.joined()
            mutable.replaceCharacters(in: match.range, with: arabic + suffix)
        }
        return mutable as String
    }

    /// 扫描文本中所有词法时间匹配（currentMonth/previousMonth/currentWeek 等）。
    /// 同一 kind 可能出现多次（如“上个月”和“上月”同时出现），按 location 排序。
    private static func allLexicalMatches(in text: String) -> [LexicalMatch] {
        let phrases: [(LexicalKind, [String])] = [
            (.previousMonth, ["上个月", "上月", "上一月", "前一个月"]),
            (.currentMonth, ["这个月", "本月", "这月", "当月"]),
            (.previousWeek, ["上个星期", "上星期", "上一周", "上周"]),
            (.currentWeek, ["这个星期", "这星期", "本周", "这周"]),
            (.recentMonth, ["最近一个月", "近一个月", "近30天", "最近30天"]),
            (.recentWeek, ["最近一周", "近一周", "近7天", "最近7天"]),
            (.previousYear, ["去年", "上一年"]),
            (.currentYear, ["今年", "本年"])
        ]

        var matches: [LexicalMatch] = []
        for (kind, candidates) in phrases {
            for phrase in candidates {
                guard let range = text.range(of: phrase) else { continue }
                matches.append(LexicalMatch(kind: kind, phrase: phrase, location: text.distance(from: text.startIndex, to: range.lowerBound), month: nil))
            }
        }

        if let recentDays = firstRegexMatch(pattern: #"最近(\d{1,3})天|近(\d{1,3})天"#, in: text),
           let daysText = recentDays.captures.first(where: { !$0.isEmpty }),
           let days = Int(daysText), days > 0 {
            matches.append(LexicalMatch(kind: .recentDays(days), phrase: recentDays.matchedText, location: recentDays.location, month: nil))
        }

        return matches.sorted {
            if $0.location == $1.location { return $0.phrase.count > $1.phrase.count }
            return $0.location < $1.location
        }
    }

    private static func earliestLexicalMatch(in text: String) -> LexicalMatch? {
        allLexicalMatches(in: text).first
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let matchRange = Range(match.range, in: text) else { return nil }

        let captures = (1..<match.numberOfRanges).map { index -> String in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
        return RegexMatch(
            matchedText: String(text[matchRange]),
            captures: captures,
            location: text.distance(from: text.startIndex, to: matchRange.lowerBound)
        )
    }

    private enum LexicalKind: Equatable {
        case currentMonth
        case previousMonth
        case currentWeek
        case previousWeek
        case recentWeek
        case recentMonth
        case recentDays(Int)
        case currentYear
        case previousYear
        case explicitMonthMarker
    }

    private struct LexicalMatch: Equatable {
        var kind: LexicalKind
        var phrase: String
        var location: Int
        var month: Int?
    }

    private struct RegexMatch: Equatable {
        var matchedText: String
        var captures: [String]
        var location: Int
    }
}
