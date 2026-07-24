//
//  HoloFixedToolSemanticStandaloneTests.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P3 — 固定工具（finance/habit/task/health）类型化语义独立测试，
//  不依赖会触发 CloudKit 的 App 测试宿主。
//
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Models/AI/Agent/HoloEvidenceModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentToolModels.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloFinanceTool.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloHabitTool.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloTaskTool.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloHealthTool.swift" \
//    "Holo/Services/AI/Agent/Health/HoloStrictHealthQueryService.swift" \
//    "HoloTests/Services/AI/Agent/HoloFixedToolSemanticStandaloneTests.swift" \
//    -o /tmp/holo_fixed_tool_semantic_test && /tmp/holo_fixed_tool_semantic_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloFixedToolSemanticStandaloneTests.main()
    }
}
#endif

// MARK: - 测试数据源（独立命名，避免与其他 standalone 测试联合编译时重复）

private struct FixedSemanticFinanceDataSource: HoloFinanceDataSource {
    var record: HoloFinanceToolRecord?
    func snapshot(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloFinanceToolRecord? { record }
}

private struct FixedSemanticHabitDataSource: HoloHabitDataSource {
    var records: [HoloHabitToolRecord]
    func habits(timeRange: HoloAgentTimeRange?) async -> [HoloHabitToolRecord] { records }
}

private struct FixedSemanticTaskDataSource: HoloTaskDataSource {
    var value: HoloTaskToolSnapshot
    func snapshot(timeRange: HoloAgentTimeRange?) async -> HoloTaskToolSnapshot { value }
}

private struct FixedSemanticHealthDataSource: HoloHealthDataSource {
    var daily: [HoloHealthMetricKind: [HoloHealthDailyRecord]]
    func dailyRecords(
        for metric: HoloHealthMetricKind,
        timeRange: HoloAgentTimeRange?
    ) async -> [HoloHealthDailyRecord] { daily[metric] ?? [] }
    func workoutRecords(timeRange: HoloAgentTimeRange?) async -> [HoloHealthWorkoutRecord] { [] }
}

struct HoloFixedToolSemanticStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        await test四工具outputMetrics注册表闭集完整()
        try await test财务工具产出指标与分组事件语义()
        try await test习惯工具产出差值与每日计数语义()
        try await test任务工具产出计数与每日完成语义()
        try await test健康工具产出汇总与每日数据点语义()
        test工厂精确匹配与过滤规则()
        print("HoloFixedToolSemanticStandaloneTests passed")
    }

    // MARK: - a) 完整性不变量

    /// 四个固定工具 descriptor.outputMetrics 的每个 key 都必须在注册表有精确模板（无遗漏、无前缀匹配）。
    private static func test四工具outputMetrics注册表闭集完整() async {
        let tools: [(String, [String])] = [
            ("finance", HoloFinanceTool(dataSource: FixedSemanticFinanceDataSource(record: nil)).descriptor.outputMetrics),
            ("habit", HoloHabitTool(dataSource: FixedSemanticHabitDataSource(records: [])).descriptor.outputMetrics),
            ("task", HoloTaskTool(dataSource: FixedSemanticTaskDataSource(value: emptyTaskSnapshot())).descriptor.outputMetrics),
            ("health", HoloHealthTool(dataSource: FixedSemanticHealthDataSource(daily: [:])).descriptor.outputMetrics)
        ]
        for (tool, keys) in tools {
            expect(!keys.isEmpty, "\(tool) outputMetrics 不应为空")
            for key in keys {
                expect(
                    HoloMetricSemanticFactory.fixedMetricTemplates[key] != nil,
                    "\(tool) 固定指标 \(key) 缺少语义模板（精确匹配）"
                )
            }
        }
    }

    // MARK: - b) 财务

    private static func test财务工具产出指标与分组事件语义() async throws {
        // spending_breakdown：总额 + 分类分组
        var record = baseFinanceRecord()
        record.totalCurrentAmount = 1_000
        record.transactionCount = 5
        record.categoryAmounts = ["餐饮": 600, "交通": 400]
        let breakdown = try await HoloFinanceTool(dataSource: FixedSemanticFinanceDataSource(record: record))
            .execute(request("finance", "spending_breakdown"))
        expect(breakdown.status == .success, "spending_breakdown 应成功")
        expect(breakdown.metrics.allSatisfy { $0.semantic != nil }, "spending_breakdown 每个指标必须带 semantic")

        let total = breakdown.metrics.first { $0.metricKey == "finance.total.amount" }?.semantic
        expect(total?.domain == .finance && total?.dataset == "finance.transactions", "总支出 domain/dataset 错误")
        expect(total?.measure == .amount && total?.operation == .sum && total?.valueRole == .current, "总支出语义错误")
        expect(total?.dimension == nil && total?.groupLabel == nil, "总支出不应有分组")

        let categoryMetrics = breakdown.metrics.filter { $0.metricKey == "finance.category.amount" }
        expect(categoryMetrics.count == 2, "应有两个分类指标")
        let food = categoryMetrics.first { $0.semantic?.groupLabel == "餐饮" }?.semantic
        expect(food?.dimension == .category && food?.groupLabel == "餐饮", "分类指标 groupLabel 应为分类名")
        expect(food?.measure == .amount && food?.displayUnit == "元", "分类指标业务量/单位错误")

        // 分类事件必须带各自的分组语义（不能全部回退到第一个分类指标）
        let categoryEvents = breakdown.events.filter { $0.metricKey == "finance.category.amount" }
        expect(categoryEvents.count == 2, "应有两个分类事件")
        expect(categoryEvents.contains { $0.semantic?.groupLabel == "餐饮" }, "餐饮事件 groupLabel 错误")
        expect(categoryEvents.contains { $0.semantic?.groupLabel == "交通" }, "交通事件 groupLabel 错误")
        expect(categoryEvents.allSatisfy { $0.semantic?.dimension == .category }, "分类事件 dimension 应为 category")

        // spending_pattern：金额差值 → delta + direction
        var change = baseFinanceRecord()
        change.totalCurrentAmount = 5_248
        change.totalBaselineAmount = 4_000
        let spending = try await HoloFinanceTool(dataSource: FixedSemanticFinanceDataSource(record: change))
            .execute(request("finance", "spending_pattern"))
        let delta = spending.metrics.first { $0.metricKey == "finance.amount.change" }?.semantic
        expect(delta?.valueRole == .delta && delta?.operation == .difference, "amount.change 应为 delta/difference")
        expect(delta?.direction == .increase, "amount.change 方向应为 increase")
        expect(delta?.resultValue == 1_248, "delta resultValue 应为差值 1248，实际 \(String(describing: delta?.resultValue))")
        expect(delta?.currentValue == 5_248 && delta?.baselineValue == 4_000, "delta current/baseline 应可复算")
        expect(delta?.measure == .amount, "delta 业务量应为 amount")
    }

    // MARK: - c) 习惯

    private static func test习惯工具产出差值与每日计数语义() async throws {
        let negative = HoloHabitToolRecord(
            id: "h-neg", name: "熬夜", polarity: .negative, dailyGoal: 1,
            dailyCounts: [
                HoloHabitDailyCount(dayOffset: 2, count: 1),
                HoloHabitDailyCount(dayOffset: 1, count: 1),
                HoloHabitDailyCount(dayOffset: 0, count: 3)
            ]
        )
        let positive = HoloHabitToolRecord(
            id: "h-pos", name: "晨跑", polarity: .positive, dailyGoal: 1,
            dailyCounts: [
                HoloHabitDailyCount(dayOffset: 1, count: 1),
                HoloHabitDailyCount(dayOffset: 0, count: 0)
            ]
        )
        let tool = HoloHabitTool(dataSource: FixedSemanticHabitDataSource(records: [negative, positive]))

        let control = try await tool.execute(request("habit", "negative_habit_control"))
        expect(control.metrics.allSatisfy { $0.semantic != nil }, "negative_habit_control 每个指标必须带 semantic")
        let frequency = control.metrics.first { $0.metricKey == "habit.negative.frequency_change" }?.semantic
        expect(frequency?.dataset == "habit.daily" && frequency?.domain == .habit, "习惯 dataset/domain 错误")
        expect(frequency?.valueRole == .delta && frequency?.operation == .difference, "frequency_change 应为 delta")
        expect(frequency?.direction == .increase, "1→3 应为 increase")
        expect(frequency?.resultValue == 2 && frequency?.currentValue == 3 && frequency?.baselineValue == 1,
               "frequency_change 数值角色错误：\(String(describing: frequency))")
        expect(frequency?.measure == .count, "frequency_change 业务量应为 count")
        let controlRate = control.metrics.first { $0.metricKey == "habit.negative.control_rate" }?.semantic
        expect(controlRate?.measure == .ratio, "空单位控制率必须靠模板覆盖为 ratio")

        // 每日原始计数事件：语义是 current 次数，不得继承差值指标语义
        let dailyEvents = control.events.filter { $0.metricKey == "habit.negative.frequency_change" }
        expect(!dailyEvents.isEmpty, "应有每日计数事件")
        expect(dailyEvents.allSatisfy { $0.semantic?.valueRole == .current && $0.semantic?.measure == .count },
               "每日事件语义应为 current 次数")
        expect(dailyEvents.allSatisfy { $0.semantic?.resultValue == $0.metricValue },
               "每日事件语义数值必须与事件值一致")

        let trend = try await tool.execute(request("habit", "trend_summary"))
        let completion = trend.metrics.first { $0.metricKey == "habit.positive.completion_rate" }?.semantic
        expect(completion?.measure == .ratio && completion?.operation == .ratio, "完成率应为 ratio")
        let positiveEvents = trend.events.filter { $0.metricKey == "habit.positive.completion_rate" }
        expect(positiveEvents.allSatisfy { $0.semantic?.measure == .count && $0.semantic?.valueRole == .current },
               "正向习惯每日事件语义应为 current 次数，不得继承比率语义")
    }

    // MARK: - d) 任务

    private static func test任务工具产出计数与每日完成语义() async throws {
        let snapshot = HoloTaskToolSnapshot(
            todayStats: HoloTodayTaskStats(dueToday: 5, completedToday: 2, overdue: 1),
            completionRate: 0.5,
            activeBacklogCount: 3,
            completionTrend: [
                HoloDailyTaskCount(date: Date(timeIntervalSince1970: 86_400), completedCount: 2),
                HoloDailyTaskCount(date: Date(timeIntervalSince1970: 172_800), completedCount: 4)
            ],
            overdueTasks: [HoloTaskToolRecord(id: "t1", title: "还书", descExcerpt: nil, priority: 2,
                                              dueDate: Date(timeIntervalSince1970: 86_400), plannedDate: nil, completed: false)],
            recentTasks: [],
            unplannedTasks: []
        )
        let tool = HoloTaskTool(dataSource: FixedSemanticTaskDataSource(value: snapshot))

        let today = try await tool.execute(request("task", "today_load"))
        expect(today.metrics.allSatisfy { $0.semantic != nil }, "today_load 每个指标必须带 semantic")
        let total = today.metrics.first { $0.metricKey == "task.today.total" }?.semantic
        expect(total?.dataset == "task.daily" && total?.domain == .task, "任务 dataset/domain 错误")
        expect(total?.measure == .count && total?.operation == .count && total?.valueRole == .current, "今日任务语义错误")

        let trend = try await tool.execute(request("task", "completion_trend"))
        let rate = trend.metrics.first { $0.metricKey == "task.completion.rate" }?.semantic
        expect(rate?.measure == .ratio, "nil 单位完成率必须靠模板覆盖为 ratio")
        let dailyEvents = trend.events.filter { $0.metricKey == "task.completion.rate" }
        expect(dailyEvents.count == 2, "应有两条每日完成事件")
        expect(dailyEvents.allSatisfy { $0.semantic?.dimension == .day && $0.semantic?.groupLabel != nil },
               "每日完成事件应为 day 维度 + 日期标签")
        expect(dailyEvents.allSatisfy { $0.semantic?.measure == .count },
               "每日完成事件业务量应为 count（不是 ratio）")
    }

    // MARK: - e) 健康

    private static func test健康工具产出汇总与每日数据点语义() async throws {
        let days: [HoloHealthDailyRecord] = (0..<3).map {
            HoloHealthDailyRecord(date: Date(timeIntervalSince1970: 86_400 * Double($0 + 1)), value: 8_000 + Double($0) * 1_000)
        }
        let sleepDays: [HoloHealthDailyRecord] = (0..<3).map {
            HoloHealthDailyRecord(date: Date(timeIntervalSince1970: 86_400 * Double($0 + 1)), value: 7 + Double($0) * 0.5)
        }
        let tool = HoloHealthTool(dataSource: FixedSemanticHealthDataSource(daily: [
            .steps: days,
            .sleep: sleepDays
        ]))

        let steps = try await tool.execute(request("health", "steps_summary"))
        expect(steps.metrics.allSatisfy { $0.semantic != nil }, "steps_summary 每个指标必须带 semantic")
        let average = steps.metrics.first { $0.metricKey == "health.steps.average" }?.semantic
        expect(average?.dataset == "health.steps" && average?.measure == .steps, "平均步数 dataset/业务量错误")
        expect(average?.operation == .average && average?.valueRole == .current, "平均步数应为 average/current")
        // 每日数据点事件：day 维度 + 日期标签
        let dailyEvents = steps.events.filter { $0.metricKey == "health.steps.daily" }
        expect(dailyEvents.count == 3, "应有三条每日步数事件")
        expect(dailyEvents.allSatisfy { $0.semantic?.dimension == .day }, "每日步数事件应为 day 维度")
        expect(dailyEvents.allSatisfy { $0.semantic?.groupLabel?.isEmpty == false }, "每日步数事件应有日期分组标签")
        expect(dailyEvents.allSatisfy { $0.semantic?.measure == .steps && $0.semantic?.displayUnit == "步" },
               "每日步数事件业务量/单位错误")

        let sleep = try await tool.execute(request("health", "sleep_summary"))
        expect(sleep.metrics.allSatisfy { $0.semantic != nil }, "sleep_summary 每个指标必须带 semantic")
        let sleepAverage = sleep.metrics.first { $0.metricKey == "health.sleep.average_hours" }?.semantic
        expect(sleepAverage?.dataset == "health.sleep" && sleepAverage?.measure == .durationHours,
               "平均睡眠应为 health.sleep + durationHours")
        let nights = sleep.metrics.first { $0.metricKey == "health.sleep.recorded_nights" }?.semantic
        expect(nights?.measure == .nights, "记录晚数业务量应为 nights")
        let sleepDaily = sleep.events.filter { $0.metricKey == "health.sleep.hours" }
        expect(sleepDaily.allSatisfy { $0.semantic?.dimension == .day && $0.semantic?.measure == .durationHours },
               "每日睡眠事件应为 day 维度 + durationHours")
    }

    // MARK: - f) 工厂规则

    private static func test工厂精确匹配与过滤规则() {
        // 精确匹配：未知 key / 前缀猜测一律拒绝
        expect(HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "finance.total.amounts", value: 1, unit: "元", baselineValue: nil, comparison: nil
        ) == nil, "拼写相近的 key 不得命中")
        expect(HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "dynamic.finance_transactions.spend.all", value: 1, unit: "元", baselineValue: nil, comparison: nil
        ) == nil, "动态指标不得走固定注册表")

        // groupLabel 过滤："all"/"unknown"/空 → nil
        for excluded in ["all", "unknown", " ", "ALL"] {
            let semantic = HoloMetricSemanticFactory.fixedMetricSemantic(
                metricKey: "finance.category.amount", value: 1, unit: "元", baselineValue: nil, comparison: excluded
            )
            expect(semantic?.groupLabel == nil, "comparison=\(excluded) 应过滤为 nil groupLabel")
        }
        let labelled = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "finance.category.amount", value: 1, unit: "元", baselineValue: nil, comparison: "餐饮"
        )
        expect(labelled?.groupLabel == "餐饮", "正常分类名应保留为 groupLabel")

        // direction 解析：increasing/decreasing/stable → 枚举；其他串（如分类名）→ nil
        let up = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "habit.negative.frequency_change", value: 2, unit: "次", baselineValue: 1, comparison: "increasing"
        )
        expect(up?.direction == .increase && up?.currentValue == 3, "increasing 应解析为 increase，currentValue 复算")
        let flat = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "habit.negative.frequency_change", value: 0, unit: "次", baselineValue: 1, comparison: "stable"
        )
        expect(flat?.direction == .flat, "stable 应解析为 flat")
        let garbage = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "habit.negative.frequency_change", value: 2, unit: "次", baselineValue: 1, comparison: "餐饮"
        )
        expect(garbage?.direction == nil, "非方向串不得猜方向")

        // 空单位归一：displayUnit 为 nil，measure 可由模板覆盖
        let ratio = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "task.completion.rate", value: 0.5, unit: nil, baselineValue: nil, comparison: nil
        )
        expect(ratio?.measure == .ratio && ratio?.displayUnit == nil, "nil 单位完成率应为 ratio + nil displayUnit")
        let emptyUnit = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "habit.negative.control_rate", value: 0.8, unit: "", baselineValue: nil, comparison: nil
        )
        expect(emptyUnit?.measure == .ratio && emptyUnit?.displayUnit == nil, "空串单位控制率应为 ratio + nil displayUnit")

        // 分组标签方向互斥：分组指标的 comparison 不被误解析为方向
        let category = HoloMetricSemanticFactory.fixedMetricSemantic(
            metricKey: "finance.category.concentration", value: 0.4, unit: "", baselineValue: nil, comparison: "餐饮"
        )
        expect(category?.groupLabel == "餐饮" && category?.direction == nil && category?.valueRole == .share,
               "集中度应为 share + 分类 groupLabel，无方向")
    }

    // MARK: - 构造工具

    private static func request(_ tool: String, _ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "fixed-semantic-\(tool)-\(query)",
            tool: tool,
            query: query,
            timeRange: HoloAgentTimeRange(
                label: "最近一周",
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 604_800)
            ),
            baseline: nil,
            requiredMetrics: [],
            parameters: [:]
        )
    }

    private static func baseFinanceRecord() -> HoloFinanceToolRecord {
        HoloFinanceToolRecord(
            nighttimeMealCurrent: 0,
            nighttimeMealBaseline: 0,
            categoryCounts: [:],
            totalCurrentAmount: 0,
            totalBaselineAmount: 0
        )
    }

    private static func emptyTaskSnapshot() -> HoloTaskToolSnapshot {
        HoloTaskToolSnapshot(
            todayStats: HoloTodayTaskStats(dueToday: 0, completedToday: 0, overdue: 0),
            completionRate: 0,
            activeBacklogCount: 0,
            completionTrend: [],
            overdueTasks: [],
            recentTasks: [],
            unplannedTasks: []
        )
    }
}
