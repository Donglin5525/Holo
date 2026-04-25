//
//  BudgetRepository.swift
//  Holo
//
//  预算数据仓库 - CRUD、预算状态计算、周期范围管理
//

import Foundation
import CoreData
import os.log

/// 预算管理错误
enum BudgetError: LocalizedError {
    case amountMustBePositive
    case budgetAlreadyExists
    case budgetNotFound
    case invalidAmount

    var errorDescription: String? {
        switch self {
        case .amountMustBePositive:
            return "预算金额必须大于 0"
        case .budgetAlreadyExists:
            return "该账户已存在相同周期的总预算"
        case .budgetNotFound:
            return "未找到预算记录"
        case .invalidAmount:
            return "请输入有效的预算金额"
        }
    }
}

/// 预算数据仓库
@MainActor
class BudgetRepository {

    // MARK: - Singleton

    static let shared = BudgetRepository()

    private lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext

    private let logger = Logger(subsystem: "com.holo.app", category: "BudgetRepository")

    private init() {}

    // MARK: - CRUD

    /// 获取指定账户的所有预算
    func getBudgets(forAccount accountId: UUID) -> [Budget] {
        Budget.fetchForAccount(accountId, in: context)
    }

    /// 获取指定账户的总预算
    func getTotalBudget(forAccount accountId: UUID, period: BudgetPeriod) -> Budget? {
        Budget.fetchTotalBudget(forAccount: accountId, period: period, in: context)
    }

    /// 新增预算
    func addBudget(
        accountId: UUID,
        amount: Decimal,
        period: BudgetPeriod,
        startDate: Date
    ) throws -> Budget {
        guard amount > 0 else {
            throw BudgetError.amountMustBePositive
        }

        // 检查是否已存在相同账户 + 周期的总预算
        if getTotalBudget(forAccount: accountId, period: period) != nil {
            throw BudgetError.budgetAlreadyExists
        }

        let budget = Budget.create(
            in: context,
            accountId: accountId,
            amount: NSDecimalNumber(decimal: amount),
            period: period,
            startDate: startDate
        )

        try context.save()
        logger.info("预算已创建：账户=\(accountId.uuidString.prefix(8)), 金额=\(NSDecimalNumber(decimal: amount)), 周期=\(period.rawValue)")

        return budget
    }

    /// 更新预算金额和起始日期（不允许修改周期）
    func updateBudget(_ budget: Budget, amount: Decimal?, startDate: Date?) throws {
        if let amount {
            guard amount > 0 else {
                throw BudgetError.amountMustBePositive
            }
            budget.amount = NSDecimalNumber(decimal: amount)
        }

        if let startDate {
            budget.startDate = startDate
        }

        budget.updatedAt = Date()
        try context.save()
        logger.info("预算已更新")
    }

    /// 删除预算
    func deleteBudget(_ budget: Budget) throws {
        budget.delete()
        try context.save()
        logger.info("预算已删除")
    }

    // MARK: - Category Budget CRUD

    /// 新增分类预算
    func addCategoryBudget(
        accountId: UUID,
        categoryId: UUID,
        amount: Decimal,
        period: BudgetPeriod,
        startDate: Date
    ) throws -> Budget {
        guard amount > 0 else {
            throw BudgetError.amountMustBePositive
        }

        // 检查是否已存在相同账户 + 分类 + 周期的预算
        if getCategoryBudget(forAccount: accountId, categoryId: categoryId, period: period) != nil {
            throw BudgetError.budgetAlreadyExists
        }

        let budget = Budget.create(
            in: context,
            accountId: accountId,
            amount: NSDecimalNumber(decimal: amount),
            period: period,
            startDate: startDate,
            categoryId: categoryId
        )

        try context.save()
        logger.info("分类预算已创建：分类=\(categoryId.uuidString.prefix(8)), 金额=\(NSDecimalNumber(decimal: amount))")

        return budget
    }

    /// 获取指定账户 + 分类的预算
    func getCategoryBudget(
        forAccount accountId: UUID,
        categoryId: UUID,
        period: BudgetPeriod
    ) -> Budget? {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(
            format: "accountId == %@ AND period == %@ AND categoryId == %@",
            accountId as CVarArg,
            period.rawValue,
            categoryId as CVarArg
        )
        request.fetchLimit = 1
        return (try? context.fetch(request)).flatMap { $0.first }
    }

    /// 获取指定账户的所有分类预算
    func getCategoryBudgets(forAccount accountId: UUID) -> [Budget] {
        Budget.fetchCategoryBudgets(forAccount: accountId, in: context)
    }

    // MARK: - Budget Status Computation

    /// 计算指定预算的当前状态
    func computeBudgetStatus(budget: Budget) -> BudgetStatus? {
        let range = currentPeriodRange(for: budget)
        let budgetAmount = budget.amount.decimalValue

        // 查询该账户在周期内的支出交易
        let request = Transaction.fetchRequest()

        if let categoryId = budget.categoryId {
            // 分类预算：匹配该分类及其子分类的交易
            request.predicate = NSPredicate(
                format: "account.id == %@ AND date >= %@ AND date < %@ AND type == %@ AND (category.id == %@ OR category.parentId == %@)",
                budget.accountId as CVarArg,
                range.start as NSDate,
                range.end as NSDate,
                TransactionType.expense.rawValue,
                categoryId as CVarArg,
                categoryId as CVarArg
            )
        } else {
            // 总预算：该账户所有支出交易
            request.predicate = NSPredicate(
                format: "account.id == %@ AND date >= %@ AND date < %@ AND type == %@",
                budget.accountId as CVarArg,
                range.start as NSDate,
                range.end as NSDate,
                TransactionType.expense.rawValue
            )
        }

        let transactions = (try? context.fetch(request)) ?? []
        let spentAmount = transactions.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
        let remainingAmount = budgetAmount - spentAmount
        let progress = budgetAmount > 0
            ? Double(truncating: NSDecimalNumber(decimal: spentAmount / budgetAmount))
            : 0.0

        let cal = Calendar.current
        let remainingDays = max(0, cal.dateComponents([.day], from: Date(), to: range.end).day ?? 0)

        return BudgetStatus(
            id: budget.id,
            budget: budget,
            budgetAmount: budgetAmount,
            spentAmount: spentAmount,
            remainingAmount: remainingAmount,
            progress: progress,
            periodStartDate: range.start,
            periodEndDate: range.end,
            isOverBudget: progress >= 1.0,
            isWarning: progress >= 0.8 && progress < 1.0,
            remainingDays: remainingDays
        )
    }

    /// 计算指定账户的当前总预算状态（便捷方法）
    func computeTotalBudgetStatus(
        forAccount accountId: UUID,
        period: BudgetPeriod
    ) -> BudgetStatus? {
        guard let budget = getTotalBudget(forAccount: accountId, period: period) else {
            return nil
        }
        return computeBudgetStatus(budget: budget)
    }

    // MARK: - Period Range Calculation

    /// 计算预算的当前周期日期范围
    /// 使用循环方式避免月末溢出 Bug
    func currentPeriodRange(for budget: Budget) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        var periodStart = cal.startOfDay(for: budget.startDate)
        let component = budget.budgetPeriod.calendarComponent

        // 安全阀：如果 startDate 在未来，直接返回当前周期
        if periodStart > now {
            return (periodStart, cal.date(byAdding: component, value: 1, to: periodStart) ?? now)
        }

        // 从 startDate 开始，每次加一个周期长度，找到包含 now 的区间
        var iterations = 0
        let maxIterations = 1200 // 约 100 年（月度）

        while iterations < maxIterations {
            guard let periodEnd = cal.date(byAdding: component, value: 1, to: periodStart) else {
                return (periodStart, now)
            }

            if now < periodEnd {
                return (periodStart, periodEnd)
            }

            periodStart = periodEnd
            iterations += 1
        }

        return (periodStart, now)
    }

    // MARK: - Global Aggregation（首页卡片）

    /// 计算全局总预算状态（跨所有活跃账户聚合）
    func computeGlobalTotalBudgetStatus(period: BudgetPeriod) -> GlobalBudgetSummary? {
        let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        var totalBudgetAmount: Decimal = 0
        var totalSpentAmount: Decimal = 0
        var minRemainingDays = Int.max
        var hasAnyBudget = false

        for account in accounts {
            guard let budget = getTotalBudget(forAccount: account.id, period: period),
                  let status = computeBudgetStatus(budget: budget) else {
                continue
            }
            hasAnyBudget = true
            totalBudgetAmount += status.budgetAmount
            totalSpentAmount += status.spentAmount
            minRemainingDays = min(minRemainingDays, status.remainingDays)
        }

        guard hasAnyBudget else { return nil }

        let progress = totalBudgetAmount > 0
            ? Double(truncating: NSDecimalNumber(decimal: totalSpentAmount / totalBudgetAmount))
            : 0.0

        return GlobalBudgetSummary(
            totalBudgetAmount: totalBudgetAmount,
            totalSpentAmount: totalSpentAmount,
            totalRemainingAmount: totalBudgetAmount - totalSpentAmount,
            progress: progress,
            isOverBudget: progress >= 1.0,
            isWarning: progress >= 0.8 && progress < 1.0,
            remainingDays: minRemainingDays == Int.max ? 0 : minRemainingDays
        )
    }

    /// 获取分类预算预警列表（progress >= 0.8，跨所有账户）
    func getWarningCategoryBudgets(period: BudgetPeriod) -> [CategoryBudgetWarning] {
        let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        var warnings: [CategoryBudgetWarning] = []

        for account in accounts {
            let categoryBudgets = getCategoryBudgets(forAccount: account.id)
            for budget in categoryBudgets {
                guard let status = computeBudgetStatus(budget: budget),
                      status.progress >= 0.8 else { continue }
                let category = findCategory(by: budget.categoryId)
                warnings.append(CategoryBudgetWarning(
                    categoryId: budget.categoryId,
                    categoryName: category?.name ?? "未知分类",
                    categoryIcon: category?.icon ?? "questionmark.folder.fill",
                    categoryColor: category?.color ?? "#64748B",
                    progress: status.progress,
                    isOverBudget: status.isOverBudget
                ))
            }
        }
        return warnings.sorted { $0.progress > $1.progress }
    }

    // MARK: - Helpers

    /// 按 UUID 查找分类
    func findCategory(by id: UUID?) -> Category? {
        guard let id else { return nil }
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
