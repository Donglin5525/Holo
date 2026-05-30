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
}
