import CoreData
import Foundation

@main
struct GlobalDuplicateRepairStandaloneTests {
    static func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "check failed at line \(line)") }

    static func main() throws {
        try todoScenario()
        try flatEntityScenario()
        print("PASS: 任务域副本合并（文件夹/清单/任务级联+独有子行改挂+同id子行随删+共享标签并回+想法链接保留）、平面实体合并、内容冲突保留、同步身份延迟、未保存编辑、幂等")
    }

    /// 任务域真实重复形态：清单副本挂着独有任务（改挂防级联陪葬）、
    /// 任务副本带同 id 子任务副本（随删）与独有子任务（改挂）、共享标签并回、想法链接保住。
    static func todoScenario() throws {
        let model = makeModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var names: [NSManagedObjectID: String] = [:]
        @discardableResult
        func insert(_ entityName: String, _ name: String, _ values: [String: Any]) throws -> NSManagedObject {
            let entity = model.entitiesByName[entityName]!
            let row = NSManagedObject(entity: entity, insertInto: context)
            for (key, value) in values { row.setValue(value, forKey: key) }
            try context.obtainPermanentIDs(for: [row]); names[row.objectID] = name
            return row
        }
        func relatedIds(_ row: NSManagedObject, _ key: String) -> Set<UUID> {
            Set(((row.value(forKey: key) as? Set<NSManagedObject>) ?? []).compactMap { $0.value(forKey: "id") as? UUID })
        }

        // 未保存编辑不能被修复顺带提交。
        let scratch = try insert("TodoList", "scratch", ["id": UUID(), "name": "草稿", "updatedAt": Date(timeIntervalSince1970: 1)])
        let guarded = try GlobalDuplicateRepair.repair(in: context, recordName: { names[$0] })
        check(guarded.removed == 0 && guarded.deferredGroups == 1)
        try context.save()

        let updated1 = Date(timeIntervalSince1970: 1)
        let updated2 = Date(timeIntervalSince1970: 2)

        // 清单副本：保留项 a-l、副本 b-l；独有任务 TASK-U 挂在副本上。
        let listId = UUID()
        let listS = try insert("TodoList", "a-l", ["id": listId, "name": "跨越", "updatedAt": updated1])
        let listD = try insert("TodoList", "b-l", ["id": listId, "name": "跨越", "updatedAt": updated2])
        let taskUId = UUID()
        let taskUnique = try insert("TodoTask", "task-u", ["id": taskUId, "title": "独有任务", "list": listD, "updatedAt": updated1])

        // 任务副本：保留项 a-t、副本 b-t（to-one 指向同一想法，副本内容必然一致）。
        let taskId = UUID()
        let thoughtId = UUID()
        let thought = try insert("Thought", "th-1", ["id": thoughtId, "content": "来源想法"])
        let taskS = try insert("TodoTask", "a-t", ["id": taskId, "title": "主任务", "list": listS, "sourceThought": thought, "updatedAt": updated1])
        let taskD = try insert("TodoTask", "b-t", ["id": taskId, "title": "主任务", "list": listS, "sourceThought": thought, "updatedAt": updated2])

        // 共享标签：两边都有 TAG1；副本独有 TAG2（并回保留项）。
        let tag1Id = UUID()
        let tag2Id = UUID()
        let tag1 = try insert("TodoTag", "tag-1", ["id": tag1Id])
        let tag2 = try insert("TodoTag", "tag-2", ["id": tag2Id])
        (taskS.value(forKey: "tags") as? NSMutableSet)?.add(tag1)
        (taskD.value(forKey: "tags") as? NSMutableSet)?.add(tag1)
        (taskD.value(forKey: "tags") as? NSMutableSet)?.add(tag2)

        // 子任务：同 id 副本 ITEM-X（保留项上的直接合并删除）+ 副本独有 ITEM-Y（改挂）。
        let itemXId = UUID()
        let itemYId = UUID()
        _ = try insert("CheckItem", "item-x1", ["id": itemXId, "task": taskS])
        _ = try insert("CheckItem", "item-x2", ["id": itemXId, "task": taskD])
        _ = try insert("CheckItem", "item-y", ["id": itemYId, "task": taskD])

        // 内容冲突与同步身份缺失各一组。
        let conflictId = UUID()
        _ = try insert("TodoList", "l-c1", ["id": conflictId, "name": "甲", "updatedAt": updated1])
        _ = try insert("TodoList", "l-c2", ["id": conflictId, "name": "乙", "updatedAt": updated1])
        let deferredId = UUID()
        let waiting = try insert("TodoList", "l-w1", ["id": deferredId, "name": "阅读", "updatedAt": updated1])
        _ = try insert("TodoList", "l-w2", ["id": deferredId, "name": "阅读", "updatedAt": updated1])
        names.removeValue(forKey: waiting.objectID)
        try context.save()

        let result = try GlobalDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 3)  // 同id子任务副本、清单副本、任务副本各删一行
        check(result.removedByEntity["CheckItem"] == 1)
        check(result.removedByEntity["TodoList"] == 1)
        check(result.removedByEntity["TodoTask"] == 1)
        check(result.reattachedChildren == 2)  // TASK-U 改挂保留清单 + ITEM-Y 改挂保留任务
        check(result.reattachedShared == 1)    // TAG2 并回
        precondition(result.conflictingGroups == 1 && result.deferredGroups == 1)

        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TodoList")) == 6)  // 保留项+草稿+冲突2+延迟2
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TodoTask")) == 2)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "CheckItem")) == 2)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TodoTag")) == 2)

        // 记录名排序定保留项；清单副本的独有任务已改挂保留项。
        precondition((taskUnique.value(forKey: "list") as? NSManagedObject)?.objectID == listS.objectID)
        // 任务副本独有标签并回；同 id 子任务副本随删，独有子任务改挂。
        check(relatedIds(taskS, "tags") == [tag1Id, tag2Id])
        check(relatedIds(taskS, "checkItems") == [itemXId, itemYId])
        // 想法链接保留在保留项上。
        precondition((taskS.value(forKey: "sourceThought") as? NSManagedObject)?.objectID == thought.objectID)
        // updatedAt 取组内最新。
        precondition(listS.value(forKey: "updatedAt") as? Date == updated2)
        precondition(taskS.value(forKey: "updatedAt") as? Date == updated2)
        let survivingScratch = try fetchSingle(context, entityName: "TodoList", id: scratch.value(forKey: "id") as! UUID)
        precondition(scratch.objectID == survivingScratch.objectID)

        // 再跑一遍必须无动作（幂等）。
        let again = try GlobalDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(again.removed == 0 && again.reattachedChildren == 0 && again.reattachedShared == 0)
        precondition(again.conflictingGroups == 1 && again.deferredGroups == 1)
    }

    /// 平面实体（无关系，如纪念日/洞察/聊天消息）：等内容副本合并、updatedAt 取 max。
    static func flatEntityScenario() throws {
        let model = makeModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var names: [NSManagedObjectID: String] = [:]
        @discardableResult
        func insert(_ entityName: String, _ name: String, _ values: [String: Any]) throws -> NSManagedObject {
            let entity = model.entitiesByName[entityName]!
            let row = NSManagedObject(entity: entity, insertInto: context)
            for (key, value) in values { row.setValue(value, forKey: key) }
            try context.obtainPermanentIDs(for: [row]); names[row.objectID] = name
            return row
        }

        let updated1 = Date(timeIntervalSince1970: 10)
        let updated2 = Date(timeIntervalSince1970: 20)
        let anniversaryId = UUID()
        let survivor = try insert("Anniversary", "an-a", ["id": anniversaryId, "title": "领证", "updatedAt": updated1])
        _ = try insert("Anniversary", "an-b", ["id": anniversaryId, "title": "领证", "updatedAt": updated2])
        try context.save()

        let result = try GlobalDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 1)
        check(result.removedByEntity["Anniversary"] == 1)
        let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Anniversary"))
        precondition(rows.count == 1 && rows[0].objectID == survivor.objectID)
        precondition(survivor.value(forKey: "updatedAt") as? Date == updated2)
    }

    static func fetchSingle(_ context: NSManagedObjectContext, entityName: String, id: UUID) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let row = try context.fetch(request).first else { fatalError("断言前置失败：\(entityName) 无行") }
        return row
    }

    /// 迷你任务域模型：关系形态与 CoreDataStack+TodoEntities 一致
    /// （清单→任务 cascade、任务→子任务 cascade、任务↔标签 nullify 多对多、任务→想法 nullify）。
    static func makeModel() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true
            return a
        }
        func toOne(_ name: String, _ destination: NSEntityDescription) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name; r.destinationEntity = destination
            r.minCount = 0; r.maxCount = 1; r.isOptional = true
            r.deleteRule = .nullifyDeleteRule
            return r
        }
        func toMany(_ name: String, _ destination: NSEntityDescription, rule: NSDeleteRule) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name; r.destinationEntity = destination
            r.minCount = 0; r.maxCount = 0; r.isOptional = true
            r.deleteRule = rule
            return r
        }

        let folder = NSEntityDescription()
        folder.name = "TodoFolder"; folder.managedObjectClassName = "NSManagedObject"
        folder.properties = [attr("id", .UUIDAttributeType), attr("name", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let list = NSEntityDescription()
        list.name = "TodoList"; list.managedObjectClassName = "NSManagedObject"
        list.properties = [attr("id", .UUIDAttributeType), attr("name", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let task = NSEntityDescription()
        task.name = "TodoTask"; task.managedObjectClassName = "NSManagedObject"
        task.properties = [attr("id", .UUIDAttributeType), attr("title", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let item = NSEntityDescription()
        item.name = "CheckItem"; item.managedObjectClassName = "NSManagedObject"
        item.properties = [attr("id", .UUIDAttributeType)]

        let tag = NSEntityDescription()
        tag.name = "TodoTag"; tag.managedObjectClassName = "NSManagedObject"
        tag.properties = [attr("id", .UUIDAttributeType)]

        let thought = NSEntityDescription()
        thought.name = "Thought"; thought.managedObjectClassName = "NSManagedObject"
        thought.properties = [attr("id", .UUIDAttributeType), attr("content", .stringAttributeType)]

        let anniversary = NSEntityDescription()
        anniversary.name = "Anniversary"; anniversary.managedObjectClassName = "NSManagedObject"
        anniversary.properties = [attr("id", .UUIDAttributeType), attr("title", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let folderLists = toMany("lists", list, rule: .cascadeDeleteRule)
        let listFolder = toOne("folder", folder)
        folderLists.inverseRelationship = listFolder; listFolder.inverseRelationship = folderLists

        let listTasks = toMany("tasks", task, rule: .cascadeDeleteRule)
        let taskList = toOne("list", list)
        listTasks.inverseRelationship = taskList; taskList.inverseRelationship = listTasks

        let taskItems = toMany("checkItems", item, rule: .cascadeDeleteRule)
        let itemTask = toOne("task", task)
        taskItems.inverseRelationship = itemTask; itemTask.inverseRelationship = taskItems

        let taskTags = toMany("tags", tag, rule: .nullifyDeleteRule)
        let tagTasks = toMany("tasks", task, rule: .nullifyDeleteRule)
        taskTags.inverseRelationship = tagTasks; tagTasks.inverseRelationship = taskTags

        let taskSourceThought = toOne("sourceThought", thought)
        let thoughtTasks = toMany("createdTasks", task, rule: .nullifyDeleteRule)
        taskSourceThought.inverseRelationship = thoughtTasks; thoughtTasks.inverseRelationship = taskSourceThought

        list.properties = list.properties + [listFolder, listTasks]
        folder.properties = folder.properties + [folderLists]
        task.properties = task.properties + [taskList, taskItems, taskTags, taskSourceThought]
        item.properties = item.properties + [itemTask]
        tag.properties = tag.properties + [tagTasks]
        thought.properties = thought.properties + [thoughtTasks]

        let model = NSManagedObjectModel()
        model.entities = [folder, list, task, item, tag, thought, anniversary]
        return model
    }
}
