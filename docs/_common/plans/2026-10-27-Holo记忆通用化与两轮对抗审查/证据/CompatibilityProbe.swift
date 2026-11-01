import Foundation

@main
struct CompatibilityProbe {
    static func main() throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow
        var record = HoloMemoryFiveWayFixtures.all.first { $0.scenarioID == "MTX-03" }!.record
        record.state = .active
        record.personalContext = nil
        record.decisionMetadata = nil
        record.lastSupportedAt = now
        record.freshnessScore = 1
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var raw = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        raw["knowledgeGate"] = ["requiresConfirmation": true, "semanticDigest": "future-revision"]
        let read = try decoder.decode(HoloMemoryRecord.self, from: JSONSerialization.data(withJSONObject: raw))
        let written = try JSONSerialization.jsonObject(with: encoder.encode(read)) as! [String: Any]
        print("P01 future top-level field lost on current-model round-trip:", written["knowledgeGate"] == nil)

        record.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(unknownVersion: 99, rawJSON: "{\"schemaVersion\":99,\"useLevel\":\"blocked\"}")
        print("P02 unreadable decision envelope active recall allowed:", HoloMemoryRecallPolicy.isEligible(record, now: now))
        record.state = .candidate
        let projection = HoloMemoryManagementProjection.project(.init(record: record), context: .init(now: now))
        print("P03 candidate with unknown decision offers confirm:", projection.allowedActions.contains(.confirm))

        raw = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        raw["claimKind"] = "futureKnowledgeKind"
        do {
            _ = try decoder.decode([HoloMemoryRecord].self, from: JSONSerialization.data(withJSONObject: [raw]))
            print("P04 unknown outer claim kind fails whole-array decode: false")
        } catch {
            print("P04 unknown outer claim kind fails whole-array decode: true")
        }
        record.decisionMetadata = nil
        record.state = .active
        record.schemaVersion = 99
        do { try record.validate(); print("P05 unknown positive record schema passes validation: true") }
        catch { print("P05 unknown positive record schema passes validation: false") }
        record.schemaVersion = 1
        record.expiresAt = now.addingTimeInterval(-1)
        print("P06 expired record allowed by direct-reader eligibility:", HoloMemoryAnswerEligibility.isEligible(record))
        print("P06 expired record allowed by recall policy:", HoloMemoryRecallPolicy.isEligible(record, now: now))
    }
}
