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

nonisolated enum ThoughtTopicVerifierError: Error {
    case candidateBuildFailed
    case responseContractViolation(reason: String)
}

nonisolated enum ThoughtTopicVerifier {
    /// v3.2（2026-10-12 主题双通道）：schema 3 + fits_category；类别通道与脉络通道独立判定。
    static let engineVersion = "thought_semantic_v3.2"
    static let requestSchemaVersion = 3
    /// 归属型关系（要求双侧逐字证据）：same_thread=同内容脉络；fits_category=符合用户类别定义
    private static let committingRelations: Set<String> = ["same_thread", "fits_category"]
    private static let allowedRelations: Set<String> = ["same_thread", "fits_category", "related", "none", "insufficient"]

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
        let version = await evaluationVersion(context: context)
        let recall = try await ThoughtTopicCandidateEngine.recall(targetVector: targetVector, thoughtID: thoughtID,
            store: store, index: index, context: context, calibration: calibration, provider: provider)
        var candidates: [ThoughtSemanticRelateRequestDTO.Candidate] = []
        var topicByRef: [String: UUID] = [:]
        var payloadDroppedTopicIDs: [UUID] = []
        for candidate in recall.candidates {
            let ref = "P" + String(candidates.count)
            let payload = await context.perform { () -> ThoughtSemanticRelateRequestDTO.Candidate? in
                // 同 id 副本统一解析：抓到 merged 旧行会把候选在 AI 调用前静默丢掉
                guard let topic = Topic.resolveValid(id: candidate.topicID, in: context) else { return nil }
                let thoughtRequest = Thought.fetchRequest()
                thoughtRequest.predicate = NSPredicate(format: "deletedAt == nil AND isArchived == NO AND id != %@ AND ANY topicLinks.topic.id == %@", thoughtID as CVarArg, topic.id as CVarArg)
                let members = ((try? context.fetch(thoughtRequest)) ?? []).filter { ThoughtTopicLinkProjection.isEffectiveMember($0, of: topic) }
                // 类别候选代表例「用户确认优先」（doc §3：避免 AI 自己的历史选择定义类别）；
                // 脉络候选维持最近优先。
                let ordered: [Thought]
                if candidate.kind == "category" {
                    ordered = members.sorted {
                        let sa = ThoughtTopicLinkProjection.categorySampleRank(of: $0, in: topic)
                        let sb = ThoughtTopicLinkProjection.categorySampleRank(of: $1, in: topic)
                        if sa != sb { return sa < sb }
                        return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                    }
                } else {
                    ordered = members.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                }
                let representatives = ordered.prefix(3).map {
                    ThoughtSemanticRelateRequestDTO.Representative(ref: $0.id.uuidString,
                        text: ThoughtSemanticText.prefix(ThoughtIndexV2Policy.redactedText(forUpload: $0.content), maxUTF16: 240))
                }.filter { !$0.text.isEmpty }
                return .init(ref: ref, title: ThoughtSemanticText.prefix(topic.title, maxUTF16: 32),
                    summary: topic.summary.map { ThoughtSemanticText.prefix($0, maxUTF16: 240) },
                    kind: candidate.kind,
                    definition: candidate.kind == "category"
                        ? topic.categoryDefinition.map { ThoughtSemanticText.prefix($0, maxUTF16: 240) }
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
    static func isQuoteVerbatim(_ quote: String, in text: String, rangeUTF16: [Int]?) -> Bool {
        ThoughtSemanticText.quoteMatches(quote, text: text, range: rangeUTF16)
    }
}
