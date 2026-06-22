import XCTest
@testable import Holo

/// 验证 `MemoryInsightContextBuilder.effectivePeriodRange` 的周期回退范围正确性。
///
/// 背景：当本周期天数不足阈值（周 3 天、月 7 天）时会回退到上一周期。
/// 旧实现里 `periodRange` 用 `min(start.addingDays(N), referenceDate)` 截断 end，
/// 本意是「本期不超过今天」。但回退逻辑传入的 `referenceDate` 是上一周期内的日期，
/// 会把上一周期的 end 错误截断到上一周期起点，导致回退后的范围只剩 1 天。
/// 星图、AI 洞察、首页日程都依赖此 range，错配时表现为「周期内无数据」。
///
/// 修复后 `periodRange` 的截断上限改为 `now`（默认今天），与 `referenceDate` 解耦，
/// 回退到历史周期时能返回完整的历史周期范围。这里通过显式注入 `now` 让测试确定、
/// 不依赖真实运行日。
final class MemoryInsightContextBuilderPeriodRangeTests: XCTestCase {

    // MARK: - Weekly 回退（核心：周一触发，星图空白根因）

    func testWeeklyFallbackOnMondayCoversFullPreviousWeek() {
        // 假设今天是 2026-06-22（周一）：本周 daySpan=0 < 阈值 3，应回退到上一周
        let monday = makeDate(year: 2026, month: 6, day: 22)
        let result = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .weekly,
            referenceDate: monday,
            now: monday
        )

        XCTAssertTrue(result.isFallback, "周一当周天数不足，应回退到上一周")

        // 上一周应为 06-15(周一) ~ 06-21(周日)，完整 7 天
        XCTAssertEqual(result.start, makeDate(year: 2026, month: 6, day: 15))
        XCTAssertEqual(
            result.end,
            makeDate(year: 2026, month: 6, day: 21),
            "回退后的上一周应覆盖到周日，而非被截断到上周一"
        )

        let span = Calendar.current.dateComponents([.day], from: result.start, to: result.end).day
        XCTAssertEqual(span, 6, "上一周 start→end 应间隔 6 天（覆盖 7 个自然日），而非 0 天")
    }

    func testWeeklyNoFallbackOnThursday() {
        // 假设今天是 2026-06-25（周四）：本周 daySpan=3 >= 阈值 3，不应回退
        let thursday = makeDate(year: 2026, month: 6, day: 25)
        let result = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .weekly,
            referenceDate: thursday,
            now: thursday
        )

        XCTAssertFalse(result.isFallback, "周四当周天数足够，不应回退")
        XCTAssertEqual(result.start, makeDate(year: 2026, month: 6, day: 22))
        XCTAssertEqual(result.end, makeDate(year: 2026, month: 6, day: 25))
    }

    // MARK: - Monthly 回退（同 bug 在月度的体现）

    func testMonthlyFallbackOnFirstDayCoversFullPreviousMonth() {
        // 假设今天是 2026-06-01（月初）：本月 daySpan=0 < 阈值 7，应回退到 5 月
        let firstDay = makeDate(year: 2026, month: 6, day: 1)
        let result = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .monthly,
            referenceDate: firstDay,
            now: firstDay
        )

        XCTAssertTrue(result.isFallback, "月初本月天数不足，应回退到上月")

        // 上月（5 月）应为 05-01 ~ 05-31，完整覆盖
        XCTAssertEqual(result.start, makeDate(year: 2026, month: 5, day: 1))
        XCTAssertEqual(
            result.end,
            makeDate(year: 2026, month: 5, day: 31),
            "回退后的上月应覆盖到月末，而非被截断到 05-01"
        )
    }

    func testMonthlyNoFallbackMidMonth() {
        // 假设今天是 2026-06-15：本月 daySpan=14 >= 阈值 7，不应回退
        let midMonth = makeDate(year: 2026, month: 6, day: 15)
        let result = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .monthly,
            referenceDate: midMonth,
            now: midMonth
        )

        XCTAssertFalse(result.isFallback)
        XCTAssertEqual(result.start, makeDate(year: 2026, month: 6, day: 1))
        XCTAssertEqual(result.end, makeDate(year: 2026, month: 6, day: 15))
    }

    // MARK: - 辅助

    /// 构造确定性的本地时区当天 0 点日期，避免依赖「今天」。
    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else {
            XCTFail("无法构造测试日期 \(year)-\(month)-\(day)")
            return Date()
        }
        return Calendar.current.startOfDay(for: date)
    }
}
