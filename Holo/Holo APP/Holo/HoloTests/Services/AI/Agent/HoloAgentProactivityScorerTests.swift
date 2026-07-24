//
//  HoloAgentProactivityScorerTests.swift
//  HoloTests
//
//  Agent 成熟度演进 P2 — 主动评分 + Outcome Review 测试
//

import Foundation

@main
struct HoloAgentProactivityScorerTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        test高价值高置信授权_notify()
        test高价值未授权_store()
        test低价值_ignore()
        test证据不足_watch()
        test重复惩罚降级()
        test打扰成本降级()
        test未授权永不notify()
        test评分范围0到100()
        test评分明细完整()
        testOutcomeReview_改善()
        testOutcomeReview_无变化()
        testOutcomeReview_数据不足()
        testOutcomeReview_不写因果()
        testOutcomeReview_方向判定()
        testFollowUp决策()
        print("HoloAgentProactivityScorerTests passed")
    }

    // MARK: - 主动评分

    private static func test高价值高置信授权_notify() {
        let signal = HoloProactivitySignal(
            value: 0.9, confidence: 0.85, actionability: 0.8, novelty: 0.7,
            timingFitness: 0.8, interruptionCost: 0.2, repetitionPenalty: 0.1,
            userAuthorized: true
        )
        let result = HoloAgentProactivityScorer.score(signal)
        expect(result.tier == .notify, "高价值高置信授权应 notify，实际 \(result.tier) score=\(result.score)")
        expect(result.shouldNotify, "shouldNotify 应为 true")
    }

    private static func test高价值未授权_store() {
        let signal = HoloProactivitySignal(
            value: 0.9, confidence: 0.85, actionability: 0.8, novelty: 0.7,
            timingFitness: 0.8, interruptionCost: 0.2, repetitionPenalty: 0.1,
            userAuthorized: false
        )
        let result = HoloAgentProactivityScorer.score(signal)
        expect(result.tier == .store, "未授权高价值应 store（不打扰），实际 \(result.tier)")
        expect(!result.shouldNotify, "未授权不应 notify")
        expect(result.shouldStore, "应 store")
    }

    private static func test低价值_ignore() {
        let signal = HoloProactivitySignal(
            value: 0.1, confidence: 0.1, actionability: 0.1, novelty: 0.1,
            timingFitness: 0.1, interruptionCost: 0.5, repetitionPenalty: 0.5,
            userAuthorized: true
        )
        let result = HoloAgentProactivityScorer.score(signal)
        expect(result.tier == .ignore, "低价值应 ignore，实际 \(result.tier)")
    }

    private static func test证据不足_watch() {
        let signal = HoloProactivitySignal(
            value: 0.6, confidence: 0.2, actionability: 0.5, novelty: 0.5,
            timingFitness: 0.5, interruptionCost: 0.3, repetitionPenalty: 0.1,
            userAuthorized: true
        )
        let result = HoloAgentProactivityScorer.score(signal)
        // 低置信导致评分低，应在 watch 或 ignore 范围
        expect(result.score < 65, "低置信评分应低，实际 \(result.score)")
        if result.score >= 15 {
            expect(result.tier == .watch, "评分在 watch 范围应为 watch，实际 \(result.tier)")
        }
    }

    private static func test重复惩罚降级() {
        let baseSignal = HoloProactivitySignal(
            value: 0.8, confidence: 0.8, actionability: 0.7, novelty: 0.6,
            timingFitness: 0.7, interruptionCost: 0.3, repetitionPenalty: 0.1,
            userAuthorized: true
        )
        let repeatedSignal = HoloProactivitySignal(
            value: 0.8, confidence: 0.8, actionability: 0.7, novelty: 0.6,
            timingFitness: 0.7, interruptionCost: 0.3, repetitionPenalty: 0.9,
            userAuthorized: true
        )
        let baseResult = HoloAgentProactivityScorer.score(baseSignal)
        let repeatedResult = HoloAgentProactivityScorer.score(repeatedSignal)
        expect(repeatedResult.score < baseResult.score, "重复惩罚应降低评分")
    }

    private static func test打扰成本降级() {
        let lowCost = HoloProactivitySignal(
            value: 0.7, confidence: 0.7, actionability: 0.6, novelty: 0.5,
            timingFitness: 0.6, interruptionCost: 0.1, repetitionPenalty: 0.1,
            userAuthorized: true
        )
        let highCost = HoloProactivitySignal(
            value: 0.7, confidence: 0.7, actionability: 0.6, novelty: 0.5,
            timingFitness: 0.6, interruptionCost: 0.9, repetitionPenalty: 0.1,
            userAuthorized: true
        )
        let lowResult = HoloAgentProactivityScorer.score(lowCost)
        let highResult = HoloAgentProactivityScorer.score(highCost)
        expect(highResult.score < lowResult.score, "高打扰成本应降低评分")
    }

    private static func test未授权永不notify() {
        // 即使评分极高，未授权也不应 notify
        let signal = HoloProactivitySignal(
            value: 1.0, confidence: 1.0, actionability: 1.0, novelty: 1.0,
            timingFitness: 1.0, interruptionCost: 0.0, repetitionPenalty: 0.0,
            userAuthorized: false
        )
        let result = HoloAgentProactivityScorer.score(signal)
        expect(result.tier != .notify, "未授权永不 notify，实际 \(result.tier)")
    }

    private static func test评分范围0到100() {
        for _ in 0..<20 {
            let signal = HoloProactivitySignal(
                value: Double.random(in: 0...1), confidence: Double.random(in: 0...1),
                actionability: Double.random(in: 0...1), novelty: Double.random(in: 0...1),
                timingFitness: Double.random(in: 0...1), interruptionCost: Double.random(in: 0...1),
                repetitionPenalty: Double.random(in: 0...1), userAuthorized: true
            )
            let result = HoloAgentProactivityScorer.score(signal)
            expect(result.score >= 0 && result.score <= 100, "评分应在 0~100 范围，实际 \(result.score)")
        }
    }

    private static func test评分明细完整() {
        let signal = HoloProactivitySignal(
            value: 0.5, confidence: 0.5, actionability: 0.5, novelty: 0.5,
            timingFitness: 0.5, interruptionCost: 0.5, repetitionPenalty: 0.5,
            userAuthorized: true
        )
        let result = HoloAgentProactivityScorer.score(signal)
        expect(result.breakdown.positiveComponent > 0, "正向贡献应 > 0")
        expect(result.breakdown.negativeComponent > 0, "负向扣减应 > 0")
        expect(result.breakdown.valueContribution == 0.5, "value 贡献应记录")
    }

    // MARK: - Outcome Review

    private static func testOutcomeReview_改善() {
        let review = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: "c1",
            userDecision: .confirmed, targetMetricKey: "health.steps",
            actionExecuted: true, beforeValue: 5000, afterValue: 8000,
            improvementDirection: .higherIsBetter
        )
        expect(review.metricOutcome == .improved, "步数增加应判定为改善")
    }

    private static func testOutcomeReview_无变化() {
        let review = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: nil,
            userDecision: .confirmed, targetMetricKey: "health.steps",
            actionExecuted: true, beforeValue: 5000, afterValue: 5100,
            improvementDirection: .higherIsBetter
        )
        expect(review.metricOutcome == .noChange, "2% 变化应判定为无变化")
    }

    private static func testOutcomeReview_数据不足() {
        let review = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: nil,
            userDecision: .confirmed, targetMetricKey: "health.steps",
            actionExecuted: true, beforeValue: nil, afterValue: nil
        )
        expect(review.metricOutcome == .cannotDetermine, "无数据应判定为无法判断")
    }

    private static func testOutcomeReview_不写因果() {
        let review = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: nil,
            userDecision: .confirmed, targetMetricKey: "health.steps",
            actionExecuted: true, beforeValue: 5000, afterValue: 8000
        )
        let text = HoloOutcomeReviewEngine.renderOutcome(review)
        expect(!text.contains("导致了") && !text.contains("证明"), "效果回看不应写因果")
        expect(text.contains("不代表") || text.contains("不一定"), "应包含因果免责声明")
    }

    private static func testOutcomeReview_方向判定() {
        // 消费下降是改善（lowerIsBetter）
        let review = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: nil,
            userDecision: .confirmed, targetMetricKey: "finance.total",
            actionExecuted: true, beforeValue: 5000, afterValue: 3000,
            improvementDirection: .lowerIsBetter
        )
        expect(review.metricOutcome == .improved, "消费下降应判定为改善（lowerIsBetter）")
    }

    private static func testFollowUp决策() {
        let improved = HoloOutcomeReviewEngine.review(
            actionID: "a1", sourceClaimID: nil, userDecision: .confirmed,
            targetMetricKey: "health.steps", actionExecuted: true,
            beforeValue: 5000, afterValue: 8000
        )
        expect(improved.followUpDecision == .adjust, "改善+已执行应 adjust")

        let noChange = HoloOutcomeReviewEngine.review(
            actionID: "a2", sourceClaimID: nil, userDecision: .confirmed,
            targetMetricKey: "health.steps", actionExecuted: true,
            beforeValue: 5000, afterValue: 5100
        )
        expect(noChange.followUpDecision == .continueWatching, "无变化应 continueWatching")
    }
}
