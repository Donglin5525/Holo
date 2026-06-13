//
//  HoloObserverTriggerPolicyTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 6.4 Observer Tier2 触发策略测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/HoloObserverTriggerPolicy.swift> <本测试> \
//    -o /tmp/holo_observer_policy_test && /tmp/holo_observer_policy_test
//

import Foundation

@main
struct HoloObserverTriggerPolicyTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test高严重度触发Tier2()
        testGoalConflict触发Tier2()
        testCooldown未过不触发()
        test用户手动触发无视Cooldown()
        print("HoloObserverTriggerPolicyTests passed")
    }

    private static func makePattern(type: HoloPatternType, severity: HoloPatternSeverity) -> HoloPatternSignal {
        HoloPatternSignal(
            id: "p1", type: type, title: "t", metricKey: "k",
            value: nil, baselineValue: nil, severity: severity,
            evidenceIDs: [], reason: "r", generatedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private static func test高严重度触发Tier2() {
        let policy = HoloObserverTriggerPolicy()
        let trigger = policy.shouldTriggerTier2(
            patterns: [makePattern(type: .frequencyChange, severity: .high)],
            lastTier2RunAt: nil, now: Date(timeIntervalSince1970: 100_000), userRequested: false
        )
        expect(trigger, "high severity 应触发 Tier2")
    }

    private static func testGoalConflict触发Tier2() {
        let policy = HoloObserverTriggerPolicy()
        let trigger = policy.shouldTriggerTier2(
            patterns: [makePattern(type: .goalConflict, severity: .medium)],
            lastTier2RunAt: nil, now: Date(timeIntervalSince1970: 100_000), userRequested: false
        )
        expect(trigger, "goalConflict 应触发 Tier2")
    }

    private static func testCooldown未过不触发() {
        let policy = HoloObserverTriggerPolicy()  // cooldown 360 分钟
        let now = Date(timeIntervalSince1970: 100_000)
        let last = now.addingTimeInterval(-60 * 60)  // 1 小时前（< 360 分钟）
        let trigger = policy.shouldTriggerTier2(
            patterns: [makePattern(type: .frequencyChange, severity: .high)],
            lastTier2RunAt: last, now: now, userRequested: false
        )
        expect(!trigger, "cooldown 未过不应触发")
    }

    private static func test用户手动触发无视Cooldown() {
        let policy = HoloObserverTriggerPolicy()
        let now = Date(timeIntervalSince1970: 100_000)
        let last = now.addingTimeInterval(-60 * 60)  // cooldown 内
        let trigger = policy.shouldTriggerTier2(
            patterns: [], lastTier2RunAt: last, now: now, userRequested: true
        )
        expect(trigger, "用户手动触发应无视 cooldown")
    }
}
