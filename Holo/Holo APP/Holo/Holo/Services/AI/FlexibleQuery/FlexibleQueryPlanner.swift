//
//  FlexibleQueryPlanner.swift
//  Holo
//
//  灵活查询规划器
//  Planner + PromptBuilder + Validator
//

import Foundation
import os.log

// MARK: - Planner

final class FlexibleQueryPlanner {
    private let logger = Logger(subsystem: "com.holo.app", category: "FlexibleQueryPlanner")
    private let provider: AIProvider

    init(provider: AIProvider) {
        self.provider = provider
    }

    /// 两段式规划：用独立 prompt 让 LLM 输出结构化 Query Plan
    func plan(userQuestion: String, extractedData: [String: String]?) async throws -> FlexiblePlannerResult {
        let prompt = try buildPlannerPrompt(userQuestion: userQuestion, extractedData: extractedData)

        // 使用非流式 chat completion 获取 JSON plan
        let plannerJSON = try await requestPlannerCompletion(prompt: prompt)

        // 解码 Planner 输出
        let result = try decodePlannerOutput(plannerJSON)

        // ready 状态时校验 plan
        if result.status == .ready, let plan = result.plan {
            try Self.validate(plan: plan)
        }

        return result
    }

    // MARK: - Prompt Builder

    private func buildPlannerPrompt(userQuestion: String, extractedData: [String: String]?) throws -> String {
        let template = try PromptManager.shared.loadPrompt(.flexibleQueryPlanner)

        let intentInfo: String
        if let data = extractedData {
            let pairs = data.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            intentInfo = "意图识别提取数据：{\(pairs)}"
        } else {
            intentInfo = "（无额外提取数据）"
        }

        return """
        \(template)

        ## 当前请求

        用户问题：「\(userQuestion)」
        \(intentInfo)
        """
    }

    // MARK: - LLM Completion

    private func requestPlannerCompletion(prompt: String) async throws -> String {
        let messages: [ChatMessageDTO] = [
            ChatMessageDTO(role: "user", content: prompt)
        ]
        let userContext = UserContext.empty

        return try await provider.chat(messages: messages, userContext: userContext)
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
            sort: sort,
            limit: dto.limit,
            explanationHints: dto.explanationHints ?? []
        )
    }

    // MARK: - Validator

    static func validate(plan: FlexibleQueryPlan) throws {
        // 1. 只允许 finance 域
        guard plan.domain == .finance else {
            throw FlexibleQueryPlanValidationError.unsupportedDomain
        }

        // 2. limit 上限 50
        if let limit = plan.limit, limit > 50 {
            throw FlexibleQueryPlanValidationError.unsafeLimit
        }

        // 3. 日期范围校验
        if let start = plan.filters.startDate, let end = plan.filters.endDate {
            if start > end {
                throw FlexibleQueryPlanValidationError.invalidDateRange
            }
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
