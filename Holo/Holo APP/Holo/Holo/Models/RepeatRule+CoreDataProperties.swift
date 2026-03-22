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

    /// 结束条件类型
    var endConditionType: EndConditionType {
        if untilDate != nil {
            return .onDate
        } else if untilCount > 0 {
            return .afterCount
        } else {
            return .never
        }
    }

    // MARK: - 下一次重复日期计算

    /// 计算下一次重复日期
    /// - Parameter fromDate: 起始日期
    /// - Returns: 下一次重复日期，如果已达到结束条件则返回 nil
    func nextDueDate(from fromDate: Date) -> Date? {
        let calendar = Calendar.current

        // 检查是否达到结束条件
        if let untilDate = untilDate {
            let nextDate = calculateNextRawDate(from: fromDate, calendar: calendar)
            if let next = nextDate, next > untilDate {
                return nil
            }
            return nextDate
        }

        // TODO: 支持 untilCount 检查（需要追踪已完成次数）

        return calculateNextRawDate(from: fromDate, calendar: calendar)
    }

    /// 计算原始的下一个日期（不考虑结束条件）
    private func calculateNextRawDate(from fromDate: Date, calendar: Calendar) -> Date? {
        switch repeatType {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: fromDate)

        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: fromDate)

        case .monthly:
            // 检查是否使用"第N个周X"模式
            if monthWeekOrdinal > 0, let weekday = monthWeekdayValue {
                return nextNthWeekdayOfMonth(from: fromDate, ordinal: Int(monthWeekOrdinal), weekday: weekday, calendar: calendar)
            } else {
                // 固定日期模式
                return calendar.date(byAdding: .month, value: 1, to: fromDate)
            }

        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: fromDate)

        case .custom:
            return nextCustomDate(from: fromDate, calendar: calendar)
        }
    }

    /// 计算"每月第N个周X"的下一个日期
    private func nextNthWeekdayOfMonth(from fromDate: Date, ordinal: Int, weekday: Weekday, calendar: Calendar) -> Date? {
        // 获取下个月
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: fromDate) else { return nil }

        // 找到下个月的第N个周X
        return nthWeekdayOfMonth(for: nextMonth, ordinal: ordinal, weekday: weekday, calendar: calendar)
    }

    /// 找到指定月份的第N个周X
    private func nthWeekdayOfMonth(for month: Date, ordinal: Int, weekday: Weekday, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.weekday = weekday.rawValue
        components.weekdayOrdinal = ordinal

        return calendar.date(from: components)
    }

    /// 计算自定义重复的下一个日期
    private func nextCustomDate(from fromDate: Date, calendar: Calendar) -> Date? {
        let weekdays = weekdaysArray
        guard !weekdays.isEmpty else { return nil }

        // 从第二天开始查找下一个匹配的星期
        for dayOffset in 1...7 {
            guard let candidateDate = calendar.date(byAdding: .day, value: dayOffset, to: fromDate) else { continue }
            let candidateWeekday = calendar.component(.weekday, from: candidateDate)
            if weekdays.contains(where: { $0.rawValue == candidateWeekday }) {
                return candidateDate
            }
        }

        return nil
    }

    // MARK: - 显示描述

    /// 显示描述文本
    var displayDescription: String {
        let baseDescription: String

        switch repeatType {
        case .daily:
            baseDescription = "每天"

        case .weekly:
            let weekdays = weekdaysArray
            if weekdays.isEmpty {
                baseDescription = "每周"
            } else if isWeekdays {
                baseDescription = "工作日"
            } else {
                let weekdayNames = weekdays.sorted(by: { $0.rawValue < $1.rawValue })
                    .map { $0.displayTitle }
                    .joined(separator: "、")
                baseDescription = "每周\(weekdayNames)"
            }

        case .monthly:
            if monthWeekOrdinal > 0, let weekday = monthWeekdayValue {
                let ordinalNames = ["", "第一", "第二", "第三", "第四", "第五"]
                let ordinalName = monthWeekOrdinal < ordinalNames.count ? ordinalNames[Int(monthWeekOrdinal)] : "第\(monthWeekOrdinal)"
                baseDescription = "每月\(ordinalName)个\(weekday.displayTitle)"
            } else if monthDay > 0 {
                baseDescription = "每月\(monthDay)日"
            } else {
                baseDescription = "每月"
            }

        case .yearly:
            baseDescription = "每年"

        case .custom:
            let weekdays = weekdaysArray
            if weekdays.isEmpty {
                baseDescription = "自定义"
            } else if isWeekdays {
                baseDescription = "工作日"
            } else {
                let weekdayNames = weekdays.sorted(by: { $0.rawValue < $1.rawValue })
                    .map { $0.displayTitle }
                    .joined(separator: "、")
                baseDescription = "每周\(weekdayNames)"
            }
        }

        // 添加结束条件描述
        if let untilDate = untilDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return "\(baseDescription)，直到\(formatter.string(from: untilDate))"
        } else if untilCount > 0 {
            return "\(baseDescription)，重复\(untilCount)次"
        }

        return baseDescription
    }

    /// 判断是否是工作日重复
    private var isWeekdays: Bool {
        let weekdays = weekdaysArray
        let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        return Set(weekdays) == workdays
    }
}
