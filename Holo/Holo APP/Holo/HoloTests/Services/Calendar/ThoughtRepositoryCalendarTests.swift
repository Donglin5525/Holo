//
//  ThoughtRepositoryCalendarTests.swift
//  HoloTests
//
//  日历聚合用 ThoughtRepository.fetchThoughts(from:to:) 单测
//  （半开区间、deletedAt/isArchived 过滤、边界）
//

import XCTest
import CoreData
import UIKit
@testable import Holo

final class ThoughtRepositoryCalendarTests: XCTestCase {

    private func makeRepo() throws -> (ThoughtRepository, NSManagedObjectContext) {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "ThoughtRepoCalendarTest", managedObjectModel: model)
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

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return Calendar.current.date(from: c) ?? Date()
    }

    @discardableResult
    private func makeThought(in ctx: NSManagedObjectContext,
                             content: String,
                             createdAt: Date,
                             softDeleted: Bool = false,
                             archived: Bool = false) throws -> Thought {
        let t = ctx.insertTestObject(Thought.self)
        t.id = UUID()
        t.content = content
        t.createdAt = createdAt
        t.updatedAt = createdAt
        t.orderIndex = 0
        t.organizedStatus = "organized"
        t.deletedAt = softDeleted ? createdAt : nil
        t.isArchived = archived
        try ctx.save()
        return t
    }

    func test_区间内想法返回() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "A", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeThought(in: ctx, content: "B", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 20))

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 2)
    }

    func test_半开区间_次日零点不计入() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "A", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 23))
        try makeThought(in: ctx, content: "B", createdAt: makeDate(year: 2026, month: 7, day: 2, hour: 0))

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 1, "半开区间：7/2 00:00 不应计入")
    }

    func test_软删想法被过滤() throws {
        let (repo, ctx) = try makeRepo()
        try makeThought(in: ctx, content: "正常", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 9))
        try makeThought(in: ctx, content: "已删", createdAt: makeDate(year: 2026, month: 7, day: 1, hour: 10), softDeleted: true)

        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(thoughts.count, 1, "deletedAt 非空的想法应被过滤")
        XCTAssertEqual(thoughts.first?.content, "正常")
    }

    func test_空区间返回空() throws {
        let (repo, _) = try makeRepo()
        let thoughts = try repo.fetchThoughts(
            from: makeDate(year: 2026, month: 7, day: 1),
            to: makeDate(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(thoughts.isEmpty)
    }

    // MARK: - 手动验证造数（记忆长廊·册页风）

    /// 往 app 真实沙盒库（CoreDataStack.shared）写入两条带图想法（3 图 + 1 图），
    /// 供模拟器上人工验收记忆长廊册页风卡片。仅手动触发，UserDefaults 防重复。
    /// 图片为代码生成的渐变照片（带序号），不依赖相册。
    func test_seedPolaroidFixtures_ManualVerification() throws {
        let seedFlag = "holo.test.polaroidFixturesSeeded"
        guard !UserDefaults.standard.bool(forKey: seedFlag) else {
            print("[seed] 册页风造数已存在，跳过")
            return
        }

        let ctx = CoreDataStack.shared.viewContext
        let now = Date()

        func makePhotoData(index: Int, size: CGSize, label: String) -> Data {
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { renderCtx in
                let rect = CGRect(origin: .zero, size: size)
                let colors = [
                    UIColor(hue: CGFloat((index * 47 % 360)) / 360.0, saturation: 0.42, brightness: 0.86, alpha: 1),
                    UIColor(hue: CGFloat((index * 47 + 60) % 360) / 360.0, saturation: 0.38, brightness: 0.62, alpha: 1)
                ]
                let cg = renderCtx.cgContext
                let space = CGColorSpaceCreateDeviceRGB()
                guard let grad = CGGradient(
                    colorsSpace: space,
                    colors: colors.map(\.cgColor) as CFArray,
                    locations: [0, 1]
                ) else { return }
                cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: min(size.width, size.height) * 0.28, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.92)
                ]
                (label as NSString).draw(at: CGPoint(x: 14, y: 14), withAttributes: attrs)
            }
            return image.jpegData(compressionQuality: 0.7) ?? Data()
        }

        func seed(content: String, minutesAgo: Int, labels: [String]) throws -> Thought {
            let thought = Thought(context: ctx)
            thought.id = UUID()
            thought.content = content
            thought.createdAt = now.addingTimeInterval(TimeInterval(-minutesAgo * 60))
            thought.updatedAt = thought.createdAt
            thought.orderIndex = 0
            thought.isSoftDeleted = false
            thought.createdDeviceId = HoloBackendDeviceIdentity.shared.deviceId
            for (order, label) in labels.enumerated() {
                ThoughtAttachment.create(
                    in: ctx,
                    fileName: "\(UUID().uuidString).jpeg",
                    thumbnailFileName: "\(UUID().uuidString)_thumb.jpeg",
                    thought: thought,
                    order: Int16(order),
                    imageData: makePhotoData(index: order, size: CGSize(width: 1200, height: 900), label: label),
                    thumbnailData: makePhotoData(index: order, size: CGSize(width: 300, height: 300), label: label)
                )
            }
            return thought
        }

        let three = try seed(
            content: "周末的城市行走，在江边看到了很美的落日，风把云吹开了一道缝。沿江步道走了大概五公里，在长椅上坐了很久，把最近想不通的几件事慢慢想明白了。",
            minutesAgo: 95,
            labels: ["1", "2", "3"]
        )
        let single = try seed(
            content: "晨间咖啡馆的读书时间，翻开新书第三章做点笔记。",
            minutesAgo: 40,
            labels: ["A"]
        )
        try ctx.save()

        XCTAssertEqual(three.sortedAttachments.count, 3)
        XCTAssertEqual(single.sortedAttachments.count, 1)
        UserDefaults.standard.set(true, forKey: seedFlag)
        print("[seed] 册页风造数完成：3 图想法 + 1 图想法，已写入 app 沙盒库")
    }
}
