//
//  HoloMemoryEvidenceRouter.swift
//  Holo
//
//  记忆证据与原始业务记录间的路由：可直达详情页的证据给出深链目标，
//  无详情页的对话原话证据由出处弹层现场回查原文。
//

import CoreData
import Foundation

nonisolated enum HoloMemoryEvidenceRouter {
    /// entityRef 证据指向原始业务记录；观点域的用户原话证据 sourceID 同样指向原始想法，一并直达。
    static func deepLinkTarget(for evidence: HoloMemoryEvidenceRef) -> DeepLinkTarget? {
        guard let sourceID = evidence.sourceID,
              let uuid = UUID(uuidString: sourceID) else { return nil }
        switch (evidence.kind, evidence.sourceDomain) {
        case (.entityRef, .finance):
            return .transactionDetail(transactionId: uuid)
        case (.entityRef, .task):
            return .taskDetail(taskId: uuid)
        case (.entityRef, .thought), (.explicitUserStatement, .thought):
            return .thoughtDetail(thoughtId: uuid)
        case (.entityRef, .habit):
            return .habitDetail(habitId: uuid)
        case (.entityRef, .goal):
            return .goalDetail(goalId: uuid)
        default:
            return nil
        }
    }

    /// 深链跳转前需校验原始记录仍存活（不存在或已进回收站都视为已清除）；仅可路由的证据返回实体名。
    static func sourceEntityName(for evidence: HoloMemoryEvidenceRef) -> String? {
        guard deepLinkTarget(for: evidence) != nil else { return nil }
        switch evidence.sourceDomain {
        case .finance: return "Transaction"
        case .task: return "TodoTask"
        case .thought: return "Thought"
        case .habit: return "Habit"
        case .goal: return "Goal"
        default: return nil
        }
    }
}

nonisolated enum HoloMemoryConversationExcerptLookup {
    /// 存量对话证据未随记录保存摘要时，按 sourceID 回查原始用户消息的原文作出处展示；消息已删除则返回 nil。
    static func excerpt(for evidence: HoloMemoryEvidenceRef) async -> String? {
        guard evidence.kind == .explicitUserStatement,
              evidence.sourceDomain == .conversation,
              trimmedOrNil(evidence.summary) == nil,
              let sourceID = evidence.sourceID,
              let uuid = UUID(uuidString: sourceID) else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let context = CoreDataStack.shared.newBackgroundContext()
            return try? await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["content"]
                request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", uuid as CVarArg)
                request.fetchLimit = 1
                guard let content = (try? context.fetch(request))?.first?["content"] as? String,
                      !content.isEmpty else { return nil }
                return String(HoloDomainSignalBuilder.sanitizeUserText(content).prefix(300))
            }
        }.value
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
