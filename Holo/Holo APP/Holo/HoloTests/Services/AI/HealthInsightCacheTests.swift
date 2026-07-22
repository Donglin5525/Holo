//
//  HealthInsightCacheTests.swift
//  HoloTests
//
//  健康洞察缓存测试：存取往返、刷新判断（contextHash/promptVersion N4）、失败节流、手动刷新计数。
//

import XCTest
@testable import Holo

@MainActor
final class HealthInsightCacheTests: XCTestCase {

    /// iOS 26.3 Simulator 的 hosted XCTest 在用例结束时释放 MainActor 对象及其
    /// 独立 UserDefaults，偶发触发系统层重复释放。保留到测试进程退出，避免把
    /// 运行时兼容问题误判成缓存业务失败。
    private static var retainedCaches: [HealthInsightCache] = []

    private func makeCache() -> HealthInsightCache {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let cache = HealthInsightCache(directory: dir, defaults: defaults)
        Self.retainedCaches.append(cache)
        return cache
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func outcome(status: HealthInsightGenerationStatus = .fresh,
                         hashInput: String = "stable-hash-input",
                         promptVersion: Int? = 1) -> HealthInsightGenerationOutcome {
        HealthInsightGenerationOutcome(
            snapshot: GeneratedHealthInsightSnapshot(
                generatedAt: now,
                period: HealthInsightPeriod(start: now, end: now, days: 14),
                status: status,
                coreInsight: nil,
                lifestyleLoops: [],
                evidence: [],
                fallbackReason: nil
            ),
            contextHashInput: hashInput,
            promptVersion: promptVersion
        )
    }

    func testSaveAndLoadSnapshotRoundTrip() {
        let cache = makeCache()
        cache.save(outcome(hashInput: "abc"), for: now, now: now)

        let loaded = cache.loadSnapshot(for: now)
        XCTAssertEqual(loaded?.status, .fresh)
    }

    func testNeedsRefreshWhenNoCache() {
        let cache = makeCache()
        XCTAssertTrue(cache.needsRefresh(for: now, contextHashInput: "abc", currentPromptVersion: 1))
    }

    func testNoRefreshWhenContextAndVersionUnchanged() {
        let cache = makeCache()
        cache.save(outcome(hashInput: "abc", promptVersion: 1), for: now, now: now)

        XCTAssertFalse(cache.needsRefresh(for: now, contextHashInput: "abc", currentPromptVersion: 1))
    }

    func testNeedsRefreshWhenContextHashChanged() {
        let cache = makeCache()
        cache.save(outcome(hashInput: "abc"), for: now, now: now)

        XCTAssertTrue(cache.needsRefresh(for: now, contextHashInput: "changed", currentPromptVersion: 1))
    }

    func testNeedsRefreshWhenPromptVersionChanged() {
        // 审查修订 N4：prompt 升级后旧缓存失效
        let cache = makeCache()
        cache.save(outcome(hashInput: "abc", promptVersion: 1), for: now, now: now)

        XCTAssertTrue(cache.needsRefresh(for: now, contextHashInput: "abc", currentPromptVersion: 2))
    }

    func testFailureThrottle() {
        let cache = makeCache()

        XCTAssertFalse(cache.isThrottled(now: now))

        cache.recordFailure(now: now)
        XCTAssertTrue(cache.isThrottled(now: now.addingTimeInterval(60)))           // 1 分钟内
        XCTAssertFalse(cache.isThrottled(now: now.addingTimeInterval(31 * 60)))     // 31 分钟后解除
    }

    func testManualRefreshLimitAndThrottle() {
        let cache = makeCache()

        // 当天 3 次
        XCTAssertTrue(cache.canManualRefresh(now: now))
        cache.recordManualRefresh(now: now)
        cache.recordManualRefresh(now: now)
        cache.recordManualRefresh(now: now)
        XCTAssertFalse(cache.canManualRefresh(now: now))   // 第 4 次被拒

        // 失败节流共享：recordFailure 后手动刷新也被拒（P8）
        cache.recordFailure(now: now.addingTimeInterval(3600))
        XCTAssertFalse(cache.canManualRefresh(now: now.addingTimeInterval(3600)))
    }
}
