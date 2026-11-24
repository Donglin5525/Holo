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

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        TodoTaskDatePolicyStandaloneTests.main()
    }
}
#endif
struct TodoTaskDatePolicyStandaloneTests {

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
        guard condition else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("断言失败：\(message)")
            return
            #else
            fatalError("断言失败：\(message)")
            #endif
        }
        print("  ✓ \(message)")
    }
}
