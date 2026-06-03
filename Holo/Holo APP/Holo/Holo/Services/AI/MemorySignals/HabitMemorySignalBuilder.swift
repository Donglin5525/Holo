//
//  HabitMemorySignalBuilder.swift
//  Holo
//
//  从习惯数据生成记忆信号（纯规则，不涉及 LLM）
//

import Foundation

struct HabitMemorySignalBuilder {

    /// 从习惯表现数据生成记忆信号
    /// - Parameter summaries: 习惯关注摘要（由上层从 HabitRepository 获取并计算）
    /// - Returns: 高密度信号列表（confidence > 0.4）
    static func buildSignals(from summaries: [HabitFocusSummary]) -> [HoloMemorySignal] {
        var signals: [HoloMemorySignal] = []

        for summary in summaries {
            let polarity = summary.signal.polarity

            if polarity == .negative {
                // 坏习惯信号
                signals.append(contentsOf: buildNegativeHabitSignals(summary))
            } else {
                // 好习惯信号
                signals.append(contentsOf: buildPositiveHabitSignals(summary))
            }
        }

        // 只保留 confidence > 0.4
        return signals.filter { $0.confidence > 0.4 }
    }

    // MARK: - Negative Habit Signals

    private static func buildNegativeHabitSignals(_ summary: HabitFocusSummary) -> [HoloMemorySignal] {
        var signals: [HoloMemorySignal] = []
        let name = summary.habitName
        let snapshot = summary.current
        let now = Date()

        // 触发条件 1：坏习惯 7 天内超标 ≥ 3 天
        if let overLimitDays = snapshot.overLimitDays, overLimitDays >= 3 {
            let confidence = min(0.7 + Double(overLimitDays - 3) * 0.05, 0.95)
            signals.append(HoloMemorySignal(
                id: "habit-neg-overlimit-\(name)-\(Int(now.timeIntervalSince1970))",
                title: "\(name)习惯控制不稳定",
                detail: "最近 \(snapshot.totalDays) 天中有 \(overLimitDays) 天超标"
                    + (snapshot.totalValue != nil ? "，总计 \(String(format: "%.1f", snapshot.totalValue!))\(snapshot.unit ?? "")" : ""),
                polarity: .negative,
                confidence: confidence,
                sourceModule: .habits,
                evidenceRefs: ["habit:\(name):overLimitDays:\(overLimitDays)"],
                generatedAt: now
            ))
        }

        // 触发条件 4：坏习惯控制率提升 ≥ 20%
        if let delta = summary.controlRateDelta, delta >= 0.2 {
            signals.append(HoloMemorySignal(
                id: "habit-neg-improve-\(name)-\(Int(now.timeIntervalSince1970))",
                title: "\(name)习惯控制改善",
                detail: "控制率从 \(String(format: "%.0f%%", (snapshot.completionRate - delta) * 100)) 提升至 \(String(format: "%.0f%%", snapshot.completionRate * 100))",
                polarity: .positive,
                confidence: min(0.6 + delta, 0.9),
                sourceModule: .habits,
                evidenceRefs: ["habit:\(name):controlRate:\(String(format: "%.2f", snapshot.completionRate))"],
                generatedAt: now
            ))
        }

        return signals
    }

    // MARK: - Positive Habit Signals

    private static func buildPositiveHabitSignals(_ summary: HabitFocusSummary) -> [HoloMemorySignal] {
        var signals: [HoloMemorySignal] = []
        let name = summary.habitName
        let snapshot = summary.current
        let now = Date()

        // 触发条件 2：好习惯连续中断 ≥ 5 天（通过低完成率推断）
        // 中断天数 = 总天数 - 完成天数
        let missedDays = snapshot.totalDays - snapshot.completedDays
        if missedDays >= 5 {
            signals.append(HoloMemorySignal(
                id: "habit-pos-missed-\(name)-\(Int(now.timeIntervalSince1970))",
                title: "\(name)习惯近期中断",
                detail: "最近 \(snapshot.totalDays) 天中有 \(missedDays) 天未完成",
                polarity: .negative,
                confidence: min(0.6 + Double(missedDays - 5) * 0.05, 0.9),
                sourceModule: .habits,
                evidenceRefs: ["habit:\(name):missedDays:\(missedDays)"],
                generatedAt: now
            ))
        }

        // 触发条件 3：好习惯连续完成 ≥ 7 天
        if summary.currentStreak >= 7 {
            signals.append(HoloMemorySignal(
                id: "habit-pos-streak-\(name)-\(Int(now.timeIntervalSince1970))",
                title: "\(name)习惯连续保持",
                detail: "已连续完成 \(summary.currentStreak) 天，完成率 \(String(format: "%.0f%%", snapshot.completionRate * 100))",
                polarity: .positive,
                confidence: min(0.5 + Double(summary.currentStreak - 7) * 0.02, 0.85),
                sourceModule: .habits,
                evidenceRefs: ["habit:\(name):streak:\(summary.currentStreak)"],
                generatedAt: now
            ))
        }

        return signals
    }
}
