//
//  BudgetRepositoryTests.swift
//  HoloTests
//
//  预算口径回归套件（2026-10 预算不动 BUG 收口）：
//  - 口径：挂项目的支出计入总预算/分类预算（计算层从不排除项目交易）
//  - 口径：预算绑账户——他账户消费不进本账户预算；全局汇总只含有预算账户
//  - 口径：退款负冲、老 startDate 周期推进、未来流水不计入（与统计入口同源 occurredPredicate）
//  - 通知契约：交易写方法落库后广播 .financeDataDidChange 恰好一次（单一水龙头）
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class BudgetRepositoryTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var projectRepo: FinanceProjectRepository!
    private var budgetRepo: BudgetRepository!
    private var cashAccount: Account!
    private var wechatAccount: Account!
    private var parentCategory: Holo.Category!
    private var lunchCategory: Holo.Category!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Transaction", "Category", "Account", "Budget", "FinanceProject"])

        repo = FinanceRepository(context: context)
        projectRepo = FinanceProjectRepository(finance: repo)
        budgetRepo = BudgetRepository(testContext: context)
        // 全局聚合默认走生产单例账户清单，测试替换为内存栈仓库以隔离
        let testRepo = repo!
        budgetRepo.accountsProvider = { testRepo.getAccounts(includeArchived: false) }

        cashAccount = try repo.addAccount(name: "现金", type: .cash, initialBalance: 0)
        wechatAccount = try repo.addAccount(name: "微信支付", type: .digital, initialBalance: 0)

        parentCategory = Holo.Category.create(
            in: context, name: "餐饮", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue
        )
        lunchCategory = Holo.Category.create(
            in: context, name: "午餐", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue, parentId: parentCategory.id
        )
        try? context.save()
    }

    // MARK: - Helpers

    @discardableResult
    private func addExpense(
        _ amount: Decimal,
        account: Account,
        project: FinanceProject? = nil,
        date: Date = Date()
    ) async throws -> Transaction {
        try await repo.addTransaction(
            amount: amount, type: .expense, category: lunchCategory,
            account: account, date: date, note: nil, financeProject: project
        )
    }

    /// 当月总预算的已花金额
    private func spentOfTotalBudget(account: Account) -> Decimal {
        let budget = budgetRepo.getTotalBudget(forAccount: account.id, period: .month)
        XCTAssertNotNil(budget, "setUp 里应已设置月度总预算")
        return budgetRepo.computeBudgetStatus(budget: budget!)!.spentAmount
    }

    /// 监听 .financeDataDidChange 的计数器（post 与 await 边界同步，计数无需额外等待）
    private final class ChangeNotificationCounter {
        private(set) var count = 0
        private var token: NSObjectProtocol?

        init() {
            token = NotificationCenter.default.addObserver(
                forName: .financeDataDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                self?.count += 1
            }
        }

        deinit {
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    // MARK: - 口径：项目交易参与预算（本 BUG 的核心钉子）

    func test_projectExpense_countsInTotalBudget() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: monthStart())
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")

        try await addExpense(3_500, account: cashAccount, project: project)
        try await addExpense(1_200, account: cashAccount, project: project)
        try await addExpense(80, account: cashAccount)

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 4_780, "挂项目的支出必须按普通消费计入总预算已花")
    }

    func test_projectExpense_countsInCategoryBudget() async throws {
        // 分类预算挂在父分类（餐饮），项目消费记在子分类（午餐）——父子匹配必须命中
        try budgetRepo.addCategoryBudget(
            accountId: cashAccount.id, categoryId: parentCategory.id,
            amount: 5_000, period: .month, startDate: monthStart()
        )
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")

        try await addExpense(2_600, account: cashAccount, project: project)

        let budget = budgetRepo.getCategoryBudget(
            forAccount: cashAccount.id, categoryId: parentCategory.id, period: .month
        )
        XCTAssertNotNil(budget)
        XCTAssertEqual(budgetRepo.computeBudgetStatus(budget: budget!)!.spentAmount, 2_600, "挂项目的支出必须计入分类预算（含父子分类匹配）")
    }

    func test_projectRefund_offsetsBudgetSpent() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: monthStart())
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")

        let original = try await addExpense(1_000, account: cashAccount, project: project)
        _ = try await repo.addRefundTransaction(original: original, amount: 400)

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 600, "挂项目交易的退款应负冲预算已花（退款挂靠继承原交易）")
    }

    // MARK: - 口径：预算绑账户

    func test_expenseOnOtherAccount_doesNotAffectBudget() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: monthStart())
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")

        // 微信账户没有预算：记在上面的项目消费不进现金账户预算（产品口径：预算绑账户）
        try await addExpense(9_999, account: wechatAccount, project: project)
        try await addExpense(100, account: cashAccount)

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 100, "他账户消费不得计入本账户预算")
    }

    func test_globalSummary_sumsOnlyAccountsWithBudget() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 5_000, period: .month, startDate: monthStart())
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")

        try await addExpense(1_000, account: cashAccount, project: project)
        try await addExpense(2_000, account: wechatAccount) // 无预算账户的消费

        let summary = budgetRepo.computeGlobalTotalBudgetStatus(period: .month)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary!.totalBudgetAmount, 5_000, "全局额度只含有预算账户")
        XCTAssertEqual(summary!.totalSpentAmount, 1_000, "全局已花只统计有预算账户内的消费")
    }

    // MARK: - 口径：周期窗口与已发生边界

    func test_budgetWithLegacyStartDate_coversCurrentMonth() async throws {
        // startDate 在半年前：周期应循环推进到包含今天，而不是停在旧周期
        let legacyStart = Calendar.current.date(byAdding: .month, value: -6, to: monthStart())!
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: legacyStart)

        try await addExpense(300, account: cashAccount)

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 300, "老 startDate 的月预算必须推进到当月并统计今天的支出")
    }

    func test_futureDatedExpense_excludedFromBudget() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: monthStart())

        let tomorrow = Date().addingTimeInterval(86_400)
        try await addExpense(500, account: cashAccount, date: tomorrow)
        try await addExpense(90, account: cashAccount, date: Date().addingTimeInterval(-3_600))

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 90, "未来日期的预记账不计入预算已花（与统计入口同源 occurredPredicate）")
    }

    func test_installment_onlyOccurredPeriodsCountInBudget() async throws {
        try budgetRepo.addBudget(accountId: cashAccount.id, amount: 10_000, period: .month, startDate: monthStart())

        // 3 期分期从当月开始：第 1 期今天已发生，第 2、3 期在未来月份（也不在当月周期窗内）
        _ = try await repo.addInstallmentTransactions(
            totalAmount: 3_000, feePerPeriod: 0, periods: 3, type: .expense,
            category: lunchCategory, account: cashAccount,
            startDate: monthStart(), note: "相机分期"
        )

        XCTAssertEqual(spentOfTotalBudget(account: cashAccount), 1_000, "分期组只有已发生且落在当期周期内的期数计入预算已花")
    }

    // MARK: - 通知契约（单一水龙头：写方法落库后恰好广播一次）

    func test_addTransaction_broadcastsExactlyOnce() async throws {
        let counter = ChangeNotificationCounter()
        _ = try await addExpense(30, account: cashAccount)
        XCTAssertEqual(counter.count, 1, "新增交易落库后应恰好广播一次（多了浪费重算，少了全 App 不刷新）")
    }

    func test_updateTransaction_broadcastsOnce() async throws {
        let tx = try await addExpense(30, account: cashAccount)

        let counter = ChangeNotificationCounter()
        var updates = TransactionUpdates()
        updates.amount = 45
        try await repo.updateTransaction(tx, updates: updates)
        XCTAssertEqual(counter.count, 1, "编辑交易落库后应广播一次")
    }

    func test_deleteTransaction_broadcastsOnce() async throws {
        let tx = try await addExpense(30, account: cashAccount)

        let counter = ChangeNotificationCounter()
        try await repo.deleteTransaction(tx)
        XCTAssertEqual(counter.count, 1, "删除交易落库后应广播一次")
    }

    func test_addRefundTransaction_broadcastsOnce() async throws {
        let original = try await addExpense(100, account: cashAccount)

        let counter = ChangeNotificationCounter()
        _ = try await repo.addRefundTransaction(original: original, amount: 20)
        XCTAssertEqual(counter.count, 1, "记退款落库后应广播一次")
    }

    func test_addInstallmentTransactions_broadcastsOnceForWholeGroup() async throws {
        let counter = ChangeNotificationCounter()
        _ = try await repo.addInstallmentTransactions(
            totalAmount: 3_000, feePerPeriod: 0, periods: 12, type: .expense,
            category: lunchCategory, account: cashAccount,
            startDate: monthStart(), note: "12 期分期"
        )
        XCTAssertEqual(counter.count, 1, "分期组逐笔落库不得逐笔广播，整组恰好一次")
    }

    func test_bookTransactionAtomically_skipsBroadcastOnIdempotentHit() async throws {
        let counter = ChangeNotificationCounter()
        let first = try repo.bookTransactionAtomically(
            amount: 66, type: .expense, category: lunchCategory, account: cashAccount,
            date: Date(), note: nil, remark: nil, financeProjectId: nil,
            aiCandidate: nil, aiSourceMessageId: "msg-1", aiSourceItemId: "item-1"
        )
        XCTAssertTrue(first.created)

        // 同一 AI 消息条目重放：幂等命中，不落新库也不广播
        let second = try repo.bookTransactionAtomically(
            amount: 66, type: .expense, category: lunchCategory, account: cashAccount,
            date: Date(), note: nil, remark: nil, financeProjectId: nil,
            aiCandidate: nil, aiSourceMessageId: "msg-1", aiSourceItemId: "item-1"
        )
        XCTAssertFalse(second.created)
        XCTAssertEqual(counter.count, 1, "幂等命中不产生新数据，不得重复广播")
    }

    // MARK: - 工具

    private func monthStart() -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }
}
