import XCTest
@testable import Holo

/// 谷时段门控退役断言（2026-10-19，随 qwen 全量切换）：isValleyWindow 恒谷、
/// nextValleyStart 恒返回传入时刻——守住「后台任务全天运行、不再延迟」的语义，
/// 防止后续改动无意间复活峰谷门控。历史峰谷边界口径见 git 历史。
final class HoloAIWindowPolicyTests: XCTestCase {

    private let calendar = HoloAIWindowPolicy.beijingCalendar()

    /// 北京时间指定时刻（工作日 2026-10-09 是周五；周末取 10-10 周六）。
    private func beijingDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 恒谷

    func test原高峰时刻也恒为谷() {
        // 周五工作日原高峰边界（9-12、14-18）与深夜/凌晨抽样
        let weekdayCases = [8, 9, 10, 11, 12, 14, 17, 18, 23]
        for hour in weekdayCases {
            XCTAssertTrue(
                HoloAIWindowPolicy.isValleyWindow(at: beijingDate(2026, 10, 9, hour), calendar: calendar),
                "工作日 \(hour) 点应为谷（门控已退役，全天可运行）"
            )
        }
        // 周末原高峰时刻
        for hour in [9, 15] {
            XCTAssertTrue(
                HoloAIWindowPolicy.isValleyWindow(at: beijingDate(2026, 10, 10, hour), calendar: calendar),
                "周末 \(hour) 点应为谷"
            )
        }
    }

    // MARK: - 不延迟

    func test任意时刻顺延返回自身() {
        // 原高峰时刻（上午/下午）与原谷时刻：nextValleyStart 一律返回传入时刻
        let cases = [
            beijingDate(2026, 10, 9, 10, 30),  // 原上午高峰
            beijingDate(2026, 10, 9, 15, 0),   // 原下午高峰
            beijingDate(2026, 10, 9, 19, 30),  // 原晚间谷
            beijingDate(2026, 10, 10, 10, 0),  // 原周末谷
        ]
        for date in cases {
            XCTAssertEqual(HoloAIWindowPolicy.nextValleyStart(after: date, calendar: calendar), date)
        }
    }
}
