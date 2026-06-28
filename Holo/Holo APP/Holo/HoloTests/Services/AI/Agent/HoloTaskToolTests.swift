//
//  HoloTaskToolTests.swift
//  HoloTests
//
//  Agent V3.1 — TaskTool 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloTaskTool.swift> <本测试> \
//    -o /tmp/holo_task_tool_test && /tmp/holo_task_tool_test
//

import Foundation

struct MockTaskDataSource: HoloTaskDataSource {
    let snapshot: HoloTaskToolSnapshot
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot { snapshot }
}

@main
struct HoloTaskToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test今日负载产出总数与完成指标()
        try await test积压风险产出逾期与积压指标()
        try await test完成趋势产出每日事件()
        try await test空任务返回empty()
        test不支持查询返回invalid()
        print("HoloTaskToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "task-1", tool: "task", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func makeRecord(id: String, title: String, priority: Int = 2, completed: Bool = false, dueDate: Date? = nil) -> HoloTaskToolRecord {
        HoloTaskToolRecord(id: id, title: title, descExcerpt: nil, priority: priority, dueDate: dueDate, plannedDate: nil, completed: completed)
    }

    private static func makeSnapshot(
        todayStats: HoloTodayTaskStats = HoloTodayTaskStats(dueToday: 0, completedToday: 0, overdue: 0),
        completionRate: Double = 0,
        activeBacklogCount: Int = 0,
        completionTrend: [HoloDailyTaskCount] = [],
        overdueTasks: [HoloTaskToolRecord] = [],
        recentTasks: [HoloTaskToolRecord] = [],
        unplannedTasks: [HoloTaskToolRecord] = []
    ) -> HoloTaskToolSnapshot {
        HoloTaskToolSnapshot(
            todayStats: todayStats, completionRate: completionRate, activeBacklogCount: activeBacklogCount,
            completionTrend: completionTrend, overdueTasks: overdueTasks, recentTasks: recentTasks, unplannedTasks: unplannedTasks
        )
    }

    private static func test今日负载产出总数与完成指标() async throws {
        let snapshot = makeSnapshot(
            todayStats: HoloTodayTaskStats(dueToday: 5, completedToday: 2, overdue: 1),
            overdueTasks: [makeRecord(id: "t1", title: "逾期任务", dueDate: Date())]
        )
        let tool = HoloTaskTool(dataSource: MockTaskDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "today_load"))

        expect(result.status == .success, "today_load 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "task.today.total" && $0.value == 5 }, "今日到期应为 5")
        expect(result.metrics.contains { $0.metricKey == "task.today.completed" && $0.value == 2 }, "今日完成应为 2")
        expect(result.metrics.contains { $0.metricKey == "task.overdue.count" && $0.value == 1 }, "逾期应为 1")
    }

    private static func test积压风险产出逾期与积压指标() async throws {
        let snapshot = makeSnapshot(
            activeBacklogCount: 3,
            overdueTasks: [makeRecord(id: "t1", title: "逾期一"), makeRecord(id: "t2", title: "逾期二")],
            unplannedTasks: [makeRecord(id: "t3", title: "无计划任务")]
        )
        let tool = HoloTaskTool(dataSource: MockTaskDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "backlog_risk"))

        expect(result.status == .success, "backlog_risk 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "task.overdue.count" && $0.value == 2 }, "逾期应为 2")
        expect(result.metrics.contains { $0.metricKey == "task.backlog.active_count" && $0.value == 3 }, "活跃积压应为 3")
        expect(result.events.count == 3, "应为逾期+无计划任务生成证据，实际 \(result.events.count)")
    }

    private static func test完成趋势产出每日事件() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 25))!
        let snapshot = makeSnapshot(
            completionRate: 0.5,
            completionTrend: [
                HoloDailyTaskCount(date: base, completedCount: 3),
                HoloDailyTaskCount(date: calendar.date(byAdding: .day, value: 1, to: base)!, completedCount: 5)
            ]
        )
        let tool = HoloTaskTool(dataSource: MockTaskDataSource(snapshot: snapshot))

        let result = try await tool.execute(makeRequest(query: "completion_trend"))

        expect(result.status == .success, "completion_trend 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "task.completion.rate" && abs(($0.value ?? -1) - 0.5) < 0.001 }, "完成率应为 0.5")
        expect(result.events.count == 2, "应为每天生成一条证据，实际 \(result.events.count)")
    }

    private static func test空任务返回empty() async throws {
        let tool = HoloTaskTool(dataSource: MockTaskDataSource(snapshot: makeSnapshot()))

        let result = try await tool.execute(makeRequest(query: "today_load"))

        expect(result.status == .empty, "空任务应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
    }

    private static func test不支持查询返回invalid() {
        let tool = HoloTaskTool(dataSource: MockTaskDataSource(snapshot: makeSnapshot()))
        let result = tool.validate(makeRequest(query: "unknown_query"))
        if case .invalid = result {
            return
        }
        fatalError("不支持查询应返回 .invalid，实际 \(result)")
    }
}
