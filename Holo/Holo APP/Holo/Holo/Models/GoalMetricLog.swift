//
//  GoalMetricLog.swift
//  Holo
//
//  量化目标手动记录实体（仅 manual 源使用）
//  与 Goal 不建 Core Data 关系，用 goalId 外键关联
//

import Foundation
import CoreData

@objc(GoalMetricLog)
public class GoalMetricLog: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<GoalMetricLog> {
        NSFetchRequest<GoalMetricLog>(entityName: "GoalMetricLog")
    }

    // MARK: - Core Data Properties

    @NSManaged public var id: UUID
    @NSManaged public var goalId: UUID
    @NSManaged public var date: Date
    /// 累积型=本次增量，达标型=当前水平
    @NSManaged public var value: Double
    @NSManaged public var note: String?
    @NSManaged public var createdAt: Date
}

// MARK: - Identifiable

extension GoalMetricLog: Identifiable {}
