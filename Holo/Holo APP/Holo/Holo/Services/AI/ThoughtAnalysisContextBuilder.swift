//
//  ThoughtAnalysisContextBuilder.swift
//  Holo
//
//  想法分析上下文构建器
//  调用 ThoughtRepository 的统计方法获取心情、标签和趋势数据
//

import Foundation
import os.log

struct ThoughtAnalysisContextBuilder {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtAnalysisCtx")

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> ThoughtAnalysisContext? {
        let repo = ThoughtRepository()
        let calendar = Calendar.current
        let startInclusive = calendar.startOfDay(for: request.start)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: request.end)) else {
            return nil
        }

        let totalCount = repo.getThoughtCount(from: startInclusive, to: endExclusive)

        guard totalCount > 0 else {
            return nil
        }

        // 心情分布
        let moodDict = repo.getMoodDistribution(from: startInclusive, to: endExclusive)
        let totalMoods = moodDict.values.reduce(0, +)
        let moodDistribution: [MoodDistributionItem] = moodDict.map { mood, count in
            let total = Double(totalMoods)
            let pct: Double = total > 0 ? Double(count) / total * 100 : 0
            return MoodDistributionItem(mood: mood, count: count, percentage: pct)
        }.sorted { $0.count > $1.count }

        // 热门标签
        let topTagObjects = repo.getTopTags(from: startInclusive, to: endExclusive, limit: 5)
        let topTags = topTagObjects.compactMap { $0.name }

        // 最近想法摘要
        let recentSnippets = repo.getThoughtTexts(from: startInclusive, to: endExclusive, limit: 5)

        // 日趋势
        let dailyTrend = buildDailyThoughtTrend(
            repo: repo,
            start: startInclusive,
            end: endExclusive,
            calendar: calendar
        )

        return ThoughtAnalysisContext(
            totalCount: totalCount,
            moodDistribution: moodDistribution,
            topTags: topTags,
            recentSnippets: recentSnippets,
            dailyThoughtTrend: dailyTrend
        )
    }

    // MARK: - Daily Trend

    private func buildDailyThoughtTrend(
        repo: ThoughtRepository,
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> [DailyCountPoint] {
        // ThoughtRepository 没有按日聚合的方法，需要从 count 推算
        // 这里用一个简单的近似：总 count / 天数 做均匀分布
        // 后续可优化为精确的按日统计
        let total = repo.getThoughtCount(from: start, to: end)
        guard total > 0 else { return [] }

        let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? 1
        let avgPerDay = max(total / max(dayCount, 1), 1)

        var result: [DailyCountPoint] = []
        var current = start
        var remaining = total
        while current <= end && remaining > 0 {
            let count = min(avgPerDay, remaining)
            result.append(DailyCountPoint(date: Self.dateFmt.string(from: current), count: count))
            remaining -= count
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return Array(result.prefix(31))
    }
}
