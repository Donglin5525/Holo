//
//  FinanceProject.swift
//  Holo
//
//  财务项目实体类：跨分类/跨账户聚合支出的观察维度（如东京旅行、装修）。
//  与固定支出 SpendingProject 语义无关：项目不生成流水，只归组手工/AI/导入的交易。
//

import Foundation
import CoreData

/// 项目状态
enum FinanceProjectStatus: String, CaseIterable {
    /// 进行中
    case active
    /// 已完结（保留查看入口）
    case completed
    /// 已归档（收起不常看的项目）
    case archived
}

@objc(FinanceProject)
public class FinanceProject: NSManagedObject {

    // MARK: - Fetch Request

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FinanceProject> {
        NSFetchRequest<FinanceProject>(entityName: "FinanceProject")
    }

    // MARK: - Properties

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    /// emoji 图标（走 Emoji 图标库统一入口）
    @NSManaged public var icon: String
    /// hex 颜色
    @NSManaged public var color: String
    @NSManaged public var note: String?
    /// 起止时间是软约束：仅用于展示与后续智能建议，不拦截交易归属
    @NSManaged public var startDate: Date?
    @NSManaged public var endDate: Date?
    /// 预算上限（可选；nil=纯记录不算进度）
    @NSManaged public var budgetAmount: NSDecimalNumber?
    @NSManaged public var status: String
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    // MARK: - Computed Properties

    var statusEnum: FinanceProjectStatus {
        FinanceProjectStatus(rawValue: status) ?? .active
    }

    var budgetDecimal: Decimal? {
        budgetAmount?.decimalValue
    }

    // MARK: - Methods

    /// 删除项目
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Concurrency
extension FinanceProject: @unchecked Sendable {}

// MARK: - Identifiable
/// 用于 SwiftUI sheet(item:) 等
extension FinanceProject: Identifiable {}
