//
//  HoloFinanceTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.5 财务工具 MVP
//  计算晚间餐饮频次 / 分类集中度 / 金额变化，转为 Agent 证据。
//  依赖 HoloFinanceDataSource 协议而非真实 repository，便于测试注入；生产适配后续集成。
//

import Foundation

/// 单个分类的预算对比明细（预算口径，按预算当前周期统计）。
/// 用于支撑"为什么超支 / 哪类超预算"的归因：对比每类"预算 vs 实际"。
struct HoloFinanceCategoryBudget: Codable, Equatable, Sendable {
    var categoryName: String
    var budgetAmount: Double
    var spentAmount: Double
    var remainingAmount: Double
    var progress: Double
    var isOverBudget: Bool
}

struct HoloFinanceBudgetSnapshot: Codable, Equatable, Sendable {
    /// 有效额度（严格预算模式 = 原始额度 − 上期超支结转）
    var totalAmount: Double
    var spentAmount: Double
    var remainingAmount: Double
    var progress: Double
    var remainingDays: Int
    /// 原始预算额度（与 totalAmount 相等 = 未开启严格模式或无结转）
    var originalAmount: Double = 0
    /// 严格预算模式：上期超支结转扣减额（0 = 未开启或无结转）
    var carryoverDeduction: Double = 0
    var warningCategoryNames: [String]
    /// 全量分类预算对比明细（不限于 progress >= 0.8 的预警分类）。
    /// 空表示用户未设置任何分类预算。
    var categoryBudgets: [HoloFinanceCategoryBudget] = []
}

struct HoloFinanceAccountSnapshot: Codable, Equatable, Sendable {
    var activeAccountCount: Int
    var assets: Double
    var liabilities: Double
    var netWorth: Double
    var defaultAccountName: String?
    /// 配置了账单周期的信用卡（账单日/还款日/额度），供「还款日几号/额度多少」类问题作答
    var creditCards: [HoloFinanceCreditCard] = []
}

struct HoloFinanceCreditCard: Codable, Equatable, Sendable {
    var name: String
    var billingDay: Int
    var dueDay: Int?
    var creditLimit: Double?
}

enum HoloFinanceBalanceExpenseSource: String, Codable, Equatable, Sendable {
    case manual
    case recurring
}

struct HoloFinanceBalanceEntry: Codable, Equatable, Sendable {
    var amount: Double
    var isIncome: Bool
    var expenseSource: HoloFinanceBalanceExpenseSource = .manual
    var categoryName: String
    var excerpt: String
}

struct HoloFinanceBalanceDiagnosis: Codable, Equatable, Sendable {
    var activeAccountCount: Int
    var openingBalance: Double
    var totalIncome: Double
    var totalExpense: Double
    var currentBalance: Double
    var manualExpense: Double
    var recurringExpense: Double
    var categoryAmounts: [String: Double]
    var topExpenseExcerpts: [String]
}

nonisolated enum HoloFinanceBalanceCalculator {
    static func calculate(
        activeAccountCount: Int,
        openingBalance: Double,
        entries: [HoloFinanceBalanceEntry]
    ) -> HoloFinanceBalanceDiagnosis {
        let incomeEntries = entries.filter(\.isIncome)
        let expenseEntries = entries.filter { !$0.isIncome }
        let totalIncome = incomeEntries.reduce(0) { $0 + $1.amount }
        let totalExpense = expenseEntries.reduce(0) { $0 + $1.amount }
        var categoryAmounts: [String: Double] = [:]
        for entry in expenseEntries {
            categoryAmounts[entry.categoryName, default: 0] += entry.amount
        }
        return HoloFinanceBalanceDiagnosis(
            activeAccountCount: activeAccountCount,
            openingBalance: openingBalance,
            totalIncome: totalIncome,
            totalExpense: totalExpense,
            currentBalance: openingBalance + totalIncome - totalExpense,
            manualExpense: expenseEntries.filter { $0.expenseSource == .manual }.reduce(0) { $0 + $1.amount },
            recurringExpense: expenseEntries.filter { $0.expenseSource == .recurring }.reduce(0) { $0 + $1.amount },
            categoryAmounts: categoryAmounts,
            topExpenseExcerpts: expenseEntries.sorted { $0.amount > $1.amount }.prefix(5).map(\.excerpt)
        )
    }
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
    func balanceDiagnosis() async -> HoloFinanceBalanceDiagnosis?
    func queryRows(timeRange: HoloAgentTimeRange?, parameters: [String: String]) async -> [HoloQueryRow]
}

extension HoloFinanceDataSource {
    func balanceDiagnosis() async -> HoloFinanceBalanceDiagnosis? { nil }
    func queryRows(timeRange: HoloAgentTimeRange?, parameters: [String: String]) async -> [HoloQueryRow] { [] }
}

/// 财务工具：把聚合后的财务快照转为可信指标与证据。
struct HoloFinanceTool: HoloDataTool {

    static let dynamicCatalog = HoloDataCatalog(datasets: [
        HoloDataSetSchema(
            name: "finance.transactions",
            domain: "finance",
            description: "收入与支出交易明细",
            label: "交易明细",
            timeField: "date",
            fields: [
                HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "交易日期", label: "日期"),
                HoloDataField(name: "amount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "交易金额", label: "金额"),
                HoloDataField(name: "type", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "expense 或 income", label: "收支方向"),
                HoloDataField(name: "category", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "交易分类", label: "分类"),
                HoloDataField(name: "account", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "账户名称", label: "账户"),
                HoloDataField(name: "text", type: .text, unit: nil, filterable: true, groupable: false, aggregatable: false, description: "备注、说明和标签合并文本", label: "商户备注")
            ],
            sensitivity: .normal,
            maximumRangeDays: 366
        )
    ])

    let descriptor = HoloToolDescriptor(
        name: "finance",
        description: "财务数据分析（支出拆解 / 余额归因 / 趋势 / 预算 / 账户与净资产）",
        supportedQueries: ["spending_breakdown", "balance_diagnosis", "spending_pattern", "meal_time_distribution", "category_concentration", "keyword_trend", "budget_status", "account_summary", "dynamic_query"],
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
            "finance.budget.category.spent",
            "finance.budget.category.remaining",
            "finance.budget.category.progress",
            "finance.account.count",
            "finance.account.assets",
            "finance.account.liabilities",
            "finance.account.net_worth",
            "finance.balance.current",
            "finance.balance.opening",
            "finance.balance.income_total",
            "finance.balance.expense_total",
            "finance.balance.expense.manual",
            "finance.balance.expense.recurring",
            "finance.balance.expense.category"
        ],
        sensitivityPolicy: "normal",
        dynamicCatalog: Self.dynamicCatalog
    )

    private let dataSource: HoloFinanceDataSource

    init(dataSource: HoloFinanceDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        if request.query == "dynamic_query" {
            guard let plan = request.dynamicPlan else { return .invalid(reason: "dynamic_query 缺少 dynamicPlan") }
            do {
                try HoloDynamicQueryValidator.validate(plan, catalog: Self.dynamicCatalog)
                guard plan.source == "finance.transactions" else { return .invalid(reason: "财务工具不能访问 \(plan.source)") }
                return .valid
            } catch { return .invalid(reason: error.localizedDescription) }
        }
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
        if request.query == "dynamic_query", let plan = request.dynamicPlan {
            return await dynamicResult(request, plan: plan)
        }
        if request.query == "balance_diagnosis" {
            guard let diagnosis = await dataSource.balanceDiagnosis() else {
                return HoloMetricSemanticFactory.attachFixedToolSemantics(to: Self.emptyResult(request))
            }
            return HoloMetricSemanticFactory.attachFixedToolSemantics(
                to: balanceDiagnosisResult(request: request, diagnosis: diagnosis)
            )
        }
        guard let record = await dataSource.snapshot(
            timeRange: request.timeRange,
            baseline: request.baseline,
            parameters: request.parameters
        ) else {
            return HoloMetricSemanticFactory.attachFixedToolSemantics(to: Self.emptyResult(request))
        }
        let result: HoloDataToolResult
        switch request.query {
        case "spending_breakdown":
            result = spendingBreakdownResult(request: request, record: record)
        case "meal_time_distribution":
            result = mealTimeResult(request: request, record: record)
        case "category_concentration":
            result = concentrationResult(request: request, record: record)
        case "spending_pattern":
            result = spendingResult(request: request, record: record)
        case "keyword_trend":
            result = keywordTrendResult(request: request, record: record)
        case "budget_status":
            result = budgetStatusResult(request: request, record: record)
        case "account_summary":
            result = accountSummaryResult(request: request, record: record)
        default:
            result = Self.errorResult(request, reason: "不支持的查询：\(request.query)")
        }
        // P3：固定指标统一挂类型化语义（动态链路 P1 已覆盖，不走这里）
        return HoloMetricSemanticFactory.attachFixedToolSemantics(to: result)
    }

    // MARK: - 各 query 实现

    private func dynamicResult(_ request: HoloToolRequest, plan: HoloDynamicQueryPlan) async -> HoloDataToolResult {
        var scopedPlan = plan
        let requestedRange = plan.timeRange ?? request.timeRange
        let resolvedRange = HoloAgentHistoricalTimePolicy.resolve(requestedRange)
        if resolvedRange.isEntirelyFuture {
            var result = Self.emptyResult(request)
            result.warnings = [
                HoloToolWarning(
                    code: "FUTURE_RANGE_NOT_HISTORICAL",
                    message: "所选范围尚未发生，未把未来分期计入历史财务统计"
                )
            ]
            return result
        }
        scopedPlan.timeRange = resolvedRange.effectiveRange
        let requestedBaseline = plan.baseline
            ?? request.baseline
            ?? HoloDynamicQueryRangeResolver.baselineIfNeeded(for: plan, currentRange: scopedPlan.timeRange)
        let resolvedBaseline = HoloAgentHistoricalTimePolicy.resolve(requestedBaseline)
        scopedPlan.baseline = resolvedBaseline.isEntirelyFuture ? nil : resolvedBaseline.effectiveRange
        let current = await dataSource.queryRows(timeRange: scopedPlan.timeRange, parameters: request.parameters)
        let baseline = await dataSource.queryRows(timeRange: scopedPlan.baseline, parameters: request.parameters)
        do {
            let output = try HoloDynamicQueryEngine.execute(
                plan: scopedPlan,
                catalog: Self.dynamicCatalog,
                currentRows: current,
                baselineRows: baseline
            )
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: output.metrics.isEmpty ? .empty : .success,
                coverage: output.coverage,
                metrics: output.metrics,
                events: output.events,
                warnings: [],
                error: nil,
                sensitivity: .normal
            )
        } catch {
            return Self.errorResult(request, reason: error.localizedDescription)
        }
    }

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
                    baselineTimeRange: nil,
                    // 构造期挂分组语义：分类名只在此处可知，事后无法从事件反推
                    semantic: HoloMetricSemanticFactory.fixedMetricSemantic(
                        metricKey: "finance.category.amount",
                        value: item.value,
                        unit: "元",
                        baselineValue: nil,
                        comparison: item.key
                    )
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
        let carryoverText = budget.carryoverDeduction > 0
            ? "，含上月超支结转扣减 \(Self.moneyText(budget.carryoverDeduction)) 元（原额度 \(Self.moneyText(budget.originalAmount)) 元）"
            : ""
        var metrics = [
            HoloMetric(metricKey: "finance.budget.total", value: budget.totalAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.spent", value: budget.spentAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.remaining", value: budget.remainingAmount, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.budget.progress", value: budget.progress, unit: "比例", baselineValue: nil, comparison: nil)
        ]
        if budget.carryoverDeduction > 0 {
            metrics.append(HoloMetric(metricKey: "finance.budget.carryover", value: budget.carryoverDeduction, unit: "元", baselineValue: budget.originalAmount, comparison: nil))
        }
        var events = [HoloEvidenceEvent(
            id: "\(request.id)-budget",
            occurredAt: nil,
            metricKey: "finance.budget.remaining",
            metricValue: budget.remainingAmount,
            excerpt: "本月预算 \(Self.moneyText(budget.totalAmount)) 元（有效额度）\(carryoverText)，已用 \(Self.moneyText(budget.spentAmount)) 元，剩余 \(Self.moneyText(budget.remainingAmount)) 元，周期剩余 \(budget.remainingDays) 天\(warningText)"
        )]

        // 分类预算对比：为每个分类产出 budget/spent/remaining/progress 四项指标。
        // 进度按 1.0=100% 记录（progress 直存原始比例），便于归因层按"超支/接近上限"排序。
        // 已花金额取预算周期口径（与预算对齐），不与 spending_breakdown 的近 14 天口径混用。
        let rankedCategoryBudgets = budget.categoryBudgets
            .sorted { lhs, rhs in
                if lhs.progress == rhs.progress { return lhs.spentAmount > rhs.spentAmount }
                return lhs.progress > rhs.progress
            }
        for (index, item) in rankedCategoryBudgets.enumerated() {
            let suffix = "\(index + 1)"
            metrics.append(HoloMetric(metricKey: "finance.budget.category.spent", value: item.spentAmount, unit: "元", baselineValue: item.budgetAmount, comparison: item.categoryName))
            metrics.append(HoloMetric(metricKey: "finance.budget.category.remaining", value: item.remainingAmount, unit: "元", baselineValue: nil, comparison: item.categoryName))
            metrics.append(HoloMetric(metricKey: "finance.budget.category.progress", value: item.progress, unit: "比例", baselineValue: nil, comparison: item.categoryName))

            let overText: String
            if item.isOverBudget {
                overText = "，已超预算"
            } else if item.progress >= 0.8 {
                overText = "，接近预算上限"
            } else {
                overText = ""
            }
            events.append(HoloEvidenceEvent(
                id: "\(request.id)-budget-category-\(suffix)",
                occurredAt: nil,
                metricKey: "finance.budget.category.progress",
                metricValue: item.progress,
                excerpt: "分类「\(item.categoryName)」预算 \(Self.moneyText(item.budgetAmount)) 元，已花 \(Self.moneyText(item.spentAmount)) 元（\(Self.percentText(item.progress))）\(overText)",
                semantic: HoloMetricSemanticFactory.fixedMetricSemantic(
                    metricKey: "finance.budget.category.spent",
                    value: item.spentAmount,
                    unit: "元",
                    baselineValue: item.budgetAmount,
                    comparison: item.categoryName
                )
            ))
        }
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
        )] + account.creditCards.map { card in
            var parts = ["信用卡「\(card.name)」", "账单日每月\(card.billingDay)号"]
            if let dueDay = card.dueDay { parts.append("还款日每月\(dueDay)号") }
            if let limit = card.creditLimit { parts.append("额度\(Self.moneyText(limit))元") }
            return HoloEvidenceEvent(
                id: "\(request.id)-card-\(card.name)",
                occurredAt: nil,
                metricKey: "finance.account.credit_card",
                metricValue: card.creditLimit,
                excerpt: parts.joined(separator: "，")
            )
        }
        return Self.successResult(request, metrics: metrics, events: events)
    }

    private func balanceDiagnosisResult(
        request: HoloToolRequest,
        diagnosis: HoloFinanceBalanceDiagnosis
    ) -> HoloDataToolResult {
        var metrics = [
            HoloMetric(metricKey: "finance.balance.current", value: diagnosis.currentBalance, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.balance.opening", value: diagnosis.openingBalance, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.balance.income_total", value: diagnosis.totalIncome, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.balance.expense_total", value: diagnosis.totalExpense, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.balance.expense.manual", value: diagnosis.manualExpense, unit: "元", baselineValue: nil, comparison: nil),
            HoloMetric(metricKey: "finance.balance.expense.recurring", value: diagnosis.recurringExpense, unit: "元", baselineValue: nil, comparison: nil)
        ]
        metrics += diagnosis.categoryAmounts
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { HoloMetric(metricKey: "finance.balance.expense.category", value: $0.value, unit: "元", baselineValue: nil, comparison: $0.key) }

        var events = [
            HoloEvidenceEvent(
                id: "\(request.id)-balance-formula",
                occurredAt: nil,
                metricKey: "finance.balance.current",
                metricValue: diagnosis.currentBalance,
                excerpt: "余额 = 活跃账户开户余额 \(Self.moneyText(diagnosis.openingBalance)) 元 + 已入账收入 \(Self.moneyText(diagnosis.totalIncome)) 元 - 已入账支出 \(Self.moneyText(diagnosis.totalExpense)) 元 = \(Self.moneyText(diagnosis.currentBalance)) 元。一次性购买项目不计入；周期项目只统计已经发生的流水。",
                formula: "opening_balance + posted_income - posted_expense"
            ),
            HoloEvidenceEvent(
                id: "\(request.id)-balance-sources",
                occurredAt: nil,
                metricKey: "finance.balance.expense_total",
                metricValue: diagnosis.totalExpense,
                excerpt: "已入账支出中，普通记账 \(Self.moneyText(diagnosis.manualExpense)) 元，已发生周期支出 \(Self.moneyText(diagnosis.recurringExpense)) 元"
            )
        ]
        for (index, metric) in metrics.filter({ $0.metricKey == "finance.balance.expense.category" }).enumerated() {
            events.append(HoloEvidenceEvent(
                id: "\(request.id)-balance-category-\(index)",
                occurredAt: nil,
                metricKey: metric.metricKey,
                metricValue: metric.value,
                excerpt: "累计支出分类「\(metric.comparison ?? "未分类")」\(Self.moneyText(metric.value ?? 0)) 元"
            ))
        }
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
