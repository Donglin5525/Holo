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

@MainActor
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

    // MARK: - 待分类兜底不变量（2026-11-01 实报「记账必须选择二级分类」根治）
    // 场景复刻：用户自定义分类树删光/改名了「其他」一级，旧版 ensurePendingCategory
    // 会默默建出一级「待分类」——入账闸门只认二级，兜底分类被自己拦成死路。

    func test待分类兜底_父级全缺时补种其他一级_绝不降级为一级() async throws {
        let repo = FinanceRepository(context: context)

        let pending = repo.ensurePendingCategory(type: .expense)
        try context.save()

        // 不变量：待分类必须是二级（入账闸门只认二级）
        let parentID = try XCTUnwrap(pending.parentId, "待分类必须挂父级，一级兜底会被入账闸门拦下")
        // 父级是活的「其他」一级（与种子同词表，按名查重可命中）
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND parentId == nil AND deletedAt == nil",
            parentID as CVarArg
        )
        let parent = try XCTUnwrap(context.fetch(request).first, "补种的父一级必须真实存在")
        XCTAssertEqual(parent.name, FinanceSeedVocabulary.other.value(for: .seedLanguage))
        XCTAssertEqual(parent.type, TransactionType.expense.rawValue)

        // 幂等：再次调用返回同一条待分类，不重复建行
        let again = repo.ensurePendingCategory(type: .expense)
        XCTAssertEqual(again.objectID, pending.objectID, "重复调用不得重复建行")
    }

    func test待分类兜底_软删的其他父级不算存在_不挂回收站行() async throws {
        // 用户删了「其他」（软删进回收站）——待分类不得挂到回收站行上
        let deadParent = makeCategory(name: FinanceSeedVocabulary.other.value(for: .seedLanguage))
        deadParent.markDeleted(batchId: UUID())
        try context.save()

        let repo = FinanceRepository(context: context)
        let pending = repo.ensurePendingCategory(type: .expense)
        try context.save()

        let parentID = try XCTUnwrap(pending.parentId, "待分类必须挂活父级")
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND parentId == nil AND deletedAt == nil",
            parentID as CVarArg
        )
        _ = try XCTUnwrap(context.fetch(request).first, "必须补种新的活父级，而不是复用回收站行")
    }

    func test孤儿待分类清理_一级系统行软删_用户自建与正常二级不动() async throws {
        // 1. BUG 产物：一级 isSystem「待分类」孤儿 → 应被软删
        let orphan = makeCategory(name: FinancePendingCategory.currentName)
        orphan.isSystem = true
        // 2. legacy 名（待确认）一级系统孤儿 → 同样应被软删
        let legacyOrphan = makeCategory(name: FinancePendingCategory.legacyName)
        legacyOrphan.isSystem = true
        // 3. 用户自建一级「待分类」（isSystem=false）→ 不动
        let userTop = makeCategory(name: FinancePendingCategory.currentName)
        // 4. 正常挂靠的二级待分类 → 不动
        let parent = makeCategory(name: FinanceSeedVocabulary.other.value(for: .seedLanguage))
        let sub = makeCategory(name: FinancePendingCategory.currentName, parentId: parent.id)
        try context.save()

        FinanceRepository(context: context).softDeleteOrphanPendingCategories()

        XCTAssertNotNil(orphan.deletedAt, "一级系统孤儿应被软删")
        XCTAssertNotNil(legacyOrphan.deletedAt, "legacy 一级孤儿应被软删")
        XCTAssertNil(userTop.deletedAt, "用户自建的同名一级不动")
        XCTAssertNil(sub.deletedAt, "正常二级待分类不动")
        XCTAssertNil(parent.deletedAt, "正常父级不动")
    }

    func test孤儿待分类清理_有交易引用的孤儿留置不动() async throws {
        let repo = FinanceRepository(context: context)
        let account = try repo.addAccount(name: "现金", type: .cash, initialBalance: 0)
        let orphan = makeCategory(name: FinancePendingCategory.currentName)
        orphan.isSystem = true
        let tx = Transaction(context: context)
        tx.id = UUID()
        tx.amount = NSDecimalNumber(decimal: 10)
        tx.type = TransactionType.expense.rawValue
        tx.category = orphan
        tx.account = account
        tx.date = Date()
        try context.save()

        repo.softDeleteOrphanPendingCategories()

        XCTAssertNil(orphan.deletedAt, "有真实交易引用的孤儿留置（动它等于丢账）")
    }
}
