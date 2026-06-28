//
//  HoloGoalToolTests.swift
//  HoloTests
//
//  Agent V3.1 — GoalTool 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloGoalTool.swift> <本测试> \
//    -o /tmp/holo_goal_tool_test && /tmp/holo_goal_tool_test
//

import Foundation

struct MockGoalDataSource: HoloGoalDataSource {
    let goals: [HoloGoalToolRecord]
    func activeGoals(timeRange: HoloAgentTimeRange?) async -> [HoloGoalToolRecord] { goals }
}

@main
struct HoloGoalToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test活跃目标摘要产出数量与每目标一条证据()
        try await test进度上下文计算关联任务完成率()
        try await test截止风险产出最近截止天数指标()
        try await test空目标列表返回empty()
        test不支持查询返回invalid()
        print("HoloGoalToolTests passed")
    }

    private static func makeRequest(query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "goal-1", tool: "goal", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func makeGoal(
        id: String, title: String, domain: String = "career",
        deadline: Date? = nil, desiredOutcome: String? = nil,
        linkedTasks: [HoloGoalLinkedTaskSnapshot] = [],
        linkedHabits: [HoloGoalLinkedHabitSnapshot] = []
    ) -> HoloGoalToolRecord {
        HoloGoalToolRecord(
            id: id, title: title, domain: domain, deadline: deadline,
            desiredOutcome: desiredOutcome, updatedAt: nil,
            linkedTasks: linkedTasks, linkedHabits: linkedHabits
        )
    }

    private static func test活跃目标摘要产出数量与每目标一条证据() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 27))!
        let deadline = calendar.date(byAdding: .day, value: 10, to: base)!
        let goals = [
            makeGoal(id: "g1", title: "学好 Swift", deadline: deadline, desiredOutcome: "能独立开发 App"),
            makeGoal(id: "g2", title: "跑步健身")
        ]
        let tool = HoloGoalTool(dataSource: MockGoalDataSource(goals: goals))

        let result = try await tool.execute(makeRequest(query: "active_goal_summary"))

        expect(result.status == .success, "active_goal_summary 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "goal.active.count" && $0.value == 2 }, "应统计活跃目标 2 个")
        expect(result.events.count == 2, "应为每个目标生成一条证据，实际 \(result.events.count)")
    }

    private static func test进度上下文计算关联任务完成率() async throws {
        let goal = makeGoal(
            id: "g1", title: "学好 Swift",
            linkedTasks: [
                HoloGoalLinkedTaskSnapshot(id: "t1", title: "看文档", completed: true, dueDate: nil),
                HoloGoalLinkedTaskSnapshot(id: "t2", title: "写 demo", completed: false, dueDate: nil),
                HoloGoalLinkedTaskSnapshot(id: "t3", title: "提交", completed: true, dueDate: nil)
            ],
            linkedHabits: [HoloGoalLinkedHabitSnapshot(id: "h1", name: "每日编码")]
        )
        let tool = HoloGoalTool(dataSource: MockGoalDataSource(goals: [goal]))

        let result = try await tool.execute(makeRequest(query: "goal_progress_context"))

        expect(result.status == .success, "goal_progress_context 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "goal.linked_task.completion_rate" && abs(($0.value ?? -1) - 0.67) < 0.01 }, "关联任务完成率应为 0.67")
        expect(result.metrics.contains { $0.metricKey == "goal.linked_habit.count" && $0.value == 1 }, "关联习惯数应为 1")
    }

    private static func test截止风险产出最近截止天数指标() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let near = calendar.date(byAdding: .day, value: 5, to: Date())!
        let goals = [makeGoal(id: "g1", title: "近期目标", deadline: near)]
        let tool = HoloGoalTool(dataSource: MockGoalDataSource(goals: goals))

        let result = try await tool.execute(makeRequest(query: "goal_deadline_risk"))

        expect(result.status == .success, "goal_deadline_risk 应成功，实际 \(result.status)")
        expect(result.metrics.contains { $0.metricKey == "goal.deadline.upcoming_days" }, "应产出 goal.deadline.upcoming_days 指标")
        expect(result.events.count == 1, "应为该截止目标生成一条证据，实际 \(result.events.count)")
    }

    private static func test空目标列表返回empty() async throws {
        let tool = HoloGoalTool(dataSource: MockGoalDataSource(goals: []))

        let result = try await tool.execute(makeRequest(query: "active_goal_summary"))

        expect(result.status == .empty, "空目标应返回 empty，实际 \(result.status)")
        expect(result.metrics.isEmpty, "empty 不应带 metrics")
        expect(result.events.isEmpty, "empty 不应带 events")
    }

    private static func test不支持查询返回invalid() {
        let tool = HoloGoalTool(dataSource: MockGoalDataSource(goals: []))
        let result = tool.validate(makeRequest(query: "unknown_query"))
        if case .invalid = result {
            return
        }
        fatalError("不支持查询应返回 .invalid，实际 \(result)")
    }
}
