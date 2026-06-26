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
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "TopicRepoTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (TopicRepository(context: ctx), ctx)
    }

    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext) throws -> Thought {
        let t = Thought(context: ctx)
        t.id = UUID()
        t.content = "测试"
        t.createdAt = Date()
        t.updatedAt = Date()
        t.orderIndex = 0
        t.organizedStatus = "organized"
        try ctx.save()
        return t
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

    // MARK: - 合并

    func test_merge合并thoughts到keeper并标记merged() throws {
        let (repo, ctx) = try makeRepo()
        let keeper = try repo.create(title: "编程实践")
        try repo.activate(keeper)
        let dup = try repo.create(title: "编程实践 2")
        let thought = try makeThought(in: ctx)
        dup.addThoughts(thought)
        try ctx.save()

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
        try ctx.save()
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
}
