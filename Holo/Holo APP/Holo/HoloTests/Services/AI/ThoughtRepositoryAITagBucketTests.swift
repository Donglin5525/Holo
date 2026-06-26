//
//  ThoughtRepositoryAITagBucketTests.swift
//  HoloTests
//
//  AI 标签池聚合查询测试（P1.2）
//  覆盖 fetchAITagBuckets：聚合 .ai/.confirmedAI、排除 rejectedAI/rejectedAt、计数与 sourceBreakdown
//  使用内存 Core Data 隔离
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtRepositoryAITagBucketTests: XCTestCase {

    // MARK: - In-Memory Core Data

    /// 构建内存 Repository + Context（共享同一 context）
    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "AITagBucketTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (ThoughtRepository(context: ctx), ctx)
    }

    /// 创建测试想法
    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext) throws -> UUID {
        let thought = Thought(context: ctx)
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

    // MARK: - 聚合 .ai/.confirmedAI 按 tagName 分组

    func test_聚合ai标签按name分组与计数() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "coding", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t2, tagName: "coding", source: .ai, confidence: 0.8)
        try repo.createTagAssignment(thoughtId: t1, tagName: "vibecoding", source: .confirmedAI, confidence: 0.9)

        let buckets = try repo.fetchAITagBuckets()

        XCTAssertEqual(buckets.count, 2)
        let coding = try XCTUnwrap(buckets.first { $0.tagName == "coding" })
        XCTAssertEqual(coding.assignmentCount, 2)
        XCTAssertEqual(coding.sourceBreakdown[ThoughtTagAssignment.Source.ai.rawValue], 2)
        let vibecoding = try XCTUnwrap(buckets.first { $0.tagName == "vibecoding" })
        XCTAssertEqual(vibecoding.assignmentCount, 1)
        XCTAssertEqual(vibecoding.sourceBreakdown[ThoughtTagAssignment.Source.confirmedAI.rawValue], 1)
    }

    // MARK: - 排除 rejectedAI

    func test_排除rejectedAI来源() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "keep", source: .ai, confidence: 0.9)
        try repo.createTagAssignment(thoughtId: t1, tagName: "drop", source: .rejectedAI, confidence: 0.9)

        let buckets = try repo.fetchAITagBuckets()

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.tagName, "keep")
    }

    // MARK: - 排除 rejectedAt != nil

    func test_排除rejectedAt非nil的assignment() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "good", source: .ai, confidence: 0.9)
        // 构造异常态：source 仍是 ai 但 rejectedAt 已设
        let t2 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t2, tagName: "weird", source: .ai, confidence: 0.9)
        let request = ThoughtTagAssignment.fetchRequest()
        request.predicate = NSPredicate(format: "tag.name == %@", "weird")
        let weird = try XCTUnwrap(try ctx.fetch(request).first as? ThoughtTagAssignment)
        weird.rejectedAt = Date()
        try ctx.save()

        let buckets = try repo.fetchAITagBuckets()

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.tagName, "good")
    }

    // MARK: - 空数据

    func test_空数据返回空数组() throws {
        let (repo, _) = try makeRepo()
        let buckets = try repo.fetchAITagBuckets()
        XCTAssertTrue(buckets.isEmpty)
    }

    // MARK: - 手动标签不计入 AI 标签池

    func test_手动标签不计入AI标签池() throws {
        let (repo, ctx) = try makeRepo()
        let t1 = try makeThought(in: ctx)
        try repo.createTagAssignment(thoughtId: t1, tagName: "manualTag", source: .manual, confidence: 1.0)
        try repo.createTagAssignment(thoughtId: t1, tagName: "inlineTag", source: .inline, confidence: 1.0)
        try repo.createTagAssignment(thoughtId: t1, tagName: "aiTag", source: .ai, confidence: 0.9)

        let buckets = try repo.fetchAITagBuckets()

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.tagName, "aiTag")
    }
}
