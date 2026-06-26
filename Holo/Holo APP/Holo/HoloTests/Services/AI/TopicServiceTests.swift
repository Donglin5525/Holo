//
//  TopicServiceTests.swift
//  HoloTests
//
//  Topic Service 测试（P1.5.1）
//  覆盖 主主题展示层取（thoughts.count 最高）+ 收纳判断三者交集
//

import XCTest
import CoreData
@testable import Holo

final class TopicServiceTests: XCTestCase {

    private let service = TopicService()

    private func makeContext() throws -> NSManagedObjectContext {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "TopicServiceTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        return container.viewContext
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

    @discardableResult
    private func makeTopic(
        in ctx: NSManagedObjectContext,
        title: String,
        status: Topic.TopicStatus = .active
    ) throws -> Topic {
        let topic = Topic(context: ctx)
        topic.id = UUID()
        topic.title = title
        topic.status = status.rawValue
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        try ctx.save()
        return topic
    }

    /// 创建 assignment（每次新建独立 ThoughtTag 实例，即使同名）
    @discardableResult
    private func makeAssignment(
        in ctx: NSManagedObjectContext,
        thought: Thought,
        tagName: String,
        source: ThoughtTagAssignment.Source
    ) throws -> ThoughtTagAssignment {
        let tag = ThoughtTag(context: ctx)
        tag.id = UUID()
        tag.name = tagName
        tag.usageCount = 0
        let assignment = ThoughtTagAssignment(context: ctx)
        assignment.id = UUID()
        assignment.source = source.rawValue
        assignment.confidence = 0.9
        assignment.assignedAt = Date()
        assignment.thought = thought
        assignment.tag = tag
        try ctx.save()
        return assignment
    }

    /// 安全取 assignment 的 tag（避免 force unwrap）
    private func tagOf(_ assignment: ThoughtTagAssignment) throws -> ThoughtTag {
        try XCTUnwrap(assignment.tag)
    }

    // MARK: - 主主题展示层取

    func test_主主题取thoughtsCount最高的active() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        let topicA = try makeTopic(in: ctx, title: "A", status: .active)
        let topicB = try makeTopic(in: ctx, title: "B", status: .active)
        let t2 = try makeThought(in: ctx)
        topicA.addThoughts([thought, t2])
        topicB.addThoughts(try makeThought(in: ctx))
        thought.addTopics([topicA, topicB])
        try ctx.save()

        let primary = service.primaryDisplayTopic(for: thought)

        XCTAssertEqual(primary?.title, "A")
    }

    func test_无主题返回nil() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        XCTAssertNil(service.primaryDisplayTopic(for: thought))
    }

    // MARK: - isAbsorbed 三者交集

    func test_isAbsorbed三者交集命中() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        let topic = try makeTopic(in: ctx, title: "编程", status: .active)
        let assignment = try makeAssignment(in: ctx, thought: thought, tagName: "coding", source: .ai)
        topic.addThoughts(thought)
        topic.addAssociatedTags(try tagOf(assignment))
        try ctx.save()

        XCTAssertTrue(service.isAbsorbed(assignment))
    }

    func test_isAbsorbed观点未进Topic不命中() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        let assignment = try makeAssignment(in: ctx, thought: thought, tagName: "coding", source: .ai)

        XCTAssertFalse(service.isAbsorbed(assignment))
    }

    func test_isAbsorbed同名标签观点未进Topic不误判() throws {
        let ctx = try makeContext()
        let thought1 = try makeThought(in: ctx)
        let thought2 = try makeThought(in: ctx)
        let topic = try makeTopic(in: ctx, title: "编程", status: .active)
        // 仅 thought1 进 topic
        topic.addThoughts(thought1)
        let assignment1 = try makeAssignment(in: ctx, thought: thought1, tagName: "coding", source: .ai)
        let assignment2 = try makeAssignment(in: ctx, thought: thought2, tagName: "coding", source: .ai)
        // 仅 assignment1 的 tag 进 topic.associatedTags
        topic.addAssociatedTags(try tagOf(assignment1))
        try ctx.save()

        XCTAssertTrue(service.isAbsorbed(assignment1))
        XCTAssertFalse(service.isAbsorbed(assignment2))
    }

    func test_isAbsorbed手动source不命中() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        let topic = try makeTopic(in: ctx, title: "编程", status: .active)
        let assignment = try makeAssignment(in: ctx, thought: thought, tagName: "coding", source: .manual)
        topic.addThoughts(thought)
        topic.addAssociatedTags(try tagOf(assignment))
        try ctx.save()

        XCTAssertFalse(service.isAbsorbed(assignment))
    }

    func test_isAbsorbedrejectedAt非nil不命中() throws {
        let ctx = try makeContext()
        let thought = try makeThought(in: ctx)
        let topic = try makeTopic(in: ctx, title: "编程", status: .active)
        let assignment = try makeAssignment(in: ctx, thought: thought, tagName: "coding", source: .ai)
        assignment.rejectedAt = Date()
        topic.addThoughts(thought)
        topic.addAssociatedTags(try tagOf(assignment))
        try ctx.save()

        XCTAssertFalse(service.isAbsorbed(assignment))
    }
}
