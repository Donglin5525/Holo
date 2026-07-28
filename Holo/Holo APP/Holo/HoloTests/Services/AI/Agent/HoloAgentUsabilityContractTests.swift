//
//  HoloAgentUsabilityContractTests.swift
//  HoloTests
//
//  Holo Agent 用户可用性契约：覆盖全部主业务域，确保“分析/优化”不是财务特判。
//

import Foundation

@main
private struct HoloAgentUsabilityContractTests {

    private struct Case {
        var question: String
        var expectedDomains: Set<String>
        var expectsRecommendations: Bool
        var expectsExplicitYear: Bool
    }

    static func main() {
        let cases = [
            Case(
                question: "分析我2026年的财务数据，有哪些需要优化的地方？",
                expectedDomains: ["finance"],
                expectsRecommendations: true,
                expectsExplicitYear: true
            ),
            Case(
                question: "最近一个月睡眠表现怎么样，哪些地方需要改善？",
                expectedDomains: ["health"],
                expectsRecommendations: true,
                expectsExplicitYear: false
            ),
            Case(
                question: "分析我2026年的习惯执行，应该优先优化什么？",
                expectedDomains: ["habit"],
                expectsRecommendations: true,
                expectsExplicitYear: true
            ),
            Case(
                question: "今年的任务完成情况有哪些问题，下一步怎么调整？",
                expectedDomains: ["task"],
                expectsRecommendations: true,
                expectsExplicitYear: false
            ),
            Case(
                question: "分析目标进度，有哪些风险和改进建议？",
                expectedDomains: ["goal"],
                expectsRecommendations: true,
                expectsExplicitYear: false
            ),
            Case(
                question: "分析最近的想法记录，哪些主题值得继续深化？",
                expectedDomains: ["thought"],
                expectsRecommendations: true,
                expectsExplicitYear: false
            ),
            Case(
                question: "分析我2026年的睡眠和消费数据，有哪些需要优化的地方？",
                expectedDomains: ["health", "finance"],
                expectsRecommendations: true,
                expectsExplicitYear: true
            )
        ]

        for item in cases {
            let frame = HoloAgentSemanticFrameBuilder.buildFrame(
                query: item.question,
                referenceDate: referenceDate,
                calendar: calendar
            )
            expect(
                Set(frame.domains) == item.expectedDomains,
                "\(item.question) 域识别错误：\(frame.domains)"
            )
            expect(
                frame.requestedDeliverables.contains(.diagnosis),
                "\(item.question) 必须识别为诊断/分析任务"
            )
            expect(
                frame.requestedDeliverables.contains(.recommendations) == item.expectsRecommendations,
                "\(item.question) 的建议交付物识别错误"
            )
            if item.expectsExplicitYear {
                expect(
                    frame.resolvedTime?.scope.timeRange.label == "2026年",
                    "\(item.question) 必须锁定 2026 全年"
                )
            }

            let observationOnly = [
                HoloAgentClaim(
                    id: "observation",
                    type: "observation",
                    displayText: "已完成数据分析",
                    metricAssertions: [],
                    evidenceIDs: [],
                    prohibitedInferences: [],
                    confidence: 0.8
                )
            ]
            let missing = HoloAgentAnswerRequestPolicy.missingDeliverables(
                in: observationOnly,
                question: item.question
            )
            expect(
                missing.contains(.recommendations) == item.expectsRecommendations,
                "\(item.question) 的答案完成度门禁错误"
            )
        }

        let groundedAssertion = HoloMetricAssertion(
            metricKey: "finance.category.dining.amount",
            value: 25_800,
            baselineValue: 18_000,
            unit: "元",
            comparison: "increase",
            evidenceIDs: ["finance-dining"]
        )
        let inventedTarget = HoloAgentClaim(
            id: "invented-target",
            type: "suggestion",
            displayText: "建议把娱乐预算控制在每月1500元以内，预计节省600-1200元",
            metricAssertions: [groundedAssertion],
            evidenceIDs: ["finance-dining"],
            prohibitedInferences: [],
            confidence: 0.8
        )
        expect(
            HoloAgentAnswerRequestPolicy.missingDeliverables(
                in: [inventedTarget],
                question: "分析我2026年的财务数据，有哪些需要优化的地方？"
            ).contains(.recommendations),
            "无证据预算/节省金额不能算完成建议交付"
        )

        let groundedSuggestion = HoloAgentClaim(
            id: "grounded-suggestion",
            type: "suggestion",
            displayText: "优先检查餐饮支出，它比对比期增加约43%",
            metricAssertions: [groundedAssertion],
            evidenceIDs: ["finance-dining"],
            prohibitedInferences: [],
            confidence: 0.8
        )
        expect(
            !HoloAgentAnswerRequestPolicy.missingDeliverables(
                in: [groundedSuggestion],
                question: "有哪些需要优化的地方？"
            ).contains(.recommendations),
            "可由 assertion 复算的建议数字应保留"
        )

        let stepGoalClaim = HoloAgentClaim(
            id: "step-goal-definition",
            type: "observation",
            displayText: "达到 10,000 步 1 天",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "health.steps.goal_met_days",
                    value: 1,
                    baselineValue: nil,
                    unit: "天",
                    comparison: nil,
                    evidenceIDs: ["health-step-goal"]
                )
            ],
            evidenceIDs: ["health-step-goal"],
            prohibitedInferences: [],
            confidence: 1
        )
        expect(
            HoloAgentClaimTextGroundingPolicy.unsupportedNumbers(in: stepGoalClaim).isEmpty,
            "由 metricKey 定义的 10,000 步达标阈值不应被误判为模型编造"
        )

        print("HoloAgentUsabilityContractTests passed: \(cases.count) domains/cross-domain cases")
    }

    private static let referenceDate: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 12))!
    }()

    private static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "zh_CN")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
