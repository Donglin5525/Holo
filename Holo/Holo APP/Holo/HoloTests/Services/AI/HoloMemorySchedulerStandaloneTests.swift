import Foundation

actor SchedulerControlBox {
    var state: HoloMemoryControlState
    var consent = true

    init(enabled: Bool = true) {
        state = HoloMemoryControlState(
            automaticMemoryEnabled: enabled,
            memoryAssistedAnsweringEnabled: true,
            learningBaselineAt: nil,
            userDecisionVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func snapshot() -> HoloMemoryControlState { state }
    func hasConsent() -> Bool { consent }
    func closeAndClear(at date: Date) {
        state.automaticMemoryEnabled = false
        state.learningBaselineAt = date
        state.userDecisionVersion += 1
        state.updatedAt = date
    }
}

actor CounterBox {
    var extractionCount = 0
    var commitCount = 0
    func extracted() { extractionCount += 1 }
    func committed() { commitCount += 1 }
    func snapshot() -> (Int, Int) { (extractionCount, commitCount) }
}

actor ExtractionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func hasStarted() -> Bool { started }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemorySchedulerStandaloneTests.main()
    }
}
#endif
struct HoloMemorySchedulerStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        testDirtyCoalescingAndBoundedCatchUp()
        testObservationKeyContract()
        testResourceBudget()
        try await testIdempotencyFrequencyAndRetry()
        try await testMaterialThresholdCrossDomainAndDailyBudget()
        try await testOnlyOneAIJobRunsAtATime()
        try await testControlStateRecheckBeforeCommit()
        #if DEBUG
        try await testDebugResetValidationState()
        #endif
        print("HoloMemorySchedulerStandaloneTests: \(assertions) assertions passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func testDirtyCoalescingAndBoundedCatchUp() {
        var registry = HoloMemoryDirtyRegistry()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        registry.markDirty(target: .domain(.finance), sourceDigest: "a", now: start)
        registry.markDirty(target: .domain(.finance), sourceDigest: "b", now: start.addingTimeInterval(2))
        registry.markDirty(target: .domain(.finance), sourceDigest: "c", now: start.addingTimeInterval(4))

        expect(registry.count == 1, "连续变化只能合并为一个领域 dirty 状态")
        expect(registry.entry(for: .domain(.finance))?.changeCount == 3,
               "合并状态应记录变化次数，但不积累逐条待办")
        expect(registry.readyEntries(now: start.addingTimeInterval(8), debounce: 5).isEmpty,
               "debounce 未结束时不得启动观察")
        expect(registry.readyEntries(now: start.addingTimeInterval(10), debounce: 5).count == 1,
               "debounce 结束后只产生一次领域观察")

        let reopenedAt = start.addingTimeInterval(90 * 86_400)
        let window = HoloMemoryObservationWindow.make(
            target: .domain(.finance),
            dirtySince: start,
            now: reopenedAt,
            catchUpLimit: 14 * 86_400
        )
        expect(window.start >= reopenedAt.addingTimeInterval(-14 * 86_400),
               "长时间关闭后只能补规定时间窗口，不能扫描全部积压")
    }

    private static func testObservationKeyContract() {
        let window = HoloMemoryObservationWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        let key = HoloMemoryObservationKey.make(
            target: .domain(.health),
            window: window,
            sourceDigest: "digest-123",
            extractorVersion: 4,
            promptVersion: 7
        )
        expect(key.contains("domain:health"), "observation key 必须包含领域")
        expect(key.contains("window:100-200"), "observation key 必须包含窗口")
        expect(key.contains("digest:digest-123"), "observation key 必须包含源摘要")
        expect(key.contains("extractor:4|prompt:7"), "observation key 必须包含萃取器与 Prompt 版本")
    }

    private static func testResourceBudget() {
        let blockedSnapshots: [(HoloMemoryResourceSnapshot, HoloMemoryResourceDeferral)] = [
            (.init(networkAvailable: false), .noNetwork),
            (.init(lowPowerModeEnabled: true), .lowPowerMode),
            (.init(lowDataModeEnabled: true), .lowDataMode),
            (.init(foregroundCriticalOperation: true), .foregroundCriticalOperation),
            (.init(dailyAICallCount: 10, dailyAICallLimit: 10), .dailyBudgetExhausted)
        ]
        for (snapshot, expected) in blockedSnapshots {
            expect(HoloMemoryResourceBudget.evaluate(snapshot) == .deferred(expected),
                   "资源预算应正确延后：\(expected)")
        }
        expect(HoloMemoryResourceBudget.evaluate(.init()) == .allowed,
               "资源正常时应允许静默观察")
    }

    private static func testIdempotencyFrequencyAndRetry() async throws {
        let control = SchedulerControlBox()
        let counter = CounterBox()
        let scheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        await scheduler.markDirty(target: .domain(.finance), sourceDigest: "finance-v1", now: now)
        let events = await scheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in await counter.extracted(); return Data("ok".utf8) },
            commit: { _, _ in await counter.committed() }
        )
        expect(events.contains(where: { if case .succeeded = $0 { true } else { false } }),
               "首次 observation 应成功")

        await scheduler.markDirty(
            target: .domain(.finance),
            sourceDigest: "finance-v2",
            now: now.addingTimeInterval(20)
        )
        let sameDay = await scheduler.runIfNeeded(
            now: now.addingTimeInterval(30),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in await counter.extracted(); return Data() },
            commit: { _, _ in await counter.committed() }
        )
        expect(sameDay.contains(.deferredByFrequency(.domain(.finance))),
               "每个变化领域每天最多一次 AI 萃取")

        let retryScheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        await retryScheduler.markDirty(target: .domain(.habit), sourceDigest: "habit-v1", now: now)
        let failed = await retryScheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in throw TestError.expected },
            commit: { _, _ in }
        )
        guard case .failed(_, let retryAt) = failed.last else {
            fatalError("失败 observation 必须记录重试时间")
        }
        assertions += 1
        let beforeRetry = await retryScheduler.runIfNeeded(
            now: retryAt.addingTimeInterval(-1),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 0,
            materialChange: { _ in true },
            extract: { _ in await counter.extracted(); return Data() },
            commit: { _, _ in await counter.committed() }
        )
        expect(beforeRetry.contains(where: { if case .deferredByBackoff = $0 { true } else { false } }),
               "失败后必须按指数退避延后，不能立即重试")

        let counts = await counter.snapshot()
        expect(counts.0 == 1 && counts.1 == 1,
               "同 key/同日限制与退避期间不得重复调用或提交")
    }

    private static func testControlStateRecheckBeforeCommit() async throws {
        let control = SchedulerControlBox()
        let counter = CounterBox()
        let scheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        await scheduler.markDirty(target: .domain(.goal), sourceDigest: "goal-v1", now: now)
        let events = await scheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in
                await counter.extracted()
                await control.closeAndClear(at: now.addingTimeInterval(11))
                return Data("stale".utf8)
            },
            commit: { _, _ in await counter.committed() }
        )
        let counts = await counter.snapshot()
        expect(counts.0 == 1 && counts.1 == 0,
               "多设备关闭或清空发生在 AI 返回后时，旧任务不得提交")
        expect(events.contains(.cancelledByNewerControl(.domain(.goal))),
               "调度器应显式记录被更新用户控制取消")
    }

    private static func testMaterialThresholdCrossDomainAndDailyBudget() async throws {
        let control = SchedulerControlBox()
        let counter = CounterBox()

        let materialScheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        await materialScheduler.markDirty(
            target: .domain(.thought),
            sourceDigest: "tiny-change",
            now: now
        )
        let materialEvents = await materialScheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in false },
            extract: { _ in await counter.extracted(); return Data() },
            commit: { _, _ in await counter.committed() }
        )
        expect(materialEvents.contains(.belowMaterialThreshold(.domain(.thought))),
               "未达到 material change 阈值时不得调用 AI")
        let materialCounts = await counter.snapshot()
        expect(materialCounts.0 == 0 && materialCounts.1 == 0,
               "小变化不得消耗 AI 调用或产生提交")

        let crossScheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        await crossScheduler.markDirty(target: .crossDomain, sourceDigest: "cross-v1", now: now)
        _ = await crossScheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in Data() },
            commit: { _, _ in }
        )
        await crossScheduler.markDirty(
            target: .crossDomain,
            sourceDigest: "cross-v2",
            now: now.addingTimeInterval(20)
        )
        let weeklyEvents = await crossScheduler.runIfNeeded(
            now: now.addingTimeInterval(30),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in Data() },
            commit: { _, _ in }
        )
        expect(weeklyEvents.contains(.deferredByFrequency(.crossDomain)),
               "跨域融合每周最多运行一次")

        let budgetCounter = CounterBox()
        let budgetScheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        await budgetScheduler.markDirty(target: .domain(.task), sourceDigest: "task", now: now)
        await budgetScheduler.markDirty(target: .domain(.profile), sourceDigest: "profile", now: now)
        let budgetEvents = await budgetScheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(dailyAICallLimit: 1),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in await budgetCounter.extracted(); return Data() },
            commit: { _, _ in await budgetCounter.committed() }
        )
        let budgetCounts = await budgetCounter.snapshot()
        expect(budgetCounts.0 == 1 && budgetCounts.1 == 1,
               "日预算耗尽后，剩余领域必须延后")
        expect(budgetEvents.contains(.deferredByResource(.dailyBudgetExhausted)),
               "预算延后应留下可验证事件")
    }

    private static func testOnlyOneAIJobRunsAtATime() async throws {
        let control = SchedulerControlBox()
        let gate = ExtractionGate()
        let scheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        let now = Date(timeIntervalSince1970: 1_728_000_000)
        await scheduler.markDirty(target: .domain(.conversation), sourceDigest: "chat", now: now)
        let first = Task {
            await scheduler.runIfNeeded(
                now: now.addingTimeInterval(10),
                resourceSnapshot: .init(),
                extractorVersion: 1,
                promptVersion: 1,
                debounce: 5,
                materialChange: { _ in true },
                extract: { _ in await gate.wait(); return Data() },
                commit: { _, _ in }
            )
        }
        for _ in 0..<1_000 {
            if await gate.hasStarted() { break }
            await Task.yield()
        }
        let didStart = await gate.hasStarted()
        expect(didStart, "首个记忆 AI job 应已进入执行阶段")
        let second = await scheduler.runIfNeeded(
            now: now.addingTimeInterval(11),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 5,
            materialChange: { _ in true },
            extract: { _ in Data() },
            commit: { _, _ in }
        )
        expect(second == [.alreadyRunning], "同时最多只能运行一个记忆 AI job")
        await gate.release()
        _ = await first.value
    }

    #if DEBUG
    private static func testDebugResetValidationState() async throws {
        let control = SchedulerControlBox()
        let scheduler = HoloMemoryObservationScheduler(
            controlStateProvider: { await control.snapshot() },
            consentProvider: { await control.hasConsent() }
        )
        let now = Date(timeIntervalSince1970: 1_735_000_000)
        await scheduler.markDirty(target: .domain(.finance), sourceDigest: "finance", now: now)
        _ = await scheduler.runIfNeeded(
            now: now.addingTimeInterval(10),
            resourceSnapshot: .init(),
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 0,
            materialChange: { _ in true },
            extract: { _ in Data() },
            commit: { _, _ in }
        )
        let before = await scheduler.debugSnapshot(now: now.addingTimeInterval(10))
        expect(before.aiCallsToday == 1, "Debug 重置前应保留真实调用计数")

        let didReset = await scheduler.debugResetValidationState()
        expect(didReset, "Debug 重置应在空闲时成功")
        let after = await scheduler.debugSnapshot(now: now.addingTimeInterval(10))
        expect(after.aiCallsToday == 0, "Debug 重置应清空当日验证额度")
        expect(after.targets.allSatisfy { !$0.isDirty && $0.retryAt == nil },
               "Debug 重置应清空 dirty 与退避，但不操作用户记忆")
    }
    #endif

    enum TestError: Error { case expected }
}
