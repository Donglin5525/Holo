//
//  GoalHealthResultSeries.swift
//  Holo
//
//  苹果健康类目标的结果周序列（2026-11-20 报告改版 E 期）：
//  只对体重 / 体脂这类「达标型」指标，按周取该周最后一次有效观测，最多 8 周。
//  上云的只有「周起始日标签 + 数值」这一列聚合点，不传原始样本、不传时间戳明细；
//  后端 goalComponents.js 据此画趋势图、算完成预测（snapshot.goalResultSeries.points）。
//

import Foundation

struct GoalResultSeriesWire: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let label: String
        let value: Double
    }
    let points: [Point]
}

@MainActor
enum GoalHealthResultSeries {
    static let maxWeeks = 8

    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// 目标回顾快照用：非健康目标 / 非达标型指标 / 不足 2 个点返回 nil
    static func weekly(for review: GoalEvaluationSnapshot, now: Date = Date(),
                       calendar: Calendar = .current) async -> GoalResultSeriesWire? {
        guard review.result.sourceKind == .healthKit,
              let goal = GoalRepository.shared.findGoal(by: review.goalID),
              let kind = goal.healthMetricKindEnum,
              kind == .bodyMass || kind == .bodyFatPercentage else { return nil }
        let goalStart = calendar.startOfDay(for: goal.baselineDate ?? goal.createdAt)
        let today = calendar.startOfDay(for: now)
        var points: [GoalResultSeriesWire.Point] = []
        for weekOffset in stride(from: maxWeeks - 1, through: 0, by: -1) {
            guard let weekEnd = calendar.date(byAdding: .day, value: 1 - weekOffset * 7, to: today),
                  let weekStart = calendar.date(byAdding: .day, value: -7, to: weekEnd),
                  weekEnd > goalStart else { continue }
            let since = max(weekStart, goalStart)
            if case .value(let sample) = await HealthRepository.shared.fetchGoalMetric(kind: kind, since: since, before: min(weekEnd, now)),
               sample.value.isFinite, sample.value > 0 {
                points.append(.init(label: labelFormatter.string(from: weekStart), value: (sample.value * 10).rounded() / 10))
            }
        }
        return points.count >= 2 ? GoalResultSeriesWire(points: points) : nil
    }
}
