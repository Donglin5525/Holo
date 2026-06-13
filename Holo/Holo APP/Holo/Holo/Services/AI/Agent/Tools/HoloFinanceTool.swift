//
//  HoloFinanceTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.5 财务工具 MVP
//  计算晚间餐饮频次 / 分类集中度 / 金额变化，转为 Agent 证据。
//  依赖 HoloFinanceDataSource 协议而非真实 repository，便于测试注入；生产适配后续集成。
//

import Foundation

/// FinanceTool 读取的财务快照（中性视图，已按周期聚合）。
struct HoloFinanceToolRecord: Codable, Equatable, Sendable {
    /// 当前周期晚间餐饮次数。
    var nighttimeMealCurrent: Int
    /// 基线周期晚间餐饮次数。
    var nighttimeMealBaseline: Int
    /// 当前周期各分类次数。
    var categoryCounts: [String: Int]
    /// 当前周期总金额。
    var totalCurrentAmount: Double
    /// 基线周期总金额。
    var totalBaselineAmount: Double
}

/// 财务数据源协议：返回 nil 表示无数据。生产实现适配真实 FinanceAnalysisContextBuilder（后续集成）。
protocol HoloFinanceDataSource: Sendable {
    func snapshot() async -> HoloFinanceToolRecord?
}

/// 财务工具：把聚合后的财务快照转为可信指标与证据。
struct HoloFinanceTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "finance",
        description: "财务数据分析（消费模式 / 餐饮时段 / 分类集中度）",
        supportedQueries: ["spending_pattern", "meal_time_distribution", "category_concentration"],
        supportedTimeRanges: [],
        outputMetrics: [
            "finance.meal.nighttime_count",
            "finance.category.concentration",
            "finance.amount.change"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloFinanceDataSource

    init(dataSource: HoloFinanceDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        let supported: Set<String> = ["spending_pattern", "meal_time_distribution", "category_concentration"]
        if supported.contains(request.query) { return .valid }
        return .invalid(reason: "不支持的查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        guard let record = await dataSource.snapshot() else {
            return Self.emptyResult(request)
        }
        switch request.query {
        case "meal_time_distribution":
            return mealTimeResult(request: request, record: record)
        case "category_concentration":
            return concentrationResult(request: request, record: record)
        case "spending_pattern":
            return spendingResult(request: request, record: record)
        default:
            return Self.errorResult(request, reason: "不支持的查询：\(request.query)")
        }
    }

    // MARK: - 各 query 实现

    private func mealTimeResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        let current = Double(record.nighttimeMealCurrent)
        let baseline = Double(record.nighttimeMealBaseline)
        let metrics = [HoloMetric(metricKey: "finance.meal.nighttime_count", value: current, unit: "次",
                                  baselineValue: baseline, comparison: Self.direction(current, baseline))]
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-night-meal", occurredAt: nil,
            metricKey: "finance.meal.nighttime_count", metricValue: current,
            excerpt: "晚间餐饮 本期 \(record.nighttimeMealCurrent) 次 / 基线 \(record.nighttimeMealBaseline) 次"
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    private func concentrationResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        let total = record.categoryCounts.values.reduce(0, +)
        guard total > 0, let top = record.categoryCounts.max(by: { $0.value < $1.value }) else {
            return Self.emptyResult(request)
        }
        let ratio = Double(top.value) / Double(total)
        let metrics = [HoloMetric(metricKey: "finance.category.concentration", value: ratio, unit: "",
                                  baselineValue: nil, comparison: top.key)]
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-top-category", occurredAt: nil,
            metricKey: "finance.category.concentration", metricValue: Double(top.value),
            excerpt: "最集中分类「\(top.key)」占 \(top.value)/\(total)"
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    private func spendingResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        let current = record.totalCurrentAmount
        let baseline = record.totalBaselineAmount
        let metrics = [HoloMetric(metricKey: "finance.amount.change", value: current - baseline, unit: "元",
                                  baselineValue: baseline, comparison: Self.direction(current, baseline))]
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-amount", occurredAt: nil,
            metricKey: "finance.amount.change", metricValue: current,
            excerpt: "消费金额 本期 \(current) 元 / 基线 \(baseline) 元"
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    // MARK: - 辅助

    private static func direction(_ current: Double, _ baseline: Double) -> String {
        current > baseline ? "increasing" : (current < baseline ? "decreasing" : "stable")
    }

    private static func successResult(_ request: HoloToolRequest,
                                      metrics: [HoloMetric], events: [HoloEvidenceEvent]) -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
                           coverage: nil, metrics: metrics, events: events, warnings: [], error: nil)
    }

    private static func emptyResult(_ request: HoloToolRequest) -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .empty,
                           coverage: nil, metrics: [], events: [], warnings: [], error: nil)
    }

    private static func errorResult(_ request: HoloToolRequest, reason: String) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .error,
            coverage: nil, metrics: [], events: [], warnings: [],
            error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: reason, recoverable: true)
        )
    }
}
