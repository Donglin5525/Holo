//
//  HoloPatternMinerTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.6 Pattern Miner 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/PatternMining/HoloPatternMiner.swift> <本测试> \
//    -o /tmp/holo_pattern_miner_test && /tmp/holo_pattern_miner_test
//

import Foundation

@main
struct HoloPatternMinerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test频率变化8到20生成highFrequencyChange()
        test超限天数生成goalConflict()
        test晚间餐饮频次偏移生成timeDistributionShift()
        test无显著变化不生成highPattern()
        print("HoloPatternMinerTests passed")
    }

    private static func makeResult(metrics: [HoloMetric], eventIDs: [String]) -> HoloDataToolResult {
        let events = eventIDs.map {
            HoloEvidenceEvent(id: $0, occurredAt: nil, metricKey: "m", metricValue: nil, excerpt: "e")
        }
        return HoloDataToolResult(toolRequestID: "req", tool: "habit", status: .success,
                                  coverage: nil, metrics: metrics, events: events,
                                  warnings: [], error: nil)
    }

    /// habit.negative.frequency_change 8→12→20（change=12 increasing）⇒ .frequencyChange + .high，evidence 含 3 天。
    private static func test频率变化8到20生成highFrequencyChange() {
        let result = makeResult(
            metrics: [HoloMetric(metricKey: "habit.negative.frequency_change", value: 12, unit: "次",
                                 baselineValue: 8, comparison: "increasing")],
            eventIDs: ["e1", "e2", "e3"]
        )
        let signals = HoloPatternMiner().mine(toolResults: [result])

        let signal = signals.first { $0.type == .frequencyChange }
        expect(signal != nil, "应生成 frequencyChange 信号")
        expect(signal?.severity == .high, "变化 12 应为 high，实际 \(signal?.severity.rawValue ?? "nil")")
        expect(signal?.evidenceIDs.count == 3, "evidenceIDs 应含 3 天，实际 \(signal?.evidenceIDs.count ?? -1)")
        expect(signal?.value == 12, "value 应为 12")
    }

    /// habit.negative.over_limit_days > 0 ⇒ .goalConflict。
    private static func test超限天数生成goalConflict() {
        let result = makeResult(
            metrics: [HoloMetric(metricKey: "habit.negative.over_limit_days", value: 2, unit: "天",
                                 baselineValue: nil, comparison: nil)],
            eventIDs: ["e1"]
        )
        let signals = HoloPatternMiner().mine(toolResults: [result])

        let signal = signals.first { $0.type == .goalConflict }
        expect(signal != nil, "over_limit_days>0 应生成 goalConflict")
        expect(signal?.evidenceIDs.contains("e1") ?? false, "应携带 evidenceIDs")
    }

    /// finance.meal.nighttime_count 4 vs 1 ⇒ .timeDistributionShift。
    private static func test晚间餐饮频次偏移生成timeDistributionShift() {
        let result = makeResult(
            metrics: [HoloMetric(metricKey: "finance.meal.nighttime_count", value: 4, unit: "次",
                                 baselineValue: 1, comparison: "increasing")],
            eventIDs: ["e1"]
        )
        let signals = HoloPatternMiner().mine(toolResults: [result])

        let signal = signals.first { $0.type == .timeDistributionShift }
        expect(signal != nil, "4 vs 1 应生成 timeDistributionShift")
    }

    /// 无显著变化（stable / 变化过小）不应生成 high 级 pattern。
    private static func test无显著变化不生成highPattern() {
        let result = makeResult(
            metrics: [HoloMetric(metricKey: "habit.negative.frequency_change", value: 0, unit: "次",
                                 baselineValue: 0, comparison: "stable")],
            eventIDs: ["e1"]
        )
        let signals = HoloPatternMiner().mine(toolResults: [result])

        expect(!signals.contains { $0.severity == .high }, "无显著变化不应生成 high 级 pattern")
        expect(!signals.contains { $0.type == .frequencyChange }, "stable 不应生成 frequencyChange")
    }
}
