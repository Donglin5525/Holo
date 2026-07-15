//
//  HoloMemoryQueryService.swift
//  Holo
//
//  统一访问策略、结构化相关性排序、token 预算与异步刷新。
//

import Foundation

nonisolated enum HoloMemoryQueryBudgetPolicy {
    static let p95LatencyTargetMilliseconds: Double = 100
    static let defaultTokenBudget = 2_000
    static let defaultMaximumRecords = 8
    static let serialNetworkRoundTripsOnCriticalPath = 0
}

protocol HoloMemoryQueryStore: Sendable {
    func fetchAvailableMemoryRecords() async throws -> [HoloMemoryRecord]
    func fetchSuppressionCount() async throws -> Int
}

extension HoloMemoryQueryStore {
    func fetchSuppressionCount() async throws -> Int { 0 }
}

#if !HOLO_MEMORY_STANDALONE
extension CoreDataHoloMemoryRepository: HoloMemoryQueryStore {
    func fetchAvailableMemoryRecords() async throws -> [HoloMemoryRecord] {
        try await query(.active)
    }

    func fetchSuppressionCount() async throws -> Int {
        try await queryTombstones().count
    }
}
#endif

struct HoloMemoryQueryContext: Equatable, Sendable {
    var route: HoloMemoryQueryRoute
    var answerAuthority: HoloMemoryAnswerAuthority
    var records: [HoloMemoryRecord]
    var requiresDetailData: Bool
    var estimatedTokens: Int
    var refreshDecision: HoloMemoryRefreshDecision
}

struct HoloMemoryQueryService: Sendable {
    typealias AnsweringAllowed = @Sendable (HoloMemoryAnswerConsumer) async -> Bool

    private let store: any HoloMemoryQueryStore
    private let answeringAllowed: AnsweringAllowed
    private let refreshCoordinator: HoloMemoryRefreshCoordinator

    init(
        store: any HoloMemoryQueryStore,
        answeringAllowed: @escaping AnsweringAllowed,
        refreshCoordinator: HoloMemoryRefreshCoordinator
    ) {
        self.store = store
        self.answeringAllowed = answeringAllowed
        self.refreshCoordinator = refreshCoordinator
    }

    #if !HOLO_MEMORY_STANDALONE
    static func live() async throws -> HoloMemoryQueryService {
        let repository = try await HoloMemoryRuntime.shared.repository()
        return HoloMemoryQueryService(
            store: repository,
            answeringAllowed: { consumer in
                await MainActor.run {
                    HoloMemoryAccessPolicy.current.answeringDecision(for: consumer) == .allowed
                }
            },
            refreshCoordinator: .live
        )
    }
    #endif

    func query(
        question: String,
        semanticContext: HoloMemoryQuerySemanticContext? = nil,
        consumer: HoloMemoryAnswerConsumer = .chat,
        now: Date = Date(),
        tokenBudget: Int = HoloMemoryQueryBudgetPolicy.defaultTokenBudget,
        maxRecords: Int = HoloMemoryQueryBudgetPolicy.defaultMaximumRecords
    ) async throws -> HoloMemoryQueryContext {
        let queryStartedAt = Date()
        let intent = HoloMemoryQueryRouter.route(
            question,
            semanticContext: semanticContext,
            now: now
        )
        guard await answeringAllowed(consumer) else {
            let disabledContext = HoloMemoryQueryContext(
                route: intent.route,
                answerAuthority: intent.answerAuthority,
                records: [],
                requiresDetailData: intent.requiresDetailData,
                estimatedTokens: 0,
                refreshDecision: .disabled
            )
            #if !HOLO_MEMORY_STANDALONE
            await HoloMemoryQualityMetrics.shared.recordQuery(
                durationMilliseconds: Date().timeIntervalSince(queryStartedAt) * 1_000,
                selectedCount: 0
            )
            if consumer == .chat {
                await HoloMemoryQualityMetrics.shared.recordChatPath(serialNetworkRoundTrips: 0)
            }
            #endif
            return disabledContext
        }

        let available = try await store.fetchAvailableMemoryRecords().filter {
            $0.state == .active &&
            ![.rejected, .forgotten, .markedIrrelevant].contains($0.userDecision)
        }
        let matching = available.filter { matches($0, intent: intent) }
        let ranked = matching.sorted {
            let left = score($0, intent: intent, now: now)
            let right = score($1, intent: intent, now: now)
            if left == right { return $0.id < $1.id }
            return left > right
        }

        var selected: [HoloMemoryRecord] = []
        var usedTokens = 0
        for record in ranked.prefix(max(0, maxRecords)) {
            let cost = estimatedTokens(for: record)
            guard usedTokens + cost <= max(0, tokenBudget) else { continue }
            selected.append(record)
            usedTokens += cost
        }
        let refresh = refreshCoordinator.scheduleIfNeeded(for: selected, now: now)
        let context = HoloMemoryQueryContext(
            route: intent.route,
            answerAuthority: intent.answerAuthority,
            records: selected,
            requiresDetailData: intent.requiresDetailData,
            estimatedTokens: usedTokens,
            refreshDecision: refresh
        )
        #if !HOLO_MEMORY_STANDALONE
        await HoloMemoryQualityMetrics.shared.recordQuery(
            durationMilliseconds: Date().timeIntervalSince(queryStartedAt) * 1_000,
            selectedCount: selected.count
        )
        if consumer == .chat {
            await HoloMemoryQualityMetrics.shared.recordChatPath(serialNetworkRoundTrips: 0)
        }
        #endif
        return context
    }

    func suppressionCount(
        consumer: HoloMemoryAnswerConsumer
    ) async -> Int {
        guard await answeringAllowed(consumer) else { return 0 }
        return (try? await store.fetchSuppressionCount()) ?? 0
    }

    private func matches(
        _ record: HoloMemoryRecord,
        intent: HoloMemoryQueryIntent
    ) -> Bool {
        switch intent.route {
        case .detail, .domainMemory:
            guard record.scope == .domain else { return false }
        case .holisticMemory, .planningHybrid:
            if record.scope == .crossDomain { return intent.includeCrossDomain }
        }
        if !intent.requestedDomains.isEmpty,
           Set(record.sourceDomains).isDisjoint(with: intent.requestedDomains) {
            return false
        }
        if !intent.requestedClaimKinds.isEmpty,
           !intent.requestedClaimKinds.contains(record.claimKind) {
            return false
        }
        if !intent.requestedAnchors.isEmpty {
            let recordAnchors = Set(record.anchorRefs.map(\.stableKey))
            let requested = Set(intent.requestedAnchors.map(\.stableKey))
            if recordAnchors.isDisjoint(with: requested) { return false }
        }
        return true
    }

    private func score(
        _ record: HoloMemoryRecord,
        intent: HoloMemoryQueryIntent,
        now: Date
    ) -> Double {
        var relevance = 0.2
        if !Set(record.sourceDomains).isDisjoint(with: intent.requestedDomains) {
            relevance += 0.3
        }
        if intent.requestedClaimKinds.contains(record.claimKind) { relevance += 0.15 }
        let recordAnchors = Set(record.anchorRefs.map(\.stableKey))
        if intent.requestedAnchors.contains(where: { recordAnchors.contains($0.stableKey) }) {
            relevance += 0.25
        }
        if intent.route == .holisticMemory && record.scope == .crossDomain { relevance += 0.2 }
        if intent.includeProfile && record.sourceDomains.contains(.profile) { relevance += 0.2 }
        if intent.route == .planningHybrid && record.sourceDomains.contains(.goal) { relevance += 0.2 }

        var applicability = 1.0
        if let requested = intent.timeRange,
           let validFrom = record.validFrom,
           let validTo = record.validTo,
           (validTo < requested.start || validFrom > requested.end) {
            applicability = 0.35
        }
        // 持久化的新鲜度包含反证等历史降权；查询时再叠加时间衰减，避免旧结论长期占据高位。
        let timeFreshness = HoloMemoryScorer.freshness(
            persistenceClass: record.persistenceClass,
            lastSupportedAt: record.lastSupportedAt,
            now: now
        )
        return HoloMemoryScorer.recallScore(
            relevance: min(1, relevance),
            freshness: min(record.freshnessScore, timeFreshness),
            confidence: record.confidenceScore,
            contextApplicability: applicability
        )
    }

    private func estimatedTokens(for record: HoloMemoryRecord) -> Int {
        let characterCount = record.aiUseSummary.count +
            record.prohibitedInferences.joined(separator: "；").count + 48
        return max(1, Int(ceil(Double(characterCount) / 1.8)))
    }
}
