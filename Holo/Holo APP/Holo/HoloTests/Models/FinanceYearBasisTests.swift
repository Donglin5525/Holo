import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        FinanceYearBasisTests.main()
    }
}
#endif

/// 年度口径引擎测试：记账年区间、按口径平移、已过周期数、月均与同比模型。
/// 只测纯函数（startDay 显式传参），不经过 FinancePeriodSettings 单例，
/// 避免测试执行顺序与全局 UserDefaults 状态耦合。
struct FinanceYearBasisTests {
    static func main() {
        testBillingYearRangeMidYear()
        testBillingYearRangeJanuaryBelongsToPreviousYear()
        testBillingYearRangeStartDay1EqualsCalendarYear()
        testBillingYearRangeStartDay31MonthEndCap()
        testShiftedYearRangeCalendar()
        testShiftedYearRangeBilling()
        testElapsedPeriodCountMidYear()
        testElapsedPeriodCountYearStart()
        testElapsedPeriodCountCapAtTwelve()
        testYearBasisPersistenceRoundTrip()
        testPeriodSummaryMonthlyAverage()
        testComparisonPointChangePercentage()
        print("FinanceYearBasisTests passed")
    }

    // MARK: - 记账年区间

    private static func testBillingYearRangeMidYear() {
        let calendar = fixedCalendar()
        let range = BillingCycleCalculator.billingYearRange(
            startDay: 25,
            reference: date(2026, 9, 26, calendar: calendar),
            calendar: calendar
        )
        expect(range.start == date(2026, 1, 25, calendar: calendar), "年中（9/26）的记账年应从本年 1/25 起")
        expect(range.end == date(2027, 1, 25, calendar: calendar), "记账年 end 应为 12 个账期后（开区间）")
    }

    private static func testBillingYearRangeJanuaryBelongsToPreviousYear() {
        let calendar = fixedCalendar()
        // 2026/1/10 所在账期是 2025/12/25–2026/1/24，归属 2025 记账年
        let range = BillingCycleCalculator.billingYearRange(
            startDay: 25,
            reference: date(2026, 1, 10, calendar: calendar),
            calendar: calendar
        )
        expect(range.start == date(2025, 1, 25, calendar: calendar), "1 月上旬应归属上一个记账年")
        expect(range.end == date(2026, 1, 25, calendar: calendar), "2025 记账年 end 是 2026/1/25")
    }

    private static func testBillingYearRangeStartDay1EqualsCalendarYear() {
        let calendar = fixedCalendar()
        let range = BillingCycleCalculator.billingYearRange(
            startDay: 1,
            reference: date(2026, 5, 15, calendar: calendar),
            calendar: calendar
        )
        expect(range.start == date(2026, 1, 1, calendar: calendar), "起始日=1 时记账年等价自然年（起点）")
        expect(range.end == date(2027, 1, 1, calendar: calendar), "起始日=1 时记账年等价自然年（终点）")
    }

    private static func testBillingYearRangeStartDay31MonthEndCap() {
        let calendar = fixedCalendar()
        let range = BillingCycleCalculator.billingYearRange(
            startDay: 31,
            reference: date(2026, 9, 26, calendar: calendar),
            calendar: calendar
        )
        expect(range.start == date(2026, 1, 31, calendar: calendar), "起始日 31 的记账年从 1/31 起")
        // 12 个账期后 cap 到 2027/1/31
        expect(range.end == date(2027, 1, 31, calendar: calendar), "起始日 31 平移 12 期 end 应 cap 到次年 1/31")
    }

    // MARK: - 按口径平移

    private static func testShiftedYearRangeCalendar() {
        let calendar = fixedCalendar()
        let range = BillingCycleCalculator.shiftedYearRange(
            start: date(2026, 1, 1, calendar: calendar),
            end: date(2027, 1, 1, calendar: calendar),
            offset: -1,
            basis: .calendar,
            startDay: 25,
            calendar: calendar
        )
        expect(range.start == date(2025, 1, 1, calendar: calendar), "自然年上一年起点")
        expect(range.end == date(2026, 1, 1, calendar: calendar), "自然年上一年终点")
    }

    private static func testShiftedYearRangeBilling() {
        let calendar = fixedCalendar()
        let range = BillingCycleCalculator.shiftedYearRange(
            start: date(2026, 1, 25, calendar: calendar),
            end: date(2027, 1, 25, calendar: calendar),
            offset: -1,
            basis: .billing,
            startDay: 25,
            calendar: calendar
        )
        expect(range.start == date(2025, 1, 25, calendar: calendar), "记账年上一年 = 12 个账期前")
        expect(range.end == date(2026, 1, 25, calendar: calendar), "记账年上一年 end 同步平移 12 期")
    }

    // MARK: - 已过周期数（月均口径）

    private static func testElapsedPeriodCountMidYear() {
        let calendar = fixedCalendar()
        let count = BillingCycleCalculator.elapsedPeriodCount(
            from: date(2026, 1, 25, calendar: calendar),
            to: date(2027, 1, 25, calendar: calendar),
            now: date(2026, 9, 26, calendar: calendar),
            calendar: calendar
        )
        expect(count == 9, "1/25 起到 9/26：9 期完整或进行中（第 9 期 9/25 刚开始也计入），实际 \(count)")
    }

    private static func testElapsedPeriodCountYearStart() {
        let calendar = fixedCalendar()
        let count = BillingCycleCalculator.elapsedPeriodCount(
            from: date(2026, 1, 25, calendar: calendar),
            to: date(2027, 1, 25, calendar: calendar),
            now: date(2026, 1, 26, calendar: calendar),
            calendar: calendar
        )
        expect(count == 1, "记账年第 2 天：只过了 1 期，实际 \(count)")
    }

    private static func testElapsedPeriodCountCapAtTwelve() {
        let calendar = fixedCalendar()
        let count = BillingCycleCalculator.elapsedPeriodCount(
            from: date(2026, 1, 1, calendar: calendar),
            to: date(2027, 1, 1, calendar: calendar),
            now: date(2026, 12, 31, calendar: calendar),
            calendar: calendar
        )
        expect(count == 12, "全年走完封顶 12，实际 \(count)")
    }

    // MARK: - 口径持久化

    private static func testYearBasisPersistenceRoundTrip() {
        let key = "financeYearBasis"
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        expect(FinanceYearBasis.loadDefault() == .billing, "未设置时默认记账年（与月档同锚）")

        FinanceYearBasis.calendar.persist()
        expect(FinanceYearBasis.loadDefault() == .calendar, "持久化后读回应为自然年")
    }

    // MARK: - 月均与同比模型

    private static func testPeriodSummaryMonthlyAverage() {
        let summary = PeriodSummary(
            totalExpense: Decimal(string: "52830")!,
            totalIncome: Decimal(string: "79600")!,
            transactionCount: 200,
            averageDailyExpense: 0,
            averageDailyIncome: 0,
            dayCount: 365,
            elapsedPeriodCount: 9
        )
        let monthly = summary.averageMonthlyExpense
        let expected = Decimal(string: "52830")! / 9
        expect(monthly == expected, "月均支出 = 总额 ÷ 已过 9 期，实际 \(monthly)")

        let zero = PeriodSummary.empty()
        expect(zero.elapsedPeriodCount == 0, "空汇总不带周期数（UI 回退日均）")
        expect(zero.averageMonthlyExpense == 0, "零总额月均为 0，不因除法崩")
    }

    private static func testComparisonPointChangePercentage() {
        let point = YearComparisonPoint(
            label: "8月",
            rangeText: nil,
            current: Decimal(string: "6420")!,
            previous: Decimal(string: "5890")!,
            isFuture: false,
            isOngoing: false
        )
        guard let percentage = point.changePercentage else {
            fatalError("上期有值时涨跌幅不应为 nil")
        }
        expect(abs(percentage - 9.0) < 0.05, "6420 vs 5890 ≈ +9.0%，实际 \(percentage)")

        let noBase = YearComparisonPoint(
            label: "1月",
            rangeText: nil,
            current: Decimal(string: "100")!,
            previous: 0,
            isFuture: false,
            isOngoing: false
        )
        expect(noBase.changePercentage == nil, "上期为 0 无基准，涨跌幅应为 nil")
    }

    // MARK: - 辅助

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
