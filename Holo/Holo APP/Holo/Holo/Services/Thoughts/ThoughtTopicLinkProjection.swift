//
//  ThoughtTopicLinkProjection.swift
//  Holo
//
//  想法-主题关系投影层（语义图谱 V3 Phase 1，方案 §7.1/§18）
//
//  Phase 1 定位：旧 Thought.topics relationship 仍是唯一读源（旧 UI 不变），
//  本层负责三件事——
//  1. 双写：所有写旧关系的路径同步维护 ThoughtTopicLink（镜像 pair 集合 + 叠加语义）；
//  2. 存量迁移：把旧裸关系幂等回填为 link 行（保守映射，宁 legacy 不伪造用户决定）；
//  3. shadow 对账：全库对比「旧关系集合 vs link active 投影集合」，门禁=差异 0。
//
//  投影优先级（同 pair 多行裁决）：user active > rejected 墓碑 > ai/v3 > legacy。
//  用户决定不可被 AI 覆盖；用户移除后 AI 不得在同正文版本重建（墓碑压 active）。
//

import CoreData
import Foundation
import CryptoKit

enum ThoughtTopicLinkProjection {

    // MARK: - 行级原语

    /// 取或建 pair 的 link 行。按语义对（thought+topic）查重——异形 ID 的
    /// 重复行（多设备竞态形态）也收敛：首行保留，其余标 superseded。
    /// 只做对象图操作，不 save——事务边界归调用方（与旧关系写在同一事务）。
    @discardableResult
    static func upsertLink(thought: Thought, topic: Topic) -> ThoughtTopicLink {
        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@ AND topic == %@", thought, topic)
        request.fetchLimit = 0
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        if let rows = try? ManagedObjectContextCompat.fetch(request, in: thought.managedObjectContext),
           let first = rows.sorted(by: { $0.projectionRank < $1.projectionRank }).first {
            for extra in rows where extra !== first && extra.stateEnum == .active {
                extra.stateEnum = .superseded
                extra.updatedAt = Date()
            }
            return first
        }
        let link = ThoughtTopicLink(entity: NSEntityDescription.entity(forEntityName: "ThoughtTopicLink",
                                                                       in: thought.managedObjectContext!)!,
                                    insertInto: thought.managedObjectContext)
        link.id = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
        link.thought = thought
        link.topic = topic
        link.sourceEnum = .legacyUnknown
        link.stateEnum = .active
        link.visibilityEnum = .internalOnly
        link.consentGeneration = 0
        link.createdAt = Date()
        link.updatedAt = Date()
        return link
    }

    /// 用户手动移入：pair → user/manual + active + userVisible，清拒绝痕迹。
    /// 用户主动重建曾被拒绝的 pair 是合法的用户决定（覆盖旧拒绝）。
    static func recordManualAdd(thought: Thought, topic: Topic) {
        let link = upsertLink(thought: thought, topic: topic)
        link.sourceEnum = .userManual
        link.stateEnum = .active
        link.visibilityEnum = .userVisible
        link.rejectedAt = nil
        link.basisTextHash = nil
        link.decisionTier = nil
        link.updatedAt = Date()
    }

    /// 建议卡「建立主题」（§4.4）：pair → user/acceptedSuggestion + active + userVisible。
    /// 优先级与手动同档（用户接受了这次建议=用户决定），清拒绝痕迹。
    static func recordAcceptedSuggestion(thought: Thought, topic: Topic) {
        let link = upsertLink(thought: thought, topic: topic)
        link.sourceEnum = .userAcceptedSuggestion
        link.stateEnum = .active
        link.visibilityEnum = .userVisible
        link.rejectedAt = nil
        link.basisTextHash = nil
        link.decisionTier = nil
        link.updatedAt = Date()
    }

    /// 关系被新版本取代（AI 分类替换、引擎重写）：active → superseded 留痕。
    /// 用户决定的 active 行不压制（§7.1：AI 换分类不得移除用户手动/接受的关系）。
    static func recordSuperseded(thought: Thought, topic: Topic) {
        let link = upsertLink(thought: thought, topic: topic)
        guard link.stateEnum == .active, !isUserDecision(link) else { return }
        link.stateEnum = .superseded
        link.updatedAt = Date()
    }

    /// 用户手动移出：pair 写 rejected 墓碑（不物理删除），AI 不得在同 pair 重建。
    static func recordManualRemove(thought: Thought, topic: Topic) {
        let link = upsertLink(thought: thought, topic: topic)
        link.stateEnum = .rejected
        link.rejectedAt = Date()
        link.updatedAt = Date()
    }

    /// V2 AI 分类通道写入：pair → legacy/ai + active + internal。
    /// （Phase 3 起 V3 引擎改走 ai/v3 + decisionTier；此处保持 V2 语义。）
    /// §7.1 不变量「用户决定不可被 AI 覆盖」（2026-09-10 起生效，取代 Phase 1 镜像妥协）：
    /// - 现有行是用户拒绝墓碑 → 不复活（同一错误不得重现）；
    /// - 现有行是用户手动/接受建议的 active 关系 → 不降级不替换（保留用户选择）；
    /// 两种情况 AI 分类的其他产出（标签等）不受影响，仅主题归属让位于用户。
    static func recordLegacyAIAssignment(thought: Thought, topic: Topic) {
        let link = upsertLink(thought: thought, topic: topic)
        guard !isUserDecision(link) else { return }
        link.sourceEnum = .legacyAI
        link.stateEnum = .active
        link.visibilityEnum = .internalOnly
        link.updatedAt = Date()
    }

    /// V3 语义引擎正式写入（relation=on，2026-09-24 方案 §3 P0：
    /// 「开启 relation 也没有正式自动关联写入路径」的修复）：
    /// pair → ai/v3 + active + weakVisible，带 basisTextHash / decisionTier /
    /// engineVersion / consentGeneration。调用方负责在同一 context save。
    /// 用户拒绝墓碑不复活、用户 active 不降级（isUserDecision 让位，§7.1）。
    /// 返回是否实际写入（false = 用户决定优先被让位）。
    @discardableResult
    static func recordAIV3Decision(thought: Thought, topic: Topic,
                                   basisTextHash: String,
                                   decisionTier: String,
                                   engineVersion: String,
                                   consentGeneration: Int64,
                                   evidenceRange: [Int]? = nil) -> Bool {
        if isUserRejectedPair(thought: thought, topic: topic) { return false }
        let link = upsertLink(thought: thought, topic: topic)
        if isUserDecision(link) { return false }
        link.sourceEnum = .aiV3
        link.stateEnum = .active
        link.visibilityEnum = .weakVisible
        link.basisTextHash = basisTextHash
        link.decisionTier = decisionTier
        link.engineVersion = engineVersion
        link.consentGeneration = consentGeneration
        if let range = evidenceRange, range.count == 2 {
            link.evidenceRange = "\(range[0]),\(range[1])"
        }
        link.updatedAt = Date()
        return true
    }

    /// 该 pair 当前是否处于用户拒绝墓碑（AI 分类旧关系层守卫用）。
    static func isUserRejectedPair(thought: Thought, topic: Topic) -> Bool {
        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@ AND topic == %@", thought, topic)
        request.fetchLimit = 0
        let rows = (try? ManagedObjectContextCompat.fetch(request, in: thought.managedObjectContext)) ?? []
        return rows.contains { $0.stateEnum == .rejected }
    }

    /// 用户决定判定：手动移入 / 建议卡接受 / 显式拒绝（墓碑）都属用户意志。
    private static func isUserDecision(_ link: ThoughtTopicLink) -> Bool {
        if link.stateEnum == .rejected { return true }
        switch link.sourceEnum {
        case .userManual, .userAcceptedSuggestion:
            return link.stateEnum == .active
        default:
            return false
        }
    }

    /// 主题合并（duplicate → keeper）：镜像旧 relationship 行为——
    /// keeper 侧 upsert（新行继承 duplicate 行语义），duplicate 侧行保留不动
    /// （旧读路径中 thought.topics 同时含两者，merged 状态由 Topic 层表达）。
    static func recordMerge(into keeper: Topic, from duplicate: Topic) {
        guard let dupLinks = duplicate.topicLinks as? Set<ThoughtTopicLink> else { return }
        for dupLink in dupLinks where dupLink.stateEnum == .active {
            guard let thought = dupLink.thought else { continue }
            let keeperLink = upsertLink(thought: thought, topic: keeper)
            if keeperLink.stateEnum == .active && keeperLink !== dupLink {
                continue // keeper 侧已有有效行（rank 由裁决保证），不覆盖
            }
            keeperLink.sourceEnum = dupLink.sourceEnum
            keeperLink.stateEnum = .active
            keeperLink.visibilityEnum = dupLink.visibilityEnum
            keeperLink.updatedAt = Date()
        }
    }

    /// AI 关系只对生成它的正文版本有效；用户决定持续有效。
    private static func isCurrentActive(_ link: ThoughtTopicLink, thought: Thought) -> Bool {
        guard link.stateEnum == .active else { return false }
        guard link.sourceEnum == .aiV3 else { return true }
        let hash = SHA256.hash(data: Data(thought.content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return link.basisTextHash == hash
    }

    // MARK: - 读投影（Phase 1 shadow 口径；Phase 4 起为新读路径）

    /// 一条想法的有效 Topic：同 pair 取投影优先级行，仅 active 计入。
    /// 与旧读 thought.topics 同口径（含 merged/archived topic 的关系行，过滤交给上层）。
    static func effectiveTopics(for thought: Thought) -> [Topic] {
        guard let links = thought.topicLinks as? Set<ThoughtTopicLink>, !links.isEmpty else { return [] }
        var bestByPair: [UUID: ThoughtTopicLink] = [:]
        var pairKeyByLink: [ObjectIdentifier: UUID] = [:]
        for link in links {
            guard let topic = link.topic else { continue }
            let pair = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
            pairKeyByLink[ObjectIdentifier(link)] = pair
            if let best = bestByPair[pair] {
                if link.projectionRank < best.projectionRank { bestByPair[pair] = link }
            } else {
                bestByPair[pair] = link
            }
        }
        return bestByPair.values
            .filter { isCurrentActive($0, thought: thought) }
            .compactMap { $0.topic }
            .filter { $0.isVisibleTopic && ($0.value(forKey: "deletedAt") as? Date) == nil }
    }

    /// 单 pair 有效成员判定（2026-09-27 P0-A 读源统一）：与 effectiveTopics 同一
    /// 裁决规则，供仓库层精筛与旁路读点复用，不各自实现口径。
    static func isEffectiveMember(_ thought: Thought, of topic: Topic) -> Bool {
        guard let links = thought.topicLinks as? Set<ThoughtTopicLink> else { return false }
        var best: ThoughtTopicLink?
        for link in links where link.topic?.id == topic.id {
            if best == nil || link.projectionRank < best!.projectionRank { best = link }
        }
        return best.map { isCurrentActive($0, thought: thought) } ?? false
    }

    /// 有效成员的来源（P1 来源感知）：user=用户手动/接受建议，ai=Holo 高可信
    /// 自动归入，legacy=历史归集（来源不明）；非有效成员返回 nil。
    enum MembershipSource { case user, ai, legacy }

    static func membershipSource(of thought: Thought, in topic: Topic) -> MembershipSource? {
        guard let links = thought.topicLinks as? Set<ThoughtTopicLink> else { return nil }
        var best: ThoughtTopicLink?
        for link in links where link.topic?.id == topic.id {
            if best == nil || link.projectionRank < best!.projectionRank { best = link }
        }
        guard let winner = best, isCurrentActive(winner, thought: thought) else { return nil }
        switch winner.sourceEnum {
        case .userManual, .userAcceptedSuggestion:
            return .user
        case .aiV3:
            return .ai
        case .legacyAI, .legacyUnknown:
            return .legacy
        }
    }

    /// 主题的有效成员计数（P0-A 口径）：per-pair 裁决 + 排除已删/已归档想法
    /// （与 fetchThoughts(byTopic:) 默认口径一致）。deletedAt 走 KVC——
    /// 声明在 SoftDeletable 扩展，standalone 直编环境不带该文件。
    static func effectiveActiveThoughtCount(of topic: Topic, includeArchived: Bool = false) -> Int {
        guard let links = topic.topicLinks as? Set<ThoughtTopicLink>, !links.isEmpty else { return 0 }
        var bestByThought: [ObjectIdentifier: (Thought, ThoughtTopicLink)] = [:]
        for link in links {
            guard let thought = link.thought else { continue }
            let key = ObjectIdentifier(thought)
            if let (_, best) = bestByThought[key], link.projectionRank >= best.projectionRank { continue }
            bestByThought[key] = (thought, link)
        }
        return bestByThought.values.filter { pair in
            isCurrentActive(pair.1, thought: pair.0)
                && (pair.0.value(forKey: "deletedAt") as? Date) == nil
                && (includeArchived || pair.0.isArchived == false)
        }.count
    }

    // MARK: - 存量迁移（幂等、逐批、可中断；方案 §18.2）

    struct BackfillReport: Codable {
        var scannedThoughts = 0
        var pairsExamined = 0
        var linksCreated = 0
        var linksSkippedExisting = 0
        var linksPreservedUserDecision = 0 // 已存在 rejected/superseded 行，不复活
    }

    /// 把旧 Thought.topics 裸关系回填为 ThoughtTopicLink。
    /// 映射规则（保守：宁 legacy 不伪造用户决定）——
    /// · topicAssignmentReason 非空 → legacy/ai（AI 分类通道写的）
    /// · 其余（含 topicConfidence==1 无法与 AI 恰好 1.0 区分的）→ legacy/unknown
    /// · visibility 一律 internal（Phase 1 不改 UI；Phase 3 起重新评估）
    /// 幂等：已存在 active 行跳过；已存在 rejected/superseded 行保留用户决定。
    static func backfillLegacyLinks(in context: NSManagedObjectContext, batchSize: Int = 200) throws -> BackfillReport {
        var report = BackfillReport()
        let request = Thought.fetchRequest()
        request.fetchBatchSize = batchSize
        let thoughts = try ManagedObjectContextCompat.fetch(request, in: context)
        for thought in thoughts {
            report.scannedThoughts += 1
            guard let topics = thought.topics as? Set<Topic> else { continue }
            let hasAIReason = (thought.topicAssignmentReason?.isEmpty == false)
            for topic in topics {
                report.pairsExamined += 1
                let pairID = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
                let linkRequest = ThoughtTopicLink.fetchRequest()
                linkRequest.predicate = NSPredicate(format: "id == %@", pairID as CVarArg)
                linkRequest.fetchLimit = 1
                if let existing = try ManagedObjectContextCompat.fetch(linkRequest, in: context).first {
                    if existing.stateEnum == .active {
                        report.linksSkippedExisting += 1
                    } else {
                        report.linksPreservedUserDecision += 1
                    }
                    continue
                }
                let link = upsertLink(thought: thought, topic: topic)
                link.sourceEnum = hasAIReason ? .legacyAI : .legacyUnknown
                report.linksCreated += 1
            }
            if report.pairsExamined % batchSize == 0, context.hasChanges {
                try context.save() // 逐批落盘：可中断，重跑从缺失处继续
            }
        }
        if context.hasChanges { try context.save() }
        return report
    }

    // MARK: - Shadow 对账（Phase 1 门禁：差异 = 0）

    struct ShadowReport: Codable {
        var legacyPairs = 0            // 旧 relationship 的 (thought, topic) 对数
        var projectedPairs = 0         // link active 投影对数
        var missingInProjection = 0    // 旧有、投影无 → 双写缺口
        var extraInProjection = 0      // 投影有、旧无 → link 越权写入
        var duplicateLinkRows = 0      // 同 pair 多行（裁决层兜底，但应趋零）
        var supersededOrRejectedRows = 0 // 墓碑/被替换行数（不进投影，仅统计）

        var isConsistent: Bool { missingInProjection == 0 && extraInProjection == 0 }
    }

    /// 全库对比旧关系集合与 link active 投影集合。
    /// 口径：未软删 Thought（软删想法的关系两侧都冻结，属 V3 §14 恢复语义，Phase 3 接）。
    static func shadowDifference(in context: NSManagedObjectContext) throws -> ShadowReport {
        var report = ShadowReport()
        var legacyByThought: [UUID: Set<UUID>] = [:]
        var projectedByThought: [UUID: Set<UUID>] = [:]

        let thoughtRequest = Thought.fetchRequest()
        thoughtRequest.predicate = NSPredicate(format: "deletedAt == nil")
        thoughtRequest.fetchBatchSize = 200
        for thought in try ManagedObjectContextCompat.fetch(thoughtRequest, in: context) {
            var topicIDs = Set<UUID>()
            if let topics = thought.topics as? Set<Topic> {
                topicIDs = Set(topics.map(\.id))
            }
            legacyByThought[thought.id] = topicIDs
        }

        let linkRequest = ThoughtTopicLink.fetchRequest()
        linkRequest.fetchBatchSize = 500
        var seenPairs = Set<String>() // 语义 pair 键（thought|topic），异形 ID 的重复行也算重复
        for link in try ManagedObjectContextCompat.fetch(linkRequest, in: context) {
            guard let thought = link.thought, let topic = link.topic else { continue }
            let pairKey = "\(thought.id.uuidString)|\(topic.id.uuidString)"
            if seenPairs.contains(pairKey) { report.duplicateLinkRows += 1 }
            seenPairs.insert(pairKey)
            guard link.stateEnum == .active else {
                report.supersededOrRejectedRows += 1
                continue
            }
            // active 行必须与最佳裁决行一致才计入投影（同 pair 多行取 rank 最小）
            projectedByThought[thought.id, default: []].insert(topic.id)
        }
        // 同 pair 多 active 行只算一次投影（上面 Set 去重），与 effectiveTopics 裁决一致

        for (thoughtID, legacySet) in legacyByThought {
            let projectedSet = projectedByThought[thoughtID] ?? []
            report.missingInProjection += legacySet.subtracting(projectedSet).count
            report.extraInProjection += projectedSet.subtracting(legacySet).count
        }
        for thoughtID in projectedByThought.keys where legacyByThought[thoughtID] == nil {
            report.extraInProjection += projectedByThought[thoughtID]?.count ?? 0
        }
        report.legacyPairs = legacyByThought.values.reduce(0) { $0 + $1.count }
        report.projectedPairs = projectedByThought.values.reduce(0) { $0 + $1.count }
        return report
    }
}

/// fetch 兼容层：隔离泛型 NSFetchRequest 在不同 context 类型下的调用样板。
enum ManagedObjectContextCompat {
    static func fetch<T: NSManagedObject>(_ request: NSFetchRequest<T>, in context: NSManagedObjectContext?) throws -> [T] {
        guard let context else { return [] }
        return try context.fetch(request)
    }
}
