import Foundation

@main
struct HoloMemoryScorerStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        let evidenceInput = HoloMemoryConfidenceInput(
            sourceReliability: 0.95,
            evidenceCoverage: 0.9,
            crossCycleConsistency: 0.9,
            independentEvidenceCount: 4,
            counterEvidenceCount: 0,
            userDecision: .none
        )
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let later = now.addingTimeInterval(365 * 86_400)
        let confidenceNow = HoloMemoryScorer.confidence(evidenceInput)
        let confidenceLater = HoloMemoryScorer.confidence(evidenceInput)
        expect(confidenceNow == confidenceLater,
               "成立置信度不能因为自然时间流逝而直接下降")

        let currentFreshness = HoloMemoryScorer.freshness(
            persistenceClass: .currentState,
            lastSupportedAt: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        let durableFreshness = HoloMemoryScorer.freshness(
            persistenceClass: .durable,
            lastSupportedAt: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        let permanentFreshness = HoloMemoryScorer.freshness(
            persistenceClass: .permanentFact,
            lastSupportedAt: now.addingTimeInterval(-365 * 86_400),
            now: now
        )
        expect(currentFreshness < durableFreshness,
               "currentState 应比 durable 更快衰减")
        expect(permanentFreshness == 1,
               "永久事实的成立新鲜度不随时间衰减")

        let weakNew = HoloMemoryScorer.recallScore(
            relevance: 1,
            freshness: 1,
            confidence: 0.25,
            contextApplicability: 1
        )
        let stableStillValid = HoloMemoryScorer.recallScore(
            relevance: 1,
            freshness: 0.75,
            confidence: 0.9,
            contextApplicability: 1
        )
        expect(stableStillValid > weakNew,
               "新鲜但证据弱的内容不能压过仍有效的高置信记忆")

        let confirmed = HoloMemoryScorer.confidence(
            HoloMemoryConfidenceInput(
                sourceReliability: 0.9,
                evidenceCoverage: 0.8,
                crossCycleConsistency: 0.8,
                independentEvidenceCount: 3,
                counterEvidenceCount: 0,
                userDecision: .confirmed
            )
        )
        let automatic = HoloMemoryScorer.confidence(
            HoloMemoryConfidenceInput(
                sourceReliability: 0.9,
                evidenceCoverage: 0.8,
                crossCycleConsistency: 0.8,
                independentEvidenceCount: 3,
                counterEvidenceCount: 0,
                userDecision: .none
            )
        )
        expect(confirmed > automatic, "用户确认必须优先于自动分数")

        let oldVersion = HoloMemoryRankedScore(
            memoryID: "memory-a",
            value: 0.8,
            scoringVersion: 1
        )
        let newVersion = HoloMemoryRankedScore(
            memoryID: "memory-b",
            value: 0.7,
            scoringVersion: 2
        )
        do {
            _ = try HoloMemoryScorer.isHigherRanked(oldVersion, than: newVersion)
            fatalError("不同 scoringVersion 的分数不允许直接比较")
        } catch HoloMemoryScoringError.incomparableVersions {
            assertionCount += 1
        }

        expect(HoloMemoryScorer.freshness(
            persistenceClass: .currentState,
            lastSupportedAt: now,
            now: later
        ) < currentFreshness,
        "新鲜度必须随时间继续下降")

        print("HoloMemoryScorerStandaloneTests passed: \(assertionCount) assertions")
    }
}
