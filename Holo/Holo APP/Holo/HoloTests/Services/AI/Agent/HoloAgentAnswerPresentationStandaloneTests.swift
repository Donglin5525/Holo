//
//  HoloAgentAnswerPresentationStandaloneTests.swift
//  HoloTests
//
//  独立验证 Agent 用户答案模型，不依赖会触发 CloudKit 的 App 测试宿主。
//

import Foundation

@main
struct HoloAgentAnswerPresentationStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        test步数问题生成用户可读答案()
        try test旧结果JSON保持兼容()
        print("HoloAgentAnswerPresentationStandaloneTests passed")
    }

    private static func test步数问题生成用户可读答案() {
        let range = HoloAgentTimeRange(
            label: "最近一个月",
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let assertions = [
            HoloMetricAssertion(
                metricKey: "health.steps.average",
                value: 6990.8,
                baselineValue: nil,
                unit: "步",
                comparison: nil,
                evidenceIDs: ["steps-average"]
            ),
            HoloMetricAssertion(
                metricKey: "health.steps.goal_met_days",
                value: 1,
                baselineValue: nil,
                unit: "天",
                comparison: nil,
                evidenceIDs: ["steps-goal"]
            )
        ]
        let claim = HoloAgentClaim(
            id: "steps",
            type: "observation",
            displayText: "步数汇总：health.steps.average = 6990.80 步；步数汇总：health.steps.goal_met_days = 1.00 天",
            metricAssertions: assertions,
            evidenceIDs: ["steps-average", "steps-goal"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let evidence = [
            makeEvidence(
                id: "steps-average",
                metricKey: "health.steps.average",
                metricValue: 6990.8,
                unit: "步",
                excerpt: "步数汇总：health.steps.average = 6990.80 步",
                range: range
            ),
            makeEvidence(
                id: "steps-goal",
                metricKey: "health.steps.goal_met_days",
                metricValue: 1,
                unit: "天",
                excerpt: "步数汇总：health.steps.goal_met_days = 1.00 天",
                range: range
            )
        ]

        let result = HoloAgentResultRenderer().render(
            claims: [claim],
            evidence: evidence,
            title: "深度分析",
            question: "最近一个月平均步数是多少？",
            coverage: HoloDataCoverage(
                coveredDays: 28,
                totalDays: 30,
                coverageRatio: 28.0 / 30.0,
                missingRanges: [],
                note: "已读取 28/30 天健康数据"
            )
        )

        expect(result.headline == "最近一个月的步数", "标题必须严格跟随步数主题")
        expect(result.directAnswer == "最近一个月，日均 6,991 步", "首屏必须直接回答平均步数")
        expect(result.coverageText?.contains("28/30 天") == true, "必须展示有效数据覆盖")
        expect(result.sections.map(\.title) == ["达标情况"], "辅助结论必须使用语义标题")
        expect(result.sections.first?.body == "达到 10,000 步 1 天", "达标天数必须解释达标口径")

        let visibleText = [result.title, result.summary]
            + [result.headline, result.directAnswer, result.coverageText].compactMap { $0 }
            + result.sections.flatMap { [$0.title, $0.body] }
            + result.evidenceReferences.map(\.summary)
        let flattened = visibleText.joined(separator: " ")
        expect(!flattened.contains("睡眠"), "步数问题不能混入睡眠主题")
        expect(!flattened.contains("观察 01"), "用户界面不能出现无语义编号")
        expect(!flattened.contains("health."), "用户界面不能暴露内部 metric key")
        expect(!flattened.contains("goal_met_days"), "用户界面不能暴露内部字段")
        expect(!flattened.contains("average ="), "用户界面不能暴露机器表达式")
    }

    private static func test旧结果JSON保持兼容() throws {
        let json = #"{"title":"旧","summary":"s","sections":[],"evidenceReferences":[]}"#
        let data = try unwrap(json.data(using: .utf8), "旧 JSON 编码失败")
        let result = try JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
        expect(result.question == nil, "旧结果缺少 question 时必须解码为 nil")
        expect(result.headline == nil, "旧结果缺少 headline 时必须解码为 nil")
        expect(result.directAnswer == nil, "旧结果缺少 directAnswer 时必须解码为 nil")
    }

    private static func makeEvidence(
        id: String,
        metricKey: String,
        metricValue: Double,
        unit: String,
        excerpt: String,
        range: HoloAgentTimeRange
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: .health,
            sourceID: nil,
            sourceKind: "steps_summary",
            timeRange: range,
            occurredAt: range.end,
            metricKey: metricKey,
            metricValue: metricValue,
            unit: unit,
            baselineValue: nil,
            baselineTimeRange: nil,
            comparison: nil,
            excerpt: excerpt,
            redactedExcerpt: excerpt,
            sensitivity: .sensitive,
            confidence: 0.9,
            status: .active,
            generatedBy: "test",
            generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [],
            referencedByMemoryIDs: [],
            deviceID: nil
        )
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "HoloAgentAnswerPresentationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }
}
