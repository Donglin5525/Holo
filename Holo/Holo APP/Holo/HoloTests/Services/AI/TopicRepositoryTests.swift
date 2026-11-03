//
//  TopicRepositoryTests.swift
//  HoloTests
//
//  Topic Repository 测试（P1.5.1）
//  覆盖 创建/幂等查重/归一化/状态/合并/thoughtCount 实时算/同步后去重
//

import XCTest
import CoreData
@testable import Holo

final class TopicRepositoryTests: XCTestCase {

    private func makeRepo() throws -> (TopicRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TopicRepoTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        let repository = TopicRepository(context: ctx)
        CoreDataTestSupport.retain(container, ctx, repository)
        return (repository, ctx)
    }

    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext) throws -> Thought {
        let t = ctx.insertTestObject(Thought.self)
        t.id = UUID()
        t.content = "测试"
        t.createdAt = Date()
        t.updatedAt = Date()
        t.orderIndex = 0
        t.organizedStatus = "organized"
        try ctx.save()
        return t
    }

    /// 存量旧关系 → link 迁移（与生产 backfill bootstrap 同路径）。
    /// 读源统一（2026-09-27 P0-A）后，裸旧关系不是合法读态——生产写点全部
    /// 双写 link，存量经启动回填；测试直接摆旧关系后同样补一次回填。
    @discardableResult
    private func backfillLegacy(_ ctx: NSManagedObjectContext) throws -> ThoughtTopicLinkProjection.BackfillReport {
        let report = try ThoughtTopicLinkProjection.backfillLegacyLinks(in: ctx)
        try ctx.save()
        return report
    }

    // MARK: - 创建

    func test_创建主题默认candidate状态() throws {
        let (repo, _) = try makeRepo()
        let topic = try repo.create(title: "编程实践")
        XCTAssertEqual(topic.statusEnum, .candidate)
        XCTAssertEqual(topic.title, "编程实践")
    }

    // MARK: - 幂等查重

    func test_幂等创建同标题复用() throws {
        let (repo, _) = try makeRepo()
        let t1 = try repo.getOrCreateTopic(title: "编程实践")
        let t2 = try repo.getOrCreateTopic(title: "编程实践")
        XCTAssertEqual(t1.id, t2.id)
    }

    func test_归一化查重忽略大小写与首尾空格() throws {
        let (repo, _) = try makeRepo()
        _ = try repo.create(title: "Coding")
        // 注：中文无大小写，用英文验证 lowercased
        let found = try repo.getByTitle("  coding  ")
        XCTAssertNotNil(found)
    }

    // MARK: - 状态

    func test_hide改状态为hidden() throws {
        let (repo, _) = try makeRepo()
        let topic = try repo.create(title: "主题A")
        try repo.hide(topic)
        XCTAssertEqual(topic.statusEnum, .hidden)
    }

    func test_activate改状态为active() throws {
        let (repo, _) = try makeRepo()
        let topic = try repo.create(title: "主题A")
        try repo.activate(topic)
        XCTAssertEqual(topic.statusEnum, .active)
    }

    func test_classification主题与历史active主题分流() throws {
        let (repo, _) = try makeRepo()
        let historical = try repo.create(title: "历史主题")
        try repo.activate(historical)
        let classification = try repo.createClassificationTopic(title: "工作与事业")

        XCTAssertEqual(try repo.fetchClassificationTopics().map(\.id), [classification.id])
        XCTAssertTrue(try repo.fetchVisibleTopics().contains(where: { $0.id == historical.id }))
    }

    func test_历史主题关系不污染未归类口径() throws {
        let (repo, ctx) = try makeRepo()
        let historical = try repo.create(title: "旧版主题")
        try repo.activate(historical)
        let thought = try makeThought(in: ctx)
        try repo.assign(thoughtId: thought.id, toTopic: historical.id)

        let thoughtRepository = ThoughtRepository(context: ctx)
        CoreDataTestSupport.retain(thoughtRepository)
        XCTAssertTrue(try thoughtRepository.fetchUnclassifiedThoughts().contains(where: { $0.id == thought.id }))
    }

    func test_applyClassification只保留一个分类主题且nil回未归类() throws {
        let (repo, ctx) = try makeRepo()
        let work = try repo.createClassificationTopic(title: "工作与事业")
        let health = try repo.createClassificationTopic(title: "生活与健康")
        let thought = try makeThought(in: ctx)

        try repo.applyClassification(thoughtId: thought.id, topicTitle: work.title, tagPaths: ["工作与事业/规划"])
        try repo.applyClassification(thoughtId: thought.id, topicTitle: health.title, tagPaths: ["生活与健康/跑步"])

        let classificationIds = ((thought.topics as? Set<Topic>) ?? [])
            .filter(\.isClassificationTopic)
            .map(\.id)
        XCTAssertEqual(classificationIds, [health.id])

        try repo.applyClassification(thoughtId: thought.id, topicTitle: nil, tagPaths: ["未分类/随手记"])
        let thoughtRepository = ThoughtRepository(context: ctx)
        CoreDataTestSupport.retain(thoughtRepository)
        XCTAssertTrue(try thoughtRepository.fetchUnclassifiedThoughts().contains(where: { $0.id == thought.id }))
    }

    func test_未分类保留字不能创建或改名为实体主题() throws {
        let (repo, _) = try makeRepo()
        XCTAssertThrowsError(try repo.createClassificationTopic(title: "未分类"))

        let topic = try repo.createClassificationTopic(title: "工作与事业")
        XCTAssertThrowsError(try repo.renameClassificationTopic(topic, to: "未分类"))
        XCTAssertEqual(topic.title, "工作与事业")
    }

    // MARK: - 合并

    func test_merge合并thoughts到keeper并标记merged() throws {
        let (repo, ctx) = try makeRepo()
        let keeper = try repo.create(title: "编程实践")
        try repo.activate(keeper)
        let dup = try repo.create(title: "编程实践 2")
        let thought = try makeThought(in: ctx)
        dup.addThoughts(thought)
        try backfillLegacy(ctx)

        try repo.merge(into: keeper, from: dup)

        XCTAssertEqual(dup.statusEnum, .merged)
        XCTAssertEqual(dup.mergedToTopic, keeper)
        XCTAssertEqual(repo.thoughtCount(of: keeper), 1)
    }

    // MARK: - thoughtCount 实时算

    func test_thoughtCount实时算不缓存() throws {
        let (repo, ctx) = try makeRepo()
        let topic = try repo.create(title: "主题A")
        XCTAssertEqual(repo.thoughtCount(of: topic), 0)
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        topic.addThoughts([t1, t2])
        try backfillLegacy(ctx)
        XCTAssertEqual(repo.thoughtCount(of: topic), 2)
    }

    // MARK: - 同步后去重

    func test_mergeDuplicateTopics合并同名() throws {
        let (repo, _) = try makeRepo()
        // create 不查重，直接建两个同名 candidate
        _ = try repo.create(title: "编程实践")
        _ = try repo.create(title: "编程实践")

        let mergedCount = try repo.mergeDuplicateTopics()

        XCTAssertEqual(mergedCount, 1)
        let visible = try repo.fetchVisibleTopics()
        XCTAssertEqual(visible.count, 1)
    }

    func test_mergeDuplicateTopics保留classification状态() throws {
        let (repo, _) = try makeRepo()
        let historical = try repo.create(title: "同名主题")
        try repo.activate(historical)
        let classification = try repo.create(title: "同名主题")
        try repo.setClassificationEnabled(classification, isEnabled: true)

        _ = try repo.mergeDuplicateTopics()

        XCTAssertEqual(try repo.fetchClassificationTopics().count, 1)
    }

    // MARK: - 来源词主源（P1.5.3）

    func test_setSourceTerms写入associatedTags主源并派生names() throws {
        let (repo, _) = try makeRepo()
        let topic = try repo.create(title: "编程")
        try repo.setSourceTerms(topic: topic, tagNames: ["coding", "vibecoding"])

        let tags = topic.associatedTags as? Set<ThoughtTag> ?? []
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(Set(tags.map { $0.name }), Set(["coding", "vibecoding"]))
        XCTAssertEqual(topic.associatedTagNames, "coding,vibecoding")
    }

    func test_setSourceTerms对不存在标签getOrCreate不崩溃() throws {
        let (repo, _) = try makeRepo()
        let topic = try repo.create(title: "编程")
        try repo.setSourceTerms(topic: topic, tagNames: ["全新标签"])
        XCTAssertEqual((topic.associatedTags as? Set<ThoughtTag>)?.count, 1)
    }

    // MARK: - applyConvergence（P2.4，归并不改 source）

    func test_applyConvergence新建主题关联观点写来源词() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)

        let topic = try repo.applyConvergence(
            matchedTopicId: nil,
            topicTitle: "编程实践",
            thoughtIds: [t1.id, t2.id],
            sourceTerms: ["coding", "vibecoding"]
        )

        XCTAssertEqual(topic.title, "编程实践")
        XCTAssertEqual(topic.statusEnum, .classification)
        XCTAssertEqual(repo.thoughtCount(of: topic), 2)
        XCTAssertEqual((topic.associatedTags as? Set<ThoughtTag>)?.count, 2)
    }

    func test_applyConvergence归入现有主题复用() throws {
        let (repo, ctx) = try makeRepo()
        let existing = try repo.create(title: "编程")
        try repo.activate(existing)
        let t1 = try makeThought(in: ctx)

        let topic = try repo.applyConvergence(
            matchedTopicId: existing.id,
            topicTitle: "编程",
            thoughtIds: [t1.id],
            sourceTerms: ["coding"]
        )

        XCTAssertEqual(topic.id, existing.id)
        XCTAssertEqual(repo.thoughtCount(of: topic), 1)
    }

    // MARK: - 同 id 多行副本的有效行解析（语义 V3 读源统一，2026-10-12）

    /// 直插一行 Topic（不走 repo.create，避免幂等查重吞掉同 id 副本场景）。
    @discardableResult
    private func insertTopicRow(_ ctx: NSManagedObjectContext, id: UUID, status: Topic.TopicStatus) throws -> Topic {
        let topic = ctx.insertTestObject(Topic.self)
        topic.id = id
        topic.title = "碎碎念"
        topic.status = status.rawValue
        topic.titleSource = "user"
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        topic.topicRevision = 1
        try ctx.save()
        return topic
    }

    /// 真机「碎碎念」实况：同 id 一行 classification、一行 merged 旧行，
    /// 且 merged 行物理行号更小（先落库）。旧实现 fetch 后取 .first 是抓阄，
    /// 抓到 merged 行候选即在 AI 调用前消失；解析入口必须稳定取到有效行。
    func test_resolveValid同id有效行与merged旧行_稳定解析到有效行() throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic"])
        let id = UUID()
        try insertTopicRow(ctx, id: id, status: .merged)          // 先插入：行号更小
        try insertTopicRow(ctx, id: id, status: .classification)  // 后插入：当前有效行

        let resolved = Topic.resolveValid(id: id, in: ctx)

        XCTAssertEqual(resolved?.statusEnum, .classification)
    }

    /// 顺序红线：必须先过滤可见再去重副本。反过来会把行号更小的 merged
    /// 副本钉成幸存行，再被可见过滤丢掉，等于整个主题被判不存在。
    func test_resolveValidRows先过滤可见再去重() throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic"])
        let shared = UUID(), other = UUID()
        try insertTopicRow(ctx, id: shared, status: .merged)
        try insertTopicRow(ctx, id: shared, status: .classification)
        try insertTopicRow(ctx, id: other, status: .active)

        let all = try ctx.fetch(Topic.fetchRequest())
        let resolved = Topic.resolveValidRows(all)

        XCTAssertEqual(Set(resolved.map(\.id)), Set([shared, other]))
        XCTAssertEqual(resolved.first(where: { $0.id == shared })?.statusEnum, .classification)
    }

    func test_resolveValid同id双可见副本收敛单行() throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic"])
        let id = UUID()
        try insertTopicRow(ctx, id: id, status: .classification)
        try insertTopicRow(ctx, id: id, status: .active)

        let all = try ctx.fetch(Topic.fetchRequest())
        let resolved = Topic.resolveValidRows(all)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, id)
    }

    func test_resolveValid无可见行返回nil() throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic"])
        let id = UUID()
        try insertTopicRow(ctx, id: id, status: .merged)

        XCTAssertNil(Topic.resolveValid(id: id, in: ctx))
    }
}
