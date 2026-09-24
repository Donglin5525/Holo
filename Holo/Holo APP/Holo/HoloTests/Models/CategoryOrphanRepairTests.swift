//
//  CategoryOrphanRepairTests.swift
//  HoloTests
//
//  孤儿分类修复 + 回收站恢复父子联动的 Core Data 集成测试。
//  背景：活子+死父的孤儿二级分类会在统计分析聚合中冒充一级混入饼图
//  （2026-09-25 东林实报），修复 = 恢复联动 + 启动自愈双通道。
//

import XCTest
import CoreData
@testable import Holo

// iOS 26 SDK 的某模块也导出 Category 名字，与 Holo.Category 冲突；
// 显式指回被测类型
private typealias Category = Holo.Category

final class CategoryOrphanRepairTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCategory(
        name: String,
        type: String = "expense",
        parentId: UUID? = nil,
        id: UUID = UUID()
    ) -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: "tag",
            color: "#13A4EC",
            type: type,
            isDefault: false,
            parentId: parentId,
            isSystem: false
        )
        category.id = id
        return category
    }

    // MARK: - 孤儿修复

    func test孤儿修复_活子软删父_联动恢复父一级() throws {
        let parentId = UUID()
        let parent = makeCategory(name: "餐饮", id: parentId)
        parent.markDeleted(batchId: UUID())
        let child = makeCategory(name: "午饭", parentId: parentId)

        let result = try CategoryOrphanRepair.repair(in: context)

        XCTAssertEqual(result.restoredParents, 1)
        XCTAssertEqual(result.danglingChildren, 0)
        XCTAssertNil(parent.deletedAt, "父一级应被联动恢复")
        XCTAssertNil(child.deletedAt, "子分类保持活跃")
    }

    func test孤儿修复_父已活_不动作() throws {
        let parentId = UUID()
        makeCategory(name: "餐饮", id: parentId)
        let child = makeCategory(name: "午饭", parentId: parentId)

        let result = try CategoryOrphanRepair.repair(in: context)

        XCTAssertEqual(result.restoredParents, 0)
        XCTAssertEqual(result.danglingChildren, 0)
    }

    func test孤儿修复_父行悬空_计数暴露不崩() throws {
        makeCategory(name: "午饭", parentId: UUID())

        let result = try CategoryOrphanRepair.repair(in: context)

        XCTAssertEqual(result.danglingChildren, 1)
        XCTAssertEqual(result.restoredParents, 0)
    }

    func test孤儿修复_同id父副本_优先活行不复活死行() throws {
        let parentId = UUID()
        makeCategory(name: "餐饮副本死行", id: parentId).markDeleted(batchId: UUID())
        makeCategory(name: "餐饮正身", id: parentId)
        let child = makeCategory(name: "午饭", parentId: parentId)

        let result = try CategoryOrphanRepair.repair(in: context)

        XCTAssertEqual(result.restoredParents, 0, "已有活父时不得复活软删副本，否则制造新副本")
        let parentRows = try context.fetch(Category.fetchRequest()).filter { $0.id == parentId }
        XCTAssertEqual(parentRows.count, 2)
        XCTAssertTrue(parentRows.contains { $0.deletedAt != nil }, "软删副本行保持原状")
        XCTAssertTrue(parentRows.contains { $0.deletedAt == nil }, "活行保持活跃")
    }

    func test孤儿修复_软删子分类不参与判定() throws {
        let parentId = UUID()
        let parent = makeCategory(name: "餐饮", id: parentId)
        parent.markDeleted(batchId: UUID())
        let child = makeCategory(name: "午饭", parentId: parentId)
        child.markDeleted(batchId: UUID())

        let result = try CategoryOrphanRepair.repair(in: context)

        XCTAssertEqual(result.restoredParents, 0, "子分类自身在回收站时不算孤儿，父保持软删")
        XCTAssertNotNil(parent.deletedAt)
    }

    // MARK: - 回收站恢复联动

    func test恢复联动_恢复二级分类_连带恢复软删父一级() throws {
        let parentId = UUID()
        let parent = makeCategory(name: "餐饮", id: parentId)
        parent.markDeleted(batchId: UUID())
        let child = makeCategory(name: "午饭", parentId: parentId)

        let linked = RecycleBinService.restoreLinkedParents(of: child, in: context)

        XCTAssertEqual(linked, 1)
        XCTAssertNil(parent.deletedAt, "恢复二级分类时父一级应一并恢复")
    }

    func test恢复联动_一级分类无父_返回零() throws {
        let top = makeCategory(name: "餐饮")

        let linked = RecycleBinService.restoreLinkedParents(of: top, in: context)

        XCTAssertEqual(linked, 0)
    }
}
