//
//  HabitFocusModels.swift
//  Holo
//
//  习惯关注主题语义：统一好习惯与减少型/戒除型坏习惯的 AI 表达
//

import Foundation

enum HabitFocusSource: String, Codable, Equatable, Hashable, Sendable {
    case manualBadHabit
    case habitKeyword
    case goalKeyword
    case profileKeyword
}

enum HabitFocusTrend: String, Codable, Equatable, Sendable {
    case better
    case stable
    case worse
    case unknown
}

struct HabitFocusSignal: Codable, Equatable, Sendable {
    let polarity: HabitPolarity
    let sources: Set<HabitFocusSource>
    let needsClarification: Bool

    static func classify(
        habitName: String,
        isBadHabit: Bool,
        goalTitle: String?,
        profileContext: String?
    ) -> HabitFocusSignal {
        var sources: Set<HabitFocusSource> = []

        if isBadHabit {
            sources.insert(.manualBadHabit)
        }
        if containsNegativeHabitKeyword(habitName) {
            sources.insert(.habitKeyword)
        }
        if let goalTitle, containsNegativeHabitKeyword(goalTitle) {
            sources.insert(.goalKeyword)
        }
        if let profileContext, containsNegativeHabitKeyword(profileContext) {
            sources.insert(.profileKeyword)
        }

        if isBadHabit {
            return HabitFocusSignal(polarity: .negative, sources: sources, needsClarification: false)
        }

        if sources.contains(.goalKeyword) || sources.contains(.profileKeyword) {
            return HabitFocusSignal(polarity: .negative, sources: sources, needsClarification: false)
        }

        let keywordSourceCount = sources.filter { $0 != .manualBadHabit }.count
        return HabitFocusSignal(
            polarity: .positive,
            sources: sources,
            needsClarification: keywordSourceCount == 1
        )
    }

    private static func containsNegativeHabitKeyword(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let keywords = [
            "戒烟", "抽烟", "吸烟", "香烟", "烟瘾", "复吸", "少抽烟", "少抽",
            "戒酒", "喝酒", "少喝酒", "暴食", "熬夜", "戒糖", "少糖"
        ]
        return keywords.contains { normalized.contains($0) }
    }
}

struct HabitFocusSummary: Codable, Equatable, Sendable {
    let habitName: String
    let signal: HabitFocusSignal
    let current: HabitPerformanceSnapshot
    let previous: HabitPerformanceSnapshot?
    let currentStreak: Int
    let goalTitle: String?

    var trend: HabitFocusTrend {
        guard signal.polarity == .negative else {
            return positiveTrend
        }
        return negativeTrend
    }

    var totalValueDelta: Double? {
        guard let current = current.totalValue, let previous = previous?.totalValue else { return nil }
        return current - previous
    }

    var overLimitDaysDelta: Int? {
        guard let current = current.overLimitDays, let previous = previous?.overLimitDays else { return nil }
        return current - previous
    }

    var controlRateDelta: Double? {
        guard let previous else { return nil }
        return current.completionRate - previous.completionRate
    }

    var aiContextLine: String {
        let unit = current.unit ?? ""
        var parts: [String] = []

        if signal.polarity == .negative {
            parts.append("\(habitName)：负向习惯")
            if let goalTitle {
                parts.append("关联目标「\(goalTitle)」")
            }
            if let totalValue = current.totalValue {
                parts.append("发生总量 \(format(totalValue))\(unit)")
            }
            if let targetValue = current.targetValue {
                parts.append("每日上限 \(format(targetValue))\(unit)")
            }
            if let overLimitDays = current.overLimitDays {
                parts.append("超标 \(overLimitDays) 天")
            }
            if let controlledDays = current.controlledDays {
                parts.append("控制 \(controlledDays)/\(current.totalDays) 天")
            }
            parts.append("控制率 \(formatPercent(current.completionRate))")
            if let totalValueDelta {
                parts.append(totalValueDelta > 0
                             ? "比上期增加 \(format(totalValueDelta))\(unit)"
                             : totalValueDelta < 0
                                ? "比上期减少 \(format(abs(totalValueDelta)))\(unit)"
                                : "发生总量与上期持平")
            }
            if let overLimitDaysDelta, overLimitDaysDelta != 0 {
                parts.append(overLimitDaysDelta > 0
                             ? "超标天数增加 \(overLimitDaysDelta) 天"
                             : "超标天数减少 \(abs(overLimitDaysDelta)) 天")
            }
            if currentStreak > 0 {
                parts.append("连续控制 \(currentStreak) 天")
            }
            if signal.needsClarification {
                parts.append("需要确认是否按坏习惯分析")
            }
            return parts.joined(separator: "，")
        }

        parts.append("\(habitName)：正向习惯")
        parts.append("完成率 \(formatPercent(current.completionRate))")
        if currentStreak > 0 {
            parts.append("连续 \(currentStreak) 天")
        }
        if signal.needsClarification {
            parts.append("名称含减少/戒除语义，建议确认是否为坏习惯")
        }
        return parts.joined(separator: "，")
    }

    private var negativeTrend: HabitFocusTrend {
        guard let previous else { return .unknown }

        if let totalValueDelta, totalValueDelta > 0 {
            return .worse
        }
        if let overLimitDaysDelta, overLimitDaysDelta > 0 {
            return .worse
        }
        if current.completionRate < previous.completionRate {
            return .worse
        }
        if let totalValueDelta, totalValueDelta < 0 {
            return .better
        }
        if let overLimitDaysDelta, overLimitDaysDelta < 0 {
            return .better
        }
        if current.completionRate > previous.completionRate {
            return .better
        }
        return .stable
    }

    private var positiveTrend: HabitFocusTrend {
        guard let previous else { return .unknown }
        if current.completionRate > previous.completionRate { return .better }
        if current.completionRate < previous.completionRate { return .worse }
        return .stable
    }

    private func format(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
