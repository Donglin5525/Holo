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

    var errorDescription: String? {
        switch self {
        case .amountMustBePositive:
            return "预算金额必须大于 0"
        case .budgetAlreadyExists:
            return "该账户已存在相同周期的总预算"
        case .budgetNotFound:
            return "未找到预算记录"
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

    // MARK: - Budget Status Computation

    /// 计算指定预算的当前状态
    func computeBudgetStatus(budget: Budget) -> BudgetStatus? {
        let range = currentPeriodRange(for: budget)
        let budgetAmount = budget.amount.decimalValue

        // 查询该账户在周期内的支出交易
        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "account.id == %@ AND date >= %@ AND date < %@ AND type == %@",
            budget.accountId as CVarArg,
            range.start as NSDate,
            range.end as NSDate,
            TransactionType.expense.rawValue
        )

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
}
