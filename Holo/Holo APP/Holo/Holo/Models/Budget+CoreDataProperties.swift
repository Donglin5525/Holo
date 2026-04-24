//
//  Budget+CoreDataProperties.swift
//  Holo
//
//  预算扩展 - 静态方法和工厂方法
//

import Foundation
import CoreData

extension Budget {

    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Budget> {
        return NSFetchRequest<Budget>(entityName: "Budget")
    }

    // MARK: - Factory Methods

    /// 创建新的预算
    static func create(
        in context: NSManagedObjectContext,
        accountId: UUID,
        amount: NSDecimalNumber,
        period: BudgetPeriod,
        startDate: Date,
        categoryId: UUID? = nil
    ) -> Budget {
        let budget = Budget(context: context)
        budget.id = UUID()
        budget.accountId = accountId
        budget.categoryId = categoryId
        budget.amount = amount
        budget.period = period.rawValue
        budget.startDate = startDate
        budget.createdAt = Date()
        budget.updatedAt = Date()

        return budget
    }

    // MARK: - Query Helpers

    /// 查询指定账户的所有预算
    static func fetchForAccount(
        _ accountId: UUID,
        in context: NSManagedObjectContext
    ) -> [Budget] {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(format: "accountId == %@", accountId as CVarArg)

        return (try? context.fetch(request)) ?? []
    }

    /// 查询指定账户的总预算
    static func fetchTotalBudget(
        forAccount accountId: UUID,
        period: BudgetPeriod,
        in context: NSManagedObjectContext
    ) -> Budget? {
        let request = Budget.fetchRequest()
        request.predicate = NSPredicate(
            format: "accountId == %@ AND period == %@ AND categoryId == nil",
            accountId as CVarArg,
            period.rawValue
        )
        request.fetchLimit = 1

        return (try? context.fetch(request)).flatMap { $0.first }
    }
}
