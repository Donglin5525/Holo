import XCTest
@testable import Holo

final class TransactionDateResolverTests: XCTestCase {
    func testResolveUsesTransactionDateFromExtractedData() throws {
        let referenceDate = try makeDate(year: 2026, month: 7, day: 2, hour: 15, minute: 26)

        let result = TransactionDateResolver.resolve(
            from: ["transactionDate": "2026-07-01"],
            referenceDate: referenceDate
        )
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 26)
    }

    func testResolveFallsBackToDateFieldForLegacyExtraction() throws {
        let referenceDate = try makeDate(year: 2026, month: 7, day: 2, hour: 15)

        let result = TransactionDateResolver.resolve(
            from: ["date": "昨天"],
            referenceDate: referenceDate
        )
        let components = Calendar.current.dateComponents([.year, .month, .day], from: result)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)
    }

    func testResolveKeepsExplicitTimeWhenExtractedDataContainsTime() throws {
        let referenceDate = try makeDate(year: 2026, month: 7, day: 2, hour: 15, minute: 26)

        let result = TransactionDateResolver.resolve(
            from: ["transactionDate": "昨天晚上8点半"],
            referenceDate: referenceDate
        )
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: result)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 20)
        XCTAssertEqual(components.minute, 30)
    }

    func testResolveFallsBackToReferenceDateWhenMissing() throws {
        let referenceDate = try makeDate(year: 2026, month: 7, day: 2, hour: 15)

        let result = TransactionDateResolver.resolve(
            from: ["amount": "35"],
            referenceDate: referenceDate
        )

        XCTAssertEqual(result, referenceDate)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(components.date)
    }
}
