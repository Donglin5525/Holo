//
//  HoloPatternMiner.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.6 确定性 Pattern Miner
//  从工具结果的 metrics 提取趋势信号，只基于数值规则，不做自然语言人生判断。
//  每条 pattern 必须携带 evidenceIDs，severity 由变化幅度与目标冲突决定。
//

import Foundation

struct HoloPatternMiner {

    /// 遍历所有工具结果，按 metricKey 规则提取确定性信号。
    func mine(toolResults: [HoloDataToolResult], now: Date = Date()) -> [HoloPatternSignal] {
        var signals: [HoloPatternSignal] = []
        for result in toolResults {
            let evidenceIDs = result.events.map(\.id)
            for metric in result.metrics {
                if let signal = makeSignal(metric: metric, evidenceIDs: evidenceIDs, now: now) {
                    signals.append(signal)
                }
            }
        }
        return signals
    }

    // MARK: - 规则

    private func makeSignal(metric: HoloMetric, evidenceIDs: [String], now: Date) -> HoloPatternSignal? {
        let value = metric.value ?? 0
        switch metric.metricKey {
        case "habit.negative.frequency_change":
            // 仅在确有方向且非零变化时生成
            guard metric.comparison == "increasing" || metric.comparison == "decreasing", value != 0 else {
                return nil
            }
            let severity: HoloPatternSeverity = abs(value) >= 10 ? .high : (abs(value) >= 3 ? .medium : .low)
            return build(type: .frequencyChange, metric: metric, severity: severity,
                         evidenceIDs: evidenceIDs, now: now,
                         title: "负向习惯频率变化",
                         reason: "频率变化 \(formatValue(value))，方向 \(metric.comparison ?? "")")

        case "habit.negative.over_limit_days":
            guard value > 0 else { return nil }
            let severity: HoloPatternSeverity = value >= 3 ? .high : (value >= 1 ? .medium : .low)
            return build(type: .goalConflict, metric: metric, severity: severity,
                         evidenceIDs: evidenceIDs, now: now,
                         title: "负向习惯超出目标",
                         reason: "近 \(Int(value)) 天超出每日上限")

        case "finance.meal.nighttime_count":
            let baseline = metric.baselineValue ?? 0
            let diff = value - baseline
            // 差距不足 3 次视为不显著，不生成
            guard diff >= 3 else { return nil }
            let severity: HoloPatternSeverity = diff >= 3 ? .high : .medium
            return build(type: .timeDistributionShift, metric: metric, severity: severity,
                         evidenceIDs: evidenceIDs, now: now,
                         title: "晚间餐饮频次偏移",
                         reason: "本期 \(Int(value)) 次，基线 \(Int(baseline)) 次")

        default:
            return nil
        }
    }

    private func build(type: HoloPatternType, metric: HoloMetric, severity: HoloPatternSeverity,
                       evidenceIDs: [String], now: Date, title: String, reason: String) -> HoloPatternSignal {
        HoloPatternSignal(
            id: "\(type.rawValue)-\(metric.metricKey)",
            type: type, title: title, metricKey: metric.metricKey,
            value: metric.value, baselineValue: metric.baselineValue,
            severity: severity, evidenceIDs: evidenceIDs, reason: reason, generatedAt: now
        )
    }

    private func formatValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : "\(value)"
    }
}
