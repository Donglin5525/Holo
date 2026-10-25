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
    /// 实体证据统一深链出口：sourceID 按 HoloLifeSourceKeys 规范解析（带域前缀的剥前缀，
    /// 存量裸 UUID 回落到证据自身的 sourceDomain 判域），有详情页的域直达。
    /// kind 不参与可达性判定——能否直达只取决于 sourceID 是否指向一个有详情页的实体记录；
    /// 聚合快照无单一出处、habit 打卡 UUID 指向打卡而非习惯本身，均返回 nil 由调用方弹出处预览。
    static func deepLinkTarget(for evidence: HoloMemoryEvidenceRef) -> DeepLinkTarget? {
        guard evidence.kind != .aggregateSnapshot,
              let sourceID = evidence.sourceID,
              let uuid = UUID(uuidString: HoloLifeSourceKeys.entityID(of: sourceID)) else { return nil }
        guard !sourceID.hasPrefix(HoloLifeSourceKeys.habitCheckinPrefix) else { return nil }
        switch routingDomain(of: sourceID, evidence: evidence) {
        case .finance: return .transactionDetail(transactionId: uuid)
        case .task: return .taskDetail(taskId: uuid)
        case .thought: return .thoughtDetail(thoughtId: uuid)
        case .habit: return .habitDetail(habitId: uuid)
        case .goal: return .goalDetail(goalId: uuid)
        case .health, .conversation, .profile: return nil
        }
    }

    /// 域判定：带前缀的 sourceKey 以前缀为准（萃取写入时的真值）；存量裸 UUID 本身不携带
    /// 域信息，回落到证据上的 sourceDomain——那是它真实出身的唯一记录。
    private static func routingDomain(
        of sourceID: String,
        evidence: HoloMemoryEvidenceRef
    ) -> HoloMemoryDomain {
        let prefixed = [
            HoloLifeSourceKeys.financePrefix, HoloLifeSourceKeys.taskPrefix,
            HoloLifeSourceKeys.habitCheckinPrefix, HoloLifeSourceKeys.habitPrefix,
            HoloLifeSourceKeys.conversationPrefix, HoloLifeSourceKeys.goalPrefix
        ].contains { sourceID.hasPrefix($0) }
        if prefixed,
           let domain = HoloMemoryDomain(rawValue: HoloLifeSourceKeys.domain(of: sourceID)) {
            return domain
        }
        return evidence.sourceDomain
    }

    /// 深链跳转前需校验原始记录仍存活；仅可路由的证据返回实体名。
    static func sourceEntityName(for evidence: HoloMemoryEvidenceRef) -> String? {
        guard deepLinkTarget(for: evidence) != nil,
              let sourceID = evidence.sourceID else { return nil }
        switch routingDomain(of: sourceID, evidence: evidence) {
        case .finance: return "Transaction"
        case .task: return "TodoTask"
        case .thought: return "Thought"
        case .habit: return "Habit"
        case .goal: return "Goal"
        case .health, .conversation, .profile: return nil
        }
    }
}

@MainActor
enum HoloMemoryEvidenceSourceAliveCheck {
    /// 深链前校验原始记录仍存活；谓词与 HoloMemoryEvidenceSourceLookup.liveText 的各域
    /// 活源口径一致（能跳 = 打开详情页能核对着原内容）。
    static func isAlive(_ evidence: HoloMemoryEvidenceRef) -> Bool {
        guard let entityName = HoloMemoryEvidenceRouter.sourceEntityName(for: evidence),
              let sourceID = evidence.sourceID,
              let uuid = UUID(uuidString: HoloLifeSourceKeys.entityID(of: sourceID)) else { return false }
        let alive: String
        switch entityName {
        case "TodoTask": alive = "deletedFlag == NO AND archived == NO"
        case "Thought": alive = "deletedAt == nil AND isArchived == NO"
        case "Habit": alive = "isArchived == NO"
        case "Goal": alive = "TRUEPREDICATE"
        default: alive = "deletedAt == nil"
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@ AND \(alive)", uuid as CVarArg)
        request.fetchLimit = 1
        return ((try? CoreDataStack.shared.viewContext.count(for: request)) ?? 0) > 0
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

    /// 原始记录自身的事件时间（任务=完成/计划/创建、交易=发生时间、打卡=打卡日、
    /// 其余=创建/发送时间）。证据行展示这个日期而不是萃取观察时间，用户才能对上
    /// 「我那天做了什么」；记录已删除或不存在返回 nil，由调用方回落观察时间。
    static func sourceEventDate(for evidence: HoloMemoryEvidenceRef) async -> Date? {
        guard let sourceID = evidence.sourceID else { return nil }
        return await MainActor.run {
            let context = CoreDataStack.shared.viewContext
            let uuid = UUID(uuidString: HoloLifeSourceKeys.entityID(of: sourceID))
            switch HoloLifeSourceKeys.domain(of: sourceID) {
            case "finance":
                guard let uuid,
                      let transaction = fetch(Transaction.fetchRequest(), id: uuid,
                                              predicate: "id == %@ AND deletedAt == nil",
                                              context: context) else { return nil }
                return transaction.date
            case "task":
                guard let uuid,
                      let task = fetch(TodoTask.fetchRequest(), id: uuid,
                                       predicate: "id == %@ AND deletedFlag == NO AND archived == NO",
                                       context: context) else { return nil }
                return task.completedAt ?? task.plannedStart ?? task.createdAt
            case "habit":
                guard let uuid else { return nil }
                if sourceID.hasPrefix(HoloLifeSourceKeys.habitCheckinPrefix) {
                    let request = HabitRecord.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                    request.fetchLimit = 1
                    guard let record = (try? context.fetch(request))?.first else { return nil }
                    return record.date
                }
                guard let habit = fetch(Habit.fetchRequest(), id: uuid,
                                        predicate: "id == %@ AND isArchived == NO",
                                        context: context) else { return nil }
                return habit.createdAt
            case "conversation":
                guard let uuid,
                      let message = fetch(ChatMessage.fetchRequest(), id: uuid,
                                          predicate: "id == %@ AND deletedAt == nil AND isStreaming == NO",
                                          context: context) else { return nil }
                return message.timestamp
            case "goal":
                guard let uuid,
                      let goal = fetch(Goal.fetchRequest(), id: uuid,
                                       predicate: "id == %@",
                                       context: context) else { return nil }
                return goal.createdAt
            default:
                guard let uuid,
                      let thought = fetch(Thought.fetchRequest(), id: uuid,
                                          predicate: "id == %@ AND deletedAt == nil AND isArchived == NO",
                                          context: context) else { return nil }
                return thought.createdAt
            }
        }
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
