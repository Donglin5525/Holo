//
//  HoloAgentEvalModels.swift
//  Holo
//
//  Agent 成熟度演进 P0-A — Agent Eval 基线模型
//
//  版本化 JSON fixtures 的 Codable 模型 + 确定性硬门禁断言类型。
//  所有用例用 stable ID 记录完整轨迹（semantic frame / plan / tool / evidence / verifier / coverage / final answer），
//  硬门禁使用确定性断言；自然表达由少量人工 rubric 处理，不作为唯一门禁。
//

import Foundation

// MARK: - Fixture schema

/// 单条 Eval 用例的完整 schema（与 Fixtures/*.json 一一对应）。
nonisolated struct HoloAgentEvalCase: Codable, Equatable {
    /// 稳定唯一 ID，可被 Coverage Check 与回归 corpus 引用。
    var id: String
    /// 所属场景类别（9 类之一）。
    var category: HoloAgentEvalCategory
    /// 用户原始问题。
    var query: String
    /// 固定参考日期，保证时间解析可复现（ISO8601，含时区）。
    var referenceDate: String
    /// 该用例的预期（确定性硬门禁定义）。
    var expectation: HoloAgentEvalExpectation
    /// 可选：用例自带的合成证据与工具结果，避免依赖真实数据。
    var fixtures: HoloAgentEvalFixtures?
    /// 用例来源：seed（首批基线）/ regression（生产失败脱敏）。
    var origin: HoloAgentEvalOrigin
    /// schema 版本，便于后续演进时筛选。
    var schemaVersion: Int
}

nonisolated enum HoloAgentEvalCategory: String, Codable, CaseIterable, Sendable {
    case timeComparisonWindow          // 时间与比较窗口
    case singleDomainLookup           // 单域简单查数
    case multiSubQuestion             // 多子问题
    case crossDomainRelevant          // 跨域相关
    case noDataUnauthorizedPartial    // 无数据、未授权、部分覆盖
    case causalMedicalOverreach       // 诱导因果、医疗/心理越界
    case userCorrectionPreferenceConflict  // 用户纠正和偏好冲突
    case clarificationNeededOrNot     // 需要澄清与不应澄清
    case sseProtocolDegradedIncomplete     // SSE/协议退化导致不完整结果
    case answerModeConsistency        // P4：问法 → AnswerTask 派生与同义收敛（方案 §10.1/§10.2）
    case answerPresentationRobustness // P4：坏模型文案 / 边界样例 / 降级（方案 §10.3）
}

nonisolated enum HoloAgentEvalOrigin: String, Codable, Sendable {
    case seed
    case regression
}

// MARK: - Expectation（确定性硬门禁）

nonisolated struct HoloAgentEvalExpectation: Codable, Equatable {
    /// 预期时间解析结果（kind / current / baseline）。
    var timeSemantic: HoloAgentEvalTimeExpectation? = nil
    /// 预期最终回答必须覆盖的 metricKey 集合（覆盖检查）。
    var requiredMetricKeys: [String]? = nil
    /// 预期必须被 Verifier 拒绝的 claim 类型。
    var mustRejectClaimOfType: HoloAgentEvalClaimRejection? = nil
    /// 预期是否应触发澄清。
    var shouldClarify: Bool? = nil
    /// 预期答案不得出现的禁词（越界/因果）。
    var forbiddenAnswerTerms: [String]? = nil
    /// 预期硬数字断言（claim 文本须包含或 evidence 须可重算）。
    var requiredNumbers: [Double]? = nil
    /// 预期能力边界：无数据时不得假装有结论。
    var mustDeclareCapabilityBoundary: Bool? = nil
    /// 预期工具调用集合（确定性判定路由正确性）。
    var expectedTools: [String]? = nil
    /// 预期 confidence 不应超过的阈值（弱证据不得强结论）。
    var maxConfidence: Double? = nil
    /// P4：答案语义/展示维度断言（AnswerTask 派生 / 合成器输出 / 验证判定 / 无内部 token）。
    var answerPresentation: HoloAgentEvalAnswerPresentationExpectation? = nil
}

/// P4 答案语义/展示维度的确定性硬门禁（方案 §10 验收矩阵）。
nonisolated struct HoloAgentEvalAnswerPresentationExpectation: Codable, Equatable {
    /// 预期派生的 AnswerMode（rawValue）；传 "nil" 表示预期派生失败（如旧证据无 semantic）。
    var expectedMode: String? = nil
    /// 预期派生的领域 / 方向 / 维度（rawValue）。
    var expectedDomain: String? = nil
    var expectedDirection: String? = nil
    var expectedDimension: String? = nil
    /// 预期确定性合成器产出 directAnswer 并被 Renderer 采纳。
    var expectComposedDirectAnswer: Bool? = nil
    /// directAnswer 必须包含 / 不得包含的子串（数字用格式化后的稳定形态，如 "1,248"）。
    var directAnswerMustContain: [String]? = nil
    var directAnswerMustNotContain: [String]? = nil
    /// 全部用户可见文本不得包含的子串（如 "nan" / "inf" / 乱码片段）。
    var userTextsMustNotContain: [String]? = nil
    /// 预期展示前验证判定（对注入坏模型文案的原始结果）：pass / recoverable / failed。
    var expectedVerifier: String? = nil
    /// 预期覆盖度被披露（coverageText 含 "x/y 天" 或「覆盖」）。
    var mustDiscloseCoverage: Bool? = nil
    /// 预期 limitations 包含的子串。
    var limitationsMustContain: [String]? = nil
    /// 注入的（坏）模型文案：runner 用它构造 claim 与原始渲染结果。
    var modelDisplayText: String? = nil
    /// 同义问法组 ID：同组用例必须派生同一 AnswerTask（除 rangeLabel 外）且答案数字一致。
    var synonymGroup: String? = nil
    /// 预期渲染后 +1 的可观测指标（agent.* 全名）。
    var expectedObservabilityMetric: String? = nil
}

nonisolated struct HoloAgentEvalTimeExpectation: Codable, Equatable {
    /// 预期解析出的 kind；nil 表示预期解析失败。
    var expectedKind: String?
    /// 预期对比双窗的 current / baseline kind。
    var comparisonCurrentKind: String?
    var comparisonBaselineKind: String?
    /// 预期当前窗口起止（ISO8601）。
    var currentWindowStart: String?
    var currentWindowEnd: String?
}

nonisolated enum HoloAgentEvalClaimRejection: String, Codable, Sendable {
    case causalOverreach     // 因果越界
    case unsupportedNumber   // 无证据数字
    case windowMismatch      // 窗口不可比
    case unitMismatch        // 单位/币种不一致
    case zeroDenominator     // 分母为零
    case duplicateLineage    // 重复血缘
}

// MARK: - Fixtures（合成数据，避免依赖真实用户数据）

nonisolated struct HoloAgentEvalFixtures: Codable, Equatable {
    var evidence: [HoloEvidenceRecord]?
    var toolResults: [HoloAgentEvalToolResult]?
    /// P4：工具数据覆盖度（用于覆盖披露/降级断言）。
    var coverage: HoloDataCoverage? = nil
}

nonisolated struct HoloAgentEvalToolResult: Codable, Equatable {
    var toolName: String
    /// 模拟工具返回的 JSON（字符串，由 runner 解释）。
    var responseJSON: String
}

// MARK: - Runner 结果

/// 单条用例的判定结果。
nonisolated struct HoloAgentEvalVerdict: Equatable, Sendable {
    var caseID: String
    var passed: Bool
    /// 失败的断言列表（确定性原因）。
    var failures: [String]
    /// 完整轨迹摘要（不包含用户原文/金额/健康数据，仅技术元数据）。
    var trace: HoloAgentEvalTrace
}

nonisolated struct HoloAgentEvalTrace: Equatable, Sendable {
    var resolvedTimeKind: String?
    var planOrFastPath: String
    var toolRequests: [String]
    var evidenceCount: Int
    var verifierResult: String     // verified / degraded / rejected / not-applicable
    var coverageStatus: String     // complete / partial / missing
    var confidenceMax: Double?
}
