//
//  CategoryDeletionIntegrationTests.swift
//  HoloTests
//
//  分类删除统一预检与原子执行的 Core Data 集成测试（方案 §7.2）
//

import XCTest
import CoreData
@testable import Holo

// iOS 26 SDK 的某模块也导出 Category 名字，与 Holo.Category 冲突；
// 显式指回被测类型
private typealias Category = Holo.Category

final class CategoryDeletionIntegrationTests: XCTestCase {

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
        isDefault: Bool = false,
        isSystem: Bool = false,
        id: UUID = UUID()
    ) -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: "tag",
            color: "#13A4EC",
            type: type,
            isDefault: isDefault,
            parentId: parentId,
            isSystem: isSystem
        )
        category.id = id
        return category
    }

    @discardableResult
    private func makeTransaction(
        category: Category,
        type: String = "expense",
        amount: Decimal = 20,
        note: String? = "测试明细"
    ) -> Transaction {
        let tx = context.insertTestObject(Transaction.self)
        tx.id = UUID()
        tx.amount = NSDecimalNumber(decimal: amount)
        tx.type = type
        tx.date = Date()
        tx.note = note
        tx.category = category
        return tx
    }

    @discardableResult
    private func makeAccount(name: String = "现金") -> Account {
        let account = context.insertTestObject(Account.self)
        account.id = UUID()
        account.name = name
        account.createdAt = Date()
        account.updatedAt = Date()
        return account
    }

    @discardableResult
    private func makeBudget(
        category: Category,
        account: Account,
        amount: Decimal = 100,
        period: BudgetPeriod = .month
    ) -> Budget {
        Budget.create(
            in: context,
            accountId: account.id,
            amount: NSDecimalNumber(decimal: amount),
            period: period,
            startDate: Date(),
            categoryId: category.id
        )
    }

    @discardableResult
    private func makeSpendingProject(
        name: String,
        category: Category,
        accountId: UUID
    ) -> SpendingProject {
        let project = context.insertTestObject(SpendingProject.self)
        project.id = UUID()
        project.name = name
        project.kind = SpendingProjectKind.recurring.rawValue
        project.amount = NSDecimalNumber(decimal: 15)
        project.startDate = Date()
        project.maxOccurrences = 0
        project.occurrencesGenerated = 0
        project.isPaused = false
        project.autoGenerateTransaction = true
        project.categoryId = category.id
        project.accountId = accountId
        project.createdAt = Date()
        project.updatedAt = Date()
        return project
    }

    @discardableResult
    private func makeMappingRule(
        candidate: String,
        targetPrimary: String,
        targetSub: String,
        type: String = "expense"
    ) -> CategoryMappingRecordEntity {
        let record = context.insertTestObject(CategoryMappingRecordEntity.self)
        record.mappingKey = "\(type)|\(targetPrimary)|\(candidate)"
        record.transactionType = type
        record.primaryCategory = targetPrimary
        record.candidate = candidate
        record.targetPrimary = targetPrimary
        record.targetSub = targetSub
        record.updatedAt = Date()
        return record
    }

    /// 标准测试家族：源一级「源餐饮」+ 源二级「咖啡」，目标一级「目标餐饮」+ 目标二级「茶」
    private func makeFamily() -> (sourceParent: Category, sourceChild: Category, targetParent: Category, targetChild: Category) {
        let sourceParent = makeCategory(name: "源餐饮")
        let sourceChild = makeCategory(name: "咖啡", parentId: sourceParent.id)
        let targetParent = makeCategory(name: "目标餐饮")
        let targetChild = makeCategory(name: "茶", parentId: targetParent.id)
        try? context.save()
        return (sourceParent, sourceChild, targetParent, targetChild)
    }

    private func executeExpectingSuccess(
        _ snapshot: CategoryDeletionImpactSnapshot,
        disposition: CategoryDeletionDisposition
    ) throws {
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: disposition
        )
        try CategoryDeletionExecutor.execute(command, in: context)
    }

    private func allRows(id: UUID) -> [Category] {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - 空分类软删除

    func testDeleteEmptySecondarySoftDeletesCategoryOnly() throws {
        let family = makeFamily()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertFalse(snapshot.hasReferences)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))

        let rows = allRows(id: family.sourceChild.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].deletedAt)
        XCTAssertNotNil(rows[0].deletedBatchId)
        XCTAssertEqual(rows[0].deletedBatchId, rows[0].deletedBatchId)

        // 其他分类不受影响
        XCTAssertNil(allRows(id: family.targetChild.id)[0].deletedAt)
        XCTAssertNil(allRows(id: family.sourceParent.id)[0].deletedAt)
    }

    func testDeletePresetSecondaryIsAllowed() throws {
        // D1：isDefault 不再限制删除
        let parent = makeCategory(name: "餐饮")
        let presetChild = makeCategory(name: "咖啡", parentId: parent.id, isDefault: true)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: presetChild.id, in: context)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))

        XCTAssertNotNil(allRows(id: presetChild.id)[0].deletedAt)
    }

    // MARK: - 转移

    func testMoveAllRedirectsLiveAndRecycledTransactions() throws {
        let family = makeFamily()
        let live = makeTransaction(category: family.sourceChild, amount: 30)
        let recycled = makeTransaction(category: family.sourceChild, amount: 50, note: "回收站中")
        recycled.markDeleted(batchId: UUID())
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertEqual(snapshot.liveTransactions.count, 1)
        XCTAssertEqual(snapshot.recycledTransactionCount, 1)
        XCTAssertEqual(snapshot.liveTransactionTotal, -30)

        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
        )

        // 活明细与回收站明细都改指目标，类型不变，软删状态不被破坏
        XCTAssertEqual(live.category?.id, family.targetChild.id)
        XCTAssertEqual(recycled.category?.id, family.targetChild.id)
        XCTAssertNotNil(recycled.deletedAt)
        XCTAssertNil(live.deletedAt)
        // 源分类软删
        XCTAssertNotNil(allRows(id: family.sourceChild.id)[0].deletedAt)
    }

    func testMoveBudgetRedirectsCategoryIdWithoutConflict() throws {
        let family = makeFamily()
        let account = makeAccount()
        makeBudget(category: family.sourceChild, account: account)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertEqual(snapshot.budgets.count, 1)

        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
        )

        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let budgets = try context.fetch(request)
        XCTAssertEqual(budgets.count, 1)
        XCTAssertEqual(budgets[0].categoryId, family.targetChild.id)
        XCTAssertEqual(budgets[0].amount, NSDecimalNumber(decimal: 100))
    }

    func testBudgetConflictBlocksSubmissionWithoutResolution() throws {
        let family = makeFamily()
        let account = makeAccount()
        makeBudget(category: family.sourceChild, account: account)
        makeBudget(category: family.targetChild, account: account, amount: 55)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertThrowsError(
            try executeExpectingSuccess(
                snapshot,
                disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
            )
        ) { error in
            guard case FinanceError.categoryDeletionBlocked = error else {
                return XCTFail("应为 categoryDeletionBlocked，实际 \(error)")
            }
        }
    }

    func testBudgetMergeAmountsUnifiesIntoTarget() throws {
        let family = makeFamily()
        let account = makeAccount()
        makeBudget(category: family.sourceChild, account: account, amount: 100)
        makeBudget(category: family.targetChild, account: account, amount: 55)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        let conflictID = snapshot.budgets[0].id
        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(
                toCategoryID: family.targetChild.id,
                budgetConflicts: [conflictID: .mergeAmounts]
            ))
        )

        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let budgets = try context.fetch(request)
        XCTAssertEqual(budgets.count, 1)
        XCTAssertEqual(budgets[0].amount, NSDecimalNumber(decimal: 155))
        XCTAssertEqual(budgets[0].categoryId, family.targetChild.id)
    }

    func testBudgetKeepTargetMovesConflictingBudgetToBatch() throws {
        let family = makeFamily()
        let account = makeAccount()
        makeBudget(category: family.sourceChild, account: account, amount: 100)
        makeBudget(category: family.targetChild, account: account, amount: 55)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        let conflictID = snapshot.budgets[0].id
        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(
                toCategoryID: family.targetChild.id,
                budgetConflicts: [conflictID: .keepTarget]
            ))
        )

        let request = Budget.fetchRequest()
        let budgets = try context.fetch(request)
        let alive = budgets.filter { $0.deletedAt == nil }
        let trashed = budgets.filter { $0.deletedAt != nil }
        XCTAssertEqual(alive.count, 1)
        XCTAssertEqual(alive[0].amount, NSDecimalNumber(decimal: 55))
        XCTAssertEqual(trashed.count, 1)
        // 保留目标的预算与分类同批次，可随批次恢复
        let categoryBatch = allRows(id: family.sourceChild.id)[0].deletedBatchId
        XCTAssertEqual(trashed[0].deletedBatchId, categoryBatch)
    }

    func testMoveRedirectsSpendingProjects() throws {
        let family = makeFamily()
        let account = makeAccount()
        let project = makeSpendingProject(name: "网费", category: family.sourceChild, accountId: account.id)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertEqual(snapshot.spendingProjects.count, 1)

        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
        )

        XCTAssertEqual(project.categoryId, family.targetChild.id)
        XCTAssertNil(project.deletedAt)
    }

    func testMoveRewritesLearnedRuleTargets() throws {
        let family = makeFamily()
        let rule = makeMappingRule(
            candidate: "瑞幸", targetPrimary: "源餐饮", targetSub: "咖啡"
        )
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertEqual(snapshot.learnedMappings.count, 1)

        try executeExpectingSuccess(
            snapshot,
            disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
        )

        XCTAssertEqual(rule.targetSub, "茶")
        XCTAssertEqual(rule.targetPrimary, "目标餐饮")
    }

    // MARK: - 一并删除

    func testDeleteWithReferencesPutsEverythingInSameBatch() throws {
        let family = makeFamily()
        let account = makeAccount()
        let tx = makeTransaction(category: family.sourceChild, amount: 88)
        let budget = makeBudget(category: family.sourceChild, account: account)
        let project = makeSpendingProject(name: "会员", category: family.sourceChild, accountId: account.id)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))

        let batchIDs: Set<UUID?> = [
            allRows(id: family.sourceChild.id)[0].deletedBatchId,
            tx.deletedBatchId,
            budget.deletedBatchId,
            project.deletedBatchId
        ]
        XCTAssertEqual(batchIDs.count, 1)
        XCTAssertNotNil(batchIDs.first ?? nil)
        XCTAssertNotNil(tx.deletedAt)
        XCTAssertNotNil(budget.deletedAt)
        XCTAssertNotNil(project.deletedAt)
    }

    func testDeleteWithReferencesDeletesLearnedRules() throws {
        let family = makeFamily()
        makeMappingRule(candidate: "瑞幸", targetPrimary: "源餐饮", targetSub: "咖啡")
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        XCTAssertEqual(snapshot.learnedMappings.count, 1)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))

        XCTAssertEqual(try context.count(for: CategoryMappingRecordEntity.fetchRequest()), 0)
    }

    // MARK: - 一级分类

    func testPrimaryMoveKeepsTransactionsOnOriginalSubcategory() throws {
        // 方式 1：保留子分类迁移，账目仍指原二级（方案 §3.3）
        let family = makeFamily()
        let grandChild = makeCategory(name: "拿铁", parentId: family.sourceParent.id)
        let tx = makeTransaction(category: grandChild)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceParent.id, in: context)
        XCTAssertEqual(snapshot.scope, .primary)
        XCTAssertEqual(snapshot.childCategories.count, 2)
        XCTAssertEqual(snapshot.liveTransactions.count, 1)

        try executeExpectingSuccess(
            snapshot,
            disposition: .primary(.moveChildren(toParentID: family.targetParent.id, conflicts: [:]))
        )

        // 子分类改挂目标父，颜色跟随；账目不动
        XCTAssertEqual(allRows(id: grandChild.id)[0].parentId, family.targetParent.id)
        XCTAssertEqual(allRows(id: grandChild.id)[0].color, family.targetParent.color)
        XCTAssertEqual(tx.category?.id, grandChild.id)
        // 源一级软删
        XCTAssertNotNil(allRows(id: family.sourceParent.id)[0].deletedAt)
    }

    func testPrimaryMoveResolvesNameConflictByRename() throws {
        let family = makeFamily()
        // 目标父下已有同名「咖啡」
        let existing = makeCategory(name: "咖啡", parentId: family.targetParent.id)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceParent.id, in: context)
        let coffeeChild = snapshot.childCategories.first { $0.name == "咖啡" }!

        try executeExpectingSuccess(
            snapshot,
            disposition: .primary(.moveChildren(
                toParentID: family.targetParent.id,
                conflicts: [coffeeChild.id: .keepBothRenamed]
            ))
        )

        // 冲突子分类重命名后迁移，原同名分类保持不动
        let renamed = allRows(id: coffeeChild.id)[0]
        XCTAssertEqual(renamed.name, "咖啡 2")
        XCTAssertEqual(renamed.parentId, family.targetParent.id)
        XCTAssertEqual(allRows(id: existing.id)[0].name, "咖啡")
        XCTAssertNil(allRows(id: existing.id)[0].deletedAt)
    }

    func testPrimaryMoveMergesConflictIntoExisting() throws {
        let family = makeFamily()
        // 目标父下已有同名「咖啡」；源侧的「咖啡」即 family.sourceChild
        let existing = makeCategory(name: "咖啡", parentId: family.targetParent.id)
        let tx = makeTransaction(category: family.sourceChild)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceParent.id, in: context)
        try executeExpectingSuccess(
            snapshot,
            disposition: .primary(.moveChildren(
                toParentID: family.targetParent.id,
                conflicts: [family.sourceChild.id: .mergeIntoExisting]
            ))
        )

        // 账目改挂已有同名分类，冲突行进批次
        XCTAssertEqual(tx.category?.id, existing.id)
        XCTAssertNotNil(allRows(id: family.sourceChild.id)[0].deletedAt)
        XCTAssertNil(allRows(id: existing.id)[0].deletedAt)
    }

    func testPrimaryDisposeChildrenHandlesEachIndependently() throws {
        let family = makeFamily()
        let secondChild = makeCategory(name: "茶叶", parentId: family.sourceParent.id)
        let txCoffee = makeTransaction(category: family.sourceChild)
        let txTea = makeTransaction(category: secondChild)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceParent.id, in: context)
        try executeExpectingSuccess(
            snapshot,
            disposition: .primary(.disposeChildren([
                family.sourceChild.id: .moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]),
                secondChild.id: .deleteWithReferences
            ]))
        )

        XCTAssertEqual(txCoffee.category?.id, family.targetChild.id)
        XCTAssertNil(txCoffee.deletedAt)
        XCTAssertNotNil(txTea.deletedAt)
        XCTAssertNotNil(allRows(id: secondChild.id)[0].deletedAt)
        XCTAssertNotNil(allRows(id: family.sourceParent.id)[0].deletedAt)
        // 全家族同一批次
        let batchIDs: Set<UUID?> = [
            allRows(id: family.sourceParent.id)[0].deletedBatchId,
            allRows(id: family.sourceChild.id)[0].deletedBatchId,
            allRows(id: secondChild.id)[0].deletedBatchId,
            txTea.deletedBatchId
        ]
        XCTAssertEqual(batchIDs.count, 1)
    }

    // MARK: - 原子性与并发保护

    func testStaleRevisionIsRejected() throws {
        let family = makeFamily()
        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)

        // 预检后数据被改（他端新增一笔账目）
        makeTransaction(category: family.sourceChild, amount: 999)
        try? context.save()

        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: .secondary(.deleteWithReferences)
        )
        XCTAssertThrowsError(try CategoryDeletionExecutor.execute(command, in: context)) { error in
            guard case FinanceError.staleCategoryDeletion = error else {
                return XCTFail("应为 staleCategoryDeletion，实际 \(error)")
            }
        }
    }

    func testExecuteFailsCleanlyWhenTargetDeleted() throws {
        // 执行时转移目标已被删除（他端操作）：整体拒绝，零部分写入
        let family = makeFamily()
        let tx = makeTransaction(category: family.sourceChild)
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)

        // 预检后目标被软删（不影响源家族版本指纹——重算快照应能发现引用不变）
        for row in allRows(id: family.targetChild.id) {
            row.markDeleted(batchId: UUID())
        }
        try context.save()

        XCTAssertThrowsError(
            try executeExpectingSuccess(
                snapshot,
                disposition: .secondary(.moveAll(toCategoryID: family.targetChild.id, budgetConflicts: [:]))
            )
        )

        // 拒绝后明细未改指、分类未软删
        XCTAssertEqual(tx.category?.id, family.sourceChild.id)
        XCTAssertNil(allRows(id: family.sourceChild.id)[0].deletedAt)
    }

    // MARK: - 预设分类不复活

    func testDeletedPresetCategoryDoesNotReviveOnReseed() throws {
        // 首装全量种子（走 seedDefaultCategories 的新用户分支）
        Category.seedDefaultCategories(in: context)

        // 找到种子里的预设二级「咖啡」（不存在则取任一预设二级）
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "parentId != nil AND isDefault == YES AND deletedAt == nil")
        let presets = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
        try XCTSkipIf(presets.isEmpty, "种子未铺出预设二级")
        let victim = presets.first { $0.name.contains("咖啡") } ?? presets[0]

        // 用户删除该预设
        let snapshot = try CategoryDeletionExecutor.impact(categoryID: victim.id, in: context)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))
        XCTAssertNotNil(allRows(id: victim.id)[0].deletedAt)

        // 冷启动/进财务页会重跑 setup → seedDefaultCategories（老用户分支）
        Category.seedDefaultCategories(in: context)
        try? context.save()

        // 断言：软删行保持软删，且没有种出同名新活行
        for row in allRows(id: victim.id) {
            XCTAssertNotNil(row.deletedAt, "软删行不应被复活")
        }
        let aliveSameName = Category.fetchRequest()
        aliveSameName.predicate = NSPredicate(
            format: "name == %@ AND type == %@ AND deletedAt == nil",
            victim.name, victim.type
        )
        XCTAssertEqual(
            DuplicateRowFilter.deduplicatingCopies(try context.fetch(aliveSameName)).count,
            0,
            "重跑种子后不应补出同名新行：\(victim.name)"
        )
    }

    // MARK: - iCloud 重复行

    func testDuplicateRowsAreAllSoftDeleted() throws {
        let family = makeFamily()
        // 同 id 副本行（CloudKit 回流的常见形态）
        let duplicate = Category.create(
            in: context,
            name: "咖啡",
            icon: "tag",
            color: "#13A4EC",
            type: "expense",
            parentId: family.sourceParent.id
        )
        duplicate.id = family.sourceChild.id
        try? context.save()

        let snapshot = try CategoryDeletionExecutor.impact(categoryID: family.sourceChild.id, in: context)
        try executeExpectingSuccess(snapshot, disposition: .secondary(.deleteWithReferences))

        let rows = allRows(id: family.sourceChild.id)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNotNil(row.deletedAt)
            XCTAssertNotNil(row.deletedBatchId)
        }
    }
}
