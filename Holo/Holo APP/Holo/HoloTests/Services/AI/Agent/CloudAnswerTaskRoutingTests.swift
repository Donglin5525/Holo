//
//  CloudAnswerTaskRoutingTests.swift
//  Holo
//
//  深度分析场景路由与冻结回答任务（2026-09-19 提示词与证据链落地方案 任务2）：
//  - 显式场景不再依赖问句逐字相等——用户改写问句仍按所选场景深度分析；
//  - 长期模式不占额度，发送走普通对话；
//  - 场景元数据（问题类型/回答清单/默认时间窗）随快照冻结为
//    AnalysisAnswerTaskV1 上云，编码契约向后兼容（旧后端忽略该键）。
//

import XCTest
@testable import Holo

final class CloudAnswerTaskRoutingTests: XCTestCase {

    // MARK: - 发送路由（resolveSendRoute 纯函数）

    func test_显式场景_改写问句仍路由深度分析() {
        // 旧契约：文本与预填原句相等才命中；用户认真改写反而丢场景（方案 P1 根治点）
        let route = ChatViewModel.resolveSendRoute(
            text: "8月的外卖是不是比7月花得多？主要是次数多了还是每次更贵？",
            explicitScenario: .finance,
            planningStatus: nil,
            hasDraftForReview: false
        )
        guard case .explicitDeepAnalysis(let scenario) = route else {
            return XCTFail("改写问句后应仍按财务场景路由深度分析，实际 \(route)")
        }
        XCTAssertEqual(scenario, .finance)
    }

    func test_显式场景_预填原句命中() {
        let route = ChatViewModel.resolveSendRoute(
            text: AnalysisScenario.finance.question,
            explicitScenario: .finance,
            planningStatus: nil,
            hasDraftForReview: false
        )
        guard case .explicitDeepAnalysis = route else {
            return XCTFail("预填原句应命中显式深度分析，实际 \(route)")
        }
    }

    func test_长期模式不占额度_走常规路由() {
        let route = ChatViewModel.resolveSendRoute(
            text: AnalysisScenario.longTermPattern.question,
            explicitScenario: .longTermPattern,
            planningStatus: nil,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .regular)
    }

    func test_无显式场景_规划收集期优先() {
        let route = ChatViewModel.resolveSendRoute(
            text: "随便问问",
            explicitScenario: nil,
            planningStatus: .collecting,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .goalPlanningReply)
    }

    func test_无显式场景_常规消息() {
        let route = ChatViewModel.resolveSendRoute(
            text: "帮我记一笔午饭 35 元",
            explicitScenario: nil,
            planningStatus: nil,
            hasDraftForReview: false
        )
        XCTAssertEqual(route, .regular)
    }

    // MARK: - 场景元数据（AnalysisAnswerTaskV1 的客户端侧）

    func test_七个分析场景_问句为疑问句且互不重复() {
        let consuming = AnalysisScenario.allCases.filter(\.consumesAnalysisQuota)
        XCTAssertEqual(consuming.count, 7, "消耗额度的分析场景应为 7 个")
        var seen = Set<String>()
        for scenario in consuming {
            XCTAssertTrue(
                scenario.question.contains("？"),
                "\(scenario) 预填问句应为疑问句式：\(scenario.question)"
            )
            XCTAssertTrue(seen.insert(scenario.question).inserted, "问句重复：\(scenario.question)")
        }
    }

    func test_分析场景_回答清单与问题类型齐备() {
        for scenario in AnalysisScenario.allCases where scenario.consumesAnalysisQuota {
            XCTAssertFalse(
                scenario.answerChecklist.isEmpty,
                "\(scenario) 应有回答清单（子问题逐项回答的契约）"
            )
            XCTAssertFalse(
                scenario.answerTaskKind.isEmpty,
                "\(scenario) 应有问题类型"
            )
        }
        XCTAssertEqual(AnalysisScenario.longTermPattern.answerChecklist.count, 0, "长期模式不带分析清单")
    }

    func test_默认时间窗_目标与长期模式不冻结_其余三十天() {
        XCTAssertNil(AnalysisScenario.goal.defaultRangeDays, "目标复盘看目标全程，不冻结 30 天窗")
        XCTAssertNil(AnalysisScenario.longTermPattern.defaultRangeDays)
        for scenario in [.crossDomain, .finance, .habit, .health, .task, .thought] as [AnalysisScenario] {
            XCTAssertEqual(scenario.defaultRangeDays, 30, "\(scenario) 默认最近 30 天")
        }
    }

    // MARK: - 快照 answerTask 编码契约

    func test_快照JSON_带场景时编码answerTask_无场景时不带该键() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // 带场景：answerTask 全字段编码，primaryTimeRange 为 Unix 秒
        let withTask = HoloCloudAnalysisSnapshotBuilder.Snapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_758_253_200),
            historyDays: 180,
            datasets: [:],
            answerTask: .init(
                scenarioID: AnalysisScenario.finance.rawValue,
                userQuestion: "最近的钱主要花在了哪里？",
                questionKind: AnalysisScenario.finance.answerTaskKind,
                primaryTimeRange: .init(
                    label: "最近30天",
                    start: 1_755_640_000,
                    end: 1_758_253_200
                ),
                answerChecklist: AnalysisScenario.finance.answerChecklist
            )
        )
        let taskJSON = try XCTUnwrap(String(data: encoder.encode(withTask), encoding: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(taskJSON.utf8)) as? [String: Any])
        let answerTask = try XCTUnwrap(decoded["answerTask"] as? [String: Any])
        XCTAssertEqual(answerTask["scenarioID"] as? String, "finance")
        XCTAssertEqual(answerTask["questionKind"] as? String, "diagnosis")
        let range = try XCTUnwrap(answerTask["primaryTimeRange"] as? [String: Any])
        XCTAssertEqual(range["start"] as? Double, 1_755_640_000)
        XCTAssertEqual(range["end"] as? Double, 1_758_253_200)
        XCTAssertNotNil((answerTask["answerChecklist"] as? [Any])?.isEmpty == false)

        // 无场景：键不出现（旧后端零感知）
        let withoutTask = HoloCloudAnalysisSnapshotBuilder.Snapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_758_253_200),
            historyDays: 180,
            datasets: [:],
            answerTask: nil
        )
        let plainJSON = try XCTUnwrap(String(data: encoder.encode(withoutTask), encoding: .utf8))
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plainJSON.utf8)) as? [String: Any])
        XCTAssertNil(plain["answerTask"], "无场景时不得编码 answerTask 键")
    }
}

// MARK: - 自由问句时间词冻结（2026-09-24「问近一周答 180 天」根治）

/// 聊天打字的问句此前不冻结时间窗（只有场景卡带窗），云端退回快照默认窗
/// 180 天全窗分析。现在自由问句的时间词同样进 answerTask.primaryTimeRange。
final class CloudFreeformQuestionTimeRangeTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_758_253_200) // 2026-09-19 03:00 UTC（东八 11:00）

    func test_最近一周_冻结为七天窗() throws {
        let range = try XCTUnwrap(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "最近一周我的睡眠时长和作息节奏有变化吗？", now: reference
        ))
        // 解析器口径：「最近一周」= 含今天在内的 7 个自然日，起点对齐当天零点
        // （比精确减 168 小时更符合「按整天」的用户心智）；终点截到当前时刻
        let calendar = Calendar(identifier: .gregorian)
        var east = calendar
        east.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let expectedStart = east.startOfDay(for: reference).addingTimeInterval(-6 * 86_400)
        XCTAssertEqual(range.start, expectedStart.timeIntervalSince1970, accuracy: 1,
                       "最近一周=含今天的 7 个自然日（9/13 00:00 起）")
        XCTAssertEqual(range.end, reference.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(range.label.contains("问句指定"), "标签须注明来源是问句")
    }

    func test_近N天_支持数字变体() throws {
        let range = try XCTUnwrap(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "近30天花了多少钱", now: reference
        ))
        let calendar = Calendar(identifier: .gregorian)
        var east = calendar
        east.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let expectedStart = east.startOfDay(for: reference).addingTimeInterval(-29 * 86_400)
        XCTAssertEqual(range.start, expectedStart.timeIntervalSince1970, accuracy: 1,
                       "近30天=含今天的 30 个自然日")
    }

    func test_含未来段的语义_end截到当前时刻() throws {
        let range = try XCTUnwrap(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "今年我的支出结构怎么样", now: reference
        ))
        XCTAssertEqual(range.end, reference.timeIntervalSince1970, accuracy: 1,
                       "「今年」含未来段，已发生统计只能算到快照截止")
        XCTAssertLessThan(range.start, reference.timeIntervalSince1970 - 200 * 86_400,
                          "起点应为年初")
    }

    func test_无时间词_不瞎猜返回nil() {
        XCTAssertNil(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "我的睡眠怎么样", now: reference
        ))
        XCTAssertNil(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "", now: reference
        ))
    }
}

/// 2026-09-24 深夜实锤追加：「两」字缺口——「最近两个月」因中文数字映射表缺「两」
/// 整句解析失败，报告答成默认 180 天。锁定泛化规则（N 个天/周/月/年）与「两」。
final class CloudTwoMonthsFreezeTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_758_682_800) // 2026-09-24 15:00 UTC（东八 23:00）

    func test_最近两个月_冻结为两个日历月窗() throws {
        let range = try XCTUnwrap(HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(
            question: "最近两个月花了多少钱？有什么建议吗？", now: reference
        ))
        let calendar = Calendar.current
        // 近两个月 = 从「当天零点」回退两个日历月的那天 +1 起，end 含明天零点前（自然日口径）
        let today = calendar.startOfDay(for: reference)
        let monthBack = calendar.date(byAdding: .month, value: -2, to: today) ?? today
        let expectedStart = calendar.date(byAdding: .day, value: 1, to: monthBack) ?? today
        XCTAssertEqual(range.start, expectedStart.timeIntervalSince1970, accuracy: 5,
                       "「两」必须按 2 解析成两个月窗（此前缺「两」映射导致解析失败）")
        XCTAssertEqual(range.end, reference.timeIntervalSince1970, accuracy: 5)
        XCTAssertTrue(range.label.contains("问句指定"))
    }

    func test_量词变体_两个星期_近两年_过去三个月_全部命中() throws {
        let samples = [
            "最近两个星期我的习惯坚持得怎么样",
            "近两年换了几个城市生活",
            "过去三个月的睡眠有变化吗",
            "最近两周花了多少钱",
            "最近半年的健康趋势",
        ]
        for question in samples {
            XCTAssertNotNil(
                HoloCloudAnalysisSnapshotBuilder.resolvedQuestionTimeRange(question: question, now: reference),
                "「\(question)」应解析出时间窗"
            )
        }
    }
}
