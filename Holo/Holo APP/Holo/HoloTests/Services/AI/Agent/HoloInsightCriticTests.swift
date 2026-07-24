//
//  HoloInsightCriticTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 4.2 Insight Critic 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Verification/HoloInsightCritic.swift> <本测试> \
//    -o /tmp/holo_insight_critic_test && /tmp/holo_insight_critic_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloInsightCriticTests.main()
    }
}
#endif
struct HoloInsightCriticTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test空话词被过滤()
        test无Evidence被过滤()
        test实质Claim被保留()
        test多Claim混合过滤()
        print("HoloInsightCriticTests passed")
    }

    private static func makeClaim(text: String, evidenceIDs: [String]) -> HoloAgentClaim {
        HoloAgentClaim(
            id: "c-\(text.hashValue)", type: "observation", displayText: text,
            metricAssertions: evidenceIDs.isEmpty
                ? []
                : [HoloMetricAssertion(metricKey: "k", value: 1, baselineValue: nil,
                                       unit: "次", comparison: nil, evidenceIDs: evidenceIDs)],
            evidenceIDs: evidenceIDs, prohibitedInferences: [], confidence: 0.9
        )
    }

    private static func test空话词被过滤() {
        let claim = makeClaim(text: "继续保持好习惯", evidenceIDs: ["e1"])
        let kept = HoloInsightCritic().filter([claim], patterns: [])
        expect(kept.isEmpty, "空话词「继续保持」应被过滤")
    }

    private static func test无Evidence被过滤() {
        let claim = makeClaim(text: "本周任务数量是 5 个", evidenceIDs: [])
        let kept = HoloInsightCritic().filter([claim], patterns: [])
        expect(kept.isEmpty, "无 evidence 的 claim 应被过滤")
    }

    private static func test实质Claim被保留() {
        let claim = makeClaim(text: "负向习惯发生量连续上升", evidenceIDs: ["e1"])
        let kept = HoloInsightCritic().filter([claim], patterns: [])
        expect(kept.count == 1, "有 evidence 的实质 claim 应保留")
    }

    private static func test多Claim混合过滤() {
        let claims = [
            makeClaim(text: "节奏不错继续保持", evidenceIDs: ["e1"]),   // 空话 → 过滤
            makeClaim(text: "晚间餐饮次数明显增加", evidenceIDs: ["e2"]), // 实质 → 保留
            makeClaim(text: "统计完成", evidenceIDs: [])                 // 无证据 → 过滤
        ]
        let kept = HoloInsightCritic().filter(claims, patterns: [])
        expect(kept.count == 1, "应只保留 1 条实质 claim，实际 \(kept.count)")
        expect(kept.first?.displayText.contains("晚间餐饮") ?? false, "应保留晚间餐饮 claim")
    }
}
