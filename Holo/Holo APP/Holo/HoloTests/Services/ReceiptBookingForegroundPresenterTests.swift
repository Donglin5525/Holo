//
//  ReceiptBookingForegroundPresenterTests.swift
//  HoloTests
//
//  图片快捷记账「确认页必达」（2026-09-22）：
//  - present：导航 + 落「已自动弹过」标记
//  - presentIfNeeded：无草案不动；有未弹过草案弹最新；弹过的不再弹（不重复打扰）
//
//  草案通过 store 的磁盘目录直接注入（StoredDraft → JSON 落盘），
//  与生产 loadDrafts 同一条读取链路，不 mock。
//

import XCTest
@testable import Holo

@MainActor
final class ReceiptBookingForegroundPresenterTests: XCTestCase {

    private let key = "receiptBookingLastAutoPresentedDraftID"
    private var injectedDraftIDs: [UUID] = []

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        DeepLinkState.shared.pendingTarget = nil
        // 只清理本测试注入的草案，不扫全目录（避免误删并行用例的文件）
        for id in injectedDraftIDs {
            if let url = ReceiptBookingResultStore.draftDirectoryURL?
                .appendingPathComponent("\(id.uuidString).json") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        injectedDraftIDs = []
        try await super.tearDown()
    }

    // MARK: - 注入辅助

    private func injectDraft(id: UUID, createdAt: Date = Date()) throws {
        let draft = ReceiptBookingResultStore.StoredDraft(
            id: id,
            createdAt: createdAt,
            reasons: ["review.amount.low_confidence"],
            amountText: "35.00",
            typeIsIncome: false,
            merchant: "测试商户",
            dateText: nil,
            note: nil,
            paymentChannel: "支付宝",
            amountOriginalText: "35.00",
            paymentStatusOriginalText: nil,
            categoryCandidate: nil,
            normalizedCategoryCandidate: nil,
            semanticCategoryHint: nil,
            imageType: "",
            sourceKey: "test-\(id.uuidString)",
            itemKey: "test-\(id.uuidString)",
            accountChoiceRaw: "automatic",
            projectChoiceRaw: "noProject",
            modeRaw: "autoWhenSafe",
            items: nil
        )
        let dir = try XCTUnwrap(ReceiptBookingResultStore.draftDirectoryURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: dir.appendingPathComponent("\(id.uuidString).json"))
        injectedDraftIDs.append(id)
    }

    // MARK: - present

    func testPresentNavigatesAndMarksDraft() {
        let id = UUID()

        ReceiptBookingForegroundPresenter.present(draftID: id)

        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .receiptReview(draftID: id))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), id.uuidString)
    }

    // MARK: - presentIfNeeded

    func testPresentIfNeededDoesNothingWithoutDrafts() {
        DeepLinkState.shared.pendingTarget = nil

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        XCTAssertNil(DeepLinkState.shared.pendingTarget)
    }

    func testPresentIfNeededPresentsLatestUnseenDraft() throws {
        let older = UUID(), latest = UUID()
        try injectDraft(id: older, createdAt: Date().addingTimeInterval(-60))
        try injectDraft(id: latest)

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        // 弹的是最新一条，并落标记
        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .receiptReview(draftID: latest))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), latest.uuidString)
    }

    func testPresentIfNeededSkipsAlreadyPresentedDraft() throws {
        let id = UUID()
        try injectDraft(id: id)
        // 模拟已自动弹过：用户关掉复核页 = 暂不处理的信号
        UserDefaults.standard.set(id.uuidString, forKey: key)

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        XCTAssertNil(DeepLinkState.shared.pendingTarget)
    }

    func testPresentIfNeededPresentsAgainForNewerDraft() throws {
        let seen = UUID(), fresh = UUID()
        try injectDraft(id: seen, createdAt: Date().addingTimeInterval(-120))
        try injectDraft(id: fresh, createdAt: Date().addingTimeInterval(-60))
        UserDefaults.standard.set(seen.uuidString, forKey: key)

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        // 旧的已弹过不打扰，新截图产生的新草案照常弹
        XCTAssertEqual(DeepLinkState.shared.pendingTarget, .receiptReview(draftID: fresh))
    }

    // MARK: - 新鲜度闸门（2026-09-23 东林实锤拍板）

    func testPresentIfNeededIgnoresStaleDraft() throws {
        // 9-23 实锤场景：昨天的测试草案 + 今天识别被拒（无新草案）——
        // 回前台绝不能把旧草案当成这次的结果弹出来
        let stale = UUID()
        try injectDraft(id: stale, createdAt: Date().addingTimeInterval(-30 * 60))

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        XCTAssertNil(DeepLinkState.shared.pendingTarget, "10 分钟外的旧草案绝不自动弹")
        XCTAssertNil(UserDefaults.standard.string(forKey: key), "未弹出就不落「已弹过」标记")
    }

    func testPresentIfNeededOnlyLooksAtLatestDraft() throws {
        // 最新一条是旧草案时不许翻找更早的可弹对象——自动弹只服务「刚识别完」
        let stale = UUID(), older = UUID()
        try injectDraft(id: older, createdAt: Date().addingTimeInterval(-40 * 60))
        try injectDraft(id: stale, createdAt: Date().addingTimeInterval(-30 * 60))

        ReceiptBookingForegroundPresenter.presentIfNeeded()

        XCTAssertNil(DeepLinkState.shared.pendingTarget)
    }

    func testFreshnessWindowBoundary() {
        let now = Date()
        XCTAssertTrue(
            ReceiptBookingForegroundPresenter.isFreshlyCreated(
                now.addingTimeInterval(-10 * 60), now: now
            ),
            "窗口边界（恰好 10 分钟）内算新鲜"
        )
        XCTAssertFalse(
            ReceiptBookingForegroundPresenter.isFreshlyCreated(
                now.addingTimeInterval(-10 * 60 - 1), now: now
            ),
            "超过 10 分钟不算新鲜"
        )
        XCTAssertFalse(
            ReceiptBookingForegroundPresenter.isFreshlyCreated(
                now.addingTimeInterval(5), now: now
            ),
            "未来时间（时钟偏差）不算新鲜"
        )
    }
}
