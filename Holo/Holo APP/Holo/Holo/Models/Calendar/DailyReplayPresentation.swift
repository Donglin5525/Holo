//
//  DailyReplayPresentation.swift
//  Holo
//
//  日回放的纯展示规则：把原始事件组织成「时段 → 记忆时刻」，并按场景决定是否折叠连续空白日期。
//  这里不持有 UI 状态，保证分组、文案与跨日结构可以独立验证。
//

import Foundation

enum DailyReplayPeriod: Int, CaseIterable, Identifiable {
    case untimed
    case earlyMorning
    case morning
    case noon
    case afternoon
    case evening
    case lateNight

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .untimed:      return "当天记录"
        case .earlyMorning: return "凌晨"
        case .morning:      return "上午"
        case .noon:         return "中午"
        case .afternoon:    return "下午"
        case .evening:      return "晚上"
        case .lateNight:    return "深夜"
        }
    }

    static func classify(_ event: CalendarEvent, calendar: Calendar = .current) -> DailyReplayPeriod {
        guard event.hasReliableTime else { return .untimed }
        switch calendar.component(.hour, from: event.date) {
        case 0..<6:   return .earlyMorning
        case 6..<11:  return .morning
        case 11..<14: return .noon
        case 14..<18: return .afternoon
        case 18..<22: return .evening
        default:      return .lateNight
        }
    }
}

struct DailyReplayMoment: Identifiable {
    let id: String
    let module: CalendarModule
    let date: Date
    let events: [CalendarEvent]
    let title: String
    let signedTotal: Decimal?

    var timeText: String {
        events.allSatisfy { !$0.hasReliableTime }
            ? "当天"
            : Self.timeFormatter.string(from: date)
    }

    var recordCountText: String? {
        events.count > 1 ? "\(events.count) 条记录" : nil
    }

    var singleValueText: String? {
        guard events.count == 1 else { return nil }
        return events[0].detail
    }

    var contextText: String? {
        guard events.count == 1 else { return nil }
        let event = events[0]
        if let context = event.context, !context.isEmpty { return context }
        guard event.module != .finance else { return nil }
        return event.detail
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

enum DailyReplayPresentation {

    /// 同一分钟、同一模块属于同一个生活动作，合成一个「记忆时刻」。
    /// 不跨模块合并，避免把同一时刻的记账和习惯误表达成同一件事。
    static func moments(from events: [CalendarEvent], calendar: Calendar = .current) -> [DailyReplayMoment] {
        struct MomentKey: Hashable {
            let module: CalendarModule
            let minute: Int
        }

        let groups = Dictionary(grouping: events) { event in
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: event.date)
            let minute = (((((components.year ?? 0) * 13 + (components.month ?? 0)) * 32
                            + (components.day ?? 0)) * 24 + (components.hour ?? 0)) * 60
                          + (components.minute ?? 0))
            return MomentKey(module: event.module, minute: minute)
        }

        return groups.values.map { rawEvents in
            let sorted = rawEvents.sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            let module = sorted[0].module
            return DailyReplayMoment(
                id: sorted.map { $0.id.uuidString }.joined(separator: "-"),
                module: module,
                date: sorted[0].date,
                events: sorted,
                title: groupTitle(for: sorted, module: module),
                signedTotal: signedFinanceTotal(for: sorted, module: module)
            )
        }
        .sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.module.rawValue < rhs.module.rawValue
        }
    }

    static func momentsByPeriod(from events: [CalendarEvent], calendar: Calendar = .current) -> [DailyReplayPeriod: [DailyReplayMoment]] {
        Dictionary(grouping: moments(from: events, calendar: calendar)) { moment in
            DailyReplayPeriod.classify(moment.events[0], calendar: calendar)
        }
    }

    /// 只在数据确实形成明显结构时生成一天的小结，避免每一天都硬凑 AI 式文案。
    static func narrative(for events: [CalendarEvent], calendar: Calendar = .current) -> String? {
        guard events.count >= 4 else { return nil }

        let reliable = events.filter(\.hasReliableTime).sorted { $0.date < $1.date }
        let nightCount = reliable.filter { calendar.component(.hour, from: $0.date) >= 18 }.count
        if reliable.count >= 4, Double(nightCount) / Double(reliable.count) >= 0.65 {
            return "这一天的记忆，大多留在夜里。"
        }

        if let first = reliable.first?.date,
           let last = reliable.last?.date,
           calendar.component(.hour, from: first) < 8,
           calendar.component(.hour, from: last) >= 21 {
            return "从清晨到夜晚，这一天留下了完整的生活轨迹。"
        }

        let moduleCounts = Dictionary(grouping: events, by: \.module).mapValues(\.count)
        guard let dominant = moduleCounts.max(by: { $0.value < $1.value }),
              Double(dominant.value) / Double(events.count) >= 0.6 else {
            return moduleCounts.count >= 3 ? "行动、往来与想法，在这一天交织成一段生活。" : nil
        }

        switch dominant.key {
        case .finance: return "这一天的生活往来，被认真地留了下来。"
        case .habit:   return "一些微小而持续的完成，构成了这一天。"
        case .todo:    return "这一天向前推进了不少事情。"
        case .thought: return "这一天留下了不少值得回看的念头。"
        case .health:  return "这一天，对身体的感受格外清晰。"
        }
    }

    private static func groupTitle(for events: [CalendarEvent], module: CalendarModule) -> String {
        guard events.count > 1 else { return events[0].title }
        switch module {
        case .finance:
            let directions = Set(events.compactMap(\.valueDirection))
            if directions == [.positive] { return "\(events.count) 笔收入" }
            if directions == [.negative] { return "\(events.count) 笔支出" }
            return "\(events.count) 笔记账"
        case .habit:   return "完成了 \(events.count) 个习惯"
        case .todo:    return "完成了 \(events.count) 项待办"
        case .thought: return "记录了 \(events.count) 条想法"
        case .health:  return "留下了 \(events.count) 条健康记录"
        }
    }

    private static func signedFinanceTotal(for events: [CalendarEvent], module: CalendarModule) -> Decimal? {
        guard module == .finance, events.allSatisfy({ $0.numericValue != nil && $0.valueDirection != nil }) else {
            return nil
        }
        return events.reduce(Decimal.zero) { partial, event in
            guard let value = event.numericValue, let direction = event.valueDirection else { return partial }
            return partial + (direction == .negative ? -value : value)
        }
    }
}

enum DailyReplayChapter: Identifiable {
    case day(Date)
    case gap([Date])

    var id: String {
        switch self {
        case .day(let date):
            return "day-\(Int(date.timeIntervalSinceReferenceDate))"
        case .gap(let dates):
            let first = Int(dates.first?.timeIntervalSinceReferenceDate ?? 0)
            let last = Int(dates.last?.timeIntervalSinceReferenceDate ?? 0)
            return "gap-\(first)-\(last)"
        }
    }
}

enum DailyReplayChapterBuilder {

    /// 3 天及以上的连续空白段折成一个章节；首日和当前范围末日始终保留，保证上下文完整。
    static func make(from start: Date,
                     through end: Date,
                     eventCountsByDay: [Date: Int],
                     collapseEmptyRuns: Bool = true,
                     calendar: Calendar = .current) -> [DailyReplayChapter] {
        let startDay = calendar.startOfDay(for: min(start, end))
        let endDay = calendar.startOfDay(for: max(start, end))
        var days: [Date] = []
        var cursor = startDay
        while cursor <= endDay {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // 日回放要求每个自然日都能通过滑动抵达，因此关闭折叠时保留全部日期章节。
        if !collapseEmptyRuns {
            return days.map(DailyReplayChapter.day)
        }

        var result: [DailyReplayChapter] = []
        var index = 0
        while index < days.count {
            let day = days[index]
            if (eventCountsByDay[day] ?? 0) > 0 || index == 0 || index == days.count - 1 {
                result.append(.day(day))
                index += 1
                continue
            }

            var endIndex = index
            while endIndex + 1 < days.count - 1,
                  (eventCountsByDay[days[endIndex + 1]] ?? 0) == 0 {
                endIndex += 1
            }
            let run = Array(days[index...endIndex])
            if run.count >= 3 {
                result.append(.gap(run))
            } else {
                result.append(contentsOf: run.map(DailyReplayChapter.day))
            }
            index = endIndex + 1
        }
        return result
    }
}

// MARK: - 空白日滑动导航

enum DailyReplayEmptyDaySwipeDirection {
    case upward
    case downward
}

enum DailyReplayEmptyDayNavigation {
    /// 空白日没有足够内容产生系统滚动时，把纵向手势明确转换成日期动作。
    /// 历史日上滑进入下一天；今天之后不可浏览，因此今天上滑回看昨天。
    static func target(from day: Date,
                       direction: DailyReplayEmptyDaySwipeDirection,
                       today: Date,
                       calendar: Calendar = .current) -> Date {
        let current = calendar.startOfDay(for: min(day, today))
        let todayStart = calendar.startOfDay(for: today)

        switch direction {
        case .upward:
            if current < todayStart,
               let next = calendar.date(byAdding: .day, value: 1, to: current) {
                return min(next, todayStart)
            }
            return calendar.date(byAdding: .day, value: -1, to: current) ?? current

        case .downward:
            return calendar.date(byAdding: .day, value: -1, to: current) ?? current
        }
    }
}
