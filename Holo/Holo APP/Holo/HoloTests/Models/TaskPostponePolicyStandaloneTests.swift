//
//  TaskPostponePolicyStandaloneTests.swift
//  Holo
//
//  运行：
//    swiftc Holo/Models/TaskPostponePolicy.swift \
//      HoloTests/Models/TaskPostponePolicyStandaloneTests.swift \
//      -o /tmp/task-postpone-policy-tests && /tmp/task-postpone-policy-tests
//

import Foundation

@main
private struct TaskPostponePolicyStandaloneTests {

    /// 固定日历：2026-08-25（周三）为「今天」，与设计原型同一时间基准
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_587_200)) // 2026-08-25（周二）00:00 +08
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func main() {
        let now = date(16, 20) // 周二 16:20

        // MARK: 定时 · 未过期（今天 17:00）
        let timed = TaskPostponePolicy.options(
            dueDate: date(17, 0), isAllDay: false, isOverdue: false, now: now, calendar: calendar
        )
        let delays = timed.filter {
            if case .delayMinutes = $0.kind { return true }
            return false
        }
        expect(delays.map(\.subLabel) == ["17:15", "17:30", "18:00"], "17:00 的顺延档锚原时刻：17:15/17:30/18:00")
        expect(delays.map(\.label) == ["15分钟后", "30分钟后", "1小时后"], "顺延档主词")
        expect(delays.first?.isPrimary == true, "顺延档第一档是推荐位")
        let timedDays = timed.filter { $0.kind != .custom && delays.map(\.id).contains($0.id) == false }
        expect(
            timedDays.map(\.subLabel) == ["明天 17:00", "周五 17:00", "下周二 17:00"],
            "跨天档保时刻：明天/周五/下周二 17:00（8/25 周二 +3=周五、+7=下周二）"
        )
        expect(timed.last?.isCustom == true, "面板末尾必有自定义档")

        // MARK: 定时 · 跨午夜（23:50 + 30 分钟）
        let late = TaskPostponePolicy.options(
            dueDate: date(23, 50), isAllDay: false, isOverdue: false, now: now, calendar: calendar
        )
        expect(
            late.first { $0.label == "30分钟后" }?.subLabel == "明天 00:20",
            "23:50 延 30 分钟跨午夜，落点直写「明天 00:20」"
        )

        // MARK: 全天 · 今天
        let allDay = TaskPostponePolicy.options(
            dueDate: date(0), isAllDay: true, isOverdue: false, now: now, calendar: calendar
        )
        let allDayDays = allDay.filter { $0.kind != .custom }
        expect(
            allDayDays.map(\.label) == ["明天", "三天后", "一周后"],
            "全天档 = 明天/三天后/一周后（无本周末，已拍板砍掉）"
        )
        expect(
            allDayDays.map(\.subLabel) == ["明天", "周五", "下周二"],
            "全天落点小字不带时刻（+3=周五、+7=下周二）"
        )
        expect(allDayDays.allSatisfy(\.isAllDay), "全天任务延期后仍是全天")
        // 用固定基准日比较，禁用 isDateInToday（它读真实系统时钟，基准日一过断言必翻车）
        expect(
            allDayDays.allSatisfy { calendar.isDate($0.targetDate!, inSameDayAs: now) == false
                && calendar.component(.hour, from: $0.targetDate!) == 0 },
            "全天落点对齐到目标日零点"
        )

        // MARK: 周三基准（三天后 = 周六，weekday=7 曾触发下标越界真机闪退）
        let wednesday = date(10, 0, dayOffset: 1)
        let fromWednesday = TaskPostponePolicy.options(
            dueDate: date(17, 0, dayOffset: 1), isAllDay: false, isOverdue: false,
            now: wednesday, calendar: calendar
        )
        expect(
            fromWednesday.first { $0.id == "day-3" }?.subLabel == "周六 17:00",
            "周三定时延三天 = 周六（weekday 7 下标不越界）"
        )
        let wednesdayAllDay = TaskPostponePolicy.options(
            dueDate: date(0, dayOffset: 1), isAllDay: true, isOverdue: false,
            now: wednesday, calendar: calendar
        )
        expect(
            wednesdayAllDay.filter { $0.kind != .custom }.map(\.subLabel) == ["明天", "周六", "下周三"],
            "周三全天档：三天后 = 周六，文案不越界"
        )

        // MARK: 过期 · 定时（昨天 21:00）
        let overdueTimed = TaskPostponePolicy.options(
            dueDate: date(21, 0, dayOffset: -1), isAllDay: false, isOverdue: true, now: now, calendar: calendar
        )
        expect(overdueTimed.first?.label == "今天", "过期面板第一档永远是「今天」")
        expect(overdueTimed.first?.subLabel == "21:00", "过期定时推今天 = 今天原时刻（未过）")
        expect(overdueTimed.first?.isPrimary == true, "今天档是推荐位")
        expect(
            overdueTimed.first { $0.label == "明天" }?.subLabel == "明天 21:00",
            "过期任务明天档保时刻"
        )

        // MARK: 过期 · 定时且今天原时刻已过（now 22:00）
        let lateNow = date(22, 0)
        let overduePassed = TaskPostponePolicy.options(
            dueDate: date(21, 0, dayOffset: -1), isAllDay: false, isOverdue: true, now: lateNow, calendar: calendar
        )
        expect(
            overduePassed.first?.subLabel == "22:30（原时刻已过）",
            "原时刻已过 → 今天档顺延 30 分钟并标注"
        )

        // MARK: 过期 · 全天（昨天）
        let overdueAllDay = TaskPostponePolicy.options(
            dueDate: date(0, dayOffset: -1), isAllDay: true, isOverdue: true, now: now, calendar: calendar
        )
        expect(overdueAllDay.first?.label == "今天", "过期全天第一档 = 今天")
        expect(
            overdueAllDay.first?.targetDate == calendar.startOfDay(for: now),
            "过期全天落点 = 今天零点"
        )

        // MARK: overdueTodayTarget（批量入口共用规则）
        let (allDayTarget, _) = TaskPostponePolicy.overdueTodayTarget(
            dueDate: date(0, dayOffset: -3), isAllDay: true, now: now, calendar: calendar
        )
        expect(allDayTarget == calendar.startOfDay(for: now), "批量：过期全天推今天零点")

        // MARK: canPostpone
        expect(TaskPostponePolicy.canPostpone(dueDate: date(17), completed: false, repeatRuleExists: false),
               "有截止日期的普通任务可延期")
        expect(!TaskPostponePolicy.canPostpone(dueDate: nil, completed: false, repeatRuleExists: false),
               "未安排任务不可延期（那是安排，不是延期）")
        expect(!TaskPostponePolicy.canPostpone(dueDate: date(17), completed: true, repeatRuleExists: false),
               "已完成任务不可延期")
        expect(!TaskPostponePolicy.canPostpone(dueDate: date(17), completed: false, repeatRuleExists: true),
               "重复任务一期不接延期")

        // MARK: 自定义档不带落点（由面板生成）
        expect(
            timed.first { $0.isCustom }?.targetDate == nil,
            "自定义档 targetDate 为 nil，由面板回填"
        )

        print("✅ TaskPostponePolicyStandaloneTests 全部通过")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("断言失败：\(message)") }
        print("  ✓ \(message)")
    }
}
