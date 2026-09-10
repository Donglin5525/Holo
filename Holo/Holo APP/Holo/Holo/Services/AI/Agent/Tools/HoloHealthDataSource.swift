//
//  HoloHealthDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — 生产健康数据源。
//  Agent 使用 [start, end)，HealthRepository 范围查询包含结束日，此处统一转换。
//

import Foundation

struct HoloDefaultHealthDataSource: HoloHealthDataSource {

    func dailyRecords(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> [HoloHealthDailyRecord] {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return [] }

        let repository = HealthRepository.shared
        let data: [DailyHealthData]
        switch metric {
        case .steps:
            data = await repository.fetchStepsRange(from: window.start, to: window.inclusiveEnd)
        case .sleep:
            data = await repository.fetchSleepRange(from: window.start, to: window.inclusiveEnd)
        case .stand:
            data = await repository.fetchStandTimeRange(from: window.start, to: window.inclusiveEnd)
        case .activity:
            data = await repository.fetchActiveMinutesRange(from: window.start, to: window.inclusiveEnd)
        }

        return data.map { HoloHealthDailyRecord(date: $0.date, value: $0.value) }
    }

    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord] {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return [] }

        let data = await HealthRepository.shared.fetchWorkoutsRange(
            from: window.start,
            to: window.inclusiveEnd
        )
        return data.map {
            HoloHealthWorkoutRecord(
                date: $0.date,
                totalMinutes: $0.totalMinutes,
                sessionCount: $0.sessionCount,
                topType: $0.topType
            )
        }
    }

    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloSleepRecord] {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return [] }
        return await HealthRepository.shared.fetchSleepDetailRange(from: window.start, to: window.inclusiveEnd).map {
            HoloSleepRecord(date: $0.date, totalHours: $0.totalHours, coreHours: $0.coreHours,
                            deepHours: $0.deepHours, remHours: $0.remHours, awakeHours: $0.awakeHours,
                            inBedHours: $0.inBedHours, bedtime: $0.bedtime, wakeTime: $0.wakeTime,
                            interruptionCount: $0.interruptionCount)
        }
    }

    func activityPatternRecords(timeRange: HoloAgentTimeRange?) async -> [HoloActivityPatternRecord] {
        switch await activityPatternRecordsStrict(timeRange: timeRange) {
        case .value(let records): return records
        case .noData, .waitingForUnlock, .unavailable: return []
        }
    }

    func energyRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] {
        switch await energyRecordsStrict(timeRange: timeRange) {
        case .value(let records): return records
        case .noData, .waitingForUnlock, .unavailable: return []
        }
    }

    func distanceRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] {
        switch await distanceRecordsStrict(timeRange: timeRange) {
        case .value(let records): return records
        case .noData, .waitingForUnlock, .unavailable: return []
        }
    }

    // MARK: - 严格查询（§7.1 P0-4：锁屏错误必须显式传播，不得伪装空数组/0）

    func dailyRecordsStrict(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        let repository = HealthRepository.shared
        let metricType: HealthMetricType
        switch metric {
        case .steps: metricType = .steps
        case .sleep: metricType = .sleep
        case .stand: metricType = .standHours
        case .activity: metricType = .activeMinutes
        }
        return await repository.fetchDailyRangeStrict(for: metricType, from: window.start, to: window.inclusiveEnd)
            .map { $0.map { HoloHealthDailyRecord(date: $0.date, value: $0.value) } }
    }

    func workoutRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthWorkoutRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        return await HealthRepository.shared.fetchWorkoutsRangeStrict(from: window.start, to: window.inclusiveEnd)
            .map { $0.map {
                HoloHealthWorkoutRecord(
                    date: $0.date,
                    totalMinutes: $0.totalMinutes,
                    sessionCount: $0.sessionCount,
                    topType: $0.topType
                )
            } }
    }

    func sleepRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloSleepRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        return await HealthRepository.shared.fetchSleepDetailRangeStrict(from: window.start, to: window.inclusiveEnd)
            .map { $0.map {
                HoloSleepRecord(date: $0.date, totalHours: $0.totalHours, coreHours: $0.coreHours,
                                deepHours: $0.deepHours, remHours: $0.remHours, awakeHours: $0.awakeHours,
                                inBedHours: $0.inBedHours, bedtime: $0.bedtime, wakeTime: $0.wakeTime,
                                interruptionCount: $0.interruptionCount,
                                remEpisodes: $0.remEpisodes,
                                remLatencyMinutes: $0.remLatencyMinutes,
                                deepFrontLoadPercent: $0.deepFrontLoadPercent,
                                sleepOnsetLatencyMinutes: $0.sleepOnsetLatencyMinutes)
            } }
    }

    // MARK: - 一期细粒度数据（活动节律 / 能量 / 距离）

    func activityPatternRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloActivityPatternRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        return await HealthRepository.shared.fetchHourlyStepsRangeStrict(from: window.start, to: window.inclusiveEnd)
            .map { days in
                days.compactMap { day -> HoloActivityPatternRecord? in
                    // 24 桶为单一事实源（分析器与卡片同样 prefix），边界多吐的桶不计入
                    let buckets = Array(day.hourly.prefix(24))
                    // 全天无步数样本的天不产出记录（不可得 ≠ 静坐一整天）
                    let total = buckets.reduce(0, +)
                    guard total > 0 else { return nil }
                    let features = ActivityDistributionAnalyzer.features(hourlySteps: buckets)
                    return HoloActivityPatternRecord(
                        date: day.date,
                        longestSedentaryMinutes: features.longestSedentaryMinutes,
                        activeWindowStartHour: features.activeWindowStartHour,
                        activeWindowEndHour: features.activeWindowEndHour,
                        eveningStepShare: features.eveningStepShare,
                        peakHour: features.peakHour,
                        totalSteps: total
                    )
                }
            }
    }

    func energyRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        return await HealthRepository.shared.fetchEnergyRangeStrict(from: window.start, to: window.inclusiveEnd)
            .map { $0.map { HoloHealthDailyRecord(date: $0.date, value: $0.value) } }
    }

    func distanceRecordsStrict(timeRange: HoloAgentTimeRange?) async -> HoloHealthQueryOutcome<[HoloHealthDailyRecord]> {
        let window = Self.repositoryWindow(for: timeRange)
        guard window.start <= window.inclusiveEnd else { return .noData }

        return await HealthRepository.shared.fetchDistanceRangeStrict(from: window.start, to: window.inclusiveEnd)
            .map { $0.map { HoloHealthDailyRecord(date: $0.date, value: $0.value) } }
    }

    private static func repositoryWindow(
        for timeRange: HoloAgentTimeRange?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, inclusiveEnd: Date) {
        let today = calendar.startOfDay(for: now)
        let defaultEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let historicalRange = HoloAgentHistoricalTimePolicy.resolve(
            timeRange,
            asOf: now,
            calendar: calendar
        )
        guard !historicalRange.isEntirelyFuture else {
            return (defaultEnd, today)
        }
        let effectiveRange = historicalRange.effectiveRange
        let exclusiveEnd = calendar.startOfDay(for: effectiveRange?.end ?? defaultEnd)
        let start = calendar.startOfDay(
            for: effectiveRange?.start ?? calendar.date(byAdding: .day, value: -13, to: today) ?? today
        )
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
        return (start, inclusiveEnd)
    }
}
