//
//  HealthInsightGenerationServiceTests.swift
//  HoloTests
//
//  健康洞察生成服务编排测试：成功 / 数据不足 / 失败回退；
//  后台隐性生成（2026-11-09）：取消≠失败 / 新鲜度规则 / 单飞行 / 7 天门控。
//

import XCTest
@testable import Holo

@MainActor
final class HealthInsightGenerationServiceTests: XCTestCase {

    // MARK: - 后台生成测试夹具（独立 defaults + 临时缓存目录 + 可注入 now）

    private var defaults: UserDefaults!
    private var cacheDir: URL!
    private var cache: HealthInsightCache!
    private var fixedNow: Date!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "health-insight-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-insight-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cache = HealthInsightCache(directory: cacheDir, defaults: defaults)
        // 固定时刻 15:00（本地时区当日下午）：-3h/-7h 均不跨天，缓存年龄断言稳定
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 15
        fixedNow = Calendar.current.date(from: comps) ?? Date()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDir)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        cacheDir = nil
        cache = nil
        fixedNow = nil
        suiteName = nil
    }

    private static let validResponse =
        #"{"coreInsight":{"id":"c","domain":"mixed","title":"恢复不足","summary":"摘要","confidence":0.7,"evidenceIds":["health-sleep-20260622"]}}"#

    private func makeProvider() -> MockHealthInsightProvider {
        let provider = MockHealthInsightProvider()
        provider.response = Self.validResponse
        return provider
    }

    private func makeScheduler(
        dataSource: HealthInsightDataSource = StubHealthDataSource(),
        provider: MockHealthInsightProvider,
        lastVisitAgo: TimeInterval? = 24 * 3600
    ) -> HealthInsightScheduler {
        if let lastVisitAgo {
            defaults.set(fixedNow.timeIntervalSince1970 - lastVisitAgo, forKey: "com.holo.healthInsight.lastHealthPageVisitAt")
        }
        return HealthInsightScheduler(
            service: HealthInsightGenerationService(
                contextBuilder: HealthInsightContextBuilder(dataSource: dataSource),
                provider: provider,
                cache: cache
            ),
            cache: cache,
            defaults: defaults,
            now: { [fixedNow] in fixedNow },
            isConsentGranted: { true }
        )
    }

    private func seedTodayCache(contextHashInput: String, savedAt: Date) {
        let outcome = HealthInsightGenerationOutcome(
            snapshot: GeneratedHealthInsightSnapshot(
                generatedAt: savedAt,
                period: HealthInsightPeriod(start: savedAt, end: savedAt, days: 1),
                status: .fresh,
                coreInsight: nil,
                lifestyleLoops: [],
                evidence: [],
                fallbackReason: nil
            ),
            contextHashInput: contextHashInput,
            promptVersion: nil
        )
        cache.save(outcome, for: Calendar.current.startOfDay(for: fixedNow), now: savedAt)
    }

    // MARK: - 纯生成（generate）

    func testGenerateReturnsFreshSnapshotOnSuccess() async throws {
        let provider = MockHealthInsightProvider()
        provider.response = #"{"coreInsight":{"id":"c","domain":"mixed","title":"恢复不足","summary":"摘要","confidence":0.7,"evidenceIds":["health-sleep-20260622"]}}"#
        provider.version = 1

        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: StubHealthDataSource()),
            provider: provider
        )
        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .fresh)
        XCTAssertNotNil(outcome.snapshot.coreInsight)
        XCTAssertEqual(outcome.promptVersion, 1)
        XCTAssertFalse(outcome.contextHashInput.isEmpty)
    }

    func testGenerateReturnsInsufficientWhenNoSleepData() async {
        let provider = MockHealthInsightProvider()
        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: EmptyHealthDataSource()),
            provider: provider
        )

        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .insufficientData)
        XCTAssertNil(outcome.snapshot.coreInsight)
        XCTAssertFalse(provider.wasCalled, "数据不足时不应调用 provider")
    }

    func testGenerateReturnsFallbackOnProviderError() async {
        let provider = MockHealthInsightProvider()
        provider.shouldThrow = true

        let service = HealthInsightGenerationService(
            contextBuilder: HealthInsightContextBuilder(dataSource: StubHealthDataSource()),
            provider: provider
        )

        let outcome = await service.generate()

        XCTAssertEqual(outcome.snapshot.status, .fallback)
        // fallback 提供本地规则 core（方案 5.3），lifestyleLoops 为空（不展示伪跨模块）
        XCTAssertNotNil(outcome.snapshot.coreInsight)
        XCTAssertTrue(outcome.snapshot.lifestyleLoops.isEmpty)
        XCTAssertNotNil(outcome.snapshot.fallbackReason)
    }

    // MARK: - 取消≠失败

    func testCancellationErrorDoesNotThrottleOrOverwriteCache() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        // 先成功生成一次：今日缓存 + 页面显示 fresh
        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()
        let seededTitle = cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow))?.coreInsight?.title
        XCTAssertNotNil(seededTitle)

        // provider 抛取消：手动刷新绕过新鲜度，命中取消路径
        provider.thrownError = CancellationError()
        scheduler.refreshManually()
        await scheduler.waitUntilIdle()

        XCTAssertFalse(cache.isThrottled(now: fixedNow), "取消不得触发失败节流")
        XCTAssertEqual(
            cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow))?.coreInsight?.title,
            seededTitle,
            "取消不得用保底文案覆盖已有缓存"
        )
        XCTAssertEqual(scheduler.snapshot?.coreInsight?.title, seededTitle, "取消不得改变页面已显示内容")
    }

    func testURLErrorCancelledDoesNotThrottleOrOverwriteCache() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()
        let seededTitle = cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow))?.coreInsight?.title
        XCTAssertNotNil(seededTitle)

        provider.thrownError = URLError(.cancelled)
        scheduler.refreshManually()
        await scheduler.waitUntilIdle()

        XCTAssertFalse(cache.isThrottled(now: fixedNow), "URL 层取消同样不记失败")
        XCTAssertEqual(scheduler.snapshot?.coreInsight?.title, seededTitle)
    }

    func testRealFailureKeepsThrottleAndDisplay() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()
        let seededTitle = cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow))?.coreInsight?.title
        XCTAssertNotNil(seededTitle)

        provider.thrownError = APIError.networkUnavailable
        scheduler.refreshManually()
        await scheduler.waitUntilIdle()

        XCTAssertTrue(cache.isThrottled(now: fixedNow), "真失败保持 30 分钟失败节流")
        XCTAssertEqual(
            cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow))?.coreInsight?.title,
            seededTitle,
            "失败不得用保底文案覆盖已有缓存"
        )
        XCTAssertEqual(scheduler.snapshot?.coreInsight?.title, seededTitle, "页面保持已有显示")
    }

    // MARK: - 新鲜度规则

    func testNoTodayCacheGenerates() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 1, "今天没有成功缓存 → 生成")
        XCTAssertEqual(scheduler.snapshot?.status, .fresh)
        XCTAssertNotNil(cache.loadSnapshot(for: Calendar.current.startOfDay(for: fixedNow)), "成功结果写入今日缓存")
    }

    func testRecentCacheWithChangedHashSkipsGeneration() async {
        // 缓存 3 小时前保存、hash 与当前 context 不一致 → 未满 6 小时跳过
        seedTodayCache(contextHashInput: "seed-hash-input", savedAt: fixedNow.addingTimeInterval(-3 * 3600))

        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 0, "hash 变了但缓存未满 6 小时 → 跳过，不调模型")
    }

    func testStaleCacheWithChangedHashRegenerates() async {
        // 缓存 7 小时前保存、hash 与当前 context 不一致 → 超过 6 小时重新生成
        seedTodayCache(contextHashInput: "seed-hash-input", savedAt: fixedNow.addingTimeInterval(-7 * 3600))

        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider)

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 1, "hash 变了且缓存超过 6 小时 → 重新生成")
        XCTAssertEqual(scheduler.snapshot?.status, .fresh)
    }

    // MARK: - 单飞行

    func testConcurrentTriggersCallProviderOnlyOnce() async {
        let provider = makeProvider()
        provider.delayNanos = 100_000_000   // 100ms 挂起点：保证第二次触发时首飞仍在途

        let scheduler = makeScheduler(provider: provider)
        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        scheduler.refreshIfNeeded(trigger: .appBecameActive)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 1, "同一时刻重复触发只跑一次")
    }

    // MARK: - 7 天门控（回到前台自动生成）

    func testForegroundRefreshSkipsWhenHealthPageNeverVisited() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider, lastVisitAgo: nil)

        scheduler.refreshIfNeeded(trigger: .appBecameActive)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 0, "从未访问过健康页 → 回到前台不自动生成")
    }

    func testForegroundRefreshSkipsWhenLastVisitOlderThanSevenDays() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(provider: provider, lastVisitAgo: 8 * 24 * 3600)

        scheduler.refreshIfNeeded(trigger: .appBecameActive)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 0, "超过 7 天未访问健康页 → 回到前台不自动生成")
    }

    // MARK: - 数据不足不调模型（后台入口）

    func testBackgroundGenerationSkipsProviderWhenDataInsufficient() async {
        let provider = makeProvider()
        let scheduler = makeScheduler(dataSource: EmptyHealthDataSource(), provider: provider)

        scheduler.seedSnapshotForDisplay()
        XCTAssertEqual(scheduler.snapshot?.status, .fallback, "无缓存时种子为保底文案")

        scheduler.refreshIfNeeded(trigger: .healthPageAppeared)
        await scheduler.waitUntilIdle()

        XCTAssertEqual(provider.callCount, 0, "数据不足不调模型")
        XCTAssertEqual(scheduler.snapshot?.status, .insufficientData, "无有效缓存时更新为诚实空态")
    }
}

// MARK: - Mock Provider

@MainActor
final class MockHealthInsightProvider: AIProvider {
    var lastCallLog: LLMCallLog?

    var response: String = "{}"
    var version: Int? = nil
    var shouldThrow = false
    /// 优先于 shouldThrow 的显式错误（取消/URLError 注入用）。
    var thrownError: (any Error)?
    /// 模拟在途生成（单飞行测试的挂起点）。
    var delayNanos: UInt64 = 0
    private(set) var wasCalled = false
    private(set) var callCount = 0

    func generateHealthInsight(contextJSON: String) async throws -> HealthInsightGenerationResult {
        wasCalled = true
        callCount += 1
        if let thrownError {
            throw thrownError
        }
        if shouldThrow {
            throw APIError.serverError("mock 生成失败")
        }
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        return HealthInsightGenerationResult(rawResponse: response, promptVersion: version)
    }

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        throw APIError.serverError("not implemented")
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        throw APIError.serverError("not implemented")
    }

    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: APIError.serverError("not implemented"))
        }
    }
}

// MARK: - Stub DataSources

/// 提供一天低睡眠数据（isDataSufficient=true）。
private struct StubHealthDataSource: HealthInsightDataSource {
    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] {
        [DailyHealthData(date: start, value: 5.5)]
    }
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyWorkouts(from start: Date, to end: Date) async -> [DailyWorkoutData] { [] }
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] { [] }
    func habitDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord] { [] }
    func taskDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord] { [] }
    func thoughtDailyCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord] { [] }
}

/// 无任何健康数据（isDataSufficient=false）。
private struct EmptyHealthDataSource: HealthInsightDataSource {
    func dailySleep(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailySteps(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyStand(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyActive(from start: Date, to end: Date) async -> [DailyHealthData] { [] }
    func dailyWorkouts(from start: Date, to end: Date) async -> [DailyWorkoutData] { [] }
    func financeRecords(from start: Date, to end: Date) async -> [HealthInsightFinanceRecord] { [] }
    func habitDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightHabitRecord] { [] }
    func taskDailyCompletion(from start: Date, to end: Date) async -> [HealthInsightTaskRecord] { [] }
    func thoughtDailyCount(from start: Date, to end: Date) async -> [HealthInsightThoughtRecord] { [] }
}
