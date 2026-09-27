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
import Foundation
import OSLog

// MARK: - 传输 DTO（与后端 §16.2 契约对齐）

struct ThoughtSemanticRelateRequestDTO: Codable {
    struct Target: Codable { let ref: String; let text: String }
    struct Representative: Codable { let ref: String; let text: String }
    struct Candidate: Codable {
        let ref: String
        let title: String
        let summary: String?
        let representatives: [Representative]
    }
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let engineVersion: String
    let target: Target
    let candidates: [Candidate]
}

struct ThoughtSemanticRelateResponseDTO: Codable {
    struct Decision: Codable {
        let candidateRef: String
        let relation: String
        let quote: String?
        let rangeUTF16: [Int]?
    }
    let schemaVersion: Int
    let operationId: String
    let textRevision: String
    let decisions: [Decision]
}

// MARK: - 决策结果

struct ThoughtRelationDecision: Codable, Equatable {
    var topicID: UUID
    var relation: String          // same_thread / related / none / insufficient
    var tier: String              // high / medium / low
    var verifierQuote: String?
    var verifierRangeUTF16: [Int]?   // 证据区间（正式提交时随 basisTextHash 落库）
    var scoreFeaturesJSON: String
}

enum ThoughtTopicVerifierError: Error {
    case candidateBuildFailed
    case responseContractViolation(reason: String)
}

enum ThoughtTopicVerifier {

    static let engineVersion = "thought_semantic_v3.0"
    private static let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtTopicVerifier")

    /// 影子执行一次完整判断：召回 → 构造最小请求 → 云端验证 → 客户端二次校验 → 分层。
    /// 返回逐候选决策（含 low）。网络类失败上抛（P0-C：relate 任务化后由执行器
    /// 退避重试，不再静默丢弃）；候选召回为空等合法空结果返回 []。
    /// consentGeneration：发起时授权代数快照，relate 网络往返后提交前逐项重验（P0-B）。
    static func shadowEvaluate(thoughtID: UUID,
                               redactedText: String,
                               contentHash: String,
                               targetVector: [Float],
                               store: ThoughtSemanticStore,
                               index: (any LocalSemanticIndex)?,
                               context: NSManagedObjectContext,
                               provider: HoloBackendAIProvider,
                               calibration: ThoughtSemanticCalibration,
                               consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        try await evaluate(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
                           targetVector: targetVector, store: store, index: index, context: context,
                           provider: provider, calibration: calibration, commitHighTier: false,
                           consentGeneration: consentGeneration)
    }

    /// 正式评估（relation=on 且校准通过时）：high tier 决策原子提交为
    /// ai/v3 + weakVisible 的有效 ThoughtTopicLink（方案 §3 P0）。
    /// 用户拒绝墓碑与用户 active 由投影层让位（isUserDecision 优先）。
    /// 网络类失败上抛（P0-C），由 relate 执行器退避重试。
    static func evaluateAndCommit(thoughtID: UUID,
                                  redactedText: String,
                                  contentHash: String,
                                  targetVector: [Float],
                                  store: ThoughtSemanticStore,
                                  index: (any LocalSemanticIndex)?,
                                  context: NSManagedObjectContext,
                                  provider: HoloBackendAIProvider,
                                  calibration: ThoughtSemanticCalibration,
                                  consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {
        try await evaluate(thoughtID: thoughtID, redactedText: redactedText, contentHash: contentHash,
                           targetVector: targetVector, store: store, index: index, context: context,
                           provider: provider, calibration: calibration, commitHighTier: true,
                           consentGeneration: consentGeneration)
    }

    /// 评估内核：shadow 与正式提交共用（召回/请求/二次校验/分层一致，
    /// 差异只在 high tier 是否落 ThoughtTopicLink）。
    private static func evaluate(thoughtID: UUID,
                                 redactedText: String,
                                 contentHash: String,
                                 targetVector: [Float],
                                 store: ThoughtSemanticStore,
                                 index: (any LocalSemanticIndex)?,
                                 context: NSManagedObjectContext,
                                 provider: HoloBackendAIProvider,
                                 calibration: ThoughtSemanticCalibration,
                                 commitHighTier: Bool,
                                 consentGeneration: Int64) async throws -> [ThoughtRelationDecision]? {

        // 1. 召回
        let recallOutcome = await ThoughtTopicCandidateEngine.recall(
            targetVector: targetVector, thoughtID: thoughtID,
            store: store, index: index, context: context, calibration: calibration)
        guard !recallOutcome.candidates.isEmpty else {
            try? await store.recordRelationCandidate(
                thoughtID: thoughtID, topicID: UUID(), contentHash: contentHash,
                scoreFeatures: "{}", verifierResult: "no_recall:\(recallOutcome.reason ?? "none")",
                state: "expired", engineVersion: engineVersion,
                expiryDays: calibration.candidateExpiryDays)
            return []
        }
        let candidates = recallOutcome.candidates

        // 2. 候选上下文：每主题 ≤3 条代表片段（成员想法正文脱敏后截断 240 UTF-16）
        var requestCandidates: [ThoughtSemanticRelateRequestDTO.Candidate] = []
        for (i, candidate) in candidates.enumerated() {
            let reps = await representativeTexts(topicID: candidate.topicID, context: context)
            guard !reps.isEmpty else { continue }
            requestCandidates.append(.init(
                ref: "P\(i)",
                title: String(candidate.topicTitle.prefix(32)),
                summary: nil,
                representatives: reps.enumerated().map { .init(ref: "R\($0.offset)", text: $0.element) }))
        }
        guard !requestCandidates.isEmpty else { return nil }

        // 3. 云端验证
        let request = ThoughtSemanticRelateRequestDTO(
            schemaVersion: 1,
            operationId: UUID().uuidString,
            textRevision: contentHash,
            engineVersion: engineVersion,
            target: .init(ref: "T0", text: String(redactedText.prefix(4_000))),
            candidates: requestCandidates)
        let response: ThoughtSemanticRelateResponseDTO
        do {
            response = try await provider.semanticRelate(request)
        } catch {
            // P0-C：网络类失败上抛给 relate 执行器退避重试（不再静默返回 nil）
            logger.debug("relate 调用失败（将由队列重试）：\(error.localizedDescription)")
            throw error
        }

        // 4. 客户端二次校验（§9.2 步骤 7）：quote 逐字存在 + range 对齐 + ref 白名单
        let allowedRefs = Set(requestCandidates.map(\.ref))
        var verified: [ThoughtSemanticRelateResponseDTO.Decision] = []
        for decision in response.decisions {
            guard allowedRefs.contains(decision.candidateRef) else { continue }
            if decision.quote != nil {
                guard let quote = decision.quote,
                      isQuoteVerbatim(quote, in: redactedText, rangeUTF16: decision.rangeUTF16)
                else { continue } // 证据不逐字=整条丢弃
            }
            verified.append(decision)
        }

        // 5. 决策分层（§10.2）：verifier 离散结论 × 独立信号，不使用任何自报置信度
        let sorted = candidates.sorted { $0.recallScore > $1.recallScore }
        let topScore = sorted.first?.recallScore ?? 0
        let secondScore = sorted.dropFirst().first?.recallScore ?? 0
        let margin = topScore - secondScore

        var decisions: [ThoughtRelationDecision] = []
        for decision in verified {
            guard let index = Int(decision.candidateRef.dropFirst()), index < candidates.count else { continue }
            let candidate = candidates[index]
            let features: [String: Float] = [
                "centroid": candidate.centroidCosine ?? -1,
                "votes": Float(candidate.neighborVotes),
                "neighborMean": candidate.neighborMeanCosine,
                "margin": margin,
            ]
            let tier = decideTier(relation: decision.relation,
                                  hasQuote: decision.quote != nil,
                                  topScore: topScore,
                                  margin: margin,
                                  isTopCandidate: candidate.topicID == sorted.first?.topicID,
                                  calibration: calibration)
            let result = ThoughtRelationDecision(
                topicID: candidate.topicID,
                relation: decision.relation,
                tier: tier,
                verifierQuote: decision.quote,
                verifierRangeUTF16: decision.rangeUTF16,
                scoreFeaturesJSON: (try? JSONEncoder().encode(features)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            decisions.append(result)

            // shadow 记录（无正文：features 数字 + verifier 离散结论；
            // quote 原文片段随记录落库供 P1 回源——P0-B）
            try? await store.recordRelationCandidate(
                thoughtID: thoughtID, topicID: candidate.topicID, contentHash: contentHash,
                scoreFeatures: result.scoreFeaturesJSON,
                verifierResult: decision.relation,
                state: commitHighTier ? "committed_\(tier)" : "shadow_\(tier)",
                engineVersion: engineVersion,
                expiryDays: calibration.candidateExpiryDays,
                verifierQuote: decision.quote)

            // 正式提交：仅 high tier 落有效 link（拒绝墓碑/用户 active 由投影层让位）
            if commitHighTier, tier == "high" {
                await commitDecision(result, thoughtID: thoughtID, contentHash: contentHash,
                                     context: context, calibration: calibration,
                                     consentGeneration: consentGeneration)
            }
        }
        return decisions
    }

    /// high tier 决策原子提交：读回 thought/topic → 投影层写入 → 同一 context save。
    /// 对象不存在/已被删/正文版本变化/授权已撤回或代数已变时静默放弃
    /// （晚到结果不落旧版本，P0-B：relate 网络往返后逐项重验，与 embed 路径同款守卫）。
    private static func commitDecision(_ decision: ThoughtRelationDecision,
                                       thoughtID: UUID,
                                       contentHash: String,
                                       context: NSManagedObjectContext,
                                       calibration: ThoughtSemanticCalibration,
                                       consentGeneration: Int64) async {
        // 授权重验必须在 context.perform 外做（MainActor 标记的 consent 读取）；
        // 撤回后迟到的 relate 结果直接丢弃，不落库也不盖新代数
        let consentStillValid = await MainActor.run {
            ThoughtSemanticFeatureFlags.consentGeneration == consentGeneration
                && HoloAIDataProcessingConsent.shared.isGranted
        }
        guard consentStillValid else {
            logger.notice("迟到 relate 决策丢弃 thought=\(thoughtID)（授权已撤回或代数已变）")
            return
        }

        let topicID = decision.topicID
        await context.perform {
            let thoughtRequest = Thought.fetchRequest()
            thoughtRequest.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", thoughtID as CVarArg)
            thoughtRequest.fetchLimit = 1
            guard let thought = (try? context.fetch(thoughtRequest))?.first,
                  let currentContent = thought.value(forKey: "content") as? String,
                  ThoughtEmbeddingStore.contentHash(of: currentContent) == contentHash else { return }

            let topicRequest = Topic.fetchRequest()
            topicRequest.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", topicID as CVarArg)
            topicRequest.fetchLimit = 1
            guard let topic = (try? context.fetch(topicRequest))?.first else { return }

            _ = ThoughtTopicLinkProjection.recordAIV3Decision(
                thought: thought, topic: topic,
                basisTextHash: contentHash,
                decisionTier: decision.tier,
                engineVersion: engineVersion,
                consentGeneration: consentGeneration,
                evidenceRange: decision.verifierRangeUTF16)
            // 保存失败不再静默吞（P0-B）：显式记日志暴露，下一轮 relate 补跑可自愈；
            // 成功后广播归入回执（P1 §3.2：卡片一次性短暂 toast，object 供列表过滤）
            do {
                try context.save()
                NotificationCenter.default.post(
                    name: .thoughtTopicLinkDidCommit,
                    object: ["thoughtId": thoughtID, "topicTitle": topic.title],
                    userInfo: ["source": "ai"])
                // 数据变更同步广播：侧栏计数/主题详情/列表卡片都监听本通知刷新——
                // 校验实锤（2026-09-27）：只发回执通知时三处全部滞后到下一次数据变化
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            } catch {
                logger.error("relate link 保存失败 thought=\(thoughtID) topic=\(topicID)：\(error.localizedDescription)")
                context.rollback()
            }
        }
    }

    /// quote 逐字校验：range 先验边界（模型可能返回负数/倒序/越界，NSString 越界
    /// substring 直接崩溃——2026-09-24 方案 §3 P0），切片后须与 quote 完全一致。
    static func isQuoteVerbatim(_ quote: String, in text: String, rangeUTF16: [Int]?) -> Bool {
        guard let range = rangeUTF16, range.count == 2,
              range[0] >= 0, range[1] >= range[0],
              range[1] <= text.utf16.count else { return false }
        let ns = text as NSString
        return ns.substring(with: NSRange(location: range[0], length: range[1] - range[0])) == quote
    }

    /// §10.2 分层规则（数值全部来自校准配置）。
    private static func decideTier(relation: String,
                                   hasQuote: Bool,
                                   topScore: Float,
                                   margin: Float,
                                   isTopCandidate: Bool,
                                   calibration: ThoughtSemanticCalibration) -> String {
        switch relation {
        case "same_thread":
            if hasQuote, topScore >= calibration.recallMinCosine,
               margin >= calibration.marginMinDelta, isTopCandidate {
                return "high"
            }
            return "medium"
        case "related":
            return "medium"
        default:
            return "low"
        }
    }

    /// 主题代表片段：成员想法按时间分布取 ≤3 条（最早/最新/中间），脱敏后截断 240 UTF-16。
    private static func representativeTexts(topicID: UUID, context: NSManagedObjectContext) async -> [String] {
        await context.perform {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil AND ANY topicLinks.topic.id == %@ AND ANY topicLinks.state == %@",
                                             topicID as CVarArg, "active")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            let thoughts = (try? context.fetch(request)) ?? []
            guard !thoughts.isEmpty else { return [] }
            let picks: [Thought]
            switch thoughts.count {
            case 1, 2, 3: picks = Array(thoughts)
            default: picks = [thoughts[0], thoughts[thoughts.count / 2], thoughts[thoughts.count - 1]]
            }
            return picks.map { String(ThoughtIndexV2Policy.redactedText(forUpload: $0.content).prefix(240)) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}
