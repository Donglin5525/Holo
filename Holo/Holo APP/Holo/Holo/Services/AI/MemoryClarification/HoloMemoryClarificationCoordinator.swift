//
//  HoloMemoryClarificationCoordinator.swift
//  Holo
//
//  按需澄清协调器（低确认成本方案 §8.4/§11.4/ADR-2）。
//
//  职责仅限：选出至多一个「会改变当前结果」的最小问题；验证冷却/预算/用户控制；
//  把回答按最窄适用范围写回统一记忆仓库。它不得调用业务写工具、不得后台主动通知、
//  不得把多个问题打包成审核清单、不得在用户回答前把候选当事实注入计划。
//
//  纯逻辑 + 依赖注入（历史存取/仓库），standalone 可测。
//

import Foundation

nonisolated enum HoloMemoryClarificationCoordinator {
    /// 同一 logicalQuestionKey 跳过/不确定后的冷却天数（首版产品契约，不得改成「尽量」）。
    static let sameQuestionCooldownDays = 30
    /// 普通入口滚动窗口（天）与窗口内最多提问数。
    static let globalRollingWindowDays = 7
    static let globalBudgetPerRollingWindow = 1

    /// 每次用户主动发起的流程最多问 1 个记忆澄清。
    static let perFlowQuestionLimit = 1

    /// 开关规范实现（HoloAIFeatureFlags 同名属性从这里读取）。
    static let enabledKey = "holo_memory_justInTimeClarificationEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    // MARK: - 问题选取

    /// 从 askWhenRelevant 候选中选出至多一个最高影响的问题。
    /// - Parameter affectsCurrentOutcome: 调用方判定「当前结果是否真实依赖该记录」
    ///   （规划/聊天上下文相关性；不确定时必须返回 false——不问比误问安全）。
    static func selectQuestion(
        records: [HoloMemoryRecord],
        affectsCurrentOutcome: (HoloMemoryRecord) -> Bool,
        now: Date,
        history: HoloMemoryClarificationPromptHistory
    ) -> (question: HoloMemoryClarificationQuestion, updatedHistory: HoloMemoryClarificationPromptHistory)? {
        guard isEnabled else { return nil }

        // 全局预算：滚动 7 天最多 1 个（普通入口；§8.4）。
        let windowStart = now.addingTimeInterval(-Double(globalRollingWindowDays) * 86_400)
        let recentPrompts = history.recentPromptDates.filter { $0 > windowStart }
        guard recentPrompts.count < globalBudgetPerRollingWindow else { return nil }

        // 候选：askWhenRelevant（决策元数据或冲突/高影响推断桥接）且当前结果依赖。
        let askCandidates = records.filter { record in
            isAskWhenRelevant(record, now: now) && affectsCurrentOutcome(record)
        }
        guard !askCandidates.isEmpty else { return nil }

        // 冷却过滤：同题 30 天内不重复，除非证据修订实质变化。
        let eligible = askCandidates.filter { record in
            let key = logicalQuestionKey(for: record)
            guard let state = history.perQuestion[key] else { return true }
            if let cooldownUntil = state.cooldownUntil, cooldownUntil > now {
                let currentRevision = evidenceRevision(for: record)
                // 实质变化解锁：证据修订与上次提问时不同（新证据必须能改变候选答案；
                // 修订摘要即「证据集合变化」的确定性代理）。
                return currentRevision != (state.evidenceRevisionAtLastPrompt ?? "")
            }
            return true
        }
        guard !eligible.isEmpty else { return nil }

        // 最高影响优先；并列取最新更新的。
        let best = eligible
            .sorted { lhs, rhs in
                let l = impactRank(lhs, now: now)
                let r = impactRank(rhs, now: now)
                if l != r { return l > r }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first!

        let question = makeQuestion(for: best, now: now)
        var updated = history
        updated.recentPromptDates = recentPrompts + [now]
        updated.perQuestion[question.logicalQuestionKey] = HoloMemoryClarificationQuestionState(
            lastPromptedAt: now,
            promptCount: (history.perQuestion[question.logicalQuestionKey]?.promptCount ?? 0) + 1,
            cooldownUntil: nil,
            evidenceRevisionAtLastPrompt: question.evidenceRevisionAtPrompt
        )
        return (question, updated)
    }

    // MARK: - 回答写回（§8.5）

    struct WritebackOutcome: Equatable, Sendable {
        var didWriteBack: Bool
        var enteredCooldown: Bool
        var suppressedWithTombstone: Bool
    }

    /// 把用户回答写回统一记忆仓库；澄清本身不触发任何业务动作（ADR-4）。
    static func apply(
        answer: HoloMemoryClarificationAnswer,
        to question: HoloMemoryClarificationQuestion,
        in store: any HoloMemoryClarificationWritebackStore,
        now: Date,
        history: HoloMemoryClarificationPromptHistory
    ) async throws -> (outcome: WritebackOutcome, updatedHistory: HoloMemoryClarificationPromptHistory) {
        var updated = history
        var outcome = WritebackOutcome(didWriteBack: false, enteredCooldown: false, suppressedWithTombstone: false)

        switch answer {
        case .answered(let optionIndex):
            guard let record = try await store.fetch(id: question.recordID),
                  question.options.indices.contains(optionIndex) else {
                // 记录已不存在/选项越界：进冷却防重复打扰。
                enterCooldown(
                    key: question.logicalQuestionKey,
                    evidenceRevision: question.evidenceRevisionAtPrompt,
                    into: &updated,
                    now: now
                )
                outcome.enteredCooldown = true
                return (outcome, updated)
            }
            let option = question.options[optionIndex]
            var newVersion = record
            // 最窄适用范围：只有明确长期/重复表达才 durable userConfirmed；
            // 其余仅生成与本次回答范围一致的状态（默认本次/本周期）。
            let answerStatement = option.semanticAnswer
            newVersion.evidenceRefs.append(
                HoloMemoryEvidenceRef(
                    id: "clarify-\(HoloContextSuppressionKeys.stableDigest("\(question.logicalQuestionKey)|\(answerStatement)|\(Int(now.timeIntervalSince1970))"))",
                    kind: .explicitUserStatement,
                    sourceDomain: record.sourceDomains.first ?? .conversation,
                    lineageKey: "clarification:\(question.logicalQuestionKey)",
                    revisionDigest: "rev-\(Int(now.timeIntervalSince1970))",
                    observedAt: now,
                    summary: answerStatement
                )
            )
            if option.expressesDurableRule {
                newVersion.userDecision = .confirmed
                newVersion.state = .active
                newVersion.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(
                    v2: HoloMemoryDecisionMetadataV2(
                        policyVersion: HoloMemoryDecisionPolicy.currentVersion,
                        sourceAuthority: .explicitUserStatement,
                        evidenceVerdict: .supported,
                        impactLevel: .medium,
                        persistencePermission: .durable,
                        useLevel: .factEligible,
                        attentionPolicy: .silent,
                        reasonCodes: [.declaredStatementAccepted],
                        evaluatedAt: now,
                        evidenceRevision: question.evidenceRevisionAtPrompt
                    )
                )
                newVersion.personalContext?.v1?.admission = HoloContextAdmissionV1(
                    level: .adviceEligible,
                    policyVersion: HoloMemoryDecisionPolicy.currentVersion,
                    decidedAt: now
                )
            } else {
                // 最窄范围：保持观察、不升 durable，回答仅作为本次证据可回源。
                newVersion.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(
                    v2: HoloMemoryDecisionMetadataV2(
                        policyVersion: HoloMemoryDecisionPolicy.currentVersion,
                        sourceAuthority: .explicitUserStatement,
                        evidenceVerdict: .supported,
                        impactLevel: .low,
                        persistencePermission: .sourceScoped,
                        useLevel: .observeOnly,
                        attentionPolicy: .silent,
                        reasonCodes: [.temporaryScopeNarrowed],
                        evaluatedAt: now,
                        evidenceRevision: question.evidenceRevisionAtPrompt
                    )
                )
            }
            newVersion.recordVersion = record.recordVersion + 1
            newVersion.predecessorVersionID = record.versionID
            newVersion.updatedAt = now
            try newVersion.validate()
            try await store.replaceRecordForUserControl(newVersion)
            outcome.didWriteBack = true

        case .dismissed:
            // 暂时不确定/关闭/跳过：不改变事实状态，进入 30 天冷却（§8.5）。
            enterCooldown(
                key: question.logicalQuestionKey,
                evidenceRevision: question.evidenceRevisionAtPrompt,
                into: &updated,
                now: now
            )
            outcome.enteredCooldown = true

        case .doNotUse:
            // suppression + 语义墓碑：不召回、不因换 ID 或同义改写重生（§8.5/P5）。
            if let record = try await store.fetch(id: question.recordID) {
                let control = try await store.loadControlState()
                let version = max(control.userDecisionVersion, Int64(now.timeIntervalSince1970 * 1_000)) + 1
                try await store.saveTombstone(
                    HoloMemoryTombstone(
                        identityKey: record.id,
                        scope: record.scope,
                        claimKind: record.claimKind,
                        anchorKeys: HoloMemoryIdentity.canonicalAnchors(record.anchorRefs).map(\.stableKey),
                        userDecisionVersion: version,
                        createdAt: now
                    )
                )
                _ = try await store.markUserDecision(id: record.id, decision: .rejected, now: now)
                outcome.suppressedWithTombstone = true
            }
            enterCooldown(
                key: question.logicalQuestionKey,
                evidenceRevision: question.evidenceRevisionAtPrompt,
                into: &updated,
                now: now
            )
            outcome.enteredCooldown = true
        }
        return (outcome, updated)
    }

    /// 进入同题冷却：历史无该题状态时创建（回答可能在历史清理后到达）。
    private static func enterCooldown(
        key: String,
        evidenceRevision: String,
        into history: inout HoloMemoryClarificationPromptHistory,
        now: Date
    ) {
        var state = history.perQuestion[key]
            ?? HoloMemoryClarificationQuestionState(lastPromptedAt: now)
        state.cooldownUntil = now.addingTimeInterval(Double(sameQuestionCooldownDays) * 86_400)
        state.evidenceRevisionAtLastPrompt = state.evidenceRevisionAtLastPrompt ?? evidenceRevision
        history.perQuestion[key] = state
    }

    // MARK: - 历史存取（UserDefaults，仅 metadata）

    static func loadHistory(defaults: UserDefaults = .standard) -> HoloMemoryClarificationPromptHistory {
        guard let data = defaults.data(forKey: historyKey),
              let history = try? JSONDecoder().decode(
                  HoloMemoryClarificationPromptHistory.self,
                  from: data
              ) else {
            return .empty
        }
        return history
    }

    static func saveHistory(
        _ history: HoloMemoryClarificationPromptHistory,
        defaults: UserDefaults = .standard
    ) {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private static let historyKey = "holo_memory_clarification_history"

    // MARK: - 私有

    private static func isAskWhenRelevant(
        _ record: HoloMemoryRecord,
        now: Date
    ) -> Bool {
        if let v2 = record.decisionMetadata?.v2, v2.isReliablyDecoded {
            return v2.attentionPolicy == .askWhenRelevant
        }
        // 无元数据（未迁移旧记录/测试构造）：按 v4 现算，与写入路径同口径。
        guard HoloMemoryDecisionPolicy.isEnabled else { return false }
        return HoloMemoryDecisionPolicy.evaluate(record, now: now).route == .askWhenRelevant
    }

    private static func impactRank(_ record: HoloMemoryRecord, now: Date) -> Int {
        let level: HoloMemoryDecisionImpactLevel
        if let cached = record.decisionMetadata?.v2?.impactLevel, cached != .unrecognized("") {
            level = cached
        } else {
            // 无元数据按 v4 现算（与选取口径一致）。
            level = HoloMemoryDecisionInputDeriver.derive(for: record, now: now).impactLevel
        }
        switch level {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .unrecognized: return 2
        }
    }

    /// 主体/关系/范围/缺失变量的规范化签名（§10.2：不用显示文案做 key）。
    static func logicalQuestionKey(for record: HoloMemoryRecord) -> String {
        let payload = record.personalContext?.v1
        let scope = payload?.applicability.scopeSignature ?? record.subjectKey
        let relation = payload?.relationText ?? record.claimKind.rawValue
        let missing = payload?.openQuestions.first ?? "适用范围"
        return HoloContextSuppressionKeys.stableDigest(
            "\(scope)|\(relation)|\(missing)|ask"
        )
    }

    private static func evidenceRevision(for record: HoloMemoryRecord) -> String {
        (record.evidenceRefs.map(\.revisionDigest) + record.counterEvidenceRefs.map(\.revisionDigest))
            .sorted()
            .joined(separator: "|")
    }

    private static func makeQuestion(
        for record: HoloMemoryRecord,
        now: Date
    ) -> HoloMemoryClarificationQuestion {
        let payload = record.personalContext?.v1
        // 文案优先复用后台已形成的 openQuestions；本地模板兜底（§11.4：零新增串行模型调用）。
        let openQuestion = payload?.openQuestions.first
        let statement = payload?.statement ?? record.displaySummary
        let questionText = openQuestion ?? String(
            localized: "为了不把安排弄错，想和你确认：\(statement)——现在还成立吗？"
        )
        let impactSummary = String(
            localized: "不同答案会改变这部分的结果"
        )
        return HoloMemoryClarificationQuestion(
            recordID: record.id,
            logicalQuestionKey: logicalQuestionKey(for: record),
            questionText: questionText,
            missingVariable: payload?.openQuestions.first ?? "当前是否仍然成立",
            impactSummary: impactSummary,
            options: defaultOptions(statement: statement),
            recordVersionAtPrompt: record.versionID,
            evidenceRevisionAtPrompt: evidenceRevision(for: record)
        )
    }

    /// 本地默认选项：长期规则 / 仅当前范围 / 暂不确定 / 不再使用（§8.4 呈现结构）。
    private static func defaultOptions(statement: String) -> [HoloMemoryClarificationOption] {
        [
            HoloMemoryClarificationOption(
                title: String(localized: "一直如此"),
                semanticAnswer: String(localized: "\(statement)（长期规则）"),
                expressesDurableRule: true
            ),
            HoloMemoryClarificationOption(
                title: String(localized: "只是最近/这一次"),
                semanticAnswer: String(localized: "\(statement)（仅当前范围）")
            ),
            HoloMemoryClarificationOption(
                title: String(localized: "暂时不确定"),
                semanticAnswer: "",
                isDismissal: true
            ),
            HoloMemoryClarificationOption(
                title: String(localized: "不要使用这条信息"),
                semanticAnswer: "",
                isDismissal: true
            ),
        ]
    }
}

/// 写回仓库（统一 Repository 的最小面）：澄清不引入新的存储。
nonisolated protocol HoloMemoryClarificationWritebackStore: Sendable {
    func fetch(id: String) async throws -> HoloMemoryRecord?
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws
    func markUserDecision(id: String, decision: HoloMemoryUserDecision, now: Date) async throws -> Bool
    func loadControlState() async throws -> HoloMemoryControlState
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws
}

#if !HOLO_MEMORY_STANDALONE
extension CoreDataHoloMemoryRepository: HoloMemoryClarificationWritebackStore {}
#endif
