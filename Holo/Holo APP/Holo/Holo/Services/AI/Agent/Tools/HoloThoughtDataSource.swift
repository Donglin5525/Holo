//
//  HoloThoughtDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — 生产想法数据源
//  ThoughtRepository 非单例且默认绑定 viewContext，必须在 MainActor 内实例化与查询。
//  ThoughtTag 等实体在 MainActor.run 闭包内转为 String，绝不跨界。
//

import Foundation

struct HoloDefaultThoughtDataSource: HoloThoughtDataSource {

    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloThoughtToolSnapshot {
        let calendar = Calendar.current
        let end = timeRange?.end ?? Date()
        let start = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: end) ?? end)
        return await MainActor.run {
            let repo = ThoughtRepository()
            let topTags = repo.getTopTags(from: start, to: end, limit: 5).map(\.name)
            return HoloThoughtToolSnapshot(
                totalCount: repo.getThoughtCount(from: start, to: end),
                moodDistribution: repo.getMoodDistribution(from: start, to: end),
                topTags: topTags,
                snippets: repo.getThoughtTexts(from: start, to: end, limit: 5)
                    .map { String($0.prefix(120)) },
                dailyCounts: repo.getThoughtCountByDay(from: start, to: end)
            )
        }
    }
}
