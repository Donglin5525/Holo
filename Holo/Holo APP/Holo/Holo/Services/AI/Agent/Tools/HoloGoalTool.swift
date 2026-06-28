//
//  HoloGoalTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — GoalTool MVP
//  将活跃目标数据转为 Agent 可验证的指标和证据。
//  依赖仅限值类型与 HoloGoalDataSource 协议；Core Data 实体由生产 DataSource 在 MainActor 内转换。
//

import Foundation

// MARK: - Value Types

struct HoloGoalLinkedTaskSnapshot: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var completed: Bool
    var dueDate: Date?
}

struct HoloGoalLinkedHabitSnapshot: Codable, Equatable, Sendable {
    var id: String
    var name: String
}

struct HoloGoalToolRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var domain: String
    var deadline: Date?
    var desiredOutcome: String?
    var updatedAt: Date?
    var linkedTasks: [HoloGoalLinkedTaskSnapshot]
    var linkedHabits: [HoloGoalLinkedHabitSnapshot]
}

// MARK: - DataSource Protocol

protocol HoloGoalDataSource: Sendable {
    func activeGoals(timeRange: HoloAgentTimeRange?) async -> [HoloGoalToolRecord]
}

// MARK: - Tool

struct HoloGoalTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "goal",
        description: "目标数据分析（活跃目标 / 关联任务与习惯进度 / 截止风险）",
        supportedQueries: ["active_goal_summary", "goal_progress_context", "goal_deadline_risk"],
        supportedTimeRanges: ["recent", "7d", "14d", "30d"],
        outputMetrics: [
            "goal.active.count",
            "goal.deadline.upcoming_days",
            "goal.linked_task.completion_rate",
            "goal.linked_habit.count"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloGoalDataSource

    init(dataSource: HoloGoalDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的目标查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let goals = await dataSource.activeGoals(timeRange: request.timeRange)
        switch request.query {
        case "active_goal_summary":
            return Self.activeGoalSummary(request: request, goals: goals)
        case "goal_progress_context":
            return Self.progressContext(request: request, goals: goals)
        case "goal_deadline_risk":
            return Self.deadlineRisk(request: request, goals: goals)
        default:
            return Self.empty(
                request: request,
                warnings: [HoloToolWarning(code: "UNSUPPORTED_QUERY", message: "不支持的目标查询：\(request.query)")]
            )
        }
    }
}

// MARK: - Query Implementations

extension HoloGoalTool {

    /// active_goal_summary：活跃目标数量 + 每目标一条证据。
    private static func activeGoalSummary(request: HoloToolRequest, goals: [HoloGoalToolRecord]) -> HoloDataToolResult {
        guard !goals.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_GOAL_DATA", message: "没有可用的活跃目标")
            ])
        }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "goal.active.count", value: Double(goals.count), unit: "个", baselineValue: nil, comparison: nil)
        ]
        let events = goals.enumerated().map { index, goal in
            HoloEvidenceEvent(
                id: "goal-\(index)-\(goal.id)",
                occurredAt: goal.updatedAt,
                metricKey: "goal.active.count",
                metricValue: 1,
                excerpt: excerpt(for: goal)
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// goal_progress_context：关联任务完成率 + 关联习惯数。
    private static func progressContext(request: HoloToolRequest, goals: [HoloGoalToolRecord]) -> HoloDataToolResult {
        guard !goals.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_GOAL_DATA", message: "没有可用的活跃目标")
            ])
        }
        let allTasks = goals.flatMap { $0.linkedTasks }
        let completionRate: Double
        if allTasks.isEmpty {
            completionRate = 0
        } else {
            let completed = allTasks.filter { $0.completed }.count
            completionRate = Self.round(Double(completed) / Double(allTasks.count))
        }
        let habitCount = goals.reduce(0) { $0 + $1.linkedHabits.count }
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "goal.linked_task.completion_rate", value: completionRate, unit: nil, baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "goal.linked_habit.count", value: Double(habitCount), unit: "个", baselineValue: nil, comparison: nil)
        ]
        let events = goals.enumerated().map { index, goal in
            let taskDone = goal.linkedTasks.filter { $0.completed }.count
            let taskTotal = goal.linkedTasks.count
            return HoloEvidenceEvent(
                id: "goal-progress-\(index)-\(goal.id)",
                occurredAt: goal.updatedAt,
                metricKey: "goal.linked_task.completion_rate",
                metricValue: taskTotal > 0 ? Self.round(Double(taskDone) / Double(taskTotal)) : nil,
                excerpt: "目标「\(goal.title)」关联任务 \(taskDone)/\(taskTotal) 完成，习惯 \(goal.linkedHabits.count) 个"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: metrics, events: events, warnings: [], error: nil
        )
    }

    /// goal_deadline_risk：近期截止目标 + 最近截止天数。
    private static func deadlineRisk(request: HoloToolRequest, goals: [HoloGoalToolRecord]) -> HoloDataToolResult {
        guard !goals.isEmpty else {
            return empty(request: request, warnings: [
                HoloToolWarning(code: "NO_GOAL_DATA", message: "没有可用的活跃目标")
            ])
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let withDeadline = goals.compactMap { goal -> (goal: HoloGoalToolRecord, deadline: Date)? in
            guard let deadline = goal.deadline else { return nil }
            return (goal: goal, deadline: deadline)
        }.sorted { $0.deadline < $1.deadline }

        guard let nearest = withDeadline.first else {
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .success,
                coverage: nil,
                metrics: [HoloMetric(metricKey: "goal.deadline.upcoming_days", value: nil, unit: "天", baselineValue: nil, comparison: nil)],
                events: [],
                warnings: [HoloToolWarning(code: "NO_DEADLINE", message: "活跃目标均未设置截止日期")],
                error: nil
            )
        }

        let nearestDays = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: nearest.deadline)).day ?? 0
        let metrics: [HoloMetric] = [
            HoloMetric(metricKey: "goal.deadline.upcoming_days", value: Double(nearestDays), unit: "天", baselineValue: nil, comparison: nil)
        ]
        let events = withDeadline.enumerated().map { index, pair in
            let goalDays = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: pair.deadline)).day ?? 0
            return HoloEvidenceEvent(
                id: "goal-deadline-\(index)-\(pair.goal.id)",
                occurredAt: pair.deadline,
                metricKey: "goal.deadline.upcoming_days",
                metricValue: Double(goalDays),
                excerpt: "目标「\(pair.goal.title)」\(displayFormatter.string(from: pair.deadline)) 截止，剩 \(goalDays) 天"
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

    private static func excerpt(for goal: HoloGoalToolRecord) -> String {
        var parts: [String] = ["目标「\(goal.title)」", "领域：\(goal.domain)"]
        if let deadline = goal.deadline {
            parts.append("截止：\(displayFormatter.string(from: deadline))")
        }
        if let outcome = goal.desiredOutcome, !outcome.isEmpty {
            parts.append("期望：\(String(outcome.prefix(40)))")
        }
        return parts.joined(separator: "，")
    }

    private static func round(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
