@testable import Holo
//
//  HoloAgentEvalAnswerPresentationCorpus.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P4 — 答案语义/展示问法矩阵（方案 §10，共 92 条）
//
//  不重复 P0 seed corpus 的 9 类场景，专注两个新类别：
//    - answerModeConsistency（52 条）：问法 → AnswerTask 派生与同义收敛（§10.1/§10.2），
//      覆盖财务/习惯/任务/健康/目标的 lookup/comparison/ranking/breakdown/trend/correlation
//      适用组合；同义问法组由 runner 交叉断言（同一 AnswerTask + 数字一致）。
//    - answerPresentationRobustness（40 条）：坏模型文案 / 边界样例 / 降级（§10.3），
//      含零基准、双零、缺失分类名、增量并列、总增组减、24/31 天覆盖、NaN/负值/单位缺失、
//      旧证据无 semantic、错标题/错单位/内部 key/乱码与六个可观测指标。
//  全部为确定性 fixture（类型化语义证据 + 注入模型文案），不调用 LLM。
//

import Foundation

enum HoloAgentEvalAnswerPresentationCorpus {

    static func allCases() -> [HoloAgentEvalCase] {
        var cases: [HoloAgentEvalCase] = []
        cases.append(contentsOf: financeModeConsistency())
        cases.append(contentsOf: habitModeConsistency())
        cases.append(contentsOf: taskModeConsistency())
        cases.append(contentsOf: healthModeConsistency())
        cases.append(contentsOf: goalAndCorrelationConsistency())
        cases.append(contentsOf: boundaryRobustness())
        cases.append(contentsOf: legacyAndObservabilityRobustness())
        cases.append(contentsOf: badModelTextRobustness())
        return cases
    }

    // MARK: - 用例构造工具

    private static func makeCase(
        _ id: String,
        category: HoloAgentEvalCategory,
        query: String,
        evidence: [HoloEvidenceRecord],
        coverage: HoloDataCoverage? = nil,
        expectation ap: HoloAgentEvalAnswerPresentationExpectation
    ) -> HoloAgentEvalCase {
        HoloAgentEvalCase(
            id: id, category: category, query: query,
            referenceDate: HoloAgentEvalSeedCorpus.referenceISO,
            expectation: HoloAgentEvalExpectation(answerPresentation: ap),
            fixtures: HoloAgentEvalFixtures(evidence: evidence, coverage: coverage),
            origin: .seed, schemaVersion: 1
        )
    }

    /// AnswerTask 派生一致性断言（含同义组）。
    private static func consistency(
        mode: String,
        domain: String,
        direction: String? = nil,
        dimension: String? = nil,
        contains: [String],
        group: String? = nil
    ) -> HoloAgentEvalAnswerPresentationExpectation {
        HoloAgentEvalAnswerPresentationExpectation(
            expectedMode: mode, expectedDomain: domain, expectedDirection: direction,
            expectedDimension: dimension, expectComposedDirectAnswer: true,
            directAnswerMustContain: contains, synonymGroup: group
        )
    }

    // MARK: - 证据构造工具

    private static func makeRange(_ label: String) -> HoloAgentTimeRange {
        HoloAgentTimeRange(label: label, start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
    }

    private static func sem(
        domain: HoloEvidenceSourceModule = .finance,
        dataset: String = "finance.transactions",
        measure: HoloMetricMeasure = .amount,
        operation: HoloMetricOperation,
        role: HoloMetricValueRole,
        dimension: HoloMetricDimension? = nil,
        label: String? = nil,
        direction: HoloMetricDirection? = nil,
        current: Double? = nil,
        baseline: Double? = nil,
        result: Double,
        unit: String? = "元"
    ) -> HoloMetricSemantic {
        HoloMetricSemantic(
            domain: domain, dataset: dataset, measure: measure, operation: operation,
            valueRole: role, dimension: dimension, groupLabel: label, direction: direction,
            currentValue: current, baselineValue: baseline, resultValue: result, displayUnit: unit
        )
    }

    /// excerpt 保持中性：不含分组名（用户可见）、不含内部 token。
    private static func ev(
        _ id: String,
        range: HoloAgentTimeRange,
        baselineRange: HoloAgentTimeRange? = nil,
        semantic: HoloMetricSemantic
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: semantic.domain, sourceID: nil,
            sourceKind: "dynamic_query", timeRange: range, occurredAt: nil,
            metricKey: "dynamic.eval.\(id)", metricValue: semantic.resultValue,
            unit: semantic.displayUnit, baselineValue: semantic.baselineValue,
            baselineTimeRange: baselineRange, comparison: semantic.groupLabel,
            semantic: semantic,
            excerpt: "动态计算明细", redactedExcerpt: "动态计算明细",
            sensitivity: .normal, confidence: 0.9, status: .active,
            generatedBy: "eval-fixture", generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }

    private static func coverage(_ covered: Int, _ total: Int) -> HoloDataCoverage {
        HoloDataCoverage(
            coveredDays: covered, totalDays: total,
            coverageRatio: Double(covered) / Double(total), missingRanges: [], note: nil
        )
    }

    // MARK: - 标准 fixtures

    /// 财务标准对比：总 +1,248（餐饮 +620 / 交通 +386 / 购物 +242），维度 category。
    private static func financeIncreaseEvidence(
        range rangeLabel: String = "本月",
        baseline baselineLabel: String = "上月"
    ) -> [HoloEvidenceRecord] {
        let range = makeRange(rangeLabel), base = makeRange(baselineLabel)
        func delta(_ id: String, _ label: String?, _ current: Double, _ baseValue: Double) -> HoloEvidenceRecord {
            ev(id, range: range, baselineRange: base, semantic: sem(
                operation: .difference, role: .delta, dimension: .category, label: label,
                direction: current > baseValue ? .increase : .decrease,
                current: current, baseline: baseValue, result: current - baseValue))
        }
        return [
            delta("fin-all", nil, 5_248, 4_000),
            delta("fin-food", "餐饮", 1_120, 500),
            delta("fin-transit", "交通", 886, 500),
            delta("fin-shopping", "购物", 342, 100)
        ]
    }

    /// 财务下降对比：总 -800（餐饮 -500 / 交通 -300）。
    private static func financeDecreaseEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月"), base = makeRange("上月")
        func delta(_ id: String, _ label: String?, _ current: Double, _ baseValue: Double) -> HoloEvidenceRecord {
            ev(id, range: range, baselineRange: base, semantic: sem(
                operation: .difference, role: .delta, dimension: .category, label: label,
                direction: .decrease, current: current, baseline: baseValue, result: current - baseValue))
        }
        return [delta("dec-all", nil, 3_200, 4_000), delta("dec-food", "餐饮", 1_000, 1_500), delta("dec-transit", "交通", 700, 1_000)]
    }

    /// 财务涨幅对比：changeRate（餐饮 +24% / 交通 +77.2% / 购物 +242%）+ 对应 delta（+120/+386/+242）。
    private static func financeRateEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月"), base = makeRange("上月")
        func pair(_ id: String, _ label: String, _ current: Double, _ baseValue: Double) -> [HoloEvidenceRecord] {
            let rate = (current - baseValue) / baseValue
            return [
                ev("rate-\(id)", range: range, baselineRange: base, semantic: sem(
                    measure: .ratio, operation: .percentageChange, role: .changeRate,
                    dimension: .category, label: label, direction: .increase,
                    current: current, baseline: baseValue, result: rate, unit: "比例")),
                ev("delta-\(id)", range: range, baselineRange: base, semantic: sem(
                    operation: .difference, role: .delta, dimension: .category, label: label,
                    direction: .increase, current: current, baseline: baseValue,
                    result: current - baseValue, unit: "元"))
            ]
        }
        return pair("food", "餐饮", 620, 500) + pair("transit", "交通", 886, 500) + pair("shopping", "购物", 342, 100)
    }

    /// 财务单值 lookup：总支出 3,248.5 元。
    private static func financeSingleCurrentEvidence() -> [HoloEvidenceRecord] {
        [ev("fin-sum", range: makeRange("本月"), semantic: sem(
            operation: .sum, role: .current, current: 3_248.5, result: 3_248.5))]
    }

    /// 财务分类现状：餐饮 1,120 / 交通 886 / 购物 342（ranking/breakdown 共用）。
    private static func financeCategoryCurrentsEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月")
        func current(_ id: String, _ label: String, _ value: Double) -> HoloEvidenceRecord {
            ev(id, range: range, semantic: sem(
                operation: .sum, role: .current, dimension: .category, label: label,
                current: value, result: value))
        }
        return [current("cur-food", "餐饮", 1_120), current("cur-transit", "交通", 886), current("cur-shopping", "购物", 342)]
    }

    /// 财务每日点：100 → 130 → 160（趋势斜率 30 元/天）。
    private static func financeDayPointsEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本月")
        let points: [(String, Double)] = [("2026-07-13", 100.0), ("2026-07-14", 130.0), ("2026-07-15", 160.0)]
        return points.map { day, value in
            ev("day-\(day)", range: range, semantic: sem(
                operation: .sum, role: .current, dimension: .day, label: day,
                current: value, result: value))
        }
    }

    /// 习惯对比：总 +5 次（晨跑 +3 / 阅读 +2），维度 habit。
    private static func habitComparisonEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本周"), base = makeRange("上周")
        func delta(_ id: String, _ label: String?, _ current: Double, _ baseValue: Double) -> HoloEvidenceRecord {
            ev(id, range: range, baselineRange: base, semantic: sem(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .difference, role: .delta, dimension: .habit, label: label,
                direction: .increase, current: current, baseline: baseValue,
                result: current - baseValue, unit: "次"))
        }
        return [delta("hab-all", nil, 14, 9), delta("hab-run", "晨跑", 8, 5), delta("hab-read", "阅读", 4, 2)]
    }

    /// 习惯现状：晨跑 5 / 阅读 4 / 冥想 3 次（ranking/breakdown 共用）。
    private static func habitGroupCurrentsEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本周")
        func current(_ id: String, _ label: String, _ value: Double) -> HoloEvidenceRecord {
            ev(id, range: range, semantic: sem(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .sum, role: .current, dimension: .habit, label: label,
                current: value, result: value, unit: "次"))
        }
        return [current("hab-run", "晨跑", 5), current("hab-read", "阅读", 4), current("hab-meditate", "冥想", 3)]
    }

    /// 习惯汇总：单一聚合 9 次 + 每日点 2/3/4（P4 修正后趋势需显式意图）。
    private static func habitTrendEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("本周")
        var evidence = [ev("hab-sum", range: range, semantic: sem(
            domain: .habit, dataset: "habit.daily", measure: .count,
            operation: .sum, role: .current, current: 9, result: 9, unit: "次"))]
        evidence += [("2026-07-13", 2.0), ("2026-07-14", 3.0), ("2026-07-15", 4.0)].map { day, value in
            ev("hab-\(day)", range: range, semantic: sem(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .sum, role: .current, dimension: .day, label: day,
                current: value, result: value, unit: "次"))
        }
        return evidence
    }

    /// 健康汇总：单一平均聚合 6,990.8 步 + 5 个每日点（固定健康工具真实形态）。
    private static func healthAverageEvidence() -> [HoloEvidenceRecord] {
        let range = makeRange("最近一个月")
        var evidence = [ev("steps-average", range: range, semantic: sem(
            domain: .health, dataset: "health.steps", measure: .steps,
            operation: .average, role: .current, current: 6_990.8, result: 6_990.8, unit: "步"))]
        evidence += [("2026-07-11", 6_200.0), ("2026-07-12", 7_100.0), ("2026-07-13", 6_800.0),
                     ("2026-07-14", 7_400.0), ("2026-07-15", 7_200.0)].map { day, value in
            ev("steps-\(day)", range: range, semantic: sem(
                domain: .health, dataset: "health.steps", measure: .steps,
                operation: .sum, role: .current, dimension: .day, label: day,
                current: value, result: value, unit: "步"))
        }
        return evidence
    }

    /// 健康趋势：聚合 + 每日点（6,200 → 7,200，斜率 250 步/天），标签为最近一周。
    private static func healthTrendEvidence() -> [HoloEvidenceRecord] {
        healthAverageEvidence().map { record in
            var copy = record
            copy.timeRange = makeRange("最近一周")
            return copy
        }
    }

    /// 健康每日点（ranking：7,400 最高）。
    private static func healthDayPointsEvidence() -> [HoloEvidenceRecord] {
        Array(healthAverageEvidence().dropFirst())
    }
}

// MARK: - 一致性矩阵（answerModeConsistency，52 条）

extension HoloAgentEvalAnswerPresentationCorpus {

    /// 财务：同义问法组（消费/支出/花费/开销/开支 × 多在哪/增加在哪/导致上涨 ×
    /// 本月对上月/最近30天对前30天/自定义区间 × 单句/追问/省略主语/口语化）+ 四模式。
    static func financeModeConsistency() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerModeConsistency
        let increaseExp = consistency(
            mode: "comparison", domain: "finance", direction: "increase", dimension: "category",
            contains: ["1,248 元", "餐饮（+620 元）", "交通（+386 元）", "购物（+242 元）"],
            group: "syn-fin-inc"
        )
        var cases: [HoloAgentEvalCase] = []
        // 同义组 syn-fin-inc（14 条）：同答案任务、同数字，问法覆盖 §10.1 全部维度。
        let increaseQueries = [
            "这个月消费比上个月多在哪儿？",      // 单句·消费
            "本月支出比上月主要多花在什么地方？",  // 支出·多花
            "最近这月开销增加是哪几类导致的？",    // 开销·什么导致上涨
            "这个月花费比上个月多在哪？",         // 花费
            "本月比上个月什么导致支出上涨？",      // 上涨
            "这个月消费跟上个月比，增加在哪里？",  // 增加在哪
            "那比上月多在哪呢？",               // 追问·省略主语
            "本月消费跟上月比涨在哪？",          // 涨
            "这个月开支比上个月多了哪些？",       // 开支
            "这月比上个月多花的钱去哪了？",       // 口语化
            "本月花费相比上月增加了什么？",
            "这个月支出比上个月多在哪类？",
            "跟上个月比呢，多花在哪？",          // 追问
            "多了哪些开销？"                   // 省略主语
        ]
        for (index, query) in increaseQueries.enumerated() {
            cases.append(makeCase(
                String(format: "amc-%03d", index + 1), category: category, query: query,
                evidence: financeIncreaseEvidence(), expectation: increaseExp
            ))
        }

        // 同义组 syn-fin-dec（5 条）：下降方向收敛。
        let decreaseExp = consistency(
            mode: "comparison", domain: "finance", direction: "decrease", dimension: "category",
            contains: ["减少 800 元", "餐饮（-500 元）", "交通（-300 元）"],
            group: "syn-fin-dec"
        )
        let decreaseQueries = [
            "这个月消费比上个月少在哪？",
            "本月支出比上月减少的部分主要是哪些？",
            "最近这月开销降在什么地方？",
            "这个月花费比上个月少了什么？",
            "本月比上个月少花在哪几类？"
        ]
        for (offset, query) in decreaseQueries.enumerated() {
            cases.append(makeCase(
                String(format: "amc-%03d", 15 + offset), category: category, query: query,
                evidence: financeDecreaseEvidence(), expectation: decreaseExp
            ))
        }

        // 同义组 syn-fin-rate（3 条）：「涨幅最高」按变化率排序。
        let rateExp = consistency(
            mode: "comparison", domain: "finance", direction: "increase", dimension: "category",
            contains: ["购物（+242%）", "交通（+77.2%）"],
            group: "syn-fin-rate"
        )
        let rateQueries = [
            "这个月哪类消费涨幅最高？",
            "本月支出涨幅最大的是哪类？",
            "哪类开销的涨幅排第一？"
        ]
        for (offset, query) in rateQueries.enumerated() {
            cases.append(makeCase(
                String(format: "amc-%03d", 20 + offset), category: category, query: query,
                evidence: financeRateEvidence(), expectation: rateExp
            ))
        }

        // 同义组 syn-fin-custom（3 条）：自定义区间/最近30天对前30天，rangeLabel 允许不同、数字必须一致。
        let customExp = consistency(
            mode: "comparison", domain: "finance", direction: "increase", dimension: "category",
            contains: ["1,248 元", "餐饮（+620 元）"],
            group: "syn-fin-custom"
        )
        cases.append(makeCase("amc-023", category: category, query: "6月1日到6月30日的消费比5月多在哪？",
                              evidence: financeIncreaseEvidence(range: "6月", baseline: "5月"), expectation: customExp))
        cases.append(makeCase("amc-024", category: category, query: "最近30天对前30天，支出增加在哪？",
                              evidence: financeIncreaseEvidence(range: "最近30天", baseline: "前30天"), expectation: customExp))
        cases.append(makeCase("amc-025", category: category, query: "4月比3月哪类花得多？",
                              evidence: financeIncreaseEvidence(range: "4月", baseline: "3月"), expectation: customExp))

        // 财务 lookup / ranking / breakdown / trend。
        cases.append(makeCase("amc-026", category: category, query: "这个月花了多少钱？",
                              evidence: financeSingleCurrentEvidence(),
                              expectation: consistency(mode: "lookup", domain: "finance", contains: ["3,248.5 元"])))
        cases.append(makeCase("amc-027", category: category, query: "本月哪类支出最多？",
                              evidence: financeCategoryCurrentsEvidence(),
                              expectation: consistency(mode: "ranking", domain: "finance", direction: "increase",
                                                       dimension: "category", contains: ["餐饮（1,120 元）", "交通（886 元）"])))
        cases.append(makeCase("amc-028", category: category, query: "本月支出都花在了哪些类别？",
                              evidence: financeCategoryCurrentsEvidence(),
                              expectation: consistency(mode: "breakdown", domain: "finance", dimension: "category",
                                                       contains: ["共 2,348 元", "餐饮（1,120 元）"])))
        cases.append(makeCase("amc-029", category: category, query: "最近支出趋势怎么样？",
                              evidence: financeDayPointsEvidence(),
                              expectation: consistency(mode: "trend", domain: "finance", contains: ["上升趋势", "30 元"])))
        return cases
    }

    /// 习惯：lookup / comparison / ranking / breakdown / trend 全组合。
    static func habitModeConsistency() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerModeConsistency
        let increaseExp = consistency(
            mode: "comparison", domain: "habit", direction: "increase", dimension: "habit",
            contains: ["增加 5 次", "晨跑（+3 次）"], group: "syn-hab-inc"
        )
        let rankExp = consistency(
            mode: "ranking", domain: "habit", dimension: "habit",
            contains: ["晨跑（5 次）", "阅读（4 次）"], group: "syn-hab-rank"
        )
        let trendExp = consistency(
            mode: "trend", domain: "habit",
            contains: ["上升趋势", "1 次"], group: "syn-hab-trend"
        )
        return [
            makeCase("amc-030", category: category, query: "本周冥想打卡了几次？",
                     evidence: [ev("hab-single", range: makeRange("本周"), semantic: sem(
                        domain: .habit, dataset: "habit.daily", measure: .count,
                        operation: .sum, role: .current, current: 6, result: 6, unit: "次"))],
                     expectation: consistency(mode: "lookup", domain: "habit", contains: ["6 次"])),
            makeCase("amc-031", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(), expectation: increaseExp),
            makeCase("amc-032", category: category, query: "这周习惯完成比上周增加在哪些习惯上？",
                     evidence: habitComparisonEvidence(), expectation: increaseExp),
            makeCase("amc-033", category: category, query: "本周哪个习惯坚持得最好？",
                     evidence: habitGroupCurrentsEvidence(), expectation: rankExp),
            makeCase("amc-034", category: category, query: "本周习惯排名前三是哪些？",
                     evidence: habitGroupCurrentsEvidence(), expectation: rankExp),
            makeCase("amc-035", category: category, query: "最近习惯打卡趋势如何？",
                     evidence: habitTrendEvidence(), expectation: trendExp),
            makeCase("amc-036", category: category, query: "最近打卡次数有什么变化？",
                     evidence: habitTrendEvidence(), expectation: trendExp),
            makeCase("amc-037", category: category, query: "本周各项习惯完成情况如何拆解？",
                     evidence: habitGroupCurrentsEvidence(),
                     expectation: consistency(mode: "breakdown", domain: "habit", dimension: "habit",
                                              contains: ["共 12 次", "晨跑（5 次）"]))
        ]
    }

    /// 任务：lookup / comparison / trend（任务 schema 无业务分组字段，ranking/breakdown 不适用）。
    static func taskModeConsistency() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerModeConsistency
        let comparisonExp = consistency(
            mode: "comparison", domain: "task",
            contains: ["增加 4 个"], group: "syn-task-cmp"
        )
        let range = makeRange("本周"), base = makeRange("上周")
        return [
            makeCase("amc-038", category: category, query: "本周完成了多少个任务？",
                     evidence: [ev("task-sum", range: range, semantic: sem(
                        domain: .task, dataset: "task.daily", measure: .count,
                        operation: .sum, role: .current, current: 12, result: 12, unit: "个"))],
                     expectation: consistency(mode: "lookup", domain: "task", contains: ["12 个"])),
            makeCase("amc-039", category: category, query: "本周任务完成比上周变化如何？",
                     evidence: [ev("task-delta", range: range, baselineRange: base, semantic: sem(
                        domain: .task, dataset: "task.daily", measure: .count,
                        operation: .difference, role: .delta, direction: .increase,
                        current: 12, baseline: 8, result: 4, unit: "个"))],
                     expectation: comparisonExp),
            makeCase("amc-040", category: category, query: "这周任务数比上周怎么样？",
                     evidence: [ev("task-delta", range: range, baselineRange: base, semantic: sem(
                        domain: .task, dataset: "task.daily", measure: .count,
                        operation: .difference, role: .delta, direction: .increase,
                        current: 12, baseline: 8, result: 4, unit: "个"))],
                     expectation: comparisonExp),
            makeCase("amc-041", category: category, query: "最近任务完成趋势怎么样？",
                     evidence: [ev("task-total", range: range, semantic: sem(
                        domain: .task, dataset: "task.daily", measure: .count,
                        operation: .sum, role: .current, current: 12, result: 12, unit: "个"))]
                        + [("2026-07-13", 3.0), ("2026-07-14", 4.0), ("2026-07-15", 5.0)].map { day, value in
                            ev("task-\(day)", range: range, semantic: sem(
                                domain: .task, dataset: "task.daily", measure: .count,
                                operation: .sum, role: .current, dimension: .day, label: day,
                                current: value, result: value, unit: "个"))
                        },
                     expectation: consistency(mode: "trend", domain: "task", contains: ["上升趋势"]))
        ]
    }

    /// 健康：lookup（平均/日均同义 + 睡眠）/ comparison / trend / ranking。
    static func healthModeConsistency() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerModeConsistency
        let averageExp = consistency(
            mode: "lookup", domain: "health",
            contains: ["6,991 步"], group: "syn-health-avg"
        )
        let trendExp = consistency(
            mode: "trend", domain: "health",
            contains: ["上升趋势", "250 步"], group: "syn-health-trend"
        )
        return [
            // P4 修正回归：平均/日均/口语化问法 + 汇总证据 → lookup 聚合值，不派生 trend。
            makeCase("amc-042", category: category, query: "最近一个月平均步数是多少？",
                     evidence: healthAverageEvidence(), expectation: averageExp),
            makeCase("amc-043", category: category, query: "最近日均步数多少？",
                     evidence: healthAverageEvidence(), expectation: averageExp),
            makeCase("amc-044", category: category, query: "步数最近咋走？",
                     evidence: healthAverageEvidence(), expectation: averageExp),
            makeCase("amc-045", category: category, query: "本周平均睡眠几小时？",
                     evidence: [ev("sleep-avg", range: makeRange("本周"), semantic: sem(
                        domain: .health, dataset: "health.sleep", measure: .durationHours,
                        operation: .average, role: .current, current: 7.2, result: 7.2, unit: "小时"))],
                     expectation: consistency(mode: "lookup", domain: "health", contains: ["7.2 小时"])),
            makeCase("amc-046", category: category, query: "最近一周步数趋势如何？",
                     evidence: healthTrendEvidence(), expectation: trendExp),
            makeCase("amc-047", category: category, query: "最近步数有什么变化？",
                     evidence: healthTrendEvidence(), expectation: trendExp),
            makeCase("amc-048", category: category, query: "本周步数和上周相比如何？",
                     evidence: [ev("steps-delta", range: makeRange("本周"), baselineRange: makeRange("上周"),
                                   semantic: sem(domain: .health, dataset: "health.steps", measure: .steps,
                                                 operation: .difference, role: .delta, direction: .increase,
                                                 current: 85_200, baseline: 80_000, result: 5_200, unit: "步"))],
                     expectation: consistency(mode: "comparison", domain: "health", contains: ["5,200 步"])),
            makeCase("amc-049", category: category, query: "最近哪天步数最多？",
                     evidence: healthDayPointsEvidence(),
                     expectation: consistency(mode: "ranking", domain: "health", direction: "increase",
                                              dimension: "day", contains: ["7,400 步"]))
        ]
    }

    /// 目标与跨域关联。
    static func goalAndCorrelationConsistency() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerModeConsistency
        let range = makeRange("本月")
        return [
            makeCase("amc-050", category: category, query: "本月目标进度怎么样？",
                     evidence: [ev("goal-progress", range: range, semantic: sem(
                        domain: .goal, dataset: "goal.progress", measure: .ratio,
                        operation: .average, role: .current, current: 0.65, result: 0.65, unit: "%"))],
                     expectation: consistency(mode: "lookup", domain: "goal", contains: ["占比"])),
            makeCase("amc-051", category: category, query: "哪个目标进度最高？",
                     evidence: [("fitness", "健身", 0.8), ("reading", "阅读", 0.5), ("saving", "储蓄", 0.3)].map { id, label, value in
                        ev("goal-\(id)", range: range, semantic: sem(
                            domain: .goal, dataset: "goal.progress", measure: .ratio,
                            operation: .average, role: .current, dimension: .category, label: label,
                            current: value, result: value, unit: "%"))
                     },
                     expectation: consistency(mode: "ranking", domain: "goal", dimension: "category",
                                              contains: ["健身（0.8 %）"])),
            makeCase("amc-052", category: category, query: "最近运动和睡眠有关联吗？",
                     evidence: [ev("corr", range: makeRange("最近一周"), semantic: sem(
                        domain: .health, dataset: "health.cross", measure: .correlation,
                        operation: .correlation, role: .current, current: 0.82, result: 0.82, unit: "相关系数"))],
                     expectation: consistency(mode: "correlation", domain: "health",
                                              contains: ["相关系数为 0.82", "不表示因果"]))
        ]
    }
}

// MARK: - 鲁棒性矩阵（answerPresentationRobustness，40 条）

extension HoloAgentEvalAnswerPresentationCorpus {

    /// 边界样例（§10.3）：零基准 / 双零 / 缺失分类名 / 增量并列 / 总增组减 /
    /// 24/31 天覆盖 / NaN / 负值 / 单位缺失。
    static func boundaryRobustness() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerPresentationRobustness
        let range = makeRange("本月"), base = makeRange("上月")

        func delta(_ id: String, _ label: String?, _ current: Double, _ baseValue: Double,
                   direction: HoloMetricDirection? = nil) -> HoloEvidenceRecord {
            ev(id, range: range, baselineRange: base, semantic: sem(
                operation: .difference, role: .delta, dimension: .category, label: label,
                direction: direction ?? (current > baseValue ? .increase : (current < baseValue ? .decrease : .flat)),
                current: current, baseline: baseValue, result: current - baseValue))
        }

        // 零基准变化率 + 双零持平组（取自 §10.3 组合）
        let zeroBaselineEvidence: [HoloEvidenceRecord] = [
            ev("zr-food", range: range, baselineRange: base, semantic: sem(
                measure: .ratio, operation: .percentageChange, role: .changeRate,
                dimension: .category, label: "餐饮", direction: .increase,
                current: 620, baseline: 500, result: 0.243, unit: "比例")),
            delta("zd-food", "餐饮", 620, 500),
            ev("zr-fun", range: range, baselineRange: base, semantic: sem(
                measure: .ratio, operation: .percentageChange, role: .changeRate,
                dimension: .category, label: "娱乐", direction: .increase,
                current: 200, baseline: 0, result: 2.0, unit: "比例")),
            delta("zd-fun", "娱乐", 200, 0),
            delta("zd-idle", "闲置", 0, 0)
        ]

        return [
            // 基准为 0：百分比无意义，回退绝对变化
            makeCase("apr-001", category: category, query: "哪些支出涨幅最高？",
                     evidence: zeroBaselineEvidence,
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["餐饮（+24.3%）", "娱乐（+200 元）"],
                                        directAnswerMustNotContain: ["200%", "闲置"])),
            // 单组零基准：贡献占比仍可读，无 inf
            makeCase("apr-002", category: category, query: "本月娱乐支出比上月多了多少？",
                     evidence: [delta("fun-only", "娱乐", 300, 0)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 300 元", "娱乐（+300 元）"],
                                        directAnswerMustNotContain: ["inf", "nan"])),
            // 当前和基准都为 0：明确说基本持平
            makeCase("apr-003", category: category, query: "本月消费和上月相比怎么样？",
                     evidence: [delta("zz-all", nil, 0, 0), delta("zz-food", "餐饮", 0, 0), delta("zz-transit", "交通", 0, 0)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["基本持平"],
                                        directAnswerMustNotContain: ["nan", "inf"])),
            // 持平分组不出现在明细
            makeCase("apr-004", category: category, query: "本月支出比上月变化如何？",
                     evidence: [delta("zf-all", nil, 1_200, 1_000), delta("zf-food", "餐饮", 1_200, 1_000), delta("zf-idle", "闲置", 0, 0)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 200 元", "餐饮（+200 元）"],
                                        directAnswerMustNotContain: ["闲置"])),
            // 缺失分类名（空串）：跳过，不硬凑
            makeCase("apr-005", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: [delta("ml-all", nil, 3_700, 3_200), delta("ml-empty", "", 300, 0), delta("ml-food", "餐饮", 700, 500)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 500 元", "餐饮（+200 元）"],
                                        directAnswerMustNotContain: ["+300"])),
            // 分类名含控制字符：转义清理后展示
            makeCase("apr-006", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: [delta("cc-all", nil, 400, 200), delta("cc-food", "餐\u{0}饮", 400, 200)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["餐饮（+200 元）"],
                                        userTextsMustNotContain: ["\u{0}"])),
            // 增量并列：按 groupLabel 字典序稳定（交通 < 餐饮），与输入顺序无关
            makeCase("apr-007", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: [delta("tie-transit", "交通", 800, 500), delta("tie-food", "餐饮", 800, 500)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 600 元", "交通（+300 元）和餐饮（+300 元）"])),
            makeCase("apr-008", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: [delta("tie2-food", "餐饮", 800, 500), delta("tie2-transit", "交通", 800, 500)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 600 元", "交通（+300 元）和餐饮（+300 元）"])),
            // 总增组减：必须说明抵消项
            makeCase("apr-009", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: [delta("of-all", nil, 2_500, 1_500), delta("of-food", "餐饮", 2_300, 1_000), delta("of-transit", "交通", 200, 500)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 1,000 元", "交通减少 300 元，抵消了部分增量"])),
            // 总减组增：反向抵消项
            makeCase("apr-010", category: category, query: "本月消费比上个月少在哪？",
                     evidence: [delta("od-all", nil, 500, 1_500), delta("od-food", "餐饮", 200, 1_500), delta("od-transit", "交通", 800, 500)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["减少 1,000 元", "交通增加 300 元，抵消了部分减量"])),
            // 覆盖 24/31 天：必须披露
            makeCase("apr-011", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(), coverage: coverage(24, 31),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        mustDiscloseCoverage: true)),
            // 完整覆盖 31/31：披露但不告警
            makeCase("apr-012", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(), coverage: coverage(31, 31),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        mustDiscloseCoverage: true)),
            // 覆盖 12/31（<0.6）：披露 + 限制说明
            makeCase("apr-013", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(), coverage: coverage(12, 31),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        mustDiscloseCoverage: true,
                                        limitationsMustContain: ["数据覆盖不足"])),
            // 习惯域低覆盖：同一披露规则跨域复用
            makeCase("apr-014", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(), coverage: coverage(10, 30),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "habit",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 5 次"],
                                        mustDiscloseCoverage: true,
                                        limitationsMustContain: ["数据覆盖不足"])),
            // NaN / 无穷分组被过滤，有限值正常展示
            makeCase("apr-015", category: category, query: "多在哪儿",
                     evidence: [delta("nan-all", nil, 342, 100),
                                ev("nan-a", range: range, baselineRange: base, semantic: sem(
                                    operation: .difference, role: .delta, dimension: .category, label: "餐饮",
                                    current: .nan, baseline: 500, result: .nan)),
                                ev("nan-b", range: range, baselineRange: base, semantic: sem(
                                    operation: .difference, role: .delta, dimension: .category, label: "交通",
                                    current: .infinity, baseline: 500, result: .infinity)),
                                delta("nan-good", "购物", 342, 100)],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["购物（+242 元）"],
                                        userTextsMustNotContain: ["nan", "inf", "餐饮", "交通"])),
            // 全部 NaN/无穷：合成器放弃，走兼容兜底且不泄露 nan/inf
            makeCase("apr-016", category: category, query: "多在哪儿",
                     evidence: [ev("bad-a", range: range, baselineRange: base, semantic: sem(
                                    operation: .difference, role: .delta, dimension: .category, label: "餐饮",
                                    current: .nan, baseline: 500, result: .nan)),
                                ev("bad-b", range: range, baselineRange: base, semantic: sem(
                                    operation: .difference, role: .delta, dimension: .category, label: "交通",
                                    current: .infinity, baseline: 500, result: .infinity))],
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: false,
                                        userTextsMustNotContain: ["nan", "inf"])),
            // 负值正常展示
            makeCase("apr-017", category: category, query: "本月账户余额是多少？",
                     evidence: [ev("neg", range: range, semantic: sem(
                        operation: .sum, role: .current, current: -50, result: -50))],
                     expectation: .init(expectedMode: "lookup", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["-50 元"])),
            // 单位缺失：不拼 nil/空单位
            makeCase("apr-018", category: category, query: "本月记录数是多少？",
                     evidence: [ev("no-unit", range: range, semantic: sem(
                        domain: .agent, dataset: "agent.runs", measure: .none,
                        operation: .count, role: .current, current: 42, result: 42, unit: nil))],
                     expectation: .init(expectedMode: "lookup", expectedDomain: "agent",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["该指标 42"],
                                        directAnswerMustNotContain: ["nan", "nil"]))
        ]
    }

    /// 旧证据（无 semantic）兼容兜底 + 可观测指标。
    static func legacyAndObservabilityRobustness() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerPresentationRobustness
        let legacyFinance = [legacyEvidence(
            id: "legacy-fin", metricKey: "finance.total.amount", value: 3_200, unit: "元",
            module: .finance, rangeLabel: "本月", excerpt: "本月总支出 3,200 元"
        )]
        return [
            // 旧证据：不派生 AnswerTask、合成器放弃，走兼容目录；agent.semantic.missing +1
            makeCase("apr-019", category: category, query: "本月消费多少",
                     evidence: legacyFinance,
                     expectation: .init(expectedMode: "nil", expectComposedDirectAnswer: false,
                                        directAnswerMustContain: ["3,200"],
                                        expectedObservabilityMetric: "agent.semantic.missing")),
            // 旧目录可识别并兼容适配：agent.semantic.legacy_fallback +1
            makeCase("apr-020", category: category, query: "这个月总支出",
                     evidence: legacyFinance,
                     expectation: .init(expectedMode: "nil", expectComposedDirectAnswer: false,
                                        directAnswerMustContain: ["3,200"],
                                        expectedObservabilityMetric: "agent.semantic.legacy_fallback")),
            // 旧健康证据：目录特化句式兜底
            makeCase("apr-021", category: category, query: "最近一个月平均步数是多少？",
                     evidence: [legacyEvidence(
                        id: "legacy-steps", metricKey: "health.steps.average", value: 6_990.8, unit: "步",
                        module: .health, rangeLabel: "最近一个月", excerpt: "步数汇总"
                     )],
                     expectation: .init(expectedMode: "nil", expectComposedDirectAnswer: false,
                                        directAnswerMustContain: ["日均", "6,991"])),
            // 旧证据 + 部分覆盖：覆盖度仍按统一规则披露
            makeCase("apr-022", category: category, query: "本月消费多少",
                     evidence: legacyFinance, coverage: coverage(24, 31),
                     expectation: .init(expectedMode: "nil", expectComposedDirectAnswer: false,
                                        directAnswerMustContain: ["3,200"],
                                        mustDiscloseCoverage: true)),
            // 带语义证据：agent.answer.composer_used +1
            makeCase("apr-040", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        expectedObservabilityMetric: "agent.answer.composer_used"))
        ]
    }

    /// 坏模型文案：错标题 / 错单位 / 错数字 / 内部 key / 公式 / 乱码 / 无证据结论 /
    /// 方向矛盾 / 编造分组，最终数字结论不受影响（发布门槛 5）。
    static func badModelTextRobustness() -> [HoloAgentEvalCase] {
        let category = HoloAgentEvalCategory.answerPresentationRobustness
        let taskDeltaEvidence = [ev("task-delta", range: makeRange("本周"), baselineRange: makeRange("上周"),
                                    semantic: sem(domain: .task, dataset: "task.daily", measure: .count,
                                                  operation: .difference, role: .delta, direction: .increase,
                                                  current: 12, baseline: 8, result: 4, unit: "个"))]
        return [
            // 内部占位词（截图事故原文）：被拦截，directAnswer 由合成器产出
            makeCase("apr-023", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "finance",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        userTextsMustNotContain: ["计算结果", "24.3 比例", "dynamic.", "difference("],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "计算结果 24.3 比例",
                                        expectedObservabilityMetric: "agent.answer.internal_token_blocked")),
            // 内部 metricKey：被拦截并计数 model_text_discarded
            makeCase("apr-024", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(),
                     expectation: .init(expectedMode: "comparison", expectedDomain: "habit",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 5 次"],
                                        userTextsMustNotContain: ["dynamic."],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "dynamic.habit_daily.delta = 5",
                                        expectedObservabilityMetric: "agent.answer.model_text_discarded")),
            // 健康域内部占位词：同一拦截规则跨域复用
            makeCase("apr-025", category: category, query: "最近一个月平均步数是多少？",
                     evidence: healthAverageEvidence(),
                     expectation: .init(expectedMode: "lookup", expectedDomain: "health",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["6,991 步"],
                                        userTextsMustNotContain: ["计算结果"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "计算结果 6,990.8 比例")),
            // 任务域内部占位词
            makeCase("apr-026", category: category, query: "本周任务完成比上周变化如何？",
                     evidence: taskDeltaEvidence,
                     expectation: .init(expectedMode: "comparison", expectedDomain: "task",
                                        expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 4 个"],
                                        userTextsMustNotContain: ["计算结果"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "计算结果 4 比例")),
            // 半角公式调用：被拦截
            makeCase("apr-027", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        userTextsMustNotContain: ["difference("],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "difference(spend) = 1248")),
            makeCase("apr-028", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 5 次"],
                                        userTextsMustNotContain: ["sum("],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "sum(amount) 已算出")),
            // 错数字：验证判 pass（解释层保留），但数字结论只认合成器
            makeCase("apr-029", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        directAnswerMustNotContain: ["12,480"],
                                        expectedVerifier: "pass",
                                        modelDisplayText: "本月总支出 12,480 元，比上月翻了三倍。")),
            // 错单位：结论单位只认语义
            makeCase("apr-030", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        directAnswerMustNotContain: ["美元"],
                                        expectedVerifier: "pass",
                                        modelDisplayText: "本月支出 1,248 美元")),
            // 乱码 + 占位词：随内部 token 一并清除
            makeCase("apr-031", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        userTextsMustNotContain: ["计算结果", "�"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "计算结果 �� 支出异常")),
            // 无证据却给数字结论：failed → 边界说明，coverage_failed +1
            makeCase("apr-032", category: category, query: "本月消费多少",
                     evidence: [],
                     expectation: .init(directAnswerMustContain: ["没能形成可信结论"],
                                        userTextsMustNotContain: ["3,200"],
                                        expectedVerifier: "failed",
                                        modelDisplayText: "本月支出 3,200 元",
                                        expectedObservabilityMetric: "agent.answer.coverage_failed")),
            makeCase("apr-033", category: category, query: "最近步数怎么样",
                     evidence: [],
                     expectation: .init(directAnswerMustContain: ["没能形成可信结论"],
                                        userTextsMustNotContain: ["8,500"],
                                        expectedVerifier: "failed",
                                        modelDisplayText: "最近步数 8,500 步")),
            makeCase("apr-034", category: category, query: "本周打卡几次",
                     evidence: [],
                     expectation: .init(directAnswerMustContain: ["没能形成可信结论"],
                                        userTextsMustNotContain: ["20 次"],
                                        expectedVerifier: "failed",
                                        modelDisplayText: "本周打卡 20 次")),
            // 方向矛盾：可修复，矛盾句被丢弃
            makeCase("apr-035", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        userTextsMustNotContain: ["餐饮减少 620"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "餐饮增加 620 元；餐饮减少 620 元。")),
            makeCase("apr-036", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 5 次"],
                                        userTextsMustNotContain: ["晨跑减少"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "晨跑增加 3 次，晨跑减少 3 次")),
            // 编造分组：可修复，编造内容被丢弃
            makeCase("apr-037", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["餐饮（+620 元）"],
                                        userTextsMustNotContain: ["零食"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "本月支出增加，主要来自零食（+999 元）。")),
            makeCase("apr-038", category: category, query: "本周习惯打卡比上周多在哪？",
                     evidence: habitComparisonEvidence(),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["增加 5 次"],
                                        userTextsMustNotContain: ["打游戏"],
                                        expectedVerifier: "recoverable",
                                        modelDisplayText: "主要来自打游戏（+9 次）")),
            // 覆盖不足未披露：可修复，修复后强制披露
            makeCase("apr-039", category: category, query: "这个月消费比上个月多在哪儿？",
                     evidence: financeIncreaseEvidence(), coverage: coverage(24, 31),
                     expectation: .init(expectComposedDirectAnswer: true,
                                        directAnswerMustContain: ["1,248 元"],
                                        expectedVerifier: "recoverable",
                                        mustDiscloseCoverage: true,
                                        modelDisplayText: "本月支出比上月增加。"))
        ]
    }

    /// 旧证据（无 semantic）：模拟历史持久化记录。
    private static func legacyEvidence(
        id: String, metricKey: String, value: Double, unit: String,
        module: HoloEvidenceSourceModule, rangeLabel: String, excerpt: String
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id, dedupeKey: id, sourceModule: module, sourceID: nil,
            sourceKind: "aggregate", timeRange: makeRange(rangeLabel), occurredAt: nil,
            metricKey: metricKey, metricValue: value, unit: unit,
            baselineValue: nil, comparison: nil,
            excerpt: excerpt, redactedExcerpt: excerpt,
            sensitivity: .normal, confidence: 0.9, status: .active,
            generatedBy: "eval-fixture", generatedAt: Date(timeIntervalSince1970: 2_000),
            referencedByJobIDs: [], referencedByMemoryIDs: [], deviceID: nil
        )
    }
}
