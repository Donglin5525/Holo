//
//  ThoughtFollowupProjection.swift
//  Holo
//
//  想法脉络核对读侧投影与统一资格（W3，2026-11-16 方案 §6 C3 / §5 B1 / §2 A08）
//
//  主题页脉络卡与编辑器「相关旧想法」读同一张 evidence 关系投影（§6 C1），资格
//  与投影共用一个函数——视图零资格判断：非试点主题 / 授权断 / 试点关 / 能力失效
//  时 activeThreadCards 返回空数组；verifiedRelations 另内建「显示相关笔记」
//  开关与试点范围判断（§5 B1「相关区还需现有显示相关笔记开关」）。
//
//  读侧资格内建（§2 A08「上传前、提交前、投影时用统一资格和版本校验」）：
//  · 试点开关链：AI 处理授权 + 智能整理 + 自动成主题 + 试点范围 == 当前 scopeID；
//  · 服务器能力：只读 ≤5 分钟内存缓存，读路径不出网——缓存由协调器心跳保温，
//    过期/离线即隐藏新增派生卡（§6 C2「离线且能力过期时隐藏」）；
//  · verified 结果 30 天 / 每主题 200 批次过期先隐藏（与 pruneFollowupRetention
//    同参数，§6 C3）；
//  · 每个 source 的文本处理版本与正文 hash 对当前脱敏正文再验（编辑/移出/排除/
//    归档/删除后 ChangeFeed 已清的兜底，读时再验）：任何一个来源失效 → 整批
//    隐藏（§6 C3「共用上下文生成的整个批次失效」）。
//
//  跨 actor 只传值快照；显示句柄只从本机 source 映射绑定（§6 C3）。
//

import CoreData
import Foundation

// MARK: - 对外值类型（UI 路按此调用，签名稳定）

nonisolated struct FollowupCardSource {
    let thoughtID: UUID
    let createdAt: Date
    let isAnchor: Bool
    let excerpt: String
}

nonisolated struct FollowupThreadCard {
    let localID: UUID
    let title: String
    let question: String
    let supportCount: Int
    let sources: [FollowupCardSource]
}

nonisolated struct FollowupVerifiedRelation {
    let fromThoughtID: UUID
    let relationKind: String
    let reason: String
    let evidenceQuote: String
}

/// 设置页三档诊断（§1「等待整理 / 已核对 / 稍后重试」）。
nonisolated enum FollowupPilotStatus {
    case waiting
    case verified
    case retryLater
}

// MARK: - 投影（静态方法入口，同 ThoughtTopicLinkProjection 惯例）

nonisolated enum ThoughtFollowupProjection {

    /// 打开中的脉络/相关视图收到后立即撤掉旧证据并重读投影（§6 C3
    /// 「打开中的视图收到失效事件立即撤掉旧证据」）。ChangeFeed 在定向清理、
    /// 撤权、设置变化与索引销毁后发送。
    static let followupDerivedDidChange = Notification.Name("thoughtFollowupDerivedDidChange")

    /// 结果过期先隐藏的界限（§6 C3：与 pruneFollowupRetention 同参数）。
    static let resultMaxAge: TimeInterval = 30 * 86_400
    static let maxBatchesPerScope = 200

    // MARK: 主题页脉络卡（≤2，已含压制/排序/资格过滤，§5 B2）

    static func activeThreadCards(scopeID: UUID) async throws -> [FollowupThreadCard] {
        guard await ThoughtFollowupReadSupport.chainHolds(scopeID: scopeID),
              await ThoughtFollowupReadSupport.capabilityHolds() else { return [] }
        guard let store = await ThoughtSemanticPipeline.shared.store else { return [] }
        let batches = try await ThoughtFollowupReadSupport.validatedBatches(store: store, scopeID: scopeID)
        let dismissals = (try? await store.followupDismissals(scopeID: scopeID)) ?? []
        // 候选 = thread 非 nil 的 verified 批次：thread 成员经校验器逐条有成立
        // 关系（§6 C2），有效支持数 = 成员数；相同成员集合由 formThreadCards 合并。
        let candidates: [ThoughtFollowupSampling.ThreadCandidate] = batches.compactMap { batch in
            guard let threadID = batch.result.threadID,
                  batch.result.threadTitle != nil,
                  batch.result.threadMemberIDs.count >= ThoughtFollowupContract.threadMembersMin else { return nil }
            return ThoughtFollowupSampling.ThreadCandidate(
                displayID: threadID,
                memberIDs: Set(batch.result.threadMemberIDs),
                supportCount: batch.result.threadMemberIDs.count,
                latestEvidenceAt: batch.sources.map(\.frozenCreatedAt).max() ?? batch.result.verifiedAt ?? Date())
        }
        let formed = ThoughtFollowupSampling.formThreadCards(
            candidates: candidates,
            dismissals: dismissals.map {
                ThoughtFollowupSampling.ThreadDismissal(displayID: $0.threadID, memberIDs: Set($0.memberIDs))
            })
        // displayID → 展示批次（thread local ID 一次核对生成一个，同键取最近 verified）
        var batchByThreadID: [String: ThoughtFollowupReadSupport.ValidatedBatch] = [:]
        for batch in batches {
            guard let threadID = batch.result.threadID else { continue }
            if let existing = batchByThreadID[threadID],
               (existing.result.verifiedAt ?? .distantPast) >= (batch.result.verifiedAt ?? .distantPast) { continue }
            batchByThreadID[threadID] = batch
        }
        var cards: [FollowupThreadCard] = []
        for card in formed {
            guard let batch = batchByThreadID[card.displayID],
                  let title = batch.result.threadTitle,
                  let question = batch.result.threadQuestion,
                  let localID = UUID(uuidString: card.displayID) else { continue }
            // 来源按时间排好（§1「按时间排好的 3–5 条来源」）；日期用当前可核验的
            // 记录时间（§6 C1），角色与摘录取窗口文本
            let sources = batch.result.threadMemberIDs
                .sorted { (batch.frozenCreatedAts[$0] ?? .distantPast) < (batch.frozenCreatedAts[$1] ?? .distantPast) }
                .compactMap { memberID -> FollowupCardSource? in
                    guard let source = batch.sources.first(where: { $0.thoughtID == memberID }) else { return nil }
                    let createdAt = batch.currentCreatedAts[memberID] ?? source.frozenCreatedAt
                    return FollowupCardSource(
                        thoughtID: memberID,
                        createdAt: createdAt,
                        isAnchor: memberID == batch.result.anchorID,
                        excerpt: ThoughtFollowupReadSupport.windowExcerpt(source: source,
                                                                          redacted: batch.redactedTexts[memberID]))
                }
            guard sources.count >= ThoughtFollowupContract.threadMembersMin else { continue }
            cards.append(FollowupThreadCard(localID: localID, title: title, question: question,
                                             supportCount: card.supportCount, sources: sources))
        }
        return cards
    }

    // MARK: 相关旧想法（当前笔记在试点范围内时，从较早回看当前，≤2，§6 C1）

    static func verifiedRelations(for thoughtID: UUID) async throws -> [FollowupVerifiedRelation] {
        guard let scopeID = ThoughtSemanticFeatureFlags.followupPilotScope() else { return [] }
        guard await ThoughtFollowupReadSupport.chainHolds(scopeID: scopeID),
              await ThoughtFollowupReadSupport.capabilityHolds(),
              // 相关区还需现有显示相关笔记开关（§5 B1；视图零资格判断）
              ThoughtSemanticFeatureFlags.resurfacingEnabled else { return [] }
        guard let store = await ThoughtSemanticPipeline.shared.store else { return [] }
        let batches = try await ThoughtFollowupReadSupport.validatedBatches(store: store, scopeID: scopeID)
        // 当前笔记有效且位于试点范围（§6 C1「只在当前笔记有效且位于试点范围时读取」）
        let involving = batches.filter { batch in batch.sources.contains { $0.thoughtID == thoughtID } }
        guard !involving.isEmpty,
              let currentFrozen = involving.compactMap({ $0.frozenCreatedAts[thoughtID] }).min() else { return [] }

        struct Candidate {
            var from: UUID
            var kind: String
            var reason: String
            var quote: String
            var rank: Int
            var verifiedAt: Date
        }
        // 优先明确的修正、关键对照和补充（§6 C1「优先明确的修正、关键对照和补充」）
        let ranks = ["revises": 0, "contrasts": 1, "adds_example": 2, "continues": 3]
        var byFrom: [UUID: Candidate] = [:]
        for batch in involving {
            let anchorID = batch.result.anchorID
            for decision in batch.result.decisions {
                guard ThoughtFollowupContract.establishedRelations.contains(decision.relation),
                      let reason = decision.reason,
                      let otherEvidence = ThoughtFollowupReadSupport.pairmate(batch: batch,
                                                                              anchorID: anchorID,
                                                                              decision: decision,
                                                                              currentThoughtID: thoughtID),
                      let otherFrozen = batch.frozenCreatedAts[otherEvidence.otherID] else { continue }
                // 从较早回看当前：仅保留对方冻结创建时间早于当前的 pair；时间相同
                // 仅允许对照，不声称先后变化（§6 C1）
                let earlier = otherFrozen < currentFrozen
                let sameTimeContrast = otherFrozen == currentFrozen && decision.relation == "contrasts"
                guard earlier || sameTimeContrast else { continue }
                let candidate = Candidate(from: otherEvidence.otherID,
                                          kind: decision.relation,
                                          reason: reason,
                                          quote: otherEvidence.quote,
                                          rank: ranks[decision.relation] ?? ranks.count,
                                          verifiedAt: batch.result.verifiedAt ?? .distantPast)
                if let existing = byFrom[candidate.from],
                   existing.rank < candidate.rank
                    || (existing.rank == candidate.rank && existing.verifiedAt >= candidate.verifiedAt) { continue }
                byFrom[candidate.from] = candidate
            }
        }
        return byFrom.values
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.from.uuidString < $1.from.uuidString
            }
            .prefix(2)   // 每条最多取两条（§6 C1）
            .map { FollowupVerifiedRelation(fromThoughtID: $0.from, relationKind: $0.kind,
                                            reason: $0.reason, evidenceQuote: $0.quote) }
    }

    // MARK: 隐藏一条脉络（写 dismissal，立即生效，§5 B2/§6 C3）

    static func hideThread(localID: UUID, scopeID: UUID) async throws {
        guard let store = await ThoughtSemanticPipeline.shared.store else { return }
        // 隐藏回执带确认展示过的成员 ID 集合（高重叠压制用，§6 C3 Dismissal 行）
        let results = (try? await store.followupResults(scopeID: scopeID)) ?? []
        let members = results.first(where: { $0.threadID == localID.uuidString })?.threadMemberIDs ?? []
        try await store.recordFollowupDismissal(scopeID: scopeID,
                                                threadID: localID.uuidString,
                                                memberIDs: members)
        NotificationCenter.default.post(name: followupDerivedDidChange, object: nil)
    }

    // MARK: 手动重试（诊断页「稍后重试」三档联动）

    /// 手动重试（诊断页「稍后重试」）：failed 与未到期 waiting 有界复位为 pending
    ///（定向人工复测的解冻口径，§6 C2 末条；attempt 口径不动，日额度仍在领取处
    /// 强制 ≤4，§5 B1「不得通过手动入口绕过新核对上限」），随后立即自踢一轮
    /// 受控处理——直调协调器的被动入口，与谷窗心跳同一领取/单飞路径。
    static func requestRetry(scopeID: UUID) async throws {
        guard await ThoughtFollowupReadSupport.chainHolds(scopeID: scopeID) else { return }
        guard let store = await ThoughtSemanticPipeline.shared.store else { return }
        try await store.retryFollowupTasks(scopeID: scopeID)
        await ThoughtFollowupCoordinator.shared.process(store: store)
    }

    // MARK: 试点三档诊断（设置页）

    /// 判定口径（§1「等待整理 / 已核对 / 稍后重试」，数据来自 Store 队列快照）：
    /// 1. 完成终态（verified 含空结果 no_result）存在且无任何在途 → 已核对；
    /// 2. 存在 failed 或已到重试时刻的 waiting → 稍后重试（重试入口可点亮）；
    /// 3. 其余（排队 / 处理中 / 未到期等待 / 尚无任务）→ 等待整理。
    static func pilotStatus(scopeID: UUID) async throws -> FollowupPilotStatus {
        guard let store = await ThoughtSemanticPipeline.shared.store else { return .waiting }
        let queue = try await store.followupQueueStatus(scopeID: scopeID)
        if queue.inFlight == 0, queue.completed > 0 { return .verified }
        if queue.failed > 0 || queue.waitingDue > 0 { return .retryLater }
        return .waiting
    }
}

// MARK: - 读侧共享支持（投影与 ChangeFeed 定向清理共用，§6 C3「共用一个资格函数」）

nonisolated enum ThoughtFollowupReadSupport {

    /// 范围当前事实快照（值出上下文，§6 C3「对象跨 actor 仅传值快照」）。
    struct ScopeFacts {
        var scopeValid: Bool
        /// thoughtID → 当前脱敏正文 hash；缺项 = 当前不可用作 source
        /// （已删 / 归档 / 排除 / 非有效成员 / 正文为空，§6 C3 读时再验兜底）
        var eligibleHashes: [UUID: String]
        var createdAts: [UUID: Date]
        var redactedTexts: [UUID: String]

        init(scopeValid: Bool, eligibleHashes: [UUID: String] = [:],
             createdAts: [UUID: Date] = [:], redactedTexts: [UUID: String] = [:]) {
            self.scopeValid = scopeValid
            self.eligibleHashes = eligibleHashes
            self.createdAts = createdAts
            self.redactedTexts = redactedTexts
        }
    }

    /// 读侧校验通过的批次快照。
    struct ValidatedBatch {
        var result: ThoughtSemanticStore.FollowupResultRecord
        var sources: [ThoughtSemanticStore.FollowupSourceRecord]
        /// source.thoughtID → 冻结创建时间（关系方向裁决，§6 C1「按冻结的 createdAt」）
        var frozenCreatedAts: [UUID: Date]
        /// 当前可核验记录时间（§6 C1「日期用笔记当前可核验的记录时间」）
        var currentCreatedAts: [UUID: Date]
        /// 当前脱敏正文（窗口文本重建用；hash 已核对一致）
        var redactedTexts: [UUID: String]
    }

    /// 试点开关链 + 授权当前（§5 B1 全链资格；服务器能力另查 capabilityHolds）。
    static func chainHolds(scopeID: UUID) async -> Bool {
        let granted = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
        guard granted,
              ThoughtSemanticFeatureFlags.automaticEnabled,
              ThoughtSemanticFeatureFlags.enabled(ThoughtSemanticFeatureFlags.newTopicsKey),
              ThoughtSemanticFeatureFlags.followupPilotScope() == scopeID else { return false }
        return true
    }

    /// 服务器能力（§2 A13「服务端暗开与客户端试点都成立才可出网」）：只读 ≤5 分钟
    /// 内存缓存——读路径不出网，缓存由协调器心跳保温；过期/离线即隐藏新增派生卡
    /// （§6 C2；关闭带来的远端最长可见窗口是 5 分钟）。
    static func capabilityHolds() async -> Bool {
        let subject = HoloBackendDeviceIdentity.shared.deviceId
        guard let cached = await ThoughtFollowupCapabilityCache.shared.capabilities(for: subject) else { return false }
        return cached.isFollowupSupported
    }

    /// 范围当前事实：主题有效性 + 各 thought 的可用性 / 成员资格 / 当前脱敏 hash。
    /// 仓库读在其上下文内完成（§5 B1），成员语义与协调器同口径（投影裁决）。
    static func loadScopeFacts(scopeID: UUID, thoughtIDs: [UUID]) async -> ScopeFacts {
        let ids = Array(Set(thoughtIDs))
        let context = CoreDataStack.shared.newBackgroundContext()
        return await context.perform {
            guard let topic = Topic.resolveValid(id: scopeID, in: context) else {
                return ScopeFacts(scopeValid: false)
            }
            guard !ids.isEmpty else { return ScopeFacts(scopeValid: true) }
            let request = Thought.fetchRequest()
            request.predicate = ThoughtAIAudience.aiVisible(
                NSPredicate(format: "deletedAt == nil AND isArchived == NO AND id IN %@", ids))
            let thoughts = (try? context.fetch(request)) ?? []
            var hashes: [UUID: String] = [:]
            var createdAts: [UUID: Date] = [:]
            var texts: [UUID: String] = [:]
            for thought in thoughts
            where !ThoughtAIAudience.isExcluded(thought)
                && ThoughtTopicLinkProjection.isEffectiveMember(thought, of: topic) {
                let redacted = ThoughtIndexV2Policy.redactedText(forUpload: thought.content)
                guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                hashes[thought.id] = ThoughtSemanticText.contentHash(redacted)
                createdAts[thought.id] = thought.createdAt
                texts[thought.id] = redacted
            }
            return ScopeFacts(scopeValid: true, eligibleHashes: hashes,
                              createdAts: createdAts, redactedTexts: texts)
        }
    }

    /// verified 批次读侧再验（§6 C3 最后两段的兜底路径）：
    /// 30 天过期先隐藏 → 每主题 200 批次（取先触发）→ 每批全部 source 的
    /// 文本处理版本与正文 hash 对当前事实核对，任何一个失效整批丢弃。
    static func validatedBatches(store: ThoughtSemanticStore, scopeID: UUID,
                                 now: Date = Date()) async throws -> [ValidatedBatch] {
        let results = try await store.followupResults(scopeID: scopeID)
        guard !results.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-ThoughtFollowupProjection.resultMaxAge)
        let fresh = results
            .filter { ($0.verifiedAt ?? .distantPast) > cutoff }
            .sorted { ($0.verifiedAt ?? .distantPast) > ($1.verifiedAt ?? .distantPast) }
            .prefix(ThoughtFollowupProjection.maxBatchesPerScope)
        var sourcesByTask: [String: [ThoughtSemanticStore.FollowupSourceRecord]] = [:]
        var allIDs: [UUID] = []
        for result in fresh {
            let sources = try await store.followupSources(taskKey: result.taskKey)
            sourcesByTask[result.taskKey] = sources
            allIDs.append(contentsOf: sources.map(\.thoughtID))
        }
        let facts = await loadScopeFacts(scopeID: scopeID, thoughtIDs: allIDs)
        guard facts.scopeValid else { return [] }
        var batches: [ValidatedBatch] = []
        for result in fresh {
            guard let sources = sourcesByTask[result.taskKey],
                  sources.count >= ThoughtFollowupContract.notesMinCount else { continue }
            guard sources.allSatisfy({ source in
                source.redactionVersion == ThoughtIndexV2Policy.engineVersion
                    && facts.eligibleHashes[source.thoughtID] == source.contentHash
            }) else { continue }
            batches.append(ValidatedBatch(
                result: result,
                sources: sources,
                frozenCreatedAts: Dictionary(sources.map { ($0.thoughtID, $0.frozenCreatedAt) },
                                             uniquingKeysWith: { first, _ in first }),
                currentCreatedAts: facts.createdAts,
                redactedTexts: facts.redactedTexts))
        }
        return batches
    }

    /// 摘录取窗口文本（§1「每条显示日期、角色及原文片段」）：当前脱敏正文
    /// （hash 已核对一致）按 source 窗口 offset/length 重建 UTF-16 切片；
    /// 行损坏时退回落库摘要。
    static func windowExcerpt(source: ThoughtSemanticStore.FollowupSourceRecord, redacted: String?) -> String {
        guard let redacted, let window = source.windows.first else { return source.summary }
        guard let start = String.Index(utf16Offset: window.offsetUTF16, in: redacted).samePosition(in: redacted),
              let end = String.Index(utf16Offset: window.offsetUTF16 + window.lengthUTF16, in: redacted)
                  .samePosition(in: redacted) else { return source.summary }
        let text = String(redacted[start..<end])
        return text.isEmpty ? source.summary : text
    }

    /// pair 里「当前笔记的对方」及其证据（句柄只从本机 source 映射绑定，§6 C3）：
    /// 当前为锚点 → 对方 = otherThoughtID，取 otherEvidence；当前为对方 →
    /// 对方 = 锚点，取 anchorEvidence。
    static func pairmate(batch: ValidatedBatch,
                         anchorID: UUID,
                         decision: ThoughtSemanticStore.FollowupDecisionRecord,
                         currentThoughtID: UUID) -> (otherID: UUID, quote: String)? {
        if anchorID == currentThoughtID, decision.otherThoughtID != currentThoughtID {
            guard let evidence = decision.otherEvidence else { return nil }
            return (decision.otherThoughtID, evidence.quote)
        }
        if decision.otherThoughtID == currentThoughtID, anchorID != currentThoughtID {
            guard let evidence = decision.anchorEvidence else { return nil }
            return (anchorID, evidence.quote)
        }
        return nil
    }
}

// MARK: - 定向清理引擎（ChangeFeed 防抖后调用，§6 C3「统一收口给 ChangeFeed」）

nonisolated enum ThoughtFollowupInvalidation {

    /// 一批同源变更（已防抖）的定向清理，复用 W2 Store API、不整库清：
    /// · 范围已无效（隐藏/合并/删除，改名 resolveValid 仍有效不触发）→ 整范围
    ///   退出清理 destroyFollowupData（结果与来源；隐藏回执保留，
    ///   §6 C3「日常重算与回滚保留拒绝」）；
    /// · 受影响 thought：按 Source 表反查当前试点范围 verified 批次的输入行，
    ///   命中且当前事实已变（不可用/移出/排除/正文 hash 不符）的批次逐键
    ///   finishFollowupNoResult——派生内容清空 + 完成凭证保留（同键不再重调），
    ///   source 窗口随保留淘汰（pruneFollowupRetention 第 4 步）回收。
    /// 返回清空的批次数（供调用方记日志）。
    @discardableResult
    static func run(store: ThoughtSemanticStore,
                    scopeID: UUID,
                    affectedThoughtIDs: Set<UUID>) async throws -> Int {
        let facts = await ThoughtFollowupReadSupport.loadScopeFacts(
            scopeID: scopeID, thoughtIDs: Array(affectedThoughtIDs))
        guard facts.scopeValid else {
            try await store.destroyFollowupData(scopeID: scopeID)
            return 0
        }
        guard !affectedThoughtIDs.isEmpty else { return 0 }
        let results = try await store.followupResults(scopeID: scopeID)
        var cleared = 0
        for result in results {
            let sources = try await store.followupSources(taskKey: result.taskKey)
            let invalidated = sources.contains { source in
                guard affectedThoughtIDs.contains(source.thoughtID) else { return false }
                let current = facts.eligibleHashes[source.thoughtID]
                return current == nil || current != source.contentHash
            }
            guard invalidated else { continue }
            try await store.finishFollowupNoResult(taskKey: result.taskKey)
            cleared += 1
        }
        return cleared
    }
}
