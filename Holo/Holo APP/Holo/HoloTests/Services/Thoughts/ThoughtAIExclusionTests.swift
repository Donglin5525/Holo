//
//  ThoughtAIExclusionTests.swift
//  HoloTests
//
//  标签级 AI 排除（2026-10-21 方案）核心测试：
//  判定口径（只认用户关联）/ AI 聚合过滤 / 双向 reconcile / 合并继承 / 长期记忆按源删除
//  方案：docs/_common/notes/2026-10-21-想法标签AI排除产品方案.md
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtAIExclusionTests: XCTestCase {

    // MARK: - In-Memory Core Data

    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "AIExclusionTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = ThoughtRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext, content: String = "今天记了一条想法，内容足够长。") throws -> UUID {
        let thought = ctx.insertTestObject(Thought.self)
        let id = UUID()
        thought.id = id
        thought.content = content
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()
        return id
    }

    private func fetchThought(_ id: UUID, in ctx: NSManagedObjectContext) throws -> Thought {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        guard let thought = try ctx.fetch(request).first else {
            throw XCTSkip("想法不存在")
        }
        return thought
    }

    private func setExcludeFromAI(_ excluded: Bool, tagName: String, in ctx: NSManagedObjectContext) throws {
        let request = ThoughtTag.fetchRequest()
        let tags = try ctx.fetch(request)
        let key = ThoughtTagNormalizer.key(tagName)
        guard let tag = tags.first(where: { ThoughtTagNormalizer.key($0.name) == key }) else {
            throw XCTSkip("标签不存在：\(tagName)")
        }
        tag.excludeFromAI = excluded
        try ctx.save()
    }

    private func makeActiveTopicLink(thoughtId: UUID, topicTitle: String, in ctx: NSManagedObjectContext) throws -> Topic {
        let thought = try fetchThought(thoughtId, in: ctx)
        let topic = ctx.insertTestObject(Topic.self)
        topic.id = UUID()
        topic.title = topicTitle
        topic.status = Topic.TopicStatus.classification.rawValue
        topic.confidence = 0
        topic.thoughtCount = 1
        topic.createdAt = Date()
        topic.updatedAt = Date()
        let link = ctx.insertTestObject(ThoughtTopicLink.self)
        link.id = UUID()
        link.thought = thought
        link.topic = topic
        link.source = "ai/v3"
        link.state = "active"
        link.visibility = "internal"
        link.consentGeneration = 0
        link.createdAt = Date()
        link.updatedAt = Date()
        try ctx.save()
        return topic
    }

    // MARK: - 判定口径

    func test_判定_用户关联命中排除() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .manual, confidence: 1)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let thought = try fetchThought(id, in: ctx)
        XCTAssertTrue(ThoughtAIAudience.isExcluded(thought), "用户手打标签命中排除应生效")
    }

    func test_判定_AI关联不触发排除() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .ai, confidence: 0.9)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let thought = try fetchThought(id, in: ctx)
        XCTAssertFalse(ThoughtAIAudience.isExcluded(thought), "AI 自动打的标签不触发排除（防自缠绕）")
    }

    func test_判定_rejectedAI不触发() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .confirmedAI, confidence: 0.9)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)
        // 用户拒绝过这个 AI 标签 → 关联失效
        let request = ThoughtTagAssignment.fetchRequest()
        request.predicate = NSPredicate(format: "thought.id == %@", id as CVarArg)
        let assignment = try XCTUnwrap(try ctx.fetch(request).first)
        assignment.source = ThoughtTagAssignment.Source.rejectedAI.rawValue
        assignment.rejectedAt = Date()
        try ctx.save()

        let thought = try fetchThought(id, in: ctx)
        XCTAssertFalse(ThoughtAIAudience.isExcluded(thought), "rejectedAI 关联不触发排除")
    }

    func test_判定_混合标签整条退出() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "工作", source: .manual, confidence: 1)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .inline, confidence: 1)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let thought = try fetchThought(id, in: ctx)
        XCTAssertTrue(ThoughtAIAudience.isExcluded(thought), "带任一排除标签即整条退出")
    }

    func test_谓词_fetch过滤与用户查询共存() throws {
        let (repo, ctx) = try makeRepo()
        let excludedId = try makeThought(in: ctx, content: "这条是日记内容不该给AI看到")
        let normalId = try makeThought(in: ctx, content: "这条是正常工作想法")
        _ = try makeThought(in: ctx, content: "这条只有AI打的标签")
        try repo.createTagAssignment(thoughtId: excludedId, tagName: "日记", source: .manual, confidence: 1)
        try repo.createTagAssignment(thoughtId: normalId, tagName: "工作", source: .manual, confidence: 1)
        let aiOnlyTagId = try makeThought(in: ctx, content: "AI 自动打标签的想法")
        try repo.createTagAssignment(thoughtId: aiOnlyTagId, tagName: "日记", source: .ai, confidence: 0.9)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let request = Thought.fetchRequest()
        request.predicate = ThoughtAIAudience.aiVisible(
            NSPredicate(format: "deletedAt == nil AND isArchived == NO"))
        let visible = try ctx.fetch(request)
        XCTAssertEqual(visible.count, 3, "命中排除的一条被过滤；AI 打「日记」的两条不受影响（其一为 aiOnlyTagId）")

        // 用户查询（fetchAll 不过滤）不受影响：全部 4 条可见
        XCTAssertEqual(try repo.fetchAll().count, 4, "用户界面查询照常包含排除想法")
    }

    // MARK: - AI 聚合方法过滤

    func test_AI聚合方法_排除命中想法() throws {
        let (repo, ctx) = try makeRepo()
        let excludedId = try makeThought(in: ctx, content: "日记内容不该出现在任何AI聚合里")
        try makeThought(in: ctx, content: "正常想法内容一")
        try makeThought(in: ctx, content: "正常想法内容二")
        try repo.createTagAssignment(thoughtId: excludedId, tagName: "日记", source: .manual, confidence: 1)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let start = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

        XCTAssertEqual(repo.getThoughtCount(from: start, to: end), 2, "计数不含排除想法——连条数都不给 AI")
        XCTAssertEqual(repo.getThoughtTexts(from: start, to: end, limit: 10).count, 2, "原文摘录不含排除想法")
        XCTAssertTrue(repo.getTopTags(from: start, to: end, limit: 10)
            .allSatisfy { ThoughtTagNormalizer.key($0.name) != ThoughtTagNormalizer.key("日记") },
            "热门标签统计不含排除标签")

        // 按天计数：AI 口径排除 / 用户口径（周观察）照常包含
        XCTAssertEqual(repo.getThoughtCountByDay(from: start, to: end, aiVisibleOnly: true).values.reduce(0, +), 2)
        XCTAssertEqual(repo.getThoughtCountByDay(from: start, to: end).values.reduce(0, +), 3)
    }

    // MARK: - 子页数据源

    func test_子页数据源_只列用户标签() throws {
        let (repo, ctx) = try makeRepo()
        let userThought = try makeThought(in: ctx)
        let aiThought = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: userThought, tagName: "日记", source: .manual, confidence: 1)
        try repo.createTagAssignment(thoughtId: aiThought, tagName: "灵感碎片", source: .ai, confidence: 0.9)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let scopeTags = repo.fetchUserTagsForAIScope()
        XCTAssertTrue(scopeTags.contains { ThoughtTagNormalizer.key($0.tag.name) == ThoughtTagNormalizer.key("日记") },
                      "用户标签在列")
        XCTAssertFalse(scopeTags.contains { ThoughtTagNormalizer.key($0.tag.name) == ThoughtTagNormalizer.key("灵感碎片") },
                       "纯 AI 标签不提供排除开关（判定只认用户关联，给了也永不生效）")

        XCTAssertEqual(repo.countExcludedTags(), 1)
        XCTAssertEqual(repo.countExcludedThoughts(), 1)
    }

    // MARK: - 双向 reconcile

    func test_reconcile_命中排除_落excluded并撤AI痕迹() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .manual, confidence: 1)
        try repo.createTagAssignment(thoughtId: id, tagName: "情绪", source: .ai, confidence: 0.9)
        let topic = try makeActiveTopicLink(thoughtId: id, topicTitle: "内心记录", in: ctx)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        let outcome = ThoughtAIExclusionService.performReconcile(thoughtIDs: [id], in: ctx)

        XCTAssertEqual(outcome.excluded, [id], "命中即收集")
        let thought = try fetchThought(id, in: ctx)
        XCTAssertEqual(thought.organizedStatus, ThoughtAIClassificationPolicy.excludedStatus, "状态落地 excluded")

        let assignments = try ctx.fetch(ThoughtTagAssignment.fetchRequest())
        XCTAssertEqual(assignments.first { ThoughtTagNormalizer.key($0.tag?.name ?? "") == ThoughtTagNormalizer.key("日记") }?.source,
                       ThoughtTagAssignment.Source.manual.rawValue,
                       "用户关联不动")
        XCTAssertEqual(assignments.first { ThoughtTagNormalizer.key($0.tag?.name ?? "") == ThoughtTagNormalizer.key("情绪") }?.indexState,
                       ThoughtIndexState.superseded.rawValue,
                       "AI 打的标签退出有效集")

        let links = try ctx.fetch(ThoughtTopicLink.fetchRequest())
        XCTAssertEqual(links.first?.stateEnum, .superseded, "AI 主题归属走 superseded 墓碑（非 rejected，防类别理解反证外泄）")
        XCTAssertEqual(topic.statusEnum, .hidden, "成员归零的分类主题收口为 hidden")
    }

    func test_reconcile_解除命中_恢复pending() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .manual, confidence: 1)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)
        _ = ThoughtAIExclusionService.performReconcile(thoughtIDs: [id], in: ctx)

        // 用户关闭排除：标签事实解除 → 恢复
        try setExcludeFromAI(false, tagName: "日记", in: ctx)
        let outcome = ThoughtAIExclusionService.performReconcile(thoughtIDs: [id], in: ctx)

        XCTAssertEqual(outcome.restored, 1, "困在 excluded 的想法恢复")
        XCTAssertEqual(try fetchThought(id, in: ctx).organizedStatus, "pending", "恢复后回到待整理，等管线重新归类")
    }

    func test_reconcile_幂等_重复执行无重复副作用() throws {
        let (repo, ctx) = try makeRepo()
        let id = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: id, tagName: "日记", source: .manual, confidence: 1)
        _ = try makeActiveTopicLink(thoughtId: id, topicTitle: "内心记录", in: ctx)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        _ = ThoughtAIExclusionService.performReconcile(thoughtIDs: [id], in: ctx)
        let second = ThoughtAIExclusionService.performReconcile(thoughtIDs: [id], in: ctx)

        let links = try ctx.fetch(ThoughtTopicLink.fetchRequest())
        XCTAssertEqual(links.count, 1, "不产生重复墓碑")
        XCTAssertEqual(links.first?.stateEnum, .superseded, "墓碑状态保持 superseded")
        XCTAssertEqual(second.excluded, [id], "已标记的仍幂等收集（供 actor 侧清向量），但不重复落地")
    }

    // MARK: - 合并继承

    func test_合并_排除属性安全继承() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "日记", source: .manual, confidence: 1)
        try repo.createTagAssignment(thoughtId: t2, tagName: "记录", source: .manual, confidence: 1)
        try setExcludeFromAI(true, tagName: "日记", in: ctx)

        // 「日记」合并进「记录」：目标必须继承排除（隐私泄漏方向，宁可多排除）
        _ = try repo.renameTag(from: "日记", to: "记录")

        let request = ThoughtTag.fetchRequest()
        let tags = try ctx.fetch(request)
        XCTAssertTrue(tags.contains { ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key("记录") && $0.excludeFromAI },
                      "合并目标继承排除属性")
        XCTAssertFalse(tags.contains { ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key("日记") },
                       "源标签已删除")
    }

    // 长期记忆按源删除的验证在 HoloLegacyMemoryStoreRegressionTests（Standalone 独立进程）：
    // FileStore 在 XCTest 宿主内同步测试会触发 malloc 析构崩溃（welcomenote 1015 实证坑）。
}
