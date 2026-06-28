//
//  HoloHealthDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — 生产健康数据源
//  复用 HealthRepository 的睡眠范围查询，避免 Agent 直接依赖 HealthKit 细节。
//

import Foundation

struct HoloDefaultHealthDataSource: HoloHealthDataSource {

    func sleepRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthDailyRecord] {
        let calendar = Calendar.current
        let end = timeRange?.end ?? calendar.startOfDay(for: Date())
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: end) ?? end)
        let data = await HealthRepository.shared.fetchSleepRange(
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        )
        return data.map { HoloHealthDailyRecord(date: $0.date, value: $0.value) }
    }
}
