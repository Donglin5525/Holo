//
//  FinanceProjectRepository.swift
//  Holo
//
//  财务项目数据仓库：项目增删改查 + 交易挂靠 + 项目视角聚合。
//
//  口径铁律（与全 App 统一口径一致，见 Transaction.statisticsType）：
//  - 项目是「一件事」的资金全景，收支都可挂靠（2026-10-04 方向定稿）
//  - 总支出（统计语义）= 已发生 + 排对账调整 + 支出侧（含退款负冲，退款挂靠继承原交易）
//  - 总收入（统计语义）= 已发生 + 排对账调整 + 收入侧（退款不算收入——已在支出侧冲减）
//  - 净投入 = 总支出 − 总收入；预算只约束支出
//  - 明细列表（项目详情交易流）= 明细语义：已发生 + 含对账调整流水，收支都出现
//  挂项目的交易在余额/分类统计/预算中按普通交易参与，本项目只提供项目视角汇总。
//

import Foundation
import CoreData

@MainActor
final class FinanceProjectRepository {

    static let shared = FinanceProjectRepository()

    private let finance: FinanceRepository
    var context: NSManagedObjectContext { finance.context }

    private init() {
        finance = .shared
    }

    /// 模块内测试入口：注入测试用 FinanceRepository（内存 context），避免读写真实库
    init(finance: FinanceRepository) {
        self.finance = finance
    }

    // MARK: - 项目查询

    func allProjects() -> [FinanceProject] {
        let request = FinanceProject.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 进行中项目（记账表单选择器、AI 挂靠候选都用这份清单）
    func activeProjects() -> [FinanceProject] {
        allProjects().filter { $0.statusEnum == .active }
    }

    func findProject(by id: UUID) -> FinanceProject? {
        let request = FinanceProject.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "id == %@", id as CVarArg),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    // MARK: - 项目增删改

    @discardableResult
    func create(
        name: String,
        icon: String,
        color: String,
        note: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        budgetAmount: Decimal? = nil
    ) throws -> FinanceProject {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw FinanceError.invalidData }

        let project = FinanceProject(context: context)
        project.id = UUID()
        project.name = trimmedName
        project.icon = icon
        project.color = color
        project.note = note
        project.startDate = startDate
        project.endDate = endDate
        project.budgetAmount = budgetAmount.map { NSDecimalNumber(decimal: $0) }
        project.status = FinanceProjectStatus.active.rawValue
        project.createdAt = Date()
        project.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
        return project
    }

    /// 编辑项目（表单整表提交：编辑页持有全部当前值，直接全量覆盖）
    func update(
        _ project: FinanceProject,
        name: String,
        icon: String,
        color: String,
        note: String?,
        startDate: Date?,
        endDate: Date?,
        budgetAmount: Decimal?
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw FinanceError.invalidData }

        project.name = trimmedName
        project.icon = icon
        project.color = color
        project.note = note
        project.startDate = startDate
        project.endDate = endDate
        project.budgetAmount = budgetAmount.map { NSDecimalNumber(decimal: $0) }
        project.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    func updateStatus(_ project: FinanceProject, status: FinanceProjectStatus) throws {
        project.status = status.rawValue
        project.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    /// 删除项目：仅解除所有交易的挂靠，交易本身一律不动。
    /// 项目不参与余额与统计，删除对账务数据零影响。
    func deleteProject(_ project: FinanceProject) throws {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "financeProjectId == %@", project.id as CVarArg),
            NSPredicate(format: "deletedAt == nil")
        ])
        for transaction in (try? context.fetch(request)) ?? [] {
            transaction.financeProjectId = nil
            transaction.updatedAt = Date()
        }
        context.delete(project)
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    // MARK: - 交易挂靠

    /// 项目交易明细（详情页交易流；明细语义：已发生 + 含对账调整流水）
    func fetchTransactions(forProject projectId: UUID) -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "financeProjectId == %@", projectId as CVarArg),
            FinanceTransactionOccurrencePolicy.occurredPredicate(),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 项目支出侧交易（统计口径：已发生 + 排对账调整 + 支出侧——退款笔挂靠继承原交易，
    /// 金额取 statisticsAmount 负值在聚合时自然冲减，与全局统计同构）
    func fetchExpenseTransactions(forProject projectId: UUID, asOf snapshotDate: Date = Date()) -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "financeProjectId == %@", projectId as CVarArg),
            FinanceTransactionOccurrencePolicy.occurredPredicate(asOf: snapshotDate),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate(),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "type == %@", TransactionType.expense.rawValue),
                NSPredicate(format: "refundOfTransactionId != nil")
            ]),
            NSPredicate(format: "deletedAt == nil")
        ])
        request.relationshipKeyPathsForPrefetching = ["category"]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 项目收入侧交易（统计口径：已发生 + 排对账调整 + 收入且非退款——退款在支出侧冲减）
    func fetchIncomeTransactions(forProject projectId: UUID, asOf snapshotDate: Date = Date()) -> [Transaction] {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "financeProjectId == %@", projectId as CVarArg),
            FinanceTransactionOccurrencePolicy.occurredPredicate(asOf: snapshotDate),
            FinanceTransactionOccurrencePolicy.reconciliationExclusionPredicate(),
            NSPredicate(format: "type == %@", TransactionType.income.rawValue),
            NSPredicate(format: "refundOfTransactionId == nil"),
            NSPredicate(format: "deletedAt == nil")
        ])
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }

    /// 批量挂靠到项目（从历史挑交易补挂；已有项目归属的交易会被改挂到新项目）
    func attach(_ transactions: [Transaction], to project: FinanceProject) throws {
        for transaction in transactions {
            transaction.financeProjectId = project.id
            transaction.updatedAt = Date()
        }
        project.updatedAt = Date()
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    /// 批量解除挂靠
    func detach(_ transactions: [Transaction]) throws {
        for transaction in transactions {
            transaction.financeProjectId = nil
            transaction.updatedAt = Date()
        }
        try context.save()
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
    }

    // MARK: - 项目视角聚合

    /// 项目总支出（统计口径：支出侧含退款负冲）
    func totalExpense(forProject projectId: UUID, asOf snapshotDate: Date = Date()) -> Decimal {
        fetchExpenseTransactions(forProject: projectId, asOf: snapshotDate)
            .reduce(Decimal(0)) { $0 + $1.statisticsAmount }
    }

    /// 项目总收入（统计口径：收入且非退款）
    func totalIncome(forProject projectId: UUID, asOf snapshotDate: Date = Date()) -> Decimal {
        fetchIncomeTransactions(forProject: projectId, asOf: snapshotDate)
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }

    /// 项目净投入 = 总支出 − 总收入（负值即项目已回血超过投入）
    func netAmount(forProject projectId: UUID, asOf snapshotDate: Date = Date()) -> Decimal {
        totalExpense(forProject: projectId, asOf: snapshotDate)
            - totalIncome(forProject: projectId, asOf: snapshotDate)
    }

    /// 项目全程区间（统计页「看项目全程」用）：startDate/endDate 缺失时按首末笔
    /// 交易日期补齐（收支都参与——进账也是这件事的资金轨迹），两者皆空返回 nil。
    /// 返回的 end 为排他上界（含末笔当天），与自定义时间组件同一语义。
    func projectSpan(of project: FinanceProject) -> (start: Date, end: Date)? {
        let txns = fetchExpenseTransactions(forProject: project.id) + fetchIncomeTransactions(forProject: project.id)
        let first = [project.startDate, txns.map(\.date).min()].compactMap { $0 }.min()
        let last = [project.endDate, txns.map(\.date).max()].compactMap { $0 }.max()
        guard let start = first, let lastDay = last else { return nil }

        let calendar = Calendar.current
        if let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) {
            return (calendar.startOfDay(for: start), endExclusive)
        }
        return (start, lastDay.addingTimeInterval(86400))
    }

    /// 项目分类构成（一级分类口径：二级分类归入父分类，与统计页「类别对比」一致；
    /// 支出侧含退款负冲，退款分类已联动原交易）
    func categoryAggregations(forProject projectId: UUID) -> [CategoryAggregation] {
        let transactions = fetchExpenseTransactions(forProject: projectId)
        guard !transactions.isEmpty else { return [] }

        let totalAmount = transactions.reduce(Decimal(0)) { $0 + $1.statisticsAmount }

        var categoryMap: [UUID: (category: Category, amount: Decimal, count: Int)] = [:]
        for tx in transactions {
            guard let txCategory = tx.category else { continue }
            let topCategory: Category
            if txCategory.isTopLevel {
                topCategory = txCategory
            } else if let parentId = txCategory.parentId, let parent = finance.findCategory(by: parentId) {
                topCategory = parent
            } else {
                topCategory = txCategory
            }

            if var entry = categoryMap[topCategory.id] {
                entry.amount += tx.statisticsAmount
                entry.count += 1
                categoryMap[topCategory.id] = entry
            } else {
                categoryMap[topCategory.id] = (category: topCategory, amount: tx.statisticsAmount, count: 1)
            }
        }

        return categoryMap.map { (_, value) -> CategoryAggregation in
            let percentage = totalAmount > 0 ? (value.amount / totalAmount) * 100 : 0
            return CategoryAggregation(
                category: value.category,
                amount: value.amount,
                percentage: Double(truncating: percentage as NSDecimalNumber),
                transactionCount: value.count
            )
        }.sorted { $0.amount > $1.amount }
    }

    // MARK: - AI 项目名匹配

    /// 把模型回传的 projectCandidate 匹配成项目（record_expense 挂靠）：
    /// 精确同名优先，其次互为包含；命中多个视为歧义不挂——误挂比漏挂伤害大。
    static func matchProjectCandidate(
        _ candidate: String?,
        in projects: [FinanceProject]
    ) -> (project: FinanceProject?, ambiguous: Bool) {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return (nil, false)
        }
        let exact = projects.filter { $0.name == trimmed }
        if exact.count == 1 { return (exact[0], false) }
        let partial = projects.filter { $0.name.contains(trimmed) || trimmed.contains($0.name) }
        if exact.isEmpty && partial.count == 1 { return (partial[0], false) }
        if exact.count > 1 || (exact.isEmpty && partial.count > 1) { return (nil, true) }
        return (nil, false)
    }

    // MARK: - 历史口径清洗

    /// 一次性迁移（启动入口见 FinanceProjectIncomeDetachBootstrap）：收入交易解除项目挂靠。
    /// 口径=收入不挂项目（与票根 §21.3 一致）；手动表单「记住上次项目」曾不分收支预选，
    /// 收入模式项目行隐藏无从取消，存量收入被静默挂上项目，此处追溯清理。
    /// 含软删交易（恢复后也不再带项目）；幂等，无匹配即零改动。返回清洗笔数。
    nonisolated static func detachProjectsFromIncomeTransactions(
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "type == %@", TransactionType.income.rawValue),
            NSPredicate(format: "financeProjectId != nil")
        ])
        let stale = try context.fetch(request)
        guard !stale.isEmpty else { return 0 }
        let now = Date()
        for transaction in stale {
            transaction.financeProjectId = nil
            transaction.updatedAt = now
        }
        try context.save()
        return stale.count
    }

    /// 一次性迁移（与上面清洗配套，启动时先清洗后回填）：退款笔挂靠继承原交易。
    /// 「退款挂靠恒等于原交易」是不变式——原支出挂了项目，名下退款须同挂，
    /// 项目支出侧负冲才与全局统计对账。此函数回填存量（新退款在创建时已自动继承）。
    /// 含软删退款（与清洗对称）；幂等，返回回填笔数。
    nonisolated static func backfillRefundProjectAttachments(
        in context: NSManagedObjectContext
    ) throws -> Int {
        let attachedRequest = Transaction.fetchRequest()
        attachedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "financeProjectId != nil"),
            NSPredicate(format: "deletedAt == nil")
        ])
        var projectByOriginalId: [UUID: UUID] = [:]
        for tx in try context.fetch(attachedRequest) where tx.refundOfTransactionId == nil {
            projectByOriginalId[tx.id] = tx.financeProjectId
        }
        guard !projectByOriginalId.isEmpty else { return 0 }

        let refundRequest = Transaction.fetchRequest()
        refundRequest.predicate = NSPredicate(format: "refundOfTransactionId != nil")
        let now = Date()
        var backfilled = 0
        for refund in try context.fetch(refundRequest) {
            guard let originalId = refund.refundOfTransactionId,
                  let targetProjectId = projectByOriginalId[originalId],
                  refund.financeProjectId != targetProjectId else { continue }
            refund.financeProjectId = targetProjectId
            refund.updatedAt = now
            backfilled += 1
        }
        guard backfilled > 0 else { return 0 }
        try context.save()
        return backfilled
    }

    // MARK: - 汇总

    /// 项目列表页顶部汇总：只统计进行中项目
    struct Summary {
        var activeCount: Int = 0
        /// 进行中项目合计已花（支出侧含退款负冲）
        var totalExpense: Decimal = 0
        /// 进行中项目合计收入（收入且非退款）
        var totalIncome: Decimal = 0
        /// 进行中项目合计预算（仅设有预算的项目）
        var totalBudget: Decimal = 0
    }

    func summary(asOf snapshotDate: Date = Date()) -> Summary {
        var result = Summary()
        for project in allProjects() where project.statusEnum == .active {
            result.activeCount += 1
            result.totalExpense += totalExpense(forProject: project.id, asOf: snapshotDate)
            result.totalIncome += totalIncome(forProject: project.id, asOf: snapshotDate)
            if let budget = project.budgetDecimal {
                result.totalBudget += budget
            }
        }
        return result
    }
}

// MARK: - 交易行项目徽标缓存

/// 交易行展示挂靠项目名用的快照缓存：
/// 长列表里每行渲染查库是 O(N) 次小查询，按 financeProjectId 缓存，
/// 收到数据变更通知整表失效；查不到（已删/软删）也缓存空值避免反复查。
@MainActor
enum FinanceProjectTagCache {
    private static var snapshot: [UUID: (icon: String, name: String)?] = [:]
    private static var observerInstalled = false

    static func lookup(_ projectId: UUID?) -> (icon: String, name: String)? {
        guard let projectId else { return nil }
        installObserverIfNeeded()
        if let cached = snapshot[projectId] { return cached }
        let project = FinanceProjectRepository.shared.findProject(by: projectId)
        snapshot[projectId] = project.map { (icon: $0.icon, name: $0.name) }
        return snapshot[projectId] ?? nil
    }

    private static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: .financeDataDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                snapshot.removeAll()
            }
        }
    }
}
