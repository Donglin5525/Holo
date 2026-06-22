//
//  ThoughtOrganizationBatchTests.swift
//  HoloTests
//
//  想法批量自动整理测试
//  覆盖 ThoughtRepository 的未整理查询/计数/批量标记 + organizedStatus 终态过滤
//  使用内存 Core Data 隔离，不影响真实数据
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtOrganizationBatchTests: XCTestCase {

    // MARK: - In-Memory Core Data

    /// 构建内存 Context，复用项目 model 定义，隔离测试数据
    private func makeInMemoryContext() throws -> NSManagedObjectContext {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "ThoughtBatchTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var storeError: Error?
        container.loadPersistentStores { _, error in
            storeError = error
        }
        if let storeError { throw storeError }

        return container.viewContext
    }

    /// 创建测试想法（organizedStatus 可设 nil，模拟早于 backfill 的脏数据）
    @discardableResult
    private func makeThought(
        in context: NSManagedObjectContext,
        organizedStatus: String?,
        createdAt: Date = Date(),
        isArchived: Bool = false,
        isSoftDeleted: Bool = false
    ) throws -> UUID {
        let thought = Thought(context: context)
        let id = UUID()
        thought.id = id
        thought.content = "测试内容，长度足够触发整理"
        thought.createdAt = createdAt
        thought.updatedAt = createdAt
        thought.orderIndex = 0
        thought.organizedStatus = organizedStatus
        thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId
        thought.isSoftDeleted = isSoftDeleted
        thought.isArchived = isArchived
        try context.save()
        return id
    }

    // MARK: - fetchUnprocessedThoughtIds：纳入范围

    func testFetchUnprocessed_includesUnprocessedAndNil() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        let unprocessedId = try makeThought(in: context, organizedStatus: "unprocessed")
        let nilId = try makeThought(in: context, organizedStatus: nil)

        let ids = try repo.fetchUnprocessedThoughtIds()

        XCTAssertTrue(ids.contains(unprocessedId), "unprocessed 应纳入批量整理")
        XCTAssertTrue(ids.contains(nilId), "nil（早于 backfill 的脏数据）应纳入")
    }

    // MARK: - fetchUnprocessedThoughtIds：排除终态

    func testFetchUnprocessed_excludesTerminalStatuses() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        let organizedId = try makeThought(in: context, organizedStatus: "organized")
        let pendingId = try makeThought(in: context, organizedStatus: "pending")
        let processingId = try makeThought(in: context, organizedStatus: "processing")
        let skippedId = try makeThought(in: context, organizedStatus: "skipped")
        let disabledId = try makeThought(in: context, organizedStatus: "disabled")
        let failedId = try makeThought(in: context, organizedStatus: "failed")

        let ids = try repo.fetchUnprocessedThoughtIds()

        XCTAssertFalse(ids.contains(organizedId), "organized 是终态，应排除（避免覆盖已确认标签）")
        XCTAssertFalse(ids.contains(pendingId), "pending 已在队列，应排除")
        XCTAssertFalse(ids.contains(processingId), "processing 整理中，应排除")
        XCTAssertFalse(ids.contains(skippedId), "skipped 内容太短，应排除")
        XCTAssertFalse(ids.contains(disabledId), "disabled 用户关闭，应排除")
        XCTAssertFalse(ids.contains(failedId), "failed 避免重试循环，应排除")
    }

    // MARK: - fetchUnprocessedThoughtIds：排除归档/删除

    func testFetchUnprocessed_excludesArchivedAndDeleted() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        let archivedId = try makeThought(in: context, organizedStatus: "unprocessed", isArchived: true)
        let deletedId = try makeThought(in: context, organizedStatus: "unprocessed", isSoftDeleted: true)
        let normalId = try makeThought(in: context, organizedStatus: "unprocessed")

        let ids = try repo.fetchUnprocessedThoughtIds()

        XCTAssertFalse(ids.contains(archivedId), "归档想法应排除")
        XCTAssertFalse(ids.contains(deletedId), "软删除想法应排除")
        XCTAssertTrue(ids.contains(normalId), "正常未整理想法应纳入")
    }

    /// 回归测试：老想法 createdDeviceId 为 nil（字段引入前创建 / backfill 未补）时，
    /// 不应被 deviceId 过滤掉——这是「自动整理」能捞到老想法的关键
    func testFetchUnprocessed_includesThoughtsWithNilDeviceId() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        let thought = Thought(context: context)
        thought.id = UUID()
        thought.content = "老想法，createdDeviceId 为 nil"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "unprocessed"
        thought.createdDeviceId = nil
        thought.isSoftDeleted = false
        thought.isArchived = false
        try context.save()

        let ids = try repo.fetchUnprocessedThoughtIds()
        XCTAssertTrue(ids.contains(thought.id), "createdDeviceId 为 nil 的老想法应纳入批量整理")

        let count = try repo.countUnprocessed()
        XCTAssertEqual(count, 1, "nil deviceId 的老想法应被计数")
    }

    // MARK: - countUnprocessed

    func testCountUnprocessed_matchesFetchCount() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        _ = try makeThought(in: context, organizedStatus: "unprocessed")
        _ = try makeThought(in: context, organizedStatus: nil)
        _ = try makeThought(in: context, organizedStatus: "organized")
        _ = try makeThought(in: context, organizedStatus: "failed")

        let count = try repo.countUnprocessed()
        let fetchCount = try repo.fetchUnprocessedThoughtIds().count

        XCTAssertEqual(count, 2, "只有 unprocessed + nil 算未整理")
        XCTAssertEqual(count, fetchCount, "count 与 fetch 结果应一致")
    }

    // MARK: - markBatchPending：状态流转

    func testMarkBatchPending_setsStatusToPending() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        let id1 = try makeThought(in: context, organizedStatus: "unprocessed")
        let id2 = try makeThought(in: context, organizedStatus: nil)

        try repo.markBatchPending(thoughtIds: [id1, id2])

        // 标记后 fetchUnprocessed 应排除（pending 是终态）
        let unprocessed = try repo.fetchUnprocessedThoughtIds()
        XCTAssertFalse(unprocessed.contains(id1), "标记 pending 后不再算未整理")
        XCTAssertFalse(unprocessed.contains(id2), "标记 pending 后不再算未整理")

        // 验证状态流转到 pending
        let pending = try repo.fetchPendingThoughtIds()
        XCTAssertTrue(pending.contains(id1), "状态应流转为 pending")
        XCTAssertTrue(pending.contains(id2), "状态应流转为 pending")
    }

    func testMarkBatchPending_emptyListDoesNotThrow() throws {
        let context = try makeInMemoryContext()
        let repo = ThoughtRepository(context: context)

        XCTAssertNoThrow(try repo.markBatchPending(thoughtIds: []), "空列表应安全跳过")
    }
}
