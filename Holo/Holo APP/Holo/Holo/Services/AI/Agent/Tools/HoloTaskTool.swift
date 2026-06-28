//
//  HoloTaskTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — TaskTool MVP
//  将待办任务统计转为 Agent 可验证的指标和证据。
//  本文件零 Core Data 依赖：snapshot 只用 tool-local 值类型，
//  禁止引用 Repository 层的 TaskPeriodStats / DailyTaskCount（N1 约束）。
//  TodoTask -> HoloTaskToolRecord 的 init(task:) 放在生产 DataSource 文件。
//

import Foundation

// MARK: - Value Types (tool-local)

struct HoloTodayTaskStats: Codable, Equatable, Sendable {
    var dueToday: Int
    var completedToday: Int
    var overdue: Int
}

struct HoloDailyTaskCount: Codable, Equatable, Sendable {
    var date: Date
    var completedCount: Int
}

struct HoloTaskToolRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var descExcerpt: String?
    var priority: Int
    var dueDate: Date?
    var plannedDate: Date?
    var completed: Bool
}

struct HoloTaskToolSnapshot: Codable, Equatable, Sendable {
    var todayStats: HoloTodayTaskStats
    var completionRate: Double
    var activeBacklogCount: Int
    var completionTrend: [HoloDailyTaskCount]
    var overdueTasks: [HoloTaskToolRecord]
    var recentTasks: [HoloTaskToolRecord]
    var unplannedTasks: [HoloTaskToolRecord]
}

// MARK: - DataSource Protocol

protocol HoloTaskDataSource: Sendable {
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot
}

// MARK: - Tool

struct HoloTaskTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "task",
        description: "待办任务数据分析（今日负载 / 积压风险 / 完成趋势）",
        supportedQueries: ["today_load", "backlog_risk", "completion_trend"],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "task.today.total",
            "task.today.completed",
            "task.overdue.count",
            "task.backlog.active_count",
            "task.completion.rate"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloTaskDataSource

    init(dataSource: HoloTaskDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的任务查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let snapshot = await dataSource.snapshot(timeRange: request.timeRange)
        switch request.query {
        case "today_load":
            return Self.todayLoad(request: request, snapshot: snapshot)
        case "backlog_risk":
            return Self.backlogRisk(request: request, snapshot: snapshot)
        case "completion_trend":
            return Self.completionTrend(request: request, snapshot: snapshot)
        default:
            return Self.empty(
                request: request,
                warnings: [HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的任务查询：\(request.query)")]
            )
        }
    }
}

// MARK: - Query Implementations

extension HoloTaskTool {

    /// today_load：今日到期 / 完成 / 逾期 + 逾期任务证据。
    private static func todayLoad(request: HoloToolRequest, snapshot: HoloTaskToolSnapshot) -> HoloDataToolResult {
        let s = snapshot.todayStats
        let isEmpty = s.dueToday == 0 && s.completedToday == 0 && s.overdue == 0 && snapshot.overdueTasks.isEmpty
        if isEmpty {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_TASK_DATA", message: "没有今日任务数据")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "task.today.total", value: Double(s.dueToday), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "task.today.completed", value: Double(s.completedToday), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "task.overdue.count", value: Double(s.overdue), unit: "条", baselineValue: nil, comparison: nil)
        ]
        let events = snapshot.overdueTasks.enumerated().map { index, task in
            HoloEvidenceEvent(
                id: "task-today-\(index)-\(task.id)",
                occurredAt: task.dueDate,
                metricKey: "task.overdue.count",
                metricValue: 1,
                excerpt: excerpt(for: task)
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// backlog_risk：逾期 + 积压 + 无计划任务证据。
    private static func backlogRisk(request: HoloToolRequest, snapshot: HoloTaskToolSnapshot) -> HoloDataToolResult {
        let isEmpty = snapshot.overdueTasks.isEmpty
            && snapshot.unplannedTasks.isEmpty
            && snapshot.recentTasks.isEmpty
            && snapshot.activeBacklogCount == 0
        if isEmpty {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_TASK_DATA", message: "没有积压任务数据")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "task.overdue.count", value: Double(snapshot.overdueTasks.count), unit: "条", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "task.backlog.active_count", value: Double(snapshot.activeBacklogCount), unit: "条", baselineValue: nil, comparison: nil)
        ]
        var events = snapshot.overdueTasks.enumerated().map { index, task in
            HoloEvidenceEvent(
                id: "task-overdue-\(index)-\(task.id)",
                occurredAt: task.dueDate,
                metricKey: "task.overdue.count",
                metricValue: 1,
                excerpt: excerpt(for: task)
            )
        }
        events += snapshot.unplannedTasks.enumerated().map { index, task in
            HoloEvidenceEvent(
                id: "task-unplanned-\(index)-\(task.id)",
                occurredAt: task.plannedDate,
                metricKey: "task.backlog.active_count",
                metricValue: 1,
                excerpt: excerpt(for: task)
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// completion_trend：完成率 + 每日完成数证据。
    private static func completionTrend(request: HoloToolRequest, snapshot: HoloTaskToolSnapshot) -> HoloDataToolResult {
        if snapshot.completionTrend.isEmpty {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_TASK_DATA", message: "没有完成趋势数据")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "task.completion.rate", value: snapshot.completionRate, unit: nil, baselineValue: nil, comparison: nil)
        ]
        let events = snapshot.completionTrend.enumerated().map { index, item in
            HoloEvidenceEvent(
                id: "task-trend-\(index)",
                occurredAt: item.date,
                metricKey: "task.completion.rate",
                metricValue: Double(item.completedCount),
                excerpt: "\(displayFormatter.string(from: item.date)) 完成 \(item.completedCount) 条"
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

    private static func excerpt(for task: HoloTaskToolRecord) -> String {
        let status = task.completed ? "已完成" : "未完成"
        var parts: [String] = ["任务「\(task.title)」", status, "优先级 \(task.priority)"]
        if let due = task.dueDate {
            parts.append("截止 \(displayFormatter.string(from: due))")
        }
        return parts.joined(separator: "，")
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
