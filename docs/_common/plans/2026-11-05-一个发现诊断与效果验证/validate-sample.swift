import Foundation

// 只重放生成结果：不使用 verifyEval.fabricatedCandidate，不把人工拟稿冒充模型生成。
@main
struct ValidateDiscoverySample {
    struct Evidence: Decodable {
        struct Range: Decodable { let start: String? }
        let evidenceID: String
        let sourceBlock: String
        let lineageGroup: String
        let occurredRange: Range
    }

    static func main() throws {
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = try Data(contentsOf: inputURL)
        let root = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let candidates = try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(
            from: JSONSerialization.data(withJSONObject: root["candidates"]!)
        )
        let verification = try DiscoveryAIPacket.decodeValidatedVerificationEnvelope(
            from: JSONSerialization.data(withJSONObject: root["verification"]!)
        )
        let evidence = try JSONDecoder().decode([Evidence].self,
            from: JSONSerialization.data(withJSONObject: root["evidence"]!))
        precondition(candidates.runID == verification.runID)
        var checks = 2
        let candidate = candidates.candidates[0]
        let byID = Dictionary(evidence.map { ($0.evidenceID, $0) }, uniquingKeysWith: { first, _ in first })
        let result = verification.candidateResults.first { $0.candidateID == candidate.candidateID }!
        precondition(result.verdict == .accept)
        checks += 1
        let verdicts = Dictionary(result.claimResults.map { ($0.claimID, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        for claim in candidate.claims {
            precondition(verdicts[claim.claimID] == .supported)
            checks += 1
            for citation in claim.citations {
                let source = byID[citation.evidenceID]!.sourceBlock
                precondition(DiscoveryQuoteAlignment.align(quote: citation.quote, source: source) != nil)
                checks += 1
            }
        }
        // 反例：改写后的引文不能通过真实引用对齐器。
        precondition(DiscoveryQuoteAlignment.align(quote: "已完成全部作品集", source: evidence[0].sourceBlock) == nil)
        checks += 1
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let citedIDs = Set(candidate.claims.flatMap { $0.citations.map(\.evidenceID) })
        let cited = evidence.filter { citedIDs.contains($0.evidenceID) }
        let dates = cited.compactMap { $0.occurredRange.start }.compactMap { formatter.date(from: $0 + "T00:00:00+08:00") }
        let policy = DiscoveryPublicationPolicy()
        func decide(eventCount: Int) -> DiscoveryPublicationOutcome {
            policy.decide(DiscoveryPublicationInput(
                runID: candidates.runID,
                freezeDigest: "synthetic-trial-replay",
                acceptedCandidates: [AcceptedCandidate(candidate: candidate, verification: result, counterEvidenceCount: 0)],
                counterCoverage: [candidate.candidateID: .completedNoHit],
                evidence: [candidate.candidateID: DiscoveryEvidenceSummary(
                    independentEventCount: eventCount,
                    independentEventDates: dates,
                    independentDayCount: Set(dates.map { calendar.startOfDay(for: $0) }).count)],
                negativeFingerprints: [], recentSubjectFingerprints: [],
                now: formatter.date(from: "2026-11-05T00:00:00+08:00")!
            ))
        }
        // 复现真机拒因：再多引用，若都来自同一事件，也不许冒充两次独立经历。
        if case .rejectAll(let rejections) = decide(eventCount: 1) {
            precondition(rejections.contains { $0.reason == .insufficientIndependentEvents(required: 2, actual: 1) })
        } else { fatalError("单一事件被错误放行") }
        checks += 1
        guard case .publish(let payload) = decide(eventCount: Set(cited.map(\.lineageGroup)).count) else {
            fatalError("合格试评样本未通过当前发布策略")
        }
        checks += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS: \(checks) assertions; schema, verified claims, exact quotes, publication, single-event rejection; synthetic trial sample only")
    }
}
