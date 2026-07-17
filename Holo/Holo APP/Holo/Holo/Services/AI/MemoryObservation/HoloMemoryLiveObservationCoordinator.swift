//
//  HoloMemoryLiveObservationCoordinator.swift
//  Holo
//
//  将真实模块快照、调度器、领域萃取、跨域融合和统一仓库串成静默运行链路。
//

import Foundation
import Network
import OSLog

nonisolated enum HoloMemoryLiveObservationPlan {
    private struct StableEvidence: Codable {
        var id: String
        var kind: HoloMemoryEvidenceKind
        var sourceDomain: HoloMemoryDomain
        var lineageKey: String
        var sourceID: String?
        var revisionDigest: String
        var aggregateDefinition: String?
        var sampleCount: Int?
        var summary: String?
    }

    private struct StableSignal: Codable {
        var id: String
        var domain: HoloMemoryDomain
        var kind: HoloDomainSignalKind
        var evidence: StableEvidence
        var anchors: [HoloMemoryAnchorRef]
        var numericFacts: [String: Double]
        var prohibitedInferences: [String]
        var userText: String?
        var explicitUserStance: String?
        var aiSummary: String?
    }

    static func signalDigest(_ signals: [HoloDomainMemorySignal]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stableSignals = signals.sorted { $0.id < $1.id }.map { signal in
            StableSignal(
                id: signal.id,
                domain: signal.domain,
                kind: signal.kind,
                evidence: StableEvidence(
                    id: signal.evidence.id,
                    kind: signal.evidence.kind,
                    sourceDomain: signal.evidence.sourceDomain,
                    lineageKey: signal.evidence.lineageKey,
                    sourceID: signal.evidence.sourceID,
                    revisionDigest: signal.evidence.revisionDigest,
                    aggregateDefinition: signal.evidence.aggregateDefinition,
                    sampleCount: signal.evidence.sampleCount,
                    summary: signal.evidence.summary
                ),
                anchors: signal.anchors.sorted { $0.stableKey < $1.stableKey },
                numericFacts: signal.numericFacts,
                prohibitedInferences: signal.prohibitedInferences.sorted(),
                userText: signal.userText,
                explicitUserStance: signal.explicitUserStance,
                aiSummary: signal.aiSummary
            )
        }
        let data = (try? encoder.encode(stableSignals)) ?? Data()
        return digest(String(decoding: data, as: UTF8.self))
    }

    static func changedDomainDigests(
        signalsByDomain: [HoloMemoryDomain: [HoloDomainMemorySignal]],
        previous: [String: String]
    ) -> [HoloMemoryDomain: String] {
        Dictionary(uniqueKeysWithValues: signalsByDomain.compactMap { domain, signals in
            guard !signals.isEmpty else { return nil }
            let current = signalDigest(signals)
            return previous[domain.rawValue] == current ? nil : (domain, current)
        })
    }

    static func crossDomainDigest(_ candidates: [HoloCrossDomainFusionCandidate]) -> String {
        digest(candidates.map(\.identityKey).sorted().joined(separator: "|"))
    }

    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

#if !HOLO_MEMORY_STANDALONE
private struct HoloMemoryNetworkSnapshot: Sendable {
    var isAvailable: Bool
    var isConstrained: Bool
}

private final class HoloMemoryNetworkState: @unchecked Sendable {
    static let shared = HoloMemoryNetworkState()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.holo.memory.network", qos: .utility)
    private let lock = NSLock()
    private var latest = HoloMemoryNetworkSnapshot(isAvailable: false, isConstrained: false)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            latest = HoloMemoryNetworkSnapshot(
                isAvailable: path.status == .satisfied,
                isConstrained: path.isConstrained
            )
            lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func snapshot() -> HoloMemoryNetworkSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

private struct HoloMemoryLiveExtractionPayload: Codable, Sendable {
    var domainPackage: HoloDomainObservationPackage?
    var crossDomainCandidates: [HoloCrossDomainFusionCandidate]?
    var modelOutput: Data
}

private enum HoloMemoryLiveObservationError: Error {
    case missingDomainSignals
    case invalidPayload
    case validationRejected
    case emptyCrossDomainCandidate
}

nonisolated struct HoloMemoryLiveObservationRunSummary: Equatable, Sendable {
    var developerMessage: String
    var changedDomainCount: Int
    var succeededCount: Int
    var failedCount: Int
}

actor HoloMemoryLiveObservationCoordinator {
    static let shared = HoloMemoryLiveObservationCoordinator()

    private let logger = Logger(subsystem: "com.holo.app", category: "LiveMemoryObservation")
    private let defaults = UserDefaults.standard
    private let signalDigestKey = "holo_memory_live_signalDigests_v1"
    private let fusionOccurrenceKey = "holo_memory_live_fusionOccurrences_v1"
    private var isRunning = false

    @discardableResult
    func run(
        trigger: HoloMemorySchedulerTrigger,
        now: Date = Date()
    ) async -> HoloMemoryLiveObservationRunSummary {
        guard trigger != .enteredBackground else {
            return .init(
                developerMessage: "未执行：进入后台只做轻量检查",
                changedDomainCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }
        guard !isRunning else {
            return .init(
                developerMessage: "未执行：已有记忆任务正在运行",
                changedDomainCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }
        let externalAIAllowed = await MainActor.run {
            HoloMemoryAccessPolicy.current.extractionDecision(for: .externalAI) == .allowedExternalAI
        }
        guard externalAIAllowed else {
            return .init(
                developerMessage: "未执行：请先开启自动形成记忆并确认数据处理授权",
                changedDomainCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }

        isRunning = true
        _ = HoloMemoryNetworkState.shared
        await HoloMemoryQualityMetrics.shared.recordConcurrentMemoryAIJobs(1)
        defer { isRunning = false }

        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            // 每次轻量观察先执行容量治理；只归档可重建的自动记忆，保留用户确认事实与墓碑。
            _ = try await HoloMemoryCompactionService().compact(
                repository: repository,
                now: now
            )
            let signalsByDomain = await MemorySignalDataAdapter.buildDomainSignals(now: now)
            let previousDigests = loadStringDictionary(forKey: signalDigestKey)
            let changed = HoloMemoryLiveObservationPlan.changedDomainDigests(
                signalsByDomain: signalsByDomain,
                previous: previousDigests
            )

            var nextDigests = previousDigests
            for (domain, digest) in changed {
                await HoloMemoryObservationScheduler.shared.markDirty(
                    target: .domain(domain),
                    sourceDigest: digest,
                    now: now
                )
                nextDigests[domain.rawValue] = digest
            }
            saveStringDictionary(nextDigests, forKey: signalDigestKey)

            let domainEvents = await runScheduler(
                repository: repository,
                signalsByDomain: signalsByDomain,
                now: now
            )
            let completedDomainRun = domainEvents.contains { event in
                if case .succeeded(let job) = event,
                   case .domain = job.target { return true }
                return false
            }
            guard completedDomainRun else {
                return summarize(events: domainEvents, changedDomainCount: changed.count)
            }

            let active = try await repository.query(.active).filter { $0.state == .active }
            let candidates = HoloCrossDomainCandidateBuilder.build(from: active)
            guard !candidates.isEmpty else {
                return summarize(events: domainEvents, changedDomainCount: changed.count)
            }
            await HoloMemoryObservationScheduler.shared.markDirty(
                target: .crossDomain,
                sourceDigest: HoloMemoryLiveObservationPlan.crossDomainDigest(candidates),
                now: now
            )
            let crossEvents = await runScheduler(
                repository: repository,
                signalsByDomain: signalsByDomain,
                now: now
            )
            return summarize(
                events: domainEvents + crossEvents,
                changedDomainCount: changed.count
            )
        } catch {
            // 不记录用户数据、摘要和 evidence，仅记录错误类型。
            logger.error("静默记忆运行失败：errorType=\(String(describing: type(of: error)), privacy: .public)")
            return .init(
                developerMessage: "失败：记忆运行环境异常（\(String(describing: type(of: error)))）",
                changedDomainCount: 0,
                succeededCount: 0,
                failedCount: 1
            )
        }
    }

    #if DEBUG
    /// 清理 Debug 调度、退避和脱敏回执，让真机可以立即重新验收；不会删除用户记忆。
    func debugResetValidationState() async -> Bool {
        guard !isRunning,
              await HoloMemoryObservationScheduler.shared.debugResetValidationState() else {
            return false
        }
        defaults.removeObject(forKey: signalDigestKey)
        defaults.removeObject(forKey: fusionOccurrenceKey)
        await HoloMemoryTraceStore.shared.removeAll()
        return true
    }
    #endif

    private func runScheduler(
        repository: any HoloMemoryRepository & HoloDomainMemoryObservationStore,
        signalsByDomain: [HoloMemoryDomain: [HoloDomainMemorySignal]],
        now: Date
    ) async -> [HoloMemorySchedulerEvent] {
        let process = ProcessInfo.processInfo
        let network = HoloMemoryNetworkState.shared.snapshot()
        let resource = HoloMemoryResourceSnapshot(
            networkAvailable: network.isAvailable,
            lowPowerModeEnabled: process.isLowPowerModeEnabled,
            lowDataModeEnabled: network.isConstrained,
            foregroundCriticalOperation: false,
            thermalPressureHigh: process.thermalState == .serious || process.thermalState == .critical,
            dailyAICallCount: 0,
            dailyAICallLimit: 8
        )
        return await HoloMemoryObservationScheduler.shared.runIfNeeded(
            now: now,
            resourceSnapshot: resource,
            extractorVersion: 1,
            promptVersion: 1,
            debounce: 0,
            materialChange: { entry in
                switch entry.target {
                case .domain(let domain):
                    return signalsByDomain[domain]?.isEmpty == false
                case .crossDomain:
                    let records = ((try? await repository.query(.active)) ?? [])
                        .filter { $0.state == .active }
                    return !HoloCrossDomainCandidateBuilder.build(from: records).isEmpty
                }
            },
            extract: { job in
                switch job.target {
                case .domain(let domain):
                    guard let signals = signalsByDomain[domain], !signals.isEmpty else {
                        throw HoloMemoryLiveObservationError.missingDomainSignals
                    }
                    let existing = try await repository.query(.domain(domain))
                    let package = HoloDomainObservationPackageBuilder.build(
                        domain: domain,
                        window: job.window,
                        signals: signals,
                        existingMemories: existing
                    )
                    let request = try HoloDomainObservationPackageBuilder.makeRequest(package)
                    let output: Data
                    do {
                        output = try await HoloBackendDomainMemoryLLMClient().extract(
                            request: request,
                            domain: domain
                        )
                    } catch {
                        #if DEBUG
                        await HoloMemoryTraceStore.shared.appendDomainPipeline(
                            domain: domain,
                            signalCount: signals.count,
                            packageRecordCount: existing.count,
                            validatorAcceptedCount: 0,
                            plannedMutationCount: 0,
                            aiRequestStatus: "failed:\(String(describing: type(of: error)))",
                            validatorRejections: nil,
                            committedMutationCount: 0,
                            outcome: "requestFailed"
                        )
                        #endif
                        throw error
                    }
                    return try JSONEncoder().encode(HoloMemoryLiveExtractionPayload(
                        domainPackage: package,
                        crossDomainCandidates: nil,
                        modelOutput: output
                    ))
                case .crossDomain:
                    let records = try await repository.query(.active)
                        .filter { $0.state == .active }
                    let candidates = HoloCrossDomainCandidateBuilder.build(from: records)
                    guard !candidates.isEmpty else {
                        throw HoloMemoryLiveObservationError.emptyCrossDomainCandidate
                    }
                    let output = try await HoloCrossDomainFusionService.requestFusion(for: candidates)
                    return try JSONEncoder().encode(HoloMemoryLiveExtractionPayload(
                        domainPackage: nil,
                        crossDomainCandidates: candidates,
                        modelOutput: output
                    ))
                }
            },
            commit: { [weak self] job, data in
                guard let self,
                      let payload = try? JSONDecoder().decode(
                        HoloMemoryLiveExtractionPayload.self,
                        from: data
                      ) else { throw HoloMemoryLiveObservationError.invalidPayload }
                switch job.target {
                case .domain(let domain):
                    guard let package = payload.domainPackage else {
                        throw HoloMemoryLiveObservationError.invalidPayload
                    }
                    let result = HoloDomainMemoryOutputValidator.decodeAndValidate(
                        payload.modelOutput,
                        against: package,
                        now: now,
                        extractorVersion: job.extractorVersion,
                        promptVersion: job.promptVersion
                    )
                    await HoloMemoryQualityMetrics.shared.recordValidation(
                        generated: result.validRecords.count + result.rejections.count,
                        rejected: result.rejections.count
                    )
                    guard result.rejections.isEmpty else {
                        #if DEBUG
                        await HoloMemoryTraceStore.shared.appendDomainPipeline(
                            domain: domain,
                            signalCount: package.signals.count,
                            packageRecordCount: package.existingMemories.count,
                            validatorAcceptedCount: result.validRecords.count,
                            plannedMutationCount: result.validRecords.count,
                            aiRequestStatus: "succeeded",
                            validatorRejections: result.rejections.map(\.rawValue),
                            committedMutationCount: 0,
                            outcome: "validatorRejected"
                        )
                        #endif
                        throw HoloMemoryLiveObservationError.validationRejected
                    }
                    do {
                        let upserts = try await HoloDomainMemoryObservationApplier.apply(
                            result,
                            to: repository,
                            observationKey: job.observationKey,
                            domain: domain,
                            extractorVersion: job.extractorVersion,
                            promptVersion: job.promptVersion,
                            completedAt: now
                        )
                        await self.recordWriteReceipts(
                            records: result.validRecords,
                            upserts: upserts,
                            batchKey: job.observationKey,
                            now: now
                        )
                        #if DEBUG
                        let committedCount = upserts.filter {
                            $0 == .inserted || $0 == .updated
                        }.count
                        await HoloMemoryTraceStore.shared.appendDomainPipeline(
                            domain: domain,
                            signalCount: package.signals.count,
                            packageRecordCount: package.existingMemories.count,
                            validatorAcceptedCount: result.validRecords.count,
                            plannedMutationCount: result.validRecords.count,
                            aiRequestStatus: "succeeded",
                            validatorRejections: [],
                            committedMutationCount: committedCount,
                            outcome: "succeeded"
                        )
                        #endif
                    } catch {
                        #if DEBUG
                        await HoloMemoryTraceStore.shared.appendDomainPipeline(
                            domain: domain,
                            signalCount: package.signals.count,
                            packageRecordCount: package.existingMemories.count,
                            validatorAcceptedCount: result.validRecords.count,
                            plannedMutationCount: result.validRecords.count,
                            aiRequestStatus: "succeeded",
                            validatorRejections: [],
                            committedMutationCount: 0,
                            outcome: "persistenceFailed:\(String(describing: type(of: error)))"
                        )
                        #endif
                        throw error
                    }
                case .crossDomain:
                    guard let candidates = payload.crossDomainCandidates else {
                        throw HoloMemoryLiveObservationError.invalidPayload
                    }
                    try await self.commitCrossDomain(
                        payload.modelOutput,
                        candidates: candidates,
                        repository: repository,
                        observationKey: job.observationKey,
                        now: now
                    )
                }
            }
        )
    }

    private func summarize(
        events: [HoloMemorySchedulerEvent],
        changedDomainCount: Int
    ) -> HoloMemoryLiveObservationRunSummary {
        let succeededCount = events.filter {
            if case .succeeded = $0 { return true }
            return false
        }.count
        let failedCount = events.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        let message: String
        if failedCount > 0 {
            message = "失败：\(failedCount) 个任务未通过；请进入对应领域查看具体阶段"
        } else if succeededCount > 0 {
            message = "成功：\(succeededCount) 个任务完成，\(changedDomainCount) 个领域检测到变化"
        } else if events.contains(.deferredByResource(.dailyBudgetExhausted)) {
            message = "未执行：今日 8 次静默 AI 调用额度已用完"
        } else if events.contains(.automaticMemoryDisabled) {
            message = "未执行：自动形成记忆未开启"
        } else if events.contains(.dataProcessingConsentMissing) {
            message = "未执行：尚未确认数据处理授权"
        } else if events.contains(where: {
            if case .deferredByBackoff = $0 { return true }
            return false
        }) {
            message = "未执行：任务仍在失败退避期"
        } else if changedDomainCount == 0 {
            message = "无需执行：没有检测到新的实质数据变化"
        } else {
            message = "未执行：当前设备资源或运行频率暂不满足条件"
        }
        return HoloMemoryLiveObservationRunSummary(
            developerMessage: message,
            changedDomainCount: changedDomainCount,
            succeededCount: succeededCount,
            failedCount: failedCount
        )
    }

    private func commitCrossDomain(
        _ data: Data,
        candidates: [HoloCrossDomainFusionCandidate],
        repository: any HoloMemoryRepository & HoloDomainMemoryObservationStore,
        observationKey: String,
        now: Date
    ) async throws {
        var occurrences = loadIntDictionary(forKey: fusionOccurrenceKey)
        let decisions = HoloCrossDomainFusionService.evaluate(
            data,
            against: candidates,
            priorOccurrenceCounts: occurrences,
            now: now
        )
        let rejectedCount = decisions.filter {
            if case .rejected = $0 { return true }
            return false
        }.count
        await HoloMemoryQualityMetrics.shared.recordValidation(
            generated: decisions.count,
            rejected: rejectedCount
        )
        if !decisions.isEmpty && rejectedCount == decisions.count {
            throw HoloMemoryLiveObservationError.validationRejected
        }
        for decision in decisions {
            switch decision {
            case .transient(let preview):
                occurrences[preview.candidateIdentityKey, default: 0] += 1
            case .persist(let record):
                let upsert = try await repository.upsert(record, observationKey: observationKey)
                recordWriteReceipts(
                    records: [record],
                    upserts: [upsert],
                    batchKey: observationKey,
                    now: now
                )
                if let candidate = candidates.first(where: {
                    Set($0.sourceMemoryIDs) == Set(record.upstreamMemoryIDs)
                }) {
                    occurrences[candidate.identityKey, default: 0] += 1
                }
            case .rejected:
                continue
            }
        }
        saveIntDictionary(occurrences, forKey: fusionOccurrenceKey)
    }

    private func recordWriteReceipts(
        records: [HoloMemoryRecord],
        upserts: [HoloMemoryUpsertResult],
        batchKey: String,
        now: Date
    ) {
        let inserted = zip(records, upserts).compactMap { pair in
            let (record, result) = pair
            return result == .inserted ? record : nil
        }
        let automaticallyAdopted = inserted.filter { $0.state == .active }
        let needsConfirmation = inserted.filter { $0.state == .candidate }
        if !automaticallyAdopted.isEmpty {
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: automaticallyAdopted.map(\.id),
                message: "Holo 新记住了 \(automaticallyAdopted.count) 件事",
                adoptionKind: .automaticallyAdopted,
                batchKey: "\(batchKey):automatic",
                now: now
            )
        }
        if !needsConfirmation.isEmpty {
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: needsConfirmation.map(\.id),
                message: "有 \(needsConfirmation.count) 件事想和你确认",
                adoptionKind: .needsConfirmation,
                batchKey: "\(batchKey):confirmation",
                now: now
            )
        }
    }

    private func loadStringDictionary(forKey key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func saveStringDictionary(_ value: [String: String], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private func loadIntDictionary(forKey key: String) -> [String: Int] {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    private func saveIntDictionary(_ value: [String: Int], forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
#endif
