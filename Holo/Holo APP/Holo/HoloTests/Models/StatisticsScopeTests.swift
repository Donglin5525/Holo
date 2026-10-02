//
//  StatisticsScopeTests.swift
//  HoloTests
//
//  统计维度筛选（账户/项目下钻）数据层单测：
//  - scope 谓词：单账户 / 单项目 / 交集 / 默认全量（既有消费点零回归）
//  - 归档账户可选可筛（历史交易不消失）
//  - 账户/项目排行聚合：降序、占比、退款负冲、已删项目剔除
//  - 单账户累计余额（账户维度余额线起点）
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class StatisticsScopeTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var projectRepo: FinanceProjectRepository!
    private var cashAccount: Account!
    private var wechatAccount: Account!
    private var lunchCategory: Holo.Category!

    /// 统计时间窗：过去 1 小时 ~ 未来 1 小时（造数都落在「已发生」口径内）
    private var window: (start: Date, end: Date) {
        (Date().addingTimeInterval(-3600), Date().addingTimeInterval(3600))
    }

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Transaction", "Category", "Account", "Budget", "FinanceProject"])

        repo = FinanceRepository(context: context)
        projectRepo = FinanceProjectRepository(finance: repo)
        cashAccount = repo.addAccount(name: "现金", type: .cash, initialBalance: 0)
        wechatAccount = repo.addAccount(name: "微信支付", type: .digital, initialBalance: 0)

        let parentCategory = Holo.Category.create(
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

    private func statisticsIds(scope: StatisticsScope) async throws -> [UUID] {
        let w = window
        let txns = try await repo.getStatisticsTransactions(from: w.start, to: w.end, scope: scope)
        return txns.map { $0.id }
    }

    // MARK: - scope 谓词

    func test_scope_accountFilter_returnsOnlyThatAccount() async throws {
        let t1 = try await addExpense(30, account: cashAccount)
        let t2 = try await addExpense(50, account: wechatAccount)

        let ids = try await statisticsIds(scope: StatisticsScope(accountId: cashAccount.id, financeProjectId: nil))
        XCTAssertEqual(Set(ids), [t1.id], "账户筛选只应收该账户的交易")
    }

    func test_scope_projectFilter_returnsOnlyProjectTransactions() async throws {
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")
        let t1 = try await addExpense(100, account: cashAccount, project: project)
        _ = try await addExpense(20, account: cashAccount)

        let ids = try await statisticsIds(scope: StatisticsScope(accountId: nil, financeProjectId: project.id))
        XCTAssertEqual(Set(ids), [t1.id], "项目筛选只收回挂靠该项目的交易")
    }

    func test_scope_accountAndProject_intersect() async throws {
        let project = try projectRepo.create(name: "装修", icon: "🔨", color: "#8B5CF6")
        let t1 = try await addExpense(100, account: cashAccount, project: project)     // 命中交集
        _ = try await addExpense(80, account: cashAccount)                              // 只命中账户
        _ = try await addExpense(60, account: wechatAccount, project: project)          // 只命中项目

        let scope = StatisticsScope(accountId: cashAccount.id, financeProjectId: project.id)
        let ids = try await statisticsIds(scope: scope)
        XCTAssertEqual(Set(ids), [t1.id], "账户+项目同时筛选应取交集")
    }

    func test_scope_defaultAll_returnsEverything_zeroRegression() async throws {
        let t1 = try await addExpense(30, account: cashAccount)
        let t2 = try await addExpense(50, account: wechatAccount)

        // 不传 scope（既有消费点的调用形态）必须等价于全量
        let w = window
        let defaultTxns = try await repo.getStatisticsTransactions(from: w.start, to: w.end)
        XCTAssertEqual(Set(defaultTxns.map { $0.id }), [t1.id, t2.id])
        let allTxns = try await repo.getStatisticsTransactions(from: w.start, to: w.end, scope: .all)
        XCTAssertEqual(Set(allTxns.map { $0.id }), [t1.id, t2.id])
    }

    func test_scope_archivedAccount_stillSelectable() async throws {
        let oldCard = repo.addAccount(name: "旧储蓄卡", type: .bank, initialBalance: 0)
        let t1 = try await addExpense(120, account: oldCard)
        try repo.archiveAccount(oldCard)

        let ids = try await statisticsIds(scope: StatisticsScope(accountId: oldCard.id, financeProjectId: nil))
        XCTAssertEqual(Set(ids), [t1.id], "归档账户的历史交易在选中它时必须可见")
    }

    // MARK: - 排行聚合

    func test_accountAggregations_rankByExpenseDescending() async throws {
        try await addExpense(30, account: cashAccount)
        try await addExpense(80, account: wechatAccount)
        try await addExpense(20, account: cashAccount)

        let w = window
        let rankings = try await repo.getAccountAggregations(from: w.start, to: w.end)

        XCTAssertEqual(rankings.count, 2)
        XCTAssertEqual(rankings[0].account.id, wechatAccount.id, "微信 80 应排第一")
        XCTAssertEqual(rankings[0].expense, 80)
        XCTAssertEqual(rankings[0].income, 0)
        XCTAssertEqual(rankings[1].account.id, cashAccount.id, "现金 30+20=50 第二")
        XCTAssertEqual(rankings[1].expense, 50)
        // 占比 = 占本期总支出（130），与汇总卡口径一致
        XCTAssertEqual(rankings[0].percentage, 80.0 * 100 / 130, accuracy: 0.01)
        XCTAssertEqual(rankings[1].percentage, 50.0 * 100 / 130, accuracy: 0.01)
    }

    func test_accountAggregations_refundOffsetsExpense() async throws {
        let t1 = try await addExpense(100, account: wechatAccount)
        // 退款笔：物理上是 income，但统计口径按负支出冲减该账户
        let refund = Transaction(context: context)
        refund.id = UUID()
        refund.amount = NSDecimalNumber(decimal: 40)
        refund.type = TransactionType.income.rawValue
        refund.category = lunchCategory
        refund.account = wechatAccount
        refund.date = Date()
        refund.refundOfTransactionId = t1.id
        try context.save()

        let w = window
        let rankings = try await repo.getAccountAggregations(from: w.start, to: w.end)

        XCTAssertEqual(rankings.first { $0.account.id == wechatAccount.id }?.expense, 60, "退款应负冲该账户支出：100-40=60")
    }

    func test_financeProjectAggregations_excludeDeletedProject() async throws {
        let tokyo = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")
        let decor = try projectRepo.create(name: "装修", icon: "🔨", color: "#8B5CF6")
        try await addExpense(100, account: cashAccount, project: tokyo)
        try await addExpense(80, account: cashAccount, project: decor)
        try await addExpense(20, account: cashAccount)

        try projectRepo.deleteProject(decor)

        let w = window
        let rankings = try await repo.getFinanceProjectAggregations(from: w.start, to: w.end)

        XCTAssertEqual(rankings.count, 1, "已删项目的挂靠交易不计入排行")
        XCTAssertEqual(rankings[0].project.id, tokyo.id)
        XCTAssertEqual(rankings[0].expense, 100)
        // 占比分母 = 本期总支出（200，含挂已删项目的 80 与未挂项目的 20），
        // 与汇总卡口径一致；排行只展示仍存在的项目
        XCTAssertEqual(rankings[0].percentage, 50, accuracy: 0.01)
    }

    func test_financeProjectAggregations_scopeSlicedByAccount() async throws {
        let tokyo = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500")
        try await addExpense(100, account: cashAccount, project: tokyo)
        try await addExpense(60, account: wechatAccount, project: tokyo)

        let w = window
        let rankings = try await repo.getFinanceProjectAggregations(
            from: w.start, to: w.end,
            scope: StatisticsScope(accountId: wechatAccount.id, financeProjectId: nil)
        )

        XCTAssertEqual(rankings.first?.expense, 60, "账户切片下的项目排行只算该账户支出")
    }

    // MARK: - 分类聚合带维度

    func test_topLevelCategoryAggregations_respectScope() async throws {
        try await addExpense(30, account: cashAccount)
        try await addExpense(50, account: wechatAccount)

        let w = window
        let aggAll = try await repo.getTopLevelCategoryAggregations(from: w.start, to: w.end, type: .expense)
        let aggScoped = try await repo.getTopLevelCategoryAggregations(
            from: w.start, to: w.end, type: .expense,
            scope: StatisticsScope(accountId: wechatAccount.id, financeProjectId: nil)
        )

        XCTAssertEqual(aggAll.first?.amount, 80)
        XCTAssertEqual(aggScoped.first?.amount, 50, "维度筛选下的分类聚合只算该维度金额")
    }

    // MARK: - 账户维度余额线起点

    func test_accountCumulativeBalance_initialPlusPriorFlow() async throws {
        let card = repo.addAccount(name: "储蓄卡", type: .bank, initialBalance: 1000)
        // 时间窗起点之前的交易：+200
        try await repo.addTransaction(
            amount: 200, type: .income, category: lunchCategory,
            account: card, date: Date().addingTimeInterval(-86400 * 10), note: nil
        )
        // 窗内交易（不应计入起点）
        try await addExpense(30, account: card)

        let start = Date().addingTimeInterval(-3600)
        let balance = repo.getAccountCumulativeBalance(accountId: card.id, before: start)
        XCTAssertEqual(balance, 1200, "账户余额线起点 = initialBalance + 窗口前净流，窗内交易不计入")
    }

    func test_accountCumulativeBalance_unknownAccountIsZero() {
        let balance = repo.getAccountCumulativeBalance(accountId: UUID(), before: Date())
        XCTAssertEqual(balance, 0)
    }

    // MARK: - 项目全程区间（「看项目全程」）

    func test_projectSpan_prefersStoredDates() throws {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 18))!
        let end = cal.date(from: DateComponents(year: 2026, month: 9, day: 26))!
        let project = try projectRepo.create(name: "东京旅行", icon: "🗾", color: "#FF9500", note: nil, startDate: start, endDate: end, budgetAmount: nil)

        // 存储起止日齐全：直接采用（不依赖交易）
        let span = projectRepo.projectSpan(of: project)
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.start, cal.startOfDay(for: start))
        // end 为排他上界：endDate 当天的次日零点
        XCTAssertEqual(span?.end, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)))
    }

    func test_projectSpan_backfillsFromTransactionsWhenDatesMissing() async throws {
        // AI/手动建的项目常没填期间：按首末笔支出日期补齐
        let project = try projectRepo.create(name: "装修", icon: "🔨", color: "#8B5CF6")
        let cal = Calendar.current
        let first = cal.date(byAdding: .day, value: -20, to: Date())!
        let last = cal.date(byAdding: .day, value: -2, to: Date())!
        try await addExpense(100, account: cashAccount, project: project, date: first)
        try await addExpense(80, account: cashAccount, project: project, date: last)

        let span = projectRepo.projectSpan(of: project)
        XCTAssertEqual(span?.start, cal.startOfDay(for: first))
        XCTAssertEqual(span?.end, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)))
    }

    func test_projectSpan_emptyProjectReturnsNil() throws {
        // 无交易且无期间：没有全程可言
        let project = try projectRepo.create(name: "空项目", icon: "🫙", color: "#64748B")
        XCTAssertNil(projectRepo.projectSpan(of: project))
    }
}
