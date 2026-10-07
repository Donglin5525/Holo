//
//  TodayReliefPolicyTests.swift
//  HoloTests
//
//  「今天减负」纯值规则单测（2026-10-03 实施方案 §7.2/§7.4）
//  不建 Core Data 栈：scope/payload 结构、期限确认、日目标派生全部纯值验证。
//

import XCTest
@testable import Holo

final class TodayReliefPolicyTests: XCTestCase {

    // 固定时区，避免宿主机时区影响断言
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func makeScope(_ dateString: String, hour: Int = 20) -> HoloTodayDayScope {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = tz
        let date = formatter.date(from: "\(dateString) \(String(format: "%02d", hour)):00")!
        return HoloTodayDayScope(referenceTime: date, calendar: calendar, timeZone: tz)
    }

    // MARK: - Scope（§7.1）

    func test_scope_key与边界() throws {
        let scope = makeScope("2026-10-03")
        XCTAssertEqual(scope.dateKey, "2026-10-03")
        XCTAssertEqual(scope.scopeKey, "2026-10-03@Asia/Shanghai")
        // 左闭右开
        XCTAssertTrue(scope.contains(scope.dayStart))
        XCTAssertFalse(scope.contains(scope.dayEnd))
        XCTAssertEqual(scope.dayEnd.timeIntervalSince(scope.dayStart), 86_400, accuracy: 1)
    }

    func test_scope_跨午夜构造() throws {
        let lateNight = makeScope("2026-10-03", hour: 23)
        let afterMidnight = makeScope("2026-10-04", hour: 0)
        XCTAssertEqual(lateNight.dayEnd, afterMidnight.dayStart)
        XCTAssertNotEqual(lateNight.scopeKey, afterMidnight.scopeKey)
    }

    // MARK: - Payload 结构（§7.2）

    func test_payload_互斥去重上限() throws {
        let id = UUID()
        var payload = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [.init(taskID: id, goal: .taskResult)],
            deferredTaskIDs: [id]
        )
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateStructure(payload)) { error in
            guard case HoloTodayReliefPolicy.PayloadStructureError.entriesDeferredOverlap = error else {
                return XCTFail("期望互斥错误，实得 \(error)")
            }
        }

        payload = HoloTodayPlanPayload(selectionMode: .explicit, deferredTaskIDs: [id, id])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateStructure(payload))

        // 上限 50：超限拒绝，不静默截断
        let many = (0...50).map { _ in HoloTodaySelectionEntry(taskID: UUID(), goal: .taskResult) }
        payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: many)
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateStructure(payload))
        let exactly = Array(many.prefix(50))
        payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: exactly)
        XCTAssertNoThrow(try HoloTodayReliefPolicy.validateStructure(payload))
    }

    func test_payload_inheritBase必须全空() throws {
        let bad = HoloTodayPlanPayload(selectionMode: .inheritBase, entries: [.init(taskID: UUID(), goal: .taskResult)])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateStructure(bad))
        XCTAssertNoThrow(try HoloTodayReliefPolicy.validateStructure(.inheritBase))
        // explicit + 空 entries 是有效结果（今天不主动推进任何任务）
        XCTAssertNoThrow(try HoloTodayReliefPolicy.validateStructure(HoloTodayPlanPayload(selectionMode: .explicit)))
    }

    func test_payload_canonical编码与摘要稳定() throws {
        let payload = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [.init(taskID: UUID(), goal: .taskResult)],
            deferredTaskIDs: [],
            confirmedMustTaskIDs: [],
            deadlineAcknowledgements: [.init(taskID: UUID(), deadlineFingerprint: "abc")]
        )
        let data = try payload.canonicalData()
        let decoded = try HoloTodayPlanPayload.decode(from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(try payload.digest(), try payload.digest(), "同 payload 摘要必须稳定")
        // 顺序变化 = 不同 payload（顺序是契约的一部分）
        let reordered = HoloTodayPlanPayload(
            selectionMode: .explicit,
            entries: [payload.entries[0]],
            deadlineAcknowledgements: []
        )
        XCTAssertNotEqual(try payload.digest(), try reordered.digest())
    }

    func test_goal编解码_枚举关联值() throws {
        let stepID = UUID(), revisionID = UUID()
        let goal = HoloTodayGoal.existingStep(stepID: stepID, originRevisionID: revisionID, contentFingerprint: "fp")
        let entry = HoloTodaySelectionEntry(taskID: UUID(), goal: goal)
        let payload = HoloTodayPlanPayload(selectionMode: .explicit, entries: [entry])
        let decoded = try HoloTodayPlanPayload.decode(from: try payload.canonicalData())
        XCTAssertEqual(decoded.entries.first?.goal, goal)

        // AI 输出同形 JSON：{"kind":"existingStep","stepID":...} 必须可解析
        let json = """
        {"schemaVersion":1,"selectionMode":"explicit","entries":[{"taskID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","goal":{"kind":"existingStep","stepID":"\(stepID.uuidString)","originRevisionID":"\(revisionID.uuidString)","contentFingerprint":"fp"}}],"deferredTaskIDs":[],"confirmedMustTaskIDs":[],"deadlineAcknowledgements":[]}
        """
        let fromAI = try HoloTodayPlanPayload.decode(from: Data(json.utf8))
        XCTAssertEqual(fromAI.entries.first?.goal, goal)

        // 未知 kind 拒绝
        let bad = json.replacingOccurrences(of: "existingStep", with: "magicStep")
        XCTAssertThrowsError(try HoloTodayPlanPayload.decode(from: Data(bad.utf8)))
    }

    // MARK: - 期限确认（§4.3）

    func test_期限指纹_全天口径与稳定性() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = tz

        // 非全天：同刻稳定；改期即变
        let due = formatter.date(from: "2026-10-03 21:00")!
        XCTAssertEqual(
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: due, isAllDay: false),
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: due, isAllDay: false)
        )
        let later = formatter.date(from: "2026-10-03 21:30")!
        XCTAssertNotEqual(
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: due, isAllDay: false),
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: later, isAllDay: false)
        )

        // 全天：同日不同入库时刻指纹一致
        let allDayA = formatter.date(from: "2026-10-03 00:05")!
        let allDayB = formatter.date(from: "2026-10-03 09:00")!
        XCTAssertEqual(
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: allDayA, isAllDay: true),
            HoloTodayReliefPolicy.deadlineFingerprint(dueDate: allDayB, isAllDay: true)
        )

        // 无截止 → nil（无需确认）
        XCTAssertNil(HoloTodayReliefPolicy.deadlineFingerprint(dueDate: nil, isAllDay: false))
    }

    func test_需要风险确认的期限范围() throws {
        let scope = makeScope("2026-10-03")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = tz

        // 今日 21:00 到期（非全天）→ 需要
        XCTAssertTrue(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: formatter.date(from: "2026-10-03 21:00")!, isAllDay: false, scope: scope))
        // 昨天到期 → 需要
        XCTAssertTrue(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: formatter.date(from: "2026-10-02 10:00")!, isAllDay: false, scope: scope))
        // 明天到期 → 不需要
        XCTAssertFalse(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: formatter.date(from: "2026-10-04 10:00")!, isAllDay: false, scope: scope))
        // 无截止 → 不需要
        XCTAssertFalse(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: nil, isAllDay: false, scope: scope))
        // 全天今日到期（日末口径，不从 00:00 开始催）→ 需要
        XCTAssertTrue(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: formatter.date(from: "2026-10-03 00:00")!, isAllDay: true, scope: scope))
        // 全天明日 → 不需要
        XCTAssertFalse(HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
            dueDate: formatter.date(from: "2026-10-04 00:00")!, isAllDay: true, scope: scope))
    }

    // MARK: - 日目标状态（§7.4）

    private func makeFacts(
        task: HoloTodayReliefPolicy.TaskFact,
        step: HoloTodayReliefPolicy.StepFact? = nil
    ) -> HoloTodayReliefPolicy.Facts {
        HoloTodayReliefPolicy.Facts(
            tasks: [task.id: task],
            steps: step.map { [$0.id: $0] } ?? [:]
        )
    }

    func test_目标状态_表格全分支() throws {
        let taskID = UUID()
        let stepID = UUID()

        // taskResult 未完成 → pending；完成 → goalReached
        var facts = makeFacts(task: .init(id: taskID, title: "报名", dueDate: nil, isAllDay: false, completed: false, visible: true))
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .taskResult), facts: facts), .pending)
        facts = makeFacts(task: .init(id: taskID, title: "报名", dueDate: nil, isAllDay: false, completed: true, visible: true))
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .taskResult), facts: facts), .goalReached)

        // existingStep：根完成 → goalReached（未做步骤不伪造完成）
        let doneStep = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskID, actionText: "看航班", doneWhen: nil, stateRaw: "pending", originRevisionID: UUID())
        facts = makeFacts(
            task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: true, visible: true),
            step: doneStep
        )
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: doneStep.originRevisionID, contentFingerprint: HoloTodayReliefPolicy.stepFingerprint(doneStep))), facts: facts), .goalReached)

        // 步骤完成、根未完成 → goalReached（今天推进到这里）
        let finishedStep = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskID, actionText: "看航班", doneWhen: nil, stateRaw: "done", originRevisionID: UUID())
        facts = makeFacts(
            task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: true),
            step: finishedStep
        )
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: finishedStep.originRevisionID, contentFingerprint: HoloTodayReliefPolicy.stepFingerprint(finishedStep))), facts: facts), .goalReached)

        // 步骤撤回（done → pending）→ 重新待推进
        let revertedStep = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskID, actionText: "看航班", doneWhen: nil, stateRaw: "pending", originRevisionID: finishedStep.originRevisionID)
        facts = makeFacts(
            task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: true),
            step: revertedStep
        )
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: revertedStep.originRevisionID, contentFingerprint: HoloTodayReliefPolicy.stepFingerprint(revertedStep))), facts: facts), .pending)

        // 执行版本变化但 ID/内容仍有效 → 继续使用（不能误报失效）
        let sameStepNewRevision = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskID, actionText: "看航班", doneWhen: nil, stateRaw: "pending", originRevisionID: UUID())
        facts = makeFacts(
            task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: true),
            step: sameStepNewRevision
        )
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: UUID(), contentFingerprint: HoloTodayReliefPolicy.stepFingerprint(sameStepNewRevision))), facts: facts), .pending)

        // 步骤内容被替换 → needsRecheck
        let changedStep = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskID, actionText: "改签航班", doneWhen: nil, stateRaw: "pending", originRevisionID: UUID())
        facts = makeFacts(
            task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: true),
            step: changedStep
        )
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: UUID(), contentFingerprint: "stale-fingerprint")), facts: facts), .needsRecheck(reason: "stepContentChanged"))

        // 步骤消失 → needsRecheck；任务不可见 → excluded
        facts = makeFacts(task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: true))
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .existingStep(stepID: stepID, originRevisionID: UUID(), contentFingerprint: "fp")), facts: facts), .needsRecheck(reason: "stepMissing"))
        facts = makeFacts(task: .init(id: taskID, title: "机票", dueDate: nil, isAllDay: false, completed: false, visible: false))
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: taskID, goal: .taskResult), facts: facts), .excluded(reason: "taskInvisible"))
        // 任务整行消失 → excluded
        XCTAssertEqual(HoloTodayReliefPolicy.goalState(entry: .init(taskID: UUID(), goal: .taskResult), facts: HoloTodayReliefPolicy.Facts()), .excluded(reason: "taskMissing"))
    }

    func test_引用校验_放下今日到期需确认() throws {
        let scope = makeScope("2026-10-03")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = tz
        let dueToday = formatter.date(from: "2026-10-03 21:00")!

        let taskID = UUID()
        let task = HoloTodayReliefPolicy.TaskFact(id: taskID, title: "报名", dueDate: dueToday, isAllDay: false, completed: false, visible: true)
        let facts = HoloTodayReliefPolicy.Facts(tasks: [taskID: task])

        // 无确认 → 拒绝
        let noAck = HoloTodayPlanPayload(selectionMode: .explicit, deferredTaskIDs: [taskID])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(noAck, facts: facts, scope: scope)) { error in
            guard case HoloTodayReliefPolicy.ValidationError.deadlineAcknowledgementRequired = error else {
                return XCTFail("期望需要确认，实得 \(error)")
            }
        }

        // 指纹不匹配 → 拒绝
        let staleAck = HoloTodayPlanPayload(
            selectionMode: .explicit,
            deferredTaskIDs: [taskID],
            deadlineAcknowledgements: [.init(taskID: taskID, deadlineFingerprint: "stale")]
        )
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(staleAck, facts: facts, scope: scope))

        // 有效确认 → 通过
        let validFingerprint = HoloTodayReliefPolicy.deadlineFingerprint(dueDate: dueToday, isAllDay: false)!
        let validAck = HoloTodayPlanPayload(
            selectionMode: .explicit,
            deferredTaskIDs: [taskID],
            deadlineAcknowledgements: [.init(taskID: taskID, deadlineFingerprint: validFingerprint)]
        )
        XCTAssertNoThrow(try HoloTodayReliefPolicy.validateReferences(validAck, facts: facts, scope: scope))

        // 期限被编辑 → 原确认失效
        let editedTask = HoloTodayReliefPolicy.TaskFact(id: taskID, title: "报名", dueDate: later(dueToday), isAllDay: false, completed: false, visible: true)
        let editedFacts = HoloTodayReliefPolicy.Facts(tasks: [taskID: editedTask])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(validAck, facts: editedFacts, scope: scope))
    }

    func test_引用校验_步骤归属与内容() throws {
        let scope = makeScope("2026-10-03")
        let taskA = UUID(), taskB = UUID(), stepID = UUID()
        let step = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskB, actionText: "看航班", doneWhen: "记下两个候选", stateRaw: "pending", originRevisionID: UUID())
        let facts = HoloTodayReliefPolicy.Facts(
            tasks: [
                taskA: .init(id: taskA, title: "A", dueDate: nil, isAllDay: false, completed: false, visible: true),
                taskB: .init(id: taskB, title: "B", dueDate: nil, isAllDay: false, completed: false, visible: true),
            ],
            steps: [stepID: step]
        )
        let fingerprint = HoloTodayReliefPolicy.stepFingerprint(step)

        // 跨任务 stepID → 拒绝（R31）
        let crossTask = HoloTodayPlanPayload(selectionMode: .explicit, entries: [
            .init(taskID: taskA, goal: .existingStep(stepID: stepID, originRevisionID: step.originRevisionID, contentFingerprint: fingerprint))
        ])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(crossTask, facts: facts, scope: scope)) { error in
            guard case HoloTodayReliefPolicy.ValidationError.stepNotInTask = error else {
                return XCTFail("期望步骤归属错误，实得 \(error)")
            }
        }

        // 内容指纹过期 → 拒绝
        let staleFingerprint = HoloTodayPlanPayload(selectionMode: .explicit, entries: [
            .init(taskID: taskB, goal: .existingStep(stepID: stepID, originRevisionID: step.originRevisionID, contentFingerprint: "stale"))
        ])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(staleFingerprint, facts: facts, scope: scope))

        // 有效步骤 → 通过
        let valid = HoloTodayPlanPayload(selectionMode: .explicit, entries: [
            .init(taskID: taskB, goal: .existingStep(stepID: stepID, originRevisionID: step.originRevisionID, contentFingerprint: fingerprint))
        ])
        XCTAssertNoThrow(try HoloTodayReliefPolicy.validateReferences(valid, facts: facts, scope: scope))

        // 已完成步骤作为目标 → 拒绝（应重新选择）
        let doneStep = HoloTodayReliefPolicy.StepFact(id: stepID, taskID: taskB, actionText: "看航班", doneWhen: nil, stateRaw: "done", originRevisionID: step.originRevisionID)
        let doneFacts = HoloTodayReliefPolicy.Facts(tasks: facts.tasks, steps: [stepID: doneStep])
        XCTAssertThrowsError(try HoloTodayReliefPolicy.validateReferences(valid, facts: doneFacts, scope: scope))
    }

    // MARK: - Helpers

    private func later(_ date: Date) -> Date {
        date.addingTimeInterval(3_600)
    }
}
