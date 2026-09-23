//
//  HoloLifeSourceObservation.swift
//  Holo
//
//  R1 四域来源观察（方案 2026-09-23 §3.1/§4.2 R1）。
//
//  - finance / task / habit 三域分页适配（thought 已有 HoloThoughtContextSourcePaging，本文件不重复）。
//  - sourceKey 规范：新域 "domain:UUID"（habit 打卡 "habit-checkin:UUID"）；thought 存量为裸 UUID。
//  - 编辑、完成、撤销、软删必须改变 revisionDigest：游标时间轴（updatedAt/createdAt 变化重进页）
//    与内容摘要（含状态位）双保险；打卡硬删由批次对账回查发现（"deleted" 哨兵）。
//  - 变更重放模型：不新造队列系统——既有「(updatedAt,id) 游标 + sourceKey@revision 批次 receipt」
//    即持久变更队列（Core Data 保存、导入、删改、恢复、CloudKit 合并统一表现为 updatedAt 变化
//    进入下一轮分页；重复消息按批次键幂等跳过）。
//  - 纯 Core Data 读取，无 LLM；金额不进模型正文（§3.10），只进修订摘要保证修订敏感。
//

import CoreData
import Foundation

// MARK: - sourceKey 规范（§3.1）

enum HoloLifeSourceKeys {
    static let financePrefix = "finance:"
    static let taskPrefix = "task:"
    static let habitPrefix = "habit:"
    static let habitCheckinPrefix = "habit-checkin:"

    static func financeKey(_ id: UUID) -> String { financePrefix + id.uuidString }
    static func taskKey(_ id: UUID) -> String { taskPrefix + id.uuidString }
    static func habitKey(_ id: UUID) -> String { habitPrefix + id.uuidString }
    static func habitCheckinKey(_ id: UUID) -> String { habitCheckinPrefix + id.uuidString }

    /// sourceKey 的域归属（无前缀 = thought 存量）。
    static func domain(of sourceKey: String) -> String {
        if sourceKey.hasPrefix(financePrefix) { return "finance" }
        if sourceKey.hasPrefix(taskPrefix) { return "task" }
        if sourceKey.hasPrefix(habitCheckinPrefix) { return "habit" }
        if sourceKey.hasPrefix(habitPrefix) { return "habit" }
        return "thought"
    }

    /// 去掉域前缀的实体 ID（thought 原样返回）。
    static func entityID(of sourceKey: String) -> String {
        for prefix in [financePrefix, taskPrefix, habitCheckinPrefix, habitPrefix]
        where sourceKey.hasPrefix(prefix) {
            return String(sourceKey.dropFirst(prefix.count))
        }
        return sourceKey
    }
}

// MARK: - 财务域分页

@MainActor
struct HoloFinanceContextSourcePaging: HoloContextSourcePaging {
    let repository: FinanceRepository

    @MainActor
    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?) {
        let request = Transaction.fetchRequest()
        // 活源：未软删（作废/删除的交易不再产出新候选；删除经修订回查对账发现）。
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        request.fetchLimit = cursor == nil ? limit : limit * 2
        let results = try repository.context.fetch(request)
        let filtered = results.drop { transaction in
            guard let after = cursor?.updatedAt else { return false }
            if transaction.updatedAt < after { return true }
            let lastKey = HoloLifeSourceKeys.financeKey(transaction.id)
            return transaction.updatedAt == after && lastKey <= cursor?.sourceID ?? ""
        }
        let page = Array(filtered.prefix(limit)).filter { transaction in
            !(baseline != nil && transaction.updatedAt < baseline!)
        }
        let snapshots = page.map { transaction in
            let categoryText = transaction.category.map { category in
                repository.resolveCategoryNames(from: category).sub.map { "\($0)" } ?? category.name ?? ""
            } ?? ""
            var businessState: [String: String] = [
                "type": transaction.type,
            ]
            if !categoryText.isEmpty { businessState["category"] = categoryText }
            if transaction.installmentGroupId != nil { businessState["installment"] = "true" }
            return HoloContextSourceSnapshot(
                sourceID: HoloLifeSourceKeys.financeKey(transaction.id),
                sourceDomain: "finance",
                sourceKind: "transaction",
                revisionDigest: Self.revisionDigest(transaction),
                sourceCreatedAt: transaction.createdAt,
                sourceUpdatedAt: transaction.updatedAt,
                plainText: Self.observationText(transaction, categoryText: categoryText),
                sensitivity: .normal,
                accessGeneration: 1,
                eventTime: transaction.date,
                businessState: businessState
            )
        }
        guard let last = page.last else { return ([], nil) }
        return (snapshots, HoloContextSourceCursor(
            updatedAt: last.updatedAt,
            sourceID: HoloLifeSourceKeys.financeKey(last.id)
        ))
    }

    /// 模型可见正文：分类 + 备注（金额不进正文，§3.10；商品线索在 note/remark）。
    @MainActor
    static func observationText(_ transaction: Transaction, categoryText: String) -> String {
        var parts: [String] = []
        let typeName = transaction.type == "income" ? "收入" : "支出"
        if !categoryText.isEmpty { parts.append("【\(typeName)·\(categoryText)】") }
        let noteParts = [transaction.note, transaction.remark]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        parts.append(contentsOf: noteParts)
        return parts.joined(separator: " ")
    }

    /// 修订摘要：更新时间 + 交易语义字段（金额/类型/日期/备注/软删），任一变化即新修订。
    @MainActor
    static func revisionDigest(_ transaction: Transaction) -> String {
        let content = [
            transaction.type,
            transaction.amount.stringValue,
            ISO8601DateFormatter().string(from: transaction.date),
            transaction.note ?? "",
            transaction.remark ?? "",
            transaction.deletedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "alive",
        ].joined(separator: "|")
        return "\(transaction.updatedAt.timeIntervalSince1970)-\(HoloContextSuppressionKeys.stableDigest(content))"
    }
}

// MARK: - 任务域分页

@MainActor
struct HoloTaskContextSourcePaging: HoloContextSourcePaging {
    let repository: TodoRepository

    @MainActor
    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?) {
        let request = TodoTask.fetchRequest()
        // 活源：未删未归档；完成/撤销状态如实进 businessState（§3.1：创建不等于发生）。
        request.predicate = NSPredicate(format: "deletedFlag == NO AND archived == NO")
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        request.fetchLimit = cursor == nil ? limit : limit * 2
        let results = try repository.context.fetch(request)
        let filtered = results.drop { task in
            guard let after = cursor?.updatedAt else { return false }
            if task.updatedAt < after { return true }
            let lastKey = HoloLifeSourceKeys.taskKey(task.id)
            return task.updatedAt == after && lastKey <= cursor?.sourceID ?? ""
        }
        let page = Array(filtered.prefix(limit)).filter { task in
            !(baseline != nil && task.updatedAt < baseline!)
        }
        let snapshots = page.map { task in
            var businessState: [String: String] = [
                "completed": task.completed ? "true" : "false",
            ]
            if let completedAt = task.completedAt {
                businessState["completedAt"] = ISO8601DateFormatter().string(from: completedAt)
            }
            return HoloContextSourceSnapshot(
                sourceID: HoloLifeSourceKeys.taskKey(task.id),
                sourceDomain: "task",
                sourceKind: "todoTask",
                revisionDigest: Self.revisionDigest(task),
                sourceCreatedAt: task.createdAt,
                sourceUpdatedAt: task.updatedAt,
                plainText: Self.observationText(task),
                sensitivity: .normal,
                accessGeneration: 1,
                eventTime: task.completedAt ?? task.plannedStart ?? task.updatedAt,
                businessState: businessState
            )
        }
        guard let last = page.last else { return ([], nil) }
        return (snapshots, HoloContextSourceCursor(
            updatedAt: last.updatedAt,
            sourceID: HoloLifeSourceKeys.taskKey(last.id)
        ))
    }

    /// 模型可见正文：标题 + 正文（状态走 businessState，不塞正文重复表达）。
    @MainActor
    static func observationText(_ task: TodoTask) -> String {
        var text = "任务「\(task.title)」"
        if let desc = task.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            text += "：" + desc
        }
        return text
    }

    /// 修订摘要：完成/撤销/改期/改标题/软删都构成新修订。
    @MainActor
    static func revisionDigest(_ task: TodoTask) -> String {
        let content = [
            task.title,
            task.desc ?? "",
            task.completed ? "done" : "open",
            task.completedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            task.dueDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            task.deletedFlag ? "deleted" : "alive",
        ].joined(separator: "|")
        return "\(task.updatedAt.timeIntervalSince1970)-\(HoloContextSuppressionKeys.stableDigest(content))"
    }
}

// MARK: - 习惯域分页（定义 + 打卡，单一时间轴）

@MainActor
struct HoloHabitContextSourcePaging: HoloContextSourcePaging {
    let repository: HabitRepository

    /// 定义与打卡共用一条 (时间, sourceKey) 游标轴：定义按 updatedAt、打卡按 createdAt。
    @MainActor
    func fetchContextSourcePage(
        after cursor: HoloContextSourceCursor?,
        limit: Int,
        baseline: Date?
    ) async throws -> (sources: [HoloContextSourceSnapshot], nextCursor: HoloContextSourceCursor?) {
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "isArchived == NO")
        habitRequest.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let recordRequest = HabitRecord.fetchRequest()
        recordRequest.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let habitDefinitions = try repository.context.fetch(habitRequest)
        let checkinRecords = try repository.context.fetch(recordRequest)

        // 立即构造快照后统一排序分页（无延迟闭包；页内实体同 context 存活）。
        var unified: [(time: Date, key: String, snapshot: HoloContextSourceSnapshot)] = []
        for habit in habitDefinitions {
            unified.append((habit.updatedAt, HoloLifeSourceKeys.habitKey(habit.id), Self.definitionSnapshot(habit)))
        }
        for record in checkinRecords {
            unified.append((record.createdAt, HoloLifeSourceKeys.habitCheckinKey(record.id), Self.checkinSnapshot(record)))
        }
        unified.sort { lhs, rhs in
            if lhs.time == rhs.time { return lhs.key < rhs.key }
            return lhs.time < rhs.time
        }
        var startIndex = 0
        if let cursor {
            startIndex = unified.firstIndex { entry in
                if entry.time != cursor.updatedAt { return entry.time > cursor.updatedAt }
                return entry.key > cursor.sourceID
            } ?? unified.count
        }
        let page = unified[startIndex...].prefix(limit).filter { entry in
            !(baseline != nil && entry.time < baseline!)
        }
        let snapshots = page.map(\.snapshot)
        guard let last = page.last else { return ([], nil) }
        return (snapshots, HoloContextSourceCursor(updatedAt: last.time, sourceID: last.key))
    }

    @MainActor
    static func definitionSnapshot(_ habit: Habit) -> HoloContextSourceSnapshot {
        let frequencyText: String
        switch habit.habitFrequency {
        case .daily: frequencyText = "每天"
        case .weekly: frequencyText = "每周"
        case .monthly: frequencyText = "每月"
        }
        return HoloContextSourceSnapshot(
            sourceID: HoloLifeSourceKeys.habitKey(habit.id),
            sourceDomain: "habit",
            sourceKind: "habitDefinition",
            revisionDigest: Self.definitionRevisionDigest(habit),
            sourceCreatedAt: habit.createdAt,
            sourceUpdatedAt: habit.updatedAt,
            plainText: "习惯「\(habit.name)」（\(frequencyText)）",
            sensitivity: .normal,
            accessGeneration: 1,
            businessState: [
                "frequency": habit.frequency,
                "type": habit.habitType == .numeric ? "numeric" : "checkIn",
            ]
        )
    }

    @MainActor
    static func checkinSnapshot(_ record: HabitRecord) -> HoloContextSourceSnapshot {
        var text = "完成习惯打卡"
        if let habit = record.habit {
            text += "「\(habit.name)」"
        }
        if let value = record.value?.doubleValue {
            text += "，数值 \(value)"
        }
        if let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            text += "：" + note
        }
        var businessState: [String: String] = [
            "isCompleted": record.isCompleted ? "true" : "false",
        ]
        if let habit = record.habit { businessState["habitName"] = habit.name }
        return HoloContextSourceSnapshot(
            sourceID: HoloLifeSourceKeys.habitCheckinKey(record.id),
            sourceDomain: "habit",
            sourceKind: "habitCheckin",
            revisionDigest: Self.checkinRevisionDigest(record),
            sourceCreatedAt: record.createdAt,
            sourceUpdatedAt: record.createdAt,
            plainText: text,
            sensitivity: .normal,
            accessGeneration: 1,
            eventTime: record.date,
            lineageRootIDs: ["evt-checkin-\(record.id.uuidString)"],
            businessState: businessState
        )
    }

    @MainActor
    static func definitionRevisionDigest(_ habit: Habit) -> String {
        let content = [habit.name, habit.frequency, habit.isArchived ? "archived" : "active"].joined(separator: "|")
        return "\(habit.updatedAt.timeIntervalSince1970)-\(HoloContextSuppressionKeys.stableDigest(content))"
    }

    @MainActor
    static func checkinRevisionDigest(_ record: HabitRecord) -> String {
        let content = [
            record.habitId.uuidString,
            record.isCompleted ? "done" : "open",
            record.value?.stringValue ?? "",
            record.note ?? "",
        ].joined(separator: "|")
        return "\(record.createdAt.timeIntervalSince1970)-\(HoloContextSuppressionKeys.stableDigest(content))"
    }
}

// MARK: - 四域注册表与修订回查

@MainActor
enum HoloLifeSourceObservation {
    /// R1 接入的四域（thought 走既有实现；轮询顺序稳定保证游标公平推进）。
    static let domains: [String] = ["thought", "finance", "task", "habit"]

    static func makePaging(
        domain: String,
        context: NSManagedObjectContext = CoreDataStack.shared.viewContext
    ) -> (any HoloContextSourcePaging)? {
        switch domain {
        case "thought":
            return HoloThoughtContextSourcePaging(repository: ThoughtRepository())
        case "finance":
            return HoloFinanceContextSourcePaging(repository: FinanceRepository(context: context))
        case "task":
            return HoloTaskContextSourcePaging(repository: TodoRepository(context: context))
        case "habit":
            return HoloHabitContextSourcePaging(repository: HabitRepository(context: context, observesRemoteChanges: false))
        default:
            return nil
        }
    }

    /// 修订目录：按 sourceKey 前缀分派回查各域当前修订（软删/查不到 → "deleted" 哨兵，
    /// 触发批次对账拒绝）。thought 存量无前缀。
    static func currentRevisionDigests(
        sourceKeys: [String],
        context: NSManagedObjectContext = CoreDataStack.shared.viewContext,
        thoughtRepository: ThoughtRepository = ThoughtRepository()
    ) -> [String: String] {
        var revisions: [String: String] = [:]
        for sourceKey in sourceKeys {
            guard let uuid = UUID(uuidString: HoloLifeSourceKeys.entityID(of: sourceKey)) else {
                revisions[sourceKey] = "deleted"
                continue
            }
            switch HoloLifeSourceKeys.domain(of: sourceKey) {
            case "finance":
                let request = Transaction.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                if let transaction = (try? context.fetch(request))?.first {
                    // 业务删除（软删）视同来源消失：回查 deleted 哨兵触发失效传播。
                    revisions[sourceKey] = transaction.deletedAt == nil
                        ? HoloFinanceContextSourcePaging.revisionDigest(transaction)
                        : "deleted"
                } else {
                    revisions[sourceKey] = "deleted"
                }
            case "task":
                let request = TodoTask.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                if let task = (try? context.fetch(request))?.first {
                    revisions[sourceKey] = task.deletedFlag
                        ? "deleted"
                        : HoloTaskContextSourcePaging.revisionDigest(task)
                } else {
                    revisions[sourceKey] = "deleted"
                }
            case "habit":
                if sourceKey.hasPrefix(HoloLifeSourceKeys.habitCheckinPrefix) {
                    let request = HabitRecord.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                    if let record = (try? context.fetch(request))?.first {
                        revisions[sourceKey] = HoloHabitContextSourcePaging.checkinRevisionDigest(record)
                    } else {
                        revisions[sourceKey] = "deleted"
                    }
                } else {
                    let request = Habit.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                    if let habit = (try? context.fetch(request))?.first {
                        revisions[sourceKey] = HoloHabitContextSourcePaging.definitionRevisionDigest(habit)
                    } else {
                        revisions[sourceKey] = "deleted"
                    }
                }
            default:
                if let thought = try? thoughtRepository.fetchById(uuid) {
                    revisions[sourceKey] = HoloThoughtContextSourcePaging.revisionDigest(thought)
                } else {
                    revisions[sourceKey] = "deleted"
                }
            }
        }
        return revisions
    }
}
