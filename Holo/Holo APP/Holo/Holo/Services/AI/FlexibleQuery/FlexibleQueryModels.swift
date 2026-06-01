//
//  FlexibleQueryModels.swift
//  Holo
//
//  灵活数据查询的数据模型
//  Plan / Result / Filters / Evidence / 枚举
//

import Foundation

// MARK: - Query Plan

/// 灵活查询计划
struct FlexibleQueryPlan: Codable, Equatable, Sendable {
    let domain: FlexibleQueryDomain
    let operation: FlexibleQueryOperation
    let filters: FinanceQueryFilters
    let calculation: FlexibleQueryCalculation?
    let sort: FlexibleQuerySort?
    let limit: Int?
    let explanationHints: [ExplanationHint]
}

// MARK: - Domain & Operation

enum FlexibleQueryDomain: String, Codable, Sendable {
    case finance
}

enum FlexibleQueryOperation: String, Codable, Sendable {
    case findLatestTransaction
    case findEarliestTransaction
    case countTransactions
    case sumAmount
    case maxTransaction
    case minTransaction
    case rankByDay
    case listTransactions
}

enum FlexibleQueryCalculation: String, Codable, Sendable {
    case elapsedTimeSinceTransaction
    case daysBetweenTransactions
    case averageAmount
    case none
}

// MARK: - Sort

struct FlexibleQuerySort: Codable, Equatable, Sendable {
    let field: FlexibleQuerySortField
    let direction: FlexibleQuerySortDirection
}

enum FlexibleQuerySortField: String, Codable, Sendable {
    case date
    case amount
}

enum FlexibleQuerySortDirection: String, Codable, Sendable {
    case asc
    case desc
}

// MARK: - Filters

struct FinanceQueryFilters: Codable, Equatable, Sendable {
    let type: TransactionTypeFilter?
    let amountGreaterThan: Decimal?
    let amountGreaterThanOrEqual: Decimal?
    let amountLessThan: Decimal?
    let amountLessThanOrEqual: Decimal?
    let amountEqual: Decimal?
    let keywords: [String]
    let excludedKeywords: [String]
    let categoryNames: [String]
    let startDate: String?
    let endDate: String?
    let accountNames: [String]
    let includeNote: Bool
    let includeRemark: Bool
    let includeTags: Bool
    let includeCategory: Bool
}

enum TransactionTypeFilter: String, Codable, Sendable {
    case expense
    case income
    case any
}

// MARK: - ExplanationHint

/// 结构化 hint：替代自由文本，避免 planner-answer builder 隐性契约
/// 带关联值的 enum 不能自动合成 Codable，需手写序列化
enum ExplanationHint: Equatable, Sendable {
    case approximateConstraint(field: String, reason: String)
    case lowConfidenceMatch(fields: [String])
    case inferredCategory(synonym: String, target: String)
    case noExplicitRecord(note: String)
}

// MARK: - ExplanationHint Codable

extension ExplanationHint: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case field
        case reason
        case fields
        case synonym
        case target
        case note
    }

    // Planner LLM 输出 JSON 格式：{ "approximateConstraint": { "field": "...", "reason": "..." } }
    // 即单 key 对象，key 即类型
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let ac = try? container.decode([String: ApproximateConstraintDTO].self),
           let value = ac["approximateConstraint"] {
            self = .approximateConstraint(field: value.field, reason: value.reason)
            return
        }
        if let lcm = try? container.decode([String: LowConfidenceMatchDTO].self),
           let value = lcm["lowConfidenceMatch"] {
            self = .lowConfidenceMatch(fields: value.fields)
            return
        }
        if let ic = try? container.decode([String: InferredCategoryDTO].self),
           let value = ic["inferredCategory"] {
            self = .inferredCategory(synonym: value.synonym, target: value.target)
            return
        }
        if let ner = try? container.decode([String: NoExplicitRecordDTO].self),
           let value = ner["noExplicitRecord"] {
            self = .noExplicitRecord(note: value.note)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown ExplanationHint type")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .approximateConstraint(let field, let reason):
            try container.encode(["approximateConstraint": ApproximateConstraintDTO(field: field, reason: reason)])
        case .lowConfidenceMatch(let fields):
            try container.encode(["lowConfidenceMatch": LowConfidenceMatchDTO(fields: fields)])
        case .inferredCategory(let synonym, let target):
            try container.encode(["inferredCategory": InferredCategoryDTO(synonym: synonym, target: target)])
        case .noExplicitRecord(let note):
            try container.encode(["noExplicitRecord": NoExplicitRecordDTO(note: note)])
        }
    }

    private struct ApproximateConstraintDTO: Codable {
        let field: String
        let reason: String
    }
    private struct LowConfidenceMatchDTO: Codable {
        let fields: [String]
    }
    private struct InferredCategoryDTO: Codable {
        let synonym: String
        let target: String
    }
    private struct NoExplicitRecordDTO: Codable {
        let note: String
    }
}

// MARK: - Planner Result

/// Planner 输出结果
struct FlexiblePlannerResult: Equatable, Sendable {
    let status: FlexiblePlannerStatus
    let clarificationQuestion: String?
    let plan: FlexibleQueryPlan?
}

enum FlexiblePlannerStatus: String, Codable, Sendable {
    case ready
    case needsClarification = "needs_clarification"
    case unsupported
}

// MARK: - Query Result

/// 执行器输出
struct FlexibleQueryResult: Codable, Equatable, Sendable {
    let plan: FlexibleQueryPlan
    let status: FlexibleQueryStatus
    let summary: FlexibleQuerySummary
    let matchedTransactions: [FlexibleTransactionEvidence]
    let calculationResult: FlexibleCalculationResult?
    let emptyReason: String?
    let followUpSuggestion: FlexibleQueryFollowUp?
}

enum FlexibleQueryStatus: String, Codable, Sendable {
    case success
    case empty
    case ambiguous
    case unsupported
    case failed
}

// MARK: - Summary

struct FlexibleQuerySummary: Codable, Equatable, Sendable {
    let totalMatched: Int
    let totalAmount: Decimal?
    let dateRange: String?
    let topCategory: String?
}

// MARK: - Evidence

struct FlexibleTransactionEvidence: Codable, Equatable, Sendable {
    let id: String
    let date: String
    let amount: Decimal
    let type: String
    let note: String?
    let remark: String?
    let tags: [String]
    let primaryCategory: String?
    let subCategory: String?
    let matchedFields: [String]
    let matchReason: String
}

// MARK: - Calculation Result

struct FlexibleCalculationResult: Codable, Equatable, Sendable {
    let type: FlexibleQueryCalculation
    let valueText: String
    let days: Int?
    let amount: Decimal?
    let count: Int?
    let date: String?
}

// MARK: - Follow Up

struct FlexibleQueryFollowUp: Codable, Equatable, Sendable {
    let question: String
    let relaxedPlan: FlexibleQueryPlan?
}

// MARK: - Validation Error

enum FlexibleQueryPlanValidationError: Error, LocalizedError {
    case unsupportedDomain
    case unsupportedOperation
    case missingFilters
    case unsafeLimit
    case invalidDateRange
    case unsupportedCalculation
    case tooManyKeywords
    case keywordTooLong
    case categoryNameTooLong
    case hardcodedValueDetected
    case operationFilterMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedDomain: return "不支持的查询域"
        case .unsupportedOperation: return "不支持的操作类型"
        case .missingFilters: return "缺少过滤条件"
        case .unsafeLimit: return "limit 超出安全范围"
        case .invalidDateRange: return "日期范围无效"
        case .unsupportedCalculation: return "不支持的计算类型"
        case .tooManyKeywords: return "关键词数量超过限制（最多10个）"
        case .keywordTooLong: return "关键词长度超过限制（最长20字符）"
        case .categoryNameTooLong: return "分类名长度超过限制（最长30字符）"
        case .hardcodedValueDetected: return "检测到不合理的硬编码数值"
        case .operationFilterMismatch: return "操作类型与过滤条件不匹配"
        }
    }
}
