//
//  ThoughtRepositoryTagManagementTests.swift
//  HoloTests
//
//  观点标签全局管理测试（删除 / 重命名 / 合并 / 拒绝偏好联动）
//  方案：docs/thoughts/plans/2026-07-17-Holo观点标签管理方案.md
//  使用内存 Core Data 隔离
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtRepositoryTagManagementTests: XCTestCase {

    // MARK: - In-Memory Core Data

    /// 构建内存 Repository + Context（共享同一 context）
    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TagManagementTest", managedObjectModel: model)
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

    /// 创建测试想法
    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext) throws -> UUID {
        let thought = ctx.insertTestObject(Thought.self)
        let id = UUID()
        thought.id = id
        thought.content = "测试内容"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()
        return id
    }

    /// 按名称取标签实体（测试断言用）
    private func fetchTag(named name: String, in ctx: NSManagedObjectContext) throws -> ThoughtTag? {
        let request = ThoughtTag.fetchRequest()
        let tags = try ctx.fetch(request)
        let key = ThoughtTagNormalizer.key(name)
        return tags.first { ThoughtTagNormalizer.key($0.name) == key }
    }

    /// 取想法的 assignment 列表
    private func fetchAssignments(thoughtId: UUID, in ctx: NSManagedObjectContext) throws -> [ThoughtTagAssignment] {
        let request = ThoughtTagAssignment.fetchRequest()
        request.predicate = NSPredicate(format: "thought.id == %@", thoughtId as CVarArg)
        return try ctx.fetch(request)
    }

    /// 构造带关联标签的 Topic
    private func makeTopic(in ctx: NSManagedObjectContext, title: String, tags: [ThoughtTag]) throws -> Topic {
        let topic = ctx.insertTestObject(Topic.self)
        topic.id = UUID()
        topic.title = title
        topic.status = Topic.TopicStatus.active.rawValue
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        topic.addAssociatedTags(Set(tags))
        topic.associatedTagNames = tags.map(\.name).sorted().joined(separator: ",")
        try ctx.save()
        return topic
    }

    // MARK: - 全局删除

    func test_全局删除_移除全部assignment并删除tag实体() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "work", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "work", source: .ai, confidence: 0.8)

        _ = try repo.deleteTagGlobally(name: "work")

        XCTAssertNil(try fetchTag(named: "work", in: ctx), "tag 实体应被删除")
        XCTAssertTrue(try fetchAssignments(thoughtId: t1, in: ctx).isEmpty, "想法1 的 assignment 应清空")
        XCTAssertTrue(try fetchAssignments(thoughtId: t2, in: ctx).isEmpty, "想法2 的 assignment 应清空")
        XCTAssertTrue(try repo.fetchAITagBuckets().isEmpty, "标签池应不再含该标签")
    }

    func test_全局删除_返回移除条数() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "work", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "work", source: .manual, confidence: 1.0)

        let result = try repo.deleteTagGlobally(name: "work")

        XCTAssertEqual(result.removedAssignmentCount, 2)
    }

    func test_全局删除_重算受影响Topic缓存() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "work", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t1, tagName: "life", source: .ai, confidence: 0.9)
        let workTag = try XCTUnwrap(fetchTag(named: "work", in: ctx))
        let lifeTag = try XCTUnwrap(fetchTag(named: "life", in: ctx))
        let topic = try makeTopic(in: ctx, title: "日常", tags: [workTag, lifeTag])

        let result = try repo.deleteTagGlobally(name: "work")

        XCTAssertEqual(result.affectedTopicIds, [topic.id])
        XCTAssertEqual(topic.associatedTagNames, "life", "删除后 Topic 缓存应不再含被删标签")
        let topicTags = try XCTUnwrap(topic.associatedTags as? Set<ThoughtTag>)
        XCTAssertEqual(topicTags.map(\.name), ["life"], "Topic 关联标签关系应断开被删标签")
    }

    func test_全局删除_空白名抛tagNameEmpty() async throws {
        let (repo, _) = try makeRepo()
        XCTAssertThrowsError(try repo.deleteTagGlobally(name: "  ")) { error in
            XCTAssertEqual(error as? ThoughtError, .tagNameEmpty)
        }
    }

    func test_全局删除_标签不存在抛notFound() async throws {
        let (repo, _) = try makeRepo()
        XCTAssertThrowsError(try repo.deleteTagGlobally(name: "ghost")) { error in
            XCTAssertEqual(error as? ThoughtError, .notFound)
        }
    }

    // MARK: - 重命名（目标名不存在）

    func test_重命名到新名_改名且assignment保持() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)

        try repo.renameTag(from: "工作事业", to: "事业")

        let tag = try XCTUnwrap(fetchTag(named: "事业", in: ctx))
        XCTAssertEqual(tag.name, "事业")
        let assignments = try fetchAssignments(thoughtId: t1, in: ctx)
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments.first?.tag?.name, "事业")
        XCTAssertEqual(assignments.first?.source, ThoughtTagAssignment.Source.ai.rawValue, "来源应保持")
    }

    func test_重命名_仅显示差异_更新displayName且不新建tag() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "ai能力", source: .ai, confidence: 0.9)

        try repo.renameTag(from: "ai能力", to: "AI能力")

        XCTAssertEqual(try repo.getAllTags().count, 1, "归一化同 key 不应新建标签")
        XCTAssertEqual(try repo.getAllTags().first?.name, "AI能力")
    }

    func test_重命名_空白新名抛tagNameEmpty() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "work", source: .ai, confidence: 0.9)
        XCTAssertThrowsError(try repo.renameTag(from: "work", to: " # ")) { error in
            XCTAssertEqual(error as? ThoughtError, .tagNameEmpty)
        }
    }

    func test_重命名_源不存在抛notFound() async throws {
        let (repo, _) = try makeRepo()
        XCTAssertThrowsError(try repo.renameTag(from: "ghost", to: "newName")) { error in
            XCTAssertEqual(error as? ThoughtError, .notFound)
        }
    }

    // MARK: - 重命名（目标已存在 → 合并）

    func test_合并_assignments迁移并保留source() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "工作", source: .manual, confidence: 1.0)

        try repo.renameTag(from: "工作事业", to: "工作")

        XCTAssertNil(try fetchTag(named: "工作事业", in: ctx), "源标签实体应删除")
        let t1Assignments = try fetchAssignments(thoughtId: t1, in: ctx)
        XCTAssertEqual(t1Assignments.count, 1)
        XCTAssertEqual(t1Assignments.first?.tag?.name, "工作")
        XCTAssertEqual(t1Assignments.first?.source, ThoughtTagAssignment.Source.ai.rawValue, "迁移后 ai 来源应保留")
        let t2Assignments = try fetchAssignments(thoughtId: t2, in: ctx)
        XCTAssertEqual(t2Assignments.count, 1)
        XCTAssertEqual(t2Assignments.first?.source, ThoughtTagAssignment.Source.manual.rawValue)
    }

    func test_合并_同想法去重保留高优先级来源() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作", source: .manual, confidence: 1.0)

        try repo.renameTag(from: "工作事业", to: "工作")

        let assignments = try fetchAssignments(thoughtId: t1, in: ctx)
        XCTAssertEqual(assignments.count, 1, "同一想法同名标签只留一条")
        XCTAssertEqual(assignments.first?.source, ThoughtTagAssignment.Source.manual.rawValue, "manual 应胜过 ai")
    }

    func test_合并_usageCount重算为可见assignment去重想法数() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        let t3 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "工作事业", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "工作", source: .manual, confidence: 1.0)
        try repo.createTagAssignment(thoughtId: t3, tagName: "工作", source: .manual, confidence: 1.0)

        try repo.renameTag(from: "工作事业", to: "工作")

        let tag = try XCTUnwrap(fetchTag(named: "工作", in: ctx))
        XCTAssertEqual(tag.usageCount, 3, "去重想法数：t1(ai) + t2(manual) + t3(manual) = 3")
    }

    func test_合并_Topic关系迁移且缓存重算() async throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t1, tagName: "工作", source: .manual, confidence: 1.0)
        let sourceTag = try XCTUnwrap(fetchTag(named: "工作事业", in: ctx))
        let topic = try makeTopic(in: ctx, title: "职场", tags: [sourceTag])

        try repo.renameTag(from: "工作事业", to: "工作")

        let topicTags = try XCTUnwrap(topic.associatedTags as? Set<ThoughtTag>)
        XCTAssertEqual(topicTags.map(\.name), ["工作"], "Topic 应改关联目标标签")
        XCTAssertEqual(topic.associatedTagNames, "工作", "Topic 缓存应重算为目标名")
    }

    // MARK: - update 保留 AI assignments（修复「编辑保存后 AI 标签消失 / 幽灵标签」）

    func test_update_用inlineTags时保留AI_assignments() async throws {
        let (repo, ctx) = try makeRepo()
        let tid = try makeThought(in: ctx)
        // 预置：已有 AI 标签 + 用户行内标签
        try repo.createTagAssignment(thoughtId: tid, tagName: "AI建议", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: tid, tagName: "旧手敲", source: .inline, confidence: 1.0)

        // 编辑保存：正文里只有「新手敲」标签
        _ = try repo.update(tid, content: "新内容 #新手敲", inlineTags: ["新手敲"])

        let assignments = try fetchAssignments(thoughtId: tid, in: ctx)
        // AI 标签应保留
        XCTAssertTrue(assignments.contains { $0.source == "ai" && $0.tag?.name == "AI建议" },
                      "AI 标签应保留，不被编辑动作清空")
        // 旧 inline 应被清理（用户编辑了内容）
        XCTAssertFalse(assignments.contains { $0.source == "inline" && $0.tag?.name == "旧手敲" },
                       "旧的 inline 标签应被清理")
        // 新 inline 应写入
        XCTAssertTrue(assignments.contains { $0.source == "inline" && $0.tag?.name == "新手敲" },
                      "新 inline 标签应写入，source 为 inline")
    }

    func test_update_保留confirmedAI_assignments() async throws {
        let (repo, ctx) = try makeRepo()
        let tid = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: tid, tagName: "已确认", source: .confirmedAI, confidence: 0.95)

        _ = try repo.update(tid, content: "编辑 #别的", inlineTags: ["别的"])

        let assignments = try fetchAssignments(thoughtId: tid, in: ctx)
        XCTAssertTrue(assignments.contains { $0.source == "confirmedAI" && $0.tag?.name == "已确认" },
                      "用户确认过的 AI 标签应保留")
    }

    func test_update_tags参数兼容() async throws {
        // 旧调用方用 tags 参数（无 inlineTags），也应走 inline 重建逻辑并保留 AI
        let (repo, ctx) = try makeRepo()
        let tid = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: tid, tagName: "AI建议", source: .ai, confidence: 0.9)

        _ = try repo.update(tid, content: "新", tags: ["手动"])  // 用 tags（兼容路径）

        let assignments = try fetchAssignments(thoughtId: tid, in: ctx)
        XCTAssertTrue(assignments.contains { $0.source == "ai" },
                      "即使走旧 tags 参数，AI 标签也应保留")
        XCTAssertTrue(assignments.contains { $0.source == "inline" && $0.tag?.name == "手动" },
                      "tags 参数的标签应标 inline source（与正文 #标签 同等）")
    }

    func test_update_不传tags时不改动标签() async throws {
        let (repo, ctx) = try makeRepo()
        let tid = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: tid, tagName: "AI建议", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: tid, tagName: "手敲", source: .inline, confidence: 1.0)

        // 只更新内容，不传 tags/inlineTags → 标签不动
        _ = try repo.update(tid, content: "只改内容")

        let assignments = try fetchAssignments(thoughtId: tid, in: ctx)
        XCTAssertEqual(assignments.count, 2, "未传 tags 时不应改动任何 assignment")
    }
}

// MARK: - Service 层（拒绝偏好联动）

final class ThoughtTagManagementServiceTests: XCTestCase {

    /// 拒绝偏好 UserDefaults key（与 ThoughtOrganizationService.rejectedTagsKey 一致，private 无法直接引用）
    private static let rejectedTagsKey = "rejectedAITags"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.rejectedTagsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.rejectedTagsKey)
        super.tearDown()
    }

    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "TagManagementServiceTest", managedObjectModel: model)
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
    private func makeThought(in ctx: NSManagedObjectContext) throws -> UUID {
        let thought = ctx.insertTestObject(Thought.self)
        let id = UUID()
        thought.id = id
        thought.content = "测试内容"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()
        return id
    }

    /// 在 MainActor 上下文执行整个 Service 测试体：
    /// 内存 CoreData 对象的创建与释放都收敛在 MainActor job 内，测试 task 本身不持有它们，
    /// 避免 XCTest 测试 task 在错误 executor 析构时释放 CoreData 对象触发 TaskLocal double-free
    @MainActor
    private func runOnMainActor<T>(_ work: @MainActor () throws -> T) async rethrows -> T {
        try work()
    }

    func test_全局删除_拒绝偏好包含该名() async throws {
        try await runOnMainActor {
            let (repo, ctx) = try makeRepo()
            let t1 = try makeThought(in: ctx)
            try repo.createTagAssignment(thoughtId: t1, tagName: "碎片标签", source: .ai, confidence: 0.9)
            let service = ThoughtOrganizationService()

            let result = service.deleteTagEverywhere(name: "碎片标签", repository: repo)

            XCTAssertEqual(result?.removedAssignmentCount, 1)
            XCTAssertTrue(service.loadRejectedTagNames().contains("碎片标签"), "删除后应写入拒绝偏好防 AI 再生")
        }
    }

    func test_重命名_旧名进拒绝偏好() async throws {
        try await runOnMainActor {
            let (repo, ctx) = try makeRepo()
            let t1 = try makeThought(in: ctx)
            try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
            let service = ThoughtOrganizationService()

            try service.renameTagEverywhere(from: "工作事业", to: "工作", repository: repo)

            XCTAssertTrue(service.loadRejectedTagNames().contains("工作事业"), "旧名应进拒绝偏好防 AI 重打造成分裂")
        }
    }

    func test_重命名_新名从拒绝偏好移除() async throws {
        try await runOnMainActor {
            let (repo, ctx) = try makeRepo()
            let t1 = try makeThought(in: ctx)
            try repo.createTagAssignment(thoughtId: t1, tagName: "工作事业", source: .ai, confidence: 0.9)
            let service = ThoughtOrganizationService()
            service.addRejectedTag(name: "工作")  // 预置：用户曾拒绝过「工作」，现在改主意启用它

            try service.renameTagEverywhere(from: "工作事业", to: "工作", repository: repo)

            XCTAssertFalse(service.loadRejectedTagNames().contains("工作"), "新名应从拒绝偏好移除，避免与认可池信号矛盾")
            XCTAssertTrue(service.loadRejectedTagNames().contains("工作事业"))
        }
    }
}
