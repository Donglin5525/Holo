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

    // MARK: - 补签（Retroactive）

    /// 创建补签记录：date 归到目标日当天（与逐日谓词对齐），createdAt 记真实补签时间
    /// 调用方负责落库前校验（窗口、幂等、额度），本方法只负责建对象
    /// - Parameter day: 补签目标日（应为 startOfDay）
    static func createRetroactiveCheckIn(
        in context: NSManagedObjectContext,
        habit: Habit,
        on day: Date,
        note: String? = nil
    ) -> HabitRecord {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = habit.id
        record.date = day
        record.isCompleted = true
        record.value = nil
        record.note = note
        record.createdAt = Date()
        record.isRetroactive = true
        record.habit = habit
        return record
    }

    /// 创建补签数值记录（计数/测量型习惯补签）
    static func createRetroactiveNumeric(
        in context: NSManagedObjectContext,
        habit: Habit,
        on day: Date,
        value: Double,
        note: String? = nil
    ) -> HabitRecord {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = habit.id
        record.date = day
        record.isCompleted = false
        record.value = NSNumber(value: value)
        record.note = note
        record.createdAt = Date()
        record.isRetroactive = true
        record.habit = habit
        return record
    }
}
