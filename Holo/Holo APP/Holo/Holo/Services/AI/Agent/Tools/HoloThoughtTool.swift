//
//  HoloThoughtTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — ThoughtTool MVP
//  将想法与情绪统计转为 Agent 可验证的指标和证据。
//  原文仅以短摘录形式出现，避免把完整私密内容灌给模型。
//

import Foundation

// MARK: - Value Types

struct HoloThoughtToolSnapshot: Codable, Equatable, Sendable {
    var totalCount: Int
    var moodDistribution: [String: Int]
    var topTags: [String]
    var snippets: [String]
    var dailyCounts: [String: Int]
}

// MARK: - DataSource Protocol

protocol HoloThoughtDataSource: Sendable {
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloThoughtToolSnapshot
}

// MARK: - Tool

struct HoloThoughtTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "thought",
        description: "想法与情绪数据分析（心情分布 / 主题摘要 / 活跃趋势）",
        supportedQueries: ["mood_summary", "thought_theme_summary", "thought_activity_trend"],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "thought.count.total",
            "thought.mood.count",
            "thought.activity.daily_count"
        ],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloThoughtDataSource

    init(dataSource: HoloThoughtDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的想法查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let snapshot = await dataSource.snapshot(timeRange: request.timeRange)
        switch request.query {
        case "mood_summary":
            return Self.moodSummary(request: request, snapshot: snapshot)
        case "thought_theme_summary":
            return Self.themeSummary(request: request, snapshot: snapshot)
        case "thought_activity_trend":
            return Self.activityTrend(request: request, snapshot: snapshot)
        default:
            return Self.empty(
                request: request,
                warnings: [HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的想法查询：\(request.query)")]
            )
        }
    }
}

// MARK: - Query Implementations

extension HoloThoughtTool {

    /// mood_summary：想法总数 + 心情分布。
    private static func moodSummary(request: HoloToolRequest, snapshot: HoloThoughtToolSnapshot) -> HoloDataToolResult {
        guard snapshot.totalCount > 0 else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_THOUGHT_DATA", message: "没有可用的想法数据")
            ])
        }
        let moodCount = snapshot.moodDistribution.values.reduce(0, +)
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "thought.count.total", value: Double(snapshot.totalCount), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "thought.mood.count", value: Double(moodCount), unit: "条", baselineValue: nil, comparison: nil)
        ]
        let events = snapshot.moodDistribution.sorted { $0.key < $1.key }.map { (mood, count) in
            HoloEvidenceEvent(
                id: "thought-mood-\(mood)",
                occurredAt: nil,
                metricKey: "thought.mood.count",
                metricValue: Double(count),
                excerpt: "心情「\(mood)」出现 \(count) 次"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// thought_theme_summary：热门标签 + 脱敏摘录（只描述出现的内容，不下心理判断）。
    private static func themeSummary(request: HoloToolRequest, snapshot: HoloThoughtToolSnapshot) -> HoloDataToolResult {
        guard snapshot.totalCount > 0 else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_THOUGHT_DATA", message: "没有可用的想法数据")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "thought.count.total", value: Double(snapshot.totalCount), unit: "条", baselineValue: nil, comparison: nil)
        ]
        var events: [HoloEvidenceEvent] = snapshot.topTags.enumerated().map { index, tag in
            HoloEvidenceEvent(
                id: "thought-tag-\(index)-\(tag)",
                occurredAt: nil,
                metricKey: nil,
                metricValue: nil,
                excerpt: "热门标签：\(tag)"
            )
        }
        events += snapshot.snippets.enumerated().map { index, snippet in
            HoloEvidenceEvent(
                id: "thought-snippet-\(index)",
                occurredAt: nil,
                metricKey: nil,
                metricValue: nil,
                excerpt: "最近想法出现：\(snippet)"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// thought_activity_trend：按天想法数量趋势。
    private static func activityTrend(request: HoloToolRequest, snapshot: HoloThoughtToolSnapshot) -> HoloDataToolResult {
        guard snapshot.totalCount > 0, !snapshot.dailyCounts.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_THOUGHT_DATA", message: "没有可用的想法数据")
            ])
        }
        let dailyMax = snapshot.dailyCounts.values.max() ?? 0
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "thought.count.total", value: Double(snapshot.totalCount), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "thought.activity.daily_count", value: Double(dailyMax), unit: "条", baselineValue: nil, comparison: nil)
        ]
        let events = snapshot.dailyCounts.sorted(by: { $0.key < $1.key }).map { (day, count) in
            HoloEvidenceEvent(
                id: "thought-day-\(day)",
                occurredAt: nil,
                metricKey: "thought.activity.daily_count",
                metricValue: Double(count),
                excerpt: "\(day) 记录 \(count) 条想法"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    // MARK: - Helpers

    private static func empty(request: HoloToolRequest, warnings: [HoloToolWarning]) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .empty,
            coverage: nil, metrics: [], events: [], warnings: warnings, error: nil
        )
    }
}
