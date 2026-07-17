//
//  TopicRepositoryDeleteTests.swift
//  HoloTests
//
//  主题删除测试：想法回未归类 / 标签关联断开 / 自引用清理 / 返回值
//  与标签管理同一类问题的主题侧补齐（长按菜单数据源）
//  使用内存 Core Data 隔离
//

import XCTest
import CoreData
@testable import Holo

final class TopicRepositoryDeleteTests: XCTestCase {

    // MARK: - In-Memory Core Data

    /// 构建内存 Repository + Context（共享同一 context）
    private func makeRepo() throws -> (TopicRepository, ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "TopicDeleteTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (TopicRepository(context: ctx), ThoughtRepository(context: ctx), ctx)
    }

    /// 创建测试想法
    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext) throws -> Thought {
        let thought = Thought(context: ctx)
        thought.id = UUID()
        thought.content = "测试内容"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        try ctx.save()
        return thought
    }

    /// 创建测试标签
    private func makeTag(in ctx: NSManagedObjectContext, name: String) throws -> ThoughtTag {
        let tag = ThoughtTag(context: ctx)
        tag.id = UUID()
        tag.name = name
        tag.usageCount = 1
        try ctx.save()
        return tag
    }

    /// 创建测试主题
    private func makeTopic(in ctx: NSManagedObjectContext, title: String) throws -> Topic {
        let topic = Topic(context: ctx)
        topic.id = UUID()
        topic.title = title
        topic.status = Topic.TopicStatus.active.rawValue
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        try ctx.save()
        return topic
    }

    // MARK: - 删除

    func test_删除主题_想法回未归类且主题实体消失() async throws {
        let (repo, thoughtRepo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        let topic = try makeTopic(in: ctx, title: "职场思考")
        topic.addThoughts(Set([t1, t2]))
        try ctx.save()

        _ = try repo.delete(topic)

        XCTAssertEqual(t1.topics?.count ?? 0, 0, "想法1 的主题关联应断开")
        XCTAssertEqual(t2.topics?.count ?? 0, 0, "想法2 的主题关联应断开")
        let unclassified = try thoughtRepo.fetchUnclassifiedThoughts()
        XCTAssertEqual(Set(unclassified.map(\.id)), Set([t1.id, t2.id]), "想法应回到未归类")
        XCTAssertTrue(try repo.fetchVisibleTopics().isEmpty, "主题列表应为空")
    }

    func test_删除主题_标签关联断开但标签实体保留() async throws {
        let (repo, _, ctx) = try makeRepo()
        let tag = try makeTag(in: ctx, name: "工作")
        let topic = try makeTopic(in: ctx, title: "职场思考")
        topic.addAssociatedTags(tag)
        topic.refreshAssociatedTagNamesCache()
        try ctx.save()

        _ = try repo.delete(topic)

        XCTAssertEqual(tag.associatedTopics?.count ?? 0, 0, "标签的主题关联应断开")
        let request = ThoughtTag.fetchRequest()
        let tags = try ctx.fetch(request)
        XCTAssertEqual(tags.count, 1, "标签实体应保留（主题删除不影响标签池）")
    }

    func test_删除主题_返回标题来源词和想法数() async throws {
        let (repo, _, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let tagA = try makeTag(in: ctx, name: "工作")
        let tagB = try makeTag(in: ctx, name: "成长")
        let topic = try makeTopic(in: ctx, title: "职场思考")
        topic.addThoughts(t1)
        topic.addAssociatedTags(Set([tagA, tagB]))
        try ctx.save()

        let result = try repo.delete(topic)

        XCTAssertEqual(result.title, "职场思考")
        XCTAssertEqual(result.sourceTerms, ["工作", "成长"], "来源词应按排序返回，供写归并拒绝记录")
        XCTAssertEqual(result.removedThoughtCount, 1)
    }

    func test_删除主题_被合并子主题的指向断开() async throws {
        let (repo, _, ctx) = try makeRepo()
        let keeper = try makeTopic(in: ctx, title: "主主题")
        let merged = try makeTopic(in: ctx, title: "已合并子主题")
        merged.status = Topic.TopicStatus.merged.rawValue
        merged.mergedToTopic = keeper
        try ctx.save()

        _ = try repo.delete(keeper)

        XCTAssertNil(merged.mergedToTopic, "子主题的 mergedToTopic 应断开，避免悬挂指向")
    }
}
