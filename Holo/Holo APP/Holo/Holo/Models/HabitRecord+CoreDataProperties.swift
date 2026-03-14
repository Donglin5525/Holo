//
//  HabitRecord+CoreDataProperties.swift
//  Holo
//
//  习惯记录扩展 - 静态方法
//

import Foundation
import CoreData

extension HabitRecord {
    
    // MARK: - Fetch Request
    
    /// 创建 fetch request
    @nonobjc public class func fetchRequest() -> NSFetchRequest<HabitRecord> {
        return NSFetchRequest<HabitRecord>(entityName: "HabitRecord")
    }
    
    // MARK: - Factory Methods
    
    /// 创建打卡记录（打卡型习惯）
    /// - Parameters:
    ///   - context: Core Data 上下文
    ///   - habit: 关联的习惯
    ///   - isCompleted: 是否完成
    ///   - note: 备注
    /// - Returns: 新建的 HabitRecord 实例
    static func createCheckIn(
        in context: NSManagedObjectContext,
        habit: Habit,
        isCompleted: Bool = true,
        note: String? = nil
    ) -> HabitRecord {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = habit.id
        record.date = Date()
        record.isCompleted = isCompleted
        record.value = nil
        record.note = note
        record.createdAt = Date()
        record.habit = habit
        return record
    }
    
    /// 创建数值记录（数值型习惯）
    /// - Parameters:
    ///   - context: Core Data 上下文
    ///   - habit: 关联的习惯
    ///   - value: 记录数值
    ///   - note: 备注
    /// - Returns: 新建的 HabitRecord 实例
    static func createNumeric(
        in context: NSManagedObjectContext,
        habit: Habit,
        value: Double,
        note: String? = nil
    ) -> HabitRecord {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = habit.id
        record.date = Date()
        record.isCompleted = false  // 数值型不使用此字段
        record.value = NSNumber(value: value)
        record.note = note
        record.createdAt = Date()
        record.habit = habit
        return record
    }
}
