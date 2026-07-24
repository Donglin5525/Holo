//
//  HoloAgentPolicyContext.swift
//  Holo
//
//  Agent 成熟度演进 P1-B — 统一 AgentPolicyContext
//
//  让 Agent 稳定记住用户纠正，同时避免把偏好固化成不可更改的"人格标签"。
//  复用 HoloMemoryRecord（claimKind/preference/hypothesis + 生命周期）、
//  InsightPreferenceProfile、feedback 近期纠正主题，不新增第二套用户策略存储。
//
//  冲突顺序：
//    当前明确输入 > 当前任务安全/产品规则 > 用户明确纠正/禁止项 >
//    用户确认的稳定偏好 > 近期弱偏好 > 全局默认
//

import Foundation

// MARK: - Policy Entry

/// 单条 Agent Policy。携带来源、状态和有效期。
nonisolated struct HoloAgentPolicyEntry: Equatable, Sendable, Codable {
    /// 稳定 ID。
    var id: String
    /// 规则内容（如"不要使用百分比"、"不要建议多运动"）。
    var rule: String
    /// 来源类型。
    var source: HoloPolicySource
    /// 优先级（数字越大越优先）。
    var priority: Int
    /// 有效期（nil = 永久）。
    var validUntil: Date?
    /// 当前状态。
    var status: HoloPolicyStatus
    /// 关联的数据域（nil = 全域）。
    var relatedDomain: String?

    init(id: String, rule: String, source: HoloPolicySource, priority: Int, validUntil: Date? = nil, status: HoloPolicyStatus = .active, relatedDomain: String? = nil) {
        self.id = id
        self.rule = rule
        self.source = source
        self.priority = priority
        self.validUntil = validUntil
        self.status = status
        self.relatedDomain = relatedDomain
    }
}

nonisolated enum HoloPolicySource: String, Codable, Equatable, Sendable {
    case currentInput          // 当前明确输入（最高优先级）
    case taskRule              // 当前任务的安全/产品规则
    case explicitCorrection    // 用户明确纠正/禁止项
    case confirmedPreference   // 用户确认的稳定偏好
    case weakPreference        // 近期弱偏好
    case globalDefault         // 全局默认

    /// 默认优先级（数字越大越优先）。
    var defaultPriority: Int {
        switch self {
        case .currentInput: return 100
        case .taskRule: return 90
        case .explicitCorrection: return 80
        case .confirmedPreference: return 60
        case .weakPreference: return 40
        case .globalDefault: return 10
        }
    }
}

nonisolated enum HoloPolicyStatus: String, Codable, Equatable, Sendable {
    case active      // 生效中
    case superseded  // 被更新规则取代
    case disputed    // 用户有争议
    case expired     // 已过期
    case forgotten   // 用户主动遗忘
}

// MARK: - Policy Context

/// 统一的 Agent Policy Context，注入到每次相关 Agent 任务。
/// 只注入与当前任务相关的少量 policy，有 Token 上限，不泄露无关领域数据。
nonisolated struct HoloAgentPolicyContext: Equatable, Sendable {
    /// 按 priority 降序排列的生效规则。
    var entries: [HoloAgentPolicyEntry]
    /// Token 预算上限（注入时截断）。
    var tokenBudget: Int
    /// 实际使用的 token 估算。
    var estimatedTokens: Int

    /// 按冲突顺序解析后的最终规则（移除 superseded/expired/forgotten）。
    var activeRules: [HoloAgentPolicyEntry] {
        entries.filter { $0.status == .active }
    }

    /// 当前域相关的规则。
    func rules(forDomain domain: String?) -> [HoloAgentPolicyEntry] {
        activeRules.filter { entry in
            entry.relatedDomain == nil || entry.relatedDomain == domain
        }
    }

    /// 当前输入能覆盖旧偏好（返回被覆盖的旧规则 ID）。
    func overriddenByCurrentInput() -> [String] {
        let currentInputRules = activeRules.filter { $0.source == .currentInput }
        guard !currentInputRules.isEmpty else { return [] }
        // 同域的更低优先级规则被覆盖
        return activeRules.filter { rule in
            rule.source != .currentInput &&
            currentInputRules.contains(where: { $0.relatedDomain == nil || $0.relatedDomain == rule.relatedDomain })
        }.map(\.id)
    }
}

// MARK: - Policy Builder

nonisolated enum HoloAgentPolicyBuilder {

    /// 默认 Token 预算。
    static let defaultTokenBudget = 800

    /// 从各数据源构建统一的 Policy Context。
    /// - Parameters:
    ///   - confirmedPreferences: 用户确认的稳定偏好（来自 InsightPreferenceProfile）
    ///   - explicitCorrections: 用户明确纠正/禁止项（来自 HoloMemoryRecord claimKind=.explicitPreference）
    ///   - weakPreferences: 近期弱偏好（来自 feedback 近期纠正主题）
    ///   - currentInput: 当前任务的明确输入
    ///   - domains: 当前任务涉及的域
    ///   - now: 当前时间（用于过期判断）
    static func build(
        confirmedPreferences: [String],
        explicitCorrections: [String],
        weakPreferences: [String],
        currentInput: [String],
        domains: [String],
        now: Date = Date(),
        tokenBudget: Int = defaultTokenBudget
    ) -> HoloAgentPolicyContext {
        var entries: [HoloAgentPolicyEntry] = []
        var idCounter = 0

        func nextID() -> String {
            idCounter += 1
            return "policy-\(idCounter)"
        }

        // 1. 当前明确输入（最高优先级）
        for input in currentInput {
            entries.append(HoloAgentPolicyEntry(
                id: nextID(), rule: input, source: .currentInput,
                priority: HoloPolicySource.currentInput.defaultPriority
            ))
        }

        // 2. 用户明确纠正/禁止项
        for correction in explicitCorrections {
            entries.append(HoloAgentPolicyEntry(
                id: nextID(), rule: correction, source: .explicitCorrection,
                priority: HoloPolicySource.explicitCorrection.defaultPriority
            ))
        }

        // 3. 用户确认的稳定偏好
        for pref in confirmedPreferences {
            entries.append(HoloAgentPolicyEntry(
                id: nextID(), rule: pref, source: .confirmedPreference,
                priority: HoloPolicySource.confirmedPreference.defaultPriority
            ))
        }

        // 4. 近期弱偏好（带有效期，30 天）
        let weakExpiry = Calendar.current.date(byAdding: .day, value: 30, to: now)
        for weak in weakPreferences {
            entries.append(HoloAgentPolicyEntry(
                id: nextID(), rule: weak, source: .weakPreference,
                priority: HoloPolicySource.weakPreference.defaultPriority,
                validUntil: weakExpiry
            ))
        }

        // 5. 全局默认
        entries.append(HoloAgentPolicyEntry(
            id: nextID(), rule: "不确定时优先说明假设而非猜测", source: .globalDefault,
            priority: HoloPolicySource.globalDefault.defaultPriority
        ))

        // 过滤过期规则
        entries = entries.filter { entry in
            if let validUntil = entry.validUntil, validUntil < now {
                return false
            }
            return true
        }

        // 按 priority 降序
        entries.sort { $0.priority > $1.priority }

        // Token 截断：估算每条约 15 token
        let perEntryTokens = 15
        let maxEntries = max(1, tokenBudget / perEntryTokens)
        let truncated = Array(entries.prefix(maxEntries))
        let estimatedTokens = truncated.count * perEntryTokens

        return HoloAgentPolicyContext(
            entries: truncated,
            tokenBudget: tokenBudget,
            estimatedTokens: estimatedTokens
        )
    }
}

// MARK: - 长期结论准入门槛

/// 判断 Agent Claim 是否值得进入 Memory Record 生命周期。
/// 重要 Claim 只有满足重复、价值和证据门槛时才进入长期结论；
/// 一次性查数不进入长期结论生命周期。
nonisolated enum HoloAgentConclusionPromotionPolicy {

    /// 准入条件。
    struct PromotionThreshold {
        /// 最小重复次数（同一结论被独立验证的次数）。
        var minOccurrences: Int = 2
        /// 最小证据数量。
        var minEvidenceCount: Int = 2
        /// 最小系统置信度。
        var minSystemConfidence: Double = 0.6
        /// 最小 verifier verdict。
        var minVerdict: HoloClaimVerificationVerdict = .verified
    }

    static let defaultThreshold = PromotionThreshold()

    /// 判断 claim 是否值得持久化为长期结论。
    static func shouldPromote(
        claim: HoloAgentClaim,
        occurrences: Int,
        verificationResult: HoloClaimVerificationResultV2?,
        threshold: PromotionThreshold = defaultThreshold
    ) -> Bool {
        // 一次性查数（type=observation 且无 baseline）不进入，除非重复次数足够
        let isOneShotLookup = claim.type == "observation" &&
            !claim.metricAssertions.contains(where: { $0.baselineValue != nil })
        if isOneShotLookup && occurrences < threshold.minOccurrences {
            return false
        }

        guard occurrences >= threshold.minOccurrences else { return false }

        let evidenceCount = claim.metricAssertions.flatMap(\.evidenceIDs).count
        guard evidenceCount >= threshold.minEvidenceCount else { return false }

        if let result = verificationResult {
            guard result.systemConfidence >= threshold.minSystemConfidence else { return false }
            // degraded 也可以进入但标注，rejected 不进入
            guard result.verdict != .rejected else { return false }
        }

        return true
    }
}
