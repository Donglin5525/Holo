//
//  ThoughtAttachmentProjectionTests.swift
//  HoloTests
//
//  附件缩略图投影查询（fetchAttachmentThumbnails）单测：
//  只取缩略图列不 fire 原图、窗口口径与 fetchThoughts 一致、排序与副本去重。
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtAttachmentProjectionTests: XCTestCase {

    private var ctx: NSManagedObjectContext!
    private var repo: ThoughtRepository!

    override func setUpWithError() throws {
        ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        repo = ThoughtRepository(context: ctx)
        try CoreDataTestSupport.clearEntities(ctx, ["Thought", "ThoughtAttachment"])
    }

    private func makeDate(_ day: Int, hour: Int = 9) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 7
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    @discardableResult
    private func makeThought(day: Int, hour: Int = 9,
                              softDeleted: Bool = false,
                              archived: Bool = false,
                              photos: Int) throws -> Thought {
        let t = ctx.insertTestObject(Thought.self)
        t.id = UUID()
        t.content = "带 \(photos) 图的想法"
        t.createdAt = makeDate(day, hour: hour)
        t.updatedAt = t.createdAt
        t.orderIndex = 0
        t.organizedStatus = "organized"
        t.deletedAt = softDeleted ? t.createdAt : nil
        t.isArchived = archived
        for order in 0..<photos {
            ThoughtAttachment.create(
                in: ctx,
                fileName: "\(UUID().uuidString).jpeg",
                thumbnailFileName: "\(UUID().uuidString)_thumb.jpeg",
                thought: t,
                order: Int16(order),
                imageData: Data([UInt8(order)]),          // 原图列：投影查询绝不应触碰
                thumbnailData: Data([0xF0 + UInt8(order)]) // 缩略图列：按序可辨识
            )
        }
        try ctx.save()
        return t
    }

    private func range(_ day: Int) -> (Date, Date) {
        (makeDate(day, hour: 0), makeDate(day + 1, hour: 0))
    }

    func test_五图想法投影返回五张缩略图_按sortOrder排序() throws {
        let thought = try makeThought(day: 1, photos: 5)
        let (start, end) = range(1)
        let projections = try repo.fetchAttachmentThumbnails(from: start, to: end)

        XCTAssertEqual(projections[thought.id]?.count, 5)
        let values = try XCTUnwrap(projections[thought.id])
        XCTAssertEqual(values.map { $0.first ?? 0 }, [0xF0, 0xF1, 0xF2, 0xF3, 0xF4],
                       "缩略图应按 sortOrder 升序，且只含缩略图列")
    }

    func test_窗口外与无图想法不产生投影() throws {
        let inWindow = try makeThought(day: 1, photos: 2)
        try makeThought(day: 5, photos: 3)   // 窗口外
        try makeThought(day: 1, photos: 0)   // 无附件
        let (start, end) = range(1)

        let projections = try repo.fetchAttachmentThumbnails(from: start, to: end)
        XCTAssertEqual(projections.count, 1, "只有窗口内带图想法产生投影")
        XCTAssertEqual(projections[inWindow.id]?.count, 2)
    }

    func test_软删与归档想法的附件被过滤() throws {
        try makeThought(day: 1, softDeleted: true, photos: 2)
        try makeThought(day: 1, archived: true, photos: 1)
        try makeThought(day: 1, photos: 1)
        let (start, end) = range(1)

        let projections = try repo.fetchAttachmentThumbnails(from: start, to: end)
        XCTAssertEqual(projections.values.map(\.count).reduce(0, +), 1,
                       "deletedAt 非空与 isArchived 的想法附件不应进入投影")
    }

    func test_同id副本行的附件按sortOrder去重() throws {
        let original = try makeThought(day: 1, photos: 3)
        // iCloud 同步副本：同 id 新行，附件内容一致（sortOrder 相同）
        let copy = ctx.insertTestObject(Thought.self)
        copy.id = original.id
        copy.content = original.content
        copy.createdAt = original.createdAt
        copy.updatedAt = original.updatedAt
        copy.orderIndex = 0
        copy.organizedStatus = "organized"
        for order in 0..<3 {
            ThoughtAttachment.create(
                in: ctx,
                fileName: "\(UUID().uuidString).jpeg",
                thumbnailFileName: "\(UUID().uuidString)_thumb.jpeg",
                thought: copy,
                order: Int16(order),
                imageData: Data([UInt8(order)]),
                thumbnailData: Data([0xF0 + UInt8(order)])
            )
        }
        try ctx.save()

        let (start, end) = range(1)
        let projections = try repo.fetchAttachmentThumbnails(from: start, to: end)
        XCTAssertEqual(projections[original.id]?.count, 3,
                       "副本行附件与正主同 (id, sortOrder)，应去重为一份")
    }
}
