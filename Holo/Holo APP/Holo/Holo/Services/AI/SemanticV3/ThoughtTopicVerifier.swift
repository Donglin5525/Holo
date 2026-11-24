//
//  ThoughtTopicVerifier.swift
//  Holo
//
//  语义关联验证器与决策分层（语义图谱 V3 Phase 3，方案 §9.2 步骤 6-8 / §10）
//
//  候选明确时只发 Top 3 Topic 的最小上下文（title + 各 ≤3 条代表片段，逐条 ≤240 UTF-16）；
//  模型只返回离散关系与逐字证据。客户端二次校验（quote 逐字/range/ref 白名单），
//  再按独立信号分层：high 弱展示 / medium 仅内部 / low 丢弃——shadow 阶段只记录。
//
//  W1 类别规则层（2026-11-16 方案 §4 A2）：schema 4 独立路径 evaluateSchema4——
//  用户规则优先（definitionSource=user）、excludes_category 负向、差量落库
//  （未覆盖主题保留既有归属、只有明确负向才撤销、容量排序 + 影子记录）。
//  schema 1/2/3 的请求与解码路径零变化（evaluateLegacy 原样保留）。
//

import CoreData
import CryptoKit
import Foundation
import OSLog

// MARK: - 传输 DTO（与后端 §16.2 契约对齐）

nonisolated struct ThoughtSemanticRelateRequestDTO: Codable {
    struct Target: Codable { let ref: String; let text: String }
    struct Representative: Codable { let ref: String; let text: String }
    struct Candidate: Codable {
        let ref: String
        let title: String
        let summary: String?
        /// schema 3：category=用户类别 / thread=内容脉络（缺省按 thread）
        let kind: String?
        /// schema 3：类别定义（用户口径，仅 category 候选携带；与 AI 摘要 summary 分开）
        let definition: String?
        /// schema 4（类别规则层）：规则来源标注 user|none；nil = schema 1/2/3（编码不变）。
        /// 类别 user 时 definition 必须为脱敏后的用户规则（1–240 UTF-16）；thread 恒 none。
        var definitionSource: String? = nil
        let representatives: [Representative]
    }
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let engineVersion: String
    let target: Target
    let candidates: [Candidate]
}

nonisolated struct ThoughtSemanticRelateResponseDTO: Codable {
    struct Decision: Codable {
        let candidateRef: String
        let relation: String
        let quote: String?
        let rangeUTF16: [Int]?
        var representativeRef: String? = nil
        var representativeQuote: String? = nil
        var sharedSubject: String? = nil
    }
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let decisions: [Decision]
    var outcome: String? = nil
    var reasonCode: String? = nil
}

// MARK: - 决策结果

nonisolated struct ThoughtRelationDecision: Codable, Equatable {
    var topicID: UUID
    var relation: String          // same_thread / fits_category / none / insufficient
    var tier: String              // high / medium / low
    var verifierQuote: String?
    var verifierRangeUTF16: [Int]?   // 证据区间（正式提交时随 basisTextHash 落库）
    var scoreFeaturesJSON: String
}

// MARK: - schema 4 差量选型（纯函数输入输出，供测试与提交共用）

/// 类别规则送审判据（schema 4）：长度以实际送审文本（脱敏 + 裁剪外缘空白后）的
/// UTF-16 计数为准。历史超限定义保持原文、不静默截断——该类别跳过评判，
/// 保留既有 AI 归属及用户决定，留诊断。
nonisolated enum ThoughtSchema4RulePayload: Equatable {
    /// 类别无用户规则（命名避开 none：快照以 Optional 持有，`.none` 会与 nil 混淆）
    case noUserRule
    case user(definition: String)               // 送审规则（1–240 UTF-16）
    case skip(reason: String)                   // category_definition_too_long / category_definition_unreadable
}

/// 一次 schema 4 评估聚合后的单候选结论（跨段聚合已完成）。
nonisolated struct ThoughtSchema4CandidateVerdict: Equatable {
    var topicID: UUID
    var kind: String                 // category / thread
    var relation: String             // same_thread / fits_category / excludes_category / related / none / insufficient
    /// 正项是否明确引用用户规则（definitionSource=user 且 representativeRef=definition）
    var citesUserRule: Bool
    var verifierQuote: String?
    var verifierRangeUTF16: [Int]?
    var recallScore: Float
    /// 内容脉络候选：所有送审段一致给明确负向（none）
    var consistentNone: Bool
}

/// schema 4 差量落库裁决结果。
nonisolated struct ThoughtSchema4Selection: Equatable {
    /// 本轮提交/续期的正项（按优先序），含既有保留行的续期
    var affirmed: [ThoughtRelationDecision]
    /// 明确负向撤销集合（类别 excludes_category / 脉络全段一致 none）
    var revokedTopicIDs: Set<UUID>
    /// 判正但容量未入的正项（写影子记录，含原因）
    var capacityDeferredTopicIDs: [UUID]
    /// 保留的既有自动归属（未召回/未送判/非明确负向）
    var retainedTopicIDs: Set<UUID>

    static let empty = ThoughtSchema4Selection(affirmed: [], revokedTopicIDs: [], capacityDeferredTopicIDs: [], retainedTopicIDs: [])
}

nonisolated enum ThoughtTopicVerifierError: Error {
    case candidateBuildFailed
    case responseContractViolation(reason: String)
}

nonisolated enum ThoughtTopicVerifier {
    /// v3.2（2026-10-12 主题双通道）：schema 3 + fits_category；类别通道与脉络通道独立判定。
    static let engineVersion = "thought_semantic_v3.2"
    static let requestSchemaVersion = 3
    /// W1 类别规则层（2026-11-16 方案 §4 A2）：schema 4 + excludes_category + 用户规则优先。
    static let schema4RequestVersion = 4
    static let schema4EngineVersion = "thought_semantic_v4"
    /// 归属型关系（要求双侧逐字证据）：same_thread=同内容脉络；fits_category=符合用户类别定义
    private static let committingRelations: Set<String> = ["same_thread", "fits_category"]
    private static let allowedRelations: Set<String> = ["same_thread", "fits_category", "related", "none", "insufficient"]
    /// schema 4 关系枚举：新增 excludes_category（只允许 category + definitionSource=user）
    private static let schema4AllowedRelations: Set<String> = ["same_thread", "fits_category", "excludes_category", "related", "none", "insufficient"]
    /// 每条想法的自动归属总上限（A2：手动关系不占额、也不被修改）
    static let autoAttributionLimit = 3

    /// 目录版本不包含 AI 成员数，避免自动写关系又触发自身重评。
    static func evaluationVersion(context: NSManagedObjectContext) async -> String {
        let catalog = await context.perform {
            let request = Topic.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil")
            return Topic.resolveValidRows((try? context.fetch(request)) ?? [])
                .map { "\($0.id.uuidString)|\($0.title)|\($0.status)|\($0.summary ?? "")|\($0.categoryDefinition ?? "")" }.sorted().joined(separator: "\n")
        }
        let digest = SHA256.hash(data: Data(catalog.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return engineVersion + ":" + digest + (ThoughtSemanticFeatureFlags.relation == .on ? ":live" : ":shadow")
    }

    static func shadowEvaluate(thoughtID: UUID, redactedText: String, contentHash: String,
        targetVector: [Float], store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?,
        context: NSManagedObjectContext, provider: HoloBackendAIProvider,
        calibration: ThoughtSemanticCalibration, consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        try await evaluate(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
            targetVector: targetVector, store: store, index: index, context: context, provider: provider,
            calibration: calibration, commit: false, consentGeneration: consentGeneration)
    }
    static func evaluateAndCommit(thoughtID: UUID, redactedText: String, contentHash: String,
        targetVector: [Float], store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?,
        context: NSManagedObjectContext, provider: HoloBackendAIProvider,
        calibration: ThoughtSemanticCalibration, consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        try await evaluate(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
            targetVector: targetVector, store: store, index: index, context: context, provider: provider,
            calibration: calibration, commit: true, consentGeneration: consentGeneration)
    }
    private static func evaluate(thoughtID: UUID, redactedText: String, contentHash: String,
        targetVector: [Float], store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?,
        context: NSManagedObjectContext, provider: HoloBackendAIProvider,
        calibration: ThoughtSemanticCalibration, commit: Bool, consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        // W1 类别规则层分派：模式 × 隔离样本 × 服务端闸由同一策略函数裁决
        // （队列去重 hasRelationRecord 共用 categoryRulesCoverage，不得各自拼装）。
        if let v4Mode = ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: thoughtID) {
            do {
                return try await evaluateSchema4(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
                    targetVector: targetVector, store: store, index: index, context: context, provider: provider,
                    calibration: calibration, consentGeneration: consentGeneration,
                    v4Mode: v4Mode, commit: commit && v4Mode == .live)
            } catch {
                guard isSchema4ProtocolRejection(error) else { throw error }
                // 服务端拒（协议错误/灰度关闭）：停发新版请求；既有归属保留、不生成
                // 空结果回执，也不对这些样本立即补发旧协议（恢复旧策略走重试与 W4
                // 定向回滚）。错误按既有封套映射上抛，重试策略内不形成风暴。
                ThoughtSemanticFeatureFlags.markSchema4ServerRejected()
                try? await store.recordCategoryRulesDiagnostic(thoughtID: thoughtID, topicID: thoughtID,
                    contentHash: contentHash, reason: "schema4_server_rejected", mode: v4Mode.rawValue)
                throw error
            }
        }
        return try await evaluateLegacy(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
            targetVector: targetVector, store: store, index: index, context: context, provider: provider,
            calibration: calibration, commit: commit, consentGeneration: consentGeneration)
    }

    // MARK: - legacy 路径（schema 1/2/3，行为零变化）

    private static func evaluateLegacy(thoughtID: UUID, redactedText: String, contentHash: String,
        targetVector: [Float], store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?,
        context: NSManagedObjectContext, provider: HoloBackendAIProvider,
        calibration: ThoughtSemanticCalibration, commit: Bool, consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        let catalogVersion = await evaluationVersion(context: context)
        // 与入队去重共用完整指纹；类别理解升版才重评，读取失败时交给队列重试。
        let version = try await store.relationEvaluationVersion(catalogVersion: catalogVersion)
        let recall = try await ThoughtTopicCandidateEngine.recall(targetVector: targetVector, thoughtID: thoughtID,
            store: store, index: index, context: context, calibration: calibration, provider: provider)
        // 类别定义来源：用户口径（categoryDefinition）优先，其次本机 AI brief（零打扰起草/精化）
        var briefDefinitionByTopic: [UUID: String] = [:]
        for candidate in recall.candidates where candidate.kind == "category" {
            if let brief = try? await store.loadCategoryBrief(topicID: candidate.topicID) {
                briefDefinitionByTopic[candidate.topicID] = brief.definition
            }
        }
        var candidates: [ThoughtSemanticRelateRequestDTO.Candidate] = []
        var topicByRef: [String: UUID] = [:]
        var payloadDroppedTopicIDs: [UUID] = []
        for candidate in recall.candidates {
            let ref = "P" + String(candidates.count)
            let payload = await context.perform { () -> ThoughtSemanticRelateRequestDTO.Candidate? in
                // 同 id 副本统一解析：抓到 merged 旧行会把候选在 AI 调用前静默丢掉
                guard let topic = Topic.resolveValid(id: candidate.topicID, in: context) else { return nil }
                let thoughtRequest = Thought.fetchRequest()
                // 候选代表成员正文会上传：排除「不参与 AI」标签的想法
                thoughtRequest.predicate = ThoughtAIAudience.aiVisible(
                    NSPredicate(format: "deletedAt == nil AND isArchived == NO AND id != %@ AND ANY topicLinks.topic.id == %@", thoughtID as CVarArg, topic.id as CVarArg))
                let members = ((try? context.fetch(thoughtRequest)) ?? []).filter { ThoughtTopicLinkProjection.isEffectiveMember($0, of: topic) }
                // 类别候选代表例「用户确认优先」（doc §3：避免 AI 自己的历史选择定义类别）；
                // 脉络候选维持最近优先。
                let ordered: [Thought]
                if candidate.kind == "category" {
                    ordered = members.sorted {
                        let sa = ThoughtTopicLinkProjection.categorySampleRank(of: $0, in: topic)
                        let sb = ThoughtTopicLinkProjection.categorySampleRank(of: $1, in: topic)
                        if sa != sb { return sa < sb }
                        return $0.updatedAt > $1.updatedAt
                    }
                } else {
                    ordered = members.sorted { $0.updatedAt > $1.updatedAt }
                }
                let representatives = ordered.prefix(3).map {
                    ThoughtSemanticRelateRequestDTO.Representative(ref: $0.id.uuidString,
                        text: ThoughtSemanticText.prefix(ThoughtIndexV2Policy.redactedText(forUpload: $0.content), maxUTF16: 240))
                }.filter { !$0.text.isEmpty }
                return .init(ref: ref, title: ThoughtSemanticText.prefix(topic.title, maxUTF16: 32),
                    summary: topic.summary.map { ThoughtSemanticText.prefix($0, maxUTF16: 240) },
                    kind: candidate.kind,
                    definition: candidate.kind == "category"
                        ? (topic.categoryDefinition.map { ThoughtSemanticText.prefix($0, maxUTF16: 240) }
                           ?? briefDefinitionByTopic[candidate.topicID].map { ThoughtSemanticText.prefix($0, maxUTF16: 240) })
                        : nil,
                    representatives: representatives)
            }
            if let payload { candidates.append(payload); topicByRef[ref] = candidate.topicID }
            else { payloadDroppedTopicIDs.append(candidate.topicID) }
        }
        var resultsByTopic: [UUID: ThoughtRelationDecision] = [:]
        // 诊断元数据（只记 id 与判定码，不落正文）：no_match 不再是黑盒
        var verdictsByTopic: [UUID: String] = [:]
        var requestChunkCount = 0
        if !candidates.isEmpty {
            for chunk in ThoughtSemanticText.chunks(redactedText, maxUTF16: 4_000) {
                guard ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { throw CancellationError() }
                requestChunkCount += 1
                let request = ThoughtSemanticRelateRequestDTO(schemaVersion: Self.requestSchemaVersion, operationId: UUID().uuidString,
                    textRevision: contentHash, engineVersion: engineVersion,
                    target: .init(ref: "T0", text: chunk.text), candidates: candidates)
                let response = try await provider.semanticRelate(request)
                guard response.schemaVersion == Self.requestSchemaVersion, response.operationId == request.operationId,
                      response.textRevision == contentHash else { throw ThoughtTopicVerifierError.responseContractViolation(reason: "envelope") }
                if response.outcome == "deferred" {
                    throw APIError.backendError(statusCode: 400, code: "CONTENT_DEFERRED",
                        message: "这条笔记暂未通过 AI 处理审核，原文已保留。", requestId: nil)
                }
                guard response.decisions.count == candidates.count else {
                    throw ThoughtTopicVerifierError.responseContractViolation(reason: "decisions_missing")
                }
                var seen = Set<String>()
                for decision in response.decisions {
                    guard let topicID = topicByRef[decision.candidateRef], seen.insert(decision.candidateRef).inserted,
                          let candidate = candidates.first(where: { $0.ref == decision.candidateRef }),
                          allowedRelations.contains(decision.relation) else {
                        throw ThoughtTopicVerifierError.responseContractViolation(reason: "candidate")
                    }
                    verdictsByTopic[topicID] = decision.relation
                    // 归属判定（同脉络/符合类别）要求双侧逐字证据；类别判定不要求共同对象
                    // （fits_category 无 sharedSubject 语义），但主题侧依据必须逐字可回源。
                    guard committingRelations.contains(decision.relation), let quote = decision.quote,
                          isQuoteVerbatim(quote, in: chunk.text, rangeUTF16: decision.rangeUTF16),
                          let repRef = decision.representativeRef, let repQuote = decision.representativeQuote,
                          !repQuote.isEmpty else { continue }
                    if decision.relation == "same_thread" {
                        guard let subject = decision.sharedSubject,
                              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    }
                    let basis = repRef == "definition" ? (candidate.definition ?? candidate.summary ?? candidate.title)
                        : candidate.representatives.first(where: { $0.ref == repRef })?.text
                    guard let basis, basis.contains(repQuote) else { throw ThoughtTopicVerifierError.responseContractViolation(reason: "representative_quote") }
                    if resultsByTopic[topicID] == nil {
                        let range = decision.rangeUTF16?.map { $0 + chunk.offsetUTF16 }
                        resultsByTopic[topicID] = .init(topicID: topicID, relation: decision.relation, tier: "high",
                            verifierQuote: quote, verifierRangeUTF16: range, scoreFeaturesJSON: "{\"evidenceProtocol\":3}")
                    }
                }
            }
        }
        // 双通道允许重叠归属：类别（≤类别上限）+ 脉络（≤2）合计放宽到 3。
        let results = Array(resultsByTopic.values.sorted { $0.topicID.uuidString < $1.topicID.uuidString }.prefix(3))
        // 全部网络判断结束后才提交，任何一段失败都不把半篇结果标为完成。
        if commit {
            let allowed = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
            guard allowed, ThoughtSemanticFeatureFlags.relation == .on,
                  ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { throw CancellationError() }
            let committed = try await context.perform { () -> Bool in
                context.refreshAllObjects()
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", thoughtID as CVarArg)
                guard let thought = try context.fetch(request).first,
                      ThoughtSemanticText.contentHash( thought.content) == contentHash,
                      ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { return false }
                let links = thought.topicLinks as? Set<ThoughtTopicLink> ?? []
                let selected = Set(results.map(\.topicID))
                for link in links where link.sourceEnum == .aiV3 && link.stateEnum == .active {
                    if let topic = link.topic, !selected.contains(topic.id) { link.stateEnum = .superseded; link.updatedAt = Date() }
                }
                var receipts: [String] = []
                for result in results {
                    // 同 id 副本统一解析：此处抓到 merged 旧行会把已判成立的关联静默丢弃
                    guard let topic = Topic.resolveValid(id: result.topicID, in: context) else { continue }
                    if ThoughtTopicLinkProjection.recordAIV3Decision(thought: thought, topic: topic,
                        basisTextHash: contentHash, decisionTier: "high", engineVersion: engineVersion,
                        consentGeneration: consentGeneration, evidenceRange: result.verifierRangeUTF16) {
                        receipts.append(topic.title)
                    }
                }
                // 错误向上传递，队列会保留重试；不回滚其他编辑器的未保存内容。
                do { if context.hasChanges { try context.save() } }
                catch { context.rollback(); throw error }
                for title in receipts {
                    NotificationCenter.default.post(name: .thoughtTopicLinkDidCommit,
                        object: ["thoughtId": thoughtID, "topicTitle": title], userInfo: ["source": "ai"])
                }
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                return true
            }
            guard committed else { throw CancellationError() }
        }
        for result in results {
            try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: result.topicID,
                contentHash: contentHash, scoreFeatures: result.scoreFeaturesJSON, verifierResult: result.relation,
                state: commit ? "committed_high" : "shadow_high", engineVersion: version,
                expiryDays: calibration.candidateExpiryDays, verifierQuote: result.verifierQuote)
        }
        // 固定哨兵只记录本次目录下的空结果；主题目录变化或模式升级时自然重评。
        // scoreFeatures 携带最小诊断元数据（召回/筛除/逐候选判定/分段数），字段均为
        // id 与判定码，不含正文——下次 no_match 可直接区分「没召回 / 构建被丢 / 模型拒绝」。
        var diagnostics: [String: Any] = [:]
        if let recallReason = recall.reason { diagnostics["recallReason"] = recallReason }
        diagnostics["recalled"] = recall.candidates.map { $0.topicID.uuidString }
        if !payloadDroppedTopicIDs.isEmpty { diagnostics["payloadDropped"] = payloadDroppedTopicIDs.map(\.uuidString) }
        if !verdictsByTopic.isEmpty {
            var decisions: [String: String] = [:]
            for (topicID, relation) in verdictsByTopic { decisions[topicID.uuidString] = relation }
            diagnostics["decisions"] = decisions
        }
        if requestChunkCount > 1 { diagnostics["chunks"] = requestChunkCount }
        let diagnosticsJSON = (try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: thoughtID, contentHash: contentHash,
            scoreFeatures: diagnosticsJSON, verifierResult: results.isEmpty ? "no_match" : "evaluated",
            state: commit ? "evaluated" : "shadow", engineVersion: version, expiryDays: calibration.candidateExpiryDays)
        return results
    }

    // MARK: - schema 4 路径（W1 类别规则层，2026-11-16 方案 §4 A2）

    /// schema 4 评估：用户规则优先的请求构建、excludes_category 校验、差量落库。
    /// shadow 模式只在隔离评测样本保存诊断与影子回执，不写任何正式关系；
    /// live 模式经差量裁决后提交（落库只对本次实际覆盖到的主题做差量）。
    private static func evaluateSchema4(thoughtID: UUID, redactedText: String, contentHash: String,
        targetVector: [Float], store: ThoughtSemanticStore, index: (any LocalSemanticIndex)?,
        context: NSManagedObjectContext, provider: HoloBackendAIProvider,
        calibration: ThoughtSemanticCalibration, consentGeneration: Int64,
        v4Mode: ThoughtSemanticFeatureFlags.CategoryRulesMode, commit: Bool) async throws -> [ThoughtRelationDecision]? {
        let catalogVersion = await evaluationVersion(context: context)
        // 统一评估版本键（schema + policy + effective candidate scope + contentHash）：
        // 队列去重、评估回执与去重共用；shadow 与 live 版本空间分隔，不污染 v3 回执。
        let baseVersion = try await store.relationEvaluationVersion(catalogVersion: catalogVersion)
        let version = ThoughtSemanticStore.schema4EvaluationVersionKey(
            catalogVersion: baseVersion, mode: v4Mode.rawValue, contentHash: contentHash)
        let recall = try await ThoughtTopicCandidateEngine.recall(targetVector: targetVector, thoughtID: thoughtID,
            store: store, index: index, context: context, calibration: calibration, provider: provider)
        var candidates: [ThoughtSemanticRelateRequestDTO.Candidate] = []
        var topicByRef: [String: UUID] = [:]
        var kindByTopic: [UUID: String] = [:]
        var recallScoreByTopic: [UUID: Float] = [:]
        /// 送判时的类别规则快照（提交前核对仍当前；被改 → 过期重排当前批）
        var ruleSnapshotByTopic: [UUID: ThoughtSchema4RulePayload] = [:]
        var payloadDroppedTopicIDs: [UUID] = []
        var skippedRuleTopics: [(topicID: UUID, reason: String)] = []
        for candidate in recall.candidates {
            let ref = "P" + String(candidates.count)
            let built = await context.perform { () -> (payload: ThoughtSemanticRelateRequestDTO.Candidate?,
                                                       skippedReason: String?, ruleSnapshot: ThoughtSchema4RulePayload?) in
                // 同 id 副本统一解析：抓到 merged 旧行会把候选在 AI 调用前静默丢掉
                guard let topic = Topic.resolveValid(id: candidate.topicID, in: context) else { return (nil, nil, nil) }
                let thoughtRequest = Thought.fetchRequest()
                // 候选代表成员正文会上传：排除「不参与 AI」标签的想法
                thoughtRequest.predicate = ThoughtAIAudience.aiVisible(
                    NSPredicate(format: "deletedAt == nil AND isArchived == NO AND id != %@ AND ANY topicLinks.topic.id == %@", thoughtID as CVarArg, topic.id as CVarArg))
                let members = ((try? context.fetch(thoughtRequest)) ?? []).filter { ThoughtTopicLinkProjection.isEffectiveMember($0, of: topic) }
                func userInclusionSamples() -> [Thought] {
                    // 类别代表例只带合规的用户纳入例（A1.4：主动移入/接受样本，最近优先）
                    members.filter { ThoughtTopicLinkProjection.membershipSource(of: $0, in: topic) == .user }
                        .sorted { $0.updatedAt > $1.updatedAt }
                }
                func representativeDTOs(from samples: [Thought]) -> [ThoughtSemanticRelateRequestDTO.Representative] {
                    samples.prefix(3).map {
                        ThoughtSemanticRelateRequestDTO.Representative(ref: $0.id.uuidString,
                            text: ThoughtSemanticText.prefix(ThoughtIndexV2Policy.redactedText(forUpload: $0.content), maxUTF16: 240))
                    }.filter { !$0.text.isEmpty }
                }
                guard candidate.kind == "category" else {
                    // 内容脉络：definitionSource 恒 none；代表例沿用原有合规样本（最近优先）
                    let ordered = members.sorted { $0.updatedAt > $1.updatedAt }
                    return (.init(ref: ref, title: ThoughtSemanticText.prefix(topic.title, maxUTF16: 32),
                        summary: topic.summary.map { ThoughtSemanticText.prefix($0, maxUTF16: 240) },
                        kind: "thread", definition: nil, definitionSource: "none",
                        representatives: representativeDTOs(from: ordered)), nil, .noUserRule)
                }
                // schema 4 类别：definition 只认用户已保存规则（A02：存量 AI brief 与排除
                // 数组不升格为规则）；类别不传 AI 主题摘要作为默认证据（A2 字段表）。
                let rule = schema4RulePayload(rawDefinition: topic.categoryDefinition)
                switch rule {
                case .skip(let reason):
                    // 超限/脱敏后不可判读：该类别跳过评判（诊断留痕），保留既有归属及用户决定
                    return (nil, reason, rule)
                case .noUserRule:
                    return (.init(ref: ref, title: ThoughtSemanticText.prefix(topic.title, maxUTF16: 32),
                        summary: nil, kind: "category", definition: nil, definitionSource: "none",
                        representatives: representativeDTOs(from: userInclusionSamples())), nil, .noUserRule)
                case .user(let definition):
                    return (.init(ref: ref, title: ThoughtSemanticText.prefix(topic.title, maxUTF16: 32),
                        summary: nil, kind: "category", definition: definition, definitionSource: "user",
                        representatives: representativeDTOs(from: userInclusionSamples())), nil, rule)
                }
            }
            if let payload = built.payload {
                candidates.append(payload)
                topicByRef[ref] = candidate.topicID
                kindByTopic[candidate.topicID] = candidate.kind
                recallScoreByTopic[candidate.topicID] = candidate.recallScore
                ruleSnapshotByTopic[candidate.topicID] = built.ruleSnapshot
            } else if let reason = built.skippedReason {
                skippedRuleTopics.append((candidate.topicID, reason))
            } else {
                payloadDroppedTopicIDs.append(candidate.topicID)
            }
        }
        for skipped in skippedRuleTopics {
            try? await store.recordCategoryRulesDiagnostic(thoughtID: thoughtID, topicID: skipped.topicID,
                contentHash: contentHash, reason: skipped.reason, mode: v4Mode.rawValue)
        }
        var resultsByTopic: [UUID: ThoughtRelationDecision] = [:]
        var citesUserRuleByTopic: [UUID: Bool] = [:]
        var verdictsByTopic: [UUID: String] = [:]
        var relationsSeenByTopic: [UUID: Set<String>] = [:]
        var noneChunkCountByTopic: [UUID: Int] = [:]
        var requestChunkCount = 0
        if !candidates.isEmpty {
            for chunk in ThoughtSemanticText.chunks(redactedText, maxUTF16: 4_000) {
                guard ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { throw CancellationError() }
                requestChunkCount += 1
                let request = ThoughtSemanticRelateRequestDTO(schemaVersion: Self.schema4RequestVersion, operationId: UUID().uuidString,
                    textRevision: contentHash, engineVersion: schema4EngineVersion,
                    target: .init(ref: "T0", text: chunk.text), candidates: candidates)
                let response = try await provider.semanticRelate(request)
                guard response.schemaVersion == Self.schema4RequestVersion, response.operationId == request.operationId,
                      response.textRevision == contentHash else { throw ThoughtTopicVerifierError.responseContractViolation(reason: "envelope") }
                if response.outcome == "deferred" {
                    throw APIError.backendError(statusCode: 400, code: "CONTENT_DEFERRED",
                        message: "这条笔记暂未通过 AI 处理审核，原文已保留。", requestId: nil)
                }
                guard response.decisions.count == candidates.count else {
                    throw ThoughtTopicVerifierError.responseContractViolation(reason: "decisions_missing")
                }
                var seen = Set<String>()
                for decision in response.decisions {
                    guard let topicID = topicByRef[decision.candidateRef], seen.insert(decision.candidateRef).inserted,
                          let candidate = candidates.first(where: { $0.ref == decision.candidateRef }) else {
                        throw ThoughtTopicVerifierError.responseContractViolation(reason: "candidate")
                    }
                    // schema 4 通道交叉约束：类别禁 same_thread、脉络禁 fits_category/excludes_category、
                    // excludes_category 只允许 category + user；违反即协议错误整批拒绝。
                    try validateSchema4RelationConstraints(relation: decision.relation,
                        kind: candidate.kind, definitionSource: candidate.definitionSource)
                    verdictsByTopic[topicID] = decision.relation
                    relationsSeenByTopic[topicID, default: []].insert(decision.relation)
                    if decision.relation == "none" { noneChunkCountByTopic[topicID, default: 0] += 1 }
                    if decision.relation == "excludes_category" {
                        // 负向证据四件套：目标逐字引用 + representativeRef=="definition" +
                        // representativeQuote 逐字回源用户规则；证据不全按协议错误处理，
                        // 不降级、不生成空结果回执。
                        try validateSchema4ExclusionEvidence(quote: decision.quote,
                            rangeUTF16: decision.rangeUTF16, chunkText: chunk.text,
                            representativeRef: decision.representativeRef,
                            representativeQuote: decision.representativeQuote,
                            ruleDefinition: candidate.definition)
                        continue
                    }
                    guard committingRelations.contains(decision.relation), let quote = decision.quote,
                          isQuoteVerbatim(quote, in: chunk.text, rangeUTF16: decision.rangeUTF16),
                          let repRef = decision.representativeRef, let repQuote = decision.representativeQuote,
                          !repQuote.isEmpty else { continue }
                    if decision.relation == "same_thread" {
                        guard let subject = decision.sharedSubject,
                              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    }
                    let basis = repRef == "definition" ? (candidate.definition ?? candidate.summary ?? candidate.title)
                        : candidate.representatives.first(where: { $0.ref == repRef })?.text
                    guard let basis, basis.contains(repQuote) else { throw ThoughtTopicVerifierError.responseContractViolation(reason: "representative_quote") }
                    if resultsByTopic[topicID] == nil {
                        let range = decision.rangeUTF16?.map { $0 + chunk.offsetUTF16 }
                        resultsByTopic[topicID] = .init(topicID: topicID, relation: decision.relation, tier: "high",
                            verifierQuote: quote, verifierRangeUTF16: range, scoreFeaturesJSON: "{\"evidenceProtocol\":4}")
                        citesUserRuleByTopic[topicID] = repRef == "definition" && candidate.definitionSource == "user"
                    }
                }
            }
        }
        // 长文聚合：明确反证（excludes_category）与正向命中冲突 → 依据不足（不提交也不撤销）
        for (topicID, relations) in relationsSeenByTopic
        where resultsByTopic[topicID] != nil && relations.contains("excludes_category") {
            resultsByTopic[topicID] = nil
            citesUserRuleByTopic[topicID] = nil
            verdictsByTopic[topicID] = "insufficient"
        }
        var verdicts: [ThoughtSchema4CandidateVerdict] = []
        for (topicID, relation) in verdictsByTopic {
            verdicts.append(ThoughtSchema4CandidateVerdict(
                topicID: topicID,
                kind: kindByTopic[topicID] ?? "thread",
                relation: relation,
                citesUserRule: citesUserRuleByTopic[topicID] ?? false,
                verifierQuote: resultsByTopic[topicID]?.verifierQuote,
                verifierRangeUTF16: resultsByTopic[topicID]?.verifierRangeUTF16,
                recallScore: recallScoreByTopic[topicID] ?? 0,
                consistentNone: relation == "none" && (noneChunkCountByTopic[topicID] ?? 0) == requestChunkCount))
        }
        // 差量落库：全部网络判断结束后才提交；shadow 只留回执与诊断，不触 Core Data。
        var selection = ThoughtSchema4Selection.empty
        if commit {
            let allowed = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
            guard allowed, ThoughtSemanticFeatureFlags.relation == .on,
                  ThoughtSemanticFeatureFlags.categoryRulesCoverage(thoughtID: thoughtID) == .live,
                  ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { throw CancellationError() }
            let committed: ThoughtSchema4Selection? = try await context.perform {
                context.refreshAllObjects()
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", thoughtID as CVarArg)
                guard let thought = try context.fetch(request).first,
                      ThoughtSemanticText.contentHash(thought.content) == contentHash,
                      ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration else { return nil }
                // 请求发出与落库之间核对候选规则快照：规则被改 → 过期重排当前批（不落库，交队列重试）
                for (topicID, snapshot) in ruleSnapshotByTopic {
                    guard let topic = Topic.resolveValid(id: topicID, in: context),
                          schema4RulePayload(rawDefinition: topic.categoryDefinition) == snapshot else {
                        throw CancellationError()
                    }
                }
                let links = thought.topicLinks as? Set<ThoughtTopicLink> ?? []
                let existingAutoActive = Set(links.filter { $0.sourceEnum == .aiV3 && $0.stateEnum == .active }
                    .compactMap { $0.topic?.id })
                let selection = selectSchema4Outcome(verdicts: verdicts, existingAutoActiveTopicIDs: existingAutoActive)
                // 撤销只碰 ai/v3 行（用户决定与墓碑由 sourceEnum 过滤天然不动）；
                // 新增侧继续服从 pair 级落库守卫（recordAIV3Decision 内复查墓碑与用户行）。
                for link in links where link.sourceEnum == .aiV3 && link.stateEnum == .active {
                    if let topicID = link.topic?.id, selection.revokedTopicIDs.contains(topicID) {
                        link.stateEnum = .superseded
                        link.updatedAt = Date()
                    }
                }
                var receipts: [String] = []
                for result in selection.affirmed {
                    // 同 id 副本统一解析：此处抓到 merged 旧行会把已判成立的关联静默丢弃
                    guard let topic = Topic.resolveValid(id: result.topicID, in: context) else { continue }
                    if ThoughtTopicLinkProjection.recordAIV3Decision(thought: thought, topic: topic,
                        basisTextHash: contentHash, decisionTier: "high", engineVersion: schema4EngineVersion,
                        consentGeneration: consentGeneration, evidenceRange: result.verifierRangeUTF16) {
                        receipts.append(topic.title)
                    }
                }
                do { if context.hasChanges { try context.save() } }
                catch { context.rollback(); throw error }
                for title in receipts {
                    NotificationCenter.default.post(name: .thoughtTopicLinkDidCommit,
                        object: ["thoughtId": thoughtID, "topicTitle": title], userInfo: ["source": "ai"])
                }
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                return selection
            }
            guard let resolved = committed else { throw CancellationError() }
            selection = resolved
        } else {
            // shadow 模式：仅为回执口径计算（既有归属不参与，也不产生任何写）
            selection = selectSchema4Outcome(verdicts: verdicts, existingAutoActiveTopicIDs: [])
        }
        for result in selection.affirmed {
            try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: result.topicID,
                contentHash: contentHash, scoreFeatures: result.scoreFeaturesJSON, verifierResult: result.relation,
                state: commit ? "committed_high" : "shadow_high", engineVersion: version,
                expiryDays: calibration.candidateExpiryDays, verifierQuote: result.verifierQuote)
        }
        // 判正但容量未入：影子记录留痕（含原因），不再整批 supersede（A10 差量根治）
        for topicID in selection.capacityDeferredTopicIDs {
            try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: topicID,
                contentHash: contentHash, scoreFeatures: "{\"capacityReason\":\"auto_attribution_limit\"}",
                verifierResult: verdictsByTopic[topicID] ?? "evaluated",
                state: "capacity_deferred", engineVersion: version,
                expiryDays: calibration.candidateExpiryDays)
        }
        // 明确负向（类别 excludes_category / 脉络全段一致 none）：撤销留痕
        for topicID in selection.revokedTopicIDs {
            try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: topicID,
                contentHash: contentHash, scoreFeatures: "{\"negative\":1}",
                verifierResult: verdictsByTopic[topicID] ?? "excludes_category",
                state: commit ? "negative_revoked" : "shadow_negative", engineVersion: version,
                expiryDays: calibration.candidateExpiryDays)
        }
        // 哨兵回执：同版本持久化的空结果也算完成态，不重复入队（v4 版本空间）
        var diagnostics: [String: Any] = [:]
        diagnostics["mode"] = v4Mode.rawValue
        if let recallReason = recall.reason { diagnostics["recallReason"] = recallReason }
        diagnostics["recalled"] = recall.candidates.map { $0.topicID.uuidString }
        if !payloadDroppedTopicIDs.isEmpty { diagnostics["payloadDropped"] = payloadDroppedTopicIDs.map(\.uuidString) }
        if !skippedRuleTopics.isEmpty {
            diagnostics["ruleSkipped"] = Dictionary(
                skippedRuleTopics.map { ($0.topicID.uuidString, $0.reason) }, uniquingKeysWith: { first, _ in first })
        }
        if !verdictsByTopic.isEmpty {
            var decisions: [String: String] = [:]
            for (topicID, relation) in verdictsByTopic { decisions[topicID.uuidString] = relation }
            diagnostics["decisions"] = decisions
        }
        if requestChunkCount > 1 { diagnostics["chunks"] = requestChunkCount }
        let diagnosticsJSON = (try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: thoughtID, contentHash: contentHash,
            scoreFeatures: diagnosticsJSON, verifierResult: selection.affirmed.isEmpty ? "no_match" : "evaluated",
            state: commit ? "evaluated" : "shadow", engineVersion: version, expiryDays: calibration.candidateExpiryDays)
        return selection.affirmed
    }

    // MARK: - schema 4 纯函数（请求判据/校验/差量选型，供测试与提交共用）

    /// 类别规则送审判据：脱敏 + 裁剪外缘空白后非空且 ≤240 UTF-16（以实际送审文本为准）。
    /// 历史超限定义保持原文、不静默截断——返回 skip（诊断留痕，该类别跳过评判）。
    static func schema4RulePayload(rawDefinition: String?) -> ThoughtSchema4RulePayload {
        let trimmed = (rawDefinition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noUserRule }
        let redacted = ThoughtIndexV2Policy.redactedText(forUpload: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 脱敏使规则无法判读 → 按依据不足处理（跳过评判，不降级为无规则送判）
        guard !redacted.isEmpty else { return .skip(reason: "category_definition_unreadable") }
        guard redacted.utf16.count <= ThoughtCategoryBriefClient.definitionMaxUTF16 else {
            return .skip(reason: "category_definition_too_long")
        }
        return .user(definition: redacted)
    }

    /// schema 4 关系约束（通道交叉，方案 §4 A2 字段表）：类别禁 same_thread；
    /// 内容脉络禁 fits_category/excludes_category；excludes_category 只允许 category + user。
    /// 校验不过抛协议错误（落回既有归属，不生成空结果回执）。
    static func validateSchema4RelationConstraints(relation: String, kind: String?, definitionSource: String?) throws {
        guard schema4AllowedRelations.contains(relation) else {
            throw ThoughtTopicVerifierError.responseContractViolation(reason: "relation_enum")
        }
        if kind == "category" && relation == "same_thread" {
            throw ThoughtTopicVerifierError.responseContractViolation(reason: "relation_cross_kind")
        }
        if kind == "thread" && (relation == "fits_category" || relation == "excludes_category") {
            throw ThoughtTopicVerifierError.responseContractViolation(reason: "relation_cross_kind")
        }
        if relation == "excludes_category" && definitionSource != "user" {
            throw ThoughtTopicVerifierError.responseContractViolation(reason: "excludes_category_requires_user_rule")
        }
    }

    /// excludes_category 证据完备性（四件套）：目标 quote/rangeUTF16 逐字可回源 +
    /// representativeRef=="definition" + representativeQuote 逐字回源用户规则。
    /// 任一缺失即协议错误，不得当作排除（方案 §4 A2）。
    static func validateSchema4ExclusionEvidence(quote: String?, rangeUTF16: [Int]?, chunkText: String,
                                                 representativeRef: String?, representativeQuote: String?,
                                                 ruleDefinition: String?) throws {
        guard let quote, isQuoteVerbatim(quote, in: chunkText, rangeUTF16: rangeUTF16),
              representativeRef == "definition",
              let ruleQuote = representativeQuote, !ruleQuote.isEmpty,
              let ruleDefinition, ruleDefinition.contains(ruleQuote) else {
            throw ThoughtTopicVerifierError.responseContractViolation(reason: "excludes_category_evidence")
        }
    }

    /// schema 4 服务端拒判识别：灰度关闭（THOUGHT_SCOPE_RULES_DISABLED）、请求契约
    /// 拒绝（4xx/INVALID_REQUEST）或本端复核的协议违约/解码失败。命中后停发新版请求。
    static func isSchema4ProtocolRejection(_ error: Error) -> Bool {
        if error is ThoughtTopicVerifierError { return true }
        if case APIError.decodingError = error { return true }
        if case APIError.httpError(let status, _) = error, (400...499).contains(status) { return true }
        if case APIError.backendError(_, let code, _, _) = error {
            if code == "THOUGHT_SCOPE_RULES_DISABLED" || code == "INVALID_REQUEST" { return true }
        }
        return false
    }

    /// schema 4 差量选型（纯函数）：落库只对本次实际覆盖到的主题做差量——
    /// · 未召回/未送判/容量未送的既有 AI 归属一律保留（retained，不再整批 supersede）；
    /// · 只有明确负向（类别 excludes_category、脉络全段一致 none）才撤销既有 AI 归属；
    /// · 历史超限时只移除明确负向、不加新项；
    /// · 新正项按「引用用户规则的类别匹配 > 双侧证据同脉络 > 代表例匹配」排剩余名额，
    ///   同档按召回质量、稳定 ID 平局；超出记录容量原因（capacityDeferred）。
    /// 输入 existingAutoActiveTopicIDs 只数 ai/v3 行——手动关系不占额也不被修改。
    static func selectSchema4Outcome(verdicts: [ThoughtSchema4CandidateVerdict],
                                     existingAutoActiveTopicIDs: Set<UUID>,
                                     autoAttributionLimit: Int = ThoughtTopicVerifier.autoAttributionLimit) -> ThoughtSchema4Selection {
        var revoked: Set<UUID> = []
        for verdict in verdicts {
            if verdict.relation == "excludes_category" { revoked.insert(verdict.topicID) }
            if verdict.kind == "thread" && verdict.relation == "none" && verdict.consistentNone {
                revoked.insert(verdict.topicID)
            }
        }
        let retained = existingAutoActiveTopicIDs.subtracting(revoked)
        func tier(of verdict: ThoughtSchema4CandidateVerdict) -> Int {
            if verdict.kind == "category" && verdict.relation == "fits_category" && verdict.citesUserRule { return 0 }
            if verdict.relation == "same_thread" { return 1 }
            return 2
        }
        let ranked = verdicts.filter { $0.relation == "same_thread" || $0.relation == "fits_category" }
            .sorted {
                let (ta, tb) = (tier(of: $0), tier(of: $1))
                if ta != tb { return ta < tb }
                if $0.recallScore != $1.recallScore { return $0.recallScore > $1.recallScore }
                return $0.topicID.uuidString < $1.topicID.uuidString
            }
        var slots = max(0, autoAttributionLimit - retained.count)
        var affirmed: [ThoughtRelationDecision] = []
        var deferred: [UUID] = []
        for verdict in ranked {
            if existingAutoActiveTopicIDs.contains(verdict.topicID) {
                // 既有自动归属本轮再获正向：只续期（刷新依据），不占新名额
                affirmed.append(.init(topicID: verdict.topicID, relation: verdict.relation, tier: "high",
                    verifierQuote: verdict.verifierQuote, verifierRangeUTF16: verdict.verifierRangeUTF16,
                    scoreFeaturesJSON: "{\"evidenceProtocol\":4,\"tier\":\(tier(of: verdict)),\"reaffirmed\":1}"))
                continue
            }
            if slots > 0 {
                slots -= 1
                affirmed.append(.init(topicID: verdict.topicID, relation: verdict.relation, tier: "high",
                    verifierQuote: verdict.verifierQuote, verifierRangeUTF16: verdict.verifierRangeUTF16,
                    scoreFeaturesJSON: "{\"evidenceProtocol\":4,\"tier\":\(tier(of: verdict))}"))
            } else {
                deferred.append(verdict.topicID)
            }
        }
        return ThoughtSchema4Selection(affirmed: affirmed, revokedTopicIDs: revoked,
                                       capacityDeferredTopicIDs: deferred, retainedTopicIDs: retained)
    }

    static func isQuoteVerbatim(_ quote: String, in text: String, rangeUTF16: [Int]?) -> Bool {
        ThoughtSemanticText.quoteMatches(quote, text: text, range: rangeUTF16)
    }
}
