//
//  HoloFinanceTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.5 财务工具 MVP
//  计算晚间餐饮频次 / 分类集中度 / 金额变化，转为 Agent 证据。
//  依赖 HoloFinanceDataSource 协议而非真实 repository，便于测试注入；生产适配后续集成。
//

import Foundation

struct HoloFinanceBudgetSnapshot: Codable, Equatable, Sendable {
    var totalAmount: Double
    var spentAmount: Double
    var remainingAmount: Double
    var progress: Double
    var remainingDays: Int
    var warningCategoryNames: [String]
}

struct HoloFinanceAccountSnapshot: Codable, Equatable, Sendable {
    var activeAccountCount: Int
    var assets: Double
    var liabilities: Double
    var netWorth: Double
    var defaultAccountName: String?
}

/// FinanceTool 读取的财务快照（中性视图，已按周期聚合）。
struct HoloFinanceToolRecord: Codable, Equatable, Sendable {
    /// 当前周期晚间餐饮次数。
    var nighttimeMealCurrent: Int
    /// 基线周期晚间餐饮次数。
    var nighttimeMealBaseline: Int
    /// 当前周期各分类次数。
    var categoryCounts: [String: Int]
    /// 当前周期各分类支出金额。
    var categoryAmounts: [String: Double] = [:]
    /// 当前周期总金额。
    var totalCurrentAmount: Double
    /// 基线周期总金额。
    var totalBaselineAmount: Double
    /// 当前周期支出笔数。
    var transactionCount: Int = 0
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
    /// 当前周期金额最高的脱敏账单样例。
    var topExpenseExcerpts: [String] = []
    /// 当前月全局预算状态。
    var budget: HoloFinanceBudgetSnapshot? = nil
    /// 活跃账户与净资产摘要。
    var account: HoloFinanceAccountSnapshot? = nil
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
        description: "财务数据分析（支出拆解 / 趋势 / 关键词 / 预算 / 账户与净资产）",
        supportedQueries: ["spending_breakdown", "spending_pattern", "meal_time_distribution", "category_concentration", "keyword_trend", "budget_status", "account_summary"],
        supportedTimeRanges: [],
        outputMetrics: [
            "finance.total.amount",
            "finance.category.amount",
            "finance.transaction.sample",
            "finance.meal.nighttime_count",
            "finance.category.concentration",
            "finance.amount.change",
            "finance.keyword.count",
            "finance.keyword.amount",
            "finance.budget.total",
            "finance.budget.spent",
            "finance.budget.remaining",
            "finance.budget.progress",
            "finance.account.count",
            "finance.account.assets",
            "finance.account.liabilities",
            "finance.account.net_worth"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloFinanceDataSource

    init(dataSource: HoloFinanceDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        let supported = Set(descriptor.supportedQueries)
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
        case "spending_breakdown":
            return spendingBreakdownResult(request: request, record: record)
        case "meal_time_distribution":
            return mealTimeResult(request: request, record: record)
        case "category_concentration":
            return concentrationResult(request: request, record: record)
        case "spending_pattern":
            return spendingResult(request: request, record: record)
        case "keyword_trend":
            return keywordTrendResult(request: request, record: record)
        case "budget_status":
            return budgetStatusResult(request: request, record: record)
        case "account_summary":
            return accountSummaryResult(request: request, record: record)
        default:
            return Self.errorResult(request, reason: "不支持的查询：\(request.query)")
        }
    }

    // MARK: - 各 query 实现

    private func spendingBreakdownResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        let total = record.totalCurrentAmount
        guard total > 0 else {
            return Self.emptyResult(request)
        }

        let currentRange = record.currentRange ?? request.timeRange
        let transactionCountText = record.transactionCount > 0 ? "（\(record.transactionCount) 笔）" : ""
        var metrics = [
            HoloMetric(
                metricKey: "finance.total.amount",
                value: total,
                unit: "元",
                baselineValue: nil,
                comparison: nil
            )
        ]
        var events = [
            HoloEvidenceEvent(
                id: "\(request.id)-total",
                occurredAt: nil,
                metricKey: "finance.total.amount",
                metricValue: total,
                excerpt: "\(Self.rangeTitle(currentRange, fallback: "本期"))总支出：\(Self.moneyText(total)) 元\(transactionCountText)",
                timeRange: currentRange,
                baselineTimeRange: nil
            )
        ]

        let rankedCategories = record.categoryAmounts
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(5)

        for (index, item) in rankedCategories.enumerated() {
            let ratio = total > 0 ? item.value / total : 0
            metrics.append(
                HoloMetric(
                    metricKey: "finance.category.amount",
                    value: item.value,
                    unit: "元",
                    baselineValue: nil,
                    comparison: item.key
                )
            )
            events.append(
                HoloEvidenceEvent(
                    id: "\(request.id)-category-\(index + 1)",
                    occurredAt: nil,
                    metricKey: "finance.category.amount",
                    metricValue: item.value,
                    excerpt: "\(Self.rangeTitle(currentRange, fallback: "本期"))分类去向：\(item.key)：\(Self.moneyText(item.value)) 元（约 \(Self.percentText(ratio))）",
                    timeRange: currentRange,
                    baselineTimeRange: nil
                )
            )
        }

        for (index, sample) in record.topExpenseExcerpts.prefix(5).enumerated() {
            events.append(
                HoloEvidenceEvent(
                    id: "\(request.id)-sample-\(index + 1)",
                    occurredAt: nil,
                    metricKey: "finance.transaction.sample",
                    metricValue: nil,
                    excerpt: "\(Self.rangeTitle(currentRange, fallback: "本期"))大额支出样例：\(sample)",
                    timeRange: currentRange,
                    baselineTimeRange: nil
                )
            )
        }

        return Self.successResult(request, metrics: metrics, events: events)
    }

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

    private func budgetStatusResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        guard let budget = record.budget else { return Self.emptyResult(request) }
        let warningText = budget.warningCategoryNames.isEmpty
            ? ""
            : "；接近或超过预算：\(budget.warningCategoryNames.joined(separator: "、"))"
        let metrics = [
            HoloMetric(metricKey: "finance.budget.total", value: budget.totalAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.spent", value: budget.spentAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.remaining", value: budget.remainingAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.progress", value: budget.progress, unit: "比例", baselineValue: nil, comparison: nil)
        ]
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-budget",
            occurredAt: nil,
            metricKey: "finance.budget.remaining",
            metricValue: budget.remainingAmount,
            excerpt: "本月预算 \(Self.moneyText(budget.totalAmount)) 元，已用 \(Self.moneyText(budget.spentAmount)) 元，剩余 \(Self.moneyText(budget.remainingAmount)) 元，周期剩余 \(budget.remainingDays) 天\(warningText)"
        )]
        return Self.successResult(request, metrics: metrics, events: events)
    }

    private func accountSummaryResult(request: HoloToolRequest, record: HoloFinanceToolRecord) -> HoloDataToolResult {
        guard let account = record.account else { return Self.emptyResult(request) }
        let defaultText = account.defaultAccountName.map { "，默认账户：\($0)" } ?? ""
        let metrics = [
            HoloMetric(metricKey: "finance.account.count", value: Double(account.activeAccountCount), unit: "个", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.account.assets", value: account.assets, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.account.liabilities", value: account.liabilities, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.account.net_worth", value: account.netWorth, unit: "元", baselineValue: nil, comparison: nil)
        ]
        let events = [HoloEvidenceEvent(
            id: "\(request.id)-account",
            occurredAt: nil,
            metricKey: "finance.account.net_worth",
            metricValue: account.netWorth,
            excerpt: "活跃账户 \(account.activeAccountCount) 个，资产 \(Self.moneyText(account.assets)) 元，负债 \(Self.moneyText(account.liabilities)) 元，净资产 \(Self.moneyText(account.netWorth)) 元\(defaultText)"
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

    private static func rangeTitle(_ range: HoloAgentTimeRange?, fallback: String) -> String {
        guard let range, !range.label.isEmpty else { return fallback }
        return range.label
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

    private static func percentText(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
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
