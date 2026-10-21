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
    @NSManaged public var isPaused: Bool
    /// 计划恢复日（startOfDay；nil = 无限期暂停，手动恢复）
    @NSManaged public var pausedUntil: Date?
    /// 历次暂停窗口（[HabitPauseWindow] 的 Codable 编码；连续天数冻结口径的数据底账）
    @NSManaged public var pauseWindowsData: Data?
    @NSManaged public var sortOrder: Int16
    @NSManaged public var reminderMode: String
    @NSManaged public var reminderHour: Int16
    @NSManaged public var reminderMinute: Int16
    /// 每日结算时间（距零点的时/分；0:00 = 按自然日结算）。语义见 HabitDayAttribution
    @NSManaged public var dayEndHour: Int16
    @NSManaged public var dayEndMinute: Int16
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var records: NSSet?
    @NSManaged public var goal: Goal?
    
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

    /// 打卡提醒模式（原始值不认识时回落 follow，仅打卡型参与提醒）
    var habitReminderMode: HabitReminderMode {
        get { HabitReminderMode(rawValue: reminderMode) ?? .follow }
        set { reminderMode = newValue.rawValue }
    }

    /// 单独提醒时间（solo 模式使用）
    var reminderTime: (hour: Int, minute: Int) {
        get { (Int(reminderHour), Int(reminderMinute)) }
        set {
            reminderHour = Int16(newValue.hour)
            reminderMinute = Int16(newValue.minute)
        }
    }
    
    /// 是否为打卡型习惯
    var isCheckInType: Bool {
        habitType == .checkIn
    }

    // MARK: - 每日结算时间（日界平移）

    /// 结算时刻距零点的分钟数；0 = 凌晨 0 点结算（自然日，默认）
    var dayEndMinutes: Int { Int(dayEndHour) * 60 + Int(dayEndMinute) }

    var dayEndTime: (hour: Int, minute: Int) {
        get { (Int(dayEndHour), Int(dayEndMinute)) }
        set {
            dayEndHour = Int16(newValue.hour)
            dayEndMinute = Int16(newValue.minute)
        }
    }

    var hasCustomDayEnd: Bool { dayEndMinutes != 0 }

    /// 把一个真实时刻换到该习惯的日界坐标（结算前的时刻落回前一天）
    func attributedMoment(_ moment: Date) -> Date {
        HabitDayAttribution.attributedMoment(moment, dayEndMinutes: dayEndMinutes)
    }

    func attributedDay(_ moment: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: attributedMoment(moment))
    }

    /// 该习惯此刻所处的「今天」：结算时间前仍是前一天
    func currentDay(now: Date = Date(), calendar: Calendar = .current) -> Date {
        attributedDay(now, calendar: calendar)
    }

    /// 创建日（习惯口径）：结算前创建的习惯归前一天，凌晨建完立刻打卡不会被判成「创建前」
    func creationDay(calendar: Calendar = .current) -> Date {
        attributedDay(createdAt, calendar: calendar)
    }

    // MARK: - 暂停窗口（冻结口径：暂停日不算断、不计数）

    /// 历次暂停窗口（编码存 pauseWindowsData）
    var pauseWindows: [HabitPauseWindow] {
        get {
            guard let data = pauseWindowsData else { return [] }
            return (try? JSONDecoder().decode([HabitPauseWindow].self, from: data)) ?? []
        }
        set {
            pauseWindowsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// 某一天是否处于暂停窗口内（开放窗口视为延伸至今天）
    func isDayPaused(_ day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let today = currentDay(calendar: calendar)
        return pauseWindows.contains { window in
            let start = calendar.startOfDay(for: window.startDate)
            guard dayStart >= start else { return false }
            guard let end = window.endDate else { return dayStart <= today }
            return dayStart <= calendar.startOfDay(for: end)
        }
    }

    /// 进行中（未关闭）的暂停窗口；无则 nil
    var openPauseWindow: HabitPauseWindow? {
        pauseWindows.last { $0.endDate == nil }
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
        Color(hex: color)
    }
    
    /// 是否为自定义图标（Asset Catalog 图标）
    var isCustomIcon: Bool {
        EntityIconAsset.isAsset(icon)
    }
    
    /// 记录数组
    var recordsArray: [HabitRecord] {
        let set = records as? Set<HabitRecord> ?? []
        return set.sorted { $0.date > $1.date }
    }
    
    /// 显示的单位文本
    var unitText: String {
        unit ?? (isCountType ? String(localized: "次") : "")
    }
    
    /// 频率目标描述（如 "每周 5 次"）
    var frequencyTargetText: String {
        if isCheckInType {
            if let target = targetCountValue {
                return String(localized: "\(habitFrequency.displayName) \(target) 次")
            }
            return habitFrequency.displayName
        } else {
            if let target = targetValueDouble {
                return String(localized: "目标 \(formatValue(target)) \(unitText)")
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

extension Habit: Identifiable {}

// MARK: - 暂停窗口

/// 一次暂停的时间窗口（连续天数冻结口径的最小数据单元）
/// - startDate: 暂停生效日（当天）
/// - endDate: 最后一个被冻结的日子（含）；nil = 进行中，计算时延伸至今天。
///   恢复日 = endDate 的次日；当天暂停当天恢复的窗口（start >= end）无效，落库前移除。
struct HabitPauseWindow: Codable, Equatable {
    var startDate: Date
    var endDate: Date?
}

// MARK: - 打卡提醒模式

/// 习惯打卡提醒模式（推送管理 · 习惯按条设提醒时间）
/// - follow: 跟随每日汇总，在汇总时间与其他习惯一起提醒
/// - solo: 单独时间，按习惯自己设置的 reminderTime 单独提醒
/// - none: 不提醒
enum HabitReminderMode: String, CaseIterable, Identifiable {
    case follow = "follow"
    case solo = "solo"
    case none = "none"

    var id: String { rawValue }

    /// 显示名称
    var displayName: String {
        switch self {
        case .follow: return String(localized: "跟随每日汇总")
        case .solo: return String(localized: "设单独提醒时间")
        case .none: return String(localized: "不提醒")
        }
    }
}
