import Foundation

// R05/R06（2026-10-04 体检）回归：任务输入统一验证契约。
// 覆盖：重复参数边界（interval 1…365 / 月日 1…31 / 序数 1…5 / 次数 1…999 / 空星期）
// 与计划时间日界的夏令时正确性（旧固定 24h 算法在洛杉矶春令时日得到次日 00:59）。
// 运行：bash scripts/run-task-input-contract-standalone.sh

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() {
        TaskInputContractStandaloneTests.main()
    }
}
#endif
struct TaskInputContractStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        repeatIntervalBounds()
        repeatMonthDayBounds()
        repeatOrdinalAndCountBounds()
        repeatWeekdaysContract()
        plannedRangeDayEndOrdinaryDay()
        plannedRangeDayEndDSTSpringForward()
        plannedRangeDayEndDSTFallBack()
        print("PASS: 重复参数四界+空星期+普通日/春令时/秋令时日界（R05/R06）")
    }

    // MARK: - R05 重复参数契约

    static func repeatIntervalBounds() {
        for bad in [0, -3, 366, 40000] {
            var threw = false
            do { try RepeatRuleContract.validatedInterval(bad) } catch { threw = true }
            check(threw, "间隔 \(bad) 必须拒绝")
        }
        for good in [1, 30, 365] {
            var threw = false
            do { try RepeatRuleContract.validatedInterval(good) } catch { threw = true }
            check(!threw, "间隔 \(good) 必须接受")
        }
    }

    static func repeatMonthDayBounds() {
        for bad in [0, -1, 32, 40000] {
            var threw = false
            do { try RepeatRuleContract.validatedMonthDay(bad) } catch { threw = true }
            check(threw, "月日 \(bad) 必须拒绝")
        }
        for good in [1, 15, 31] {
            var threw = false
            do { try RepeatRuleContract.validatedMonthDay(good) } catch { threw = true }
            check(!threw, "月日 \(good) 必须接受")
        }
    }

    static func repeatOrdinalAndCountBounds() {
        for bad in [0, 6, -2] {
            var threw = false
            do { try RepeatRuleContract.validatedMonthWeekOrdinal(bad) } catch { threw = true }
            check(threw, "月内序数 \(bad) 必须拒绝")
        }
        for good in [1, 3, 5] {
            var threw = false
            do { try RepeatRuleContract.validatedMonthWeekOrdinal(good) } catch { threw = true }
            check(!threw, "月内序数 \(good) 必须接受")
        }
        for bad in [0, 1000, -1] {
            var threw = false
            do { try RepeatRuleContract.validatedUntilCount(bad) } catch { threw = true }
            check(threw, "重复次数 \(bad) 必须拒绝")
        }
        for good in [1, 12, 999] {
            var threw = false
            do { try RepeatRuleContract.validatedUntilCount(good) } catch { threw = true }
            check(!threw, "重复次数 \(good) 必须接受")
        }
    }

    static func repeatWeekdaysContract() {
        var threw = false
        do { try RepeatRuleContract.validatedWeekdays([]) } catch { threw = true }
        check(threw, "空星期列表必须拒绝")
        threw = false
        do { try RepeatRuleContract.validatedWeekdays([.monday, .friday]) } catch { threw = true }
        check(!threw, "非空星期列表必须接受")
    }

    // MARK: - R06 计划时间日界

    private static func laCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private static func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func plannedRangeDayEndOrdinaryDay() {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = date(shanghai, 2026, 10, 4, 9, 0)
        let end = PlannedRangeContract.dayEnd(from: day, calendar: shanghai)
        let expected = date(shanghai, 2026, 10, 4, 23, 59)
        check(end == expected, "普通日日界应为当天 23:59，实测 \(end)")
        let startBound = PlannedRangeContract.startUpperBound(from: day, calendar: shanghai)
        check(startBound == date(shanghai, 2026, 10, 4, 23, 45), "开始上界应为当天 23:45")
    }

    static func plannedRangeDayEndDSTSpringForward() {
        // 洛杉矶 2026-03-08 春令时：02:00→03:00，当天只有 23 小时。
        // 旧算法（startOfDay+24h-1min）实测得到次日 00:59——此断言把修复钉死。
        let calendar = laCalendar()
        let day = date(calendar, 2026, 3, 8, 10, 0)
        let end = PlannedRangeContract.dayEnd(from: day, calendar: calendar)
        let expected = date(calendar, 2026, 3, 8, 23, 59)
        check(end == expected, "春令时日日界应为当天 23:59，实测 \(end)")
        let legacy = calendar.startOfDay(for: day).addingTimeInterval(24 * 3600 - 60)
        check(legacy != end, "旧固定 24h 算法在该日必然算错，若相等说明修复被回退")
        check(calendar.isDate(end, inSameDayAs: day), "日界必须与当天同日")
    }

    static func plannedRangeDayEndDSTFallBack() {
        // 洛杉矶 2026-11-01 秋令时：02:00→01:00，当天有 25 小时
        let calendar = laCalendar()
        let day = date(calendar, 2026, 11, 1, 10, 0)
        let end = PlannedRangeContract.dayEnd(from: day, calendar: calendar)
        check(end == date(calendar, 2026, 11, 1, 23, 59), "秋令时日日界应为当天 23:59，实测 \(end)")
        check(calendar.isDate(end, inSameDayAs: day), "日界必须与当天同日")
    }
}
