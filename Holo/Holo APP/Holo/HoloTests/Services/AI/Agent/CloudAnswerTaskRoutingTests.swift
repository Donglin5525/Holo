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
