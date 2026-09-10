import CoreData
import Foundation
@testable import Holo

@main
struct ThoughtDuplicateRepairStandaloneTests {
    static func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "check failed at line \(line)") }

    static func main() throws {
        try thoughtScenario()
        print("PASS: 想法副本合并、标签主题并回、同id挂子行随删、独有挂子行改挂、引用双侧改指、任务链接保留、内容冲突保留、同步身份延迟、未保存编辑、幂等")
    }

    /// 重复导入的真实形态：想法原件+挂子行原件，副本+挂子行副本。
    /// 合并时副本的同 id 挂子行随级联删（与保留项同 id 同内容），独有挂子行改挂（否则级联陪葬），
    /// 副本独有的标签/主题并回保留项（nullify 脱离前抢救），任务只保链接不删行。
    static func thoughtScenario() throws {
        let model = makeThoughtModel()
        guard let thoughtEntity = model.entities.first(where: { $0.name == "Thought" }),
              let tagEntity = model.entities.first(where: { $0.name == "ThoughtTag" }),
              let topicEntity = model.entities.first(where: { $0.name == "Topic" }),
              let assignmentEntity = model.entities.first(where: { $0.name == "ThoughtTagAssignment" }),
              let attachmentEntity = model.entities.first(where: { $0.name == "ThoughtAttachment" }),
              let referenceEntity = model.entities.first(where: { $0.name == "ThoughtReference" }),
              let taskEntity = model.entities.first(where: { $0.name == "TodoTask" }) else {
            fatalError("想法测试模型缺实体")
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
        let scratch = try insert(thoughtEntity, "scratch", ["id": UUID(), "content": "草稿", "updatedAt": Date(timeIntervalSince1970: 1)])
        let guarded = try ThoughtDuplicateRepair.repair(in: context, recordName: { names[$0] })
        check(guarded.removed == 0 && guarded.deferredGroups == 1)
        try context.save()

        let updated1 = Date(timeIntervalSince1970: 1)
        let updated2 = Date(timeIntervalSince1970: 2)
        let thoughtId = UUID()
        let thoughtS = try insert(thoughtEntity, "t-a", ["id": thoughtId, "content": "喂猫", "updatedAt": updated1])
        let thoughtD = try insert(thoughtEntity, "t-b", ["id": thoughtId, "content": "喂猫", "updatedAt": updated2])
        // 旁观想法，做引用的对端。
        let witnessId = UUID()
        let witness = try insert(thoughtEntity, "t-w", ["id": witnessId, "content": "旁观", "updatedAt": updated1])

        // 标签：共享 T1 + 副本独有 T2；主题：副本独有 TP。
        let tag1Id = UUID()
        let tag2Id = UUID()
        let tag1 = try insert(tagEntity, "tag-1", ["id": tag1Id])
        let tag2 = try insert(tagEntity, "tag-2", ["id": tag2Id])
        let topicId = UUID()
        let topic = try insert(topicEntity, "topic-1", ["id": topicId])
        (thoughtS.value(forKey: "tags") as? NSMutableSet)?.add(tag1)
        (thoughtD.value(forKey: "tags") as? NSMutableSet)?.add(tag1)
        (thoughtD.value(forKey: "tags") as? NSMutableSet)?.add(tag2)
        (thoughtD.value(forKey: "topics") as? NSMutableSet)?.add(topic)

        // 标签分配：保留项 X + 副本同 id 副本 X（随级联删）+ 副本独有 Y（改挂）。
        let assignmentXId = UUID()
        let assignmentYId = UUID()
        _ = try insert(assignmentEntity, "asg-1", ["id": assignmentXId, "thought": thoughtS])
        _ = try insert(assignmentEntity, "asg-2", ["id": assignmentXId, "thought": thoughtD])
        _ = try insert(assignmentEntity, "asg-3", ["id": assignmentYId, "thought": thoughtD])

        // 附件：同 id 副本 Z（随级联删）+ 副本独有 ATT（改挂）。
        let attachmentZId = UUID()
        let attachmentAId = UUID()
        _ = try insert(attachmentEntity, "att-1", ["id": attachmentZId, "thought": thoughtS])
        _ = try insert(attachmentEntity, "att-2", ["id": attachmentZId, "thought": thoughtD])
        _ = try insert(attachmentEntity, "att-3", ["id": attachmentAId, "thought": thoughtD])

        // 引用：副本发起 REF1（source=D）、指向副本 REF2（target=D），合并后都改指保留项。
        let ref1Id = UUID()
        let ref2Id = UUID()
        _ = try insert(referenceEntity, "ref-1", ["id": ref1Id, "sourceThought": thoughtD, "targetThought": witness])
        _ = try insert(referenceEntity, "ref-2", ["id": ref2Id, "sourceThought": witness, "targetThought": thoughtD])

        // 任务：副本独有链接 TASK1（改挂保链接）；同 id 任务副本 TASK2 不删（任务域修复器的事）。
        let task1Id = UUID()
        let task2Id = UUID()
        _ = try insert(taskEntity, "task-1", ["id": task1Id, "sourceThought": thoughtD])
        let taskCopy = try insert(taskEntity, "task-2", ["id": task2Id, "sourceThought": thoughtS])
        _ = try insert(taskEntity, "task-3", ["id": task2Id, "sourceThought": thoughtD])

        // 内容冲突（content 不一致）：整组保留。
        let conflictId = UUID()
        _ = try insert(thoughtEntity, "t-c1", ["id": conflictId, "content": "甲", "updatedAt": updated1])
        _ = try insert(thoughtEntity, "t-c2", ["id": conflictId, "content": "乙", "updatedAt": updated1])
        // 同步身份未建立（缺记录名）：整组等待。
        let deferredId = UUID()
        let waiting = try insert(thoughtEntity, "t-w1", ["id": deferredId, "content": "阅读", "updatedAt": updated1])
        _ = try insert(thoughtEntity, "t-w2", ["id": deferredId, "content": "阅读", "updatedAt": updated1])
        names.removeValue(forKey: waiting.objectID)
        try context.save()

        let result = try ThoughtDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(result.removed == 1)
        precondition(result.reattachedTags == 2 && result.reattachedChildren == 5)
        precondition(result.conflictingGroups == 1 && result.deferredGroups == 1)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Thought")) == 7)
        // 副本同 id 分配/附件副本随级联消失，独有行存活在保留项上。
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ThoughtTagAssignment")) == 2)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ThoughtAttachment")) == 2)
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ThoughtReference")) == 2)
        // 同 id 任务副本不删（任务域修复器的范围），仅随 nullify 脱离。
        try check(context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "TodoTask")) == 3)

        // 记录名排序决定保留项："t-a" 存活，updatedAt 取组内最新。
        let survivingThought = try fetchSingle(context, entityName: "Thought", id: thoughtId)
        precondition(thoughtS.objectID == survivingThought.objectID)
        precondition(thoughtS.value(forKey: "updatedAt") as? Date == updated2)
        // 副本独有的标签/主题已并回保留项。
        let survivorTagIds = Set(((thoughtS.value(forKey: "tags") as? Set<NSManagedObject>) ?? []).compactMap { $0.value(forKey: "id") as? UUID })
        check(survivorTagIds == [tag1Id, tag2Id])
        let survivorTopicIds = Set(((thoughtS.value(forKey: "topics") as? Set<NSManagedObject>) ?? []).compactMap { $0.value(forKey: "id") as? UUID })
        check(survivorTopicIds == [topicId])
        // 挂子行改挂后全部挂在保留项上；任务链接改指保留项，同 id 任务副本已脱离。
        check(relatedIds(thought: thoughtS, key: "tagAssignments") == [assignmentXId, assignmentYId])
        check(relatedIds(thought: thoughtS, key: "attachments") == [attachmentZId, attachmentAId])
        check(relatedIds(thought: thoughtS, key: "references") == [ref1Id])
        check(relatedIds(thought: thoughtS, key: "referencedBy") == [ref2Id])
        // 保留项原有 task-2 + 改挂来的 task-1；同 id 任务副本 task-3 脱离后归任务域修复器管。
        check(relatedIds(thought: thoughtS, key: "createdTasks") == [task1Id, task2Id])
        precondition((taskCopy.value(forKey: "sourceThought") as? NSManagedObject)?.objectID == thoughtS.objectID)
        let survivingScratch = try fetchSingle(context, entityName: "Thought", id: scratch.value(forKey: "id") as! UUID)
        precondition(scratch.objectID == survivingScratch.objectID)
        // 再跑一遍必须无动作（幂等）。
        let again = try ThoughtDuplicateRepair.repair(in: context, recordName: { names[$0] })
        precondition(again.removed == 0 && again.reattachedTags == 0 && again.reattachedChildren == 0)
        precondition(again.conflictingGroups == 1 && again.deferredGroups == 1)
    }

    static func relatedIds(thought: NSManagedObject, key: String) -> Set<UUID> {
        Set(((thought.value(forKey: key) as? Set<NSManagedObject>) ?? []).compactMap { $0.value(forKey: "id") as? UUID })
    }

    static func makeThoughtModel() -> NSManagedObjectModel {
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

        let thought = NSEntityDescription()
        thought.name = "Thought"; thought.managedObjectClassName = "NSManagedObject"
        thought.properties = [attr("id", .UUIDAttributeType), attr("content", .stringAttributeType), attr("updatedAt", .dateAttributeType)]

        let tag = NSEntityDescription()
        tag.name = "ThoughtTag"; tag.managedObjectClassName = "NSManagedObject"
        tag.properties = [attr("id", .UUIDAttributeType)]

        let topic = NSEntityDescription()
        topic.name = "Topic"; topic.managedObjectClassName = "NSManagedObject"
        topic.properties = [attr("id", .UUIDAttributeType)]

        let assignment = NSEntityDescription()
        assignment.name = "ThoughtTagAssignment"; assignment.managedObjectClassName = "NSManagedObject"
        assignment.properties = [attr("id", .UUIDAttributeType)]

        let attachment = NSEntityDescription()
        attachment.name = "ThoughtAttachment"; attachment.managedObjectClassName = "NSManagedObject"
        attachment.properties = [attr("id", .UUIDAttributeType)]

        let reference = NSEntityDescription()
        reference.name = "ThoughtReference"; reference.managedObjectClassName = "NSManagedObject"
        reference.properties = [attr("id", .UUIDAttributeType)]

        let task = NSEntityDescription()
        task.name = "TodoTask"; task.managedObjectClassName = "NSManagedObject"
        task.properties = [attr("id", .UUIDAttributeType)]

        let thoughtTags = toMany("tags", tag, rule: .nullifyDeleteRule)
        let tagThoughts = toMany("thoughts", thought, rule: .nullifyDeleteRule)
        thoughtTags.inverseRelationship = tagThoughts; tagThoughts.inverseRelationship = thoughtTags

        let thoughtTopics = toMany("topics", topic, rule: .nullifyDeleteRule)
        let topicThoughts = toMany("thoughts", thought, rule: .nullifyDeleteRule)
        thoughtTopics.inverseRelationship = topicThoughts; topicThoughts.inverseRelationship = thoughtTopics

        let thoughtAssignments = toMany("tagAssignments", assignment, rule: .cascadeDeleteRule)
        let assignmentThought = toOne("thought", thought)
        thoughtAssignments.inverseRelationship = assignmentThought; assignmentThought.inverseRelationship = thoughtAssignments

        let thoughtAttachments = toMany("attachments", attachment, rule: .cascadeDeleteRule)
        let attachmentThought = toOne("thought", thought)
        thoughtAttachments.inverseRelationship = attachmentThought; attachmentThought.inverseRelationship = thoughtAttachments

        let thoughtReferences = toMany("references", reference, rule: .cascadeDeleteRule)
        let referenceSource = toOne("sourceThought", thought)
        thoughtReferences.inverseRelationship = referenceSource; referenceSource.inverseRelationship = thoughtReferences

        let thoughtReferencedBy = toMany("referencedBy", reference, rule: .cascadeDeleteRule)
        let referenceTarget = toOne("targetThought", thought)
        thoughtReferencedBy.inverseRelationship = referenceTarget; referenceTarget.inverseRelationship = thoughtReferencedBy

        let thoughtTasks = toMany("createdTasks", task, rule: .nullifyDeleteRule)
        let taskSourceThought = toOne("sourceThought", thought)
        thoughtTasks.inverseRelationship = taskSourceThought; taskSourceThought.inverseRelationship = thoughtTasks

        thought.properties = thought.properties + [thoughtTags, thoughtTopics, thoughtAssignments, thoughtAttachments, thoughtReferences, thoughtReferencedBy, thoughtTasks]
        tag.properties = tag.properties + [tagThoughts]
        topic.properties = topic.properties + [topicThoughts]
        assignment.properties = assignment.properties + [assignmentThought]
        attachment.properties = attachment.properties + [attachmentThought]
        reference.properties = reference.properties + [referenceSource, referenceTarget]
        task.properties = task.properties + [taskSourceThought]

        let model = NSManagedObjectModel()
        model.entities = [thought, tag, topic, assignment, attachment, reference, task]
        return model
    }

    static func fetchSingle(_ context: NSManagedObjectContext, entityName: String, id: UUID) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let row = try context.fetch(request).first else { fatalError("断言前置失败：\(entityName) 无行") }
        return row
    }
}
