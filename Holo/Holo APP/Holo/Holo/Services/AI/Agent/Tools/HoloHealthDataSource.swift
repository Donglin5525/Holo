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

    private static func repositoryWindow(
        for timeRange: HoloAgentTimeRange?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, inclusiveEnd: Date) {
        let today = calendar.startOfDay(for: now)
        let defaultEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let exclusiveEnd = calendar.startOfDay(for: timeRange?.end ?? defaultEnd)
        let start = calendar.startOfDay(
            for: timeRange?.start ?? calendar.date(byAdding: .day, value: -13, to: today) ?? today
        )
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
        return (start, inclusiveEnd)
    }
}
