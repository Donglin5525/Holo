//
//  ThoughtTopicConsistencyTests.swift
//  HoloTests
//
//  P0 完成门测试（2026-09-27 想法标签与主题归类整改 §2.6）：
//  1) link-only 关系（V3 AI 归入不写旧关系）四处一致：卡片投影 / 侧栏计数 /
//     详情列表 / 范围搜索；
//  2) 拒绝墓碑压制后四处同灭（同版本不复活）；
//  3) 软删 / 归档不计入活跃主题；
//  4) 主题改名 / 删除不再连带改写用户标签（P0-D 解耦）；
//  5) relate 任务去重入队与 kind 隔离领取（P0-C 队列层）。
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtTopicConsistencyTests: XCTestCase {

    private func makeRepo() throws -> (TopicRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TopicConsistencyTest", managedObjectModel: model)
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
    private func makeThought(_ content: String, in ctx: NSManagedObjectContext) throws -> Thought {
        let t = ctx.insertTestObject(Thought.self)
        t.id = UUID()
        t.content = content
        t.createdAt = Date()
        t.updatedAt = Date()
        t.orderIndex = 0
        t.organizedStatus = "organized"
        try ctx.save()
        return t
    }

    /// 只写 link（模拟 V3 AI 归入路径——verifier 不写旧 Thought.topics）
    private func writeAILink(thought: Thought, topic: Topic, hash: String) throws {
        _ = ThoughtTopicLinkProjection.recordAIV3Decision(
            thought: thought, topic: topic,
            basisTextHash: hash,
            decisionTier: "high",
            engineVersion: "thought_semantic_v3.0",
            consentGeneration: ThoughtSemanticFeatureFlags.consentGeneration,
            evidenceRange: nil)
        try thought.managedObjectContext?.save()
    }

    // MARK: - 1) link-only 四处一致

    func test_linkOnlyRelation_consistentAcrossCardSidebarDetailSearch() throws {
        let (repo, ctx) = try makeRepo()
        let thought = try makeThought("想带妈妈去日本，她一直想看樱花", in: ctx)
        let topic = try repo.create(title: "日本旅行")
        topic.status = Topic.TopicStatus.active.rawValue
        try ctx.save()

        // 旧关系为空（差异场景实锤：V3 只写 link）
        XCTAssertTrue(((thought.topics as? Set<Topic>) ?? []).isEmpty, "前置：旧关系应为空")

        try writeAILink(thought: thought, topic: topic, hash: "h1")

        // ① 卡片口径（投影）
        let cardTopics = ThoughtTopicLinkProjection.effectiveTopics(for: thought)
        XCTAssertTrue(cardTopics.contains { $0.id == topic.id }, "卡片徽章应显示主题")
        // ② 侧栏计数
        XCTAssertEqual(repo.thoughtCount(of: topic), 1, "侧栏计数应含 link-only 成员")
        // ③ 详情列表
        let list = try repo.fetchThoughts(byTopic: topic.id)
        XCTAssertEqual(list.map(\.id), [thought.id], "详情列表应含 link-only 成员")
        // ④ 范围搜索
        let search = try repo.searchWithinTopic(topicId: topic.id, query: "樱花")
        XCTAssertEqual(search.map(\.id), [thought.id], "范围搜索应命中 link-only 成员")
    }

    // MARK: - 2) 拒绝墓碑后四处同灭、同版本不复活

    func test_manualRemove_suppressesEverywhere_aiDoesNotRevive() throws {
        let (repo, ctx) = try makeRepo()
        let thought = try makeThought("查了一下东京住宿，新宿性价比高", in: ctx)
        let topic = try repo.create(title: "日本旅行")
        topic.status = Topic.TopicStatus.active.rawValue
        try ctx.save()

        try writeAILink(thought: thought, topic: topic, hash: "h1")
        try repo.remove(thoughtId: thought.id, fromTopic: topic.id)

        XCTAssertTrue(ThoughtTopicLinkProjection.effectiveTopics(for: thought).isEmpty, "卡片应无主题")
        XCTAssertEqual(repo.thoughtCount(of: topic), 0, "计数应归零")
        XCTAssertTrue(try repo.fetchThoughts(byTopic: topic.id).isEmpty, "详情应无成员")

        // AI 同版本迟到决策：投影墓碑压制，四处均不复活
        try writeAILink(thought: thought, topic: topic, hash: "h1")
        XCTAssertTrue(ThoughtTopicLinkProjection.effectiveTopics(for: thought).isEmpty,
                      "拒绝后同版本 AI 决策不得复活")
        XCTAssertEqual(repo.thoughtCount(of: topic), 0)
        XCTAssertTrue(try repo.fetchThoughts(byTopic: topic.id).isEmpty)
    }

    // MARK: - 3) 软删 / 归档不计入活跃主题

    func test_archivedAndSoftDeleted_thoughtsExcludedFromCounts() throws {
        let (repo, ctx) = try makeRepo()
        let alive = try makeThought("假期可能只有五天", in: ctx)
        let archived = try makeThought("订了机票", in: ctx)
        let softDeleted = try makeThought("作废的想法", in: ctx)
        let topic = try repo.create(title: "日本旅行")
        topic.status = Topic.TopicStatus.active.rawValue
        try ctx.save()

        try repo.assign(thoughtId: alive.id, toTopic: topic.id)
        try repo.assign(thoughtId: archived.id, toTopic: topic.id)
        try repo.assign(thoughtId: softDeleted.id, toTopic: topic.id)
        XCTAssertEqual(repo.thoughtCount(of: topic), 3, "前置：三个成员")

        archived.isArchived = true
        softDeleted.deletedAt = Date()
        try ctx.save()

        XCTAssertEqual(repo.thoughtCount(of: topic), 1, "归档/软删不计入计数")
        let list = try repo.fetchThoughts(byTopic: topic.id)
        XCTAssertEqual(list.map(\.id), [alive.id], "详情列表只含活跃成员")
    }

    // MARK: - 4) 主题操作不碰用户标签（P0-D）

    func test_renameAndDeleteTopic_doNotTouchUserTagPaths() throws {
        let (repo, ctx) = try makeRepo()
        let thought = try makeThought("签证材料清单，先存着", in: ctx)
        let topic = try repo.create(title: "日本旅行")
        topic.status = Topic.TopicStatus.classification.rawValue
        try ctx.save()
        try repo.assign(thoughtId: thought.id, toTopic: topic.id)

        // 用户标签实体（历史「主题/子标签」路径形态）——断言实体文字不被主题操作改写。
        // 直接插实体（不经 getOrCreateTag），把用例收敛到「主题操作 vs 标签实体」本身
        let tag = ctx.insertTestObject(ThoughtTag.self)
        tag.id = UUID()
        tag.name = "日本旅行/签证"
        tag.usageCount = 1
        try ctx.save()

        try repo.renameClassificationTopic(topic, to: "东瀛行")
        XCTAssertEqual(topic.title, "东瀛行")
        XCTAssertEqual(tag.name, "日本旅行/签证", "改名不得改写用户标签实体")

        // 删除主题同样不改写标签
        _ = try repo.deleteClassificationTopic(topic)
        try ctx.save()
        XCTAssertEqual(tag.name, "日本旅行/签证", "删除主题不得改写用户标签实体")
    }

    // MARK: - 5) relate 队列：kind 隔离领取 + 去重（P0-C 数据层）

    func test_relateJobQueue_kindIsolationAndDedup() async throws {
        // 内存语义库（临时目录 SQLite；与生产同 schema/migration 路径）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relate-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = await ThoughtSemanticStore(root: dir)
        try await store.open()

        let thoughtID = UUID()
        let hash = "h1"

        // 首次入队成功；pending 期间重复入队被去重
        func enqueueRelate() async throws {
            guard try await !store.hasPendingJob(thoughtID: thoughtID, contentHash: hash, kind: "relate"),
                  try await !store.hasRelationRecord(thoughtID: thoughtID, contentHash: hash) else { return }
            try await store.enqueueJob(.init(
                id: UUID(), thoughtID: thoughtID, contentHash: hash, kind: "relate",
                priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil,
                consentGeneration: 1, lastErrorCode: nil))
        }
        try await enqueueRelate()
        try await enqueueRelate()
        // embed 任务同 hash 并存（不同 kind 互不挤占）
        try await store.enqueueJob(.init(
            id: UUID(), thoughtID: thoughtID, contentHash: hash, kind: "embed",
            priority: 5, state: "pending", attemptCount: 0, nextAttemptAt: nil,
            consentGeneration: 1, lastErrorCode: nil))

        let relateJob = try await store.claimNextDueJob(consentGeneration: 1, kind: "relate")
        XCTAssertEqual(relateJob?.kind, "relate", "kind=relate 只领取 relate 任务")
        let embedJob = try await store.claimNextDueJob(consentGeneration: 1, kind: "embed")
        XCTAssertEqual(embedJob?.kind, "embed", "kind=embed 只领取 embed 任务")

        // relate 跑完留下 relation_candidate 记录后，同 (thought, hash) 不再重复入队
        try await store.recordRelationCandidate(
            thoughtID: thoughtID, topicID: UUID(), contentHash: hash,
            scoreFeatures: "{}", verifierResult: "no_recall:none", state: "expired",
            engineVersion: "thought_semantic_v3.0", expiryDays: 14,
            verifierQuote: "证据片段")
        try await enqueueRelate()
        let claimedAgain = try await store.claimNextDueJob(consentGeneration: 1, kind: "relate")
        XCTAssertNil(claimedAgain, "已跑过的 (thought, hash) 不重复入队（补跑去重）")

        // 证据片段随记录可读回（P0-B quote 落库，供 P1 回源）
        let hasRecord = try await store.hasRelationRecord(thoughtID: thoughtID, contentHash: hash)
        XCTAssertTrue(hasRecord)
    }
}
