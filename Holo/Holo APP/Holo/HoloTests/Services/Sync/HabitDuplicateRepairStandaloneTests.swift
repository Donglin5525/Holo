import CoreData
import Foundation

@main
struct HabitDuplicateRepairStandaloneTests {
    static func check(_ condition: Bool) { precondition(condition) }

    static func main() throws {
        try habitScenario()
        print("PASS: 习惯副本合并、记录副本删除、孤儿记录改挂、内容冲突保留、同步身份延迟、未保存编辑、幂等")
    }

    /// 重复导入的真实形态：习惯原件+打卡记录原件，副本+记录副本。
    /// 合并时副本的同 id 记录要删（否则双份计打卡），独有记录要改挂（否则级联陪葬）。
    static func habitScenario() throws {
        let model = makeHabitModel()
        guard let habitEntity = model.entities.first(where: { $0.name == "Habit" }),
              let recordEntity = model.entities.first(where: { $0.name == "Record" }),
              let goalEntity = model.entities.first(where: { $0.name == "Goal" }) else {
            fatalError("习惯测试模型缺实体")
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var names: [NSManagedObjectID: String] = [:]
        @discardableResult
        func insert(_ entity: NSEntityDescription, _ name: String, _ values: [String: Any]) throws -> NSManagedObject {
            let row = NSManagedObject(entity: entity, insertInto: context)
            for (key, value) in values { row.setValue(value, forKey: key) }
            try context.obtainPermanentIDs(for: [row]); names[row.objectID] = name
            return row
        }

        // 未保存编辑不能被修复顺带提交。
        let scratch = try insert(habitEntity, "scratch", ["id": UUID(), "name": "草稿", "updatedAt": Date(timeIntervalSince1970: 1)])
        let guarded = try HabitDuplicateRepair.repair(in: context, recordName: { names[$0] })
        check(guarded.removed == 0 && guarded.deferredGroups == 1)
        try context.save()

        let goalId = UUID()
        let goalA = try insert(goalEntity, "goal-a", ["id": goalId, "updatedAt": Date(timeIntervalSince1970: 1)])
        let goalB = try insert(goalEntity, "goal-b", ["id": goalId, "updatedAt": Date(timeIntervalSince1970: 2)])

        let habitId = UUID()
        let updated1 = Date(timeIntervalSince1970: 1)
        let updated2 = Date(timeIntervalSince1970: 2)
        let habitS = try insert(habitEntity, "h-a", ["id": habitId, "name": "戒烟", "updatedAt": updated1, "goal": goalA])
        let habitD = try insert(habitEntity, "h-b", ["id": habitId, "name": "戒烟", "updatedAt": updated2, "goal": goalB])
        let recordId1 = UUID()
        let recordId3 = UUID()
        _ = try insert(recordEntity, "rec-1", ["id": recordId1, "updatedAt": updated1, "habit": habitS])
        // 记录副本：与保留项的记录同 id，合并时必须删，不能改挂成双份。
        _ = try insert(recordEntity, "rec-2", ["id": recordId1, "updatedAt": updated2, "habit": habitD])
        // 副本独有记录：改挂保留项，不能跟副本级联陪葬。
        _ = try insert(recordEntity, "rec-3", ["id": recordId3, "updatedAt": updated2, "habit": habitD])

        // 内容冲突（name 不一致）：整组保留。
        let conflictId = UUID()
        _ = try insert(habitEntity, "h-c1", ["id": conflictId, "name": "健身", "updatedAt": updated1])
        _ = try insert(habitEntity, "h-c2", ["id": conflictId, "name": "健身 2", "updatedAt": updated1])
        // 同步身份未建立（缺记录名）：整组等待。
        let deferredId = UUID()
        let waiting = try insert(habitEntity, "h-w1", ["id": deferredId, "name": "阅读", "updatedAt": updated1])
        _ = try insert(habitEntity, "h-w2", ["id": deferredId, "name": "阅读", "updatedAt": updated1])
        names.removeValue(forKey: waiting.objectID)
        try context.save()

        let result = try HabitDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 1 && result.remapped == 1 && result.removedRecords == 1)
        precondition(result.conflictingGroups == 1 && result.deferredGroups == 1)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Habit")) == 6)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Record")) == 2)
        // 记录名排序决定保留项："h-a" 存活，updatedAt 取组内最新。
        let survivingHabit = try fetchSingle(context, entityName: "Habit", id: habitId)
        precondition(habitS.objectID == survivingHabit.objectID)
        precondition(habitS.value(forKey: "updatedAt") as? Date == updated2)
        // 副本独有记录改挂到保留项，记录副本已删。
        check(recordIds(of: habitS) == [recordId1, recordId3])
        // goal 副本按 id 判等不阻塞合并，保留项自己的 goal 链接不变。
        precondition((habitS.value(forKey: "goal") as? NSManagedObject)?.objectID == goalA.objectID)
        let survivingScratch = try fetchSingle(context, entityName: "Habit", id: scratch.value(forKey: "id") as! UUID)
        precondition(scratch.objectID == survivingScratch.objectID)
        // 再跑一遍必须无动作（幂等）。
        let again = try HabitDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(again.removed == 0 && again.remapped == 0 && again.removedRecords == 0)
        precondition(again.conflictingGroups == 1 && again.deferredGroups == 1)
    }

    static func recordIds(of habit: NSManagedObject) -> Set<UUID> {
        let records = (habit.value(forKey: "records") as? Set<NSManagedObject>) ?? []
        return Set(records.compactMap { $0.value(forKey: "id") as? UUID })
    }

    static func makeHabitModel() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true
            return a
        }
        let goal = NSEntityDescription()
        goal.name = "Goal"; goal.managedObjectClassName = "NSManagedObject"
        goal.properties = [attr("id", .UUIDAttributeType), attr("updatedAt", .dateAttributeType)]

        let habit = NSEntityDescription()
        habit.name = "Habit"; habit.managedObjectClassName = "NSManagedObject"
        habit.properties = [attr("id", .UUIDAttributeType), attr("name", .stringAttributeType), attr("updatedAt", .dateAttributeType), attr("deletedAt", .dateAttributeType)]

        let record = NSEntityDescription()
        record.name = "Record"; record.managedObjectClassName = "NSManagedObject"
        record.properties = [attr("id", .UUIDAttributeType), attr("updatedAt", .dateAttributeType)]

        let habitRecords = NSRelationshipDescription()
        habitRecords.name = "records"; habitRecords.destinationEntity = record
        habitRecords.minCount = 0; habitRecords.maxCount = 0; habitRecords.isOptional = true
        habitRecords.deleteRule = .cascadeDeleteRule
        let recordHabit = NSRelationshipDescription()
        recordHabit.name = "habit"; recordHabit.destinationEntity = habit
        recordHabit.minCount = 0; recordHabit.maxCount = 1; recordHabit.isOptional = true
        recordHabit.deleteRule = .nullifyDeleteRule
        habitRecords.inverseRelationship = recordHabit
        recordHabit.inverseRelationship = habitRecords

        let habitGoal = NSRelationshipDescription()
        habitGoal.name = "goal"; habitGoal.destinationEntity = goal
        habitGoal.minCount = 0; habitGoal.maxCount = 1; habitGoal.isOptional = true
        habitGoal.deleteRule = .nullifyDeleteRule

        habit.properties = habit.properties + [habitRecords, habitGoal]
        record.properties = record.properties + [recordHabit]

        let model = NSManagedObjectModel()
        model.entities = [goal, habit, record]
        return model
    }

    static func fetchSingle(_ context: NSManagedObjectContext, entityName: String, id: UUID) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let row = try context.fetch(request).first else { fatalError("断言前置失败：\(entityName) 无行") }
        return row
    }
}
