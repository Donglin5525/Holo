//
//  HoloAnswerCrossDomainStandaloneTests.swift
//  HoloTests
//
//  Agent 统一结果语义契约 P3 — 跨领域合成复用与新旧输出对照独立测试，
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
//    "HoloTests/Services/AI/Agent/HoloAnswerCrossDomainStandaloneTests.swift" \
//    -o /tmp/holo_cross_domain_answer_test && /tmp/holo_cross_domain_answer_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloAnswerCrossDomainStandaloneTests.main()
    }
}
#endif

struct HoloAnswerCrossDomainStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        HoloAgentResultSemanticsFlags.typedSemanticsEnabled = true
        HoloAgentResultSemanticsFlags.deterministicComposerEnabled = true

        test比较操作跨四领域同一合成器()
        test拆解与排名跨领域复用()
        test趋势跨领域复用()
        try test新旧对照截图案例财务()
        try test新旧对照习惯任务健康()
        print("HoloAnswerCrossDomainStandaloneTests passed")
    }

    // MARK: - a) comparison：金额/次数/完成数/时长 delta 走同一合成器

    /// 同一种 comparison 操作跨财务、习惯、任务、健康四个领域：
    /// 输出结构一致（范围+名词+比基准+增加+总量+主要来自+贡献占比），名词与单位各自正确。
    private static func test比较操作跨四领域同一合成器() {
        struct Case {
            let domain: HoloEvidenceSourceModule
            let dataset: String
            let measure: HoloMetricMeasure
            let dimension: HoloMetricDimension
            let unit: String
            let range: String
            let baseline: String
            let noun: String
            let all: (current: Double, base: Double)
            let groups: [(label: String, current: Double, base: Double)]
            let topLabel: String
            let secondLabel: String
        }
        let cases: [Case] = [
            // 财务：金额 delta（支出/元）
            Case(domain: .finance, dataset: "finance.transactions", measure: .amount,
                 dimension: .category, unit: "元", range: "本月", baseline: "上月", noun: "支出",
                 all: (2_300, 2_000), groups: [("餐饮", 620, 500), ("交通", 680, 500)],
                 topLabel: "交通", secondLabel: "餐饮"),
            // 习惯：次数 delta（完成次数/次）
            Case(domain: .habit, dataset: "habit.daily", measure: .count,
                 dimension: .habit, unit: "次", range: "最近一周", baseline: "上期", noun: "完成次数",
                 all: (18, 10), groups: [("熬夜", 8, 3), ("刷手机", 10, 7)],
                 topLabel: "熬夜", secondLabel: "刷手机"),
            // 任务：完成数 delta（任务/个）
            Case(domain: .task, dataset: "task.daily", measure: .count,
                 dimension: .day, unit: "个", range: "本周", baseline: "上期", noun: "任务",
                 all: (16, 10), groups: [("周一", 6, 4), ("周三", 10, 6)],
                 topLabel: "周三", secondLabel: "周一"),
            // 健康：时长 delta（时长/小时）
            Case(domain: .health, dataset: "health.sleep", measure: .durationHours,
                 dimension: .day, unit: "小时", range: "最近一周", baseline: "上期", noun: "时长",
                 all: (16, 14), groups: [("周二", 7.2, 6), ("周四", 8.8, 8)],
                 topLabel: "周二", secondLabel: "周四")
        ]

        var answers: [String] = []
        for entry in cases {
            var evidence = [
                makeEvidence(
                    id: "\(entry.domain)-all", range: entry.range, baselineRange: entry.baseline,
                    semantic: makeSemantic(
                        domain: entry.domain, dataset: entry.dataset, measure: entry.measure,
                        operation: .difference, valueRole: .delta, dimension: entry.dimension,
                        groupLabel: nil, direction: .increase,
                        current: entry.all.current, baseline: entry.all.base,
                        result: entry.all.current - entry.all.base, unit: entry.unit
                    )
                )
            ]
            evidence += entry.groups.map { group in
                makeEvidence(
                    id: "\(entry.domain)-\(group.label)", range: entry.range, baselineRange: entry.baseline,
                    semantic: makeSemantic(
                        domain: entry.domain, dataset: entry.dataset, measure: entry.measure,
                        operation: .difference, valueRole: .delta, dimension: entry.dimension,
                        groupLabel: group.label, direction: .increase,
                        current: group.current, baseline: group.base,
                        result: group.current - group.base, unit: entry.unit
                    )
                )
            }
            let task = HoloAnswerTaskDeriver.derive(question: "多在哪儿？", evidence: evidence)
            expect(task?.mode == .comparison, "\(entry.domain) 应为 comparison，实际 \(String(describing: task?.mode))")
            expect(task?.domain == entry.domain && task?.measure == entry.measure,
                   "\(entry.domain) 任务主语义错误：\(String(describing: task))")

            let composed = HoloDeterministicAnswerComposer.compose(task: task!, evidence: evidence, coverage: nil)
            let answer = composed?.directAnswer ?? ""
            answers.append(answer)
            let totalText = HoloDeterministicAnswerComposer.format(
                entry.all.current - entry.all.base, unit: entry.unit, measure: entry.measure
            )
            let ranked = entry.groups.sorted { abs($0.current - $0.base) > abs($1.current - $1.base) }
            expect(ranked[0].label == entry.topLabel && ranked[1].label == entry.secondLabel,
                   "\(entry.domain) fixture 排序预期错误，请调整 topLabel/secondLabel")
            let topDelta = ranked[0].current - ranked[0].base
            let secondDelta = ranked[1].current - ranked[1].base
            let topText = HoloDeterministicAnswerComposer.format(abs(topDelta), unit: entry.unit, measure: entry.measure)
            let secondText = HoloDeterministicAnswerComposer.format(abs(secondDelta), unit: entry.unit, measure: entry.measure)
            expect(answer.hasPrefix("\(entry.range)\(entry.noun)比\(entry.baseline)增加 \(totalText) \(entry.unit)"),
                   "\(entry.domain) 结论开头结构/名词/单位错误：\(answer)")
            expect(answer.contains("主要来自"), "\(entry.domain) 缺少排名段：\(answer)")
            expect(answer.contains("\(entry.topLabel)（+\(topText) \(entry.unit)）"),
                   "\(entry.domain) 榜首项错误：\(answer)")
            expect(answer.contains("\(entry.secondLabel)（+\(secondText) \(entry.unit)）"),
                   "\(entry.domain) 第二项错误：\(answer)")
            expect(answer.contains("贡献了总增量的"), "\(entry.domain) 缺少贡献占比：\(answer)")
            expect(!HoloMetricSemanticCatalog.containsInternalToken(answer),
                   "\(entry.domain) 结论含内部 token：\(answer)")
        }

        // 结构一致：四条结论共享同一句式骨架（范围+名词+比基准+增加+总量+主要来自）。
        for answer in answers {
            expect(answer.contains("比") && answer.contains("增加 ") && answer.contains("，主要来自"),
                   "跨领域结论句式骨架必须一致：\(answer)")
        }
    }

    // MARK: - b) breakdown / ranking 跨领域

    private static func test拆解与排名跨领域复用() {
        // 财务 breakdown：支出去向（dimension=category）
        let financeCurrents = [
            makeEvidence(id: "f-food", range: "本月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .sum, valueRole: .current, dimension: .category,
                groupLabel: "餐饮", direction: nil, current: 600, baseline: nil, result: 600, unit: "元"
            )),
            makeEvidence(id: "f-transit", range: "本月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .sum, valueRole: .current, dimension: .category,
                groupLabel: "交通", direction: nil, current: 400, baseline: nil, result: 400, unit: "元"
            )),
            makeEvidence(id: "f-shopping", range: "本月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .sum, valueRole: .current, dimension: .category,
                groupLabel: "购物", direction: nil, current: 200, baseline: nil, result: 200, unit: "元"
            ))
        ]
        let breakdownTask = HoloAnswerTaskDeriver.derive(question: "这个月钱花在哪了？", evidence: financeCurrents)
        expect(breakdownTask?.mode == .breakdown, "无排名词应为 breakdown，实际 \(String(describing: breakdownTask?.mode))")
        let breakdown = HoloDeterministicAnswerComposer.compose(task: breakdownTask!, evidence: financeCurrents, coverage: nil)
        expect(
            breakdown?.directAnswer == "本月支出共 1,200 元，主要来自餐饮（600 元）、交通（400 元）和购物（200 元）。",
            "财务 breakdown 输出错误：\(breakdown?.directAnswer ?? "nil")"
        )

        // 财务 ranking：同一组证据，问法带「最」即切 ranking，规则零改动
        let rankingTask = HoloAnswerTaskDeriver.derive(question: "哪个分类支出最多？", evidence: financeCurrents)
        expect(rankingTask?.mode == .ranking, "带「最」应为 ranking，实际 \(String(describing: rankingTask?.mode))")
        let ranking = HoloDeterministicAnswerComposer.compose(task: rankingTask!, evidence: financeCurrents, coverage: nil)
        expect(
            ranking?.directAnswer == "本月支出最高的是餐饮（600 元）、交通（400 元）和购物（200 元）。",
            "财务 ranking 输出错误：\(ranking?.directAnswer ?? "nil")"
        )

        // 习惯 breakdown：完成分布（dimension=habit）
        let habitCurrents = [
            makeEvidence(id: "h-run", range: "最近一周", semantic: makeSemantic(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .habit,
                groupLabel: "晨跑", direction: nil, current: 5, baseline: nil, result: 5, unit: "次"
            )),
            makeEvidence(id: "h-read", range: "最近一周", semantic: makeSemantic(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .habit,
                groupLabel: "阅读", direction: nil, current: 3, baseline: nil, result: 3, unit: "次"
            ))
        ]
        let habitTask = HoloAnswerTaskDeriver.derive(question: "这段时间习惯完成分布如何？", evidence: habitCurrents)
        expect(habitTask?.mode == .breakdown, "习惯分布应为 breakdown，实际 \(String(describing: habitTask?.mode))")
        let habitAnswer = HoloDeterministicAnswerComposer.compose(task: habitTask!, evidence: habitCurrents, coverage: nil)
        expect(
            habitAnswer?.directAnswer == "最近一周完成次数共 8 次，主要来自晨跑（5 次）和阅读（3 次）。",
            "习惯 breakdown 输出错误：\(habitAnswer?.directAnswer ?? "nil")"
        )

        // 任务 ranking：哪天完成最多（dimension=day）
        let taskCurrents = [
            makeEvidence(id: "t-mon", range: "本周", semantic: makeSemantic(
                domain: .task, dataset: "task.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .day,
                groupLabel: "周一", direction: nil, current: 2, baseline: nil, result: 2, unit: "个"
            )),
            makeEvidence(id: "t-wed", range: "本周", semantic: makeSemantic(
                domain: .task, dataset: "task.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .day,
                groupLabel: "周三", direction: nil, current: 4, baseline: nil, result: 4, unit: "个"
            ))
        ]
        let taskRanking = HoloAnswerTaskDeriver.derive(question: "哪天完成任务最多？", evidence: taskCurrents)
        expect(taskRanking?.mode == .ranking, "任务排名应为 ranking，实际 \(String(describing: taskRanking?.mode))")
        let taskAnswer = HoloDeterministicAnswerComposer.compose(task: taskRanking!, evidence: taskCurrents, coverage: nil)
        expect(
            taskAnswer?.directAnswer == "本周任务最高的是周三（4 个）和周一（2 个）。",
            "任务 ranking 输出错误：\(taskAnswer?.directAnswer ?? "nil")"
        )
    }

    // MARK: - c) trend 跨领域

    private static func test趋势跨领域复用() {
        // 健康：步数趋势（步）
        let stepsTrend = [makeEvidence(id: "trend-steps", range: "最近一周", semantic: makeSemantic(
            domain: .health, dataset: "health.steps", measure: .steps,
            operation: .linearTrend, valueRole: .trend, dimension: .day,
            groupLabel: nil, direction: nil, current: nil, baseline: nil, result: 150, unit: "步"
        ))]
        let stepsTask = HoloAnswerTaskDeriver.derive(question: "最近一周步数趋势如何？", evidence: stepsTrend)
        expect(stepsTask?.mode == .trend, "linearTrend 应为 trend，实际 \(String(describing: stepsTask?.mode))")
        let stepsAnswer = HoloDeterministicAnswerComposer.compose(task: stepsTask!, evidence: stepsTrend, coverage: nil)
        expect(
            stepsAnswer?.directAnswer == "最近一周，步数呈上升趋势，平均每天变化约 150 步。",
            "健康 trend 输出错误：\(stepsAnswer?.directAnswer ?? "nil")"
        )

        // 财务：支出趋势（元），同一 trend 规则
        let financeTrend = [makeEvidence(id: "trend-finance", range: "本月", semantic: makeSemantic(
            domain: .finance, dataset: "finance.transactions", measure: .amount,
            operation: .linearTrend, valueRole: .trend, dimension: .day,
            groupLabel: nil, direction: nil, current: nil, baseline: nil, result: -50, unit: "元"
        ))]
        let financeTask = HoloAnswerTaskDeriver.derive(question: "本月支出趋势如何？", evidence: financeTrend)
        expect(financeTask?.mode == .trend, "财务 trend 应为 trend，实际 \(String(describing: financeTask?.mode))")
        let financeAnswer = HoloDeterministicAnswerComposer.compose(task: financeTask!, evidence: financeTrend, coverage: nil)
        expect(
            financeAnswer?.directAnswer == "本月，支出呈下降趋势，平均每天变化约 50 元。",
            "财务 trend 输出错误：\(financeAnswer?.directAnswer ?? "nil")"
        )
    }

    // MARK: - d) 新旧对照：截图案例（动态 finance difference/growth 证据）

    /// 同一数据两个版本：旧（无 semantic，走 catalog 兜底）与新（带 semantic，走合成器）。
    /// 新输出必须数字一致、方向正确、无内部 token，且信息不弱于旧输出。
    private static func test新旧对照截图案例财务() throws {
        // 共享数据常量：餐饮 500→620（+120 元，+24%）；交通 500→680（+180 元，+36%）；总 2000→2300（+300 元）
        let foodBase = 500.0, foodCurrent = 620.0
        let transitBase = 500.0, transitCurrent = 680.0
        let allBase = 2_000.0, allCurrent = 2_300.0

        // 旧版：category_growth 百分比证据，无 semantic（财务特判已删，走 catalog dynamicSentence）
        let legacyEvidence = [
            legacyEvidence(id: "food-growth", metricKey: "dynamic.finance_transactions.category_growth.餐饮",
                           value: (foodCurrent - foodBase) / foodBase, unit: "比例", comparison: "餐饮",
                           range: "本月", baselineRange: "上月"),
            legacyEvidence(id: "transit-growth", metricKey: "dynamic.finance_transactions.category_growth.交通",
                           value: (transitCurrent - transitBase) / transitBase, unit: "比例", comparison: "交通",
                           range: "本月", baselineRange: "上月")
        ]
        let legacyResult = render(
            question: "这个月消费比上个月多在哪儿？",
            claimID: "legacy", displayText: "计算结果 24比例；计算结果 36比例",
            evidence: legacyEvidence
        )
        expect(legacyResult.directAnswer == "本月，餐饮支出相比上期增加 24%",
               "旧路径应为 catalog 兜底单句，实际：\(legacyResult.directAnswer ?? "nil")")

        // 新版：difference + percentageChange 证据，带完整 semantic
        let newEvidence = [
            makeEvidence(id: "all-delta", range: "本月", baselineRange: "上月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .difference, valueRole: .delta, dimension: .category,
                groupLabel: nil, direction: .increase,
                current: allCurrent, baseline: allBase, result: allCurrent - allBase, unit: "元"
            )),
            makeEvidence(id: "food-delta", range: "本月", baselineRange: "上月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .difference, valueRole: .delta, dimension: .category,
                groupLabel: "餐饮", direction: .increase,
                current: foodCurrent, baseline: foodBase, result: foodCurrent - foodBase, unit: "元"
            )),
            makeEvidence(id: "transit-delta", range: "本月", baselineRange: "上月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .amount,
                operation: .difference, valueRole: .delta, dimension: .category,
                groupLabel: "交通", direction: .increase,
                current: transitCurrent, baseline: transitBase, result: transitCurrent - transitBase, unit: "元"
            )),
            makeEvidence(id: "food-rate", range: "本月", baselineRange: "上月", semantic: makeSemantic(
                domain: .finance, dataset: "finance.transactions", measure: .ratio,
                operation: .percentageChange, valueRole: .changeRate, dimension: .category,
                groupLabel: "餐饮", direction: .increase,
                current: foodCurrent, baseline: foodBase,
                result: (foodCurrent - foodBase) / foodBase, unit: "比例"
            ))
        ]
        let newResult = render(
            question: "这个月消费比上个月多在哪儿？",
            claimID: "new", displayText: "计算结果 24比例；计算结果 36比例",
            evidence: newEvidence
        )
        let newAnswer = try unwrap(newResult.directAnswer, "新路径必须有直接结论")
        expect(newAnswer == "本月支出比上月增加 300 元，主要来自交通（+180 元）和餐饮（+120 元）。交通贡献了总增量的 60%。",
               "新路径输出错误：\(newAnswer)")

        // 数字一致：新旧源自同一组共享常量；旧 24% 与新 +120 元互为同一事实
        expect(legacyResult.directAnswer!.contains("24%"), "旧路径应给出 24%")
        expect(newAnswer.contains("餐饮（+120 元）"), "新路径餐饮增量必须与旧 24% 同源（500→620）")
        // 方向正确、无内部 token
        expect(newAnswer.contains("增加"), "新路径方向必须正确")
        expect(!HoloAnswerCoverageVerifier.containsInternalToken(newAnswer), "新路径不得含内部 token")
        // 信息不弱于旧：新输出同时覆盖旧输出的首类事实，且额外给出总量与排名
        expect(newAnswer.contains("餐饮") && newAnswer.contains("交通"), "新路径必须覆盖旧路径的分类事实")
        expect(newAnswer.contains("300 元"), "新路径必须给出旧路径没有的总量结论")
    }

    // MARK: - e) 新旧对照：习惯 / 任务 / 健康各一条

    private static func test新旧对照习惯任务健康() throws {
        // 习惯：频率变化。旧 = catalog「标题+数值」无方向；新 = 合成器直接回答变化方向与数值。
        let habitLegacy = [
            legacyEvidence(id: "habit-freq", metricKey: "habit.negative.frequency_change",
                           value: 2, unit: "次", comparison: "increasing",
                           range: "最近一周", baselineRange: nil)
        ]
        let habitOld = render(question: "最近熬夜次数有什么变化？", claimID: "h-old",
                              displayText: "habit.negative.frequency_change = 2", evidence: habitLegacy)
        expect(habitOld.directAnswer == "最近一周，发生频率变化 2次",
               "习惯旧路径应为 catalog 兜底句，实际：\(habitOld.directAnswer ?? "nil")")
        let habitNew = [
            makeEvidence(id: "habit-freq-new", range: "最近一周", baselineRange: "上期", semantic: makeSemantic(
                domain: .habit, dataset: "habit.daily", measure: .count,
                operation: .difference, valueRole: .delta, dimension: nil,
                groupLabel: nil, direction: .increase,
                current: 3, baseline: 1, result: 2, unit: "次"
            ))
        ]
        let habitNewResult = render(question: "最近熬夜次数有什么变化？", claimID: "h-new",
                                    displayText: "habit.negative.frequency_change = 2", evidence: habitNew)
        let habitNewAnswer = try unwrap(habitNewResult.directAnswer, "习惯新路径必须有直接结论")
        expect(habitNewAnswer == "最近一周完成次数比上期增加 2 次。", "习惯新路径输出错误：\(habitNewAnswer)")
        expect(habitNewAnswer.contains("增加 2 次") && !habitOld.directAnswer!.contains("增加"),
               "新路径必须回答旧路径答不出的变化方向")

        // 任务：每日完成数排名。旧 = catalog 把完成数误标为「任务完成率」；新 = 排名句，单位与含义正确。
        let taskLegacy = [
            legacyEvidence(id: "task-wed", metricKey: "task.completion.rate",
                           value: 4, unit: "条", comparison: nil,
                           range: "本周", baselineRange: nil)
        ]
        let taskOld = render(question: "哪天完成任务最多？", claimID: "t-old",
                             displayText: "task.completion.rate = 4", evidence: taskLegacy)
        expect(taskOld.directAnswer == "本周，任务完成率 4条",
               "任务旧路径应为 catalog 误标句，实际：\(taskOld.directAnswer ?? "nil")")
        let taskNew = [
            makeEvidence(id: "task-mon-new", range: "本周", semantic: makeSemantic(
                domain: .task, dataset: "task.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .day,
                groupLabel: "周一", direction: nil, current: 2, baseline: nil, result: 2, unit: "条"
            )),
            makeEvidence(id: "task-wed-new", range: "本周", semantic: makeSemantic(
                domain: .task, dataset: "task.daily", measure: .count,
                operation: .count, valueRole: .current, dimension: .day,
                groupLabel: "周三", direction: nil, current: 4, baseline: nil, result: 4, unit: "条"
            ))
        ]
        let taskNewResult = render(question: "哪天完成任务最多？", claimID: "t-new",
                                   displayText: "task.completion.rate = 4", evidence: taskNew)
        let taskNewAnswer = try unwrap(taskNewResult.directAnswer, "任务新路径必须有直接结论")
        expect(taskNewAnswer == "本周任务最高的是周三（4 条）和周一（2 条）。",
               "任务新路径输出错误：\(taskNewAnswer)")
        expect(taskNewAnswer.contains("周三（4 条）"), "新路径数字必须与证据一致")
        expect(!taskNewAnswer.contains("完成率"), "新路径不得沿用旧路径的误标名词")

        // 健康：睡眠时长变化。旧 = catalog 只陈述平均值（答非所问）；新 = 直接回答时长变化。
        let healthLegacy = [
            legacyEvidence(id: "sleep-avg", metricKey: "health.sleep.average_hours",
                           value: 7.5, unit: "小时", comparison: nil,
                           range: "最近一周", baselineRange: nil)
        ]
        let healthOld = render(question: "最近睡眠时长有什么变化？", claimID: "s-old",
                               displayText: "health.sleep.average_hours = 7.5", evidence: healthLegacy)
        expect(healthOld.directAnswer == "最近一周，平均睡眠 7.5 小时",
               "健康旧路径应为 catalog 兜底句，实际：\(healthOld.directAnswer ?? "nil")")
        let healthNew = [
            makeEvidence(id: "sleep-delta", range: "最近一周", baselineRange: "上期", semantic: makeSemantic(
                domain: .health, dataset: "health.sleep", measure: .durationHours,
                operation: .difference, valueRole: .delta, dimension: nil,
                groupLabel: nil, direction: .increase,
                current: 7.5, baseline: 7, result: 0.5, unit: "小时"
            ))
        ]
        let healthNewResult = render(question: "最近睡眠时长有什么变化？", claimID: "s-new",
                                     displayText: "health.sleep.average_hours = 7.5", evidence: healthNew)
        let healthNewAnswer = try unwrap(healthNewResult.directAnswer, "健康新路径必须有直接结论")
        expect(healthNewAnswer == "最近一周时长比上期增加 0.5 小时。",
               "健康新路径输出错误：\(healthNewAnswer)")
        expect(healthNewAnswer.contains("增加 0.5 小时"), "新路径必须直接回答变化量与方向")
    }

    // MARK: - 构造工具

    private static func makeSemantic(
        domain: HoloEvidenceSourceModule,
        dataset: String,
        measure: HoloMetricMeasure,
        operation: HoloMetricOperation,
        valueRole: HoloMetricValueRole,
        dimension: HoloMetricDimension?,
        groupLabel: String?,
        direction: HoloMetricDirection?,
        current: Double?,
        baseline: Double?,
        result: Double,
        unit: String?
    ) -> HoloMetricSemantic {
        HoloMetricSemantic(
            domain: domain,
            dataset: dataset,
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
        range: String,
        baselineRange: String? = nil,
        semantic: HoloMetricSemantic
    ) -> HoloEvidenceRecord {
        HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: semantic.domain,
            sourceID: nil,
            sourceKind: "dynamic_query",
            timeRange: makeRange(range),
            occurredAt: nil,
            metricKey: "dynamic.test.\(id)",
            metricValue: semantic.resultValue,
            unit: semantic.displayUnit,
            baselineValue: semantic.baselineValue,
            baselineTimeRange: baselineRange.map(makeRange),
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

    /// 旧版证据：无 semantic，只带 metricKey/数值/单位，走 catalog 兼容层。
    private static func legacyEvidence(
        id: String,
        metricKey: String,
        value: Double,
        unit: String,
        comparison: String?,
        range: String,
        baselineRange: String?
    ) -> HoloEvidenceRecord {
        let module: HoloEvidenceSourceModule = metricKey.hasPrefix("habit") ? .habit
            : metricKey.hasPrefix("task") ? .task
            : metricKey.hasPrefix("health") ? .health
            : .finance
        return HoloEvidenceRecord(
            id: id,
            dedupeKey: id,
            sourceModule: module,
            sourceID: nil,
            sourceKind: "legacy",
            timeRange: makeRange(range),
            occurredAt: nil,
            metricKey: metricKey,
            metricValue: value,
            unit: unit,
            baselineValue: nil,
            baselineTimeRange: baselineRange.map(makeRange),
            comparison: comparison,
            excerpt: "旧证据 \(metricKey)",
            redactedExcerpt: "旧证据 \(metricKey)",
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

    private static func render(
        question: String,
        claimID: String,
        displayText: String,
        evidence: [HoloEvidenceRecord]
    ) -> HoloRenderedAgentResult {
        let assertions = evidence.map { record in
            HoloMetricAssertion(
                metricKey: record.metricKey,
                value: record.metricValue,
                baselineValue: nil,
                unit: record.unit,
                comparison: record.comparison,
                evidenceIDs: [record.id]
            )
        }
        let claim = HoloAgentClaim(
            id: claimID,
            type: "change",
            displayText: displayText,
            metricAssertions: assertions,
            evidenceIDs: evidence.map(\.id),
            prohibitedInferences: [],
            confidence: 0.9
        )
        return HoloAgentResultRenderer().render(
            claims: [claim],
            evidence: evidence,
            title: "深度分析",
            question: question,
            coverage: nil
        )
    }

    private static func makeRange(_ label: String) -> HoloAgentTimeRange {
        HoloAgentTimeRange(label: label, start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 2_000))
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "HoloAnswerCrossDomainTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }
}
