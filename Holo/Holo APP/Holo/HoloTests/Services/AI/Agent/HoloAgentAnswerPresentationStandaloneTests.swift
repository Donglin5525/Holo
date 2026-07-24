//
//  HoloAgentAnswerPresentationStandaloneTests.swift
//  HoloTests
//
//  独立验证 Agent 用户答案模型，不依赖会触发 CloudKit 的 App 测试宿主。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloAgentAnswerPresentationStandaloneTests.main()
    }
}
#endif
struct HoloAgentAnswerPresentationStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        test步数问题生成用户可读答案()
        test消费环比回答保留分类和方向()
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

    private static func test消费环比回答保留分类和方向() {
        let range = HoloAgentTimeRange(
            label: "本月",
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let baselineRange = HoloAgentTimeRange(
            label: "上月",
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000)
        )
        let categories: [(String, Double, String)] = [
            ("餐饮", 0.243, "food-growth"),
            ("购物", 0.112, "shopping-growth"),
            ("交通", 0.075, "transport-growth"),
            ("居住", -0.034, "housing-growth")
        ]
        let assertions = categories.map { category, value, evidenceID in
            HoloMetricAssertion(
                metricKey: "dynamic.finance_transactions.category_growth.\(category)",
                value: value,
                baselineValue: nil,
                unit: "比例",
                comparison: nil,
                evidenceIDs: [evidenceID]
            )
        }
        let claim = HoloAgentClaim(
            id: "finance-comparison",
            type: "change",
            displayText: "计算结果 24.3比例；计算结果 11.2比例；计算结果 7.5比例；计算结果 3.4比例",
            metricAssertions: assertions,
            evidenceIDs: categories.map { $0.2 },
            prohibitedInferences: [],
            confidence: 0.9
        )
        let evidence = categories.map { category, value, evidenceID in
            makeEvidence(
                id: evidenceID,
                metricKey: "dynamic.finance_transactions.category_growth.\(category)",
                metricValue: value,
                unit: "比例",
                excerpt: "动态计算 category_growth（\(category)）：\(value)",
                range: range,
                baselineRange: baselineRange,
                comparison: category,
                sourceModule: .finance
            )
        }

        let result = HoloAgentResultRenderer().render(
            claims: [claim],
            evidence: evidence,
            title: "深度分析",
            question: "这个月消费比上个月多在哪儿？",
            coverage: HoloDataCoverage(
                coveredDays: 24,
                totalDays: 31,
                coverageRatio: 24.0 / 31.0,
                missingRanges: [],
                note: "已读取 24/31 天账单"
            )
        )

        expect(result.headline == "本月的支出去向", "标题应保持财务去向语义")
        expect(
            result.directAnswer == "本月消费比上月主要多在餐饮（+24.3%）、购物（+11.2%）、交通（+7.5%）",
            "首句必须保留分类、对比方向和百分比"
        )
        let visibleText = ([result.directAnswer, result.coverageText].compactMap { $0 }
            + result.sections.flatMap { [$0.title, $0.body] }
            + result.evidenceReferences.map(\.summary))
            .joined(separator: " ")
        expect(!visibleText.contains("计算结果"), "用户界面不能出现计算占位词")
        expect(!visibleText.contains("category_growth"), "用户界面不能暴露动态指标名")
        expect(visibleText.contains("餐饮"), "分类名必须从已核对证据补回")
        expect(!result.directAnswer!.contains("居住"), "“多在哪”不能混入支出下降分类")
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
        range: HoloAgentTimeRange,
        baselineRange: HoloAgentTimeRange? = nil,
        comparison: String? = nil,
        sourceModule: HoloEvidenceSourceModule = .health
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: sourceModule,
            sourceID: nil,
            sourceKind: "steps_summary",
            timeRange: range,
            occurredAt: range.end,
            metricKey: metricKey,
            metricValue: metricValue,
            unit: unit,
            baselineValue: nil,
            baselineTimeRange: baselineRange,
            comparison: comparison,
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
