//
//  FinanceCategoryNameCacheTests.swift
//  HoloTests
//
//  分类层级名称缓存（2026-11-24 技术优化）：
//  - resolveCategoryNames 按分类缓存结果，分类有任何变更（改名/父子关系变化/父分类稍后到达）即失效；
//  - getAllTransactions(from:) 只取窗口内流水。
//

import XCTest
import CoreData
@testable import Holo

// iOS 26 SDK 的某模块也导出 Category 名字，与 Holo.Category 冲突；显式指回被测类型
private typealias Category = Holo.Category

@MainActor
final class FinanceCategoryNameCacheTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repository: FinanceRepository!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
        repository = FinanceRepository(context: context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        repository = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCategory(name: String, parentId: UUID? = nil, id: UUID = UUID()) -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: "tag",
            color: "#13A4EC",
            type: "expense",
            isDefault: false,
            parentId: parentId,
            isSystem: false
        )
        category.id = id
        return category
    }

    @discardableResult
    private func makeTransaction(category: Category?, daysAgo: Double) -> Transaction {
        let tx = context.insertTestObject(Transaction.self)
        tx.id = UUID()
        tx.amount = 20
        tx.type = "expense"
        tx.date = Date().addingTimeInterval(-daysAgo * 86_400)
        tx.category = category
        return tx
    }

    // MARK: - 分类层级名称

    func test二级分类解析为一级加二级() {
        let parentId = UUID()
        let parent = makeCategory(name: "餐饮", id: parentId)
        let child = makeCategory(name: "午饭", parentId: parentId)
        try? context.save()

        let names = repository.resolveCategoryNames(from: child)
        XCTAssertEqual(names.primary, parent.name)
        XCTAssertEqual(names.sub, "午饭")
    }

    func test父分类改名后缓存失效() throws {
        let parentId = UUID()
        let parent = makeCategory(name: "餐饮", id: parentId)
        let child = makeCategory(name: "午饭", parentId: parentId)
        try context.save()
        XCTAssertEqual(repository.resolveCategoryNames(from: child).primary, "餐饮")

        parent.name = "吃喝"
        try context.save()
        XCTAssertEqual(repository.resolveCategoryNames(from: child).primary, "吃喝", "父分类改名后必须拿到新名字")
    }

    func test父分类稍后同步到达() throws {
        let parentId = UUID()
        let child = makeCategory(name: "午饭", parentId: parentId)
        try context.save()
        XCTAssertEqual(repository.resolveCategoryNames(from: child).primary, "午饭", "父分类还不存在时按一级名称返回")

        makeCategory(name: "餐饮", id: parentId)
        try context.save()
        let names = repository.resolveCategoryNames(from: child)
        XCTAssertEqual(names.primary, "餐饮", "父分类到达后必须解析出层级")
        XCTAssertEqual(names.sub, "午饭")
    }

    func test二级升为一级后缓存失效() throws {
        let parentId = UUID()
        makeCategory(name: "餐饮", id: parentId)
        let child = makeCategory(name: "午饭", parentId: parentId)
        try context.save()
        XCTAssertEqual(repository.resolveCategoryNames(from: child).sub, "午饭")

        child.parentId = nil
        try context.save()
        let names = repository.resolveCategoryNames(from: child)
        XCTAssertEqual(names.primary, "午饭")
        XCTAssertNil(names.sub)
    }

    // MARK: - 按窗口取流水

    func test按起始日期只取窗口内流水() async throws {
        let category = makeCategory(name: "餐饮")
        makeTransaction(category: category, daysAgo: 10)
        makeTransaction(category: category, daysAgo: 100)
        makeTransaction(category: category, daysAgo: 200)
        try context.save()

        let now = Date()
        let windowed = try await repository.getAllTransactions(asOf: now, from: now.addingTimeInterval(-180 * 86_400))
        XCTAssertEqual(windowed.count, 2, "近 180 天窗口内只有 2 笔")
        let all = try await repository.getAllTransactions(asOf: now)
        XCTAssertEqual(all.count, 3, "不传起始日期仍是全部已发生流水")
    }
}
