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
    case currentYear
    case previousYear
}

nonisolated struct HoloAgentResolvedTimeScope: Equatable, Sendable {
    var kind: HoloAgentTimeSemanticKind
    var matchedText: String
    var timeRange: HoloAgentTimeRange
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
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    private static func earliestLexicalMatch(in text: String) -> LexicalMatch? {
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
        }.first
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
