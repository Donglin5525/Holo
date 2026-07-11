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
#if DEBUG
            return true
#else
            return false
#endif
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
nonisolated enum HoloDynamicDerivationOperator: String, Codable, Sendable { case difference, ratio, percentageChange, rate, linearTrend, coverage }
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
            coverage: coverage(rows: current, range: plan.timeRange, calendar: calendar)
        )
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

    private static func coverage(rows: [HoloQueryRow], range: HoloAgentTimeRange?, calendar: Calendar) -> HoloDataCoverage? {
        guard let range, let start = range.start, let end = range.end else { return nil }
        let total = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1)
        let covered = Set(rows.map { calendar.startOfDay(for: $0.occurredAt) }).count
        return HoloDataCoverage(coveredDays: covered, totalDays: total, coverageRatio: Double(covered) / Double(total), missingRanges: [], note: "已读取 \(covered)/\(total) 天数据")
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
}
