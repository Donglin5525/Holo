//
//  RepeatRule+CoreDataProperties.swift
//  Holo
//
//  重复规则实体属性扩展
//

import Foundation
import CoreData

extension RepeatRule {

    // MARK: - 创建方法

    @nonobjc class func create(
        in context: NSManagedObjectContext,
        type: RepeatType,
        task: TodoTask? = nil
    ) -> RepeatRule {
        let rule = RepeatRule(context: context)
        rule.id = UUID()
        rule.type = type.rawValue
        rule.task = task
        rule.createdAt = Date()
        return rule
    }

    // MARK: - 计算属性

    /// 重复类型枚举值
    var repeatType: RepeatType {
        get { RepeatType(rawValue: type) ?? .daily }
        set { type = newValue.rawValue }
    }

    /// 解析星期数组
    var weekdaysArray: [Weekday] {
        get {
            guard let weekdaysStr = weekdays, !weekdaysStr.isEmpty else { return [] }
            return weekdaysStr.split(separator: ",").compactMap { part in
                Weekday(rawValue: Int(part) ?? 0)
            }
        }
        set {
            weekdays = newValue.map { "\($0.rawValue)" }.joined(separator: ",")
        }
    }

    /// 解析月周 weekday
    var monthWeekdayValue: Weekday? {
        get {
            guard let weekdayStr = monthWeekday, let weekday = Int(weekdayStr) else { return nil }
            return Weekday(rawValue: weekday)
        }
        set {
            monthWeekday = newValue.map { "\($0.rawValue)" }
        }
    }
}
