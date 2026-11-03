//
//  ReceiptBookingResultSurfacerTests.swift
//  HoloTests
//
//  图片快捷记账「结果播报必达」（2026-10-14 东林实锤：转账截图等拒识图
//  什么都不提示）：纯逻辑锁定——
//  - message：拒识带原因、失败区分限流、重复/已记有摘要、删除留痕与
//    needsReview/undone 不播报
//  - shouldSurface：窗口内 + 未播过 + 该播的种类三闸
//  - isFresh：边界与未来时间
//

import XCTest
@testable import Holo

@MainActor
final class ReceiptBookingResultSurfacerTests: XCTestCase {

    private let key = "receiptBookingLastSurfacedResultID"

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        try await super.tearDown()
    }

    // MARK: - 构造辅助

    private func makeResult(
        kind: ReceiptBookingResultStore.StoredOutcomeKind,
        reasonCode: String? = nil,
        summaryText: String? = nil,
        createdAt: Date = Date()
    ) -> ReceiptBookingResultStore.StoredResult {
        ReceiptBookingResultStore.StoredResult(
            id: UUID(),
            createdAt: createdAt,
            kind: kind,
            reasonCode: reasonCode,
            summaryText: summaryText,
            transactionID: nil,
            additionalTransactionIDs: nil,
            draftID: nil,
            undoToken: nil,
            usedDefaultAccount: false,
            undoneAt: nil
        )
    }

    // MARK: - message（播报文案）

    func testRejectedTransferMessage() {
        let result = makeResult(kind: .rejected, reasonCode: ReceiptBookingReason.rejectTransfer.rawValue)

        let toast = ReceiptBookingResultSurfacer.message(for: result)

        XCTAssertNotNil(toast)
        XCTAssertEqual(toast?.type, .warning)
        XCTAssertTrue(toast?.text.contains("这笔没有入账") == true, "必须点明没入账")
        XCTAssertTrue(
            toast?.text.contains(ReceiptBookingReason.rejectTransfer.rejectionUserText) == true,
            "原因文案与通知/快捷指令结果文字同一口径"
        )
    }

    func testRejectedWithoutReasonCodeIsOperationLogNotSurfaced() {
        // 列表里删掉待复核的留痕（kind=rejected 但无原因码）：用户自己删的不播报
        let result = makeResult(kind: .rejected, reasonCode: nil, summaryText: "已删除一条待复核记录")

        XCTAssertNil(ReceiptBookingResultSurfacer.message(for: result))
    }

    func testFailedRateLimitedUsesQuotaText() {
        let result = makeResult(kind: .failed, reasonCode: ReceiptBookingReason.failureRateLimited.rawValue)

        let toast = ReceiptBookingResultSurfacer.message(for: result)

        XCTAssertEqual(toast?.type, .error)
        XCTAssertTrue(toast?.text.contains("今天的识别次数用完了") == true)
    }

    func testFailedGenericUsesRetryText() {
        let result = makeResult(kind: .failed, reasonCode: ReceiptBookingReason.failureNetwork.rawValue)

        let toast = ReceiptBookingResultSurfacer.message(for: result)

        XCTAssertEqual(toast?.type, .error)
        XCTAssertTrue(toast?.text.contains("截图仍在照片里") == true)
    }

    func testDuplicateWithSummarySurfaced() {
        let result = makeResult(kind: .duplicate, summaryText: "¥35.00 · 测试商户")

        let toast = ReceiptBookingResultSurfacer.message(for: result)

        XCTAssertEqual(toast?.type, .info)
        XCTAssertTrue(toast?.text.contains("¥35.00") == true)
    }

    func testDuplicateWithoutSummaryNotSurfaced() {
        XCTAssertNil(ReceiptBookingResultSurfacer.message(for: makeResult(kind: .duplicate)))
    }

    func testNeedsReviewAndUndoneNotSurfaced() {
        // needsReview 由复核页必达通道负责；undone 是用户自己撤销的
        XCTAssertNil(ReceiptBookingResultSurfacer.message(for: makeResult(kind: .needsReview)))
        XCTAssertNil(ReceiptBookingResultSurfacer.message(for: makeResult(kind: .undone)))
    }

    func testBookedSurfacesSummary() {
        let result = makeResult(kind: .booked, summaryText: "已记 ¥19.90 · 瑞幸咖啡")

        let toast = ReceiptBookingResultSurfacer.message(for: result)

        XCTAssertEqual(toast?.text, "已记 ¥19.90 · 瑞幸咖啡")
        XCTAssertEqual(toast?.type, .success)
    }

    // MARK: - shouldSurface（三闸：新鲜 + 未播过 + 该播）

    func testShouldSurfaceFreshUnseenRejection() {
        let result = makeResult(kind: .rejected, reasonCode: ReceiptBookingReason.rejectUnrelated.rawValue)

        XCTAssertTrue(ReceiptBookingResultSurfacer.shouldSurface(latest: result, lastSurfacedID: nil, now: Date()))
    }

    func testShouldNotSurfaceAlreadySurfacedResult() {
        let result = makeResult(kind: .rejected, reasonCode: ReceiptBookingReason.rejectUnrelated.rawValue)

        XCTAssertFalse(
            ReceiptBookingResultSurfacer.shouldSurface(
                latest: result, lastSurfacedID: result.id.uuidString, now: Date()
            ),
            "同一条结果只播一次"
        )
    }

    func testShouldNotSurfaceStaleResult() {
        let result = makeResult(
            kind: .rejected,
            reasonCode: ReceiptBookingReason.rejectUnrelated.rawValue,
            createdAt: Date().addingTimeInterval(-11 * 60)
        )

        XCTAssertFalse(
            ReceiptBookingResultSurfacer.shouldSurface(latest: result, lastSurfacedID: nil, now: Date()),
            "10 分钟外的历史结果不翻旧账"
        )
    }

    func testShouldNotSurfaceWhenNothingToSay() {
        // 最新一条是不该播的种类（如 needsReview）时整条通道静默
        let result = makeResult(kind: .needsReview)

        XCTAssertFalse(ReceiptBookingResultSurfacer.shouldSurface(latest: result, lastSurfacedID: nil, now: Date()))
        XCTAssertFalse(ReceiptBookingResultSurfacer.shouldSurface(latest: nil, lastSurfacedID: nil, now: Date()))
    }

    // MARK: - isFresh 边界

    func testFreshnessWindowBoundary() {
        let now = Date()
        XCTAssertTrue(ReceiptBookingResultSurfacer.isFresh(now.addingTimeInterval(-10 * 60), now: now))
        XCTAssertFalse(ReceiptBookingResultSurfacer.isFresh(now.addingTimeInterval(-10 * 60 - 1), now: now))
        XCTAssertFalse(
            ReceiptBookingResultSurfacer.isFresh(now.addingTimeInterval(5), now: now),
            "未来时间（时钟偏差）不算新鲜"
        )
    }
}
