//
//  FlexibleQueryPlanner.swift
//  Holo
//
//  灵活查询规划器
//  Planner + PromptBuilder + Validator
//

import Foundation
import os.log

// MARK: - Deterministic Merchant Aggregate Resolver

/// 只处理字段完整、无需模型推断的商户次数/总额/均价查询。
nonisolated enum MerchantAggregatePlanResolver {
    static func resolve(
        userQuestion: String,
        extractedData: [String: String]?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FlexibleQueryPlan? {
        let contextText = ([userQuestion] + (extractedData?.values.map { $0 } ?? []))
            .joined(separator: " ")

        guard !containsTrendIntent(contextText),
              requestsCount(contextText),
              requestsTotal(contextText),
              let averageUnit = averageUnit(in: contextText),
              let merchant = merchantName(from: extractedData),
              let dateRange = FlexibleQueryDateRangeResolver.resolve(
                text: contextText,
                now: now,
                calendar: calendar
              ) else {
            return nil
        }

        return FlexibleQueryPlan(
            domain: .finance,
            operation: .sumAmount,
            filters: FinanceQueryFilters(
                type: .expense,
                amountGreaterThan: nil,
                amountGreaterThanOrEqual: nil,
                amountLessThan: nil,
                amountLessThanOrEqual: nil,
                amountEqual: nil,
                keywords: [merchant],
                excludedKeywords: [],
                categoryNames: [],
                startDate: dateRange.startDate,
                endDate: dateRange.endDate,
                accountNames: [],
                includeNote: true,
                includeRemark: true,
                includeTags: true,
                includeCategory: true
            ),
            calculation: .averageAmount,
            averageUnit: averageUnit,
            sort: FlexibleQuerySort(field: .date, direction: .desc),
            limit: 20,
            explanationHints: []
        )
    }

    private static func merchantName(from extractedData: [String: String]?) -> String? {
        let keys = ["categoryHint", "categoryCandidate", "merchant", "keyword"]
        let genericValues: Set<String> = ["餐饮", "消费", "支出", "快餐"]

        for key in keys {
            guard let raw = extractedData?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  !genericValues.contains(raw),
                  raw.count <= 20 else {
                continue
            }
            return raw
        }
        return nil
    }

    private static func requestsCount(_ text: String) -> Bool {
        matches(text, pattern: "(多少|消费|购买|吃了).{0,4}(顿|吨|次|笔)|次数")
    }

    private static func requestsTotal(_ text: String) -> Bool {
        matches(text, pattern: "花了多少钱|总花费|总额|合计|消费金额")
    }

    private static func averageUnit(in text: String) -> FlexibleQueryAverageUnit? {
        if matches(text, pattern: "平均.{0,3}(顿|吨)|每顿") {
            return .meal
        }
        if matches(text, pattern: "平均.{0,3}次|每次") {
            return .occurrence
        }
        if matches(text, pattern: "平均.{0,3}笔|每笔") {
            return .transaction
        }
        return nil
    }

    private static func containsTrendIntent(_ text: String) -> Bool {
        ["趋势", "变化", "结构", "占比", "复盘", "分析"].contains { text.contains($0) }
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Planner

final class FlexibleQueryPlanner {
    private let logger = Logger(subsystem: "com.holo.app", category: "FlexibleQueryPlanner")
    private let provider: AIProvider

    init(provider: AIProvider) {
        self.provider = provider
    }

    /// 两段式规划：用独立 prompt 让 LLM 输出结构化 Query Plan
    func plan(userQuestion: String, extractedData: [String: String]?, userContext: UserContext) async throws -> FlexiblePlannerResult {
        let rawResult: FlexiblePlannerResult
        if let deterministicPlan = MerchantAggregatePlanResolver.resolve(
            userQuestion: userQuestion,
            extractedData: extractedData
        ) {
            rawResult = FlexiblePlannerResult(
                status: .ready,
                clarificationQuestion: nil,
                plan: deterministicPlan
            )
        } else {
            let prompt = buildPlannerPrompt(userQuestion: userQuestion, extractedData: extractedData)

            // 使用非流式 chat completion 获取 JSON plan
            let plannerJSON = try await requestPlannerCompletion(prompt: prompt, userContext: userContext)

            // 解码 Planner 输出
            rawResult = try decodePlannerOutput(plannerJSON)
        }

        return try Self.finalize(result: rawResult, userQuestion: userQuestion)
    }

    /// 所有 Planner 路径的统一出口：用户明确时间优先于模型推断。
    static func finalize(
        result: FlexiblePlannerResult,
        userQuestion: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> FlexiblePlannerResult {
        guard result.status == .ready, let rawPlan = result.plan else {
            return result
        }

        let plan = FlexibleQueryPlanDateNormalizer.normalize(
            plan: rawPlan,
            userQuestion: userQuestion,
            now: now,
            calendar: calendar
        )
        try validate(plan: plan, calendar: calendar)

        return FlexiblePlannerResult(
            status: result.status,
            clarificationQuestion: result.clarificationQuestion,
            plan: plan
        )
    }

    // MARK: - Prompt Builder

    private func buildPlannerPrompt(userQuestion: String, extractedData: [String: String]?) -> String {
        let intentInfo: String
        if let data = extractedData {
            let pairs = data.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            intentInfo = "意图识别提取数据：{\(pairs)}"
        } else {
            intentInfo = "（无额外提取数据）"
        }

        return """
        用户问题：「\(userQuestion)」
        \(intentInfo)
        """
    }

    // MARK: - LLM Completion

    private func requestPlannerCompletion(prompt: String, userContext: UserContext) async throws -> String {
        try await provider.completeFlexibleQueryPlan(prompt: prompt, userContext: userContext)
    }

    // MARK: - JSON Decode

    private func decodePlannerOutput(_ jsonString: String) throws -> FlexiblePlannerResult {
        // 清理可能的 markdown 代码块包裹
        let cleaned = jsonString
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw FlexibleQueryDecodeError.invalidUTF8
        }

        let dto = try JSONDecoder().decode(PlannerOutputDTO.self, from: data)

        let status = FlexiblePlannerStatus(rawValue: dto.status) ?? .unsupported
        let plan = dto.plan.map { Self.dtoToPlan($0) }

        return FlexiblePlannerResult(
            status: status,
            clarificationQuestion: dto.clarificationQuestion,
            plan: plan
        )
    }

    // MARK: - DTO Mapping

    private struct PlannerOutputDTO: Codable {
        let status: String
        let clarificationQuestion: String?
        let plan: PlanDTO?
    }

    private struct PlanDTO: Codable {
        let domain: String
        let operation: String
        let filters: FiltersDTO
        let calculation: String?
        let averageUnit: String?
        let sort: SortDTO?
        let limit: Int?
        let explanationHints: [ExplanationHint]?
    }

    private struct FiltersDTO: Codable {
        let type: String?
        let amountGreaterThan: Decimal?
        let amountGreaterThanOrEqual: Decimal?
        let amountLessThan: Decimal?
        let amountLessThanOrEqual: Decimal?
        let amountEqual: Decimal?
        let keywords: [String]?
        let excludedKeywords: [String]?
        let categoryNames: [String]?
        let startDate: String?
        let endDate: String?
        let accountNames: [String]?
        let includeNote: Bool?
        let includeRemark: Bool?
        let includeTags: Bool?
        let includeCategory: Bool?
    }

    private struct SortDTO: Codable {
        let field: String
        let direction: String
    }

    private static func dtoToPlan(_ dto: PlanDTO) -> FlexibleQueryPlan {
        let filters = FinanceQueryFilters(
            type: dto.filters.type.flatMap { TransactionTypeFilter(rawValue: $0) },
            amountGreaterThan: dto.filters.amountGreaterThan,
            amountGreaterThanOrEqual: dto.filters.amountGreaterThanOrEqual,
            amountLessThan: dto.filters.amountLessThan,
            amountLessThanOrEqual: dto.filters.amountLessThanOrEqual,
            amountEqual: dto.filters.amountEqual,
            keywords: dto.filters.keywords ?? [],
            excludedKeywords: dto.filters.excludedKeywords ?? [],
            categoryNames: dto.filters.categoryNames ?? [],
            startDate: dto.filters.startDate,
            endDate: dto.filters.endDate,
            accountNames: dto.filters.accountNames ?? [],
            includeNote: dto.filters.includeNote ?? true,
            includeRemark: dto.filters.includeRemark ?? true,
            includeTags: dto.filters.includeTags ?? true,
            includeCategory: dto.filters.includeCategory ?? true
        )

        let sort = dto.sort.flatMap { s -> FlexibleQuerySort? in
            guard let field = FlexibleQuerySortField(rawValue: s.field),
                  let dir = FlexibleQuerySortDirection(rawValue: s.direction) else { return nil }
            return FlexibleQuerySort(field: field, direction: dir)
        }

        return FlexibleQueryPlan(
            domain: FlexibleQueryDomain(rawValue: dto.domain) ?? .finance,
            operation: FlexibleQueryOperation(rawValue: dto.operation) ?? .listTransactions,
            filters: filters,
            calculation: dto.calculation.flatMap { FlexibleQueryCalculation(rawValue: $0) },
            averageUnit: dto.averageUnit.flatMap { FlexibleQueryAverageUnit(rawValue: $0) },
            sort: sort,
            limit: dto.limit,
            explanationHints: dto.explanationHints ?? []
        )
    }

    // MARK: - Validator

    static func validate(
        plan: FlexibleQueryPlan,
        calendar: Calendar = .current
    ) throws {
        // 1. 只允许 finance 域
        guard plan.domain == .finance else {
            throw FlexibleQueryPlanValidationError.unsupportedDomain
        }

        // 2. limit 上限 50
        if let limit = plan.limit, limit > 50 {
            throw FlexibleQueryPlanValidationError.unsafeLimit
        }

        // 3. 日期范围校验：非法日期不能被执行器静默忽略成全历史查询
        let startDate = try plan.filters.startDate.map {
            try FlexibleQueryDateCodec.parse($0, calendar: calendar)
        }
        let endDate = try plan.filters.endDate.map {
            try FlexibleQueryDateCodec.parse($0, calendar: calendar)
        }
        if let startDate, let endDate, startDate > endDate {
            throw FlexibleQueryPlanValidationError.invalidDateRange
        }

        // 4. keywords 数量和长度
        if plan.filters.keywords.count > 10 {
            throw FlexibleQueryPlanValidationError.tooManyKeywords
        }
        if plan.filters.keywords.contains(where: { $0.count > 20 }) {
            throw FlexibleQueryPlanValidationError.keywordTooLong
        }

        // 5. categoryName 长度
        if plan.filters.categoryNames.contains(where: { $0.count > 30 }) {
            throw FlexibleQueryPlanValidationError.categoryNameTooLong
        }

        // 6. 金额合理性
        if let amount = plan.filters.amountGreaterThan, amount < 0 || amount > 1_000_000 {
            throw FlexibleQueryPlanValidationError.hardcodedValueDetected
        }
        if let amount = plan.filters.amountLessThan, amount < 0 || amount > 1_000_000 {
            throw FlexibleQueryPlanValidationError.hardcodedValueDetected
        }
        if let amount = plan.filters.amountGreaterThanOrEqual, amount < 0 || amount > 1_000_000 {
            throw FlexibleQueryPlanValidationError.hardcodedValueDetected
        }

        // 7. excludedKeywords 数量
        if plan.filters.excludedKeywords.count > 20 {
            throw FlexibleQueryPlanValidationError.hardcodedValueDetected
        }

        // 8. 操作与过滤条件一致性
        let hasNoFilters = plan.filters.keywords.isEmpty
            && plan.filters.categoryNames.isEmpty
            && plan.filters.amountGreaterThan == nil
            && plan.filters.amountGreaterThanOrEqual == nil
            && plan.filters.amountLessThan == nil
            && plan.filters.amountLessThanOrEqual == nil
            && plan.filters.amountEqual == nil
            && plan.filters.startDate == nil
            && plan.filters.endDate == nil

        if hasNoFilters && plan.operation != .listTransactions {
            throw FlexibleQueryPlanValidationError.operationFilterMismatch
        }
    }
}

// MARK: - Decode Error

enum FlexibleQueryDecodeError: Error, LocalizedError {
    case invalidUTF8
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Planner 输出包含无效字符"
        case .invalidJSON: return "Planner 输出不是有效 JSON"
        }
    }
}
