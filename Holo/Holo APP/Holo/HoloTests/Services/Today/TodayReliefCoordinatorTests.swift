//
//  TodayReliefCoordinatorTests.swift
//  HoloTests
//
//  「今天减负」AI 协调器单测（2026-10-03 实施方案 §10.4/§15 R26/R30/R31/R32）
//  stub 注入模型服务：解析、本地校验、修复预算、迟到结果、取消零写。
//

import XCTest
@testable import Holo

final class TodayReliefCoordinatorTests: XCTestCase {

    private var tz: TimeZone { TimeZone(identifier: "Asia/Shanghai")! }

    private func makeContext(
        tasks: [HoloTodayReliefDisplayFacts.TaskDisplay] = [],
        currentPayload: HoloTodayPlanPayload? = nil,
        heads: [UUID] = []
    ) -> HoloTodayReliefSessionContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let scope = HoloTodayDayScope(referenceTime: Date(), calendar: calendar, timeZone: tz)
        return HoloTodayReliefSessionContext(
            scope: scope,
            baseTasks: tasks,
            constraints: [],
            currentPlanPayload: currentPayload,
            currentPlanHeads: heads,
            truncated: false,
            tasksAvailable: true,
            calendarAuthorized: false,
            situation: nil
        )
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String = "提交活动报名",
        dueIn: TimeInterval? = 3_600,
        step: (id: UUID, action: String)? = nil
    ) -> HoloTodayReliefDisplayFacts.TaskDisplay {
        let due = dueIn.map { Date().addingTimeInterval($0) }
        return HoloTodayReliefDisplayFacts.TaskDisplay(
            taskID: id,
            title: title,
            dueAt: due,
            isAllDay: false,
            isOverdue: false,
            matterTitle: nil,
            currentStepID: step?.id,
            currentStepAction: step?.action,
            currentStepFingerprint: step.map { "fp-\($0.id.uuidString.prefix(4))" },
            currentStepRevisionID: step.map { _ in UUID() },
            hasSteps: step != nil,
            completed: false
        )
    }

    // MARK: - 解析（§10.4 严格模式）

    func test_解析_剥离codeFence() throws {
        let taskID = UUID()
        let fenced = """
        ```json
        {"schemaVersion":1,"kind":"cannotHelp","requestID":null,"scopeKey":null,"sourceFingerprint":null,"reasonCode":"insufficientContext","message":"读不到"}
        ```
        """
        let response = try HoloTodayReliefCoordinator.parse(fenced)
        XCTAssertEqual(response.kind, "cannotHelp")
        _ = taskID
    }

    func test_解析_未知kind与坏JSON拒绝() {
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.parse("随便说点什么")) { error in
            guard case HoloTodayReliefError.invalidModelOutput = error else {
                return XCTFail("期望 invalidModelOutput，实得 \(error)")
            }
        }
        let badKind = #"{"schemaVersion":1,"kind":"magic"}"#
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.parse(badKind))
    }

    // MARK: - 物化校验（R31）

    func test_物化_合法提案_步骤指纹用本地事实() throws {
        let stepID = UUID()
        let task = makeTask(step: (stepID, "查看两个合适航班"))
        let context = makeContext(tasks: [task])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: "先保留报名",
            selected: [.init(taskID: task.taskID, goal: .init(kind: "existingStep", stepID: stepID), reasonCode: "resumeExistingStep", evidenceRefs: nil)],
            deferredTaskIDs: [], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        let outcome = try HoloTodayReliefCoordinator.materialize(
            response: response, context: context, requestID: "req-1", fingerprint: "fp"
        )
        guard case .proposal(let candidate) = outcome else {
            return XCTFail("期望 proposal，实得 \(outcome)")
        }
        guard case .existingStep(let echoedStepID, _, let fingerprint) = candidate.payload.entries.first?.goal else {
            return XCTFail("期望 existingStep")
        }
        XCTAssertEqual(echoedStepID, stepID)
        XCTAssertEqual(fingerprint, "fp-\(stepID.uuidString.prefix(4))", "版本与指纹由本地补齐，不信任模型")
    }

    func test_物化_幽灵任务ID拒绝_修标题也不许继续() throws {
        let ghost = UUID()
        let context = makeContext(tasks: [makeTask()])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil,
            selected: [.init(taskID: ghost, goal: .init(kind: "taskResult", stepID: nil), reasonCode: "userSelected", evidenceRefs: nil)],
            deferredTaskIDs: [], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.materialize(
            response: response, context: context, requestID: "r", fingerprint: "f"
        )) { error in
            guard case HoloTodayReliefError.unknownReference = error else {
                return XCTFail("期望 unknownReference，实得 \(error)")
            }
        }
    }

    func test_物化_跨任务stepID拒绝() throws {
        let taskA = makeTask(title: "A")
        let taskB = makeTask(title: "B", step: (UUID(), "B的步骤"))
        let context = makeContext(tasks: [taskA, taskB])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil,
            selected: [.init(taskID: taskA.taskID, goal: .init(kind: "existingStep", stepID: taskB.currentStepID!), reasonCode: nil, evidenceRefs: nil)],
            deferredTaskIDs: [], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.materialize(
            response: response, context: context, requestID: "r", fingerprint: "f"
        )) { error in
            guard case HoloTodayReliefError.unknownReference = error else {
                return XCTFail("期望 unknownReference（跨任务 step），实得 \(error)")
            }
        }
    }

    func test_物化_模型漏掉已选项_补回不丢选择() throws {
        let kept = makeTask(title: "报名")
        let dropped = makeTask(title: "机票")
        let current = HoloTodayPlanPayload(selectionMode: .explicit, entries: [
            .init(taskID: kept.taskID, goal: .taskResult),
            .init(taskID: dropped.taskID, goal: .taskResult),
        ])
        let context = makeContext(tasks: [kept, dropped], currentPayload: current, heads: [UUID()])
        // 模型只报了 kept，没提 dropped 也没放下 → 不完整建议须补齐
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil,
            selected: [.init(taskID: kept.taskID, goal: .init(kind: "taskResult", stepID: nil), reasonCode: nil, evidenceRefs: nil)],
            deferredTaskIDs: [], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        let outcome = try HoloTodayReliefCoordinator.materialize(response: response, context: context, requestID: "r", fingerprint: "f")
        guard case .proposal(let candidate) = outcome else { return XCTFail("实得 \(outcome)") }
        XCTAssertEqual(Set(candidate.payload.entries.map(\.taskID)), [kept.taskID, dropped.taskID], "已选项被漏掉且未放下时补回（§10.4）")
    }

    func test_物化_选择与放下重叠拒绝() throws {
        let task = makeTask()
        let context = makeContext(tasks: [task])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil,
            selected: [.init(taskID: task.taskID, goal: .init(kind: "taskResult", stepID: nil), reasonCode: nil, evidenceRefs: nil)],
            deferredTaskIDs: [task.taskID], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.materialize(response: response, context: context, requestID: "r", fingerprint: "f"))
    }

    func test_物化_非空库newTask拒绝() throws {
        let task = makeTask()
        let context = makeContext(tasks: [task])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil, selected: nil,
            deferredTaskIDs: [], warnings: nil,
            newTask: .init(title: "新任务", description: nil),
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        XCTAssertThrowsError(try HoloTodayReliefCoordinator.materialize(response: response, context: context, requestID: "r", fingerprint: "f"))
    }

    func test_物化_风险确认不由模型生成() throws {
        // 模型放下今日到期任务：payload 不含 ack，确认留给用户行内操作
        let dueTonight = makeTask(title: "今晚截止", dueIn: 3_600)
        let context = makeContext(tasks: [dueTonight])
        let response = HoloTodayReliefAIResponse(
            schemaVersion: 1, kind: "proposal",
            requestID: nil, scopeKey: nil, sourceFingerprint: nil,
            summary: nil, selected: nil,
            deferredTaskIDs: [dueTonight.taskID], warnings: nil, newTask: nil,
            question: nil, suggestedAnswers: nil, reasonCode: nil, message: nil
        )
        let outcome = try HoloTodayReliefCoordinator.materialize(response: response, context: context, requestID: "r", fingerprint: "f")
        guard case .proposal(let candidate) = outcome else { return XCTFail("实得 \(outcome)") }
        XCTAssertTrue(candidate.payload.deadlineAcknowledgements.isEmpty, "确认只能来自用户行内操作（§10.4）")
    }

    // MARK: - 修复预算与取消（R26/R30/R32）

    /// 脚本 stub：第一轮坏输出、第二轮修复。
    private final class ScriptedService: HoloTodayReliefModelServicing {
        var responses: [String]
        var calls: [(body: String, usageActionId: String)] = []
        var throwNetworkError = false

        init(responses: [String]) {
            self.responses = responses
        }

        func sendTodayReliefPlan(bodyJSON: String, usageActionId: String) async throws -> String {
            calls.append((bodyJSON, usageActionId))
            if throwNetworkError {
                throw APIError.networkUnavailable
            }
            guard !responses.isEmpty else { throw APIError.serverError("脚本耗尽") }
            return responses.removeFirst()
        }
    }

    @MainActor
    func test_修复预算_坏输出触发一次修复_同一额度动作() async throws {
        let task = makeTask()
        let bad = "这不是JSON"
        let good = """
        {"schemaVersion":1,"kind":"proposal","requestID":null,"scopeKey":null,"sourceFingerprint":null,"summary":"ok","selected":[{"taskID":"\(task.taskID.uuidString)","goal":{"kind":"taskResult"},"reasonCode":"dueSoon"}],"deferredTaskIDs":[],"warnings":null,"newTask":null}
        """
        let service = ScriptedService(responses: [bad, good])
        let coordinator = HoloTodayReliefCoordinator(servicing: service)
        let outcome = try await coordinator.generate(
            situation: "时间不够了",
            clarificationAnswer: nil,
            context: makeContext(tasks: [task])
        )
        guard case .proposal = outcome else { return XCTFail("实得 \(outcome)") }
        XCTAssertEqual(service.calls.count, 2, "一次生成最多一次结构修复")
        XCTAssertEqual(service.calls[0].usageActionId, service.calls[1].usageActionId, "结构修复沿用同一额度动作")
        XCTAssertTrue(service.calls[1].body.contains("repairNote"), "修复轮携带问题说明")
    }

    @MainActor
    func test_修复预算_两轮都坏_不再第三次调用() async {
        let service = ScriptedService(responses: ["bad1", "bad2", "never"])
        let coordinator = HoloTodayReliefCoordinator(servicing: service)
        do {
            _ = try await coordinator.generate(
                situation: "x", clarificationAnswer: nil,
                context: makeContext(tasks: [makeTask()])
            )
            XCTFail("应抛错")
        } catch {
            XCTAssertEqual(service.calls.count, 2, "第二次失败后不再调用（预算硬上限）")
        }
    }

    @MainActor
    func test_网络失败不触发结构修复() async {
        let service = ScriptedService(responses: [])
        service.throwNetworkError = true
        let coordinator = HoloTodayReliefCoordinator(servicing: service)
        do {
            _ = try await coordinator.generate(
                situation: "x", clarificationAnswer: nil,
                context: makeContext(tasks: [makeTask()])
            )
            XCTFail("应抛错")
        } catch let error as HoloTodayReliefError {
            guard case .network = error else { return XCTFail("期望 network，实得 \(error)") }
            XCTAssertEqual(service.calls.count, 1, "网络失败不触发模型 JSON 修复")
        } catch {
            XCTFail("期望 HoloTodayReliefError，实得 \(error)")
        }
    }

    @MainActor
    func test_取消_传导到在途请求() async throws {
        final class SlowService: HoloTodayReliefModelServicing {
            var cancelled = false
            func sendTodayReliefPlan(bodyJSON: String, usageActionId: String) async throws -> String {
                // 模拟慢网络：等取消信号传导
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                cancelled = true
                throw CancellationError()
            }
        }
        let service = SlowService()
        let coordinator = HoloTodayReliefCoordinator(servicing: service)
        let generation = Task {
            try await coordinator.generate(situation: "x", clarificationAnswer: nil, context: makeContext(tasks: [makeTask()]))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        coordinator.cancel()
        do {
            _ = try await generation.value
            XCTFail("取消后应抛 CancellationError")
        } catch {
            XCTAssertTrue(service.cancelled || error is CancellationError, "取消必须传导到实际请求（§10.4）")
        }
    }

    // MARK: - 指纹

    func test_输入指纹_稳定且随事实变化() {
        let task = makeTask()
        let contextA = makeContext(tasks: [task])
        let contextB = makeContext(tasks: [task])
        XCTAssertEqual(
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextA, situation: "累"),
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextB, situation: "累"),
            "相同事实指纹稳定"
        )
        let changed = makeTask(id: task.taskID, title: task.title, dueIn: task.dueAt.map { $0.timeIntervalSinceNow } == nil ? nil : 7_200)
        let contextC = makeContext(tasks: [changed])
        XCTAssertNotEqual(
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextA, situation: "累"),
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextC, situation: "累"),
            "期限变化指纹必变（采用时检测来源变化）"
        )
        XCTAssertNotEqual(
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextA, situation: "累"),
            HoloTodayReliefCoordinator.sourceFingerprint(context: contextA, situation: "不累"),
            "表达参与指纹"
        )
    }
}
