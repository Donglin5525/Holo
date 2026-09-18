//
//  GoalWorkshopValidatorTests.swift
//  Holo
//
//  目标共创响应校验器测试（方案任务 1 / §2.2）：
//  版本与枚举、会话匹配、载荷匹配、标题/证据必填、ID 唯一与引用、
//  日期严格解析、习惯关联越权、事实来源越权、路径数量、问题预算。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

final class GoalWorkshopValidatorTests: XCTestCase {
    func testGoalWorkshopValidator() throws {
        try GoalWorkshopValidatorTestSuite.run { message, file, line in
            XCTFail(message, file: file, line: line)
        }
    }
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() throws {
        try GoalWorkshopValidatorTestSuite.run { message, file, line in
            fatalError("\(message) [\(file):\(line)]")
        }
    }
}
#endif

struct GoalWorkshopValidatorTestSuite {

    typealias Failure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

    static func run(using fail: @escaping Failure) throws {
        testStrictDayParsing(fail: fail)
        testDecodingRejectsUnknownSchemaAndKind(fail: fail)
        testSessionIdentityAndStale(fail: fail)
        testQuestionRules(fail: fail)
        testOptionsRules(fail: fail)
        testPlanRules(fail: fail)
        testFactProvenanceGuard(fail: fail)
        testValidResponsesPass(fail: fail)
        print("GoalWorkshop validator suite passed: 8 组契约校验断言")
    }


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

    private static func expectError(_ error: GoalWorkshopValidationError,
                                    _ body: () throws -> Void, fail: @escaping Failure,
                                    file: StaticString = #fileID, line: UInt = #line) {
        do {
            try body()
            fail("预期错误 \(error) 但成功了", file, line)
        } catch let thrown as GoalWorkshopValidationError {
            guard thrown == error else {
                fail("错误类型不符：期望 \(error)，实际 \(thrown)", file, line)
                return
            }
        } catch {
            fail("错误类型不符：期望 \(error)，实际 \(error)", file, line)
        }
    }

    // MARK: - 工厂

    private static func makeSession(phase: GoalWorkshopPhase = .understanding,
                                questionsAsked: Int = 0) -> GoalWorkshopSessionV1 {
        var session = GoalWorkshopSessionV1(originalText: "想多读书")
        session.phase = phase
        session.questionsAsked = questionsAsked
        return session
    }

    private static func validQuestion(session: GoalWorkshopSessionV1) -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id, revision: session.revision, kind: .question,
            assistantText: "好，先对齐一件事。",
            question: GoalWorkshopQuestion(text: "「多」对你意味着什么？", whyItMatters: "决定按本数还是按时长设计")
        )
    }

    private static func validOptions(session: GoalWorkshopSessionV1) -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id, revision: session.revision, kind: .options,
            assistantText: "两条路给你选。",
            options: [
                GoalRouteOption(id: "r1", title: "固定时段", fit: "作息稳定", effort: "每天20分钟",
                                tradeoff: "被打断易归零", reason: "建立节律"),
                GoalRouteOption(id: "r2", title: "按本数", fit: "时间不固定", effort: "每周一本",
                                tradeoff: "无日常节奏", reason: "灵活")
            ],
            recommendedOptionID: "r1"
        )
    }

    private static func validPlan(session: GoalWorkshopSessionV1) -> GoalWorkshopResponseV1 {
        GoalWorkshopResponseV1(
            sessionID: session.id, revision: session.revision, kind: .plan,
            assistantText: "初稿好了。",
            plan: GoalWorkshopPlan(
                draft: GoalDraft(
                    id: "d1", title: "一年读完 12 本书", summary: nil, domain: .learning, iconEmoji: nil,
                    desiredOutcome: "读完12本非虚构", motivation: "重建阅读习惯", deadlineText: "2027-09-01",
                    tasks: [GoalTaskDraft(id: "t1", isSelected: true, title: "列一份 12 本候选书单",
                                          dueDateText: "2026-09-30", priority: 1, note: nil)],
                    habits: [GoalHabitDraft(id: "h1", isSelected: true, name: "睡前阅读", frequency: "daily",
                                            targetCount: 1, type: "checkIn", unit: nil, targetValue: nil,
                                            isBadHabit: false, successRule: "completeWhenDone")],
                    missingInfoWarnings: []
                ),
                successEvidence: "2027-09-01 前读完 12 本并留笔记",
                milestones: [GoalWorkshopMilestone(id: "m1", title: "读完第 3 本", dateText: "2026-11-30")],
                firstActionID: "t1",
                assumptions: ["假设每月能读完一本"],
                reviewDateText: "2026-12-01"
            )
        )
    }

    // MARK: - 用例

    /// 日期严格解析：位数、分隔符、非法日历日、自然语言全拒；合法值通过
    private static func testStrictDayParsing(fail: @escaping Failure) {
        let valid = ["2026-09-17", "2026-02-28", "2028-02-29", "2026-12-31"]
        let invalid = ["2026-9-3", "2026-09-3", "2026-02-30", "2027-02-29", "2026/09/17",
                       "2026-09-17 ", " 2026-09-17", "20260917", "2026-09-17T00:00:00",
                       "下个月", "2026-13-01", "2026-00-10", ""]
        for text in valid {
            guard GoalWorkshopValidator.isValidStrictDay(text) else {
                return record(fail, "合法日期被拒：\(text)")
            }
        }
        for text in invalid {
            guard !GoalWorkshopValidator.isValidStrictDay(text) else {
                return record(fail, "非法日期被放行：\(text)")
            }
        }
    }

    /// 解码边界：未知 schemaVersion / 未知 kind 直接抛错，不当空草案
    private static func testDecodingRejectsUnknownSchemaAndKind(fail: @escaping Failure) {
        let session = makeSession()
        let question = validQuestion(session: session)
        guard let data = try? JSONEncoder().encode(question),
              let baseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return record(fail, "编码基准响应失败")
        }

        var versionObject = baseObject
        versionObject["schemaVersion"] = 99
        if let badVersion = try? JSONSerialization.data(withJSONObject: versionObject) {
            do {
                _ = try JSONDecoder().decode(GoalWorkshopResponseV1.self, from: badVersion)
                record(fail, "未知 schemaVersion 应解码失败")
            } catch let error as GoalWorkshopValidationError {
                guard case .unsupportedSchemaVersion(99) = error else {
                    return record(fail, "版本错误类型不符：\(error)")
                }
            } catch {
                record(fail, "版本错误类型不符：\(error)")
            }
        }

        var kindObject = baseObject
        kindObject["schemaVersion"] = 1
        kindObject["kind"] = "saved"
        if let badKind = try? JSONSerialization.data(withJSONObject: kindObject) {
            do {
                _ = try JSONDecoder().decode(GoalWorkshopResponseV1.self, from: badKind)
                record(fail, "未知 kind 应解码失败")
            } catch let error as GoalWorkshopValidationError {
                guard case .unknownKind("saved") = error else {
                    return record(fail, "kind 错误类型不符：\(error)")
                }
            } catch {
                record(fail, "kind 错误类型不符：\(error)")
            }
        }
    }

    /// 会话匹配：sessionID 不符、revision 不符（迟到/超前）均拒绝
    private static func testSessionIdentityAndStale(fail: @escaping Failure) {
        let session = makeSession()
        var foreign = validQuestion(session: session)
        foreign.sessionID = UUID()
        expectError(.sessionIDMismatch(expected: session.id, actual: foreign.sessionID), {
            try GoalWorkshopValidator.validate(foreign, for: session)
        }, fail: fail)

        var stale = validQuestion(session: session)
        stale.revision = 5
        expectError(.staleResponse(sessionRevision: 0, responseRevision: 5), {
            try GoalWorkshopValidator.validate(stale, for: session)
        }, fail: fail)
    }

    /// question 规则：载荷互斥、必填字段、阶段、3 问预算
    private static func testQuestionRules(fail: @escaping Failure) {
        let session = makeSession()
        success({ try GoalWorkshopValidator.validate(validQuestion(session: session), for: session) }, fail: fail)

        var withOptions = validQuestion(session: session)
        withOptions.options = validOptions(session: session).options
        failure({ try GoalWorkshopValidator.validate(withOptions, for: session) }, fail: fail)

        var emptyQuestion = validQuestion(session: session)
        emptyQuestion.question = GoalWorkshopQuestion(text: "", whyItMatters: "")
        failure({ try GoalWorkshopValidator.validate(emptyQuestion, for: session) }, fail: fail)

        let reviewing = makeSession(phase: .reviewing)
        let reviewQuestion = validQuestion(session: reviewing)
        failure({ try GoalWorkshopValidator.validate(reviewQuestion, for: reviewing) }, fail: fail)

        let exhausted = makeSession(questionsAsked: GoalWorkshopBudget.maxDecisionQuestions)
        let fourth = validQuestion(session: exhausted)
        expectError(.questionBudgetExhausted, {
            try GoalWorkshopValidator.validate(fourth, for: exhausted)
        }, fail: fail)
    }

    /// options 规则：数量 1–3、ID 唯一、推荐引用存在、阶段
    private static func testOptionsRules(fail: @escaping Failure) {
        let session = makeSession()
        success({ try GoalWorkshopValidator.validate(validOptions(session: session), for: session) }, fail: fail)

        var four = validOptions(session: session)
        four.options?.append(GoalRouteOption(id: "r3", title: "第三条", fit: "x", effort: "x",
                                             tradeoff: "x", reason: "x"))
        four.options?.append(GoalRouteOption(id: "r4", title: "第四条", fit: "x", effort: "x",
                                             tradeoff: "x", reason: "x"))
        expectError(.optionsCountOutOfBounds(4), {
            try GoalWorkshopValidator.validate(four, for: session)
        }, fail: fail)

        var zero = validOptions(session: session)
        zero.options = []
        expectError(.optionsCountOutOfBounds(0), {
            try GoalWorkshopValidator.validate(zero, for: session)
        }, fail: fail)

        var duplicated = validOptions(session: session)
        duplicated.options?[1] = GoalRouteOption(id: "r1", title: "重复", fit: "x", effort: "x",
                                                 tradeoff: "x", reason: "x")
        expectError(.duplicateRouteIDs(["r1"]), {
            try GoalWorkshopValidator.validate(duplicated, for: session)
        }, fail: fail)

        var dangling = validOptions(session: session)
        dangling.recommendedOptionID = "rX"
        expectError(.danglingRecommendedOption("rX"), {
            try GoalWorkshopValidator.validate(dangling, for: session)
        }, fail: fail)

        // 路径明显时允许单一推荐
        var single = validOptions(session: session)
        single.options = [GoalRouteOption(id: "only", title: "唯一推荐", fit: "x", effort: "x",
                                          tradeoff: "x", reason: "路径无实质分歧")]
        single.recommendedOptionID = "only"
        success({ try GoalWorkshopValidator.validate(single, for: session) }, fail: fail)

        var choosing = session
        choosing.phase = .choosing
        let late = validOptions(session: choosing)
        failure({ try GoalWorkshopValidator.validate(late, for: choosing) }, fail: fail)
    }

    /// plan 规则：标题/证据必填、行动 ID 唯一、firstAction 引用、日期严格、习惯越权、阶段
    private static func testPlanRules(fail: @escaping Failure) {
        let choosing = makeSession(phase: .choosing)
        success({ try GoalWorkshopValidator.validate(validPlan(session: choosing), for: choosing) }, fail: fail)

        var noTitle = validPlan(session: choosing)
        noTitle.plan?.draft.title = "   "
        expectError(.emptyTitle, { try GoalWorkshopValidator.validate(noTitle, for: choosing) }, fail: fail)

        var noEvidence = validPlan(session: choosing)
        noEvidence.plan?.successEvidence = ""
        expectError(.emptySuccessEvidence, { try GoalWorkshopValidator.validate(noEvidence, for: choosing) }, fail: fail)

        var duplicateAction = validPlan(session: choosing)
        let original = duplicateAction.plan!.draft.tasks[0]
        duplicateAction.plan?.draft.tasks[0] = GoalTaskDraft(
            id: "h1", isSelected: original.isSelected, title: original.title,
            dueDateText: original.dueDateText, priority: original.priority, note: original.note
        )
        expectError(.duplicateActionIDs(["h1"]), {
            try GoalWorkshopValidator.validate(duplicateAction, for: choosing)
        }, fail: fail)

        var danglingFirst = validPlan(session: choosing)
        danglingFirst.plan?.firstActionID = "ghost"
        expectError(.danglingFirstAction("ghost"), {
            try GoalWorkshopValidator.validate(danglingFirst, for: choosing)
        }, fail: fail)

        var badDate = validPlan(session: choosing)
        badDate.plan?.draft.deadlineText = "2026-2-30"
        expectError(.invalidDateText("2026-2-30"), {
            try GoalWorkshopValidator.validate(badDate, for: choosing)
        }, fail: fail)

        var badMilestone = validPlan(session: choosing)
        badMilestone.plan?.milestones[0].dateText = "下个月底"
        expectError(.invalidDateText("下个月底"), {
            try GoalWorkshopValidator.validate(badMilestone, for: choosing)
        }, fail: fail)

        var habitRef = validPlan(session: choosing)
        habitRef.plan?.draft.sourceHabitId = UUID()
        expectError(.unauthorizedHabitReference, {
            try GoalWorkshopValidator.validate(habitRef, for: choosing)
        }, fail: fail)

        // exploring 阶段不收 plan（须先呈现路径）；understanding 收（跳过追问的带假设初稿）
        let exploring = makeSession(phase: .exploring)
        failure({ try GoalWorkshopValidator.validate(validPlan(session: exploring), for: exploring) }, fail: fail)
        let understanding = makeSession(phase: .understanding)
        success({ try GoalWorkshopValidator.validate(validPlan(session: understanding), for: understanding) }, fail: fail)
    }

    /// 事实来源守卫：模型只能报 inference/unknown，不得代答用户事实或授权记录
    private static func testFactProvenanceGuard(fail: @escaping Failure) {
        let session = makeSession()
        var response = validQuestion(session: session)
        response.facts = [GoalWorkshopFact(text: "用户说每周读一本", provenance: .userStated)]
        expectError(.forbiddenFactProvenance(.userStated), {
            try GoalWorkshopValidator.validate(response, for: session)
        }, fail: fail)

        var okay = validQuestion(session: session)
        okay.facts = [
            GoalWorkshopFact(text: "推断：用户作息规律", provenance: .inference),
            GoalWorkshopFact(text: "未知：可投入预算", provenance: .unknown)
        ]
        success({ try GoalWorkshopValidator.validate(okay, for: session) }, fail: fail)
    }

    /// 合法响应逐 kind 通过，且 roundtrip 编码不丢契约字段
    private static func testValidResponsesPass(fail: @escaping Failure) {
        let session = makeSession()
        for response in [validQuestion(session: session), validOptions(session: session)] {
            success({ try GoalWorkshopValidator.validate(response, for: session) }, fail: fail)
        }
        let choosing = makeSession(phase: .choosing)
        let plan = validPlan(session: choosing)
        success({ try GoalWorkshopValidator.validate(plan, for: choosing) }, fail: fail)
        do {
            let data = try JSONEncoder().encode(plan)
            let decoded = try JSONDecoder().decode(GoalWorkshopResponseV1.self, from: data)
            guard decoded == plan, decoded.plan?.firstActionID == "t1",
                  decoded.plan?.milestones.first?.dateText == "2026-11-30" else {
                return record(fail, "roundtrip 丢字段")
            }
        } catch {
            record(fail, "roundtrip 编解码失败：\(error)")
        }
    }
}
