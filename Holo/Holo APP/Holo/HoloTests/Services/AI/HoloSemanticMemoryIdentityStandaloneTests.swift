import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloSemanticMemoryIdentityStandaloneTests.main()
    }
}
#endif
struct HoloSemanticMemoryIdentityStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        let subjectKey = HoloSemanticMemoryIdentity.normalizeSubjectKey("  Habit:Running  ")
        expect(subjectKey == "habit:running", "subjectKey 应稳定归一化")

        let firstID = HoloSemanticMemoryIdentity.makeID(
            semanticType: .stablePattern,
            domain: "habit",
            subjectKey: subjectKey!
        )
        let secondID = HoloSemanticMemoryIdentity.makeID(
            semanticType: .stablePattern,
            domain: "habit",
            subjectKey: "habit:running"
        )
        let differentID = HoloSemanticMemoryIdentity.makeID(
            semanticType: .stablePattern,
            domain: "habit",
            subjectKey: "habit:reading"
        )
        expect(firstID == secondID, "同一主题跨报告必须得到同一记忆 ID")
        expect(firstID != differentID, "不同主题不能碰撞为同一记忆 ID")

        let firstEvidence = HoloLongTermMemoryEvidence(
            id: "report-a-e1",
            source: .memoryInsight,
            sourceID: "habit-record-1",
            excerpt: "周一完成跑步",
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicateEvidence = HoloLongTermMemoryEvidence(
            id: "report-b-e1",
            source: .memoryInsight,
            sourceID: "habit-record-1",
            excerpt: "同一条记录的不同描述",
            observedAt: Date(timeIntervalSince1970: 200)
        )
        let newEvidence = HoloLongTermMemoryEvidence(
            id: "report-b-e2",
            source: .memoryInsight,
            sourceID: "habit-record-2",
            excerpt: "周三完成跑步",
            observedAt: Date(timeIntervalSince1970: 300)
        )
        let merged = HoloLongTermMemoryEvidenceMerger.merge(
            [firstEvidence],
            [duplicateEvidence, newEvidence]
        )
        expect(merged.count == 2, "重复证据应去重，新证据应累积")
        print("HoloSemanticMemoryIdentity standalone tests passed")
    }
}
