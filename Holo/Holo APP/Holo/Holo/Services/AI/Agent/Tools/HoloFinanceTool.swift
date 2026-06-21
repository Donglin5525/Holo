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
    /// 当前周期解析后的实际时间范围。
    var currentRange: HoloAgentTimeRange? = nil
    /// 基线周期解析后的实际时间范围。
    var baselineRange: HoloAgentTimeRange? = nil
    /// 关键词查询命中的原始词，如“咖啡”。
    var keyword: String? = nil
    /// 当前周期关键词命中的支出笔数。
    var keywordCurrentCount: Int = 0
    /// 基线周期关键词命中的支出笔数。
    var keywordBaselineCount: Int = 0
    /// 当前周期关键词命中的支出金额。
    var keywordCurrentAmount: Double = 0
    /// 基线周期关键词命中的支出金额。
    var keywordBaselineAmount: Double = 0
    /// 当前周期关键词命中的脱敏账单样例。
    var keywordSampleExcerpts: [String] = []
}

/// 财务数据源协议：返回 nil 表示无数据。生产实现适配真实 FinanceAnalysisContextBuilder（后续集成）。
protocol HoloFinanceDataSource: Sendable {
    func snapshot(
        timeRange: HoloAgentTimeRange?,
        baseline: HoloAgentTimeRange?,
        parameters: [String: String]
    ) async -> HoloFinanceToolRecord?
}

/// 财务工具：把聚合后的财务快照转为可信指标与证据。
struct HoloFinanceTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "finance",
        description: "财务数据分析（消费模式 / 餐饮时段 / 分类集中度 / 账单文本关键词趋势；keyword_trend 需传 parameters.keyword，如 咖啡、奶茶、星巴克）",
        supportedQueries: ["spending_pattern", "meal_time_distribution", "category_concentration", "keyword_trend"],
        supportedTimeRanges: [],
        outputMetrics: [
            "finance.meal.nighttime_count",
            "finance.category.concentration",
            "finance.amount.change",
            "finance.keyword.count",
            "finance.keyword.amount"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloFinanceDataSource

    init(dataSource: HoloFinanceDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        let supported: Set<String> = ["spending_pattern", "meal_time_distribution", "category_concentration", "keyword_trend"]
        guard supported.contains(request.query) else {
            return .invalid(reason: "不支持的查询：\(request.query)")
        }
        if request.query == "keyword_trend", Self.keyword(from: request).isEmpty {
            return .invalid(reason: "关键词趋势查询缺少 parameters.keyword")
        }
        return .valid
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        guard let record = await dataSource.snapshot(
            timeRange: request.timeRange,
            baseline: request.baseline,
            parameters: request.parameters
        ) else {
            return Self.emptyResult(request)
        }
        switch request.query {
        case "meal_time_distribution":
            return mealTimeResult(request: request, record: record)
        case "category_concentration":
            return concentrationResult(request: request, record: record)
        case "spending_pattern":
            return spendingResult(request: request, record: record)
        case "keyword_trend":
            return keywordTrendResult(request: request, record: record)
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
            excerpt: Self.excerpt(
                prefix: "晚间餐饮",
                currentText: "\(record.nighttimeMealCurrent) 次",
                baselineText: "\(record.nighttimeMealBaseline) 次",
                currentRange: record.currentRange ?? request.timeRange,
                baselineRange: record.baselineRange ?? request.baseline
            ),
            timeRange: record.currentRange ?? request.timeRange,
            baselineTimeRange: record.baselineRange ?? request.baseline
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
            excerpt: Self.excerpt(
                prefix: "最集中分类「\(top.key)」",
                currentText: "\(top.value)/\(total)",
                baselineText: nil,
                currentRange: record.currentRange ?? request.timeRange,
                baselineRange: nil
            ),
            timeRange: record.currentRange ?? request.timeRange,
            baselineTimeRange: nil
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
            excerpt: Self.excerpt(
                prefix: "消费金额",
                currentText: "\(Self.moneyText(current)) 元",
                baselineText: "\(Self.moneyText(baseline)) 元",
                currentRange: record.currentRange ?? request.timeRange,
                baselineRange: record.baselineRange ?? request.baseline
            ),
            timeRange: record.currentRange ?? request.timeRange,
            baselineTimeRange: record.baselineRange ?? request.baseline
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    private func keywordTrendResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        let keyword = record.keyword ?? Self.keyword(from: request)
        guard !keyword.isEmpty, record.keywordCurrentCount > 0 else {
            return Self.emptyResult(request)
        }
        let metrics = [
            HoloMetric(
                metricKey: "finance.keyword.count",
                value: Double(record.keywordCurrentCount),
                unit: "次",
                baselineValue: Double(record.keywordBaselineCount),
                comparison: Self.direction(Double(record.keywordCurrentCount), Double(record.keywordBaselineCount))
            ),
            HoloMetric(
                metricKey: "finance.keyword.amount",
                value: record.keywordCurrentAmount,
                unit: "元",
                baselineValue: record.keywordBaselineAmount,
                comparison: Self.direction(record.keywordCurrentAmount, record.keywordBaselineAmount)
            )
        ]
        let sampleText = record.keywordSampleExcerpts.isEmpty
            ? ""
            : "；样例：" + record.keywordSampleExcerpts.prefix(3).joined(separator: "、")
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-keyword-\(keyword)",
            occurredAt: nil,
            metricKey: "finance.keyword.count",
            metricValue: Double(record.keywordCurrentCount),
            excerpt: Self.excerpt(
                prefix: "账单文本命中「\(keyword)」",
                currentText: "\(record.keywordCurrentCount) 次 / \(Self.moneyText(record.keywordCurrentAmount)) 元",
                baselineText: "\(record.keywordBaselineCount) 次 / \(Self.moneyText(record.keywordBaselineAmount)) 元",
                currentRange: record.currentRange ?? request.timeRange,
                baselineRange: record.baselineRange ?? request.baseline
            ) + sampleText,
            timeRange: record.currentRange ?? request.timeRange,
            baselineTimeRange: record.baselineRange ?? request.baseline
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    // MARK: - 辅助

    private static func direction(_ current: Double, _ baseline: Double) -> String {
        current > baseline ? "increasing" : (current < baseline ? "decreasing" : "stable")
    }

    private static func excerpt(
        prefix: String,
        currentText: String,
        baselineText: String?,
        currentRange: HoloAgentTimeRange?,
        baselineRange: HoloAgentTimeRange?
    ) -> String {
        let currentLabel = rangeText(currentRange) ?? "本期"
        guard let baselineText else {
            return "\(prefix) \(currentLabel)：\(currentText)"
        }
        let baselineLabel = rangeText(baselineRange) ?? "基线"
        return "\(prefix) \(currentLabel)：\(currentText) / \(baselineLabel)：\(baselineText)"
    }

    private static func rangeText(_ range: HoloAgentTimeRange?) -> String? {
        guard let range else { return nil }
        if let start = range.start, let end = range.end {
            return "\(range.label)（\(dateText(start))-\(dateText(end.addingTimeInterval(-1)))）"
        }
        return range.label.isEmpty ? nil : range.label
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private static func moneyText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private static func keyword(from request: HoloToolRequest) -> String {
        (request.parameters["keyword"] ?? request.parameters["term"] ?? request.parameters["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
