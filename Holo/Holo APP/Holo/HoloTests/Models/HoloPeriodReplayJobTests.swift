import XCTest
@testable import Holo

final class HoloPeriodReplayJobTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testJobRoundTripsThroughStringDictionaryJSON() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_702_678_400)
        let original = HoloPeriodReplayJob(
            periodType: .monthly,
            periodStart: start,
            periodEnd: end,
            state: .waitingForNetwork,
            attemptCount: 2,
            lastErrorCategory: "NETWORK_UNAVAILABLE",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let json = try XCTUnwrap(original.json)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let dictionary = try JSONDecoder().decode([String: String].self, from: data)
        let restored = try XCTUnwrap(HoloPeriodReplayJob(json: json))

        XCTAssertEqual(dictionary["kind"], HoloPeriodReplayJob.payloadKind)
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.state.isRecoverable)
    }

    func testCompletedAndFailedJobsAreNotAutoRecovered() {
        XCTAssertFalse(HoloPeriodReplayJobState.completed.isRecoverable)
        XCTAssertFalse(HoloPeriodReplayJobState.failed.isRecoverable)
        XCTAssertTrue(HoloPeriodReplayJobState.waitingForForeground.isRecoverable)
    }

    func testMalformedOrUnrelatedMetadataIsIgnored() {
        XCTAssertNil(HoloPeriodReplayJob(json: nil))
        XCTAssertNil(HoloPeriodReplayJob(json: #"{"kind":"other"}"#))
    }

    // MARK: - 周期称谓
    // 完整自然周期给整期称谓（“8月”），进行中/自定义给日期区间；
    // 不用“本周/本月”：周期初智能回退后标签会与数据不符，消息持久化后相对词也会过时。

    func testFullNaturalPeriodLabels() {
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 8, 1), end: date(2026, 8, 31), periodType: .monthly),
            "8月"
        )
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 2, 1), end: date(2026, 2, 28), periodType: .monthly),
            "2月"
        )
        // 2026-08-24 是周一，8-30 是周日
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 8, 24), end: date(2026, 8, 30), periodType: .weekly),
            "8月24日-30日"
        )
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 7, 1), end: date(2026, 9, 30), periodType: .quarterly),
            "7月-9月"
        )
    }

    func testInProgressPeriodLabels() {
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 9, 1), end: date(2026, 9, 2), periodType: .monthly),
            "9月1日-2日"
        )
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 8, 31), end: date(2026, 9, 1), periodType: .weekly),
            "8月31日-9月1日"
        )
    }

    func testCustomLabelIncludesSingleDayAndCrossYear() {
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 9, 1), end: date(2026, 9, 1), periodType: .custom),
            "9月1日"
        )
        XCTAssertEqual(
            HoloPeriodReplayJob.rangeLabel(
                start: date(2026, 12, 28), end: date(2027, 1, 3), periodType: .custom),
            "12月28日-2027年1月3日"
        )
    }

    func testIsFullNaturalPeriodRejectsPartial() {
        // 月初但未到月末（9月有30天，9/29 仍是进行中；9/30 当天则算完整月）
        XCTAssertFalse(HoloPeriodReplayJob.isFullNaturalPeriod(
            start: date(2026, 9, 1), end: date(2026, 9, 29), periodType: .monthly))
        // 月末但起点不是月初
        XCTAssertFalse(HoloPeriodReplayJob.isFullNaturalPeriod(
            start: date(2026, 8, 2), end: date(2026, 8, 31), periodType: .monthly))
        // 周期首但终点不是周日
        XCTAssertFalse(HoloPeriodReplayJob.isFullNaturalPeriod(
            start: date(2026, 8, 24), end: date(2026, 8, 29), periodType: .weekly))
    }

    // MARK: - 上期对比窗口（环比口径）

    /// 月度回放的上期窗口必须覆盖上一整月：排他语义下末端落在本期 start 上。
    /// 此前端在 start-1，导致月对比永久丢掉月末一天、周对比丢周日。
    func testPreviousPeriodWindowMonthlyCoversWholePreviousMonth() {
        let window = MemoryInsightContextBuilder.previousPeriodWindow(
            start: date(2026, 8, 1), end: date(2026, 8, 31))
        XCTAssertEqual(window.start, date(2026, 7, 1))
        XCTAssertEqual(window.end, date(2026, 8, 1))
        // 窗口天数 = 7 月实际天数 31，与本期等长
        XCTAssertEqual(
            calendar.dateComponents([.day], from: window.start, to: window.end).day,
            calendar.dateComponents([.day], from: date(2026, 8, 1), to: date(2026, 9, 1)).day)
    }

    func testPreviousPeriodWindowWeeklyCoversSevenDays() {
        // 2026-08-24 是周一、08-30 是周日
        let window = MemoryInsightContextBuilder.previousPeriodWindow(
            start: date(2026, 8, 24), end: date(2026, 8, 30))
        XCTAssertEqual(window.start, date(2026, 8, 17))
        XCTAssertEqual(window.end, date(2026, 8, 24))
        XCTAssertEqual(
            calendar.dateComponents([.day], from: window.start, to: window.end).day, 7)
    }

    func testPreviousPeriodWindowMatchesCurrentPeriodLength() {
        // 任意自定义区间：上期窗口与本期等长且紧贴（无重叠、无缝隙）
        let start = date(2026, 7, 10)
        let end = date(2026, 7, 19)
        let window = MemoryInsightContextBuilder.previousPeriodWindow(start: start, end: end)
        XCTAssertEqual(window.end, start)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: window.start, to: window.end).day,
            (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }
}
