//
//  HoloMemoryEvidenceRouter.swift
//  Holo
//
//  记忆证据与原始业务记录间的路由：可直达详情页的证据给出深链目标，
//  无详情页的证据由出处弹层按域回查原始记录现场原文。
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

nonisolated enum HoloMemoryEvidenceSourceLookup {
    /// 存量证据未随记录保存摘要时，按 sourceID 回查原始记录的现场原文；记录已删除
    /// 或不存在则返回 nil。个人情境证据的 sourceID 是带域前缀的 sourceKey
    /// （habit-checkin:UUID 等；thought 存量为裸 UUID），按 HoloLifeSourceKeys 规则
    /// 分派；正文复用各域来源观察的同一构造，与萃取输入同源（2026-10-09 东林反馈：
    /// 出处页不能把「未存摘要」一律说成「原始内容可能已被删除」）。
    static func liveText(for evidence: HoloMemoryEvidenceRef) async -> String? {
        guard trimmedOrNil(evidence.summary) == nil,
              let sourceID = evidence.sourceID else { return nil }
        return await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            let uuid = UUID(uuidString: HoloLifeSourceKeys.entityID(of: sourceID))
            switch HoloLifeSourceKeys.domain(of: sourceID) {
            case "finance":
                guard let uuid,
                      let transaction = fetch(Transaction.fetchRequest(), id: uuid,
                                              predicate: "id == %@ AND deletedAt == nil",
                                              context: context) else { return nil }
                let repository = FinanceRepository(context: context)
                let categoryText = transaction.category.map { category in
                    repository.resolveCategoryNames(from: category).sub.map { "\($0)" } ?? category.name ?? ""
                } ?? ""
                return nonEmpty(HoloFinanceContextSourcePaging.observationText(transaction, categoryText: categoryText))
            case "task":
                guard let uuid,
                      let task = fetch(TodoTask.fetchRequest(), id: uuid,
                                       predicate: "id == %@ AND deletedFlag == NO AND archived == NO",
                                       context: context) else { return nil }
                return nonEmpty(HoloTaskContextSourcePaging.observationText(task))
            case "habit":
                guard let uuid else { return nil }
                if sourceID.hasPrefix(HoloLifeSourceKeys.habitCheckinPrefix) {
                    let request = HabitRecord.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                    request.fetchLimit = 1
                    guard let record = (try? context.fetch(request))?.first else { return nil }
                    return nonEmpty(HoloHabitContextSourcePaging.checkinSnapshot(record).plainText)
                }
                guard let habit = fetch(Habit.fetchRequest(), id: uuid,
                                        predicate: "id == %@ AND isArchived == NO",
                                        context: context) else { return nil }
                return nonEmpty(HoloHabitContextSourcePaging.definitionSnapshot(habit).plainText)
            case "conversation":
                guard let uuid,
                      let message = fetch(ChatMessage.fetchRequest(), id: uuid,
                                          predicate: "id == %@ AND deletedAt == nil AND isStreaming == NO",
                                          context: context) else { return nil }
                return nonEmpty(HoloContextPlainTextNormalizer.normalize(message.content).plainText)
            case "goal":
                guard let uuid,
                      let goal = fetch(Goal.fetchRequest(), id: uuid,
                                       predicate: "id == %@",
                                       context: context) else { return nil }
                return nonEmpty(HoloGoalContextSourcePaging.observationText(goal))
            default:
                guard let uuid,
                      let thought = fetch(Thought.fetchRequest(), id: uuid,
                                          predicate: "id == %@ AND deletedAt == nil AND isArchived == NO",
                                          context: context) else { return nil }
                return nonEmpty(HoloContextPlainTextNormalizer.normalize(thought.content).plainText)
            }
        }
    }

    private static func fetch<T: NSManagedObject>(
        _ request: NSFetchRequest<T>,
        id: UUID,
        predicate: String,
        context: NSManagedObjectContext
    ) -> T? {
        request.predicate = NSPredicate(format: predicate, id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
