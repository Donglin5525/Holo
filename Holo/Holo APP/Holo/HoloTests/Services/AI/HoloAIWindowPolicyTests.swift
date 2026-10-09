import XCTest
@testable import Holo

/// 2026-10-09 降本两件套：谷时段判定钉死（DeepSeek 峰谷计费口径，钉北京时间）。
/// 高峰=工作日 9-12、14-18；其余谷；周六周日全天谷（官方 2026-08-23 更新）。
final class HoloAIWindowPolicyTests: XCTestCase {

    private let calendar = HoloAIWindowPolicy.beijingCalendar()

    /// 北京时间指定时刻（工作日 2026-10-09 是周五；周末取 10-10 周六 / 10-11 周日）。
    private func beijingDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - isValleyWindow 工作日边界

    func test工作日高峰边界() {
        // 周五 2026-10-09
        let cases: [(Int, Int, Bool)] = [
            (8, 59, true),   // 高峰前一分钟：谷
            (9, 0, false),   // 高峰起点
            (11, 59, false), // 上午高峰末分钟
            (12, 0, true),   // 午间谷起点
            (13, 59, true),  // 午间谷末分钟
            (14, 0, false),  // 下午高峰起点
            (17, 59, false), // 下午高峰末分钟
            (18, 0, true),   // 晚间谷起点
            (23, 30, true),  // 深夜
            (0, 0, true),    // 凌晨
        ]
        for (hour, minute, expectedValley) in cases {
            let date = beijingDate(2026, 10, 9, hour, minute)
            XCTAssertEqual(
                HoloAIWindowPolicy.isValleyWindow(at: date, calendar: calendar),
                expectedValley,
                "北京 \(hour):\(String(format: "%02d", minute)) 应为\(expectedValley ? "谷" : "峰")"
            )
        }
    }

    func test周末全天谷() {
        // 周六 10-10 / 周日 10-11，取原本的工作日高峰时刻
        for day in [10, 11] {
            for hour in [9, 10, 15, 17] {
                let date = beijingDate(2026, 10, day, hour)
                XCTAssertTrue(
                    HoloAIWindowPolicy.isValleyWindow(at: date, calendar: calendar),
                    "10-\(day) \(hour)点（周末）应为谷"
                )
            }
        }
    }

    // MARK: - nextValleyStart

    func test谷时调用返回自身() {
        let date = beijingDate(2026, 10, 9, 19, 30)
        XCTAssertEqual(HoloAIWindowPolicy.nextValleyStart(after: date, calendar: calendar), date)
        let weekend = beijingDate(2026, 10, 10, 10, 0)
        XCTAssertEqual(HoloAIWindowPolicy.nextValleyStart(after: weekend, calendar: calendar), weekend)
    }

    func test上午高峰顺延到当日12点() {
        let date = beijingDate(2026, 10, 9, 10, 30)
        let expected = beijingDate(2026, 10, 9, 12, 0)
        XCTAssertEqual(HoloAIWindowPolicy.nextValleyStart(after: date, calendar: calendar), expected)
    }

    func test下午高峰顺延到当日18点() {
        let date = beijingDate(2026, 10, 9, 15, 0)
        let expected = beijingDate(2026, 10, 9, 18, 0)
        XCTAssertEqual(HoloAIWindowPolicy.nextValleyStart(after: date, calendar: calendar), expected)
    }

    func test高峰起点边界顺延() {
        // 9:00 整（高峰第一分钟）→ 12:00；14:00 整 → 18:00
        XCTAssertEqual(
            HoloAIWindowPolicy.nextValleyStart(after: beijingDate(2026, 10, 9, 9, 0), calendar: calendar),
            beijingDate(2026, 10, 9, 12, 0)
        )
        XCTAssertEqual(
            HoloAIWindowPolicy.nextValleyStart(after: beijingDate(2026, 10, 9, 14, 0), calendar: calendar),
            beijingDate(2026, 10, 9, 18, 0)
        )
    }
}
