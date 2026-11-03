// 积累读模型与同步事件。复用现有偏好实体的独立键，不新增 CloudKit Schema。
import Foundation
import CoreData
import OSLog

nonisolated enum HoloGrowthStore {
    // 只串行化积累读写与全量清空事务；锁内不跨队列、不等待主线程。
    static let transactionLock = NSRecursiveLock()
    static let eventPrefix = "growth.milestone."
    private static let logger = Logger(subsystem: "com.holo.app", category: "GrowthStore")
    static let reminderKey = "growth.reminders.enabled"

    struct Result: Sendable {
        let snapshot: HoloGrowthSnapshot
        let events: [HoloGrowthMilestone]
        let previousEvents: [HoloGrowthMilestone]
        let remindersEnabled: Bool
    }

    static func load(context: NSManagedObjectContext, now: Date, persist: Bool) throws -> Result {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        var facts: [HoloGrowthMetric: [HoloGrowthFact]] = [:]
        let accountIDs = Set(try rows("Account", columns: [], context: context).compactMap { $0["id"] as? UUID })
        var orphanAccounts = 0
        facts[.finance] = try rows("Transaction", columns: ["date", "createdAt", "type", "isReconciliationAdjustment", "importBatchId", "importSource"], accountID: true, context: context).compactMap { row in
            guard let id = row["id"] as? UUID, let date = row["date"] as? Date,
                  let created = row["createdAt"] as? Date, let type = row["type"] as? String,
                  ["income", "expense"].contains(type), (row["isReconciliationAdjustment"] as? Bool) != true else { return nil }
            if let accountID = row["accountID"] as? UUID, !accountIDs.contains(accountID) {
                orphanAccounts += 1
                return nil
            }
            return HoloGrowthFact(id: id, date: date, recordedAt: created,
                                  allowsCelebration: row["importBatchId"] == nil && row["importSource"] == nil)
        }
        facts[.thought] = try rows("Thought", columns: ["createdAt", "isSoftDeleted"], context: context).compactMap { row in
            guard let id = row["id"] as? UUID, let date = row["createdAt"] as? Date,
                  (row["isSoftDeleted"] as? Bool) != true else { return nil }
            return HoloGrowthFact(id: id, date: date, recordedAt: date, allowsCelebration: true)
        }
        // 结算时间是习惯模块的增量字段：旧模型按自然日，新模型复用同一归属规则。
        let habitAttributes = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Habit"]?.attributesByName ?? [:]
        let settlementColumns = ["dayEndHour", "dayEndMinute"].filter { habitAttributes[$0] != nil }
        let habits = try rows("Habit", columns: ["type", "isBadHabit"] + settlementColumns, context: context)
        let habitByID = Dictionary(habits.compactMap { row in (row["id"] as? UUID).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let records = try rows("HabitRecord", columns: ["habitId", "date", "createdAt", "isCompleted", "isRetroactive"], context: context)
        struct DayRecord {
            let fact: HoloGrowthFact
            let completed: Bool
        }
        var latestByDay: [String: DayRecord] = [:]
        var orphanHabits = 0
        let calendar = Calendar.current
        for row in records {
            guard let id = row["id"] as? UUID, let habitID = row["habitId"] as? UUID,
                  let date = row["date"] as? Date, let created = row["createdAt"] as? Date else { continue }
            guard let habit = habitByID[habitID] else { orphanHabits += 1; continue }
            guard (habit["type"] as? NSNumber)?.int16Value == HabitType.checkIn.rawValue,
                  (habit["isBadHabit"] as? Bool) != true else { continue }
            let dayEnd = ((habit["dayEndHour"] as? NSNumber)?.intValue ?? 0) * 60 + ((habit["dayEndMinute"] as? NSNumber)?.intValue ?? 0)
            let retroactive = (row["isRetroactive"] as? Bool) == true
            let day = calendar.startOfDay(for: HabitDayAttribution.attributedMoment(recordDate: date,
                isRetroactive: retroactive, dayEndMinutes: dayEnd, calendar: calendar))
            let today = HabitDayAttribution.attributedDay(now, dayEndMinutes: dayEnd, calendar: calendar)
            guard day <= today, date <= now else { continue }
            let key = "\(habitID.uuidString).\(day.timeIntervalSince1970)"
            let completed = (row["isCompleted"] as? Bool) == true
            if let existing = latestByDay[key] {
                if existing.fact.recordedAt > created { continue }
                // 同时刻的撤销优先，防止副本遍历顺序改变完成状态。
                if existing.fact.recordedAt == created && !existing.completed { continue }
            }
            latestByDay[key] = DayRecord(fact: HoloGrowthFact(id: id, date: day, recordedAt: created,
                allowsCelebration: !retroactive && (habit["isBadHabit"] as? Bool) != true), completed: completed)
        }
        facts[.habit] = latestByDay.values.filter(\.completed).map(\.fact)
        if orphanAccounts + orphanHabits > 0 {
            logger.notice("积累已隔离父记录删除或尚未同步的记录：收支 \(orphanAccounts)，打卡 \(orphanHabits)")
        }
        let snapshot = HoloGrowthRules.snapshot(facts: facts, now: now)
        let previous = try events(context: context)
        let reconciled = persist ? HoloGrowthRules.reconcile(previous, snapshot: snapshot) : previous
        if persist {
            let known = Set(previous.map(\.id))
            let encoder = JSONEncoder()
            for event in reconciled where !known.contains(event.id) {
                let row = UserPreferenceEntity(context: context)
                row.key = eventPrefix + event.id
                row.value = String(decoding: try encoder.encode(event), as: UTF8.self)
                row.updatedAt = now
            }
            if context.hasChanges { try context.save() }
        }
        let reminderRequest = UserPreferenceEntity.fetchRequest()
        reminderRequest.predicate = NSPredicate(format: "key == %@", reminderKey)
        let enabled = try context.fetch(reminderRequest).max { $0.updatedAt < $1.updatedAt }?.value != "false"
        return Result(snapshot: snapshot, events: reconciled, previousEvents: previous, remindersEnabled: enabled)
    }

    /// 所有入口读取同一批稳定事件；不从当前连续天数反推历史。
    static func events(context: NSManagedObjectContext) throws -> [HoloGrowthMilestone] {
        let request = UserPreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key BEGINSWITH %@", eventPrefix + "v1.")
        let decoder = JSONDecoder()
        let decoded = try context.fetch(request).map { try decoder.decode(HoloGrowthMilestone.self, from: Data($0.value.utf8)) }
        return Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: HoloGrowthRules.merge).values.sorted {
            let lhs = $0.achievedAt ?? $0.discoveredAt, rhs = $1.achievedAt ?? $1.discoveredAt
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func setReminders(_ enabled: Bool, context: NSManagedObjectContext) throws {
        let request = UserPreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", reminderKey)
        let rows = try context.fetch(request)
        let row = rows.max { $0.updatedAt < $1.updatedAt } ?? UserPreferenceEntity(context: context)
        row.key = reminderKey
        row.value = enabled ? "true" : "false"
        row.updatedAt = Date()
        for duplicate in rows where duplicate !== row { context.delete(duplicate) }
        try context.save()
    }

    /// 全量清除与业务清除处在同一个事务；历史成就不能绕过用户删除意图。
    static func clear(context: NSManagedObjectContext) throws {
        let request = UserPreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key BEGINSWITH %@ OR key == %@", eventPrefix, reminderKey)
        for row in try context.fetch(request) { context.delete(row) }
    }

    /// 只投影计数所需字段，绝不物化想法正文/图片或触发逐笔账户查询。
    private static func rows(_ entity: String, columns: [String], accountID: Bool = false,
                             context: NSManagedObjectContext) throws -> [[String: Any]] {
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.resultType = .dictionaryResultType
        request.includesPendingChanges = false
        let identity = NSExpressionDescription()
        identity.name = "rowID"
        identity.expression = NSExpression.expressionForEvaluatedObject()
        identity.expressionResultType = .objectIDAttributeType
        var properties: [Any] = ["id", "deletedAt"] + columns
        properties.append(identity)
        if accountID {
            let parent = NSExpressionDescription()
            parent.name = "accountID"
            parent.expression = NSExpression(forKeyPath: "account.id")
            parent.expressionResultType = .UUIDAttributeType
            properties.append(parent)
        }
        request.propertiesToFetch = properties
        var unique: [UUID: [String: Any]] = [:]
        func rowNumber(_ row: [String: Any]) -> Int {
            guard let id = row["rowID"] as? NSManagedObjectID else { return .max }
            return Int(id.uriRepresentation().lastPathComponent.drop(while: { !$0.isNumber })) ?? .max
        }
        for value in try context.fetch(request) {
            guard let row = value as? [String: Any], let id = row["id"] as? UUID else { continue }
            if let existing = unique[id], rowNumber(existing) <= rowNumber(row) { continue }
            unique[id] = row
        }
        // 与全局副本规则同语义：先选最早物理行，再隔离删除态，防止活旧副本复活。
        return unique.values.filter { $0["deletedAt"] == nil || $0["deletedAt"] is NSNull }
    }
}
