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
    /// 返回逐候选决策（含 low）；失败返回 nil（shadow 静默，不打扰主流程）。
    static func shadowEvaluate(thoughtID: UUID,
                               redactedText: String,
                               contentHash: String,
                               targetVector: [Float],
                               store: ThoughtSemanticStore,
                               index: (any LocalSemanticIndex)?,
                               context: NSManagedObjectContext,
                               provider: HoloBackendAIProvider,
                               calibration: ThoughtSemanticCalibration) async -> [ThoughtRelationDecision]? {

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
            logger.debug("relate 调用失败（shadow 静默）：\(error.localizedDescription)")
            return nil
        }

        // 4. 客户端二次校验（§9.2 步骤 7）：quote 逐字存在 + range 对齐 + ref 白名单
        let allowedRefs = Set(requestCandidates.map(\.ref))
        var verified: [ThoughtSemanticRelateResponseDTO.Decision] = []
        for decision in response.decisions {
            guard allowedRefs.contains(decision.candidateRef) else { continue }
            if decision.quote != nil {
                guard let quote = decision.quote,
                      let range = decision.rangeUTF16, range.count == 2,
                      (redactedText as NSString).substring(with: NSRange(location: range[0], length: range[1] - range[0])) == quote
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
                scoreFeaturesJSON: (try? JSONEncoder().encode(features)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            decisions.append(result)

            // shadow 记录（无正文：features 数字 + verifier 离散结论）
            try? await store.recordRelationCandidate(
                thoughtID: thoughtID, topicID: candidate.topicID, contentHash: contentHash,
                scoreFeatures: result.scoreFeaturesJSON,
                verifierResult: decision.relation,
                state: "shadow_\(tier)",
                engineVersion: engineVersion,
                expiryDays: calibration.candidateExpiryDays)
        }
        return decisions
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
