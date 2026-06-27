//
//  ConvergenceRejectionRepositoryTests.swift
//  HoloTests
//
//  建议级拒绝实体仓储测试（P2.5）
//  覆盖 幂等键归一化 / 集合语义 / 过期不命中 / 重复拒绝不重复创建 / 查询
//

import XCTest
import CoreData
@testable import Holo

final class ConvergenceRejectionRepositoryTests: XCTestCase {

    private func makeRepo() throws -> (ConvergenceRejectionRepository, NSManagedObjectContext) {
        let model = CoreDataStack.shared.createDataModel()
        let container = NSPersistentContainer(name: "ConvergenceRejectionTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var storeError: Error?
        container.loadPersistentStores { _, error in storeError = error }
        if let storeError { throw storeError }
        let ctx = container.viewContext
        return (ConvergenceRejectionRepository(context: ctx), ctx)
    }

    // MARK: - suggestionKey 归一化

    func test_suggestionKey来源词顺序无关() {
        let k1 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["coding", "vibecoding"])
        let k2 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["vibecoding", "coding"])
        XCTAssertEqual(k1, k2)
    }

    func test_suggestionKey大小写与空格归一化() {
        let k1 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["Coding", " vibecoding "])
        let k2 = ConvergenceRejectionRepository.suggestionKey(topicTitle: " 编程 ", sourceTerms: ["coding", "Vibecoding"])
        XCTAssertEqual(k1, k2)
    }

    func test_suggestionKey主题名不同则不同() {
        let k1 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["coding"])
        let k2 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "AI协作", sourceTerms: ["coding"])
        XCTAssertNotEqual(k1, k2)
    }

    func test_suggestionKey来源词集合不同则不同() {
        // 子集不算同键（来源词集合必须完全一致）
        let k1 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["coding", "vibecoding"])
        let k2 = ConvergenceRejectionRepository.suggestionKey(topicTitle: "编程", sourceTerms: ["coding"])
        XCTAssertNotEqual(k1, k2)
    }

    // MARK: - reject / isRejected

    func test_reject创建记录且可命中() throws {
        let (repo, _) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding", "vibecoding"])

        XCTAssertTrue(repo.isRejected(topicTitle: "编程实践", sourceTerms: ["coding", "vibecoding"]))
    }

    func test_isRejected来源词顺序无关命中() throws {
        let (repo, _) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding", "vibecoding"])

        XCTAssertTrue(repo.isRejected(topicTitle: "编程实践", sourceTerms: ["vibecoding", "coding"]))
    }

    func test_isRejected主题名不同不命中() throws {
        let (repo, _) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"])

        XCTAssertFalse(repo.isRejected(topicTitle: "AI协作", sourceTerms: ["coding"]))
    }

    func test_isRejected来源词集合不同不命中() throws {
        let (repo, _) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding", "vibecoding"])

        XCTAssertFalse(repo.isRejected(topicTitle: "编程实践", sourceTerms: ["coding"]))
    }

    // MARK: - 过期

    func test_过期rejection不命中() throws {
        let (repo, ctx) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"])

        // 手动把 expiresAt 改到过去
        let request = ThoughtTagConvergenceRejection.fetchRequest()
        let all = try ctx.fetch(request)
        XCTAssertEqual(all.count, 1)
        for r in all { r.expiresAt = Date(timeIntervalSinceNow: -1) }
        try ctx.save()

        XCTAssertFalse(repo.isRejected(topicTitle: "编程实践", sourceTerms: ["coding"]))
    }

    // MARK: - 幂等

    func test_重复reject同键不重复创建且续期() throws {
        let (repo, ctx) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"], expiresInDays: 30)
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"], expiresInDays: 60)

        let request = ThoughtTagConvergenceRejection.fetchRequest()
        let count = try ctx.count(for: request)
        XCTAssertEqual(count, 1)  // 幂等，更新而非新建
    }

    // MARK: - fetchActiveRejections

    func test_fetchActiveRejections排除过期() throws {
        let (repo, ctx) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"], expiresInDays: 30)
        try repo.reject(topicTitle: "AI协作", sourceTerms: ["agent"], expiresInDays: 30)

        // 把第二条改到过去
        let request = ThoughtTagConvergenceRejection.fetchRequest()
        let all = try ctx.fetch(request)
        if let ai = all.first(where: { $0.topicTitle == "AI协作" }) {
            ai.expiresAt = Date(timeIntervalSinceNow: -1)
        }
        try ctx.save()

        let active = try repo.fetchActiveRejections()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.topicTitle, "编程实践")
    }

    // MARK: - purgeExpired

    func test_purgeExpired删除过期记录() throws {
        let (repo, ctx) = try makeRepo()
        try repo.reject(topicTitle: "编程实践", sourceTerms: ["coding"], expiresInDays: 30)

        let request = ThoughtTagConvergenceRejection.fetchRequest()
        let all = try ctx.fetch(request)
        for r in all { r.expiresAt = Date(timeIntervalSinceNow: -1) }
        try ctx.save()

        let purged = try repo.purgeExpired()
        XCTAssertEqual(purged, 1)
        XCTAssertEqual(try ctx.count(for: request), 0)
    }
}
