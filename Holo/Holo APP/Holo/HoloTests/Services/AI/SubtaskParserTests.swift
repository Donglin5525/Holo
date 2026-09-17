import XCTest
@testable import Holo

final class SubtaskParserTests: XCTestCase {

    // MARK: - 基本解析

    func testParseNilReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse(nil).isEmpty)
    }

    func testParseEmptyStringReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("").isEmpty)
    }

    func testParseSingleItemReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("买牛奶").isEmpty)
    }

    func testParseTwoCommaSeparatedItems() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,买洗手液"), ["买牛奶", "买洗手液"])
    }

    // MARK: - 分隔符兼容

    func testParseChineseComma() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶，买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseDunHao() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶、买面包、买鸡蛋"), ["买牛奶", "买面包", "买鸡蛋"])
    }

    func testParseSemicolon() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶；买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseMixedSeparators() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶，买面包、买鸡蛋"), ["买牛奶", "买面包", "买鸡蛋"])
    }

    // MARK: - 清理逻辑

    func testParseTrimsWhitespace() {
        XCTAssertEqual(SubtaskParser.parse(" 买牛奶 , 买洗手液 "), ["买牛奶", "买洗手液"])
    }

    func testParseDeduplicates() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,买牛奶,买洗手液"), ["买牛奶", "买洗手液"])
    }

    func testParseFiltersEmptyItems() {
        XCTAssertEqual(SubtaskParser.parse("买牛奶,,买洗手液，"), ["买牛奶", "买洗手液"])
    }

    // MARK: - 限制

    func testParseTruncatesLongTitle() {
        let longTitle = String(repeating: "买", count: 60)
        let result = SubtaskParser.parse("\(longTitle),买洗手液")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].count, SubtaskParser.maxTitleLength)
    }

    func testParseLimitsToMaxSubtasks() {
        let items = (1...15).map { "任务\($0)" }.joined(separator: ",")
        let result = SubtaskParser.parse(items)
        XCTAssertEqual(result.count, SubtaskParser.maxSubtasks)
    }

    func testParseOneItemAfterDedupReturnsEmpty() {
        XCTAssertTrue(SubtaskParser.parse("买牛奶,买牛奶").isEmpty)
    }

    // MARK: - 自然语言提醒时间

    func testNLDateParserMapsTomorrowMorningToConcreteTime() throws {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone.current
        components.year = 2026
        components.month = 5
        components.day = 30
        components.hour = 16
        components.minute = 0
        let referenceDate = try XCTUnwrap(components.date)

        let result = try XCTUnwrap(NLDateParser.parse("明天早上", referenceDate: referenceDate))
        let resultComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        XCTAssertEqual(resultComponents.year, 2026)
        XCTAssertEqual(resultComponents.month, 5)
        XCTAssertEqual(resultComponents.day, 31)
        XCTAssertEqual(resultComponents.hour, 9)
        XCTAssertEqual(resultComponents.minute, 0)
    }

    func testNLDateParserMapsTomorrowAfternoonToConcreteTime() throws {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone.current
        components.year = 2026
        components.month = 5
        components.day = 30
        components.hour = 16
        components.minute = 0
        let referenceDate = try XCTUnwrap(components.date)

        let result = try XCTUnwrap(NLDateParser.parse("明天下午", referenceDate: referenceDate))
        let resultComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        XCTAssertEqual(resultComponents.year, 2026)
        XCTAssertEqual(resultComponents.month, 5)
        XCTAssertEqual(resultComponents.day, 31)
        XCTAssertEqual(resultComponents.hour, 15)
        XCTAssertEqual(resultComponents.minute, 0)
    }

    // MARK: - 绝对日期（M月d日）

    /// 2026-09-17 事故回归：用户原话「9月20日 早上9点…」曾被解析成「今天+9点」
    func testAbsoluteChineseDateInFullSentence() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        let result = try XCTUnwrap(
            NLDateParser.parse("9月20日 早上9点要去换日币，头天晚上提醒我一下，当天早上8点再提醒一次", referenceDate: referenceDate)
        )
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    func testAbsoluteChineseDateWithExplicitYear() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        let result = try XCTUnwrap(NLDateParser.parse("2026年9月20日 早上9点", referenceDate: referenceDate))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: result)

        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 9)
    }

    /// 无年份且本年已过去 → 进位下一年（9 月说「1月5日」指来年）
    func testAbsoluteChineseDatePastThisYearRollsToNextYear() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        let result = try XCTUnwrap(NLDateParser.parse("1月5日 晚上8点", referenceDate: referenceDate))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: result)

        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 5)
        XCTAssertEqual(comps.hour, 20)
    }

    /// 显式年份在过去也照用（补录历史场景由 LLM 侧控制，本地不做猜测）
    func testAbsoluteChineseDateWithPastExplicitYearStays() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        let result = try XCTUnwrap(NLDateParser.parse("2025年1月5日 晚上8点", referenceDate: referenceDate))
        let comps = Calendar.current.dateComponents([.year], from: result)

        XCTAssertEqual(comps.year, 2025)
    }

    func testAbsoluteChineseDateRejectsInvalidDay() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        // 2 月 30 日不存在：不得进位成 3 月 2 日（被拒后按无日期词落到「今天+时间」兜底）
        let result = NLDateParser.parse("2月30日 早上9点", referenceDate: referenceDate)
        if let result {
            let comps = Calendar.current.dateComponents([.month, .day], from: result)
            XCTAssertFalse(comps.month == 3 && comps.day == 2, "非法日期不得静默进位")
        }
    }

    /// 「N号」写法
    func testAbsoluteChineseDateWithHaoSuffix() throws {
        let referenceDate = try Self.referenceDate(year: 2026, month: 9, day: 17, hour: 15)

        let result = try XCTUnwrap(NLDateParser.parse("10月3号 上午10点", referenceDate: referenceDate))
        let comps = Calendar.current.dateComponents([.month, .day, .hour], from: result)

        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 3)
        XCTAssertEqual(comps.hour, 10)
    }

    // MARK: - 提醒槽位汇总（ReminderSlotParser）

    func testReminderSlotParserCombinesMultiAndSingle() {
        let data: [String: String] = [
            "reminderDates": "2026-09-19 20:00, 2026-09-20 08:00",
            "reminderDate": "2026-09-19 20:00"
        ]
        XCTAssertEqual(
            ReminderSlotParser.parse(from: data),
            ["2026-09-19 20:00", "2026-09-20 08:00"]
        )
    }

    func testReminderSlotParserSingleOnly() {
        XCTAssertEqual(
            ReminderSlotParser.parse(from: ["reminderDate": "今天 22:00"]),
            ["今天 22:00"]
        )
    }

    func testReminderSlotParserEmpty() {
        XCTAssertTrue(ReminderSlotParser.parse(from: [:]).isEmpty)
    }

    func testReminderSlotParserChineseSeparators() {
        XCTAssertEqual(
            ReminderSlotParser.parse(from: ["reminderDates": "2026-09-19 20:00，2026-09-20 08:00"]),
            ["2026-09-19 20:00", "2026-09-20 08:00"]
        )
    }

    // MARK: - Helpers

    private static func referenceDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        return try XCTUnwrap(components.date)
    }
}
