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
    static func signalDigest(_ signals: [HoloDomainMemorySignal]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(signals.sorted { $0.id < $1.id })) ?? Data()
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

actor HoloMemoryLiveObservationCoordinator {
    static let shared = HoloMemoryLiveObservationCoordinator()

    private let logger = Logger(subsystem: "com.holo.app", category: "LiveMemoryObservation")
    private let defaults = UserDefaults.standard
    private let signalDigestKey = "holo_memory_live_signalDigests_v1"
    private let fusionOccurrenceKey = "holo_memory_live_fusionOccurrences_v1"
    private var isRunning = false

    func run(trigger: HoloMemorySchedulerTrigger, now: Date = Date()) async {
        guard trigger != .enteredBackground, !isRunning else { return }
        let externalAIAllowed = await MainActor.run {
            HoloMemoryAccessPolicy.current.extractionDecision(for: .externalAI) == .allowedExternalAI
        }
        guard externalAIAllowed else { return }

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
            guard completedDomainRun else { return }

            let active = try await repository.query(.active)
            let candidates = HoloCrossDomainCandidateBuilder.build(from: active)
            guard !candidates.isEmpty else { return }
            await HoloMemoryObservationScheduler.shared.markDirty(
                target: .crossDomain,
                sourceDigest: HoloMemoryLiveObservationPlan.crossDomainDigest(candidates),
                now: now
            )
            _ = await runScheduler(
                repository: repository,
                signalsByDomain: signalsByDomain,
                now: now
            )
        } catch {
            // 不记录用户数据、摘要和 evidence，仅记录错误类型。
            logger.error("静默记忆运行失败：errorType=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

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
                    let records = (try? await repository.query(.active)) ?? []
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
                    let output = try await HoloBackendDomainMemoryLLMClient().extract(
                        request: request,
                        domain: domain
                    )
                    return try JSONEncoder().encode(HoloMemoryLiveExtractionPayload(
                        domainPackage: package,
                        crossDomainCandidates: nil,
                        modelOutput: output
                    ))
                case .crossDomain:
                    let records = try await repository.query(.active)
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
                        throw HoloMemoryLiveObservationError.validationRejected
                    }
                    _ = try await HoloDomainMemoryObservationApplier.apply(
                        result,
                        to: repository,
                        observationKey: job.observationKey,
                        domain: domain,
                        extractorVersion: job.extractorVersion,
                        promptVersion: job.promptVersion,
                        completedAt: now
                    )
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
                _ = try await repository.upsert(record, observationKey: observationKey)
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
