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
    /// 补签标记：date 是补签目标日，createdAt 是实际补签时间
    @NSManaged public var isRetroactive: Bool
    
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
    
    /// 是否为今天的记录（自然日；习惯口径的今日判定走 Repository / attributedDay）
    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    /// 所属自然日（不含时间部分；不按结算时间平移，习惯统计口径请用 attributedDay）
    var dayDate: Date {
        Calendar.current.startOfDay(for: date)
    }

    // MARK: - 归属日（按习惯的每日结算时间，见 HabitDayAttribution）

    /// 归属时刻：实时记录按结算时间平移，补签/整日坐标记录原样
    func attributedMoment(dayEndMinutes: Int, calendar: Calendar = .current) -> Date {
        HabitDayAttribution.attributedMoment(
            recordDate: date,
            isRetroactive: isRetroactive,
            dayEndMinutes: dayEndMinutes,
            calendar: calendar
        )
    }

    /// 归属日（startOfDay）
    func attributedDay(dayEndMinutes: Int, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: attributedMoment(dayEndMinutes: dayEndMinutes, calendar: calendar))
    }

    /// 补签记录的实际补签时刻（createdAt；date 归到目标日当天零点，不反映补签时间）
    var retroactiveCreatedAtText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: createdAt)
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

extension HabitRecord: Identifiable {}
