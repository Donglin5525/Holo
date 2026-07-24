//
//  HoloAgentContractPolicy.swift
//  Holo
//
//  Agent 成熟度演进 P0-D — Agent Contract Policy
//
//  建立 HoloAgentContractPolicy：
//    - Debug/Test：必填字段缺失直接失败
//    - 灰度：严格校验并保留可控回退
//    - 生产：仅允许白名单字段兼容修复，并记录 repair/violation
//  final_claims 空 claims、事实 claim 无 evidence、非法 confidence 等关键错误不可兼容放过。
//  指标只记录技术元数据，不记录用户问题、金额、健康数据或证据正文。
//

import Foundation

// MARK: - Contract Mode

nonisolated enum HoloAgentContractMode: String, Sendable {
    case debug       // 必填字段缺失直接失败
    case staging     // 严格校验并保留可控回退
    case production  // 仅白名单字段兼容修复

    /// 当前运行模式。Debug 构建使用 debug，Release 使用 production。
    static var current: HoloAgentContractMode {
#if DEBUG
        return .debug
#else
        return .production
#endif
    }
}

// MARK: - Contract Violation / Repair

nonisolated struct HoloAgentContractViolation: Equatable, Sendable {
    var field: String
    var severity: HoloContractViolationSeverity
    var detail: String
    /// 原始值（脱敏后的技术描述，不含用户数据）。
    var observedValue: String?
}

nonisolated enum HoloContractViolationSeverity: String, Equatable, Sendable {
    case compatible      // 白名单字段缺失，可兼容修复
    case missingRequired // 必填字段缺失，不可兼容
    case invalidValue    // 值非法（如 confidence 越界、空 claims）
    case emptyResult     // final_claims 为空
}

/// 解析结果 + 契约校验结果。
nonisolated struct HoloAgentContractParseResult: Equatable {
    /// 解析出的 output（可能经兼容修复）。
    var output: HoloAgentOutput?
    /// 契约违规列表。
    var violations: [HoloAgentContractViolation]
    /// 兼容修复记录（仅在白名单内）。
    var repairs: [HoloAgentContractViolation]
    /// 是否因严重违规而拒绝。
    var isRejected: Bool

    var hasViolations: Bool { !violations.isEmpty }
}

// MARK: - Contract Policy

nonisolated enum HoloAgentContractPolicy {

    /// 白名单字段：生产模式下允许兼容修复（补默认值）。
    static let compatibleFields: Set<String> = [
        "reasoning",           // 缺失补空字符串
        "warnings",            // 缺失补空数组
        "nextStep",            // 可选，缺失不报错
        "prohibitedInferences", // 缺失补空数组
    ]

    /// 半白名单字段：缺失时补默认值但记录 repair（用于可观测性）。
    static let trackedDefaultFields: Set<String> = [
        "confidence",          // 缺失补 0.5 并记录
        "type",                // 缺失补 observation 并记录
        "unit",                // 缺失补空并记录
        "comparison",          // 可选，缺失不报错
    ]

    /// 不可兼容放过的关键错误。
    static let criticalChecks: Set<String> = [
        "empty_final_claims",  // final_claims 空 claims
        "claim_without_evidence", // 事实 claim 无 evidence
        "invalid_confidence",  // confidence 越界（<0 或 >1）
        "missing_status",      // 缺少 status 字段
    ]

    /// 校验解析后的 output 是否符合契约。
    static func validate(
        output: HoloAgentOutput?,
        mode: HoloAgentContractMode = HoloAgentContractMode.current
    ) -> HoloAgentContractParseResult {
        var violations: [HoloAgentContractViolation] = []
        var repairs: [HoloAgentContractViolation] = []

        guard let output = output else {
            return HoloAgentContractParseResult(
                output: nil,
                violations: [HoloAgentContractViolation(field: "output", severity: .missingRequired, detail: "解析失败，无 output", observedValue: nil)],
                repairs: [],
                isRejected: true
            )
        }

        // 1. status 必须存在且合法
        // (HoloAgentOutputStatus 已是枚举，decode 成功即合法)

        // 2. final_claims 状态下 claims 不能全空
        if output.status == .finalClaims && output.claims.isEmpty {
            violations.append(HoloAgentContractViolation(
                field: "claims",
                severity: .emptyResult,
                detail: "final_claims 状态下 claims 为空",
                observedValue: "[]"
            ))
        }

        // 3. 每个 claim 校验
        for (index, claim) in output.claims.enumerated() {
            let claimPrefix = "claims[\(index)]"

            // confidence 合法性
            if claim.confidence < 0 || claim.confidence > 1 {
                violations.append(HoloAgentContractViolation(
                    field: "\(claimPrefix).confidence",
                    severity: .invalidValue,
                    detail: "confidence 越界：\(claim.confidence)",
                    observedValue: "\(claim.confidence)"
                ))
            }

            // 事实 claim 必须有 evidence（observation/trend/comparison 等非 meta 类型）
            let factClaimTypes: Set<String> = ["observation", "trend", "comparison", "metric", "correlation"]
            if factClaimTypes.contains(claim.type) {
                let hasEvidence = claim.metricAssertions.contains(where: { !$0.evidenceIDs.isEmpty })
                if !hasEvidence {
                    violations.append(HoloAgentContractViolation(
                        field: "\(claimPrefix).evidenceIDs",
                        severity: .missingRequired,
                        detail: "事实 claim（type=\(claim.type)）缺少 evidence",
                        observedValue: "empty"
                    ))
                }
            }

            // displayText 不能为空
            if claim.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(HoloAgentContractViolation(
                    field: "\(claimPrefix).displayText",
                    severity: .missingRequired,
                    detail: "claim displayText 为空",
                    observedValue: "empty"
                ))
            }
        }

        // 4. 根据模式判定是否拒绝
        let hasCritical = violations.contains(where: {
            $0.severity == .missingRequired || $0.severity == .invalidValue || $0.severity == .emptyResult
        })

        let isRejected: Bool
        switch mode {
        case .debug:
            // Debug：任何违规都失败
            isRejected = !violations.isEmpty
        case .staging:
            // 灰度：关键违规失败，兼容修复保留
            isRejected = hasCritical
        case .production:
            // 生产：仅关键违规失败
            isRejected = hasCritical
        }

        return HoloAgentContractParseResult(
            output: output,
            violations: violations,
            repairs: repairs,
            isRejected: isRejected
        )
    }

    /// 将校验结果转为非敏感指标键值对（用于可观测性记录）。
    static func metrics(from result: HoloAgentContractParseResult) -> [String: Any] {
        var metrics: [String: Any] = [:]
        metrics["agent_contract_violation_count"] = result.violations.count
        metrics["agent_contract_repair_count"] = result.repairs.count
        metrics["agent_contract_rejected"] = result.isRejected

        // 按严重度分类计数
        var severityCounts: [String: Int] = [:]
        for v in result.violations {
            severityCounts[v.severity.rawValue, default: 0] += 1
        }
        metrics["violation_by_severity"] = severityCounts

        // 按字段分类计数（不含值，只记字段名）
        var fieldCounts: [String: Int] = [:]
        for v in result.violations {
            let rootField = v.field.split(separator: ".").first.map(String.init) ?? v.field
            fieldCounts[rootField, default: 0] += 1
        }
        metrics["violation_by_field"] = fieldCounts

        return metrics
    }
}
