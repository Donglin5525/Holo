//
//  ThoughtCategoryBriefMaintainer.swift
//  Holo
//
//  归档类别理解维护者（2026-10-12 主题双通道·零打扰）
//
//  挂语义管线谷时段心跳（与 embed/relate/discovery 同节拍，每拍最多维护一个主题）：
//  · 起草：classification 主题无 brief 且有效成员 ≥5 → 零问起草（宁可不启用，不猜）；
//  · 精化：brief 存在且（新增移出 或 成员较上一版 +5）且距上版 ≥12h → 攒批精化；
//  · 接管：topic.categoryDefinition 非空（用户写过定义）→ 永不维护，用户的话优先。
//  brief 只存本机语义库；升版进关联重评指纹（Verifier 拼接 brief 版本键）。
//

import CoreData
import Foundation
import OSLog

nonisolated final class ThoughtCategoryBriefMaintainer: @unchecked Sendable {

    static let shared = ThoughtCategoryBriefMaintainer()
    private init() {}

    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtCategoryBrief")

    /// 起草门槛：有效成员不足时类别判定退化为「标题+用户确认代表例」，不猜定义
    static let draftMinMembers = 5
    /// 精化门槛：成员较上一版基数的增量
    static let refineMemberDelta = 5
    /// 同一主题两次精化的最小间隔（小时）
    static let refineMinIntervalHours: Double = 12
    /// 单次请求成员样本上限（与后端契约一致）
    static let memberSampleLimit = 10
    /// 单次请求移出反证上限
    static let removalSampleLimit = 3

    struct MaintenanceNeed {
        enum Mode: String { case draft, refine }
        let mode: Mode
        let topicID: UUID
        let title: String
        let userDefinition: String?
        let members: [(ref: String, text: String, source: String)]
        let removals: [(ref: String, text: String)]
        let totalMemberCount: Int
        let totalRemovalCount: Int
    }

    /// 每个节拍最多维护一个主题；任何失败静默（下一拍再试），不阻塞队列其他工作。
    func process(store: ThoughtSemanticStore) async {
        let granted = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
        let relationOn = await MainActor.run { ThoughtSemanticFeatureFlags.relation != .off }
        guard granted, relationOn else { return }
        guard let need = await pickNeed(store: store) else { return }
        do {
            let record = try await store.loadCategoryBrief(topicID: need.topicID)
            let saved = try await ThoughtCategoryBriefClient.refreshBrief(
                topicID: need.topicID,
                record: record,
                title: need.title,
                userDefinition: need.userDefinition,
                members: need.members,
                removals: need.removals,
                totalMemberCount: need.totalMemberCount,
                totalRemovalCount: need.totalRemovalCount,
                provider: HoloBackendAIProvider(),
                store: store)
            logger.notice("类别理解已维护 mode=\(need.mode.rawValue, privacy: .public) topic=\(need.topicID.uuidString, privacy: .public) v\(saved.version)")
        } catch {
            logger.error("类别理解维护失败（下拍再试）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 选一个需要维护的主题（标题序稳定遍历，返回第一个满足条件的）。
    private func pickNeed(store: ThoughtSemanticStore) async -> MaintenanceNeed? {
        let context = CoreDataStack.shared.newBackgroundContext()
        let candidates: [(id: UUID, title: String, userDefinition: String?)] = await context.perform {
            let request = Topic.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil")
            let rows = Topic.resolveValidRows((try? context.fetch(request)) ?? [])
            return rows.filter(\.isClassificationTopic)
                .sorted { $0.title < $1.title }
                .map { ($0.id, $0.title, $0.categoryDefinition) }
        }
        for topic in candidates {
            // 用户接管：写过定义的主题 AI 不再维护
            if let userDef = topic.userDefinition, !userDef.isEmpty { continue }
            let evidence = await gatherEvidence(topicID: topic.id, context: context)
            guard let evidence else { continue }
            let brief = try? await store.loadCategoryBrief(topicID: topic.id)
            if let brief {
                let hoursSince = Date().timeIntervalSince(brief.updatedAt) / 3600
                let memberDelta = evidence.totalMemberCount - brief.basisMemberCount
                let removalDelta = evidence.totalRemovalCount - brief.basisRemovalCount
                guard hoursSince >= Self.refineMinIntervalHours,
                      removalDelta > 0 || memberDelta >= Self.refineMemberDelta else { continue }
                return MaintenanceNeed(mode: .refine, topicID: topic.id, title: topic.title,
                                        userDefinition: nil, members: evidence.members,
                                        removals: evidence.removals,
                                        totalMemberCount: evidence.totalMemberCount,
                                        totalRemovalCount: evidence.totalRemovalCount)
            } else {
                guard evidence.totalMemberCount >= Self.draftMinMembers else { continue }
                return MaintenanceNeed(mode: .draft, topicID: topic.id, title: topic.title,
                                        userDefinition: nil, members: evidence.members,
                                        removals: evidence.removals,
                                        totalMemberCount: evidence.totalMemberCount,
                                        totalRemovalCount: evidence.totalRemovalCount)
            }
        }
        return nil
    }

    private typealias Evidence = (members: [(ref: String, text: String, source: String)],
                                  removals: [(ref: String, text: String)],
                                  totalMemberCount: Int,
                                  totalRemovalCount: Int)

    /// 证据采集：有效成员（用户确认优先取样）+ 用户移出反证（最近优先）。
    private func gatherEvidence(topicID: UUID, context: NSManagedObjectContext) async -> Evidence? {
        await context.perform {
            guard let topic = Topic.resolveValid(id: topicID, in: context) else { return nil }
            let memberRequest = Thought.fetchRequest()
            // 成员样本正文会上传：排除「不参与 AI」标签的想法
            memberRequest.predicate = ThoughtAIAudience.aiVisible(
                NSPredicate(format: "deletedAt == nil AND isArchived == NO AND ANY topicLinks.topic.id == %@", topicID as CVarArg))
            let members = ((try? context.fetch(memberRequest)) ?? []).filter {
                ThoughtTopicLinkProjection.isEffectiveMember($0, of: topic)
            }
            let ordered = members.sorted {
                let sa = ThoughtTopicLinkProjection.categorySampleRank(of: $0, in: topic)
                let sb = ThoughtTopicLinkProjection.categorySampleRank(of: $1, in: topic)
                if sa != sb { return sa < sb }
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            let memberSamples = ordered.prefix(Self.memberSampleLimit).compactMap { thought -> (String, String, String)? in
                let text = ThoughtSemanticText.prefix(ThoughtIndexV2Policy.redactedText(forUpload: thought.content), maxUTF16: 240)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let source: String
                switch ThoughtTopicLinkProjection.membershipSource(of: thought, in: topic) {
                case .user: source = "user"
                case .ai: source = "ai"
                case .legacy: source = "legacy"
                case nil: return nil
                }
                return (thought.id.uuidString, text, source)
            }
            // 用户移出反证：rejected 墓碑链接的想法（正文仍在库），最近优先
            let removalRequest = ThoughtTopicLink.fetchRequest()
            removalRequest.predicate = NSPredicate(format: "topic.id == %@ AND state == %@", topicID as CVarArg, "rejected")
            removalRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            let rejectedLinks = (try? context.fetch(removalRequest)) ?? []
            var removalSamples: [(String, String)] = []
            for link in rejectedLinks {
                // 移出反证同样上传正文：历史 rejected 的想法若已带排除标签，不再外泄
                guard let thought = link.thought, !thought.isSoftDeleted,
                      !ThoughtAIAudience.isExcluded(thought) else { continue }
                let content = thought.content as String?
                guard let content, !content.isEmpty else { continue }
                let text = ThoughtSemanticText.prefix(ThoughtIndexV2Policy.redactedText(forUpload: content), maxUTF16: 240)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                removalSamples.append((thought.id.uuidString, text))
                if removalSamples.count >= Self.removalSampleLimit { break }
            }
            return Evidence(members: memberSamples, removals: removalSamples,
                            totalMemberCount: members.count,
                            totalRemovalCount: rejectedLinks.count)
        }
    }
}
