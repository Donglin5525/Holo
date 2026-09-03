//
//  FinanceReconciliationTests.swift
//  HoloTests
//
//  余额对账（批次1 数据层）单测：
//  - 调整流水双重身份：参与余额、退出收支统计、明细保留
//  - 对账锚点：写入 / 自洽检测四态 / 调整流水不污染锚点回溯
//  - updateAccount initialBalance 双层 Optional 语义
//  - 存量迁移（旧「余额调整」分类交易补标记）幂等
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class FinanceReconciliationTests: XCTestCase {

    /// 进程级共享容器：CoreDataTestSupport.sharedModel 被多个容器反复 load 后，
    /// 全量测试顺序下会触发后续测试类的「模型不兼容(134020)」系统层错误——
    /// 本类 12 个用例若各自建容器（+12 次 load）恰好把阈值推过线。
    /// 共享一个容器、每用例清数据重建 fixtures，负载与单个既有测试类持平。
    private static let sharedContainer: NSPersistentContainer = {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "ReconciliationTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var account: Account!
    private var ordinaryCategory: Holo.Category!

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext

        // 清空上一用例数据（in-memory store 不支持 batch delete，逐实体 fetch+delete）
        for entityName in ["Transaction", "Category", "Account"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in (try? context.fetch(request)) ?? [] {
                context.delete(object)
            }
        }
        try? context.save()

        repo = FinanceRepository(context: context)
        account = repo.addAccount(name: "测试储蓄卡", type: .bank, initialBalance: 100)

        // 手动种对账分类依赖的父分类（「其他收入」/「其他」）。
        // 不跑 repo.setup()：它会触发 CoreDataStack.shared 在同进程注册第二份实体模型，污染后续测试类。
        _ = Holo.Category.create(
            in: context, name: "其他收入", icon: "circle", color: "#8E8E93",
            type: TransactionType.income.rawValue
        )
        _ = Holo.Category.create(
            in: context, name: "其他", icon: "circle", color: "#8E8E93",
            type: TransactionType.expense.rawValue
        )

        // 普通交易分类必须是二级（validateTransactionCategory 的规则）
        let parentCategory = Holo.Category.create(
            in: context,
            name: "餐饮",
            icon: "fork.knife",
            color: "#FF9500",
            type: TransactionType.expense.rawValue
        )
        ordinaryCategory = Holo.Category.create(
            in: context,
            name: "午餐",
            icon: "fork.knife",
            color: "#FF9500",
            type: TransactionType.expense.rawValue,
            parentId: parentCategory.id
        )
        try? context.save()
    }

    override func tearDown() async throws {
        // 恢复迁移 flag 为「已执行」，避免本测试的 flag 操作影响其他用例的 setup()
        UserDefaults.standard.set(true, forKey: "hasMigratedReconciliationAdjustments_v1")
        context = nil
        repo = nil
    }

    // MARK: - Helpers

    private var todayRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        return (start, end)
    }

    @discardableResult
    private func addOrdinaryExpense(_ amount: Decimal, date: Date = Date()) async throws -> Transaction {
        try await repo.addTransaction(
            amount: amount,
            type: .expense,
            category: ordinaryCategory,
            account: account,
            date: date,
            note: "午餐"
        )
    }

    // MARK: - 调整流水：参与余额、退出统计、明细保留

    func test_adjustBalance_marksTransaction_and_participatesInBalance() throws {
        // 期初 100，对账到 80 → 应生成一笔 20 的 expense 调整流水，且余额确实变 80
        let tx = try repo.adjustBalance(account: account, newBalance: 80, note: nil)
        XCTAssertTrue(tx.isReconciliationAdjustment)
        XCTAssertEqual(tx.transactionType, .expense)
        XCTAssertEqual(repo.getAccountBalance(account), 80)
    }

    func test_statisticsExcludeAdjustment_whileDetailAndBalanceKeepIt() async throws {
        // 一笔普通支出 30 + 对账补差支出 20（期初 100 → 80）
        try await addOrdinaryExpense(30)
        try repo.adjustBalance(account: account, newBalance: 80, note: nil)

        let range = todayRange
        let statistics = try await repo.getStatisticsTransactions(from: range.start, to: range.end)
        let detail = try await repo.getTransactions(from: range.start, to: range.end)

        // 统计口径只有普通支出；明细两笔都在；余额两口都算
        XCTAssertEqual(statistics.count, 1)
        XCTAssertFalse(statistics[0].isReconciliationAdjustment)
        XCTAssertEqual(detail.count, 2)
        XCTAssertEqual(repo.getAccountBalance(account), 80)
    }

    func test_categoryAggregation_excludesAdjustment() async throws {
        try await addOrdinaryExpense(30)
        try repo.adjustBalance(account: account, newBalance: 80, note: nil)

        let range = todayRange
        let aggregations = try await repo.getCategoryAggregations(
            from: range.start, to: range.end, type: .expense
        )

        // 「余额调整」不进分类聚合，午餐 30 是唯一一笔
        XCTAssertEqual(aggregations.count, 1)
        XCTAssertEqual(aggregations[0].category.name, "午餐")
        XCTAssertEqual(aggregations[0].amount, 30)
    }

    // MARK: - 对账锚点四态

    func test_reconciliationStatus_neverReconciled() {
        if case .neverReconciled = repo.getReconciliationStatus(account) {} else {
            XCTFail("新账户应为 neverReconciled")
        }
    }

    func test_reconciliationStatus_reconciled_afterMarking() throws {
        try repo.adjustBalance(account: account, newBalance: 80, note: nil)
        repo.markReconciled(account, balance: repo.getAccountBalance(account))

        guard case let .reconciled(date, balance) = repo.getReconciliationStatus(account) else {
            XCTFail("对账后应为 reconciled")
            return
        }
        XCTAssertEqual(balance, 80)
        XCTAssertNotNil(date)
    }

    func test_reconciliationStatus_withActivity_afterNewTransactions() async throws {
        try repo.adjustBalance(account: account, newBalance: 80, note: nil)
        repo.markReconciled(account, balance: 80)

        // 锚点后的新账 → reconciledWithActivity，且调整流水本身不把状态打回 broken
        try await addOrdinaryExpense(25)

        guard case let .reconciledWithActivity(_, _, newCount) = repo.getReconciliationStatus(account) else {
            XCTFail("锚点后有新账应为 reconciledWithActivity")
            return
        }
        XCTAssertEqual(newCount, 1)
        XCTAssertEqual(repo.getAccountBalance(account), 55)
    }

    func test_reconciliationStatus_broken_whenEditingTransactionBeforeAnchor() async throws {
        try await addOrdinaryExpense(30)
        // 支出 30 后余额 70；对账到 65（生成 5 元调整流水），锚点记 65
        try repo.adjustBalance(account: account, newBalance: 65, note: nil)
        repo.markReconciled(account, balance: 65)

        // 改锚点前的账 → 理论锚点余额变化 → broken
        let range = todayRange
        let all = try await repo.getTransactions(from: range.start, to: range.end)
        guard let ordinary = all.first(where: { !$0.isReconciliationAdjustment }) else {
            XCTFail("找不到锚点前的普通交易")
            return
        }
        ordinary.amount = NSDecimalNumber(decimal: 10)
        try context.save()

        if case .broken = repo.getReconciliationStatus(account) {} else {
            XCTFail("修改锚点前的账应使基准失效")
        }
    }

    func test_reconciliationStatus_broken_whenSoftDeletingBeforeAnchor() async throws {
        try await addOrdinaryExpense(30)
        // 支出 30 后余额 70；对账到 65（生成 5 元调整流水），锚点记 65
        try repo.adjustBalance(account: account, newBalance: 65, note: nil)
        repo.markReconciled(account, balance: 65)

        let range = todayRange
        let all = try await repo.getTransactions(from: range.start, to: range.end)
        guard let ordinary = all.first(where: { !$0.isReconciliationAdjustment }) else {
            XCTFail("找不到锚点前的普通交易")
            return
        }
        ordinary.deletedAt = Date()
        try context.save()

        if case .broken = repo.getReconciliationStatus(account) {} else {
            XCTFail("软删锚点前的账应使基准失效")
        }
        // 余额口径随之排除软删交易：期初 100 − 调整 5 = 95
        XCTAssertEqual(repo.getAccountBalance(account), 95)
    }

    /// 调整流水 date 恒为「现在」且先于锚点写入：回溯锚点前净额时天然被包含，不破坏自洽。
    func test_anchor_selfConsistentAcrossOwnAdjustmentTransaction() throws {
        try repo.adjustBalance(account: account, newBalance: 80, note: nil)
        repo.markReconciled(account, balance: 80)
        if case .reconciled = repo.getReconciliationStatus(account) {} else {
            XCTFail("对账流水自身不得使锚点失效")
        }
    }

    // MARK: - updateAccount initialBalance

    func test_updateAccount_initialBalance_semantics() throws {
        // 不传 → 不改
        repo.updateAccount(account, name: "改名")
        XCTAssertEqual(account.initialBalance.decimalValue, 100)

        // 传 .some(.some(250)) → 改为 250，余额随之跳变
        try context.save()
        repo.updateAccount(account, initialBalance: .some(.some(250)))
        XCTAssertEqual(account.initialBalance.decimalValue, 250)
        XCTAssertEqual(repo.getAccountBalance(account), 250)

        // 改期初应使既有锚点失效（自洽检测会发现）
        repo.markReconciled(account, balance: 250)
        repo.updateAccount(account, initialBalance: .some(.some(300)))
        if case .broken = repo.getReconciliationStatus(account) {} else {
            XCTFail("改期初应使既有锚点失效")
        }
    }

    // MARK: - 存量迁移

    /// 对账功能上线前的旧「调整余额」交易（挂系统分类「余额调整」、无标记）应被一次性补上标记；
    /// flag 置位后迁移不再运行（幂等）。
    func test_migration_marksLegacyAdjustmentTransactions() throws {
        // 造旧数据：父分类「其他」+ 系统子分类「余额调整」+ 一笔挂它的无标记交易
        let parent = Holo.Category.create(
            in: context, name: "其他", icon: "circle", color: "#8E8E93",
            type: TransactionType.expense.rawValue
        )
        let adjustCategory = Holo.Category.create(
            in: context, name: "余额调整", icon: "arrow.triangle.2.circlepath", color: "#94A3B8",
            type: TransactionType.expense.rawValue, isDefault: true, sortOrder: 999,
            parentId: parent.id, isSystem: true
        )
        let legacy = Transaction(context: context)
        legacy.id = UUID()
        legacy.amount = NSDecimalNumber(decimal: 20)
        legacy.type = TransactionType.expense.rawValue
        legacy.category = adjustCategory
        legacy.account = account
        legacy.date = Date(timeIntervalSinceNow: -3600)
        legacy.note = "[余额调整]"
        legacy.createdAt = Date()
        legacy.updatedAt = Date()
        try context.save()
        XCTAssertFalse(legacy.isReconciliationAdjustment)

        // 重置迁移 flag → 直调迁移（不跑 setup()，避免实体模型污染）
        UserDefaults.standard.set(false, forKey: "hasMigratedReconciliationAdjustments_v1")
        repo.migrateLegacyReconciliationAdjustments()
        try context.save()
        XCTAssertTrue(legacy.isReconciliationAdjustment, "旧调整流水应被补上标记")

        // flag 已置位：之后新造的无标记旧式交易不再被迁移（幂等由 flag 保证）
        let latecomer = Transaction(context: context)
        latecomer.id = UUID()
        latecomer.amount = NSDecimalNumber(decimal: 5)
        latecomer.type = TransactionType.expense.rawValue
        latecomer.category = adjustCategory
        latecomer.account = account
        latecomer.date = Date(timeIntervalSinceNow: -1800)
        latecomer.note = "[余额调整]"
        latecomer.createdAt = Date()
        latecomer.updatedAt = Date()
        try context.save()

        repo.migrateLegacyReconciliationAdjustments()
        XCTAssertFalse(latecomer.isReconciliationAdjustment, "flag 置位后迁移不得重复运行")
    }

    // MARK: - 导入余额列（批次3）

    /// 银行流水余额列：千分位正数解析、负余额解析、无余额列为 nil
    func test_importBalanceColumnParsing() throws {
        let service = DataImportService.shared
        // 列布局：0 日期 / 1 类型 / 2 金额 / 3 余额
        let mapping = FieldMapping(
            dateIndex: 0, timeIndex: nil, typeIndex: 1, amountIndex: 2,
            primaryCategoryIndex: nil, subCategoryIndex: nil, accountIndex: nil,
            noteIndex: nil, descriptionIndex: nil, merchantIndex: nil, tagsIndex: nil,
            balanceIndex: 3
        )

        let positive = try service.parseRowForStream(
            ["2026-08-01", "支出", "36.50", "1,234.56"],
            mapping: mapping, template: .generic
        )
        XCTAssertEqual(positive.importBalance, Decimal(string: "1234.56"))

        let negative = try service.parseRowForStream(
            ["2026-08-02", "支出", "89.00", "-56.78"],
            mapping: mapping, template: .generic
        )
        XCTAssertEqual(negative.importBalance, Decimal(string: "-56.78"))

        // 不映射余额列 → nil（微信/支付宝账单无余额列的常态）
        let noBalanceMapping = FieldMapping(
            dateIndex: 0, timeIndex: nil, typeIndex: 1, amountIndex: 2,
            primaryCategoryIndex: nil, subCategoryIndex: nil, accountIndex: nil,
            noteIndex: nil, descriptionIndex: nil, merchantIndex: nil, tagsIndex: nil
        )
        let none = try service.parseRowForStream(
            ["2026-08-03", "支出", "12.00", "999.00"],
            mapping: noBalanceMapping, template: .generic
        )
        XCTAssertNil(none.importBalance)
    }
}
