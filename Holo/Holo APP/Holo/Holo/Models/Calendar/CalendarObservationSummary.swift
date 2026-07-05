//
//  CalendarObservationSummary.swift
//  Holo
//
//  日历轻量观察摘要：本地规则先给可信观察，未来可接 Agent 缓存深读。
//

import Foundation

struct CalendarObservationSummary: Equatable {
    enum Scope {
        case week
        case month
    }

    enum Tone {
        case empty
        case quiet
        case normal
        case notable
    }

    enum Source {
        case local
        case agentCached
    }

    let title: String
    let evidence: String
    let tone: Tone
    let source: Source

    static func make(events: [CalendarEvent], scope: Scope) -> CalendarObservationSummary {
        guard !events.isEmpty else {
            return CalendarObservationSummary(
                title: scope == .week ? "这周还没有留下太多痕迹。" : "这个月的记录还很安静。",
                evidence: "基于 0 条记录",
                tone: .empty,
                source: .local
            )
        }

        let calendar = Calendar.current
        let modules = Set(events.map(\.module))
        let dayCount = Set(events.map { calendar.startOfDay(for: $0.date) }).count
        let evidence = "基于 \(events.count) 条记录 · \(modules.count) 个模块 · \(dayCount) 天"

        if let dominantModule = dominantModule(in: events), moduleShare(dominantModule, in: events) >= 0.6 {
            return CalendarObservationSummary(
                title: "\(scopeText(scope))主要被\(dominantModule.displayName)记录占据。",
                evidence: evidence,
                tone: events.count >= 5 ? .notable : .normal,
                source: .local
            )
        }

        if let peak = peakDay(in: events), peak.count >= max(3, events.count / 2) {
            return CalendarObservationSummary(
                title: "\(dayText(peak.day))留下的生活痕迹最密。",
                evidence: evidence,
                tone: .notable,
                source: .local
            )
        }

        let eveningCount = events.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour >= 21 || hour < 6
        }.count
        if eveningCount >= 2 && eveningCount * 2 >= events.count {
            return CalendarObservationSummary(
                title: "\(scopeText(scope))的记录更常出现在夜晚。",
                evidence: evidence,
                tone: .notable,
                source: .local
            )
        }

        return CalendarObservationSummary(
            title: "\(scopeText(scope))有 \(dayCount) 天留下了记录。",
            evidence: evidence,
            tone: events.count <= 2 ? .quiet : .normal,
            source: .local
        )
    }

    private static func scopeText(_ scope: Scope) -> String {
        switch scope {
        case .week: return "这周"
        case .month: return "这个月"
        }
    }

    private static func dominantModule(in events: [CalendarEvent]) -> CalendarModule? {
        Dictionary(grouping: events, by: \.module)
            .max { $0.value.count < $1.value.count }?
            .key
    }

    private static func moduleShare(_ module: CalendarModule, in events: [CalendarEvent]) -> Double {
        guard !events.isEmpty else { return 0 }
        let count = events.filter { $0.module == module }.count
        return Double(count) / Double(events.count)
    }

    private static func peakDay(in events: [CalendarEvent]) -> (day: Date, count: Int)? {
        let calendar = Calendar.current
        return Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .map { (day: $0.key, count: $0.value.count) }
            .max { $0.count < $1.count }
    }

    private static func dayText(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: day)
    }
}
