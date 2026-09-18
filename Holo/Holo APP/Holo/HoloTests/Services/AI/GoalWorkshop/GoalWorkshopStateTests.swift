//
//  GoalWorkshopStateTests.swift
//  Holo
//
//  目标共创会话状态机测试（方案任务 1）：
//  空输入与明确目标、一次一个问题、跳过、修改已确认事实、路径选择、
//  返回上一步、重复/迟到响应、会话取消、5 次请求预算；错误状态不前进 revision。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

final class GoalWorkshopStateTests: XCTestCase {
    func testGoalWorkshopState() throws {
        try GoalWorkshopStateTestSuite.run { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    }
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() throws {
        try GoalWorkshopStateTestSuite.run { message, file, line in
            fatalError("\(message) [\(file):\(line)]")
        }
    }
}
#endif

struct GoalWorkshopStateTestSuite {

    typealias Failure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

    static func run(using fail: @escaping Failure) throws {
        testNewSessionBasics(fail: fail)
        testSingleQuestionAtATime(fail: fail)
        testSkipInUnderstandingAndExploring(fail: fail)
        testCorrectFact(fail: fail)
        testChooseRoute(fail: fail)
        testGoBackChain(fail: fail)
        testStaleAndDuplicateResponses(fail: fail)
        testAbandon(fail: fail)
        testRequestBudget(fail: fail)
        testFailedApplyDoesNotAdvanceRevision(fail: fail)
        testHappyPathToReviewing(fail: fail)
        testTerminalGuards(fail: fail)
        testSnapshotExcludesRetractedAndUnknown(fail: fail)
        testFrozenFixturesLoad(fail: fail)
        print("GoalWorkshop state suite passed: 14 组状态机与 fixtures 完整性断言")
    }

    // MARK: - 断言助手


    /// 单参失败上报助手（file/line 由调用点默认值补齐）
    private static func record(_ fail: @escaping Failure, _ message: String,
                               file: StaticString = #fileID, line: UInt = #line) {
        fail(message, file, line)
    }

    private static func success(_ body: () throws -> Void, fail: @escaping Failure,
                                file: StaticString = #fileID, line: UInt = #line) {
        do { try body() } catch { fail("预期成功但失败：\(error)", file, line) }
    }

    private static func failure(_ body: () throws -> Void, fail: @escaping Failure,
                                file: StaticString = #fileID, line: UInt = #line) {
        do {
            try body()
            fail("预期失败但成功了", file, line)
        } catch {}
    }

    // MARK: - 工厂

    private static func makeSession(seed: String = "我想在工作会议中更敢开口说英语") -> GoalWorkshopSessionV1 {
        GoalWorkshopSessionV1(originalText: seed)
    }

    private static func makeQuestion(revision: Int, session: GoalWorkshopSessionV1,
                                     text: String = "你的英文会议大概多久一次？") -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id,
            revision: revision,
            kind: .question,
            assistantText: "我理解你想在会议里更敢开口。",
            question: GoalWorkshopQuestion(text: text, whyItMatters: "频率决定先练听说还是先补基础")
        )
    }

    private static func makeOptions(revision: Int, session: GoalWorkshopSessionV1) -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id,
            revision: revision,
            kind: .options,
            assistantText: "有两条走得通的路。",
            options: [
                GoalRouteOption(id: "route-1", title: "先练会议听说", fit: "下周就要参会", effort: "每天20分钟",
                                tradeoff: "基础语法需边用边补", reason: "更贴近当前用途"),
                GoalRouteOption(id: "route-2", title: "先补语言基础", fit: "近期没有会议压力", effort: "每天20分钟",
                                tradeoff: "进入真实会议较慢", reason: "先减少基础障碍")
            ],
            recommendedOptionID: "route-1"
        )
    }

    private static func makePlan(revision: Int, session: GoalWorkshopSessionV1) -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id,
            revision: revision,
            kind: .plan,
            assistantText: "按「先练会议听说」出了初稿。",
            plan: GoalWorkshopPlan(
                draft: GoalDraft(
                    id: "draft-1",
                    title: "工作会议英语敢开口",
                    summary: "围绕真实会议场景练习听说",
                    domain: .learning,
                    iconEmoji: nil,
                    desiredOutcome: "能在周会上完整表达一次观点",
                    motivation: "晋升需要跨团队沟通",
                    deadlineText: "2026-12-31",
                    tasks: [
                        GoalTaskDraft(id: "task-1", isSelected: true, title: "本周内准备一次英文自我介绍",
                                      dueDateText: "2026-09-25", priority: 1, note: nil)
                    ],
                    habits: [
                        GoalHabitDraft(id: "habit-1", isSelected: true, name: "跟读会议录音", frequency: "daily",
                                       targetCount: 1, type: "checkIn", unit: nil, targetValue: nil,
                                       isBadHabit: false, successRule: "completeWhenDone")
                    ],
                    missingInfoWarnings: []
                ),
                successEvidence: "连续四周在周会至少发言一次",
                milestones: [GoalWorkshopMilestone(id: "m-1", title: "完成首次英文发言", dateText: "2026-10-31")],
                firstActionID: "task-1",
                assumptions: ["假设每周都有英文周会"],
                reviewDateText: "2026-10-15"
            )
        )
    }

    // MARK: - 用例

    /// 空输入与明确目标：两种种子都能建立 understanding 会话；空种子不产生事实
    private static func testNewSessionBasics(fail: @escaping Failure) {
        let clear = makeSession()
        guard clear.phase == .understanding, clear.revision == 0,
              clear.originalText.contains("工作会议") else {
            return record(fail, "明确目标种子应建立 understanding/revision=0：\(clear.phase)/\(clear.revision)")
        }
        let empty = GoalWorkshopSessionV1(originalText: "")
        guard empty.phase == .understanding, empty.facts.isEmpty, empty.originalText.isEmpty else {
            return record(fail, "空种子会话字段异常")
        }
    }

    /// 一次一个问题：currentQuestion 单值，连续两轮顺序追问各自替换
    private static func testSingleQuestionAtATime(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeQuestion(revision: 0, session: session))
        guard session.currentQuestion?.text.contains("会议") == true, session.questionsAsked == 1,
              session.phase == .understanding, session.revision == 1 else {
            return record(fail, "首轮追问后状态异常：asked=\(session.questionsAsked) rev=\(session.revision)")
        }
        success({ try session.applyUserReply("每周一次，周三早上") }, fail: fail)
        try? session.apply(makeQuestion(revision: 2, session: session, text: "现在开口的主要障碍是什么？"))
        guard session.questionsAsked == 2, session.currentQuestion?.text.contains("障碍") == true else {
            return record(fail, "第二轮追问未替换当前问题")
        }
    }

    /// 跳过：understanding 清问题并标记；exploring 无推荐时报错、有推荐时直达 choosing
    private static func testSkipInUnderstandingAndExploring(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeQuestion(revision: 0, session: session))
        success({ try session.skipQuestion() }, fail: fail)
        guard session.currentQuestion == nil, session.questioningSkipped == true, session.revision == 2 else {
            return record(fail, "understanding 跳过后应清问题并标记，rev=\(session.revision)")
        }

        var noRecommendation = makeSession()
        noRecommendation.phase = .exploring
        failure({ try noRecommendation.skipQuestion() }, fail: fail)

        var exploring = makeSession()
        exploring.phase = .exploring
        try? exploring.apply(makeOptions(revision: 0, session: exploring))  // rev 1，仍在 exploring
        success({ try exploring.skipQuestion() }, fail: fail)              // rev 2，接受推荐
        guard exploring.selectedRouteID == "route-1", exploring.phase == .choosing else {
            return record(fail, "exploring 跳过应接受推荐路径进入 choosing：\(exploring.phase)/\(String(describing: exploring.selectedRouteID))")
        }
    }

    /// 修改已确认事实：旧条目撤回留痕、新陈述以 userStated 追加
    private static func testCorrectFact(fail: @escaping Failure) {
        var session = makeSession()
        success({ try session.applyUserReply("每天晚上有两小时空闲") }, fail: fail)
        guard let factID = session.facts.first?.id else { return record(fail, "回复后应有 userStated 事实") }
        success({ try session.correctFact(id: factID, with: "不是没时间，是坐下来就不想练") }, fail: fail)
        guard session.facts.count == 2,
              session.facts[0].isRetracted == true,
              session.facts[1].provenance == .userStated,
              session.facts[1].text.contains("不想练") else {
            return record(fail, "纠正后应撤回旧事实并追加新陈述：\(session.facts)")
        }
        failure({ try session.correctFact(id: "no-such-id", with: "x") }, fail: fail)
    }

    /// 路径选择：合法 id 生效；未知 id 与错误阶段报错
    private static func testChooseRoute(fail: @escaping Failure) {
        var session = makeSession()
        failure({ try session.choose(routeID: "route-1") }, fail: fail)  // understanding 应报错
        try? session.apply(makeOptions(revision: 0, session: session))
        failure({ try session.choose(routeID: "route-9") }, fail: fail)
        success({ try session.choose(routeID: "route-2") }, fail: fail)
        guard session.phase == .choosing, session.selectedRouteID == "route-2" else {
            return record(fail, "合法选择后应进入 choosing")
        }
    }

    /// 返回上一步：reviewing→choosing 清草案；choosing→exploring 清选择；exploring 无路可退
    private static func testGoBackChain(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeOptions(revision: 0, session: session))
        success({ try session.choose(routeID: "route-1") }, fail: fail)
        try? session.apply(makePlan(revision: 2, session: session))
        guard session.phase == .reviewing else { return record(fail, "应先到达 reviewing") }
        success({ try session.goBack() }, fail: fail)
        guard session.phase == .choosing, session.plan == nil else {
            return record(fail, "reviewing 返回应清草案回 choosing")
        }
        success({ try session.goBack() }, fail: fail)
        guard session.phase == .exploring, session.selectedRouteID == nil else {
            return record(fail, "choosing 返回应清选择回 exploring")
        }
        failure({ try session.goBack() }, fail: fail)
    }

    /// 重复/迟到响应：revision 已前进的响应丢弃；sessionID 不符丢弃；状态不变
    private static func testStaleAndDuplicateResponses(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeQuestion(revision: 0, session: session))  // rev 0→1
        failure({ try session.apply(makeQuestion(revision: 0, session: session)) }, fail: fail)
        guard session.revision == 1 else { return record(fail, "重复响应不得前进 revision") }

        var foreign = makeQuestion(revision: 1, session: session)
        foreign.sessionID = UUID()
        failure({ try session.apply(foreign) }, fail: fail)
        failure({ try session.apply(makeQuestion(revision: 9, session: session)) }, fail: fail)
        guard session.revision == 1 else { return record(fail, "非法响应不得前进 revision") }
    }

    /// 会话取消：任何未保存阶段可进入 abandoned；终态不可再放弃
    private static func testAbandon(fail: @escaping Failure) {
        for seedPhase in [GoalWorkshopPhase.understanding, .exploring, .choosing, .reviewing] {
            var session = makeSession()
            session.phase = seedPhase
            success({ try session.abandon() }, fail: fail)
            guard session.phase == .abandoned else {
                return record(fail, "\(seedPhase) 放弃后应为 abandoned")
            }
        }
        var saved = makeSession()
        saved.phase = .saved
        failure({ try saved.abandon() }, fail: fail)
    }

    /// 8 次请求预算：第 8 次通过，第 9 次报错；失败退款归还计数
    private static func testRequestBudget(fail: @escaping Failure) {
        var session = makeSession()
        for index in 0..<GoalWorkshopBudget.maxModelRequests {
            success({ try session.beginModelRequest() }, fail: fail)
            guard session.requestCount == index + 1 else {
                return record(fail, "预算计数异常：\(session.requestCount)")
            }
        }
        failure({ try session.beginModelRequest() }, fail: fail)
        guard session.requestCount == GoalWorkshopBudget.maxModelRequests else {
            return record(fail, "超额请求不得增加计数")
        }

        // 退款：失败轮次归还预算，可再次发起（保险丝不是计费器）
        let revisionBeforeRefund = session.revision
        session.refundModelRequest()
        guard session.requestCount == GoalWorkshopBudget.maxModelRequests - 1 else {
            return record(fail, "退款应归还计数：\(session.requestCount)")
        }
        guard session.revision > revisionBeforeRefund else {
            return record(fail, "退款必须前进 revision 才能落库")
        }
        success({ try session.beginModelRequest() }, fail: fail)
    }

    /// 错误状态不前进 revision：载荷非法的响应被拒后 revision 与阶段不变
    private static func testFailedApplyDoesNotAdvanceRevision(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeQuestion(revision: 0, session: session))  // rev 1
        var bad = makeOptions(revision: 1, session: session)
        bad.options = []
        failure({ try session.apply(bad) }, fail: fail)
        guard session.revision == 1, session.phase == .understanding, session.routeOptions.isEmpty else {
            return record(fail, "非法响应后状态不得变化：rev=\(session.revision) phase=\(session.phase)")
        }
    }

    /// 合法全流程：追问→答→路径→选→草案→确认页
    private static func testHappyPathToReviewing(fail: @escaping Failure) {
        var session = makeSession()
        try? session.apply(makeQuestion(revision: 0, session: session))          // rev1 understanding
        success({ try session.applyUserReply("每周三早上的周会") }, fail: fail)  // rev2
        try? session.apply(makeOptions(revision: 2, session: session))           // rev3 exploring
        success({ try session.choose(routeID: "route-1") }, fail: fail)          // rev4 choosing
        try? session.apply(makePlan(revision: 4, session: session))              // rev5 reviewing
        guard session.phase == .reviewing,
              session.plan?.firstActionID == "task-1",
              session.goalDefinition?.title == "工作会议英语敢开口",
              session.selectedRouteID == "route-1" else {
            return record(fail, "全流程终态异常：\(session.phase)")
        }
    }

    /// 终态守卫：abandoned 后拒绝一切用户操作与响应
    private static func testTerminalGuards(fail: @escaping Failure) {
        var session = makeSession()
        try? session.abandon()
        failure({ try session.applyUserReply("再想想") }, fail: fail)
        failure({ try session.apply(makeQuestion(revision: session.revision, session: session)) }, fail: fail)
    }

    /// 快照：撤回与 unknown 不进请求快照；userStated/authorizedRecord/inference 保留
    private static func testSnapshotExcludesRetractedAndUnknown(fail: @escaping Failure) {
        var session = makeSession()
        success({ try session.applyUserReply("我想三个月内见效") }, fail: fail)
        session.facts.append(GoalWorkshopFact(id: "gap-1", text: "预算未知", provenance: .unknown))
        session.facts.append(GoalWorkshopFact(id: "inf-1", text: "推断：晚上有空", provenance: .inference))
        session.facts.append(GoalWorkshopFact(id: "rec-1", text: "旧目标：学英语", provenance: .authorizedRecord,
                                              sourceID: "goal-old", sourceRevision: 3))
        guard let retractedID = session.facts.first?.id else { return record(fail, "事实缺失") }
        success({ try session.correctFact(id: retractedID, with: "改为六个月内") }, fail: fail)

        let snapshot = session.buildSnapshot(today: Date(timeIntervalSince1970: 1_789_555_200))
        let ids = snapshot.activeFacts.map(\.id)
        guard !ids.contains(retractedID),
              !ids.contains("gap-1"),
              ids.contains("inf-1"), ids.contains("rec-1"),
              snapshot.today.count == 10 else {
            return record(fail, "快照事实过滤异常：\(ids)")
        }
    }

    /// 冻结 fixtures 完整性：≥40 场景可加载、id 唯一、字段完备（单一真源守卫）
    private static func testFrozenFixturesLoad(fail: @escaping Failure) {
        struct FixtureFile: Codable {
            struct Scenario: Codable {
                let id: String
                let domain: String
                let input: String
                let keyGaps: [String]
                let routes: [Route]
                let forbiddenInferences: [String]
                struct Route: Codable { let title: String; let fit: String; let tradeoff: String }
            }
            let schemaVersion: Int
            let scenarios: [Scenario]
        }
        do {
            let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let fixtureURL = sourceDir
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // → HoloTests
                .appendingPathComponent("Fixtures/GoalWorkshop/goal-workshop-scenarios-v1.json")
            guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
                return record(fail, "找不到冻结场景文件：\(fixtureURL.path)")
            }
            let data = try Data(contentsOf: fixtureURL)
            let file = try JSONDecoder().decode(FixtureFile.self, from: data)
            guard file.scenarios.count >= 40 else {
                return record(fail, "冻结场景不足 40：\(file.scenarios.count)")
            }
            let ids = file.scenarios.map(\.id)
            guard Set(ids).count == ids.count else { return record(fail, "场景 id 重复") }
            let domains = Set(file.scenarios.map(\.domain))
            guard domains.count >= 6 else { return record(fail, "领域覆盖不足：\(domains)") }
            for scenario in file.scenarios {
                guard !scenario.input.isEmpty, !scenario.routes.isEmpty,
                      !scenario.forbiddenInferences.isEmpty else {
                    return record(fail, "场景字段缺失：\(scenario.id)")
                }
                for route in scenario.routes {
                    guard !route.title.isEmpty, !route.fit.isEmpty, !route.tradeoff.isEmpty else {
                        return record(fail, "路径字段缺失：\(scenario.id)")
                    }
                }
            }
        } catch {
            record(fail, "冻结场景解析失败：\(error)")
        }
    }
}
