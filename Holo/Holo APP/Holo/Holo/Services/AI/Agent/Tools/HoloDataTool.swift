//
//  HoloDataTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.2 本地数据工具协议
//  Agent 通过实现此协议的工具读取用户数据（记账/习惯/健康等），产出可信证据。
//

import Foundation

nonisolated enum HoloAgentDynamicQueryFlags {
    private static let key = "holo_agent_dynamicQueryEnabled"
    static var enabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: key) as? Bool { return stored }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 本地数据工具协议：所有可被 Agent 调用的工具统一形态。
nonisolated protocol HoloDataTool: Sendable {
    var descriptor: HoloToolDescriptor { get }
    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult
    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult
}

/// 工具自描述：名称、能力、敏感度策略，用于注册中心汇总为 Prompt。
nonisolated struct HoloToolDescriptor: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var supportedQueries: [String]
    var supportedTimeRanges: [String]
    var outputMetrics: [String]
    var sensitivityPolicy: String
    var dynamicCatalog: HoloDataCatalog? = nil
}

// MARK: - 动态查询目录与安全 DSL

nonisolated enum HoloDataFieldType: String, Codable, Sendable { case number, text, date, boolean }

nonisolated struct HoloDataField: Codable, Equatable, Sendable {
    var name: String
    var type: HoloDataFieldType
    var unit: String?
    var filterable: Bool
    var groupable: Bool
    var aggregatable: Bool
    var description: String
}

nonisolated struct HoloDataSetSchema: Codable, Equatable, Sendable {
    var name: String
    var domain: String
    var description: String
    var timeField: String
    var fields: [HoloDataField]
    var sensitivity: HoloEvidenceSensitivity
    var maximumRangeDays: Int
}

nonisolated struct HoloDataCatalog: Codable, Equatable, Sendable {
    var datasets: [HoloDataSetSchema]
    func schema(named name: String) -> HoloDataSetSchema? { datasets.first { $0.name == name } }
}

nonisolated enum HoloQueryValue: Codable, Equatable, Sendable {
    case number(Double), text(String), date(Date), boolean(Bool)
    private enum CodingKeys: String, CodingKey { case type, number, text, date, boolean }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(HoloDataFieldType.self, forKey: .type) {
        case .number: self = .number(try c.decode(Double.self, forKey: .number))
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .date: self = .date(try c.decode(Date.self, forKey: .date))
        case .boolean: self = .boolean(try c.decode(Bool.self, forKey: .boolean))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let v): try c.encode(HoloDataFieldType.number, forKey: .type); try c.encode(v, forKey: .number)
        case .text(let v): try c.encode(HoloDataFieldType.text, forKey: .type); try c.encode(v, forKey: .text)
        case .date(let v): try c.encode(HoloDataFieldType.date, forKey: .type); try c.encode(v, forKey: .date)
        case .boolean(let v): try c.encode(HoloDataFieldType.boolean, forKey: .type); try c.encode(v, forKey: .boolean)
        }
    }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var textValue: String? { if case .text(let v) = self { return v }; return nil }
}

nonisolated struct HoloQueryRow: Codable, Equatable, Sendable {
    var id: String
    var occurredAt: Date
    var fields: [String: HoloQueryValue]
    var excerpt: String
}

nonisolated enum HoloDynamicFilterOperator: String, Codable, Sendable {
    case equal, notEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual, contains, oneOf
}
nonisolated struct HoloDynamicFilter: Codable, Equatable, Sendable {
    var field: String
    var operation: HoloDynamicFilterOperator
    var value: HoloQueryValue
    var values: [HoloQueryValue] = []
}
nonisolated enum HoloDynamicGroupBy: String, Codable, Sendable { case day, week, month, weekend, field }
nonisolated struct HoloDynamicGrouping: Codable, Equatable, Sendable {
    var type: HoloDynamicGroupBy
    var field: String? = nil
}
nonisolated enum HoloDynamicAggregationOperator: String, Codable, Sendable { case count, sum, average, min, max, distinctCount }
nonisolated struct HoloDynamicAggregation: Codable, Equatable, Sendable {
    var id: String
    var operation: HoloDynamicAggregationOperator
    var field: String? = nil
    var unit: String? = nil
    var filters: [HoloDynamicFilter] = []
}
nonisolated enum HoloDynamicDerivationOperator: String, Codable, Sendable { case difference, ratio, percentageChange, rate, perDay, linearTrend, coverage }
nonisolated struct HoloDynamicDerivation: Codable, Equatable, Sendable {
    var id: String
    var operation: HoloDynamicDerivationOperator
    var metricID: String
    var denominatorMetricID: String? = nil
    var unit: String? = nil
}
nonisolated enum HoloDynamicSortDirection: String, Codable, Sendable { case ascending, descending }
nonisolated struct HoloDynamicSort: Codable, Equatable, Sendable {
    var metricID: String
    var direction: HoloDynamicSortDirection
}
nonisolated struct HoloDynamicQueryPlan: Codable, Equatable, Sendable {
    var source: String
    var timeRange: HoloAgentTimeRange? = nil
    var baseline: HoloAgentTimeRange? = nil
    var filters: [HoloDynamicFilter] = []
    var groupBy: [HoloDynamicGrouping] = []
    var aggregations: [HoloDynamicAggregation]
    var derivations: [HoloDynamicDerivation] = []
    var sort: HoloDynamicSort? = nil
    var limit: Int = 20
    var evidenceLimit: Int = 20
}

nonisolated enum HoloCrossDomainOperation: String, Codable, Sendable {
    case correlation, conditionalAverage, groupComparison
}

nonisolated struct HoloCrossDomainQueryPlan: Codable, Equatable, Sendable {
    var leftSource: String
    var leftField: String
    var leftFilters: [HoloDynamicFilter] = []
    var rightSource: String
    var rightField: String
    var rightFilters: [HoloDynamicFilter] = []
    var operation: HoloCrossDomainOperation
    var threshold: Double? = nil
    var minimumAlignedDays: Int = 5
    var timeRange: HoloAgentTimeRange? = nil
}

nonisolated protocol HoloCrossDomainDataSource: Sendable {
    func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow]
    func rowsRead(source: String, timeRange: HoloAgentTimeRange?) async -> HoloDataSourceRead<[HoloQueryRow]>
}

nonisolated extension HoloCrossDomainDataSource {
    func rowsRead(source: String, timeRange: HoloAgentTimeRange?) async -> HoloDataSourceRead<[HoloQueryRow]> {
        .loaded(await rows(source: source, timeRange: timeRange))
    }
}

nonisolated protocol HoloDynamicRowDataSource: Sendable {
    func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow]
    func rowsRead(source: String, timeRange: HoloAgentTimeRange?) async -> HoloDataSourceRead<[HoloQueryRow]>
}

nonisolated extension HoloDynamicRowDataSource {
    func rowsRead(source: String, timeRange: HoloAgentTimeRange?) async -> HoloDataSourceRead<[HoloQueryRow]> {
        .loaded(await rows(source: source, timeRange: timeRange))
    }
}

/// 保留原工具名称与权限边界，只为其增加统一 dynamic_query 能力。
nonisolated struct HoloDynamicToolDecorator: HoloDataTool {
    let descriptor: HoloToolDescriptor
    private let base: any HoloDataTool
    private let catalog: HoloDataCatalog
    private let dataSource: any HoloDynamicRowDataSource

    init(base: any HoloDataTool, catalog: HoloDataCatalog, dataSource: any HoloDynamicRowDataSource) {
        self.base = base
        self.catalog = catalog
        self.dataSource = dataSource
        var descriptor = base.descriptor
        if !descriptor.supportedQueries.contains("dynamic_query") { descriptor.supportedQueries.append("dynamic_query") }
        descriptor.dynamicCatalog = catalog
        self.descriptor = descriptor
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        guard request.query == "dynamic_query" else { return base.validate(request) }
        guard HoloAgentDynamicQueryFlags.enabled else { return .invalid(reason: "动态查询尚未开启") }
        guard let plan = request.dynamicPlan else { return .invalid(reason: "dynamic_query 缺少 dynamicPlan") }
        do {
            try HoloDynamicQueryValidator.validate(plan, catalog: catalog)
            return .valid
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        guard request.query == "dynamic_query", var plan = request.dynamicPlan else {
            return try await base.execute(request)
        }
        guard case .valid = validate(request) else {
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .error,
                coverage: nil, metrics: [], events: [], warnings: [],
                error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: "动态查询计划无效", recoverable: true)
            )
        }
        plan.timeRange = plan.timeRange ?? request.timeRange
        plan.baseline = plan.baseline
            ?? request.baseline
            ?? HoloDynamicQueryRangeResolver.baselineIfNeeded(for: plan, currentRange: plan.timeRange)
        let currentRead = await dataSource.rowsRead(source: plan.source, timeRange: plan.timeRange)
        if [.unavailable, .waitingForUnlock, .error].contains(currentRead.status) {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: currentRead.status == .error ? .error : .unavailable,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(
                    code: currentRead.status == .waitingForUnlock ? "WAITING_FOR_UNLOCK" : "DYNAMIC_DATA_UNAVAILABLE",
                    message: currentRead.warning ?? "动态查询数据源暂不可用"
                )],
                error: HoloToolError(code: "DATA_SOURCE_UNAVAILABLE", message: currentRead.warning ?? "动态查询数据源读取失败", recoverable: true),
                sensitivity: catalog.schema(named: plan.source)?.sensitivity ?? .normal
            )
        }
        let baselineRead = await dataSource.rowsRead(source: plan.source, timeRange: plan.baseline)
        let baselineRows = [.success, .empty, .partial].contains(baselineRead.status) ? baselineRead.value : []
        do {
            let output = try HoloDynamicQueryEngine.execute(
                plan: plan, catalog: catalog, currentRows: currentRead.value, baselineRows: baselineRows
            )
            let sensitivity = catalog.schema(named: plan.source)?.sensitivity ?? .normal
            var coverage = output.coverage
            coverage?.returnedRecords = currentRead.returnedCount ?? currentRead.value.count
            coverage?.totalRecords = currentRead.totalCount ?? currentRead.value.count
            let coverageWasTruncated = coverage?.isTruncated == true
            coverage?.isTruncated = coverageWasTruncated || currentRead.isTruncated
            var warnings = output.metrics.isEmpty
                ? [HoloToolWarning(code: "NO_DYNAMIC_DATA", message: "该范围没有可计算数据")]
                : []
            if currentRead.status == .partial || currentRead.isTruncated || output.coverage?.isTruncated == true {
                warnings.append(HoloToolWarning(
                    code: "DYNAMIC_RESULT_TRUNCATED",
                    message: currentRead.warning ?? "结果或证据超过查询上限，已返回受控子集"
                ))
            }
            if ![.success, .empty, .partial].contains(baselineRead.status) {
                warnings.append(HoloToolWarning(code: "BASELINE_UNAVAILABLE", message: baselineRead.warning ?? "对比期数据暂不可用"))
            }
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool,
                status: output.metrics.isEmpty ? .empty : ((currentRead.status == .partial || currentRead.isTruncated) ? .partial : .success),
                coverage: coverage, metrics: output.metrics, events: output.events,
                warnings: warnings,
                error: nil, sensitivity: sensitivity
            )
        } catch {
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .error,
                coverage: nil, metrics: [], events: [], warnings: [],
                error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: error.localizedDescription, recoverable: true)
            )
        }
    }
}

nonisolated enum HoloAgentDynamicCatalogs {
    private static func field(_ name: String, _ type: HoloDataFieldType, _ unit: String? = nil, filterable: Bool = true, groupable: Bool = true, aggregatable: Bool = false, _ description: String) -> HoloDataField {
        HoloDataField(name: name, type: type, unit: unit, filterable: filterable, groupable: groupable, aggregatable: aggregatable, description: description)
    }
    private static func schema(_ name: String, domain: String, description: String, fields: [HoloDataField], sensitivity: HoloEvidenceSensitivity = .normal, maximumRangeDays: Int = 366) -> HoloDataCatalog {
        HoloDataCatalog(datasets: [HoloDataSetSchema(name: name, domain: domain, description: description, timeField: "date", fields: fields, sensitivity: sensitivity, maximumRangeDays: maximumRangeDays)])
    }

    static let habit = HoloDataCatalog(datasets: [HoloCrossDomainTool.habitSchema])
    static let task = HoloDataCatalog(datasets: [HoloCrossDomainTool.taskSchema])
    static let goal = HoloDataCatalog(datasets: [HoloCrossDomainTool.goalSchema])
    static let thought = schema("thought.daily", domain: "thought", description: "每日想法记录数", fields: [
        field("date", .date, nil, "日期"), field("value", .number, "条", groupable: false, aggregatable: true, "每日想法数")
    ], sensitivity: .sensitive)
    static let memory = schema("memory.entries", domain: "memory", description: "受控记忆条目", fields: [
        field("date", .date, nil, "记忆日期"), field("kind", .text, nil, "longTerm 或 episodic"),
        field("title", .text, nil, groupable: false, "标题"), field("summary", .text, nil, groupable: false, "摘要"),
        field("value", .number, "条", filterable: false, groupable: false, aggregatable: true, "条目计数")
    ], sensitivity: .sensitive)
    static let insight = schema("insight.records", domain: "insight", description: "历史观察摘要", fields: [
        field("date", .date, nil, "生成日期"), field("periodType", .text, nil, "周期类型"), field("status", .text, nil, "状态"),
        field("title", .text, nil, groupable: false, "标题"), field("summary", .text, nil, groupable: false, "摘要"),
        field("value", .number, "条", filterable: false, groupable: false, aggregatable: true, "观察计数")
    ], sensitivity: .sensitive)
    static let profile = schema("profile.items", domain: "profile", description: "用户主动档案字段", fields: [
        field("date", .date, nil, filterable: false, "读取日期"), field("category", .text, nil, "字段类别"),
        field("valueText", .text, nil, groupable: false, "档案值"), field("value", .number, "项", filterable: false, groupable: false, aggregatable: true, "字段计数")
    ], sensitivity: .sensitive, maximumRangeDays: 366)
    static let conversation = schema("conversation.metadata", domain: "conversation", description: "受控对话元数据，不含消息原文", fields: [
        field("date", .date, nil, "消息时间"), field("role", .text, nil, "角色"), field("intent", .text, nil, "意图"),
        field("value", .number, "条", filterable: false, groupable: false, aggregatable: true, "消息计数")
    ], sensitivity: .sensitive, maximumRangeDays: 90)
}

nonisolated struct HoloCrossDomainTool: HoloDataTool {
    static let habitSchema = HoloDataSetSchema(
        name: "habit.daily",
        domain: "habit",
        description: "习惯每日完成或发生次数",
        timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "日期"),
            HoloDataField(name: "value", type: .number, unit: "次", filterable: true, groupable: false, aggregatable: true, description: "每日次数"),
            HoloDataField(name: "habit", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "习惯名称"),
            HoloDataField(name: "polarity", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "positive 或 negative")
        ],
        sensitivity: .normal,
        maximumRangeDays: 366
    )

    static let taskSchema = HoloDataSetSchema(
        name: "task.daily",
        domain: "task",
        description: "每日完成任务数",
        timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "完成日期"),
            HoloDataField(name: "value", type: .number, unit: "个", filterable: true, groupable: false, aggregatable: true, description: "每日完成任务数"),
            HoloDataField(name: "highPriorityValue", type: .number, unit: "个", filterable: true, groupable: false, aggregatable: true, description: "每日完成高优任务数")
        ],
        sensitivity: .normal,
        maximumRangeDays: 366
    )

    static let goalSchema = HoloDataSetSchema(
        name: "goal.progress.daily",
        domain: "goal",
        description: "活跃目标关联任务的每日累计完成进度",
        timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "日期"),
            HoloDataField(name: "value", type: .number, unit: "%", filterable: true, groupable: false, aggregatable: true, description: "目标关联任务平均完成进度")
        ],
        sensitivity: .normal,
        maximumRangeDays: 366
    )

    static let healthSchemas: [HoloDataSetSchema] = [
        ("health.steps", "步", "每日步数"),
        ("health.sleep", "小时", "每日睡眠时长"),
        ("health.stand", "小时", "每日站立小时"),
        ("health.activity", "分钟", "每日活动分钟")
    ].map { name, unit, description in
        HoloDataSetSchema(
            name: name, domain: "health", description: description, timeField: "date",
            fields: [
                HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "记录日期"),
                HoloDataField(name: "value", type: .number, unit: unit, filterable: true, groupable: false, aggregatable: true, description: description)
            ],
            sensitivity: .sensitive, maximumRangeDays: 366
        )
    }

    static let financeSchema = HoloDataSetSchema(
        name: "finance.transactions", domain: "finance", description: "交易明细", timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "交易日期"),
            HoloDataField(name: "amount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "交易原始金额（兼容字段）"),
            HoloDataField(name: "signedAmount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "带方向金额，收入为正、支出为负"),
            HoloDataField(name: "expenseAmount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "支出金额"),
            HoloDataField(name: "incomeAmount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "收入金额"),
            HoloDataField(name: "category", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "分类"),
            HoloDataField(name: "type", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "expense 或 income")
        ],
        sensitivity: .sensitive, maximumRangeDays: 366
    )

    static let crossDomainCatalog = HoloDataCatalog(
        datasets: healthSchemas + [financeSchema, habitSchema, taskSchema, goalSchema]
    )

    let descriptor: HoloToolDescriptor
    private let dataSource: HoloCrossDomainDataSource

    init(dataSource: HoloCrossDomainDataSource) {
        self.dataSource = dataSource
        self.descriptor = HoloToolDescriptor(
            name: "cross_domain",
            description: "跨域按日关联计算（健康×财务 / 健康×习惯 / 任务×习惯 / 目标×任务），只能描述关联，不能推断因果",
            supportedQueries: ["aligned_analysis"],
            supportedTimeRanges: ["7d", "14d", "30d", "90d"],
            outputMetrics: ["dynamic.cross.correlation", "dynamic.cross.conditional_average", "dynamic.cross.group_difference"],
            sensitivityPolicy: "sensitive",
            dynamicCatalog: Self.crossDomainCatalog
        )
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        guard request.query == "aligned_analysis", let plan = request.crossDomainPlan else {
            return .invalid(reason: "aligned_analysis 缺少 crossDomainPlan")
        }
        let domains = Set([plan.leftSource.split(separator: ".").first.map(String.init) ?? "", plan.rightSource.split(separator: ".").first.map(String.init) ?? ""])
        let allowedDomainPairs: Set<Set<String>> = [
            Set(["health", "finance"]), Set(["health", "habit"]),
            Set(["task", "habit"]), Set(["goal", "task"])
        ]
        guard allowedDomainPairs.contains(domains) else {
            return .invalid(reason: "不支持该跨域组合")
        }
        guard let leftSchema = Self.crossDomainCatalog.schema(named: plan.leftSource),
              let rightSchema = Self.crossDomainCatalog.schema(named: plan.rightSource) else {
            return .invalid(reason: "跨域计划引用了未注册数据集")
        }
        guard leftSchema.fields.contains(where: { $0.name == plan.leftField && $0.type == .number && $0.aggregatable }),
              rightSchema.fields.contains(where: { $0.name == plan.rightField && $0.type == .number && $0.aggregatable }) else {
            return .invalid(reason: "跨域计划引用了不可计算字段")
        }
        let allowedLeftFilters = Set(leftSchema.fields.filter(\.filterable).map(\.name))
        let allowedRightFilters = Set(rightSchema.fields.filter(\.filterable).map(\.name))
        guard plan.leftFilters.map(\.field).allSatisfy(allowedLeftFilters.contains),
              plan.rightFilters.map(\.field).allSatisfy(allowedRightFilters.contains) else {
            return .invalid(reason: "跨域计划引用了不可筛选字段")
        }
        guard (3...90).contains(plan.minimumAlignedDays) else { return .invalid(reason: "minimumAlignedDays 超出安全范围") }
        return .valid
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        guard case .valid = validate(request), var plan = request.crossDomainPlan else {
            return Self.error(request, "跨域计划无效")
        }
        if plan.timeRange == nil { plan.timeRange = request.timeRange }
        let leftRead = await dataSource.rowsRead(source: plan.leftSource, timeRange: plan.timeRange)
        let rightRead = await dataSource.rowsRead(source: plan.rightSource, timeRange: plan.timeRange)
        if let failed = [(plan.leftSource, leftRead), (plan.rightSource, rightRead)].first(where: {
            [.unavailable, .waitingForUnlock, .error].contains($0.1.status)
        }) {
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool,
                status: failed.1.status == .error ? .error : .unavailable,
                coverage: nil, metrics: [], events: [],
                warnings: [HoloToolWarning(code: "CROSS_DOMAIN_DATA_UNAVAILABLE", message: failed.1.warning ?? "\(failed.0) 数据暂不可用")],
                error: HoloToolError(code: "DATA_SOURCE_UNAVAILABLE", message: failed.1.warning ?? "跨域数据源读取失败", recoverable: true),
                sensitivity: .sensitive
            )
        }
        let left = leftRead.value
        let right = rightRead.value
        let pairs = Self.align(
            left: left.filter { HoloDynamicQueryEngine.rowMatches($0, filters: plan.leftFilters) },
            leftField: plan.leftField,
            right: right.filter { HoloDynamicQueryEngine.rowMatches($0, filters: plan.rightFilters) },
            rightField: plan.rightField
        )
        guard pairs.count >= plan.minimumAlignedDays else {
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool, status: .empty,
                coverage: nil, metrics: [], events: [],
                warnings: [HoloToolWarning(code: "INSUFFICIENT_ALIGNED_DAYS", message: "跨域对齐仅 \(pairs.count) 天，至少需要 \(plan.minimumAlignedDays) 天")],
                error: nil, sensitivity: .sensitive
            )
        }
        let calculated = Self.calculate(plan: plan, pairs: pairs)
        guard let value = calculated.value else { return Self.error(request, "跨域数据方差不足，无法计算") }
        let metricKey = "dynamic.cross.\(plan.operation.rawValue).\(Self.sanitize(plan.leftSource))_\(Self.sanitize(plan.rightSource))"
        let sourceIDs = pairs.flatMap { [$0.leftID, $0.rightID] }
        let metric = HoloMetric(
            metricKey: metricKey,
            value: value,
            unit: calculated.unit,
            baselineValue: calculated.baseline,
            comparison: "aligned_days=\(pairs.count)",
            formula: calculated.formula,
            sourceRecordIDs: sourceIDs
        )
        let event = HoloEvidenceEvent(
            id: "cross-\(request.id)", occurredAt: plan.timeRange?.end,
            metricKey: metricKey, metricValue: value,
            excerpt: calculated.excerpt,
            timeRange: plan.timeRange,
            formula: calculated.formula,
            sourceRecordIDs: sourceIDs
        )
        let partial = leftRead.status == .partial || rightRead.status == .partial
            || leftRead.isTruncated || rightRead.isTruncated
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: partial ? .partial : .success,
            coverage: nil, metrics: [metric], events: [event],
            warnings: partial
                ? [HoloToolWarning(code: "CROSS_DOMAIN_DATA_TRUNCATED", message: "跨域分析使用了受控数据子集")]
                : [],
            error: nil, sensitivity: .sensitive
        )
    }

    private struct Pair { var left: Double; var right: Double; var leftID: String; var rightID: String }
    private struct Calculation { var value: Double?; var baseline: Double?; var unit: String; var formula: String; var excerpt: String }

    private static func align(left: [HoloQueryRow], leftField: String, right: [HoloQueryRow], rightField: String, calendar: Calendar = .current) -> [Pair] {
        func daily(_ rows: [HoloQueryRow], field: String) -> [Date: (Double, String)] {
            var buckets: [Date: [(Double, String)]] = [:]
            for row in rows {
                guard let value = row.fields[field]?.numberValue else { continue }
                buckets[calendar.startOfDay(for: row.occurredAt), default: []].append((value, row.id))
            }
            return buckets.mapValues { values in
                (values.map(\.0).reduce(0, +) / Double(values.count), values.map(\.1).joined(separator: ","))
            }
        }
        let lhs = daily(left, field: leftField), rhs = daily(right, field: rightField)
        return Set(lhs.keys).intersection(rhs.keys).sorted().compactMap { day in
            guard let l = lhs[day], let r = rhs[day] else { return nil }
            return Pair(left: l.0, right: r.0, leftID: l.1, rightID: r.1)
        }
    }

    private static func calculate(plan: HoloCrossDomainQueryPlan, pairs: [Pair]) -> Calculation {
        let threshold = plan.threshold ?? median(pairs.map(\.left))
        switch plan.operation {
        case .correlation:
            let value = correlation(pairs.map { ($0.left, $0.right) })
            return Calculation(value: value, baseline: nil, unit: "相关系数", formula: "pearson(left,right)", excerpt: "按日对齐 \(pairs.count) 天，相关系数 \(value.map { String(format: "%.3f", $0) } ?? "不可计算")；仅表示关联，不表示因果")
        case .conditionalAverage:
            let selected = pairs.filter { $0.left < threshold }.map(\.right)
            let overall = pairs.map(\.right).reduce(0, +) / Double(pairs.count)
            let value = selected.isEmpty ? nil : selected.reduce(0, +) / Double(selected.count)
            return Calculation(value: value, baseline: overall, unit: "", formula: "average(right where left < threshold)", excerpt: "左侧指标低于 \(threshold) 的 \(selected.count) 天，右侧均值为 \(value.map { String(format: "%.2f", $0) } ?? "不可计算")；全期均值 \(String(format: "%.2f", overall))")
        case .groupComparison:
            let low = pairs.filter { $0.left < threshold }.map(\.right)
            let high = pairs.filter { $0.left >= threshold }.map(\.right)
            guard !low.isEmpty, !high.isEmpty else { return Calculation(value: nil, baseline: nil, unit: "", formula: "average(high)-average(low)", excerpt: "分组样本不足") }
            let lowMean = low.reduce(0, +) / Double(low.count), highMean = high.reduce(0, +) / Double(high.count)
            return Calculation(value: highMean - lowMean, baseline: lowMean, unit: "", formula: "average(right|left>=threshold)-average(right|left<threshold)", excerpt: "按左侧指标高低分组，右侧均值差为 \(String(format: "%.2f", highMean - lowMean))；仅表示分组差异，不表示因果")
        }
    }

    private static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count > 2 else { return nil }
        let mx = pairs.map(\.0).reduce(0, +) / Double(pairs.count), my = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
        let numerator = pairs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        let dx = sqrt(pairs.map { pow($0.0 - mx, 2) }.reduce(0, +)), dy = sqrt(pairs.map { pow($0.1 - my, 2) }.reduce(0, +))
        guard dx > 0, dy > 0 else { return nil }
        return (numerator / (dx * dy) * 10_000).rounded() / 10_000
    }
    private static func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    private static func sanitize(_ value: String) -> String { value.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }
    private static func error(_ request: HoloToolRequest, _ reason: String) -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .error, coverage: nil, metrics: [], events: [], warnings: [], error: HoloToolError(code: HoloToolErrorCode.invalidParams, message: reason, recoverable: true), sensitivity: .sensitive)
    }
}

nonisolated enum HoloDynamicQueryValidationError: Error, Equatable, LocalizedError {
    case unknownDataset(String), unknownField(String), unsupportedFieldOperation(String)
    case invalidRange, rangeTooLarge(Int), tooComplex, unsafeLimit, unitMismatch(String)
    var errorDescription: String? {
        switch self {
        case .unknownDataset(let v): return "未注册数据集：\(v)"
        case .unknownField(let v): return "未注册字段：\(v)"
        case .unsupportedFieldOperation(let v): return "字段不支持该操作：\(v)"
        case .invalidRange: return "查询时间范围无效"
        case .rangeTooLarge(let v): return "查询范围超过安全上限：\(v) 天"
        case .tooComplex: return "查询计划复杂度超过上限"
        case .unsafeLimit: return "查询结果数量超过上限"
        case .unitMismatch(let v): return "字段单位不兼容：\(v)"
        }
    }
}

nonisolated enum HoloDynamicQueryValidator {
    static func validate(_ plan: HoloDynamicQueryPlan, catalog: HoloDataCatalog, calendar: Calendar = .current) throws {
        guard let schema = catalog.schema(named: plan.source) else { throw HoloDynamicQueryValidationError.unknownDataset(plan.source) }
        guard plan.aggregations.count <= 5, plan.derivations.count <= 5, plan.filters.count <= 10 else { throw HoloDynamicQueryValidationError.tooComplex }
        guard (1...50).contains(plan.limit), (1...200).contains(plan.evidenceLimit) else { throw HoloDynamicQueryValidationError.unsafeLimit }
        if let range = plan.timeRange, let start = range.start, let end = range.end {
            guard start < end else { throw HoloDynamicQueryValidationError.invalidRange }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
            guard days <= schema.maximumRangeDays else { throw HoloDynamicQueryValidationError.rangeTooLarge(days) }
        }
        let fields = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.name, $0) })
        for filter in plan.filters {
            guard let field = fields[filter.field] else { throw HoloDynamicQueryValidationError.unknownField(filter.field) }
            guard field.filterable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(filter.field) }
        }
        for grouping in plan.groupBy where grouping.type == .field {
            guard let name = grouping.field, let field = fields[name] else { throw HoloDynamicQueryValidationError.unknownField(grouping.field ?? "") }
            guard field.groupable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(name) }
        }
        for aggregation in plan.aggregations where aggregation.operation != .count {
            guard let name = aggregation.field, let field = fields[name] else { throw HoloDynamicQueryValidationError.unknownField(aggregation.field ?? "") }
            guard field.aggregatable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(name) }
            if let requested = aggregation.unit, let actual = field.unit, requested != actual { throw HoloDynamicQueryValidationError.unitMismatch(name) }
        }
        for aggregation in plan.aggregations {
            for filter in aggregation.filters {
                guard let field = fields[filter.field] else { throw HoloDynamicQueryValidationError.unknownField(filter.field) }
                guard field.filterable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(filter.field) }
            }
        }
    }
}

nonisolated struct HoloDynamicExecutionOutput: Equatable, Sendable {
    var metrics: [HoloMetric]
    var events: [HoloEvidenceEvent]
    var coverage: HoloDataCoverage?
}

nonisolated enum HoloDynamicQueryRangeResolver {
    static func baselineIfNeeded(for plan: HoloDynamicQueryPlan, currentRange: HoloAgentTimeRange?) -> HoloAgentTimeRange? {
        guard plan.baseline == nil,
              plan.derivations.contains(where: { [.difference, .ratio, .percentageChange].contains($0.operation) }),
              let currentRange,
              let start = currentRange.start,
              let end = currentRange.end else { return plan.baseline }
        let duration = end.timeIntervalSince(start)
        return HoloAgentTimeRange(label: "前一对比期", start: start.addingTimeInterval(-duration), end: start)
    }
}

/// 只执行白名单 DSL 的确定性计算器；不接受 SQL、代码或自由表达式。
nonisolated enum HoloDynamicQueryEngine {
    private struct Bucket {
        var key: String
        var rows: [HoloQueryRow]
    }

    static func execute(
        plan: HoloDynamicQueryPlan,
        catalog: HoloDataCatalog,
        currentRows: [HoloQueryRow],
        baselineRows: [HoloQueryRow] = [],
        calendar: Calendar = .current
    ) throws -> HoloDynamicExecutionOutput {
        try HoloDynamicQueryValidator.validate(plan, catalog: catalog, calendar: calendar)
        let current = currentRows.filter { matches($0, filters: plan.filters) }
        let baseline = baselineRows.filter { matches($0, filters: plan.filters) }
        let currentBuckets = buckets(current, grouping: plan.groupBy.first, calendar: calendar)
        let baselineBuckets = Dictionary(uniqueKeysWithValues: buckets(baseline, grouping: plan.groupBy.first, calendar: calendar).map { ($0.key, $0.rows) })

        var metrics: [HoloMetric] = []
        for bucket in currentBuckets {
            for aggregation in plan.aggregations {
                guard let value = aggregate(aggregation, rows: bucket.rows) else { continue }
                let baselineValue = aggregate(aggregation, rows: baselineBuckets[bucket.key] ?? [])
                let key = metricKey(source: plan.source, id: aggregation.id, group: bucket.key)
                let sourceIDs = Array(bucket.rows.prefix(plan.evidenceLimit).map(\.id))
                metrics.append(HoloMetric(
                    metricKey: key,
                    value: rounded(value),
                    unit: aggregation.unit,
                    baselineValue: baselineValue.map(rounded),
                    comparison: bucket.key == "all" ? nil : bucket.key,
                    formula: formula(aggregation),
                    sourceRecordIDs: sourceIDs
                ))
            }
        }

        for derivation in plan.derivations {
            metrics.append(contentsOf: derive(derivation, plan: plan, metrics: metrics, current: current, calendar: calendar))
        }

        if let sort = plan.sort {
            let sortable = metrics.filter { $0.metricKey.contains(".\(sanitize(sort.metricID)).") }
            if !sortable.isEmpty { metrics = sortable }
            metrics.sort {
                let lhs = $0.value ?? -.greatestFiniteMagnitude
                let rhs = $1.value ?? -.greatestFiniteMagnitude
                return sort.direction == .ascending ? lhs < rhs : lhs > rhs
            }
        }
        let isOutputTruncated = metrics.count > plan.limit
        metrics = Array(metrics.prefix(plan.limit))

        let events = metrics.map { metric in
            HoloEvidenceEvent(
                id: "dynamic-\(metric.metricKey)",
                occurredAt: plan.timeRange?.end,
                metricKey: metric.metricKey,
                metricValue: metric.value,
                excerpt: evidenceText(metric),
                timeRange: plan.timeRange,
                baselineTimeRange: plan.baseline,
                formula: metric.formula,
                sourceRecordIDs: metric.sourceRecordIDs
            )
        }
        return HoloDynamicExecutionOutput(
            metrics: metrics,
            events: events,
            coverage: coverage(
                rows: current,
                range: plan.timeRange,
                isTruncated: isOutputTruncated || current.contains { row in
                    metrics.contains { ($0.sourceRecordIDs?.contains(row.id) ?? false) == false }
                },
                calendar: calendar
            )
        )
    }

    static func rowMatches(_ row: HoloQueryRow, filters: [HoloDynamicFilter]) -> Bool {
        matches(row, filters: filters)
    }

    private static func buckets(_ rows: [HoloQueryRow], grouping: HoloDynamicGrouping?, calendar: Calendar) -> [Bucket] {
        guard let grouping else { return [Bucket(key: "all", rows: rows)] }
        var grouped: [String: [HoloQueryRow]] = [:]
        for row in rows {
            let key: String
            switch grouping.type {
            case .day:
                key = dateKey(row.occurredAt, format: "yyyy-MM-dd")
            case .week:
                let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: row.occurredAt)
                key = String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
            case .month:
                key = dateKey(row.occurredAt, format: "yyyy-MM")
            case .weekend:
                key = calendar.isDateInWeekend(row.occurredAt) ? "weekend" : "weekday"
            case .field:
                key = grouping.field.flatMap { row.fields[$0]?.textValue } ?? "unknown"
            }
            grouped[key, default: []].append(row)
        }
        return grouped.keys.sorted().map { Bucket(key: $0, rows: grouped[$0] ?? []) }
    }

    private static func matches(_ row: HoloQueryRow, filters: [HoloDynamicFilter]) -> Bool {
        filters.allSatisfy { filter in
            guard let actual = row.fields[filter.field] else { return false }
            switch (actual, filter.value, filter.operation) {
            case (.number(let lhs), .number(let rhs), .equal): return lhs == rhs
            case (.number(let lhs), .number(let rhs), .notEqual): return lhs != rhs
            case (.number(let lhs), .number(let rhs), .greaterThan): return lhs > rhs
            case (.number(let lhs), .number(let rhs), .greaterThanOrEqual): return lhs >= rhs
            case (.number(let lhs), .number(let rhs), .lessThan): return lhs < rhs
            case (.number(let lhs), .number(let rhs), .lessThanOrEqual): return lhs <= rhs
            case (.text(let lhs), .text(let rhs), .equal): return lhs.caseInsensitiveCompare(rhs) == .orderedSame
            case (.text(let lhs), .text(let rhs), .notEqual): return lhs.caseInsensitiveCompare(rhs) != .orderedSame
            case (.text(let lhs), .text(let rhs), .contains): return lhs.localizedCaseInsensitiveContains(rhs)
            case (_, _, .oneOf): return filter.values.contains(actual)
            case (.boolean(let lhs), .boolean(let rhs), .equal): return lhs == rhs
            default: return false
            }
        }
    }

    private static func aggregate(_ spec: HoloDynamicAggregation, rows: [HoloQueryRow]) -> Double? {
        let rows = rows.filter { matches($0, filters: spec.filters) }
        if spec.operation == .count { return Double(rows.count) }
        guard let field = spec.field else { return nil }
        if spec.operation == .distinctCount {
            let values = rows.compactMap { $0.fields[field] }
            return Double(Set(values.map { String(describing: $0) }).count)
        }
        let values = rows.compactMap { $0.fields[field]?.numberValue }
        guard !values.isEmpty else { return nil }
        switch spec.operation {
        case .sum: return values.reduce(0, +)
        case .average: return values.reduce(0, +) / Double(values.count)
        case .min: return values.min()
        case .max: return values.max()
        case .count, .distinctCount: return nil
        }
    }

    private static func derive(
        _ spec: HoloDynamicDerivation,
        plan: HoloDynamicQueryPlan,
        metrics: [HoloMetric],
        current: [HoloQueryRow],
        calendar: Calendar
    ) -> [HoloMetric] {
        let matching = metrics.filter { $0.metricKey.contains(".\(sanitize(spec.metricID))") }
        return matching.compactMap { metric in
            let value: Double?
            let formula: String
            switch spec.operation {
            case .difference:
                value = metric.baselineValue.map { (metric.value ?? 0) - $0 }
                formula = "current - baseline"
            case .ratio:
                if let denominatorID = spec.denominatorMetricID,
                   let denominator = metrics.first(where: { $0.metricKey.contains(".\(sanitize(denominatorID))") })?.value,
                   denominator != 0 {
                    value = (metric.value ?? 0) / denominator
                } else if let baseline = metric.baselineValue, baseline != 0 {
                    value = (metric.value ?? 0) / baseline
                } else { value = nil }
                formula = "numerator / denominator"
            case .percentageChange:
                if let baseline = metric.baselineValue, baseline != 0 { value = ((metric.value ?? 0) - baseline) / abs(baseline) } else { value = nil }
                formula = "(current - baseline) / abs(baseline)"
            case .rate:
                if let denominatorID = spec.denominatorMetricID,
                   let denominator = metrics.first(where: { $0.metricKey.contains(".\(sanitize(denominatorID))") })?.value,
                   denominator != 0 { value = (metric.value ?? 0) / denominator } else { value = nil }
                formula = "count / total"
            case .perDay:
                if let range = plan.timeRange, let start = range.start, let end = range.end {
                    let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1)
                    value = (metric.value ?? 0) / Double(days)
                    formula = "value / calendar_days(\(days))"
                } else {
                    value = nil
                    formula = "value / calendar_days"
                }
            case .linearTrend:
                let values = current.sorted { $0.occurredAt < $1.occurredAt }.compactMap { row in
                    plan.aggregations.first(where: { $0.id == spec.metricID })?.field.flatMap { row.fields[$0]?.numberValue }
                }
                value = slope(values)
                formula = "least_squares_slope"
            case .coverage:
                value = coverage(rows: current, range: plan.timeRange, calendar: calendar)?.coverageRatio
                formula = "covered_days / total_days"
            }
            guard let value else { return nil }
            let group = metric.comparison ?? "all"
            return HoloMetric(
                metricKey: metricKey(source: plan.source, id: spec.id, group: group),
                value: rounded(value),
                unit: spec.unit,
                baselineValue: nil,
                comparison: metric.comparison,
                formula: formula,
                sourceRecordIDs: metric.sourceRecordIDs
            )
        }
    }

    private static func coverage(
        rows: [HoloQueryRow],
        range: HoloAgentTimeRange?,
        isTruncated: Bool = false,
        calendar: Calendar
    ) -> HoloDataCoverage? {
        guard let range, let start = range.start, let end = range.end else { return nil }
        let total = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1)
        let coveredDates = Set(rows.map { calendar.startOfDay(for: $0.occurredAt) })
        let covered = coveredDates.count
        let missingRanges = (0..<total).compactMap { offset -> HoloAgentTimeRange? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start)),
                  !coveredDates.contains(day),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return HoloAgentTimeRange(label: "缺失日期", start: day, end: next)
        }
        let actualStart = rows.map(\.occurredAt).min()
        let actualEnd = rows.map(\.occurredAt).max().map { $0.addingTimeInterval(1) }
        return HoloDataCoverage(
            coveredDays: covered,
            totalDays: total,
            coverageRatio: Double(covered) / Double(total),
            missingRanges: missingRanges,
            note: "已读取 \(covered)/\(total) 天、\(rows.count) 条数据\(isTruncated ? "，输出已截断" : "")",
            requestedRange: range,
            actualRange: actualStart.map { HoloAgentTimeRange(label: "实际覆盖", start: $0, end: actualEnd) },
            returnedRecords: rows.count,
            totalRecords: rows.count,
            isTruncated: isTruncated
        )
    }

    private static func slope(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let n = Double(values.count)
        let xs = values.indices.map(Double.init)
        let sumX = xs.reduce(0, +), sumY = values.reduce(0, +)
        let denominator = n * xs.map { $0 * $0 }.reduce(0, +) - sumX * sumX
        guard denominator != 0 else { return nil }
        return (n * zip(xs, values).map(*).reduce(0, +) - sumX * sumY) / denominator
    }

    private static func formula(_ spec: HoloDynamicAggregation) -> String { "\(spec.operation.rawValue)(\(spec.field ?? "rows"))" }
    private static func metricKey(source: String, id: String, group: String) -> String { "dynamic.\(sanitize(source)).\(sanitize(id)).\(sanitize(group))" }
    private static func sanitize(_ value: String) -> String { value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }
    private static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
    private static func dateKey(_ date: Date, format: String) -> String { let f = DateFormatter(); f.dateFormat = format; return f.string(from: date) }
    private static func evidenceText(_ metric: HoloMetric) -> String {
        let group = metric.comparison.map { "（\($0)）" } ?? ""
        let valueText = metric.value.map { String($0) } ?? "无值"
        return "动态计算 \(metric.metricKey)\(group)：\(valueText) \(metric.unit ?? "")；公式：\(metric.formula ?? "")；来源 \(metric.sourceRecordIDs?.count ?? 0) 条"
    }
}

/// 参数校验结果。
nonisolated enum HoloToolValidationResult: Equatable, Sendable {
    case valid
    case invalid(reason: String)
}

/// 工具错误码（Executor 与各工具统一使用，便于上层识别与重试策略）。
nonisolated enum HoloToolErrorCode {
    /// 工具未注册
    static let toolNotFound = "TOOL_NOT_FOUND"
    /// 参数非法（可恢复，提示 LLM 重试）
    static let invalidParams = "INVALID_PARAMS"
    /// 执行异常（通常可恢复）
    static let executionFailure = "EXECUTION_FAILURE"
    /// 设备锁定，受保护数据（HealthKit 等）暂不可读（可恢复，§7.2 等待解锁）
    static let deviceLocked = "DEVICE_LOCKED"
    /// 健康数据权限被拒绝（不可恢复，需用户授权）
    static let healthPermissionDenied = "HEALTH_PERMISSION_DENIED"
    /// 健康查询暂时性失败（可恢复）
    static let healthTemporarilyUnavailable = "HEALTH_TEMPORARILY_UNAVAILABLE"
}
