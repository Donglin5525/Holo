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
}
