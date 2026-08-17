//
//  TodoTaskDatePolicy.swift
//  Holo
//
//  任务日期语义的唯一规则：全天任务的截止点是当天结束，而不是当天 00:00。
//

import Foundation

enum TodoTaskDatePolicy {

    /// 计算任务真正的截止时刻。
    /// 全天任务存储的是日期，展示和过期判断统一按当天 23:59:59 处理。
    static func effectiveDueDate(
        dueDate: Date?,
        isAllDay: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        guard let dueDate else { return nil }
        guard isAllDay else { return dueDate }

        return calendar.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: dueDate
        )
    }

    /// 判断未完成任务是否已过期。
    static func isOverdue(
        dueDate: Date?,
        isAllDay: Bool,
        completed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !completed,
              let effectiveDueDate = effectiveDueDate(
                dueDate: dueDate,
                isAllDay: isAllDay,
                calendar: calendar
              ) else {
            return false
        }
        return effectiveDueDate < now
    }

    static func isDueToday(
        dueDate: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let dueDate else { return false }
        return calendar.isDateInToday(dueDate)
    }

    static func isDueTomorrow(
        dueDate: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let dueDate else { return false }
        return calendar.isDateInTomorrow(dueDate)
    }
}
