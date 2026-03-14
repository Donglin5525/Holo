//
//  HabitRecord.swift
//  Holo
//
//  习惯记录实体类
//  支持一天多次记录，用于打卡和数值型习惯
//

import Foundation
import CoreData

/// 习惯记录实体
@objc(HabitRecord)
public class HabitRecord: NSManagedObject {
    
    // MARK: - Core Data Properties
    
    @NSManaged public var id: UUID
    @NSManaged public var habitId: UUID
    @NSManaged public var date: Date
    @NSManaged public var isCompleted: Bool
    @NSManaged public var value: NSNumber?
    @NSManaged public var note: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var habit: Habit?
    
    // MARK: - Computed Properties
    
    /// 数值（Double 形式）
    var valueDouble: Double? {
        get { value?.doubleValue }
        set { value = newValue.map { NSNumber(value: $0) } }
    }
    
    /// 格式化日期（显示用）
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
    
    /// 格式化时间（仅时分）
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    /// 格式化日期（完整）
    var formattedFullDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    
    /// 是否为今天的记录
    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    /// 所属日期（不含时间部分）
    var dayDate: Date {
        Calendar.current.startOfDay(for: date)
    }
    
    /// 格式化数值显示
    func formattedValue(unit: String? = nil) -> String {
        guard let val = valueDouble else { return "-" }
        let formatted: String
        if val.truncatingRemainder(dividingBy: 1) == 0 {
            formatted = String(format: "%.0f", val)
        } else {
            formatted = String(format: "%.1f", val)
        }
        if let unit = unit, !unit.isEmpty {
            return "\(formatted) \(unit)"
        }
        return formatted
    }
    
    // MARK: - Methods
    
    /// 删除记录
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Identifiable

extension HabitRecord: @retroactive Identifiable {}

// MARK: - Concurrency

extension HabitRecord: @unchecked Sendable {}
