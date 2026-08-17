//
//  TodoTaskDatePolicyStandaloneTests.swift
//  Holo
//
//  运行：
//    swiftc Holo/Models/TodoTaskDatePolicy.swift \
//      HoloTests/Models/TodoTaskDatePolicyStandaloneTests.swift \
//      -o /tmp/todo-task-date-policy-tests && /tmp/todo-task-date-policy-tests
//

import Foundation

@main
private struct TodoTaskDatePolicyStandaloneTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let today = calendar.startOfDay(for: Date())
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func main() {
        let now = date(12)

        expect(
            !TodoTaskDatePolicy.isOverdue(
                dueDate: date(0),
                isAllDay: true,
                completed: false,
                now: now,
                calendar: calendar
            ),
            "今天的全天任务在当天中午不能算过期"
        )
        expect(
            TodoTaskDatePolicy.isOverdue(
                dueDate: date(9),
                isAllDay: false,
                completed: false,
                now: now,
                calendar: calendar
            ),
            "今天 09:00 的定时任务在中午应算过期"
        )
        expect(
            TodoTaskDatePolicy.isOverdue(
                dueDate: date(0, dayOffset: -1),
                isAllDay: true,
                completed: false,
                now: now,
                calendar: calendar
            ),
            "昨天的全天任务应算过期"
        )
        expect(
            !TodoTaskDatePolicy.isOverdue(
                dueDate: date(0),
                isAllDay: true,
                completed: true,
                now: now,
                calendar: calendar
            ),
            "已完成任务不应算过期"
        )

        print("✅ TodoTaskDatePolicyStandaloneTests 全部通过")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("断言失败：\(message)") }
        print("  ✓ \(message)")
    }
}
