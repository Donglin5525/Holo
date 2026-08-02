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
    var coverageSemantics: HoloDataCoverageSemantics? = nil

    var resolvedCoverageSemantics: HoloDataCoverageSemantics {
        coverageSemantics ?? .eventRecords
    }
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
}

nonisolated protocol HoloDynamicRowDataSource: Sendable {
    func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow]
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
        let resolvedRange = HoloAgentHistoricalTimePolicy.resolve(plan.timeRange)
        if resolvedRange.isEntirelyFuture {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [
                    HoloToolWarning(
                        code: "FUTURE_RANGE_NOT_HISTORICAL",
                        message: "所选范围尚未发生，未把未来计划记录计入历史统计"
                    )
                ],
                error: nil
            )
        }
        plan.timeRange = resolvedRange.effectiveRange
        let requestedBaseline = plan.baseline
            ?? request.baseline
            ?? HoloDynamicQueryRangeResolver.baselineIfNeeded(for: plan, currentRange: plan.timeRange)
        let resolvedBaseline = HoloAgentHistoricalTimePolicy.resolve(requestedBaseline)
        plan.baseline = resolvedBaseline.isEntirelyFuture ? nil : resolvedBaseline.effectiveRange
        let currentRows = await dataSource.rows(source: plan.source, timeRange: plan.timeRange)
        let baselineRows = await dataSource.rows(source: plan.source, timeRange: plan.baseline)
        do {
            let output = try HoloDynamicQueryEngine.execute(
                plan: plan, catalog: catalog, currentRows: currentRows, baselineRows: baselineRows
            )
            let sensitivity = catalog.schema(named: plan.source)?.sensitivity ?? .normal
            return HoloDataToolResult(
                toolRequestID: request.id, tool: request.tool,
                status: output.metrics.isEmpty ? .empty : .success,
                coverage: output.coverage, metrics: output.metrics, events: output.events,
                warnings: output.metrics.isEmpty ? [HoloToolWarning(code: "NO_DYNAMIC_DATA", message: "该范围没有可计算数据")] : [],
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
        description: "习惯每日完成次数或测量值",
        timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "日期"),
            HoloDataField(name: "value", type: .number, unit: nil, filterable: true, groupable: false, aggregatable: true, description: "打卡/计数型为每日次数；测量型（如体重）为当日测量值，单位是习惯自身单位（如 kg）。unit 留空表示单位因习惯而异，由 discover 返回具体单位"),
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
            sensitivity: .sensitive,
            maximumRangeDays: 366,
            coverageSemantics: .dailyObservations
        )
    }

    static let financeSchema = HoloDataSetSchema(
        name: "finance.transactions", domain: "finance", description: "交易明细", timeField: "date",
        fields: [
            HoloDataField(name: "date", type: .date, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "交易日期"),
            HoloDataField(name: "amount", type: .number, unit: "元", filterable: true, groupable: false, aggregatable: true, description: "交易金额"),
            HoloDataField(name: "category", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "分类"),
            HoloDataField(name: "account", type: .text, unit: nil, filterable: true, groupable: true, aggregatable: false, description: "账户"),
            HoloDataField(name: "text", type: .text, unit: nil, filterable: true, groupable: false, aggregatable: false, description: "商户或备注")
        ],
        sensitivity: .normal, maximumRangeDays: 366
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
        let historicalRange = HoloAgentHistoricalTimePolicy.resolve(plan.timeRange)
        if historicalRange.isEntirelyFuture {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [
                    HoloToolWarning(
                        code: "FUTURE_RANGE_NOT_HISTORICAL",
                        message: "所选范围尚未发生，无法计算历史跨域关系"
                    )
                ],
                error: nil,
                sensitivity: .sensitive
            )
        }
        plan.timeRange = historicalRange.effectiveRange
        let left = await dataSource.rows(source: plan.leftSource, timeRange: plan.timeRange)
        let right = await dataSource.rows(source: plan.rightSource, timeRange: plan.timeRange)
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
        let semantic = HoloMetricSemanticFactory.crossDomainSemantic(
            plan: plan,
            value: value,
            baselineValue: calculated.baseline,
            unit: calculated.unit
        )
        let metric = HoloMetric(
            metricKey: metricKey,
            value: value,
            unit: calculated.unit,
            baselineValue: calculated.baseline,
            comparison: "aligned_days=\(pairs.count)",
            formula: calculated.formula,
            sourceRecordIDs: sourceIDs,
            semantic: semantic
        )
        let event = HoloEvidenceEvent(
            id: "cross-\(request.id)", occurredAt: plan.timeRange?.end,
            metricKey: metricKey, metricValue: value,
            excerpt: calculated.excerpt,
            timeRange: plan.timeRange,
            formula: calculated.formula,
            sourceRecordIDs: sourceIDs,
            semantic: semantic
        )
        return HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: [metric], events: [event], warnings: [], error: nil, sensitivity: .sensitive
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
        // limit 上限 200：全年趋势（按月 12、按周 52）等场景需要；按日聚合 365 天会超限，
        // 但 prompt 已引导按月聚合。原 50 过严，导致模型 limit:100 被反复拒绝。
        guard (1...200).contains(plan.limit), (1...200).contains(plan.evidenceLimit) else { throw HoloDynamicQueryValidationError.unsafeLimit }
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
            // distinctCount 放宽：允许 aggregatable 或 groupable 的字段。
            // groupable 的离散文本字段（如 habit 名称、finance 分类）天然适合 distinctCount，
            // 此前要求 aggregatable 导致"用户有哪些习惯名"这类探查被拒。
            // sum/average/min/max 仍严格要求 aggregatable（对文本无意义）。
            if aggregation.operation == .distinctCount {
                guard field.aggregatable || field.groupable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(name) }
            } else {
                guard field.aggregatable else { throw HoloDynamicQueryValidationError.unsupportedFieldOperation(name) }
            }
            // unit 比对忽略大小写：模型从 discover 看到"kg"可能写成"KG"，属正常差异，不该拒绝。
            // 字段 unit 为 nil（如 habit.daily.value 单位因习惯而异）时不校验。
            if let requested = aggregation.unit?.lowercased(), let actual = field.unit?.lowercased(), requested != actual {
                throw HoloDynamicQueryValidationError.unitMismatch(name)
            }
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

// MARK: - 类型化结果语义构造（P1）

/// 从查询计划、schema 与聚合/派生定义构造 `HoloMetricSemantic` 的唯一入口。
/// 只接受结构化输入，不接受自由字符串，保证语义可验证、可复算。
nonisolated enum HoloMetricSemanticFactory {

    // MARK: 单位映射

    /// unit 字符串 → 业务量；nil / 空 / 未知 → none。P2 展示层复用同一映射，保持 internal。
    static func measure(forUnit unit: String?) -> HoloMetricMeasure {
        guard let unit else { return .none }
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "元": return .amount
        case "个", "条", "项", "笔", "类", "次": return .count
        case "小时": return .durationHours
        case "分钟": return .durationMinutes
        case "步": return .steps
        case "天": return .days
        case "晚": return .nights
        case "%", "比例": return .ratio
        case "元/月": return .rateMonthly
        case "元/天": return .rateDaily
        case "相关系数": return .correlation
        default: return .none
        }
    }

    // MARK: 操作映射

    static func operation(forAggregation operation: HoloDynamicAggregationOperator) -> HoloMetricOperation {
        switch operation {
        case .count: return .count
        case .sum: return .sum
        case .average: return .average
        case .min: return .minimum
        case .max: return .maximum
        case .distinctCount: return .distinctCount
        }
    }

    static func operation(forDerivation operation: HoloDynamicDerivationOperator) -> HoloMetricOperation {
        switch operation {
        case .difference: return .difference
        case .ratio: return .ratio
        case .percentageChange: return .percentageChange
        case .rate: return .rate
        case .perDay: return .perDay
        case .linearTrend: return .linearTrend
        case .coverage: return .coverage
        }
    }

    // MARK: 数值角色与方向

    /// 聚合指标恒为 current；派生指标按操作决定角色。
    static func valueRole(forDerivation operation: HoloDynamicDerivationOperator) -> HoloMetricValueRole {
        switch operation {
        case .difference: return .delta
        case .percentageChange: return .changeRate
        case .ratio: return .share
        case .rate: return .share
        case .perDay: return .current
        case .linearTrend: return .trend
        case .coverage: return .coverage
        }
    }

    /// delta / changeRate 按结果值符号给方向（|v| < 1e-9 视为持平），其余角色无方向。
    static func direction(forRole role: HoloMetricValueRole, resultValue: Double) -> HoloMetricDirection? {
        guard role == .delta || role == .changeRate else { return nil }
        if resultValue > 1e-9 { return .increase }
        if resultValue < -1e-9 { return .decrease }
        return .flat
    }

    // MARK: 分组维度与标签

    /// 分组定义 → 维度；field 分组按字段名白名单映射，未知字段不猜、返回 nil。
    static func dimension(forGrouping grouping: HoloDynamicGrouping?) -> HoloMetricDimension? {
        guard let grouping else { return nil }
        switch grouping.type {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .weekend: return .weekend
        case .field:
            switch grouping.field {
            case "category": return .category
            case "account": return .account
            case "transactionType": return .transactionType
            case "habit": return .habit
            case "polarity": return .polarity
            case "kind": return .memoryKind
            case "periodType": return .periodType
            case "status": return .insightStatus
            case "role": return .conversationRole
            case "intent": return .conversationIntent
            default: return nil
            }
        }
    }

    /// bucket key → 展示分组标签；无分组或 "all"/"unknown" 时返回 nil。
    static func groupLabel(forBucketKey bucketKey: String, grouping: HoloDynamicGrouping?) -> String? {
        guard grouping != nil else { return nil }
        let trimmed = bucketKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "all",
              trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }

    // MARK: 领域映射

    /// schema.domain 字符串 → 来源模块；insight.records 的 domain 字符串是 "insight"，归入 memoryInsight。
    static func domain(forDomainString domain: String) -> HoloEvidenceSourceModule {
        if domain == "insight" { return .memoryInsight }
        return HoloEvidenceSourceModule(rawValue: domain) ?? .agent
    }

    // MARK: 语义构造

    /// 聚合指标语义：currentValue = 当前周期值，baselineValue = 对比周期值。
    static func aggregationSemantic(
        plan: HoloDynamicQueryPlan,
        schema: HoloDataSetSchema?,
        aggregation: HoloDynamicAggregation,
        bucketKey: String,
        value: Double,
        baselineValue: Double?
    ) -> HoloMetricSemantic {
        let semantic = HoloMetricSemantic(
            domain: domain(forDomainString: schema?.domain ?? ""),
            dataset: schema?.name ?? plan.source,
            measure: measure(forUnit: aggregation.unit),
            operation: operation(forAggregation: aggregation.operation),
            valueRole: .current,
            dimension: dimension(forGrouping: plan.groupBy.first),
            groupLabel: groupLabel(forBucketKey: bucketKey, grouping: plan.groupBy.first),
            direction: nil,
            currentValue: value,
            baselineValue: baselineValue,
            resultValue: value,
            displayUnit: aggregation.unit
        )
        assertInvariants(semantic)
        return semantic
    }

    /// 派生指标语义：currentValue / baselineValue 继承自被派生的源 metric。
    static func derivationSemantic(
        plan: HoloDynamicQueryPlan,
        schema: HoloDataSetSchema?,
        derivation: HoloDynamicDerivation,
        source: HoloMetric,
        groupKey: String,
        value: Double
    ) -> HoloMetricSemantic {
        let role = valueRole(forDerivation: derivation.operation)
        let semantic = HoloMetricSemantic(
            domain: domain(forDomainString: schema?.domain ?? ""),
            dataset: schema?.name ?? plan.source,
            measure: measure(forUnit: derivation.unit),
            operation: operation(forDerivation: derivation.operation),
            valueRole: role,
            dimension: dimension(forGrouping: plan.groupBy.first),
            groupLabel: groupLabel(forBucketKey: groupKey, grouping: plan.groupBy.first),
            direction: direction(forRole: role, resultValue: value),
            currentValue: source.value,
            baselineValue: source.baselineValue,
            resultValue: value,
            displayUnit: derivation.unit
        )
        assertInvariants(semantic)
        return semantic
    }

    /// 跨域指标语义：domain 取右侧（因变量）source 前缀，dataset 为 "left+right" 组合。
    static func crossDomainSemantic(
        plan: HoloCrossDomainQueryPlan,
        value: Double,
        baselineValue: Double?,
        unit: String
    ) -> HoloMetricSemantic {
        let operation: HoloMetricOperation
        let resolvedMeasure: HoloMetricMeasure
        switch plan.operation {
        case .correlation:
            operation = .correlation
            resolvedMeasure = .correlation
        case .conditionalAverage:
            operation = .conditionalAverage
            resolvedMeasure = measure(forUnit: unit)
        case .groupComparison:
            operation = .groupComparison
            resolvedMeasure = measure(forUnit: unit)
        }
        let rightDomain = plan.rightSource.split(separator: ".").first.map(String.init) ?? ""
        let semantic = HoloMetricSemantic(
            domain: domain(forDomainString: rightDomain),
            dataset: "\(plan.leftSource)+\(plan.rightSource)",
            measure: resolvedMeasure,
            operation: operation,
            valueRole: .current,
            dimension: nil,
            groupLabel: nil,
            direction: nil,
            currentValue: value,
            baselineValue: baselineValue,
            resultValue: value,
            displayUnit: unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : unit
        )
        assertInvariants(semantic)
        return semantic
    }

    // MARK: 不变量断言

    /// DEBUG 下校验语义不变量：delta/changeRate 必须有非 nil currentValue；direction 与 resultValue 符号一致。
    private static func assertInvariants(_ semantic: HoloMetricSemantic) {
        if semantic.valueRole == .delta || semantic.valueRole == .changeRate {
            if semantic.currentValue == nil {
                assertionFailure("HoloMetricSemantic 不变量违反：\(semantic.valueRole.rawValue) 角色缺少 currentValue（\(semantic.dataset)）")
            }
        }
        if let direction = semantic.direction {
            let value = semantic.resultValue
            switch direction {
            case .increase:
                if value <= 1e-9 {
                    assertionFailure("HoloMetricSemantic 不变量违反：direction=increase 但 resultValue=\(value)")
                }
            case .decrease:
                if value >= -1e-9 {
                    assertionFailure("HoloMetricSemantic 不变量违反：direction=decrease 但 resultValue=\(value)")
                }
            case .flat:
                if abs(value) >= 1e-9 {
                    assertionFailure("HoloMetricSemantic 不变量违反：direction=flat 但 resultValue=\(value)")
                }
            case .unknown:
                break
            }
        }
    }

    // MARK: - 固定工具语义注册表（P3）

    /// 固定工具（finance/habit/task/health）稳定 metricKey 的语义模板。
    /// 闭集、精确匹配、无前缀猜测；新增固定指标必须在此登记，动态指标走查询计划链路，不在此列。
    struct FixedMetricTemplate {
        var domain: HoloEvidenceSourceModule
        var dataset: String
        var operation: HoloMetricOperation
        var valueRole: HoloMetricValueRole
        var dimension: HoloMetricDimension? = nil
        /// 业务量覆盖：nil 时按指标 unit 经 `measure(forUnit:)` 推导。
        var measure: HoloMetricMeasure? = nil
        /// comparison 字段是分组名（如分类名），过滤 "all"/"unknown"/空 后作为 groupLabel。
        var comparisonIsGroupLabel = false
        /// comparison 字段是方向串（increasing/decreasing/stable），解析为 direction。
        var comparisonIsDirection = false
    }

    static let fixedMetricTemplates: [String: FixedMetricTemplate] = [
        // 财务（finance.transactions）
        "finance.total.amount": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.category.amount": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current, dimension: .category, comparisonIsGroupLabel: true),
        // 仅作为事件出现（脱敏账单样例，无数值指标）；登记以保持 outputMetrics 闭集完整。
        "finance.transaction.sample": .init(domain: .finance, dataset: "finance.transactions", operation: .count, valueRole: .current),
        "finance.meal.nighttime_count": .init(domain: .finance, dataset: "finance.transactions", operation: .count, valueRole: .current),
        "finance.category.concentration": .init(domain: .finance, dataset: "finance.transactions", operation: .ratio, valueRole: .share, dimension: .category, measure: .ratio, comparisonIsGroupLabel: true),
        "finance.amount.change": .init(domain: .finance, dataset: "finance.transactions", operation: .difference, valueRole: .delta, comparisonIsDirection: true),
        "finance.keyword.count": .init(domain: .finance, dataset: "finance.transactions", operation: .count, valueRole: .current),
        "finance.keyword.amount": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.budget.total": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.budget.spent": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.budget.remaining": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.budget.progress": .init(domain: .finance, dataset: "finance.transactions", operation: .ratio, valueRole: .current),
        // 分类预算对比：支撑"哪类超预算"的预算口径归因。comparison 为分类名。
        "finance.budget.category.spent": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current, dimension: .category, comparisonIsGroupLabel: true),
        "finance.budget.category.remaining": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current, dimension: .category, comparisonIsGroupLabel: true),
        "finance.budget.category.progress": .init(domain: .finance, dataset: "finance.transactions", operation: .ratio, valueRole: .current, dimension: .category, measure: .ratio, comparisonIsGroupLabel: true),
        "finance.account.count": .init(domain: .finance, dataset: "finance.transactions", operation: .count, valueRole: .current),
        "finance.account.assets": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.account.liabilities": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.account.net_worth": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.current": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.opening": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .baseline),
        "finance.balance.income_total": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.expense_total": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.expense.manual": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.expense.recurring": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current),
        "finance.balance.expense.category": .init(domain: .finance, dataset: "finance.transactions", operation: .sum, valueRole: .current, dimension: .category, comparisonIsGroupLabel: true),
        // 习惯（habit.daily）
        "habit.negative.frequency_change": .init(domain: .habit, dataset: "habit.daily", operation: .difference, valueRole: .delta, comparisonIsDirection: true),
        "habit.negative.over_limit_days": .init(domain: .habit, dataset: "habit.daily", operation: .count, valueRole: .current),
        "habit.negative.control_rate": .init(domain: .habit, dataset: "habit.daily", operation: .ratio, valueRole: .current, measure: .ratio),
        "habit.negative.goal_conflict_days": .init(domain: .habit, dataset: "habit.daily", operation: .count, valueRole: .current),
        "habit.positive.completion_rate": .init(domain: .habit, dataset: "habit.daily", operation: .ratio, valueRole: .current, measure: .ratio),
        "habit.streak_break_days": .init(domain: .habit, dataset: "habit.daily", operation: .count, valueRole: .current),
        // 任务（task.daily）
        "task.today.total": .init(domain: .task, dataset: "task.daily", operation: .count, valueRole: .current),
        "task.today.completed": .init(domain: .task, dataset: "task.daily", operation: .count, valueRole: .current),
        "task.overdue.count": .init(domain: .task, dataset: "task.daily", operation: .count, valueRole: .current),
        "task.backlog.active_count": .init(domain: .task, dataset: "task.daily", operation: .count, valueRole: .current),
        "task.completion.rate": .init(domain: .task, dataset: "task.daily", operation: .ratio, valueRole: .current, measure: .ratio),
        // 健康（health.steps / health.sleep / health.stand / health.activity / health.workout）
        "health.steps.average": .init(domain: .health, dataset: "health.steps", operation: .average, valueRole: .current),
        "health.steps.goal_met_days": .init(domain: .health, dataset: "health.steps", operation: .count, valueRole: .current),
        "health.steps.daily": .init(domain: .health, dataset: "health.steps", operation: .sum, valueRole: .current, dimension: .day),
        "health.sleep.average_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.goal_met_days": .init(domain: .health, dataset: "health.sleep", operation: .count, valueRole: .current),
        "health.sleep.low_days": .init(domain: .health, dataset: "health.sleep", operation: .count, valueRole: .current),
        "health.sleep.recorded_nights": .init(domain: .health, dataset: "health.sleep", operation: .count, valueRole: .current),
        // 波动类指标是周期内统计量，operation 枚举无 stddev，取最近聚合 average。
        "health.sleep.duration_variation_minutes": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.deep_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.core_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.rem_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.awake_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.in_bed_hours": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.efficiency": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.average_bedtime_minutes": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.average_wake_minutes": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.bedtime_variation_minutes": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.wake_variation_minutes": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.interruptions": .init(domain: .health, dataset: "health.sleep", operation: .average, valueRole: .current),
        "health.sleep.hours": .init(domain: .health, dataset: "health.sleep", operation: .sum, valueRole: .current, dimension: .day),
        "health.stand.average_hours": .init(domain: .health, dataset: "health.stand", operation: .average, valueRole: .current),
        "health.stand.goal_met_days": .init(domain: .health, dataset: "health.stand", operation: .count, valueRole: .current),
        "health.stand.hours": .init(domain: .health, dataset: "health.stand", operation: .sum, valueRole: .current, dimension: .day),
        "health.activity.average_minutes": .init(domain: .health, dataset: "health.activity", operation: .average, valueRole: .current),
        "health.activity.goal_met_days": .init(domain: .health, dataset: "health.activity", operation: .count, valueRole: .current),
        "health.activity.minutes": .init(domain: .health, dataset: "health.activity", operation: .sum, valueRole: .current, dimension: .day),
        "health.workout.total_minutes": .init(domain: .health, dataset: "health.workout", operation: .sum, valueRole: .current),
        "health.workout.session_count": .init(domain: .health, dataset: "health.workout", operation: .count, valueRole: .current),
        "health.workout.active_days": .init(domain: .health, dataset: "health.workout", operation: .count, valueRole: .current),
        "health.workout.daily_minutes": .init(domain: .health, dataset: "health.workout", operation: .sum, valueRole: .current, dimension: .day)
    ]

    /// 固定工具指标语义：精确命中注册表才产出，未知 key 返回 nil（不猜）。
    /// delta 角色的 currentValue 由 value + baselineValue 复算（工具产出的是差值与基线）。
    static func fixedMetricSemantic(
        metricKey: String,
        value: Double,
        unit: String?,
        baselineValue: Double?,
        comparison: String?
    ) -> HoloMetricSemantic? {
        guard let template = fixedMetricTemplates[metricKey] else { return nil }
        let groupLabel: String?
        if template.comparisonIsGroupLabel {
            let trimmed = comparison?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            groupLabel = trimmed.isEmpty
                || trimmed.lowercased() == "all"
                || trimmed.lowercased() == "unknown" ? nil : trimmed
        } else {
            groupLabel = nil
        }
        let direction: HoloMetricDirection?
        if template.comparisonIsDirection {
            switch comparison?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "increasing": direction = .increase
            case "decreasing": direction = .decrease
            case "stable": direction = .flat
            default: direction = nil
            }
        } else {
            direction = nil
        }
        let currentValue = template.valueRole == .delta
            ? baselineValue.map { value + $0 } ?? value
            : value
        let resolvedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let semantic = HoloMetricSemantic(
            domain: template.domain,
            dataset: template.dataset,
            measure: template.measure ?? measure(forUnit: unit),
            operation: template.operation,
            valueRole: template.valueRole,
            dimension: template.dimension,
            groupLabel: groupLabel,
            direction: direction,
            currentValue: currentValue,
            baselineValue: baselineValue,
            resultValue: value,
            displayUnit: resolvedUnit?.isEmpty == false ? resolvedUnit : nil
        )
        assertInvariants(semantic)
        return semantic
    }

    /// 固定工具事件级语义：只覆盖事件值与同名指标含义不同的 key（每日原始数据点），
    /// 避免 Runtime 回退把汇总/差值指标语义错挂到原始点上；其余事件返回 nil，
    /// 由 `HoloLocalAgentRuntime.evidenceRecords` 回退到同 metricKey 的指标语义。
    static func fixedEventSemantic(
        for event: HoloEvidenceEvent,
        metrics: [HoloMetric]
    ) -> HoloMetricSemantic? {
        guard let key = event.metricKey,
              let value = event.metricValue,
              value.isFinite else { return nil }
        switch key {
        case "health.steps.daily", "health.sleep.hours", "health.stand.hours",
             "health.activity.minutes", "health.workout.daily_minutes":
            // 每日原始数据点：day 维度 + 日期标签（可排序），支撑 trend 模式。
            guard let template = fixedMetricTemplates[key] else { return nil }
            let semantic = HoloMetricSemantic(
                domain: template.domain,
                dataset: template.dataset,
                measure: template.measure ?? measure(forUnit: dailyEventUnit(for: key)),
                operation: template.operation,
                valueRole: .current,
                dimension: .day,
                groupLabel: event.occurredAt.map(dayLabel(for:)),
                direction: nil,
                currentValue: value,
                baselineValue: nil,
                resultValue: value,
                displayUnit: dailyEventUnit(for: key)
            )
            assertInvariants(semantic)
            return semantic
        case "task.completion.rate":
            // 事件值是每日完成数（条），同名指标是完成率（比例），语义不同必须分开。
            let semantic = HoloMetricSemantic(
                domain: .task,
                dataset: "task.daily",
                measure: .count,
                operation: .count,
                valueRole: .current,
                dimension: .day,
                groupLabel: event.occurredAt.map(dayLabel(for:)),
                direction: nil,
                currentValue: value,
                baselineValue: nil,
                resultValue: value,
                displayUnit: "条"
            )
            assertInvariants(semantic)
            return semantic
        case "habit.negative.frequency_change", "habit.positive.completion_rate":
            // 事件值是当日发生/完成次数，同名指标是差值/比率，语义不同必须分开。
            let semantic = HoloMetricSemantic(
                domain: .habit,
                dataset: "habit.daily",
                measure: .count,
                operation: .count,
                valueRole: .current,
                dimension: nil,
                groupLabel: nil,
                direction: nil,
                currentValue: value,
                baselineValue: nil,
                resultValue: value,
                displayUnit: "次"
            )
            assertInvariants(semantic)
            return semantic
        default:
            return nil
        }
    }

    /// 固定工具结果统一挂语义：指标按注册表精确匹配；事件只处理上表列出的原始数据点 key。
    /// 已带 semantic 的指标/事件（如构造期显式挂上的分组事件）保持不变。
    static func attachFixedToolSemantics(to result: HoloDataToolResult) -> HoloDataToolResult {
        var result = result
        result.metrics = result.metrics.map { metric in
            var metric = metric
            if metric.semantic == nil,
               let value = metric.value,
               value.isFinite {
                metric.semantic = fixedMetricSemantic(
                    metricKey: metric.metricKey,
                    value: value,
                    unit: metric.unit,
                    baselineValue: metric.baselineValue,
                    comparison: metric.comparison
                )
            }
            return metric
        }
        let metrics = result.metrics
        result.events = result.events.map { event in
            var event = event
            if event.semantic == nil {
                event.semantic = fixedEventSemantic(for: event, metrics: metrics)
            }
            return event
        }
        return result
    }

    /// 每日原始数据点事件的单位（事件本身不带 unit，key 与单位是编译期确定的）。
    private static func dailyEventUnit(for metricKey: String) -> String? {
        switch metricKey {
        case "health.steps.daily": return "步"
        case "health.sleep.hours", "health.stand.hours": return "小时"
        case "health.activity.minutes", "health.workout.daily_minutes": return "分钟"
        default: return nil
        }
    }

    /// day 维度的分组标签：ISO 日期字典序与时间序一致，供 trend 排序。
    private static func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
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
        let schema = catalog.schema(named: plan.source)
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
                let roundedValue = rounded(value)
                let roundedBaseline = baselineValue.map(rounded)
                metrics.append(HoloMetric(
                    metricKey: key,
                    value: roundedValue,
                    unit: aggregation.unit,
                    baselineValue: roundedBaseline,
                    comparison: bucket.key == "all" ? nil : bucket.key,
                    formula: formula(aggregation),
                    sourceRecordIDs: sourceIDs,
                    semantic: HoloMetricSemanticFactory.aggregationSemantic(
                        plan: plan,
                        schema: schema,
                        aggregation: aggregation,
                        bucketKey: bucket.key,
                        value: roundedValue,
                        baselineValue: roundedBaseline
                    )
                ))
            }
        }

        for derivation in plan.derivations {
            metrics.append(contentsOf: derive(derivation, plan: plan, schema: schema, metrics: metrics, current: current, calendar: calendar))
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
                sourceRecordIDs: metric.sourceRecordIDs,
                semantic: metric.semantic
            )
        }
        return HoloDynamicExecutionOutput(
            metrics: metrics,
            events: events,
            coverage: coverage(
                rows: current,
                range: plan.timeRange,
                calendar: calendar,
                semantics: schema?.resolvedCoverageSemantics ?? .eventRecords
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
        schema: HoloDataSetSchema?,
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
                value = coverage(
                    rows: current,
                    range: plan.timeRange,
                    calendar: calendar,
                    semantics: schema?.resolvedCoverageSemantics ?? .eventRecords
                )?.coverageRatio
                formula = "covered_days / total_days"
            }
            guard let value else { return nil }
            let group = metric.comparison ?? "all"
            let roundedValue = rounded(value)
            return HoloMetric(
                metricKey: metricKey(source: plan.source, id: spec.id, group: group),
                value: roundedValue,
                unit: spec.unit,
                baselineValue: nil,
                comparison: metric.comparison,
                formula: formula,
                sourceRecordIDs: metric.sourceRecordIDs,
                semantic: HoloMetricSemanticFactory.derivationSemantic(
                    plan: plan,
                    schema: schema,
                    derivation: spec,
                    source: metric,
                    groupKey: group,
                    value: roundedValue
                )
            )
        }
    }

    private static func coverage(
        rows: [HoloQueryRow],
        range: HoloAgentTimeRange?,
        calendar: Calendar,
        semantics: HoloDataCoverageSemantics
    ) -> HoloDataCoverage? {
        guard semantics == .dailyObservations else { return nil }
        guard let range, let start = range.start, let end = range.end else { return nil }
        let total = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1)
        let covered = Set(rows.map { calendar.startOfDay(for: $0.occurredAt) }).count
        return HoloDataCoverage(
            coveredDays: covered,
            totalDays: total,
            coverageRatio: Double(covered) / Double(total),
            missingRanges: [],
            note: "已读取 \(covered)/\(total) 天数据",
            semantics: .dailyObservations
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
