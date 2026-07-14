//
//  HoloMemoryRefreshCoordinator.swift
//  Holo
//
//  Stale-while-revalidate：本轮先用可用记忆，刷新只进入后台队列。
//

import Foundation

enum HoloMemoryRefreshTarget: Codable, Equatable, Hashable, Sendable {
    case domain(HoloMemoryDomain)
    case crossDomain

    var stableKey: String {
        switch self {
        case .domain(let domain): return "domain:\(domain.rawValue)"
        case .crossDomain: return "cross-domain"
        }
    }
}

enum HoloMemoryRefreshDecision: Equatable, Sendable {
    case none
    case scheduled([HoloMemoryRefreshTarget])
    case disabled
}

struct HoloMemoryRefreshCoordinator: Sendable {
    typealias Handler = @Sendable ([HoloMemoryRefreshTarget]) async -> Void
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func scheduleIfNeeded(
        for records: [HoloMemoryRecord],
        now: Date
    ) -> HoloMemoryRefreshDecision {
        let stale = records.filter {
            $0.freshnessScore < 0.35 || ($0.expiresAt.map { $0 <= now } ?? false)
        }
        let targets = Array(Set(stale.map { record -> HoloMemoryRefreshTarget in
            if record.scope == .crossDomain { return .crossDomain }
            return .domain(record.primaryDomain ?? record.sourceDomains[0])
        })).sorted { $0.stableKey < $1.stableKey }
        guard !targets.isEmpty else { return .none }
        Task { await handler(targets) }
        return .scheduled(targets)
    }

    #if !HOLO_MEMORY_STANDALONE
    static let live = HoloMemoryRefreshCoordinator { targets in
        for target in targets {
            switch target {
            case .domain(let domain):
                await HoloMemoryObservationScheduler.shared.markDirty(
                    target: .domain(domain),
                    sourceDigest: "query-swr"
                )
            case .crossDomain:
                await HoloMemoryObservationScheduler.shared.markDirty(
                    target: .crossDomain,
                    sourceDigest: "query-swr"
                )
            }
        }
    }
    #endif
}
