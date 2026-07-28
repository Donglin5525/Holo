//
//  HoloDeterministicAnswerComposerStandaloneTests.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P2 — 答案任务派生 / 确定性合成器 / 展示前验证 独立测试，
//  不依赖会触发 CloudKit 的 App 测试宿主。
//
//  运行（在 "Holo/Holo APP/Holo" 目录下；未加 -O，性能断言按 debug 放宽到 50ms）：
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
//    "HoloTests/Services/AI/Agent/HoloDeterministicAnswerComposerStandaloneTests.swift" \
//    -o /tmp/holo_deterministic_answer_test && /tmp/holo_deterministic_answer_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloDeterministicAnswerComposerStandaloneTests.main()
    }
}
#endif

struct HoloDeterministicAnswerComposerStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        // 灰度开关默认 true，显式固定避免本机 defaults 污染测试结果。
        HoloAgentResultSemanticsFlags.typedSemanticsEnabled = true
        HoloAgentResultSemanticsFlags.deterministicComposerEnabled = true

        test财务对比全链路坏模型文案被拦截()
        test零基准不出百分比且双零持平()
        test覆盖披露与不足限制()
        test总增组减抵消项与无增加项()
        test增量并列稳定排序()
        test同义问法派生同一答案任务()
        test旧证据无语义派生与合成都放弃()
        testNaN与无穷安全降级()
        test内部token分组被跳过()
        test一句话结论模式()
        test合成性能()
        test展示前验证三态()
        test无证据数字结论走失败边界()
        print("HoloDeterministicAnswerComposerStandaloneTests passed")
    }

    // MARK: - a) 财务对比全链路（P2 完成标准）

    /// 带 semantic 的证据 + 坏模型 displayText（metricKey / 公式 / 占位词 / 乱码），
    /// 最终 directAnswer 必须正确、无内部 token、summary 不含坏文案。
    private static func test财务对比全链路坏模型文案被拦截() {
        let evidence = financeComparisonEvidence()
        let assertions = evidence.map { record in
            HoloMetricAssertion(
                metricKey: record.metricKey,
                value: record.metricValue,
                baselineValue: nil,
                unit: record.unit,
                comparison: nil,
                evidenceIDs: [record.id]
            )
        }
        let claim = HoloAgentClaim(
            id: "bad-model",
            type: "change",
            displayText: "计算结果 24.3 比例；dynamic.finance_transactions.delta = difference(spend) 乱码\u{0}",
            metricAssertions: assertions,
            evidenceIDs: evidence.map(\.id),
            prohibitedInferences: [],
            confidence: 0.9
        )

        let result = HoloAgentResultRenderer().render(
            claims: [claim],
            evidence: evidence,
            title: "深度分析",
            question: "这个月消费比上个月多在哪儿？",
            coverage: HoloDataCoverage(
                coveredDays: 24, totalDays: 31, coverageRatio: 24.0 / 31.0,
                missingRanges: [], note: nil, semantics: .eventRecords
            )
        )

        let expected = "本月支出比上月增加 1,248 元，主要来自餐饮（+620 元）、交通（+386 元）和购物（+242 元）。餐饮贡献了总增量的 49.7%。"
        expect(result.directAnswer == expected, "直接结论应由合成器产出，实际：\(result.directAnswer ?? "nil")")
        expect(result.summary == expected, "summary 不得含坏模型文案，实际：\(result.summary)")
        expect(result.headline == "本月的支出去向", "headline 应来自合成器，实际：\(result.headline ?? "nil")")
        expect(result.coverageText == nil, "交易事件不能按有记录天数披露覆盖度")

        let visible = ([result.title, result.summary]
            + [result.headline, result.directAnswer, result.coverageText].compactMap { $0 }
            + result.sections.flatMap { [$0.title, $0.body] }
            + result.evidenceReferences.map(\.summary)).joined(separator: " ")
        expect(!visible.contains("计算结果"), "用户界面不能出现计算占位词")
        expect(!visible.contains("dynamic."), "用户界面不能暴露 metricKey 前缀")
        expect(!visible.contains("乱码"), "用户界面不能出现模型乱码")
        expect(!visible.contains("difference("), "用户界面不能暴露公式")
        expect(!HoloMetricSemanticCatalog.containsInternalToken(visible), "用户界面不能含内部 token")
    }

    // MARK: - b) 零基准

    private static func test零基准不出百分比且双零持平() {
        let range = makeRange("本月")
        let evidence = [
            makeSemanticEvidence(id: "r-food", range: range, semantic: makeSemantic(
                operation: .percentageChange, valueRole: .changeRate, groupLabel: "餐饮",
                direction: .increase, current: 620, baseline: 500, result: 0.243, unit: "比例"
            )),
            makeSemanticEvidence(id: "d-food", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: .increase, current: 620, baseline: 500, result: 120, unit: "元"
            )),
            // 基准为 0：百分比无意义，只能展示绝对变化
            makeSemanticEvidence(id: "r-fun", range: range, semantic: makeSemantic(
                operation: .percentageChange, valueRole: .changeRate, groupLabel: "娱乐",
                direction: .increase, current: 200, baseline: 0, result: 2.0, unit: "比例"
            )),
            makeSemanticEvidence(id: "d-fun", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "娱乐",
                direction: .increase, current: 200, baseline: 0, result: 200, unit: "元"
            )),
            // 当前基准都为 0：持平，跳过
            makeSemanticEvidence(id: "d-idle", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "闲置",
                direction: .flat, current: 0, baseline: 0, result: 0, unit: "元"
            ))
        ]
        let task = HoloAnswerTaskDeriver.derive(question: "哪些支出涨幅最高？", evidence: evidence)
        expect(task?.mode == .comparison, "变化率问法应为 comparison，实际 \(String(describing: task?.mode))")
        expect(task?.measure == .ratio, "问涨幅时主语义应为 changeRate（ratio）")

        let composed = HoloDeterministicAnswerComposer.compose(task: task!, evidence: evidence, coverage: nil)
        let answer = composed?.directAnswer ?? ""
        expect(answer.contains("餐饮（+24.3%）"), "正常基准应展示百分比，实际：\(answer)")
        expect(answer.contains("娱乐（+200 元）"), "零基准应回退绝对变化，实际：\(answer)")
        expect(!answer.contains("200%"), "零基准不得展示无意义百分比，实际：\(answer)")
        expect(!answer.contains("闲置"), "双零持平项应跳过，实际：\(answer)")
    }

    // MARK: - c) 覆盖披露

    private static func test覆盖披露与不足限制() {
        let evidence = financeComparisonEvidence()
        let task = HoloAnswerTaskDeriver.derive(question: "这个月消费比上个月多在哪儿？", evidence: evidence)!

        let partial = HoloDataCoverage(
            coveredDays: 24,
            totalDays: 31,
            coverageRatio: 24.0 / 31.0,
            missingRanges: [],
            note: nil,
            semantics: .dailyObservations
        )
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: partial)
        expect(composed?.coverageText?.contains("24/31 天有有效观测") == true, "日度覆盖 24/31 必须披露")
        expect(composed?.limitations.isEmpty == true, "24/31 不应触发覆盖不足限制")

        let low = HoloDataCoverage(
            coveredDays: 10,
            totalDays: 31,
            coverageRatio: 10.0 / 31.0,
            missingRanges: [],
            note: nil,
            semantics: .dailyObservations
        )
        let limited = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: low)
        expect(limited?.limitations.contains("日度观测覆盖较少，趋势结论仅供参考") == true, "覆盖 <0.6 必须有限制说明")
    }

    // MARK: - d) 抵消项与无匹配方向

    private static func test总增组减抵消项与无增加项() {
        let range = makeRange("本月")
        let baseline = makeRange("上月")
        // 总增 +1000：餐饮 +1300，交通 -300
        let offsetEvidence = [
            makeSemanticEvidence(id: "all", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: nil,
                direction: .increase, current: 2500, baseline: 1500, result: 1000, unit: "元"
            )),
            makeSemanticEvidence(id: "food", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: .increase, current: 2300, baseline: 1000, result: 1300, unit: "元"
            )),
            makeSemanticEvidence(id: "transit", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "交通",
                direction: .decrease, current: 200, baseline: 500, result: -300, unit: "元"
            ))
        ]
        let task = HoloAnswerTaskDeriver.derive(question: "这个月消费比上个月多在哪儿？", evidence: offsetEvidence)!
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: offsetEvidence, coverage: nil)
        let answer = composed?.directAnswer ?? ""
        expect(answer.contains("增加 1,000 元"), "总量结论应保留，实际：\(answer)")
        expect(answer.contains("交通减少 300 元，抵消了部分增量"), "必须说明抵消项，实际：\(answer)")

        // 全部组负 delta 且 direction=increase → 直接说没有发现增加项
        let allDown = [
            makeSemanticEvidence(id: "all2", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: nil,
                direction: .decrease, current: 1000, baseline: 1500, result: -500, unit: "元"
            )),
            makeSemanticEvidence(id: "food2", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: .decrease, current: 700, baseline: 1000, result: -300, unit: "元"
            )),
            makeSemanticEvidence(id: "transit2", range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "交通",
                direction: .decrease, current: 300, baseline: 500, result: -200, unit: "元"
            ))
        ]
        let upTask = HoloAnswerTaskDeriver.derive(question: "这个月消费比上个月多在哪儿？", evidence: allDown)!
        let upAnswer = HoloDeterministicAnswerComposer.compose(task: upTask, evidence: allDown, coverage: nil)?.directAnswer ?? ""
        expect(upAnswer.contains("没有发现增加项"), "无增加项时不硬凑排名，实际：\(upAnswer)")
        expect(!upAnswer.contains("主要来自"), "无增加项时不应出现排名措辞，实际：\(upAnswer)")
    }

    // MARK: - e) 并列稳定排序

    private static func test增量并列稳定排序() {
        let range = makeRange("本月")
        // 故意把「交通」放前面输入，验证排序与输入顺序无关
        let evidence = [
            makeSemanticEvidence(id: "transit", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "交通",
                direction: .increase, current: 800, baseline: 500, result: 300, unit: "元"
            )),
            makeSemanticEvidence(id: "food", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: .increase, current: 800, baseline: 500, result: 300, unit: "元"
            ))
        ]
        let task = HoloAnswerTaskDeriver.derive(question: "这个月消费比上个月多在哪儿？", evidence: evidence)!
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: nil)
        expect(composed?.items.first?.hasPrefix("交通") == true,
               "并列应按 groupLabel 字典序（交通 U+4EA4 < 餐饮 U+9910），实际：\(composed?.items ?? [])")
        let again = HoloDeterministicAnswerComposer.compose(task: task, evidence: Array(evidence.reversed()), coverage: nil)
        expect(again?.items == composed?.items, "颠倒输入顺序后排序必须稳定")
    }

    // MARK: - f) 同义问法收敛

    private static func test同义问法派生同一答案任务() {
        let evidence = financeComparisonEvidence()
        let taskA = HoloAnswerTaskDeriver.derive(question: "这个月消费比上个月多在哪儿？", evidence: evidence)
        let taskB = HoloAnswerTaskDeriver.derive(question: "本月比上月主要多花在什么地方？", evidence: evidence)
        expect(taskA == taskB, "同义问法必须派生同一 AnswerTask：\nA=\(String(describing: taskA))\nB=\(String(describing: taskB))")
        expect(taskA?.mode == .comparison && taskA?.direction == .increase, "任务应为 comparison+increase")
        expect(taskA?.domain == .finance && taskA?.measure == .amount && taskA?.dimension == .category,
               "任务主语义应为 finance/amount/category")
    }

    // MARK: - g) 旧证据兼容

    private static func test旧证据无语义派生与合成都放弃() {
        let range = makeRange("本月")
        let legacy = HoloEvidenceRecord(
            id: "legacy-1", dedupeKey: "legacy-1", sourceModule: .health, sourceID: nil,
            sourceKind: "steps_summary", timeRange: range, occurredAt: nil,
            metricKey: "health.steps.average", metricValue: 6990.8, unit: "步",
            baselineValue: nil, comparison: nil,
            excerpt: "步数汇总", redactedExcerpt: "步数汇总",
            sensitivity: .sensitive, confidence: 0.9, status: .active,
            generatedBy: "test", generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
        expect(HoloAnswerTaskDeriver.derive(question: "最近一个月平均步数是多少？", evidence: [legacy]) == nil,
               "无 semantic 证据不应派生 AnswerTask")
        let fallbackTask = HoloAnswerTask(mode: .lookup, domain: .health, measure: .steps, dimension: nil,
                                          direction: nil, primaryRangeLabel: "本月", baselineRangeLabel: nil, limit: 3)
        expect(HoloDeterministicAnswerComposer.compose(task: fallbackTask, evidence: [legacy], coverage: nil) == nil,
               "无 semantic 证据合成器应返回 nil，调用方走旧逻辑")
    }

    // MARK: - h) NaN / 无穷

    private static func testNaN与无穷安全降级() {
        let range = makeRange("本月")
        let evidence = [
            makeSemanticEvidence(id: "nan", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: nil, current: .nan, baseline: 500, result: .nan, unit: "元"
            )),
            makeSemanticEvidence(id: "inf", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "交通",
                direction: nil, current: .infinity, baseline: 500, result: .infinity, unit: "元"
            )),
            makeSemanticEvidence(id: "ok", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "购物",
                direction: .increase, current: 342, baseline: 100, result: 242, unit: "元"
            ))
        ]
        let task = HoloAnswerTaskDeriver.derive(question: "多在哪儿", evidence: evidence)!
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: nil)
        let answer = composed?.directAnswer ?? ""
        expect(answer.contains("购物（+242 元）"), "有限值分组应保留，实际：\(answer)")
        expect(!answer.contains("nan") && !answer.contains("inf"), "不得输出 nan/inf，实际：\(answer)")
        expect(!answer.contains("餐饮") && !answer.contains("交通"), "NaN/无穷分组应跳过，实际：\(answer)")

        // 全部非法 → 整体放弃
        let allBad = Array(evidence.prefix(2))
        let badTask = HoloAnswerTaskDeriver.derive(question: "多在哪儿", evidence: allBad)!
        expect(HoloDeterministicAnswerComposer.compose(task: badTask, evidence: allBad, coverage: nil) == nil,
               "全部 NaN/无穷时合成器应返回 nil")
    }

    // MARK: - i) 内部 token 分组跳过

    private static func test内部token分组被跳过() {
        let range = makeRange("本月")
        let evidence = [
            makeSemanticEvidence(id: "bad-group", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "finance.category_amount",
                direction: .increase, current: 900, baseline: 100, result: 800, unit: "元"
            )),
            makeSemanticEvidence(id: "good-group", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "餐饮",
                direction: .increase, current: 620, baseline: 500, result: 120, unit: "元"
            ))
        ]
        let task = HoloAnswerTaskDeriver.derive(question: "多在哪儿", evidence: evidence)!
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: nil)
        expect(composed?.items.count == 1 && composed?.items.first?.hasPrefix("餐饮") == true,
               "含内部 token 的 groupLabel 必须跳过，实际：\(composed?.items ?? [])")
    }

    // MARK: - j) lookup / trend / correlation 一句话结论

    private static func test一句话结论模式() {
        let range = makeRange("最近一周")
        // lookup
        let lookupEvidence = [makeSemanticEvidence(id: "lookup", range: makeRange("本月"), semantic: makeSemantic(
            operation: .sum, valueRole: .current, groupLabel: nil,
            direction: nil, current: 3248.5, baseline: nil, result: 3248.5, unit: "元", dimension: nil
        ))]
        let lookupTask = HoloAnswerTaskDeriver.derive(question: "这个月花了多少钱？", evidence: lookupEvidence)
        expect(lookupTask?.mode == .lookup, "无分组无派生应为 lookup，实际 \(String(describing: lookupTask?.mode))")
        expect(lookupTask?.direction == nil, "「多少钱」不应误判为 increase")
        let lookupAnswer = HoloDeterministicAnswerComposer.compose(task: lookupTask!, evidence: lookupEvidence, coverage: nil)?.directAnswer ?? ""
        expect(lookupAnswer == "本月，支出 3,248.5 元", "lookup 结论应为值+单位+范围，实际：\(lookupAnswer)")

        // trend
        let trendEvidence = [makeSemanticEvidence(id: "trend", range: range, semantic: makeSemantic(
            operation: .linearTrend, valueRole: .trend, groupLabel: nil,
            direction: nil, current: nil, baseline: nil, result: 150.4, unit: "步",
            dimension: .day, domain: .health, measure: .steps
        ))]
        let trendTask = HoloAnswerTaskDeriver.derive(question: "最近一周步数趋势如何？", evidence: trendEvidence)
        expect(trendTask?.mode == .trend, "linearTrend 应为 trend，实际 \(String(describing: trendTask?.mode))")
        let trendAnswer = HoloDeterministicAnswerComposer.compose(task: trendTask!, evidence: trendEvidence, coverage: nil)?.directAnswer ?? ""
        expect(trendAnswer.contains("上升趋势") && trendAnswer.contains("150 步"), "trend 应给出方向+幅度，实际：\(trendAnswer)")

        // correlation
        let correlationEvidence = [makeSemanticEvidence(id: "corr", range: range, semantic: makeSemantic(
            operation: .correlation, valueRole: .current, groupLabel: nil,
            direction: nil, current: 0.82, baseline: nil, result: 0.82, unit: "相关系数",
            dimension: nil, domain: .finance, measure: .correlation
        ))]
        let correlationTask = HoloAnswerTaskDeriver.derive(question: "最近一周步数和支出有关联吗？", evidence: correlationEvidence)
        expect(correlationTask?.mode == .correlation, "correlation 操作应为 correlation，实际 \(String(describing: correlationTask?.mode))")
        let correlationAnswer = HoloDeterministicAnswerComposer.compose(task: correlationTask!, evidence: correlationEvidence, coverage: nil)?.directAnswer ?? ""
        expect(correlationAnswer == "最近一周，两项数据的相关系数为 0.82，相关性较强，仅表示关联，不表示因果。",
               "correlation 必须带非因果声明，实际：\(correlationAnswer)")
    }

    // MARK: - k) 性能

    private static func test合成性能() {
        let range = makeRange("本月")
        var evidence: [HoloEvidenceRecord] = []
        for index in 0..<50 {
            evidence.append(makeSemanticEvidence(id: "perf-\(index)", range: range, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: "分组\(index)",
                direction: .increase, current: 600 + Double(index), baseline: 500, result: 100 + Double(index), unit: "元"
            )))
        }
        let task = HoloAnswerTaskDeriver.derive(question: "多在哪儿", evidence: evidence)!
        let start = Date()
        let composed = HoloDeterministicAnswerComposer.compose(task: task, evidence: evidence, coverage: nil)
        let elapsedMs = Date().timeIntervalSince(start) * 1_000
        expect(composed != nil, "50 条 evidence 应能合成")
        // debug（未开 -O）编译下放宽到 50ms；-O 下应远小于方案目标 20ms
        expect(elapsedMs < 50, "50 条 evidence 合成耗时 \(elapsedMs)ms，超过 50ms 上限")
    }

    // MARK: - l) 展示前验证三态

    private static func test展示前验证三态() {
        let semantic = makeSemantic(
            operation: .difference, valueRole: .delta, groupLabel: "餐饮",
            direction: .increase, current: 620, baseline: 500, result: 120, unit: "元"
        )
        let evidence = [makeSemanticEvidence(id: "ev", range: makeRange("本月"), semantic: semantic)]
        func result(summary: String, directAnswer: String? = nil, coverageText: String? = nil) -> HoloRenderedAgentResult {
            HoloRenderedAgentResult(
                title: "本期观察", summary: summary, sections: [], evidenceReferences: [],
                question: nil, headline: nil, directAnswer: directAnswer,
                coverageText: coverageText, limitations: nil
            )
        }

        // 内部 token → recoverable / INTERNAL_TOKEN
        let tokenVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "计算结果 24.3 比例"), evidence: evidence, coverage: nil
        )
        expect(tokenVerdict == .recoverable(["INTERNAL_TOKEN"]), "内部 token 应为 recoverable，实际 \(tokenVerdict)")

        // 覆盖不足未披露 → recoverable / COVERAGE_UNDISCLOSED
        let coverage = HoloDataCoverage(
            coveredDays: 24,
            totalDays: 31,
            coverageRatio: 24.0 / 31.0,
            missingRanges: [],
            note: nil,
            semantics: .dailyObservations
        )
        let coverageVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "本月支出增加"), evidence: evidence, coverage: coverage
        )
        expect(coverageVerdict == .recoverable(["COVERAGE_UNDISCLOSED"]), "覆盖未披露应为 recoverable，实际 \(coverageVerdict)")
        let disclosedVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "本月支出增加", coverageText: "本月共 31 天，其中 24/31 天有有效记录"),
            evidence: evidence, coverage: coverage
        )
        expect(disclosedVerdict == .pass, "披露覆盖后应通过，实际 \(disclosedVerdict)")

        // 无证据有数字 → failed / NO_EVIDENCE
        let noEvidenceVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "支出 100 元"), evidence: [], coverage: nil
        )
        expect(noEvidenceVerdict == .failed(["NO_EVIDENCE"]), "无证据数字结论应为 failed，实际 \(noEvidenceVerdict)")

        // 编造分组 → recoverable / UNKNOWN_GROUP
        let unknownVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "本月支出比上月增加 100 元，主要来自娱乐（+100 元）。"),
            evidence: evidence, coverage: nil
        )
        expect(unknownVerdict == .recoverable(["UNKNOWN_GROUP"]), "编造分组应为 recoverable，实际 \(unknownVerdict)")

        // 同句同主体方向矛盾 → recoverable / DIRECTION_CONFLICT
        let conflictVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "餐饮增加 100 元；餐饮减少 200 元。"),
            evidence: evidence, coverage: nil
        )
        expect(conflictVerdict == .recoverable(["DIRECTION_CONFLICT"]), "方向矛盾应为 recoverable，实际 \(conflictVerdict)")

        // 干净结果 → pass
        let passVerdict = HoloAnswerCoverageVerifier.verify(
            result: result(summary: "本月支出比上月增加 1,248 元，主要来自餐饮（+620 元）。"),
            evidence: evidence, coverage: nil
        )
        expect(passVerdict == .pass, "干净结果应通过，实际 \(passVerdict)")
    }

    // MARK: - m) 失败边界

    private static func test无证据数字结论走失败边界() {
        let claim = HoloAgentClaim(
            id: "no-evidence",
            type: "observation",
            displayText: "支出 100 元",
            metricAssertions: [],
            evidenceIDs: [],
            prohibitedInferences: [],
            confidence: 0.9
        )
        let result = HoloAgentResultRenderer().render(
            claims: [claim], evidence: [], title: "本期观察", question: "花了多少", coverage: nil
        )
        expect(result.directAnswer == "这次分析没能形成可信结论，已为你保留数据明细。",
               "failed 时必须给边界说明，实际：\(result.directAnswer ?? "nil")")
        expect(result.sections.isEmpty, "failed 时不得交付模型文案 section")
        expect(!result.summary.contains("100"), "failed 时不得保留无证据数字")
    }

    // MARK: - 测试构造工具

    /// 标准财务对比证据：餐饮 +620 / 交通 +386 / 购物 +242 / 总 +1248，baseline 齐全。
    private static func financeComparisonEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月")
        let baseline = makeRange("上月")
        func delta(_ id: String, _ label: String?, _ current: Double, _ base: Double) -> HoloEvidenceRecord {
            makeSemanticEvidence(id: id, range: range, baselineRange: baseline, semantic: makeSemantic(
                operation: .difference, valueRole: .delta, groupLabel: label,
                direction: current > base ? .increase : .decrease,
                current: current, baseline: base, result: current - base, unit: "元"
            ))
        }
        return [
            delta("all", nil, 5_248, 4_000),
            delta("food", "餐饮", 1_120, 500),
            delta("transit", "交通", 886, 500),
            delta("shopping", "购物", 342, 100)
        ]
    }

    private static func makeRange(_ label: String) -> HoloAgentTimeRange {
        HoloAgentTimeRange(label: label, start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
    }

    private static func makeSemantic(
        operation: HoloMetricOperation,
        valueRole: HoloMetricValueRole,
        groupLabel: String?,
        direction: HoloMetricDirection?,
        current: Double?,
        baseline: Double?,
        result: Double,
        unit: String?,
        dimension: HoloMetricDimension? = .category,
        domain: HoloEvidenceSourceModule = .finance,
        measure: HoloMetricMeasure = .amount
    ) -> HoloMetricSemantic {
        HoloMetricSemantic(
            domain: domain,
            dataset: "finance.transactions",
            measure: unit == "比例" ? .ratio : measure,
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

    private static func makeSemanticEvidence(
        id: String,
        range: HoloAgentTimeRange,
        baselineRange: HoloAgentTimeRange? = nil,
        semantic: HoloMetricSemantic
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: semantic.domain,
            sourceID: nil,
            sourceKind: "dynamic_query",
            timeRange: range,
            occurredAt: nil,
            metricKey: "dynamic.test.\(id)",
            metricValue: semantic.resultValue,
            unit: semantic.displayUnit,
            baselineValue: semantic.baselineValue,
            baselineTimeRange: baselineRange,
            comparison: semantic.groupLabel,
            semantic: semantic,
            excerpt: "动态计算（\(semantic.groupLabel ?? "全部")）",
            redactedExcerpt: "动态计算（\(semantic.groupLabel ?? "全部")）",
            sensitivity: .normal,
            confidence: 0.9,
            status: .active,
            generatedBy: "test",
            generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [],
            referencedByMemoryIDs: [],
            deviceID: nil
        )
    }
}
