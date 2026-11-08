import Foundation

/// 「一个发现」是统一知识的审阅入口。本机新观察先预览，用户作出决定时才写入。
@MainActor
struct DiscoveryMemoryReviewService {
    struct Item: Identifiable {
        var id: String { knowledge.propositionID }
        let knowledge: HoloResolvedKnowledge
        let proposal: HoloKnowledgeRevision?
    }

    struct Result {
        let items: [Item]
        let checkedAt: Date
        let healthNotice: HealthNotice?
    }

    enum HealthNotice {
        case noReadings, waitingForUnlock, unavailable
    }

    private struct LocalScan {
        let proposals: [HoloKnowledgeRevision]
        let healthNotice: HealthNotice?
    }

    var domains: Set<HoloMemoryDomain> {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return [] }
        return DiscoverySettings.shared.memoryReviewDomains()
    }

    func review() async throws -> Result {
        let allowed = domains
        let epoch = DiscoverySettings.shared.localGrantEpoch
        let now = Date()
        guard !allowed.isEmpty else { return Result(items: [], checkedAt: now, healthNotice: nil) }
        let repository = try await HoloMemoryRuntime.shared.repository()
        async let scan = scanLocal(domains: allowed, now: now)
        let resolved = try await repository.resolvedKnowledgeAll(now: now)
        let local = try await scan
        let control = try await repository.loadControlState()
        var items: [Item] = []
        for draft in local.proposals {
            let stored = try await repository.knowledgeStoreSnapshot(propositionID: draft.propositionID)
            let preview = stored.includingProposal(draft, controlGeneration: control.userDecisionVersion, now: now)
                .resolve(
                    propositionID: draft.propositionID, controlGeneration: control.userDecisionVersion,
                    learningBaselineAt: control.learningBaselineAt, now: now
                )
            guard let preview, Self.isReviewable(preview, allowed: allowed, now: now),
                  preview.proposedRevision?.semanticDigest == draft.semanticDigest,
                  preview.latestEvidenceSnapshot?.id == draft.initialEvidenceSnapshot.id else { continue }
            items.append(Item(knowledge: preview, proposal: draft))
        }

        // 已有萃取结果也走统一资格和回源。旧健康聚合缺少当前读数身份，交给本机新统计。
        let verifier = makeVerifier()
        let existing = resolved.filter {
            Self.isReviewable($0, allowed: allowed, now: now)
                && $0.proposedRevision?.origin?.producer != HoloRecordedPatternMiner.producer
                && !$0.domains.contains(.health)
        }.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
        for knowledge in existing.prefix(8) {
            try Task.checkCancellation()
            guard await sourcesAreCurrent(knowledge, verifier: verifier) else { continue }
            items.append(Item(knowledge: knowledge, proposal: nil))
        }
        try Task.checkCancellation()
        guard epoch == DiscoverySettings.shared.localGrantEpoch, allowed == domains else {
            throw CancellationError()
        }
        // 交错呈现领域，财务记录多时也能尽快看到健康观察。
        let firstByDomain = items.reduce(into: [HoloMemoryDomain: Item]()) { result, item in
            if let domain = item.knowledge.domains.first, result[domain] == nil { result[domain] = item }
        }
        let first = HoloMemoryDomain.allCases.compactMap { firstByDomain[$0] }
        let firstIDs = Set(first.map(\.id))
        return Result(
            items: first + items.filter { !firstIDs.contains($0.id) },
            checkedAt: now, healthNotice: local.healthNotice
        )
    }

    func apply(_ action: HoloKnowledgeControlAction, to item: Item) async throws -> HoloKnowledgeControlOutcome {
        let allowed = domains
        let epoch = DiscoverySettings.shared.localGrantEpoch
        let now = Date()
        let shown = item.knowledge
        guard Self.isReviewable(shown, allowed: allowed, now: now),
              let digest = shown.proposedRevision?.semanticDigest,
              let evidence = shown.latestEvidenceSnapshot else { return .notAllowed(reason: "scopeChanged") }

        let repository = try await HoloMemoryRuntime.shared.repository()
        var freshProposal: HoloKnowledgeRevision?
        if let proposal = item.proposal {
            let scan = try await scanLocal(domains: Set(proposal.domains), now: now)
            guard let fresh = scan.proposals.first(where: {
                $0.propositionID == proposal.propositionID && $0.semanticDigest == digest
                    && $0.initialEvidenceSnapshot.id == evidence.id
            }) else { return .conflict(currentSemanticDigest: nil, reason: "sourceChanged") }
            freshProposal = fresh
        } else {
            guard let current = try await repository.resolvedKnowledge(propositionID: shown.propositionID, now: now),
                  Self.isReviewable(current, allowed: allowed, now: now),
                  current.proposedRevision?.semanticDigest == digest, current.latestEvidenceSnapshot?.id == evidence.id,
                  await sourcesAreCurrent(current, verifier: makeVerifier()) else {
                return .conflict(currentSemanticDigest: nil, reason: "sourceChanged")
            }
        }
        try Task.checkCancellation()
        guard epoch == DiscoverySettings.shared.localGrantEpoch, allowed == domains else {
            return .notAllowed(reason: "scopeChanged")
        }
        return try await HoloKnowledgeControlService(repository: repository).apply(
            .init(
                propositionID: shown.propositionID, expectedSemanticDigest: digest,
                knownOperationIDs: shown.restrictingOperationIDs, action: action,
                entry: DiscoveryKnowledgeBridge.originEntry, issuedAt: now
            ),
            proposal: freshProposal,
            expectedEvidenceID: evidence.id
        )
    }

    nonisolated static func isReviewable(_ knowledge: HoloResolvedKnowledge, allowed: Set<HoloMemoryDomain>, now: Date) -> Bool {
        let refs = refs(for: knowledge)
        let sources = Set(knowledge.domains + refs.map(\.sourceDomain))
        return knowledge.decision == .worthConfirming && knowledge.proposedRevision != nil
            && !refs.isEmpty && sources.isSubset(of: allowed)
            && (knowledge.cooldownUntil ?? .distantPast) <= now
    }

    nonisolated private static func refs(for knowledge: HoloResolvedKnowledge) -> [HoloMemoryEvidenceRef] {
        guard let evidence = knowledge.latestEvidenceSnapshot else { return [] }
        return evidence.supportRefs + evidence.counterRefs
    }

    private func makeVerifier() -> HoloKnowledgeCoreDataSourceVerifier {
        HoloKnowledgeCoreDataSourceVerifier(businessContainer: CoreDataStack.shared.persistentContainer)
    }

    private func sourcesAreCurrent(
        _ knowledge: HoloResolvedKnowledge, verifier: HoloKnowledgeCoreDataSourceVerifier
    ) async -> Bool {
        let refs = Self.refs(for: knowledge)
        let checked = await verifier.verifyBatch(refs)
        return refs.allSatisfy { checked[$0.id] == .verified }
    }

    private func scanLocal(domains: Set<HoloMemoryDomain>, now: Date) async throws -> LocalScan {
        let calendar = Calendar(identifier: .iso8601)
        guard let window = HoloRecordedPatternMiner.window(at: now, calendar: calendar) else {
            return LocalScan(proposals: [], healthNotice: nil)
        }
        async let health = domains.contains(.health) ? scanHealth(window: window, calendar: calendar) : nil
        let finance = domains.contains(.finance)
            ? try await MemorySignalDataAdapter.buildRecordedExpenseInputs(window: window) : []
        let healthResult = await health
        let financeProposals = HoloRecordedPatternMiner.finance(finance, window: window, calendar: calendar)
        return LocalScan(
            proposals: financeProposals + (healthResult?.proposals ?? []),
            healthNotice: healthResult?.healthNotice
        )
    }

    private func scanHealth(window: DateInterval, calendar: Calendar) async -> LocalScan {
        #if targetEnvironment(simulator)
        // 健康仓库在模拟器生成示例数据；发现只接受真实 HealthKit 读数。
        return LocalScan(proposals: [], healthNotice: .noReadings)
        #else
        let health = HealthRepository.shared
        guard health.hasRequestedPermission || health.isAuthorized else {
            return LocalScan(proposals: [], healthNotice: .noReadings)
        }
        let end = window.end.addingTimeInterval(-1)
        async let steps = health.fetchDailyRangeStrict(for: .steps, from: window.start, to: end)
        async let sleep = health.fetchDailyRangeStrict(for: .sleep, from: window.start, to: end)
        let observations: [(HoloRecordedPatternMiner.HealthMetric, HoloHealthQueryOutcome<[DailyHealthData]>)] = await [
            (.steps, steps), (.sleep, sleep)
        ]
        var proposals: [HoloKnowledgeRevision] = []
        var hasReadings = false
        var notices: [HealthNotice] = []
        for (metric, outcome) in observations {
            switch outcome {
            case .value(let days):
                hasReadings = true
                if let proposal = HoloRecordedPatternMiner.health(
                    days.map { .init(day: $0.date, value: $0.value) },
                    metric: metric, window: window, calendar: calendar
                ) { proposals.append(proposal) }
            case .noData: continue
            case .waitingForUnlock: notices.append(.waitingForUnlock)
            case .unavailable(.authorizationDenied): notices.append(.noReadings)
            case .unavailable(.recoverable): notices.append(.unavailable)
            }
        }
        return LocalScan(
            proposals: proposals,
            healthNotice: notices.first ?? (hasReadings ? nil : .noReadings)
        )
        #endif
    }
}
