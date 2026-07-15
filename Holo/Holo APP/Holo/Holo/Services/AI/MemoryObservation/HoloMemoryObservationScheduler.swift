//
//  HoloMemoryObservationScheduler.swift
//  Holo
//
//  轻量触发、幂等 observation、频率限制、退避和提交前用户控制复核。
//

import Foundation

nonisolated struct HoloMemoryScheduledObservation: Equatable, Sendable {
    var target: HoloMemoryObservationTarget
    var window: HoloMemoryObservationWindow
    var sourceDigest: String
    var observationKey: String
    var extractorVersion: Int
    var promptVersion: Int
}

nonisolated enum HoloMemorySchedulerEvent: Equatable, Sendable {
    case succeeded(HoloMemoryScheduledObservation)
    case failed(HoloMemoryObservationTarget, retryAt: Date)
    case deferredByResource(HoloMemoryResourceDeferral)
    case deferredByFrequency(HoloMemoryObservationTarget)
    case deferredByBackoff(HoloMemoryObservationTarget, until: Date)
    case belowMaterialThreshold(HoloMemoryObservationTarget)
    case cancelledByNewerControl(HoloMemoryObservationTarget)
    case automaticMemoryDisabled
    case dataProcessingConsentMissing
    case alreadyRunning
}

nonisolated enum HoloMemorySchedulerTrigger: String, Sendable {
    case appLaunch
    case enteredBackground
    case becameActive
    case dataChanged
}

private nonisolated struct HoloMemoryRetryState: Codable, Sendable {
    var attempt: Int
    var retryAt: Date
}

private nonisolated struct HoloMemorySchedulerPersistedState: Codable, Sendable {
    var registry = HoloMemoryDirtyRegistry()
    var successfulObservationKeys: [String: Date] = [:]
    var lastSuccessfulAtByTarget: [String: Date] = [:]
    var retryByObservationKey: [String: HoloMemoryRetryState] = [:]
    var aiCallDates: [Date] = []
}

#if DEBUG
nonisolated struct HoloMemorySchedulerDebugTargetSnapshot: Equatable, Sendable {
    var targetKey: String
    var isDirty: Bool
    var dirtySince: Date?
    var changeCount: Int
    var lastSuccessfulAt: Date?
    var retryAt: Date?
}

nonisolated struct HoloMemorySchedulerDebugSnapshot: Equatable, Sendable {
    var targets: [HoloMemorySchedulerDebugTargetSnapshot]
    var aiCallsToday: Int
    var dailyCallLimit: Int
    var isRunning: Bool
}
#endif

actor HoloMemoryObservationScheduler {
    typealias ControlStateProvider = @Sendable () async -> HoloMemoryControlState
    typealias ConsentProvider = @Sendable () async -> Bool

    #if !HOLO_MEMORY_STANDALONE
    static let shared = HoloMemoryObservationScheduler(
        controlStateProvider: {
            await HoloMemoryRuntime.shared.loadUserControlState()
                ?? HoloMemoryControlState.initial(now: Date(timeIntervalSince1970: 0))
        },
        consentProvider: {
            await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
        },
        defaults: .standard
    )
    #endif

    private let controlStateProvider: ControlStateProvider
    private let consentProvider: ConsentProvider
    private let defaults: UserDefaults?
    private let stateKey = "holo_memory_observationScheduler_v1"
    private var state: HoloMemorySchedulerPersistedState
    private var isRunning = false
    private var lastLightweightTrigger: HoloMemorySchedulerTrigger?

    init(
        controlStateProvider: @escaping ControlStateProvider,
        consentProvider: @escaping ConsentProvider,
        defaults: UserDefaults? = nil
    ) {
        self.controlStateProvider = controlStateProvider
        self.consentProvider = consentProvider
        self.defaults = defaults
        if let data = defaults?.data(forKey: stateKey),
           let restored = try? JSONDecoder().decode(
               HoloMemorySchedulerPersistedState.self,
               from: data
           ) {
            state = restored
        } else {
            state = HoloMemorySchedulerPersistedState()
        }
    }

    func markDirty(
        target: HoloMemoryObservationTarget,
        sourceDigest: String,
        now: Date = Date()
    ) {
        state.registry.markDirty(target: target, sourceDigest: sourceDigest, now: now)
        persist()
    }

    /// 生命周期事件只做常量时间检查，不等待数据库或网络，避免阻塞首屏与切前后台。
    func lightweightCheck(trigger: HoloMemorySchedulerTrigger) async {
        lastLightweightTrigger = trigger
        #if !HOLO_MEMORY_STANDALONE
        Task(priority: .utility) {
            await HoloMemoryLiveObservationCoordinator.shared.run(trigger: trigger)
        }
        #endif
        await Task.yield()
    }

    #if DEBUG
    func debugSnapshot(
        now: Date = Date(),
        dailyCallLimit: Int = 8
    ) -> HoloMemorySchedulerDebugSnapshot {
        let targetKeys = HoloMemoryDomain.allCases.map {
            HoloMemoryObservationTarget.domain($0).stableKey
        } + [HoloMemoryObservationTarget.crossDomain.stableKey]
        let snapshots = targetKeys.map { key in
            let dirty = state.registry.entry(for: target(for: key))
            let retryAt = state.retryByObservationKey
                .filter { $0.key.hasPrefix(key + "|") }
                .map(\.value.retryAt)
                .max()
            return HoloMemorySchedulerDebugTargetSnapshot(
                targetKey: key,
                isDirty: dirty != nil,
                dirtySince: dirty?.firstDirtyAt,
                changeCount: dirty?.changeCount ?? 0,
                lastSuccessfulAt: state.lastSuccessfulAtByTarget[key],
                retryAt: retryAt
            )
        }
        return HoloMemorySchedulerDebugSnapshot(
            targets: snapshots,
            aiCallsToday: state.aiCallDates.filter { Self.isSameDayUTC($0, now) }.count,
            dailyCallLimit: dailyCallLimit,
            isRunning: isRunning
        )
    }

    /// 仅供 Debug 真机验收重新开始一次干净运行；不删除任何用户记忆或业务数据。
    func debugResetValidationState() -> Bool {
        guard !isRunning else { return false }
        state = HoloMemorySchedulerPersistedState()
        lastLightweightTrigger = nil
        persist()
        return true
    }

    private func target(for key: String) -> HoloMemoryObservationTarget {
        if key == HoloMemoryObservationTarget.crossDomain.stableKey { return .crossDomain }
        let rawValue = key.replacingOccurrences(of: "domain:", with: "")
        return .domain(HoloMemoryDomain(rawValue: rawValue) ?? .profile)
    }
    #endif

    func runIfNeeded(
        now: Date,
        resourceSnapshot: HoloMemoryResourceSnapshot,
        extractorVersion: Int,
        promptVersion: Int,
        debounce: TimeInterval = 30,
        catchUpLimit: TimeInterval = 14 * 86_400,
        materialChange: @Sendable (HoloMemoryDirtyEntry) async -> Bool,
        extract: @Sendable (HoloMemoryScheduledObservation) async throws -> Data,
        commit: @Sendable (HoloMemoryScheduledObservation, Data) async throws -> Void
    ) async -> [HoloMemorySchedulerEvent] {
        guard !isRunning else { return [.alreadyRunning] }

        state.aiCallDates.removeAll { $0 < now.addingTimeInterval(-8 * 86_400) }
        state.successfulObservationKeys = state.successfulObservationKeys.filter {
            $0.value >= now.addingTimeInterval(-90 * 86_400)
        }
        state.retryByObservationKey = state.retryByObservationKey.filter {
            $0.value.retryAt >= now.addingTimeInterval(-86_400)
        }

        let initialControl = await controlStateProvider()
        guard initialControl.automaticMemoryEnabled else {
            return [.automaticMemoryDisabled]
        }
        guard await consentProvider() else {
            return [.dataProcessingConsentMissing]
        }

        let todayCalls = state.aiCallDates.filter { Self.isSameDayUTC($0, now) }.count
        var effectiveResources = resourceSnapshot
        effectiveResources.dailyAICallCount += todayCalls
        if case .deferred(let reason) = HoloMemoryResourceBudget.evaluate(effectiveResources) {
            return [.deferredByResource(reason)]
        }

        let ready = state.registry.readyEntries(now: now, debounce: debounce)
        guard !ready.isEmpty else { return [] }
        isRunning = true
        defer { isRunning = false }

        var events: [HoloMemorySchedulerEvent] = []
        for entry in ready {
            let callsToday = state.aiCallDates.filter { Self.isSameDayUTC($0, now) }.count
            if resourceSnapshot.dailyAICallCount + callsToday >= resourceSnapshot.dailyAICallLimit {
                events.append(.deferredByResource(.dailyBudgetExhausted))
                break
            }
            if reachedFrequencyLimit(for: entry.target, now: now) {
                events.append(.deferredByFrequency(entry.target))
                continue
            }
            guard await materialChange(entry) else {
                state.registry.consume(entry.target)
                events.append(.belowMaterialThreshold(entry.target))
                persist()
                continue
            }

            let window = HoloMemoryObservationWindow.make(
                target: entry.target,
                dirtySince: entry.firstDirtyAt,
                now: now,
                catchUpLimit: catchUpLimit
            )
            let key = HoloMemoryObservationKey.make(
                target: entry.target,
                window: window,
                sourceDigest: entry.combinedSourceDigest,
                extractorVersion: extractorVersion,
                promptVersion: promptVersion
            )
            if state.successfulObservationKeys[key] != nil {
                state.registry.consume(entry.target)
                persist()
                continue
            }
            if let retry = state.retryByObservationKey[key], retry.retryAt > now {
                events.append(.deferredByBackoff(entry.target, until: retry.retryAt))
                continue
            }

            let currentControl = await controlStateProvider()
            guard controlAllowsJob(currentControl, matching: initialControl),
                  await consentProvider() else {
                events.append(.cancelledByNewerControl(entry.target))
                continue
            }

            let job = HoloMemoryScheduledObservation(
                target: entry.target,
                window: window,
                sourceDigest: entry.combinedSourceDigest,
                observationKey: key,
                extractorVersion: extractorVersion,
                promptVersion: promptVersion
            )
            do {
                let output = try await extract(job)
                state.aiCallDates.append(now)

                let beforeCommit = await controlStateProvider()
                guard controlAllowsJob(beforeCommit, matching: initialControl),
                      await consentProvider() else {
                    events.append(.cancelledByNewerControl(entry.target))
                    persist()
                    continue
                }
                try await commit(job, output)
                state.successfulObservationKeys[key] = now
                state.lastSuccessfulAtByTarget[entry.target.stableKey] = now
                state.retryByObservationKey.removeValue(forKey: key)
                state.registry.consume(entry.target)
                events.append(.succeeded(job))
                persist()
            } catch {
                let previousAttempt = state.retryByObservationKey[key]?.attempt ?? 0
                let attempt = previousAttempt + 1
                let delay = min(pow(2, Double(attempt - 1)) * 60, 6 * 60 * 60)
                let retryAt = now.addingTimeInterval(delay)
                state.retryByObservationKey[key] = HoloMemoryRetryState(
                    attempt: attempt,
                    retryAt: retryAt
                )
                events.append(.failed(entry.target, retryAt: retryAt))
                persist()
            }
        }
        return events
    }

    private func controlAllowsJob(
        _ current: HoloMemoryControlState,
        matching initial: HoloMemoryControlState
    ) -> Bool {
        current.automaticMemoryEnabled &&
        current.userDecisionVersion == initial.userDecisionVersion &&
        current.learningBaselineAt == initial.learningBaselineAt
    }

    private func reachedFrequencyLimit(
        for target: HoloMemoryObservationTarget,
        now: Date
    ) -> Bool {
        guard let last = state.lastSuccessfulAtByTarget[target.stableKey] else { return false }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch target {
        case .domain:
            return Self.isSameDayUTC(last, now)
        case .crossDomain:
            let lhs = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: last)
            let rhs = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return lhs == rhs
        }
    }

    private func persist() {
        guard let defaults,
              let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    private nonisolated static func isSameDayUTC(_ lhs: Date, _ rhs: Date) -> Bool {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: lhs) ==
            calendar.dateComponents([.year, .month, .day], from: rhs)
    }
}
