//
//  Habit+CoreDataProperties.swift
//  Holo
//
//  习惯扩展 - 静态方法和关系操作
//

import Foundation
import CoreData

extension Habit {
    
    // MARK: - Fetch Request
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Habit> {
        return NSFetchRequest<Habit>(entityName: "Habit")
    }
    
    // MARK: - Records Relationship Accessors
    
    /// 添加单条记录
    @objc(addRecordsObject:)
    @NSManaged public func addToRecords(_ value: HabitRecord)
    
    /// 移除单条记录
    @objc(removeRecordsObject:)
    @NSManaged public func removeFromRecords(_ value: HabitRecord)
    
    /// 添加多条记录
    @objc(addRecords:)
    @NSManaged public func addToRecords(_ values: NSSet)
    
    /// 移除多条记录
    @objc(removeRecords:)
    @NSManaged public func removeFromRecords(_ values: NSSet)
    
    // MARK: - Factory Methods
    
    /// 创建新习惯
    /// - Parameters:
    ///   - context: Core Data 上下文
    ///   - name: 习惯名称
    ///   - icon: SF Symbol 图标名
    ///   - color: Hex 颜色值
    ///   - type: 习惯类型（打卡型/数值型）
    ///   - frequency: 频率（每日/每周/每月）
    ///   - targetCount: 目标次数（打卡型）
    ///   - targetValue: 目标数值（数值型）
    ///   - unit: 单位（数值型）
    ///   - aggregationType: 聚合类型（计数类/测量类）
    ///   - sortOrder: 排序顺序
    /// - Returns: 新建的 Habit 实例
    static func create(
        in context: NSManagedObjectContext,
        name: String,
        icon: String,
        color: String,
        type: HabitType,
        frequency: HabitFrequency = .daily,
        targetCount: Int? = nil,
        targetValue: Double? = nil,
        unit: String? = nil,
        aggregationType: HabitAggregationType = .sum,
        isBadHabit: Bool = false,
        sortOrder: Int16 = 0
    ) -> Habit {
        let habit = Habit(context: context)
        habit.id = UUID()
        habit.name = name
        habit.icon = icon
        habit.color = color
        habit.type = type.rawValue
        habit.frequency = frequency.rawValue
        habit.targetCount = targetCount.map { NSNumber(value: $0) }
        habit.targetValue = targetValue.map { NSNumber(value: $0) }
        habit.unit = unit
        habit.aggregationType = aggregationType.rawValue
        habit.isBadHabit = isBadHabit
        habit.isArchived = false
        habit.sortOrder = sortOrder
        habit.createdAt = Date()
        habit.updatedAt = Date()
        return habit
    }
}
