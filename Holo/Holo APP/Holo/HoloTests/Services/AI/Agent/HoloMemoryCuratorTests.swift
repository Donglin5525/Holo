//
//  HoloMemoryCuratorTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 4.3 Memory Curator 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/HoloMemoryCurator.swift> <本测试> \
//    -o /tmp/holo_memory_curator_test && /tmp/holo_memory_curator_test
//

import Foundation

@main
struct HoloMemoryCuratorTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        testGoalConflict高严重度路由episodicMemory()
        test低价值任务统计路由responseOnly()
        testSuppression命中不生成()
        test频率变化高严重度路由episodicMemory()
        print("HoloMemoryCuratorTests passed")
    }

    private static func makeClaim(id: String, text: String, evidenceIDs: [String]) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id, type: "observation", displayText: text,
            metricAssertions: evidenceIDs.isEmpty
                ? []
                : [HoloMetricAssertion(metricKey: "k", value: 1, baselineValue: nil,
                                       unit: "次", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [], confidence: 0.9
        )
    }

    private static func makePattern(type: HoloPatternType, severity: HoloPatternSeverity) -> HoloPatternSignal {
        HoloPatternSignal(
            id: "p1", type: type, title: "t", metricKey: "k",
            value: nil, baselineValue: nil, severity: severity,
            evidenceIDs: [], reason: "r", generatedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private static func testGoalConflict高严重度路由episodicMemory() {
        let claim = makeClaim(id: "c1", text: "负向习惯连续超出目标", evidenceIDs: ["e1"])
        let curated = HoloMemoryCurator().curate(
            claims: [claim], patterns: [makePattern(type: .goalConflict, severity: .high)]
        )
        expect(curated.count == 1, "应生成 1 条记忆候选")
        expect(curated.first?.route == .episodicMemory, "goalConflict+high 应路由 episodicMemory，实际 \(curated.first?.route.rawValue ?? "nil")")
    }

    private static func test低价值任务统计路由responseOnly() {
        let claim = makeClaim(id: "c2", text: "本周任务数量是 5 个", evidenceIDs: ["e2"])
        let curated = HoloMemoryCurator().curate(claims: [claim], patterns: [])
        expect(curated.count == 1, "应生成 1 条")
        expect(curated.first?.route == .responseOnly, "低价值应路由 responseOnly，实际 \(curated.first?.route.rawValue ?? "nil")")
    }

    private static func testSuppression命中不生成() {
        let claim = makeClaim(id: "c3", text: "记得多喝热水", evidenceIDs: ["e3"])
        let curated = HoloMemoryCurator().curate(
            claims: [claim], patterns: [], suppressionKeywords: ["多喝热水"]
        )
        expect(curated.isEmpty, "suppression 命中不应生成记忆候选")
    }

    private static func test频率变化高严重度路由episodicMemory() {
        let claim = makeClaim(id: "c4", text: "负向习惯发生量上升", evidenceIDs: ["e4"])
        let curated = HoloMemoryCurator().curate(
            claims: [claim], patterns: [makePattern(type: .frequencyChange, severity: .high)]
        )
        expect(curated.first?.route == .episodicMemory, "frequencyChange+high 应路由 episodicMemory")
    }
}
