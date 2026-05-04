//
//  AIParseBatchValidator.swift
//  Holo
//
//  解析结果校验器（简化版）
//  在执行前校验科目白名单、必填字段、金额非负
//

import Foundation

/// 解析结果校验器
enum AIParseBatchValidator {

    /// 校验问题码
    enum IssueCode: String {
        case missingRequiredField
        case negativeAmount
        case categoryCandidateUnmatched
    }

    /// 单条校验问题
    struct ValidationIssue {
        let itemIndex: Int
        let field: String
        let code: IssueCode
        let message: String
    }

    /// 校验结果
    struct ValidationResult {
        let issues: [ValidationIssue]
        var isValid: Bool { issues.isEmpty }

        /// 指定 item 是否有指定类型的校验问题
        func hasIssue(at index: Int, code: IssueCode) -> Bool {
            issues.contains { $0.itemIndex == index && $0.code == code }
        }
    }

    // MARK: - Public API

    /// 校验批量解析结果
    /// - Parameter batch: AI 批量解析结果
    /// - Returns: 校验结果（包含所有发现的问题）
    static func validate(batch: AIParseBatch) -> ValidationResult {
        var issues: [ValidationIssue] = []

        for (index, item) in batch.items.enumerated() {
            validateRequiredFields(item: item, index: index, issues: &issues)
            validateAmount(item: item, index: index, issues: &issues)
            validateCategory(item: item, index: index, issues: &issues)
        }

        return ValidationResult(issues: issues)
    }

    // MARK: - Required Fields

    /// 各意图的必填字段
    private static let requiredFields: [AIIntent: [String]] = [
        .recordExpense: ["amount"],
        .recordIncome: ["amount"],
        .createTask: ["title"],
        .checkIn: ["habitName"],
        .recordWeight: ["weight"]
    ]

    private static func validateRequiredFields(
        item: AIParseItem,
        index: Int,
        issues: inout [ValidationIssue]
    ) {
        guard let fields = requiredFields[item.intent] else { return }

        for field in fields {
            let value = item.extractedData?[field]
            if value == nil || value?.isEmpty == true {
                issues.append(ValidationIssue(
                    itemIndex: index,
                    field: field,
                    code: .missingRequiredField,
                    message: "缺少必填字段：\(field)"
                ))
            }
        }
    }

    // MARK: - Amount

    private static func validateAmount(
        item: AIParseItem,
        index: Int,
        issues: inout [ValidationIssue]
    ) {
        guard item.intent.isFinance,
              let amountStr = item.extractedData?["amount"],
              let amount = Decimal(string: amountStr) else { return }

        if amount < 0 {
            issues.append(ValidationIssue(
                itemIndex: index,
                field: "amount",
                code: .negativeAmount,
                message: "金额不能为负数"
            ))
        }
    }

    // MARK: - Category

    private static func validateCategory(
        item: AIParseItem,
        index: Int,
        issues: inout [ValidationIssue]
    ) {
        guard item.intent.isFinance else { return }

        let candidate = item.extractedData?["categoryCandidate"]
        let primary = item.extractedData?["primaryCategory"]
        let sub = item.extractedData?["subCategory"]

        // 有 categoryCandidate 但科目表字段为空 → 未匹配
        if let candidate, !candidate.isEmpty,
           (primary == nil || primary!.isEmpty) && (sub == nil || sub!.isEmpty) {
            issues.append(ValidationIssue(
                itemIndex: index,
                field: "categoryCandidate",
                code: .categoryCandidateUnmatched,
                message: "分类候选「\(candidate)」未在科目表中匹配到"
            ))
        }
    }
}
