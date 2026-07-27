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

    func testMonthlyLengthPayloadIsAccepted() {
        let payload = makePayload(summaryLength: 140)
        XCTAssertTrue(MemoryInsightResponseParser.validate(payload))
    }

    func testAnnualLengthPayloadIsAcceptedUpTo240Characters() {
        XCTAssertTrue(MemoryInsightResponseParser.validate(makePayload(summaryLength: 240)))
        XCTAssertFalse(MemoryInsightResponseParser.validate(makePayload(summaryLength: 241)))
    }

    private func makePayload(summaryLength: Int) -> MemoryInsightPayload {
        MemoryInsightPayload(
            title: "这一段生活有了更完整的回声",
            summary: String(repeating: "回", count: summaryLength),
            cards: [
                MemoryInsightCard(
                    id: "overview_1",
                    type: .overview,
                    title: "阶段主线",
                    body: "这一阶段的变化有明确记录支撑。",
                    evidence: [],
                    suggestedQuestion: nil
                )
            ],
            suggestedQuestions: []
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
