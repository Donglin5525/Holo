//
//  HoloMemoryQualityMetrics.swift
//  Holo
//
//  只记录聚合数字的本地质量指标；不接收也不保存记忆正文。
//

import Foundation

nonisolated struct HoloMemoryQualitySnapshot: Codable, Equatable, Sendable {
    var queryCount: Int
    var queryHitCount: Int
    var queryLatencyMilliseconds: [Double]
    var generatedCount: Int
    var validatorRejectedCount: Int
    var feedbackCount: Int
    var correctedCount: Int
    var rejectedByUserCount: Int
    var maximumSerialNetworkRoundTripsOnChatPath: Int
    var maximumConcurrentMemoryAIJobs: Int
    /// 五路决策分布（route 原始值 → 次数），仅聚合数字（低确认成本方案 §15.3）。
    var decisionRouteCounts: [String: Int]
    /// shadow 对照：v3 与 v4 结论一致的次数 / 不一致的 v3→v4 迁移对计数。
    var shadowAgreeCount: Int
    var shadowDisagreeCounts: [String: Int]

    static let empty = HoloMemoryQualitySnapshot(
        queryCount: 0,
        queryHitCount: 0,
        queryLatencyMilliseconds: [],
        generatedCount: 0,
        validatorRejectedCount: 0,
        feedbackCount: 0,
        correctedCount: 0,
        rejectedByUserCount: 0,
        maximumSerialNetworkRoundTripsOnChatPath: 0,
        maximumConcurrentMemoryAIJobs: 0,
        decisionRouteCounts: [:],
        shadowAgreeCount: 0,
        shadowDisagreeCounts: [:]
    )

    var queryHitRate: Double {
        queryCount == 0 ? 0 : Double(queryHitCount) / Double(queryCount)
    }

    var validatorRejectionRate: Double {
        generatedCount == 0 ? 0 : Double(validatorRejectedCount) / Double(generatedCount)
    }

    var correctionRate: Double {
        feedbackCount == 0 ? 0 : Double(correctedCount) / Double(feedbackCount)
    }

    var userRejectionRate: Double {
        feedbackCount == 0 ? 0 : Double(rejectedByUserCount) / Double(feedbackCount)
    }

    var queryLatencyP95Milliseconds: Double {
        guard !queryLatencyMilliseconds.isEmpty else { return 0 }
        let sorted = queryLatencyMilliseconds.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    var meetsQueryLatencySLO: Bool { queryLatencyP95Milliseconds <= 100 }
    var keepsChatPathNetworkFree: Bool { maximumSerialNetworkRoundTripsOnChatPath == 0 }
    var keepsSingleMemoryAIJob: Bool { maximumConcurrentMemoryAIJobs <= 1 }
}

actor HoloMemoryQualityMetrics {
    static let shared = HoloMemoryQualityMetrics()

    private let maximumLatencySamples: Int
    private var state: HoloMemoryQualitySnapshot

    init(
        maximumLatencySamples: Int = 1_000,
        initial: HoloMemoryQualitySnapshot = .empty
    ) {
        self.maximumLatencySamples = max(1, maximumLatencySamples)
        state = initial
    }

    func recordQuery(durationMilliseconds: Double, selectedCount: Int) {
        state.queryCount += 1
        if selectedCount > 0 { state.queryHitCount += 1 }
        state.queryLatencyMilliseconds.append(max(0, durationMilliseconds))
        if state.queryLatencyMilliseconds.count > maximumLatencySamples {
            state.queryLatencyMilliseconds.removeFirst(
                state.queryLatencyMilliseconds.count - maximumLatencySamples
            )
        }
    }

    func recordValidation(generated: Int, rejected: Int) {
        state.generatedCount += max(0, generated)
        state.validatorRejectedCount += max(0, min(rejected, generated))
    }

    func recordFeedback(corrected: Bool, rejected: Bool) {
        state.feedbackCount += 1
        if corrected { state.correctedCount += 1 }
        if rejected { state.rejectedByUserCount += 1 }
    }

    func recordChatPath(serialNetworkRoundTrips: Int) {
        state.maximumSerialNetworkRoundTripsOnChatPath = max(
            state.maximumSerialNetworkRoundTripsOnChatPath,
            max(0, serialNetworkRoundTrips)
        )
    }

    func recordConcurrentMemoryAIJobs(_ count: Int) {
        state.maximumConcurrentMemoryAIJobs = max(
            state.maximumConcurrentMemoryAIJobs,
            max(0, count)
        )
    }

    func recordDecision(route: String) {
        state.decisionRouteCounts[route, default: 0] += 1
    }

    func recordShadowDecision(legacyRoute: String, v4Route: HoloMemoryFiveWayRoute, agrees: Bool) {
        if agrees {
            state.shadowAgreeCount += 1
        } else {
            let key = "\(legacyRoute)->\(routeName(v4Route))"
            state.shadowDisagreeCounts[key, default: 0] += 1
        }
    }

    private func routeName(_ route: HoloMemoryFiveWayRoute) -> String {
        switch route {
        case .factEligible: return "fact"
        case .qualifiedAdvice: return "qualified"
        case .observeOnly: return "observe"
        case .askWhenRelevant: return "ask"
        case .discard: return "discard"
        }
    }

    func snapshot() -> HoloMemoryQualitySnapshot { state }

    func reset() { state = .empty }
}
