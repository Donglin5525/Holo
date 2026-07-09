import XCTest
@testable import Holo

final class MemoryInsightResponseParserTests: XCTestCase {
    func testEmptyResponseIsClassifiedSeparately() {
        assertFailure(
            MemoryInsightResponseParser.parseResult(" \n "),
            equals: .emptyResponse
        )
    }

    func testMalformedJSONIsInvalidJSON() {
        assertFailure(
            MemoryInsightResponseParser.parseResult("not-json"),
            equals: .invalidJSON
        )
    }

    func testDecodablePayloadWithInvalidSchemaIsInvalidSchema() {
        let raw = #"{"title":"","summary":"x","cards":[],"suggestedQuestions":[]}"#

        assertFailure(
            MemoryInsightResponseParser.parseResult(raw),
            equals: .invalidSchema
        )
    }

    private func assertFailure(
        _ result: Result<MemoryInsightPayload, MemoryInsightParseFailure>,
        equals expected: MemoryInsightParseFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("预期解析失败，实际成功", file: file, line: line)
        case .failure(let failure):
            XCTAssertEqual(failure, expected, file: file, line: line)
        }
    }
}
