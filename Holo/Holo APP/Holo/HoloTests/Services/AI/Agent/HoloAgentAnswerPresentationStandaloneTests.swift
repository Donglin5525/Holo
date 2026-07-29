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
        if CommandLine.arguments.contains("--context-source-only") {
            try test档案与分层记忆来源随结果持久化()
            print("HoloAgentAnswerPresentationStandaloneTests context source passed")
            return
        }
        test步数问题生成用户可读答案()
        test消费环比新路径由合成器产出()
        test消费环比旧证据走catalog兜底()
        test优化问题建议优先展示()
        test年度财务事故统一上下文()
        try test档案与分层记忆来源随结果持久化()
        try test旧结果JSON保持兼容()
        print("HoloAgentAnswerPresentationStandaloneTests passed")
    }

    private static func test档案与分层记忆来源随结果持久化() throws {
        let result = HoloAgentResultRenderer().render(
            claims: [],
            evidence: [],
            contextSources: [
                HoloAgentContextSourceSummary(kind: .profile, itemCount: 4),
                HoloAgentContextSourceSummary(kind: .currentStateMemory, itemCount: 2),
                HoloAgentContextSourceSummary(kind: .durableMemory, itemCount: 1)
            ]
        )
        expect(
            result.contextSourceText == "个人档案 · 近期观察 2 条 · 长期规律 1 条",
            "结果应以用户可理解的层级展示本轮实际读取来源"
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(HoloRenderedAgentResult.self, from: encoded)
        expect(decoded.contextSources == result.contextSources, "来源披露应随 Agent 结果持久化")
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
                note: "已读取 28/30 天健康数据",
                semantics: .dailyObservations
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

    /// P3 新路径：证据带类型化语义，直接结论由确定性合成器产出（财务特判已删除）。
    /// 数据与旧用例一致：餐饮 +620 / 交通 +386 / 购物 +242 / 居住 -34 / 总 +1208。
    private static func test消费环比新路径由合成器产出() {
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
        let groups: [(String?, Double, Double, String)] = [
            (nil, 5_248, 4_040, "all-delta"),
            ("餐饮", 1_120, 500, "food-delta"),
            ("交通", 886, 500, "transit-delta"),
            ("购物", 342, 100, "shopping-delta"),
            ("居住", 116, 150, "housing-delta")
        ]
        let assertions = groups.compactMap { label, current, baseline, evidenceID -> HoloMetricAssertion? in
            guard let label else { return nil }
            return HoloMetricAssertion(
                metricKey: "dynamic.finance_transactions.spend_delta.\(label)",
                value: current - baseline,
                baselineValue: baseline,
                unit: "元",
                comparison: label,
                evidenceIDs: [evidenceID]
            )
        }
        let claim = HoloAgentClaim(
            id: "finance-comparison",
            type: "change",
            displayText: "计算结果 24.3比例；计算结果 11.2比例；计算结果 7.5比例；计算结果 3.4比例",
            metricAssertions: assertions,
            evidenceIDs: groups.map { $0.3 },
            prohibitedInferences: [],
            confidence: 0.9
        )
        let evidence = groups.map { label, current, baseline, evidenceID in
            makeEvidence(
                id: evidenceID,
                metricKey: "dynamic.finance_transactions.spend_delta.\(label ?? "all")",
                metricValue: current - baseline,
                unit: "元",
                excerpt: "动态计算 spend_delta（\(label ?? "全部")）",
                range: range,
                baselineRange: baselineRange,
                comparison: label,
                sourceModule: .finance,
                semantic: HoloMetricSemantic(
                    domain: .finance,
                    dataset: "finance.transactions",
                    measure: .amount,
                    operation: .difference,
                    valueRole: .delta,
                    dimension: .category,
                    groupLabel: label,
                    direction: current > baseline ? .increase : .decrease,
                    currentValue: current,
                    baselineValue: baseline,
                    resultValue: current - baseline,
                    displayUnit: "元"
                )
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

        expect(result.headline == "本月的支出去向", "标题应保持财务去向语义，实际：\(result.headline ?? "nil")")
        expect(
            result.directAnswer == "本月支出比上月增加 1,208 元，主要来自餐饮（+620 元）、交通（+386 元）和购物（+242 元）。餐饮贡献了总增量的 51.3%。其中居住减少 34 元，抵消了部分增量。",
            "首句必须由合成器产出总量+前三项+贡献占比，实际：\(result.directAnswer ?? "nil")"
        )
        expect(result.directAnswer!.contains("其中居住减少 34 元，抵消了部分增量"), "总增组减必须披露抵消项")
        let visibleText = ([result.directAnswer, result.coverageText].compactMap { $0 }
            + result.sections.flatMap { [$0.title, $0.body] }
            + result.evidenceReferences.map(\.summary))
            .joined(separator: " ")
        expect(!visibleText.contains("计算结果"), "用户界面不能出现计算占位词")
        expect(!visibleText.contains("spend_delta"), "用户界面不能暴露动态指标名")
        expect(visibleText.contains("餐饮"), "分类名必须来自已核对证据语义")
        expect(!result.directAnswer!.contains("居住（+"), "“多在哪”排名项不能混入支出下降分类")
    }

    /// P3 兼容路径：旧证据（无 semantic）走 HoloMetricSemanticCatalog 兜底，不崩、无内部 token。
    /// 对照同一数据的新路径输出：旧路径只能给出首类增幅单句，新路径给出完整对比结论。
    private static func test消费环比旧证据走catalog兜底() {
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
            ("交通", 0.075, "transport-growth")
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
            id: "finance-comparison-legacy",
            type: "change",
            displayText: "计算结果 24.3比例；计算结果 11.2比例；计算结果 7.5比例",
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

        // 财务特判已删除：旧证据由 catalog 的 dynamicSentence 兜底成首类增幅句
        expect(
            result.directAnswer == "本月，餐饮支出相比上期增加 24.3%",
            "旧证据应走 catalog 兜底句，实际：\(result.directAnswer ?? "nil")"
        )
        let visibleText = ([result.title, result.summary]
            + [result.headline, result.directAnswer, result.coverageText].compactMap { $0 }
            + result.sections.flatMap { [$0.title, $0.body] }
            + result.evidenceReferences.map(\.summary))
            .joined(separator: " ")
        expect(!visibleText.contains("计算结果"), "兜底路径也不能出现计算占位词")
        expect(!visibleText.contains("category_growth"), "兜底路径也不能暴露动态指标名")
        expect(visibleText.contains("餐饮"), "兜底路径分类名必须保留")
    }

    private static func test优化问题建议优先展示() {
        let range = HoloAgentTimeRange(
            label: "2026年（截至7月26日）",
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let observation = HoloAgentClaim(
            id: "observation",
            type: "observation",
            displayText: "2026年截至当前总支出14598.83元",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.total.amount",
                    value: 14598.83,
                    baselineValue: nil,
                    unit: "元",
                    comparison: nil,
                    evidenceIDs: ["total"]
                )
            ],
            evidenceIDs: ["total"],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let suggestion = HoloAgentClaim(
            id: "suggestion",
            type: "suggestion",
            displayText: "优先复核餐饮支出，并为下个月设置可执行的餐饮上限",
            metricAssertions: [
                HoloMetricAssertion(
                    metricKey: "finance.category.amount",
                    value: 3516,
                    baselineValue: nil,
                    unit: "元",
                    comparison: "餐饮",
                    evidenceIDs: ["meal"]
                )
            ],
            evidenceIDs: ["meal"],
            prohibitedInferences: [],
            confidence: 0.84
        )
        let evidence = [
            makeEvidence(
                id: "total",
                metricKey: "finance.total.amount",
                metricValue: 14598.83,
                unit: "元",
                excerpt: "2026年截至当前总支出14598.83元",
                range: range,
                sourceModule: .finance
            ),
            makeEvidence(
                id: "meal",
                metricKey: "finance.category.amount",
                metricValue: 3516,
                unit: "元",
                excerpt: "餐饮支出3516元",
                range: range,
                comparison: "餐饮",
                sourceModule: .finance
            )
        ]
        let result = HoloAgentResultRenderer().render(
            claims: [observation, suggestion],
            evidence: evidence,
            question: "分析我2026年的财务数据，有哪些需要优化的地方？",
            answerContext: HoloAgentAnswerContext(
                primaryTimeRange: HoloAgentTimeRange(
                    label: "2026年",
                    start: range.start,
                    end: range.end
                ),
                snapshotCutoffAt: range.end
            )
        )

        expect(result.directAnswer?.contains("优先优化") == true, "优化问题首屏必须概括行动")
        expect(result.directAnswer != suggestion.displayText, "第一条建议不能被拆成不同字号的开场")
        expect(result.headline?.contains("优化建议") == true, "标题必须体现用户要的是优化")
        expect(result.recommendations?.count == 1, "建议必须进入类型化列表")
        expect(result.recommendations?.first?.title == "优先复核餐饮支出", "建议标题应提炼动作")
        expect(result.sections.contains { $0.kind == "observation" }, "建议后仍要保留事实依据")
    }

    private static func test年度财务事故统一上下文() {
        let staleRange = HoloAgentTimeRange(
            label: "近30天",
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let claims = [
            HoloAgentClaim(
                id: "fact",
                type: "observation",
                displayText: "礼物类支出25230.11元",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.category.amount",
                        value: 25230.11,
                        baselineValue: nil,
                        unit: "元",
                        comparison: "礼物",
                        evidenceIDs: ["gift"]
                    )
                ],
                evidenceIDs: ["gift"],
                prohibitedInferences: [],
                confidence: 0.94
            ),
            HoloAgentClaim(
                id: "r1",
                type: "suggestion",
                displayText: "建议1（高优先级）：审视礼物类大额支出。其中一笔25000元的MacBook Pro占比较高。",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.transaction.amount",
                        value: 25000,
                        baselineValue: nil,
                        unit: "元",
                        comparison: nil,
                        evidenceIDs: ["gift"]
                    )
                ],
                evidenceIDs: ["gift"],
                prohibitedInferences: [],
                confidence: 0.91
            ),
            HoloAgentClaim(
                id: "r2",
                type: "suggestion",
                displayText: "建议2（中优先级）：控制月度预算执行。本月已超支409元。",
                metricAssertions: [
                    HoloMetricAssertion(
                        metricKey: "finance.budget.overrun",
                        value: 409,
                        baselineValue: nil,
                        unit: "元",
                        comparison: nil,
                        evidenceIDs: ["budget"]
                    )
                ],
                evidenceIDs: ["budget"],
                prohibitedInferences: [],
                confidence: 0.86
            )
        ]
        let evidence = [
            makeEvidence(
                id: "gift",
                metricKey: "finance.category.amount",
                metricValue: 25230.11,
                unit: "元",
                excerpt: "礼物25230.11元，其中MacBook Pro 25000元",
                range: staleRange,
                sourceModule: .finance
            ),
            makeEvidence(
                id: "budget",
                metricKey: "finance.budget.overrun",
                metricValue: 409,
                unit: "元",
                excerpt: "本月预算超支409元",
                range: HoloAgentTimeRange(label: "本月", start: staleRange.start, end: staleRange.end),
                sourceModule: .finance
            )
        ]
        let result = HoloAgentResultRenderer().render(
            claims: claims,
            evidence: evidence,
            question: "分析我2026年的财务数据，有哪些需要优化的地方？",
            coverage: HoloDataCoverage(
                coveredDays: 132,
                totalDays: 365,
                coverageRatio: 132.0 / 365.0,
                missingRanges: [],
                note: "132天有交易",
                semantics: .eventRecords
            ),
            answerContext: HoloAgentAnswerContext(
                primaryTimeRange: HoloAgentTimeRange(
                    label: "2026年",
                    start: Date(timeIntervalSince1970: 1_767_225_600),
                    end: Date(timeIntervalSince1970: 1_798_761_600)
                ),
                snapshotCutoffAt: Date(timeIntervalSince1970: 1_785_033_600)
            )
        )

        expect(result.scope?.label == "2026年", "展示范围必须来自 Job 权威上下文")
        expect(result.headline?.contains("2026年") == true, "标题必须保留年度范围")
        expect(result.headline?.contains("近30天") == false, "旧 evidence label 不得覆盖年度范围")
        expect(result.coverageText == nil, "财务事件数据不得显示 132/365 覆盖")
        expect(result.limitations?.isEmpty == true, "财务事件数据不得触发覆盖不足")
        expect(result.recommendations?.map(\.id) == ["r1", "r2"], "两条建议必须同层且顺序稳定")
        expect(
            result.recommendations?.map(\.title) == ["审视礼物类大额支出", "控制月度预算执行"],
            "建议标题必须结构化提炼"
        )
        expect(!result.sections.contains { $0.kind == "suggestion" }, "建议不得再从第二个 sections 来源展示")
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
        sourceModule: HoloEvidenceSourceModule = .health,
        semantic: HoloMetricSemantic? = nil
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
            semantic: semantic,
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
