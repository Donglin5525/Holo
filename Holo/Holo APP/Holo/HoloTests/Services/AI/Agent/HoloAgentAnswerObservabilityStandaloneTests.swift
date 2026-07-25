//
//  HoloAgentAnswerObservabilityStandaloneTests.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P4 — 派生优先级修正（健康汇总 trend/lookup）与
//  可观测指标（方案 §11 六个本地聚合指标）独立测试，
//  不依赖会触发 CloudKit 的 App 测试宿主。
//
//  运行（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Models/AI/Agent/HoloEvidenceModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentOutputModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentToolModels.swift" \
//    "Holo/Services/AI/Agent/Tools/HoloDataTool.swift" \
//    "Holo/Services/AI/Agent/Presentation/HoloAgentAnswerTask.swift" \
//    "Holo/Services/AI/Agent/Presentation/HoloDeterministicAnswerComposer.swift" \
//    "Holo/Services/AI/Agent/Verification/HoloAnswerCoverageVerifier.swift" \
//    "Holo/Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift" \
//    "Holo/Services/AI/Agent/HoloAgentAnswerMetricCounter.swift" \
//    "HoloTests/Services/AI/Agent/HoloAgentAnswerObservabilityStandaloneTests.swift" \
//    -o /tmp/holo_answer_observability_test && /tmp/holo_answer_observability_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloAgentAnswerObservabilityStandaloneTests.main()
    }
}
#endif

struct HoloAgentAnswerObservabilityStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        HoloAgentResultSemanticsFlags.typedSemanticsEnabled = true
        HoloAgentResultSemanticsFlags.deterministicComposerEnabled = true

        test健康汇总平均问法派生lookup而非trend()
        test健康汇总无意图问法派生lookup()
        test健康汇总显式趋势意图仍派生trend()
        test健康汇总排名意图优先派生ranking()
        test显式linearTrend语义无论问法都派生trend()
        test语义缺失与旧目录兜底计数()
        test合成器使用计数()
        test内部token拦截与模型文案丢弃计数()
        test覆盖失败计数()
        test指标快照只含稳定技术码()
        print("HoloAgentAnswerObservabilityStandaloneTests passed")
    }

    // MARK: - P4 派生优先级修正

    /// 「平均/日均」问法 + 健康汇总证据（单一 current 聚合 + day 每日点）→ lookup，
    /// 且直接结论使用聚合值，不再派生 trend。
    private static func test健康汇总平均问法派生lookup而非trend() {
        let evidence = healthSummaryEvidence()
        for question in ["最近一个月平均步数是多少？", "最近日均步数多少？"] {
            let task = HoloAnswerTaskDeriver.derive(question: question, evidence: evidence)
            expect(task?.mode == .lookup, "「平均/日均」应派生 lookup，实际 \(String(describing: task?.mode))（\(question)）")
            expect(task?.measure == .steps, "主语义应为 steps 聚合，实际 \(String(describing: task?.measure))")
            let answer = HoloDeterministicAnswerComposer.compose(task: task!, evidence: evidence, coverage: nil)
            expect(answer?.directAnswer.contains("6,991 步") == true,
                   "lookup 应回答聚合值 6,991 步，实际：\(answer?.directAnswer ?? "nil")")
            expect(answer?.directAnswer.contains("趋势") == false, "平均问法不得回答趋势")
        }
    }

    /// 无意图问法（「怎么样」）：时间多点不再自动判趋势，回答聚合值。
    private static func test健康汇总无意图问法派生lookup() {
        let evidence = healthSummaryEvidence()
        let task = HoloAnswerTaskDeriver.derive(question: "最近步数怎么样？", evidence: evidence)
        expect(task?.mode == .lookup, "无意图问法应派生 lookup，实际 \(String(describing: task?.mode))")
    }

    /// 显式趋势意图词（趋势/变化/走向/越来越）仍可从时间多点派生 trend。
    private static func test健康汇总显式趋势意图仍派生trend() {
        let evidence = healthSummaryEvidence()
        for question in ["最近步数趋势如何？", "最近步数有什么变化？", "最近步数走向怎么样？", "最近步数越来越多吗？"] {
            let task = HoloAnswerTaskDeriver.derive(question: question, evidence: evidence)
            expect(task?.mode == .trend, "显式趋势意图应派生 trend，实际 \(String(describing: task?.mode))（\(question)）")
        }
    }

    /// 排名意图优先于时间序列启发（P3 行为保持不变）。
    private static func test健康汇总排名意图优先派生ranking() {
        let evidence = healthSummaryEvidence()
        let task = HoloAnswerTaskDeriver.derive(question: "哪天步数最多？", evidence: evidence)
        expect(task?.mode == .ranking, "排名意图应派生 ranking，实际 \(String(describing: task?.mode))")
    }

    /// 显式 linearTrend / trend 角色语义：无论问法都派生 trend。
    private static func test显式linearTrend语义无论问法都派生trend() {
        let range = makeRange("本周")
        let evidence = [makeEvidence(id: "trend", range: range, semantic: makeSemantic(
            domain: .health, measure: .steps, operation: .linearTrend, valueRole: .trend,
            dimension: nil, groupLabel: nil, result: 150, unit: "步"
        ))]
        let task = HoloAnswerTaskDeriver.derive(question: "最近步数怎么样？", evidence: evidence)
        expect(task?.mode == .trend, "linearTrend 语义应派生 trend，实际 \(String(describing: task?.mode))")
    }

    // MARK: - P4 可观测指标

    /// 旧证据无 semantic：agent.semantic.missing +1；旧目录产出句子：agent.semantic.legacy_fallback +1。
    private static func test语义缺失与旧目录兜底计数() {
        let counter = HoloAgentAnswerMetricCounter.shared
        counter.reset()
        let range = makeRange("本月")
        let legacy = HoloEvidenceRecord(
            id: "legacy", dedupeKey: "legacy", sourceModule: .finance, sourceID: nil,
            sourceKind: "aggregate", timeRange: range, occurredAt: nil,
            metricKey: "finance.total.amount", metricValue: 3_200, unit: "元",
            baselineValue: nil, comparison: nil, semantic: nil,
            excerpt: "本月总支出 3,200 元", redactedExcerpt: "本月总支出 3,200 元",
            sensitivity: .normal, confidence: 0.9, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
        let assertion = HoloMetricAssertion(
            metricKey: "finance.total.amount", value: 3_200, baselineValue: nil,
            unit: "元", comparison: nil, evidenceIDs: ["legacy"]
        )
        let claim = HoloAgentClaim(
            id: "c", type: "observation", displayText: "本月总支出 3,200 元",
            metricAssertions: [assertion], evidenceIDs: ["legacy"],
            prohibitedInferences: [], confidence: 0.9
        )
        let result = HoloAgentResultRenderer().render(
            claims: [claim], evidence: [legacy], title: "本期观察", question: "本月消费多少", coverage: nil
        )
        expect(result.directAnswer?.contains("3,200") == true, "旧目录兜底应给出数字结论")
        expect(counter.count(for: .semanticMissing) == 1, "semantic.missing 应 +1，实际 \(counter.count(for: .semanticMissing))")
        expect(counter.count(for: .semanticLegacyFallback) == 1, "legacy_fallback 应 +1，实际 \(counter.count(for: .semanticLegacyFallback))")
        expect(counter.count(for: .composerUsed) == 0, "旧证据不应触发合成器")
        counter.reset()
    }

    /// 带语义证据走合成器：agent.answer.composer_used +1，上下文为领域码。
    private static func test合成器使用计数() {
        let counter = HoloAgentAnswerMetricCounter.shared
        counter.reset()
        let evidence = financeComparisonEvidence()
        let claim = makeClaim(id: "ok", displayText: "本月支出比上月增加 1,248 元。", evidence: evidence)
        _ = HoloAgentResultRenderer().render(
            claims: [claim], evidence: evidence, title: "本期观察",
            question: "这个月消费比上个月多在哪儿？", coverage: nil
        )
        expect(counter.count(for: .composerUsed) == 1, "composer_used 应 +1，实际 \(counter.count(for: .composerUsed))")
        expect(counter.snapshot()["agent.answer.composer_used|finance"] == 1, "composer_used 上下文应为 finance")
        expect(counter.count(for: .semanticMissing) == 0, "有语义证据不应计 semantic.missing")
        counter.reset()
    }

    /// 模型文案含内部 token：internal_token_blocked 与 model_text_discarded 均 +1，最终答案干净。
    private static func test内部token拦截与模型文案丢弃计数() {
        let counter = HoloAgentAnswerMetricCounter.shared
        counter.reset()
        let evidence = financeComparisonEvidence()
        let claim = makeClaim(
            id: "bad", displayText: "计算结果 24.3 比例；difference(spend) 已算出",
            evidence: evidence
        )
        let result = HoloAgentResultRenderer().render(
            claims: [claim], evidence: evidence, title: "本期观察",
            question: "这个月消费比上个月多在哪儿？", coverage: nil
        )
        let visible = HoloAnswerCoverageVerifier.userFacingTexts(of: result).joined(separator: " ")
        expect(!HoloAnswerCoverageVerifier.containsInternalToken(visible), "最终用户文本不得含内部 token")
        expect(counter.count(for: .internalTokenBlocked) >= 1, "internal_token_blocked 应 +1，实际 \(counter.count(for: .internalTokenBlocked))")
        expect(counter.count(for: .modelTextDiscarded) >= 1, "model_text_discarded 应 +1，实际 \(counter.count(for: .modelTextDiscarded))")
        counter.reset()
    }

    /// 覆盖验证 failed：agent.answer.coverage_failed +1，上下文为失败短码。
    private static func test覆盖失败计数() {
        let counter = HoloAgentAnswerMetricCounter.shared
        counter.reset()
        let claim = HoloAgentClaim(
            id: "no-evidence", type: "observation", displayText: "支出 100 元",
            metricAssertions: [], evidenceIDs: [], prohibitedInferences: [], confidence: 0.9
        )
        let result = HoloAgentResultRenderer().render(
            claims: [claim], evidence: [], title: "本期观察", question: "花了多少", coverage: nil
        )
        expect(result.directAnswer == "这次分析没能形成可信结论，已为你保留数据明细。",
               "failed 应走边界说明，实际：\(result.directAnswer ?? "nil")")
        expect(counter.count(for: .coverageFailed) == 1, "coverage_failed 应 +1，实际 \(counter.count(for: .coverageFailed))")
        expect(counter.snapshot()["agent.answer.coverage_failed|NO_EVIDENCE"] == 1, "coverage_failed 上下文应为失败短码")
        counter.reset()
    }

    /// 快照 key 只允许指标名与稳定技术上下文，不得携带用户原文/分类名/数字。
    private static func test指标快照只含稳定技术码() {
        let counter = HoloAgentAnswerMetricCounter.shared
        counter.reset()
        let evidence = financeComparisonEvidence()
        _ = HoloAgentResultRenderer().render(
            claims: [makeClaim(id: "ok", displayText: "本月支出增加", evidence: evidence)],
            evidence: evidence, title: "本期观察", question: "这个月消费比上个月多在哪儿？", coverage: nil
        )
        let keys = counter.snapshot().keys
        expect(!keys.isEmpty, "快照应包含全部 6 个指标")
        for key in keys {
            expect(key.hasPrefix("agent."), "指标 key 必须是稳定指标名，实际：\(key)")
            expect(!key.contains("餐饮") && !key.contains("多在哪"), "指标不得携带用户原文/分类名：\(key)")
            expect(key.range(of: #"\d{3,}"#, options: .regularExpression) == nil, "指标不得携带具体数字：\(key)")
        }
        counter.reset()
    }

    // MARK: - 测试构造工具

    /// 固定健康工具汇总形态：单一 current 聚合（health.steps.average）+ day 维度每日点。
    private static func healthSummaryEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("最近一个月")
        var evidence = [makeEvidence(id: "steps-average", range: range, semantic: makeSemantic(
            domain: .health, measure: .steps, operation: .average, valueRole: .current,
            dimension: nil, groupLabel: nil, result: 6_990.8, unit: "步"
        ))]
        let daily: [(String, Double)] = [
            ("07-11", 6_200), ("07-12", 7_100), ("07-13", 6_800), ("07-14", 7_400), ("07-15", 7_200)
        ]
        for (day, value) in daily {
            evidence.append(makeEvidence(id: "steps-\(day)", range: range, semantic: makeSemantic(
                domain: .health, measure: .steps, operation: .sum, valueRole: .current,
                dimension: .day, groupLabel: "2026-\(day)", result: value, unit: "步"
            )))
        }
        return evidence
    }

    /// 财务对比证据：总 +1,248（餐饮 +620 / 交通 +386 / 购物 +242）。
    private static func financeComparisonEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月")
        func delta(_ id: String, _ label: String?, _ current: Double, _ base: Double) -> HoloEvidenceRecord {
            makeEvidence(id: id, range: range, baselineRange: makeRange("上月"), semantic: makeSemantic(
                domain: .finance, measure: .amount, operation: .difference, valueRole: .delta,
                dimension: .category, groupLabel: label,
                direction: current > base ? .increase : .decrease,
                current: current, baseline: base, result: current - base, unit: "元"
            ))
        }
        return [
            makeEvidence(id: "all", range: range, baselineRange: makeRange("上月"), semantic: makeSemantic(
                domain: .finance, measure: .amount, operation: .difference, valueRole: .delta,
                dimension: nil, groupLabel: nil, direction: .increase,
                current: 5_248, baseline: 4_000, result: 1_248, unit: "元"
            )),
            delta("food", "餐饮", 1_120, 500),
            delta("transit", "交通", 886, 500),
            delta("shopping", "购物", 342, 100)
        ]
    }

    private static func makeClaim(id: String, displayText: String, evidence: [HoloEvidenceRecord]) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id, type: "change", displayText: displayText,
            metricAssertions: evidence.map {
                HoloMetricAssertion(
                    metricKey: $0.metricKey, value: $0.metricValue, baselineValue: nil,
                    unit: $0.unit, comparison: nil, evidenceIDs: [$0.id]
                )
            },
            evidenceIDs: evidence.map(\.id),
            prohibitedInferences: [], confidence: 0.9
        )
    }

    private static func makeRange(_ label: String) -> HoloAgentTimeRange {
        HoloAgentTimeRange(label: label, start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
    }

    private static func makeSemantic(
        domain: HoloEvidenceSourceModule,
        measure: HoloMetricMeasure,
        operation: HoloMetricOperation,
        valueRole: HoloMetricValueRole,
        dimension: HoloMetricDimension?,
        groupLabel: String?,
        direction: HoloMetricDirection? = nil,
        current: Double? = nil,
        baseline: Double? = nil,
        result: Double,
        unit: String?
    ) -> HoloMetricSemantic {
        HoloMetricSemantic(
            domain: domain,
            dataset: "test.dataset",
            measure: measure,
            operation: operation,
            valueRole: valueRole,
            dimension: dimension,
            groupLabel: groupLabel,
            direction: direction,
            currentValue: current,
            baselineValue: baseline,
            resultValue: result,
            displayUnit: unit
        )
    }

    private static func makeEvidence(
        id: String,
        range: HoloAgentTimeRange,
        baselineRange: HoloAgentTimeRange? = nil,
        semantic: HoloMetricSemantic
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: semantic.domain, sourceID: nil,
            sourceKind: "dynamic_query", timeRange: range, occurredAt: nil,
            metricKey: "dynamic.test.\(id)", metricValue: semantic.resultValue,
            unit: semantic.displayUnit, baselineValue: semantic.baselineValue,
            baselineTimeRange: baselineRange, comparison: semantic.groupLabel,
            semantic: semantic,
            excerpt: "动态计算（\(semantic.groupLabel ?? "全部")）",
            redactedExcerpt: "动态计算（\(semantic.groupLabel ?? "全部")）",
            sensitivity: .normal, confidence: 0.9, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }
}
