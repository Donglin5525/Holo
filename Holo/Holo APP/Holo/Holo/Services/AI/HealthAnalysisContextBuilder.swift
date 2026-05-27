//
//  HealthAnalysisContextBuilder.swift
//  Holo
//
//  健康分析上下文构建器
//  通过 HealthKit 范围查询获取步数/睡眠/站立/活动数据
//

import Foundation
import os.log

struct HealthAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "HealthAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> HealthAnalysisContext? {
        let repo = HealthRepository.shared
        guard repo.isAuthorized else { return nil }

        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: request.start)
        let endDate = calendar.startOfDay(for: request.end)

        // 并发获取 4 个指标
        async let stepsData = repo.fetchStepsRange(from: startDate, to: endDate)
        async let sleepData = repo.fetchSleepRange(from: startDate, to: endDate)
        async let standData = repo.fetchStandTimeRange(from: startDate, to: endDate)
        async let activeData = repo.fetchActiveMinutesRange(from: startDate, to: endDate)

        let (steps, sleep, stand, active) = await (stepsData, sleepData, standData, activeData)

        let stepsAnalysis = buildMetricAnalysis(data: steps, goal: HealthMetricType.steps.dailyGoal)
        let sleepAnalysis = buildMetricAnalysis(data: sleep, goal: HealthMetricType.sleep.dailyGoal)
        let standAnalysis = buildMetricAnalysis(data: stand, goal: HealthMetricType.standHours.dailyGoal)
        let activeAnalysis = buildMetricAnalysis(data: active, goal: HealthMetricType.activeMinutes.dailyGoal)

        // 所有指标都没数据
        let allMetrics = [stepsAnalysis, sleepAnalysis, standAnalysis, activeAnalysis].compactMap { $0 }
        if allMetrics.isEmpty || allMetrics.allSatisfy(\.isDataFree) {
            return nil
        }

        // 体表分（3 槽位：步数 30%、睡眠 45%、站立或活动 25%）
        let bodyScore = calculateBodyScore(
            steps: stepsAnalysis,
            sleep: sleepAnalysis,
            stand: standAnalysis,
            active: activeAnalysis
        )

        // 上期体表分
        var previousScore: Double?
        if let compStart = request.comparisonStart, let compEnd = request.comparisonEnd {
            previousScore = await calculatePeriodScore(from: compStart, to: compEnd)
        }

        // 异常检测
        let anomalies = detectAnomalies(steps: steps, sleep: sleep, active: active)

        return HealthAnalysisContext(
            steps: stepsAnalysis,
            sleep: sleepAnalysis,
            stand: standAnalysis,
            activeMinutes: activeAnalysis,
            overallBodyScore: bodyScore,
            previousPeriodScore: previousScore,
            anomalyNotes: anomalies
        )
    }

    // MARK: - 指标分析构建

    private func buildMetricAnalysis(data: [DailyHealthData], goal: Double) -> HealthMetricAnalysis? {
        guard !data.isEmpty else { return nil }

        let totalValue = data.reduce(0) { $0 + $1.value }
        let totalDays = data.count
        let dailyAverage = totalDays > 0 ? totalValue / Double(totalDays) : 0
        let goalMetDays = data.filter { $0.value >= goal }.count

        // HealthKit 未返回该指标数据
        if totalValue == 0 && goalMetDays == 0 {
            return nil
        }

        let trend = data.suffix(31).map { point in
            DailyRatePoint(date: Self.dateFmt.string(from: point.date), rate: point.value)
        }

        let bestDay = data.max(by: { $0.value < $1.value }).map { point in
            DailyRatePoint(date: Self.dateFmt.string(from: point.date), rate: point.value)
        }

        return HealthMetricAnalysis(
            totalValue: totalValue,
            dailyAverage: dailyAverage,
            goalMetDays: goalMetDays,
            totalDays: totalDays,
            dailyTrend: trend,
            bestDay: bestDay
        )
    }

    // MARK: - 体表分（3 槽位模型）

    private func calculateBodyScore(
        steps: HealthMetricAnalysis?,
        sleep: HealthMetricAnalysis?,
        stand: HealthMetricAnalysis?,
        active: HealthMetricAnalysis?
    ) -> Double? {
        // stand 和 active 互斥取一
        let standOrActivity: (analysis: HealthMetricAnalysis?, goal: Double) = {
            if let stand = stand, !stand.isDataFree {
                return (stand, HealthMetricType.standHours.dailyGoal)
            }
            if let active = active, !active.isDataFree {
                return (active, HealthMetricType.activeMinutes.dailyGoal)
            }
            return (nil, 0)
        }()

        var weightedInputs: [(analysis: HealthMetricAnalysis, goal: Double, weight: Double)] = []
        if let s = steps, !s.isDataFree {
            weightedInputs.append((s, HealthMetricType.steps.dailyGoal, 0.30))
        }
        if let sl = sleep, !sl.isDataFree {
            weightedInputs.append((sl, HealthMetricType.sleep.dailyGoal, 0.45))
        }
        if let sa = standOrActivity.analysis {
            weightedInputs.append((sa, standOrActivity.goal, 0.25))
        }

        guard !weightedInputs.isEmpty else { return nil }

        let weightedScore = weightedInputs.reduce(0.0) { partial, item in
            let progress = min(item.analysis.dailyAverage / item.goal, 1.0)
            return partial + progress * item.weight * 100
        }
        let availableWeight = weightedInputs.reduce(0.0) { $0 + $1.weight }
        guard availableWeight > 0 else { return nil }

        return min(weightedScore / availableWeight, 100)
    }

    /// 计算指定日期范围的体表分
    @MainActor
    private func calculatePeriodScore(from start: Date, to end: Date) async -> Double? {
        let repo = HealthRepository.shared
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: start)
        let endDate = calendar.startOfDay(for: end)

        async let stepsData = repo.fetchStepsRange(from: startDate, to: endDate)
        async let sleepData = repo.fetchSleepRange(from: startDate, to: endDate)
        async let standData = repo.fetchStandTimeRange(from: startDate, to: endDate)
        async let activeData = repo.fetchActiveMinutesRange(from: startDate, to: endDate)

        let (steps, sleep, stand, active) = await (stepsData, sleepData, standData, activeData)

        return calculateBodyScore(
            steps: buildMetricAnalysis(data: steps, goal: HealthMetricType.steps.dailyGoal),
            sleep: buildMetricAnalysis(data: sleep, goal: HealthMetricType.sleep.dailyGoal),
            stand: buildMetricAnalysis(data: stand, goal: HealthMetricType.standHours.dailyGoal),
            active: buildMetricAnalysis(data: active, goal: HealthMetricType.activeMinutes.dailyGoal)
        )
    }

    // MARK: - 异常检测

    private func detectAnomalies(
        steps: [DailyHealthData],
        sleep: [DailyHealthData],
        active: [DailyHealthData]
    ) -> [String] {
        var anomalies: [String] = []

        // 连续 3 天睡眠 < 6h
        let lowSleep = consecutiveLowDays(data: sleep, threshold: 6.0)
        if lowSleep >= 3 {
            anomalies.append("连续 \(lowSleep) 天睡眠不足 6 小时")
        }

        // 连续 3 天步数 < 3000
        let lowSteps = consecutiveLowDays(data: steps, threshold: 3000)
        if lowSteps >= 3 {
            anomalies.append("连续 \(lowSteps) 天步数不足 3000")
        }

        // 活动分钟持续为 0
        let allZeroActive = !active.isEmpty && active.allSatisfy { $0.value == 0 }
        if allZeroActive {
            anomalies.append("活动分钟数持续为 0")
        }

        return anomalies
    }

    /// 计算连续低于阈值的最长天数
    private func consecutiveLowDays(data: [DailyHealthData], threshold: Double) -> Int {
        var maxStreak = 0
        var currentStreak = 0
        for point in data {
            if point.value < threshold {
                currentStreak += 1
                maxStreak = max(maxStreak, currentStreak)
            } else {
                currentStreak = 0
            }
        }
        return maxStreak
    }
}
