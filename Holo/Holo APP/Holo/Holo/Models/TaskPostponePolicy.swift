//
//  TaskPostponePolicy.swift
//  Holo
//
//  任务延期选项的唯一规则源：任务的时间形态 → 选项列表。
//  延期列表左滑、时间胶囊、详情页三个入口共用本规则，永不出现选项不一致。
//
//  规则（与设计原型 docs/design-prototypes/task-postpone-prototype.html 一致）：
//  · 定时·未过期：分钟档（锚原时刻，17:00 延 15 分钟 = 17:15）+ 跨天档（保时刻，天数锚今天）
//  · 全天：天数档（明天 / 三天后 / 一周后），落点仍是全天
//  · 已过期：第一档永远是「今天」（定时=今天原时刻，已过则 +30 分钟；全天=今天）
//  · 每档双行：主词 + 实际落点，跨午夜顺延直接显示「明天 00:20」
//

import Foundation

/// 延期面板的一个选项
struct TaskPostponeOption: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 今天内顺延 N 分钟（仅定时·未过期任务出现，锚原时刻）
        case delayMinutes(Int)
        /// 推到另一天（定时保时刻 / 全天保持全天）
        case anotherDay
        /// 自定义（面板内嵌日期选择，targetDate 由面板生成后回填）
        case custom
    }

    let id: String
    /// 主词：15分钟后 / 今天 / 明天 / 三天后…
    let label: String
    /// 落点小字：17:15 / 今天 21:00 / 周五 17:00 / 明天
    let subLabel: String
    /// 落点截止时间（custom 时为 nil，由面板生成）
    let targetDate: Date?
    /// 落点是否全天
    let isAllDay: Bool
    let kind: Kind
    /// 是否第一档（面板中高亮为推荐位）
    let isPrimary: Bool

    var isCustom: Bool { kind == .custom }
}

enum TaskPostponePolicy {

    /// 生成延期选项。入参全部为纯值，便于独立编译测试。
    static func options(
        dueDate: Date,
        isAllDay: Bool,
        isOverdue: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TaskPostponeOption] {
        var options: [TaskPostponeOption] = []

        if isOverdue {
            if isAllDay {
                options.append(
                    TaskPostponeOption(
                        id: "today",
                        label: "今天",
                        subLabel: "今天",
                        targetDate: calendar.startOfDay(for: now),
                        isAllDay: true,
                        kind: .anotherDay,
                        isPrimary: true
                    )
                )
            } else {
                let (target, originalTimePassed) = overdueTodayTarget(
                    dueDate: dueDate, isAllDay: false, now: now, calendar: calendar
                )
                let time = timeString(target, calendar: calendar)
                options.append(
                    TaskPostponeOption(
                        id: "today",
                        label: "今天",
                        subLabel: originalTimePassed ? "\(time)（原时刻已过）" : time,
                        targetDate: target,
                        isAllDay: false,
                        kind: .anotherDay,
                        isPrimary: true
                    )
                )
            }
            options.append(
                contentsOf: anotherDayOptions(
                    dueDate: dueDate, isAllDay: isAllDay, now: now, calendar: calendar
                )
            )
        } else if isAllDay {
            // 全天：天数档（天数锚今天，落点仍是全天）
            for (offset, label) in [(1, "明天"), (3, "三天后"), (7, "一周后")] {
                let target = calendar.date(byAdding: .day, value: offset, to: now)!
                options.append(
                    TaskPostponeOption(
                        id: "day-\(offset)",
                        label: label,
                        subLabel: dayLabel(target, withTime: false, now: now, calendar: calendar),
                        targetDate: calendar.startOfDay(for: target),
                        isAllDay: true,
                        kind: .anotherDay,
                        isPrimary: offset == 1
                    )
                )
            }
        } else {
            // 定时·未过期：分钟档锚原时刻（始终在未来：任务一旦过点即变「过期」形态）
            for (minutes, label) in [(15, "15分钟后"), (30, "30分钟后"), (60, "1小时后")] {
                let target = calendar.date(byAdding: .minute, value: minutes, to: dueDate)!
                let subLabel = calendar.isDate(target, inSameDayAs: now)
                    ? timeString(target, calendar: calendar)
                    : dayLabel(target, withTime: true, now: now, calendar: calendar) // 跨午夜：明天 00:20
                options.append(
                    TaskPostponeOption(
                        id: "delay-\(minutes)",
                        label: label,
                        subLabel: subLabel,
                        targetDate: target,
                        isAllDay: false,
                        kind: .delayMinutes(minutes),
                        isPrimary: minutes == 15
                    )
                )
            }
            options.append(
                contentsOf: anotherDayOptions(
                    dueDate: dueDate, isAllDay: isAllDay, now: now, calendar: calendar
                )
            )
        }

        options.append(
            TaskPostponeOption(
                id: "custom",
                label: "自定义",
                subLabel: "日期与时间",
                targetDate: nil,
                isAllDay: isAllDay,
                kind: .custom,
                isPrimary: false
            )
        )
        return options
    }

    /// 过期任务推「今天」的落点：定时=今天原时刻（已过则现在 +30 分钟），全天=今天零点。
    /// 过期组头「全部 → 今天」批量入口与单任务选项共用此规则。
    static func overdueTodayTarget(
        dueDate: Date,
        isAllDay: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> (target: Date, originalTimePassed: Bool) {
        if isAllDay {
            return (calendar.startOfDay(for: now), false)
        }
        let timeComponents = calendar.dateComponents([.hour, .minute], from: dueDate)
        let candidate = calendar.date(
            bySettingHour: timeComponents.hour ?? 0,
            minute: timeComponents.minute ?? 0,
            second: 0,
            of: now
        ) ?? now
        if candidate > now {
            return (candidate, false)
        }
        return (calendar.date(byAdding: .minute, value: 30, to: now) ?? now, true)
    }

    /// 是否可延期：有截止日期、未完成、非重复任务（重复任务一期不接延期）
    static func canPostpone(dueDate: Date?, completed: Bool, repeatRuleExists: Bool) -> Bool {
        dueDate != nil && !completed && !repeatRuleExists
    }

    // MARK: - Private

    /// 跨天档：明天 / 三天后 / 一周后。天数锚今天；定时任务保留原时刻。
    private static func anotherDayOptions(
        dueDate: Date,
        isAllDay: Bool,
        now: Date,
        calendar: Calendar
    ) -> [TaskPostponeOption] {
        let specs: [(Int, String)] = [(1, "明天"), (3, "三天后"), (7, "一周后")]
        return specs.map { offset, label in
            let target: Date
            if isAllDay {
                target = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: offset, to: now)!
                )
            } else {
                let timeComponents = calendar.dateComponents([.hour, .minute], from: dueDate)
                target = calendar.date(
                    bySettingHour: timeComponents.hour ?? 0,
                    minute: timeComponents.minute ?? 0,
                    second: 0,
                    of: calendar.date(byAdding: .day, value: offset, to: now)!
                )!
            }
            return TaskPostponeOption(
                id: "day-\(offset)",
                label: label,
                subLabel: dayLabel(target, withTime: !isAllDay, now: now, calendar: calendar),
                targetDate: target,
                isAllDay: isAllDay,
                kind: .anotherDay,
                isPrimary: false
            )
        }
    }

    /// 落点日期文案：明天 → 周五（≤6 天）→ 下周二（>6 天）；需要时带时刻。
    /// 用天数差而非周归属判断「下周」：周四延三天到周日，用户心智是「周日」不是「下周日」。
    private static func dayLabel(
        _ date: Date,
        withTime: Bool,
        now: Date,
        calendar: Calendar
    ) -> String {
        let dayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        // component(.weekday) 返回 1（周日）~7（周六），数组下标是 0~6，必须减一对齐
        let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
        let weekdayName = weekdayNames[calendar.component(.weekday, from: date) - 1]
        var label: String
        if dayOffset == 1 {
            label = "明天"
        } else if dayOffset > 6 {
            label = "下周" + weekdayName
        } else {
            label = "周" + weekdayName
        }
        if withTime {
            label += " " + timeString(date, calendar: calendar)
        }
        return label
    }

    private static func timeString(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
