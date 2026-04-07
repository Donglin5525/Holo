//
//  Habit.swift
//  Holo
//
//  习惯实体类
//  支持打卡型和数值型两种习惯
//

import Foundation
import CoreData
import SwiftUI

/// 习惯实体
@objc(Habit)
public class Habit: NSManagedObject {
    
    // MARK: - Core Data Properties
    
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var icon: String
    @NSManaged public var color: String
    @NSManaged public var type: Int16
    @NSManaged public var frequency: String
    @NSManaged public var targetCount: NSNumber?
    @NSManaged public var targetValue: NSNumber?
    @NSManaged public var unit: String?
    @NSManaged public var aggregationType: Int16
    @NSManaged public var isBadHabit: Bool
    @NSManaged public var isArchived: Bool
    @NSManaged public var sortOrder: Int16
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var records: NSSet?
    
    // MARK: - Computed Properties
    
    /// 习惯类型枚举
    var habitType: HabitType {
        get { HabitType(rawValue: type) ?? .checkIn }
        set { type = newValue.rawValue }
    }
    
    /// 频率枚举
    var habitFrequency: HabitFrequency {
        get { HabitFrequency(rawValue: frequency) ?? .daily }
        set { frequency = newValue.rawValue }
    }
    
    /// 聚合类型枚举
    var habitAggregationType: HabitAggregationType {
        get { HabitAggregationType(rawValue: aggregationType) ?? .sum }
        set { aggregationType = newValue.rawValue }
    }
    
    /// 是否为打卡型习惯
    var isCheckInType: Bool {
        habitType == .checkIn
    }
    
    /// 是否为数值型习惯
    var isNumericType: Bool {
        habitType == .numeric
    }
    
    /// 是否为计数类（SUM 聚合）
    var isCountType: Bool {
        isNumericType && habitAggregationType == .sum
    }
    
    /// 是否为测量类（LATEST 聚合）
    var isMeasureType: Bool {
        isNumericType && habitAggregationType == .latest
    }
    
    /// 目标次数（打卡型使用）
    var targetCountValue: Int? {
        get { targetCount?.intValue }
        set { targetCount = newValue.map { NSNumber(value: $0) } }
    }
    
    /// 目标数值（数值型使用）
    var targetValueDouble: Double? {
        get { targetValue?.doubleValue }
        set { targetValue = newValue.map { NSNumber(value: $0) } }
    }
    
    /// 习惯颜色
    var habitColor: Color {
        Color(hex: color) ?? .holoInfo
    }
    
    /// 是否为自定义图标（Asset Catalog 图标）
    var isCustomIcon: Bool {
        HabitIconPresets.allItems.first { $0.name == icon }?.isCustom ?? false
    }
    
    /// 记录数组
    var recordsArray: [HabitRecord] {
        let set = records as? Set<HabitRecord> ?? []
        return set.sorted { $0.date > $1.date }
    }
    
    /// 显示的单位文本
    var unitText: String {
        unit ?? (isCountType ? "次" : "")
    }
    
    /// 频率目标描述（如 "每周 5 次"）
    var frequencyTargetText: String {
        if isCheckInType {
            if let target = targetCountValue {
                return "\(habitFrequency.displayName) \(target) 次"
            }
            return habitFrequency.displayName
        } else {
            if let target = targetValueDouble {
                return "目标 \(formatValue(target)) \(unitText)"
            }
            return habitFrequency.displayName
        }
    }
    
    // MARK: - Helper Methods
    
    /// 格式化数值（小数点优化）
    func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
    
    /// 删除习惯
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Identifiable

extension Habit: @retroactive Identifiable {}

// MARK: - Concurrency

extension Habit: @unchecked Sendable {}
