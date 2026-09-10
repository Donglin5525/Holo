import CoreData
import Foundation

// V3 Phase 1 standalone：ThoughtTopicLink 投影层核心行为锁定。
// 运行方式见 scripts/run-thought-topic-link-standalone.sh（swiftc 直编，不挂 pbxproj）。

@main
struct ThoughtTopicLinkProjectionStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0) // precondition 崩溃时 stdout 缓冲会丢，先关缓冲
        let ctx = try makeContext()
        deterministicID()
        try backfillIdempotentAndShadowZero(ctx)
        try dualWriteLifecycleAndTombstoneSemantics(ctx)
        try projectionPriorityAcrossDuplicateRows(ctx)
        try mergeDualWrite(ctx)
        try supersededOnAIReplacement(ctx)
        print("PASS: 确定性ID、迁移幂等、shadow=0、双写生命周期、墓碑语义（V2镜像妥协在档）、重复行裁决、合并双写、AI替换superseded")
    }

    // MARK: - 1. 确定性 ID（防多设备重复 pair）

    static func deterministicID() {
        let t1 = UUID(), t2 = UUID(), p1 = UUID(), p2 = UUID()
        let a = ThoughtTopicLink.deterministicID(thoughtID: t1, topicID: p1)
        let b = ThoughtTopicLink.deterministicID(thoughtID: t1, topicID: p1)
        check(a == b, "同 pair 必须同 ID")
        check(a != ThoughtTopicLink.deterministicID(thoughtID: t1, topicID: p2))
        check(a != ThoughtTopicLink.deterministicID(thoughtID: t2, topicID: p1))
        check(a.uuidString != t1.uuidString && a.uuidString != p1.uuidString, "不得透传端点 ID")
        // 跨进程稳定：UUID 字节序处理一致（同输入两次运行结果相同由确定性算法保证）
    }

    // MARK: - 2. 存量迁移幂等 + shadow 对账为 0

    static func backfillIdempotentAndShadowZero(_ ctx: NSManagedObjectContext) throws {
        let (thoughtAI, topicAI) = try makePair(ctx, reason: "与理财相关")
        topicAI.addThoughts(thoughtAI)
        let (thoughtUnknown, topicUnknown) = try makePair(ctx, reason: nil)
        topicUnknown.addThoughts(thoughtUnknown)

        let r1 = try ThoughtTopicLinkProjection.backfillLegacyLinks(in: ctx)
        check(r1.linksCreated == 2, "首轮回填应建 2 条")
        check(r1.scannedThoughts == 2, "扫描应覆盖全部想法")

        // 映射：reason 非空 → legacy/ai；否则 legacy/unknown
        let linkAI = try fetchLink(ctx, thought: thoughtAI, topic: topicAI)
        check(linkAI.sourceEnum == .legacyAI && linkAI.visibilityEnum == .internalOnly)
        let linkUnknown = try fetchLink(ctx, thought: thoughtUnknown, topic: topicUnknown)
        check(linkUnknown.sourceEnum == .legacyUnknown)

        // 幂等：第二遍全 skip
        let r2 = try ThoughtTopicLinkProjection.backfillLegacyLinks(in: ctx)
        check(r2.linksCreated == 0 && r2.linksSkippedExisting == 2, "第二遍应零新增")

        // shadow 对账：旧关系集合 == active 投影集合
        let s = try ThoughtTopicLinkProjection.shadowDifference(in: ctx)
        check(s.isConsistent, "迁移后 shadow 差异必须为 0：\(s)")
        check(s.legacyPairs == 2 && s.projectedPairs == 2)
    }

    // MARK: - 3. 双写生命周期 + 墓碑语义

    static func dualWriteLifecycleAndTombstoneSemantics(_ ctx: NSManagedObjectContext) throws {
        let (thought, topic) = try makePair(ctx, reason: nil)

        // 手动移入（Repository 双写旧行为 + 投影层）
        topic.addThoughts(thought)
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: topic)
        var link = try fetchLink(ctx, thought: thought, topic: topic)
        check(link.isUserDecision && link.stateEnum == .active && link.visibilityEnum == .userVisible)
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent)

        // 手动移除：rejected 墓碑 + 旧关系摘除
        topic.removeThoughts(thought)
        ThoughtTopicLinkProjection.recordManualRemove(thought: thought, topic: topic)
        try ctx.save()
        link = try fetchLink(ctx, thought: thought, topic: topic)
        check(link.stateEnum == .rejected && link.rejectedAt != nil, "移除必须留墓碑")
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent, "墓碑不进投影")

        // Phase 1 已知妥协（在档）：V2 applyClassification 通道重建用户拒绝过的 pair 时，
        // link 层如实镜像旧行为翻回 active（V2 覆盖用户决定是 V3 要根治的缺陷，
        // 墓碑压制在 Phase 3 的 ai/v3 写入路径生效）。此处锁定的是镜像行为本身。
        topic.addThoughts(thought)
        ThoughtTopicLinkProjection.recordLegacyAIAssignment(thought: thought, topic: topic)
        link = try fetchLink(ctx, thought: thought, topic: topic)
        check(link.stateEnum == .active && link.sourceEnum == .legacyAI && link.visibilityEnum == .internalOnly)
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent)

        // 用户重建曾拒绝 pair（手动加回）→ 合法用户决定，覆盖 AI 行
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: topic)
        link = try fetchLink(ctx, thought: thought, topic: topic)
        check(link.isUserDecision && link.stateEnum == .active && link.rejectedAt == nil, "用户决定覆盖且清拒绝痕迹")

        // 迁移不复活用户决定：把行改回 rejected 后跑 backfill
        link.stateEnum = .rejected
        link.rejectedAt = Date()
        try ctx.save()
        let r = try ThoughtTopicLinkProjection.backfillLegacyLinks(in: ctx)
        check(r.linksPreservedUserDecision >= 1, "迁移必须保留用户拒绝决定")
        link = try fetchLink(ctx, thought: thought, topic: topic)
        check(link.stateEnum == .rejected, "迁移后墓碑仍在")
        // 恢复现场：摘掉 AI 重建的旧关系（墓碑保留），后续场景的全局 shadow 断言不被本场景遗留态污染
        topic.removeThoughts(thought)
        try ctx.save()
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent, "场景3收尾后全局一致")
    }

    // MARK: - 4. 同 pair 重复行裁决（CloudKit 竞态形态）

    static func projectionPriorityAcrossDuplicateRows(_ ctx: NSManagedObjectContext) throws {
        let (thought, topic) = try makePair(ctx, reason: nil)
        topic.addThoughts(thought)
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: topic)

        // 直接插入第二行（绕过 upsert，模拟多设备竞态产生的重复行）
        let ghost = ThoughtTopicLink(entity: NSEntityDescription.entity(forEntityName: "ThoughtTopicLink", in: ctx)!,
                                     insertInto: ctx)
        ghost.id = UUID() // 非确定性 ID，模拟异形重复
        ghost.thought = thought
        ghost.topic = topic
        ghost.sourceEnum = .legacyAI
        ghost.stateEnum = .active
        ghost.visibilityEnum = .internalOnly
        ghost.createdAt = Date(); ghost.updatedAt = Date(); ghost.consentGeneration = 0
        try ctx.save()

        let effective = ThoughtTopicLinkProjection.effectiveTopics(for: thought)
        check(effective.count == 1 && effective.first?.id == topic.id, "重复 pair 必须裁为一")

        let s = try ThoughtTopicLinkProjection.shadowDifference(in: ctx)
        check(s.duplicateLinkRows == 1, "重复行应被统计")

        // upsert 碰到确定性重复行时标 superseded 收敛
        let merged = ThoughtTopicLinkProjection.upsertLink(thought: thought, topic: topic)
        _ = merged
        check(ghost.stateEnum == .superseded, "upsert 应将重复行标 superseded")
    }

    // MARK: - 5. 合并双写

    static func mergeDualWrite(_ ctx: NSManagedObjectContext) throws {
        let (thought, keeper) = try makePair(ctx, reason: nil)
        let duplicate = Topic(context: ctx)
        duplicate.id = UUID(); duplicate.title = "重复主题"; duplicate.status = Topic.TopicStatus.active.rawValue
        duplicate.createdAt = Date(); duplicate.updatedAt = Date()
        keeper.addThoughts(thought)
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: keeper)
        duplicate.addThoughts(thought)
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: duplicate)

        // 镜像 Repository.merge 的旧行为：keeper 收编 + duplicate 标 merged（不摘关系）
        keeper.addThoughts(thought)
        duplicate.status = Topic.TopicStatus.merged.rawValue
        ThoughtTopicLinkProjection.recordMerge(into: keeper, from: duplicate)
        try ctx.save()

        check(try fetchLink(ctx, thought: thought, topic: keeper).stateEnum == .active)
        check(try fetchLink(ctx, thought: thought, topic: duplicate).stateEnum == .active, "镜像旧行为：duplicate 侧关系保留")
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent)
    }

    // MARK: - 6. AI 替换写 superseded

    static func supersededOnAIReplacement(_ ctx: NSManagedObjectContext) throws {
        let (thought, topic) = try makePair(ctx, reason: "旧分类理由")
        topic.addThoughts(thought)
        ThoughtTopicLinkProjection.recordLegacyAIAssignment(thought: thought, topic: topic)
        try ctx.save()

        // AI 分类替换（applyClassification 双写路径）：旧 pair 摘关系 + superseded
        topic.removeThoughts(thought)
        ThoughtTopicLinkProjection.recordSuperseded(thought: thought, topic: topic)
        try ctx.save()
        check(try fetchLink(ctx, thought: thought, topic: topic).stateEnum == .superseded)
        check(try ThoughtTopicLinkProjection.shadowDifference(in: ctx).isConsistent, "superseded 不进投影")
    }

    // MARK: - 夹具

    @discardableResult
    static func makePair(_ ctx: NSManagedObjectContext, reason: String?) throws -> (Thought, Topic) {
        let thought = Thought(context: ctx)
        thought.id = UUID(); thought.content = "样本 \(UUID().uuidString.prefix(6))"
        thought.createdAt = Date(); thought.updatedAt = Date()
        thought.topicAssignmentReason = reason
        thought.topicConfidence = reason == nil ? 0 : 0.8
        let topic = Topic(context: ctx)
        topic.id = UUID(); topic.title = "主题 \(UUID().uuidString.prefix(4))"
        topic.status = Topic.TopicStatus.classification.rawValue
        topic.createdAt = Date(); topic.updatedAt = Date()
        return (thought, topic)
    }

    static func fetchLink(_ ctx: NSManagedObjectContext, thought: Thought, topic: Topic) throws -> ThoughtTopicLink {
        let pairID = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", pairID as CVarArg)
        request.fetchLimit = 1
        guard let link = try ctx.fetch(request).first else { fatalError("link 行缺失：\(pairID)") }
        return link
    }

    // MARK: - 最小模型（类名指向真实 @objc 类；壳实体关系单向化，仅测试用）

    static func makeContext() throws -> NSManagedObjectContext {
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional
            return a
        }
        func toMany(_ name: String, _ dest: NSEntityDescription) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name; r.destinationEntity = dest; r.minCount = 0; r.maxCount = 0
            r.isOptional = true; r.deleteRule = .nullifyDeleteRule
            return r
        }

        let thought = NSEntityDescription()
        thought.name = "Thought"; thought.managedObjectClassName = "Thought"
        let topic = NSEntityDescription()
        topic.name = "Topic"; topic.managedObjectClassName = "Topic"
        let link = NSEntityDescription()
        link.name = "ThoughtTopicLink"; link.managedObjectClassName = "ThoughtTopicLink"

        // 核心三对关系必须互为 inverse（单向关系两侧不联动，backfill 读不到）
        let thoughtTopicsRel = toMany("topics", topic)
        let topicThoughtsRel = toMany("thoughts", thought)
        thoughtTopicsRel.inverseRelationship = topicThoughtsRel
        topicThoughtsRel.inverseRelationship = thoughtTopicsRel

        let thoughtTopicLinksRel = toMany("topicLinks", link)
        thoughtTopicLinksRel.deleteRule = .cascadeDeleteRule
        let topicTopicLinksRel = toMany("topicLinks", link)
        topicTopicLinksRel.deleteRule = .cascadeDeleteRule

        // 壳实体（仅承载关系端点，类用基类）
        let tag = NSEntityDescription(); tag.name = "ThoughtTag"; tag.managedObjectClassName = "NSManagedObject"
        let reference = NSEntityDescription(); reference.name = "ThoughtReference"; reference.managedObjectClassName = "NSManagedObject"
        let assignment = NSEntityDescription(); assignment.name = "ThoughtTagAssignment"; assignment.managedObjectClassName = "NSManagedObject"
        let attachment = NSEntityDescription(); attachment.name = "ThoughtAttachment"; attachment.managedObjectClassName = "NSManagedObject"
        let task = NSEntityDescription(); task.name = "TodoTask"; task.managedObjectClassName = "NSManagedObject"
        for shell in [tag, reference, assignment, attachment, task] {
            shell.properties = [attr("id", .UUIDAttributeType, optional: false)]
        }

        thought.properties = [
            attr("id", .UUIDAttributeType, optional: false), attr("content", .stringAttributeType, optional: false),
            attr("createdAt", .dateAttributeType, optional: false), attr("updatedAt", .dateAttributeType, optional: false),
            attr("mood", .stringAttributeType), attr("orderIndex", .integer16AttributeType),
            attr("imageData", .binaryDataAttributeType), attr("isSoftDeleted", .booleanAttributeType),
            attr("isArchived", .booleanAttributeType), attr("organizedStatus", .stringAttributeType),
            attr("createdDeviceId", .stringAttributeType), attr("organizationStartedAt", .dateAttributeType),
            attr("richContentJSON", .stringAttributeType), attr("firstLine", .stringAttributeType),
            attr("topicConfidence", .doubleAttributeType), attr("topicAssignmentReason", .stringAttributeType),
            attr("indexRequestedHash", .stringAttributeType), attr("indexCompletedHash", .stringAttributeType),
            attr("indexOperationID", .UUIDAttributeType), attr("indexAttemptCount", .integer16AttributeType),
            attr("indexNextAttemptAt", .dateAttributeType), attr("indexEngineVersion", .stringAttributeType),
            attr("deletedAt", .dateAttributeType), attr("deletedBatchId", .UUIDAttributeType),
            toMany("tags", tag), toMany("references", reference), toMany("referencedBy", reference),
            toMany("tagAssignments", assignment),
            thoughtTopicsRel, thoughtTopicLinksRel,
            toMany("attachments", attachment), toMany("createdTasks", task)
        ]

        topic.properties = [
            attr("id", .UUIDAttributeType, optional: false), attr("title", .stringAttributeType, optional: false),
            attr("iconEmoji", .stringAttributeType), attr("summary", .stringAttributeType),
            attr("status", .stringAttributeType, optional: false), attr("confidence", .doubleAttributeType),
            attr("associatedTagNames", .stringAttributeType), attr("thoughtCount", .integer16AttributeType),
            attr("createdAt", .dateAttributeType, optional: false), attr("updatedAt", .dateAttributeType, optional: false),
            attr("titleSource", .stringAttributeType), attr("originClusterFingerprint", .stringAttributeType),
            attr("summaryVersion", .integer16AttributeType), attr("summaryBasisRevision", .stringAttributeType),
            attr("summaryUpdatedAt", .dateAttributeType), attr("topicRevision", .integer64AttributeType),
            attr("deletedAt", .dateAttributeType), attr("deletedBatchId", .UUIDAttributeType),
            attr("isArchived", .booleanAttributeType), attr("rejectedAt", .dateAttributeType),
            topicThoughtsRel, toMany("associatedTags", tag), toMany("mergedFromTopics", topic),
            topicTopicLinksRel
        ]
        // mergedToTopic（to-one 自引用）
        let mergedTo = NSRelationshipDescription()
        mergedTo.name = "mergedToTopic"; mergedTo.destinationEntity = topic
        mergedTo.minCount = 0; mergedTo.maxCount = 1; mergedTo.isOptional = true
        mergedTo.deleteRule = .nullifyDeleteRule
        topic.properties.append(mergedTo)

        let linkThought = NSRelationshipDescription()
        linkThought.name = "thought"; linkThought.destinationEntity = thought
        linkThought.minCount = 0; linkThought.maxCount = 1; linkThought.isOptional = true
        linkThought.deleteRule = .nullifyDeleteRule
        let linkTopic = NSRelationshipDescription()
        linkTopic.name = "topic"; linkTopic.destinationEntity = topic
        linkTopic.minCount = 0; linkTopic.maxCount = 1; linkTopic.isOptional = true
        linkTopic.deleteRule = .nullifyDeleteRule

        thoughtTopicLinksRel.inverseRelationship = linkThought
        linkThought.inverseRelationship = thoughtTopicLinksRel
        topicTopicLinksRel.inverseRelationship = linkTopic
        linkTopic.inverseRelationship = topicTopicLinksRel

        link.properties = [
            attr("id", .UUIDAttributeType, optional: false),
            attr("source", .stringAttributeType, optional: false),
            attr("state", .stringAttributeType, optional: false),
            attr("visibility", .stringAttributeType, optional: false),
            attr("basisTextHash", .stringAttributeType), attr("engineVersion", .stringAttributeType),
            attr("decisionTier", .stringAttributeType), attr("evidenceRange", .stringAttributeType),
            attr("consentGeneration", .integer64AttributeType),
            attr("createdAt", .dateAttributeType, optional: false), attr("updatedAt", .dateAttributeType, optional: false),
            attr("rejectedAt", .dateAttributeType),
            linkThought, linkTopic
        ]

        let model = NSManagedObjectModel()
        model.entities = [thought, topic, link, tag, reference, assignment, attachment, task]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
