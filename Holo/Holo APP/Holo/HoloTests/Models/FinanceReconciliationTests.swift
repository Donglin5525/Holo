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

    /// 进程唯一测试容器（CoreDataTestSupport R4-1 政策，2026-09-16 迁入）：
    /// 此前本类自建容器 load sharedModel——同模型反复 load 跨阈值会触发后续
    /// 测试类的实体映射歧义（fetch 失败被 try? 吞成 nil 的假失败）。
    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var account: Account!
    private var ordinaryCategory: Holo.Category!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Transaction", "Category", "Account"])

        repo = FinanceRepository(context: context)
        account = try repo.addAccount(name: "测试储蓄卡", type: .bank, initialBalance: 100)

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
        try repo.updateAccount(account, name: "改名")
        XCTAssertEqual(account.initialBalance.decimalValue, 100)

        // 传 .some(.some(250)) → 改为 250，余额随之跳变
        try context.save()
        try repo.updateAccount(account, initialBalance: .some(.some(250)))
        XCTAssertEqual(account.initialBalance.decimalValue, 250)
        XCTAssertEqual(repo.getAccountBalance(account), 250)

        // 改期初应使既有锚点失效（自洽检测会发现）
        repo.markReconciled(account, balance: 250)
        try repo.updateAccount(account, initialBalance: .some(.some(300)))
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

// MARK: - 退款关联套件（P0 手动链路 + 统计冲减口径 + AI 候选匹配）

extension FinanceReconciliationTests {

    @discardableResult
    private func addRefundableExpense(
        _ amount: Decimal,
        date: Date = Date(),
        note: String? = "买衣服"
    ) async throws -> Transaction {
        try await repo.addTransaction(
            amount: amount,
            type: .expense,
            category: ordinaryCategory,
            account: account,
            date: date,
            note: note
        )
    }

    /// 全额退款：统计冲减到零、不进收入、余额不变式、分类沿用原交易
    func test_refund_fullAmount_netsStatisticsOutAndKeepsBalance() async throws {
        let original = try await addRefundableExpense(500)
        let refund = try await repo.addRefundTransaction(original: original, amount: 500)

        XCTAssertTrue(refund.isRefund)
        XCTAssertEqual(refund.transactionType, .income, "物理类型 income：余额层加回")
        XCTAssertEqual(refund.statisticsType, .expense, "统计口径：按支出侧冲减")
        XCTAssertEqual(refund.statisticsAmount, -500)
        XCTAssertEqual(refund.refundOfTransactionId, original.id)
        XCTAssertEqual(refund.category?.id, original.category?.id, "分类沿用原交易，冲减归属正确")

        let summaries = try await repo.getDailySummaries(for: Date())
        let today = summaries[Calendar.current.startOfDay(for: Date())]
        XCTAssertEqual(today?.totalExpense, 0, "当日支出净额归零")
        XCTAssertEqual(today?.totalIncome, 0, "退款不进收入统计")

        let range = todayRange
        let aggregations = try await repo.getCategoryAggregations(from: range.start, to: range.end, type: .expense)
        XCTAssertEqual(aggregations.first?.amount, 0, "分类聚合按净额")

        XCTAssertEqual(repo.getAccountBalance(account), 100, "余额不变式：期初100 -500 +500")
    }

    /// 多次部分退款 + 累计超额拦截
    func test_refund_partialMultiple_cumulativeOverflowRejected() async throws {
        let original = try await addRefundableExpense(500)
        try await repo.addRefundTransaction(original: original, amount: 300)

        do {
            _ = try await repo.addRefundTransaction(original: original, amount: 250)
            XCTFail("累计超额（300+250>500）应被拦截")
        } catch let error as FinanceError {
            guard case .refundExceedsOriginal = error else {
                return XCTFail("应抛 refundExceedsOriginal，实际 \(error)")
            }
        }

        let refunds = try await repo.getRefunds(for: original)
        XCTAssertEqual(refunds.count, 1, "超额那笔未落库")
        let total = try await repo.totalRefunded(for: original)
        XCTAssertEqual(total, 300)
    }

    /// 编辑退款笔改大金额：排除自身后累计校验，守住不超原额
    func test_refundEdit_amountBeyondRemaining_rejected() async throws {
        let original = try await addRefundableExpense(500)
        let refundA = try await repo.addRefundTransaction(original: original, amount: 300)
        _ = try await repo.addRefundTransaction(original: original, amount: 150) // 累计 450 ≤ 500

        // 把 A 改成 400：另一笔 150 + 400 = 550 > 500，应拦截（校验须排除 A 自身的旧值）
        var updates = TransactionUpdates()
        updates.amount = 400
        do {
            try await repo.updateTransaction(refundA, updates: updates)
            XCTFail("编辑后累计超额（150+400>500）应被拦截")
        } catch let error as FinanceError {
            guard case .refundExceedsOriginal = error else {
                return XCTFail("应抛 refundExceedsOriginal，实际 \(error)")
            }
        }
        XCTAssertEqual(refundA.amountAsDecimal, 300, "原值未被改写")

        // 合法区间放行：A 改成 180（150+180=330 ≤ 500）
        updates.amount = 180
        try await repo.updateTransaction(refundA, updates: updates)
        XCTAssertEqual(refundA.amountAsDecimal, 180)
    }

    /// 非支出原交易 / 分期原交易：拒绝发起退款
    func test_refund_rejectsIncomeAndInstallmentOriginals() async throws {
        // 收入侧二级分类
        let incomeParent = Holo.Category.create(
            in: context, name: "其他收入", icon: "circle", color: "#8E8E93",
            type: TransactionType.income.rawValue
        )
        let incomeCategory = Holo.Category.create(
            in: context, name: "退款", icon: "arrow.uturn.backward", color: "#34C759",
            type: TransactionType.income.rawValue, parentId: incomeParent.id
        )
        let income = try await repo.addTransaction(
            amount: 100, type: .income, category: incomeCategory, account: account
        )
        do {
            _ = try await repo.addRefundTransaction(original: income, amount: 100)
            XCTFail("收入交易不可发起退款")
        } catch let error as FinanceError {
            guard case .invalidData = error else {
                return XCTFail("应抛 invalidData，实际 \(error)")
            }
        }

        // 分期交易不可发起退款
        let installmentGroup = try await repo.addInstallmentTransactions(
            totalAmount: 600, feePerPeriod: 0, periods: 3,
            type: .expense, category: ordinaryCategory, account: account,
            startDate: Date(), note: "手机"
        )
        do {
            _ = try await repo.addRefundTransaction(original: installmentGroup[0], amount: 200)
            XCTFail("分期交易一期不可发起退款")
        } catch let error as FinanceError {
            guard case .invalidData = error else {
                return XCTFail("应抛 invalidData，实际 \(error)")
            }
        }
    }

    /// 跨月退款：冲退款到账当月，原交易当月保持原样（拍板口径）
    func test_refund_crossMonth_reducesRefundMonthOnly() async throws {
        let cal = Calendar.current
        // 40 天前必跨月（> 一个月最大 31 天）
        let originalDate = cal.date(byAdding: .day, value: -40, to: Date())!
        let original = try await addRefundableExpense(500, date: originalDate)
        try await repo.addRefundTransaction(original: original, amount: 500)

        // 退款当月（本月）：支出净额为 -500（本月只有退款笔）
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
        let monthTxns = try await repo.getStatisticsTransactions(from: monthStart, to: monthEnd)
        let monthExpense = monthTxns
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        XCTAssertEqual(monthExpense, -500, "本月支出被退款冲成负值")

        // 原交易当月：保持 500 不漂移
        let origMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: originalDate))!
        let origMonthEnd = cal.date(byAdding: .month, value: 1, to: origMonthStart)!
        let origTxns = try await repo.getStatisticsTransactions(from: origMonthStart, to: origMonthEnd)
        let origExpense = origTxns
            .filter { $0.statisticsType == .expense }
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
        XCTAssertEqual(origExpense, 500, "原交易当月报表不动")
    }

    /// 原交易被删（悬空）：退款笔继续按自身分类冲减，统计不崩
    func test_refund_originalDeleted_danglingStillReducesOwnCategory() async throws {
        let original = try await addRefundableExpense(500)
        let refund = try await repo.addRefundTransaction(original: original, amount: 200)
        try await repo.deleteTransaction(original)

        XCTAssertTrue(refund.isRefund, "悬空不影响退款笔身份")
        let range = todayRange
        let aggregations = try await repo.getCategoryAggregations(from: range.start, to: range.end, type: .expense)
        XCTAssertEqual(aggregations.first?.amount, -200, "悬空退款继续按自身分类冲减")
    }

    /// 原交易改金额护栏：不得低于名下退款累计（否则「已退 > 原额」脏账）
    func test_originalEdit_amountBelowRefunded_rejected() async throws {
        let original = try await addRefundableExpense(500)
        try await repo.addRefundTransaction(original: original, amount: 300)

        var updates = TransactionUpdates()
        updates.amount = 250
        do {
            try await repo.updateTransaction(original, updates: updates)
            XCTFail("已退 300，原额改 250 应被拦截")
        } catch let error as FinanceError {
            guard case .originalBelowRefunded = error else {
                return XCTFail("应抛 originalBelowRefunded，实际 \(error)")
            }
        }
        XCTAssertEqual(original.amountAsDecimal, 500, "原值未被改写")

        // 等于已退累计放行（刚好退满）
        updates.amount = 300
        try await repo.updateTransaction(original, updates: updates)
        XCTAssertEqual(original.amountAsDecimal, 300)

        // 无退款笔的普通交易改金额不受护栏影响
        let plain = try await addRefundableExpense(100)
        updates.amount = 1
        try await repo.updateTransaction(plain, updates: updates)
        XCTAssertEqual(plain.amountAsDecimal, 1)
    }

    /// 原交易改分类联动退款笔：冲减归属必须跟着新分类走，否则冲错分类
    func test_originalEdit_categoryChange_syncsRefunds() async throws {
        let original = try await addRefundableExpense(500)
        let refundA = try await repo.addRefundTransaction(original: original, amount: 300)
        _ = try await repo.addRefundTransaction(original: original, amount: 200)

        // 另一个支出二级分类
        let otherParent = Holo.Category.create(
            in: context, name: "购物", icon: "bag", color: "#FF2D55",
            type: TransactionType.expense.rawValue
        )
        let otherCategory = Holo.Category.create(
            in: context, name: "服饰", icon: "bag", color: "#FF2D55",
            type: TransactionType.expense.rawValue, parentId: otherParent.id
        )
        try? context.save()

        var updates = TransactionUpdates()
        updates.category = otherCategory
        try await repo.updateTransaction(original, updates: updates)

        let refunds = try await repo.getRefunds(for: original)
        XCTAssertEqual(refunds.count, 2)
        for refund in refunds {
            XCTAssertEqual(refund.category?.id, otherCategory.id, "退款笔分类随原交易同步")
        }
        XCTAssertEqual(refundA.category?.id, otherCategory.id)

        // 冲减归属落新分类：原交易本体(+500)与退款冲减(-500)都在服饰，净额归零；
        // 若退款笔未联动，它仍挂旧分类，旧分类会出现 -500 的负冲减
        let range = todayRange
        let aggregations = try await repo.getCategoryAggregations(from: range.start, to: range.end, type: .expense)
        let shopping = aggregations.first { $0.category.id == otherCategory.id }
        XCTAssertEqual(shopping?.amount, 0, "原交易与退款冲减同归新分类，净额为零")
        let oldCategoryEntry = aggregations.first { $0.category.id == ordinaryCategory.id }
        XCTAssertEqual(oldCategoryEntry?.amount ?? 0, 0, "旧分类不再有任何冲减残留")
    }

    /// 退款笔备注：新建带备注 + 编辑改备注 / 清空（空串=清空约定）
    func test_refundRemark_persistedThroughCreateAndEdit() async throws {
        let original = try await addRefundableExpense(500)
        let refund = try await repo.addRefundTransaction(
            original: original, amount: 100, remark: "退运费"
        )
        XCTAssertEqual(refund.remark, "退运费")

        var updates = TransactionUpdates()
        updates.remark = "部分退款"
        try await repo.updateTransaction(refund, updates: updates)
        XCTAssertEqual(refund.remark, "部分退款")

        updates.remark = ""
        try await repo.updateTransaction(refund, updates: updates)
        XCTAssertNil(refund.remark, "空串=清空备注")
    }

    /// 预算已花的冲减口径与统计层同源（refundOf 谓词 + statisticsAmount），
    /// BudgetRepository 为不可注入的单例（全局库），此处无法隔离验证——
    /// 预算回补正确性由模拟器走查「统计页 vs 预算页数字一致」人工核对。

    /// AI 候选匹配：金额精确 + 关键词命中优先；金额不足的支出不可能入选
    func test_findRefundCandidates_prefersExactAmountAndKeyword() async throws {
        let clothes = try await addRefundableExpense(500, note: "买衣服")
        _ = try await addRefundableExpense(500, date: Date().addingTimeInterval(-86400), note: "买裤子")
        _ = try await addRefundableExpense(120, note: "买菜")

        let candidates = try await repo.findRefundCandidates(amount: 500, keyword: "衣服")
        XCTAssertEqual(candidates.first?.id, clothes.id, "关键词命中的同额支出排第一")
        XCTAssertFalse(candidates.contains { $0.note == "买菜" }, "原额不足退款额的支出不可能被退")
        XCTAssertFalse(candidates.contains { $0.isRefund }, "退款笔自身不可再被退")
    }

    /// 删除退款笔 = 解除关联：原交易统计口径还原
    func test_refundDelete_restoresOriginalStatistics() async throws {
        let original = try await addRefundableExpense(500)
        let refund = try await repo.addRefundTransaction(original: original, amount: 300)
        try await repo.deleteTransaction(refund)

        let refunds = try await repo.getRefunds(for: original)
        XCTAssertTrue(refunds.isEmpty, "删除即解除关联")
        let range = todayRange
        let aggregations = try await repo.getCategoryAggregations(from: range.start, to: range.end, type: .expense)
        XCTAssertEqual(aggregations.first?.amount, 500, "冲减随删除还原")
    }
}
