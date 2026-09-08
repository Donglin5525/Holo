//
//  FinanceProjectRepositoryTests.swift
//  HoloTests
//
//  财务项目（批次1 数据层）单测：
//  - 项目 CRUD 与状态流转
//  - 交易挂靠 / 批量补挂 / 解除
//  - 删除项目只解除关联，交易一律不动
//  - 口径零污染：挂项目的交易照常参与全局统计；项目聚合只认「已发生 + 排对账调整 + 仅支出」
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class FinanceProjectRepositoryTests: XCTestCase {

    /// 进程级共享容器（与 FinanceReconciliationTests 同款理由：避免反复 load 模型触发不兼容错误）
    private static let sharedContainer: NSPersistentContainer = {
        let model = CoreDataTestSupport.sharedModel
        let container = NSPersistentContainer(name: "FinanceProjectTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: FinanceRepository!
    private var projectRepo: FinanceProjectRepository!
    private var account: Account!
    private var lunchCategory: Holo.Category!

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext

        // 清空上一用例数据（in-memory store 不支持 batch delete，逐实体 fetch+delete）
        for entityName in ["Transaction", "Category", "Account", "Budget", "FinanceProject"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in (try? context.fetch(request)) ?? [] {
                context.delete(object)
            }
        }
        try? context.save()

        repo = FinanceRepository(context: context)
        projectRepo = FinanceProjectRepository(finance: repo)
        account = repo.addAccount(name: "现金", type: .cash, initialBalance: 0)

        // 普通交易分类必须是二级（validateTransactionCategory 的规则）
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
    private func makeProject(name: String = "东京旅行", budget: Decimal? = nil) throws -> FinanceProject {
        try projectRepo.create(
            name: name, icon: "🗾", color: "#FF9500",
            note: nil, startDate: nil, endDate: nil, budgetAmount: budget
        )
    }

    @discardableResult
    private func addExpense(_ amount: Decimal, date: Date = Date(), project: FinanceProject? = nil) async throws -> Transaction {
        try await repo.addTransaction(
            amount: amount, type: .expense, category: lunchCategory,
            account: account, date: date, note: "拉面", financeProject: project
        )
    }

    // MARK: - 创建与查询

    func test_create_trimsName_and_findRoundtrip() throws {
        let project = try makeProject(name: "  东京旅行  ")
        XCTAssertEqual(project.name, "东京旅行")
        XCTAssertEqual(project.statusEnum, .active)
        XCTAssertEqual(projectRepo.findProject(by: project.id)?.id, project.id)
    }

    func test_create_emptyNameThrows() throws {
        XCTAssertThrowsError(try makeProject(name: "   "))
    }

    func test_activeProjects_excludesCompleted() throws {
        let active = try makeProject(name: "进行中")
        let done = try makeProject(name: "已完结")
        try projectRepo.updateStatus(done, status: .completed)

        XCTAssertEqual(projectRepo.activeProjects().map(\.id), [active.id])
    }

    // MARK: - 记账挂项目

    func test_addTransaction_withProject_setsId() async throws {
        let project = try makeProject()
        let tx = try await addExpense(50, project: project)
        XCTAssertEqual(tx.financeProjectId, project.id)
    }

    func test_addInstallmentTransactions_allPeriodsCarryProject() async throws {
        let project = try makeProject()
        let txs = try await repo.addInstallmentTransactions(
            totalAmount: 1200, feePerPeriod: 0, periods: 3,
            type: .expense, category: lunchCategory, account: account,
            startDate: Date(), note: "相机", financeProject: project
        )
        XCTAssertEqual(txs.count, 3)
        XCTAssertTrue(txs.allSatisfy { $0.financeProjectId == project.id })
    }

    // MARK: - 删除只解除关联

    func test_deleteProject_unlinksButKeepsTransactions() async throws {
        let project = try makeProject()
        let tx1 = try await addExpense(100, project: project)
        let tx2 = try await addExpense(200, project: project)
        // 删除并 save 后对象数据被丢弃，再访问属性会触发 fault 崩溃——必须先存 id
        let projectId = project.id

        try projectRepo.deleteProject(project)

        XCTAssertNil(projectRepo.findProject(by: projectId))
        let alive = try await repo.getAllTransactions()
        XCTAssertEqual(Set(alive.map(\.id)), Set([tx1.id, tx2.id]))
        XCTAssertTrue(alive.allSatisfy { $0.financeProjectId == nil })
    }

    // MARK: - 口径零污染

    func test_projectTransactions_participateInGlobalStatistics() async throws {
        let project = try makeProject()
        _ = try await addExpense(88, project: project)

        // 挂项目的交易按普通交易参与全局统计（口径不受 financeProjectId 影响）
        let stats = try await repo.getStatisticsTransactions(from: todayRange.start, to: todayRange.end)
        XCTAssertEqual(stats.count, 1)
        let aggregations = try await repo.getCategoryAggregations(from: todayRange.start, to: todayRange.end, type: .expense)
        XCTAssertEqual(aggregations.first?.amount, 88)
    }

    func test_projectExpenseAggregation_statisticsSemantics() async throws {
        let project = try makeProject()

        // 计入：已发生的过去支出
        _ = try await addExpense(100, date: Date().addingTimeInterval(-86400), project: project)
        // 不计入：未来支出（未发生）
        _ = try await addExpense(999, date: Date().addingTimeInterval(86400 * 3), project: project)
        // 不计入：收入
        let income = try await repo.addTransaction(
            amount: 500, type: .income, category: lunchCategory, account: account,
            date: Date(), note: "退款", financeProject: project
        )
        XCTAssertNotNil(income)
        // 不计入：对账调整流水
        let adjust = try await addExpense(20, project: project)
        adjust.isReconciliationAdjustment = true
        try? context.save()

        XCTAssertEqual(projectRepo.totalExpense(forProject: project.id), 100)
        // 明细列表 = 已发生语义（未来支出不出现）；类型不限、含对账调整
        XCTAssertEqual(projectRepo.fetchTransactions(forProject: project.id).count, 3)
    }

    func test_categoryAggregations_foldsSubcategoryIntoParent() async throws {
        let project = try makeProject()
        _ = try await addExpense(60, project: project)   // 二级分类「午餐」

        let aggregations = projectRepo.categoryAggregations(forProject: project.id)
        XCTAssertEqual(aggregations.count, 1)
        XCTAssertEqual(aggregations.first?.category.name, "餐饮")
        XCTAssertEqual(aggregations.first?.amount, 60)
    }

    // MARK: - 挂靠改挂 / 三态更新

    func test_attach_movesTransactionBetweenProjects() async throws {
        let first = try makeProject(name: "A")
        let second = try makeProject(name: "B")
        let tx = try await addExpense(30, project: first)

        try projectRepo.attach([tx], to: second)
        XCTAssertEqual(tx.financeProjectId, second.id)
        XCTAssertEqual(projectRepo.totalExpense(forProject: second.id), 30)
        XCTAssertEqual(projectRepo.totalExpense(forProject: first.id), 0)
    }

    func test_detach_clearsLink() async throws {
        let project = try makeProject()
        let tx = try await addExpense(30, project: project)

        try projectRepo.detach([tx])
        XCTAssertNil(tx.financeProjectId)
        XCTAssertEqual(projectRepo.totalExpense(forProject: project.id), 0)
    }

    func test_transactionUpdates_financeProjectId_triState() async throws {
        let project = try makeProject()
        let other = try makeProject(name: "装修")
        let tx = try await addExpense(45, project: project)

        // 外层 nil = 不修改
        try await repo.updateTransaction(tx, updates: TransactionUpdates(note: "改备注"))
        XCTAssertEqual(tx.financeProjectId, project.id)

        // 非 nil = 改挂
        try await repo.updateTransaction(tx, updates: TransactionUpdates(note: nil, financeProjectId: .some(other.id)))
        XCTAssertEqual(tx.financeProjectId, other.id)

        // 内层 nil = 解除挂靠
        try await repo.updateTransaction(tx, updates: TransactionUpdates(note: nil, financeProjectId: .some(nil)))
        XCTAssertNil(tx.financeProjectId)
    }

    // MARK: - 汇总

    func test_summary_countsActiveProjectsOnly() async throws {
        let travel = try makeProject(name: "东京旅行", budget: 2000)
        let renovation = try makeProject(name: "装修", budget: 1000)
        _ = try await addExpense(100, project: travel)
        _ = try await addExpense(40, project: renovation)
        let finished = try makeProject(name: "已完结", budget: 500)
        try projectRepo.updateStatus(finished, status: .completed)

        let summary = projectRepo.summary()
        XCTAssertEqual(summary.activeCount, 2)
        XCTAssertEqual(summary.totalExpense, 140)
        XCTAssertEqual(summary.totalBudget, 3000)
    }

    // MARK: - AI 项目名匹配（record_expense 的 projectCandidate 槽位）

    func test_matchProjectCandidate_exactAndPartial() throws {
        let travel = try makeProject(name: "东京旅行")
        let renovation = try makeProject(name: "装修")

        // 精确同名
        let exact = FinanceProjectRepository.matchProjectCandidate("东京旅行", in: [travel, renovation])
        XCTAssertEqual(exact.project?.id, travel.id)
        XCTAssertFalse(exact.ambiguous)

        // 候选是项目名前缀（用户说「东京」）
        let partial = FinanceProjectRepository.matchProjectCandidate("东京", in: [travel, renovation])
        XCTAssertEqual(partial.project?.id, travel.id)

        // 候选包含项目名（用户说「算东京旅行的」）
        let contained = FinanceProjectRepository.matchProjectCandidate("算东京旅行的", in: [travel, renovation])
        XCTAssertEqual(contained.project?.id, travel.id)

        // 未提及
        let none = FinanceProjectRepository.matchProjectCandidate(nil, in: [travel, renovation])
        XCTAssertNil(none.project)
        XCTAssertFalse(none.ambiguous)

        // 提到不存在的项目 → 不挂不歧义
        let missing = FinanceProjectRepository.matchProjectCandidate("火星之旅", in: [travel, renovation])
        XCTAssertNil(missing.project)
        XCTAssertFalse(missing.ambiguous)
    }

    func test_matchProjectCandidate_ambiguousDoesNotAttach() throws {
        let a = try makeProject(name: "东京旅行")
        let b = try makeProject(name: "北海道旅行")

        // 「旅行」同时命中两个项目 → 歧义不挂
        let ambiguous = FinanceProjectRepository.matchProjectCandidate("旅行", in: [a, b])
        XCTAssertNil(ambiguous.project)
        XCTAssertTrue(ambiguous.ambiguous)
    }

    // MARK: - 编辑

    func test_update_overwritesAllFields() throws {
        let project = try makeProject(budget: 100)
        let newStart = Date().addingTimeInterval(-86400)

        try projectRepo.update(
            project, name: "北海道之旅", icon: "❄️", color: "#007AFF",
            note: "冬季", startDate: newStart, endDate: nil, budgetAmount: 3000
        )

        XCTAssertEqual(project.name, "北海道之旅")
        XCTAssertEqual(project.icon, "❄️")
        XCTAssertEqual(project.note, "冬季")
        XCTAssertEqual(project.budgetDecimal, 3000)
        XCTAssertEqual(project.startDate, newStart)
        XCTAssertNil(project.endDate)
    }

    // MARK: - Private

    private var todayRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        return (start, end)
    }
}
