import XCTest
@testable import Holo

final class HoloPeriodReplayJobTests: XCTestCase {
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
}
