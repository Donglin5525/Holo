//
//  HoloMemoryObservationApplierTests.swift
//  HoloTests
//
//  测试观察结果应用器：写入、去重、续期、90 天硬上限
//

import XCTest
@testable import Holo

final class HoloMemoryObservationApplierTests: XCTestCase {

    private var store: HoloEpisodicMemoryStore!
    private var applier: HoloMemoryObservationApplier!

    override func setUp() {
        super.setUp()
        store = HoloEpisodicMemoryStore.shared
        applier = HoloMemoryObservationApplier()
        // 清空数据
        store.save([])
        store.saveSuppressionRules([])
    }

    override func tearDown() {
        store.save([])
        store.saveSuppressionRules([])
        store = nil
        applier = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeValidationResult(
        memories: [ValidatedNewMemory] = [],
        hits: [MemoryHitEntry] = [],
        weakened: [WeakenedEntry] = []
    ) -> MemoryObserverValidationResult {
        MemoryObserverValidationResult(
            validNewMemories: memories,
            validHits: hits,
            validWeakened: weakened,
            rejectedEntries: []
        )
    }

    private func makeValidatedMemory(title: String = "测试记忆",
                                     expiresInDays: Int = 30) -> ValidatedNewMemory {
        ValidatedNewMemory(
            title: title,
            summary: "测试摘要",
            confidence: 0.7,
            sensitivity: .normal,
            visibility: .suggested,
            evidenceRefs: ["sig-1"],
            reasoningSummary: "测试",
            expiresInDays: expiresInDays
        )
    }

    // 需要 feature flag 开启
    private func ensureFeatureFlagEnabled() {
        HoloMemorySettings.shared.episodicMemoryObservationEnabled = true
    }

    // MARK: - Tests

    func testApply_新记忆写入成功() {
        ensureFeatureFlagEnabled()

        let result = makeValidationResult(memories: [makeValidatedMemory(title: "新记忆A")])
        let applyResult = applier.apply(validationResult: result, runID: "run-1")

        XCTAssertEqual(applyResult.newCount, 1)
        let memories = store.load()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.title, "新记忆A")
        XCTAssertEqual(memories.first?.state, .suggested)
        XCTAssertEqual(memories.first?.createdFromRunID, "run-1")
    }

    func testApply_重复记忆不写入() {
        ensureFeatureFlagEnabled()

        // 先写入一条
        let existing = HoloEpisodicMemory(
            id: "existing-1", title: "重复标题", summary: "旧",
            state: .active, visibility: .suggested,
            confidence: .medium, sensitivity: .normal,
            hitCount: 0, semanticHitRunIDs: [], evidence: [],
            createdAt: Date(), updatedAt: Date(), lastHitAt: nil,
            expiresAt: Date().addingTimeInterval(86400 * 30),
            sourceModules: [.habits]
        )
        store.save([existing])

        // 尝试写入同标题
        let result = makeValidationResult(memories: [makeValidatedMemory(title: "重复标题")])
        let applyResult = applier.apply(validationResult: result, runID: "run-2")

        XCTAssertEqual(applyResult.newCount, 0)
        XCTAssertEqual(store.load().count, 1)
    }

    func testApply_命中续期不超过90天硬上限() {
        ensureFeatureFlagEnabled()

        // 创建一条已存在 85 天的记忆（离 90 天上限还差 5 天）
        let createdAt = Date().addingTimeInterval(-86400 * 85)
        let existing = HoloEpisodicMemory(
            id: "ep-renew-1", title: "待续期", summary: "旧",
            state: .active, visibility: .suggested,
            confidence: .high, sensitivity: .normal,
            hitCount: 3, semanticHitRunIDs: ["prev-run"], evidence: [],
            createdAt: createdAt, updatedAt: createdAt, lastHitAt: nil,
            expiresAt: Date().addingTimeInterval(86400 * 5),
            sourceModules: [.habits]
        )
        store.save([existing])

        let hits = [MemoryHitEntry(episodicMemoryID: "ep-renew-1", hitReasoning: "仍相关")]
        let result = makeValidationResult(hits: hits)
        let applyResult = applier.apply(validationResult: result, runID: "run-renew")

        XCTAssertEqual(applyResult.hitCount, 1)

        let renewed = store.load().first!
        let maxExpiry = Calendar.current.date(byAdding: .day, value: 90, to: createdAt)!
        // 续期后不应超过 90 天硬上限
        XCTAssertLessThanOrEqual(renewed.expiresAt, maxExpiry)
        XCTAssertEqual(renewed.hitCount, 4)
    }

    func testApply_featureFlag关闭时不写入() {
        HoloMemorySettings.shared.episodicMemoryObservationEnabled = false

        let result = makeValidationResult(memories: [makeValidatedMemory()])
        let applyResult = applier.apply(validationResult: result, runID: "run-off")

        XCTAssertEqual(applyResult.newCount, 0)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testApply_expired记忆不能被命中续期() {
        ensureFeatureFlagEnabled()

        let existing = HoloEpisodicMemory(
            id: "ep-expired-1", title: "已过期", summary: "旧",
            state: .expired, visibility: .suggested,
            confidence: .medium, sensitivity: .normal,
            hitCount: 0, semanticHitRunIDs: [], evidence: [],
            createdAt: Date(), updatedAt: Date(), lastHitAt: nil,
            expiresAt: Date().addingTimeInterval(-1),
            sourceModules: [.habits]
        )
        store.save([existing])

        let hits = [MemoryHitEntry(episodicMemoryID: "ep-expired-1", hitReasoning: "尝试续期")]
        let result = makeValidationResult(hits: hits)
        let applyResult = applier.apply(validationResult: result, runID: "run-expired")

        XCTAssertEqual(applyResult.hitCount, 0)
    }

    func testApply_rejected记忆不能被命中续期() {
        ensureFeatureFlagEnabled()

        let existing = HoloEpisodicMemory(
            id: "ep-rejected-1", title: "已拒绝", summary: "旧",
            state: .rejected, visibility: .suggested,
            confidence: .medium, sensitivity: .normal,
            hitCount: 0, semanticHitRunIDs: [], evidence: [],
            createdAt: Date(), updatedAt: Date(), lastHitAt: nil,
            expiresAt: Date().addingTimeInterval(86400 * 30),
            sourceModules: [.habits]
        )
        store.save([existing])

        let hits = [MemoryHitEntry(episodicMemoryID: "ep-rejected-1", hitReasoning: "尝试续期")]
        let result = makeValidationResult(hits: hits)
        let applyResult = applier.apply(validationResult: result, runID: "run-rejected")

        XCTAssertEqual(applyResult.hitCount, 0)
    }
}
