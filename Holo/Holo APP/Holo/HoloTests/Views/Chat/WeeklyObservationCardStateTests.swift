import XCTest
@testable import Holo

final class WeeklyObservationCardStateTests: XCTestCase {
    func testDismissHidesCardImmediately() {
        var state = WeeklyObservationCardState()

        state.dismiss()

        XCTAssertTrue(state.isDismissed)
        XCTAssertFalse(state.shouldDisplay(persistedDecision: true))
    }

    func testBeginRetryRejectsDuplicateAttempt() {
        var state = WeeklyObservationCardState()

        XCTAssertTrue(state.beginRetry())
        XCTAssertFalse(state.beginRetry())
        XCTAssertTrue(state.isRetrying)
    }

    func testSuccessfulRetryRestoresDisplayAndIncrementsRevision() {
        var state = WeeklyObservationCardState(isDismissed: true)

        XCTAssertTrue(state.beginRetry())
        state.finishRetry(errorMessage: nil)

        XCTAssertFalse(state.isDismissed)
        XCTAssertFalse(state.isRetrying)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.revision, 1)
    }

    func testFailedRetryRemainsRetryableAndExposesError() {
        var state = WeeklyObservationCardState()

        XCTAssertTrue(state.beginRetry())
        state.finishRetry(errorMessage: "AI 服务未返回内容，请稍后重试。")

        XCTAssertFalse(state.isRetrying)
        XCTAssertEqual(state.errorMessage, "AI 服务未返回内容，请稍后重试。")
        XCTAssertTrue(state.beginRetry())
    }
}
