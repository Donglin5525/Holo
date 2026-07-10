import XCTest
@testable import Holo

final class FlexibleQueryDateRangeTests: XCTestCase {

    func testRecentMonthMeansThirtyInclusiveCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))

        let range = try XCTUnwrap(FlexibleQueryDateRangeResolver.resolve(
            text: "最近一个月吃了多少顿麦当劳",
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(range.startDate, "2026-06-12")
        XCTAssertEqual(range.endDate, "2026-07-11")
    }

    func testEquivalentRecentMonthPhrasesUseSameThirtyDayRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))

        for phrase in ["近一个月", "过去一个月", "最近30天", "过去 30 天"] {
            let range = try XCTUnwrap(FlexibleQueryDateRangeResolver.resolve(
                text: "\(phrase)麦当劳花了多少钱",
                now: now,
                calendar: calendar
            ))
            XCTAssertEqual(range.startDate, "2026-06-12", phrase)
            XCTAssertEqual(range.endDate, "2026-07-11", phrase)
        }
    }

    func testThisMonthMeansFirstDayThroughToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))

        let range = try XCTUnwrap(FlexibleQueryDateRangeResolver.resolve(
            text: "本月麦当劳花了多少钱",
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(range.startDate, "2026-07-01")
        XCTAssertEqual(range.endDate, "2026-07-11")
    }

    func testPreviousMonthMeansCompletePreviousCalendarMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))

        let range = try XCTUnwrap(FlexibleQueryDateRangeResolver.resolve(
            text: "上个月麦当劳花了多少钱",
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(range.startDate, "2026-06-01")
        XCTAssertEqual(range.endDate, "2026-06-30")
    }

    func testStrictDateCodecRejectsImpossibleCalendarDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        XCTAssertThrowsError(
            try FlexibleQueryDateCodec.parse("2026-02-31", calendar: calendar)
        )
    }

    func testExplicitRecentMonthOverridesConflictingPlannerDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))
        let plan = Self.makePlan(startDate: "2026-06-16", endDate: "2026-06-16")

        let normalized = FlexibleQueryPlanDateNormalizer.normalize(
            plan: plan,
            userQuestion: "最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(normalized.filters.startDate, "2026-06-12")
        XCTAssertEqual(normalized.filters.endDate, "2026-07-11")
        XCTAssertEqual(normalized.filters.keywords, ["麦当劳"])
        XCTAssertEqual(normalized.filters.excludedKeywords, ["退款"])
        XCTAssertEqual(normalized.filters.accountNames, ["支付宝"])
        XCTAssertFalse(normalized.filters.includeRemark)
    }

    func testPlannerValidationRejectsImpossibleDate() {
        let plan = Self.makePlan(startDate: "2026-02-31", endDate: "2026-03-01")

        XCTAssertThrowsError(try FlexibleQueryPlanner.validate(plan: plan))
    }

    func testPlannerFinalizationAppliesExplicitUserDateRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 11,
            hour: 18
        )))
        let rawResult = FlexiblePlannerResult(
            status: .ready,
            clarificationQuestion: nil,
            plan: Self.makePlan(startDate: "2026-06-16", endDate: "2026-06-16")
        )

        let result = try FlexibleQueryPlanner.finalize(
            result: rawResult,
            userQuestion: "最近一个月吃了多少顿麦当劳，花了多少钱，平均一顿多少钱",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.plan?.filters.startDate, "2026-06-12")
        XCTAssertEqual(result.plan?.filters.endDate, "2026-07-11")
    }

    private static func makePlan(startDate: String, endDate: String) -> FlexibleQueryPlan {
        FlexibleQueryPlan(
            domain: .finance,
            operation: .sumAmount,
            filters: FinanceQueryFilters(
                type: .expense,
                amountGreaterThan: nil,
                amountGreaterThanOrEqual: nil,
                amountLessThan: nil,
                amountLessThanOrEqual: nil,
                amountEqual: nil,
                keywords: ["麦当劳"],
                excludedKeywords: ["退款"],
                categoryNames: ["餐饮"],
                startDate: startDate,
                endDate: endDate,
                accountNames: ["支付宝"],
                includeNote: true,
                includeRemark: false,
                includeTags: true,
                includeCategory: true
            ),
            calculation: .averageAmount,
            averageUnit: .meal,
            sort: FlexibleQuerySort(field: .date, direction: .desc),
            limit: 20,
            explanationHints: []
        )
    }
}
