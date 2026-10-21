//
//  GoalPlanContractTests.swift
//  HoloTests
//
//  目标闭环·计划契约纯逻辑测试（最终规格 §6.1 / §6.2 / §6.4 / §6.5 / R12 / R26 / R27）
//  - v2 payload 编解码往返、旧版/未来版本/损坏信封分版
//  - goalScope 线上 ISO8601 编码与数值秒兼容解码、去重键
//  - 修正操作白名单形状校验
//  - 资金期次确定性演算：4800→3300、6000→3000、无剩余期次不除零、已过截止、已达成、可行性差额
//  - 半开窗口 [start, min(endExclusive, cutoff))
//

import XCTest
@testable import Holo

final class GoalPlanContractTests: XCTestCase {

    private let goalID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let revisionID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let reviewID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else {
            XCTFail("无效日期 \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return d
    }

    private func makePayload() -> GoalPlanPayloadV2 {
        let habitID = UUID()
        return GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(originalWish: "北海道旅行存钱", successCriteria: "出发前专款 18000 元", deadline: date("2027-02-01T00:00:00+08:00")),
            resultSource: GoalPlanResultSourceV2(sourceType: .ledger, sourceID: nil, unit: "元", aggregation: .sum,
                                                 comparison: .reach, targetValue: 18000, baselineValue: nil,
                                                 baselineObservedAt: nil, freshnessDays: nil,
                                                 ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: UUID())),
            bindings: [
                GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habitID, draftRef: nil, role: .constraint,
                                  effectiveFrom: date("2026-10-01T00:00:00+08:00"), effectiveThrough: date("2026-10-29T00:00:00+08:00"),
                                  displayTitle: "奶茶上限", isGoalOwned: true),
            ],
            fundSchedule: [GoalFundInstallmentV2(dueDate: date("2026-10-25T00:00:00+08:00"), amount: 3000, note: nil)],
            budgetRule: nil,
            constraints: [GoalConstraintRuleV2(bindingID: UUID(), habitID: habitID, draftRef: nil, limitValue: 2, unit: "杯", windowDays: 7, displayTitle: "奶茶上限")],
            review: GoalPlanReviewV2(cadenceDays: 7, nextReviewAt: date("2026-10-27T09:00:00+08:00"), observationWindowDays: 14, verificationFocus: ["奶茶次数"]),
            basis: GoalPlanDecisionBasisV2(origin: .workshop, sourceSessionID: UUID(), sourceReportMessageID: nil, confirmedAt: date("2026-10-20T10:00:00+08:00"))
        )
    }

    // MARK: - payload 编解码

    func testPayloadV2RoundTrip() throws {
        let payload = makePayload()
        let json = try GoalPlanPayloadCodec.encode(payload)
        guard case .current(let decoded) = GoalPlanPayloadCodec.decode(json) else {
            return XCTFail("应解码为 v2")
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.resultSource?.resolvedLedgerScope, .accountBalance)
        XCTAssertEqual(decoded.fundSchedule.first?.amount, Decimal(3000))
    }

    func testVersionTwoRemainsReadableAndNewRequirementRoundTrips() throws {
        var payload = makePayload()
        payload.schemaVersion = 2
        guard case .current(let old) = GoalPlanPayloadCodec.decode(try GoalPlanPayloadCodec.encode(payload)) else {
            return XCTFail("已有v2计划必须可读取")
        }
        XCTAssertEqual(old.bindings.count, 1)
        XCTAssertNil(old.bindings[0].requirement)
        payload.bindings[0].requirement = GoalBindingRequirement(metric: .eventCount, target: 2)
        guard case .current(let next) = GoalPlanPayloadCodec.decode(try GoalPlanPayloadCodec.encode(payload)) else {
            return XCTFail("新要求必须可读取")
        }
        XCTAssertEqual(next.schemaVersion, 3)
        XCTAssertEqual(next.bindings[0].requirement?.metric, .eventCount)
        XCTAssertEqual(next.bindings[0].requirement?.target, 2)
    }

    func testLegacyVersionOneIsNotTreatedAsCurrentPlan() {
        let legacy = #"{"schemaVersion":1,"planTitle":"旧共创","successEvidence":"x"}"#
        XCTAssertEqual(GoalPlanPayloadCodec.decode(legacy), .legacyDecisionSummary)
        XCTAssertEqual(GoalPlanPayloadCodec.decode(#"{"planTitle":"无版本号"}"#), .legacyDecisionSummary)
    }

    func testFutureSchemaIsReadOnlyNotOverwritten() {
        XCTAssertEqual(GoalPlanPayloadCodec.decode(#"{"schemaVersion":9,"foo":1}"#), .unsupportedFuture(version: 9))
    }

    func testEmptyAndCorruptedEnvelopes() {
        XCTAssertEqual(GoalPlanPayloadCodec.decode(nil), .empty)
        XCTAssertEqual(GoalPlanPayloadCodec.decode(""), .empty)
        XCTAssertEqual(GoalPlanPayloadCodec.decode("not json"), .corrupted)
        XCTAssertEqual(GoalPlanPayloadCodec.decode(#"{"schemaVersion":2}"#), .corrupted, "v2 缺必填字段应判损坏而非空计划")
    }

    func testLedgerScopeNilKeepsLegacyWholeLedgerSemantics() {
        let source = GoalPlanResultSourceV2(sourceType: .ledger, sourceID: nil, unit: "元", aggregation: .sum,
                                            comparison: .reach, targetValue: 1000, baselineValue: nil,
                                            baselineObservedAt: nil, freshnessDays: nil, ledgerScope: nil)
        XCTAssertEqual(source.resolvedLedgerScope, .wholeLedgerDelta)
        XCTAssertEqual(GoalLedgerScopeKind.wholeLedgerDelta.rawValue, "whole_ledger_delta")
        XCTAssertEqual(GoalLedgerScopeKind.accountBalance.rawValue, "account_balance")
    }

    func testBindingEffectiveWindowAndEnd() {
        var binding = makePayload().bindings[0]
        XCTAssertFalse(binding.isEffective(at: date("2026-09-30T23:59:59+08:00")))
        XCTAssertTrue(binding.isEffective(at: date("2026-10-01T00:00:00+08:00")))
        XCTAssertTrue(binding.isEffective(at: date("2026-10-28T23:59:59+08:00")))
        XCTAssertFalse(binding.isEffective(at: date("2026-10-29T00:00:00+08:00")), "effectiveThrough 为开区间上界")
        binding.endedAt = date("2026-10-10T00:00:00+08:00")
        XCTAssertFalse(binding.isEffective(at: date("2026-10-05T00:00:00+08:00")), "已结束绑定不再生效")
    }

    func testStableBindingIDIsDeterministic() {
        let entity = UUID()
        let a = GoalPlanBindingV2.stableID(entityType: .task, entityID: entity)
        let b = GoalPlanBindingV2.stableID(entityType: .task, entityID: entity)
        let c = GoalPlanBindingV2.stableID(entityType: .habit, entityID: entity)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - goalScope

    func testGoalScopeEncodesISO8601AndDecodesBothForms() throws {
        let scope = HoloAgentGoalScope(goalID: goalID, planRevisionID: revisionID, reviewID: reviewID,
                                       windowStart: date("2026-10-01T00:00:00+08:00"),
                                       windowEndExclusive: date("2026-10-15T00:00:00+08:00"),
                                       snapshotCutoffAt: date("2026-10-15T09:00:00+08:00"),
                                       timeZoneID: "Asia/Shanghai", sourceDigest: "abc")
        let data = try JSONEncoder().encode(scope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["goalID"] as? String, goalID.uuidString)
        XCTAssertTrue((object["windowStart"] as? String)?.hasSuffix("Z") == true, "线上日期为 ISO8601 字符串")

        let decoded = try JSONDecoder().decode(HoloAgentGoalScope.self, from: data)
        XCTAssertEqual(decoded, scope)

        let numeric = """
        {"goalID":"\(goalID.uuidString)","planRevisionID":"\(revisionID.uuidString)","reviewID":"\(reviewID.uuidString)",
         "windowStart":1759276800,"windowEndExclusive":1760486400000,"snapshotCutoffAt":1760518800,
         "timeZoneID":"Asia/Shanghai","sourceDigest":"abc"}
        """
        let fromNumeric = try JSONDecoder().decode(HoloAgentGoalScope.self, from: Data(numeric.utf8))
        XCTAssertEqual(fromNumeric.windowStart, Date(timeIntervalSince1970: 1_759_276_800))
        XCTAssertEqual(fromNumeric.windowEndExclusive, Date(timeIntervalSince1970: 1_760_486_400), "毫秒值应被识别")
        XCTAssertEqual(fromNumeric.schemaVersion, 1, "缺省 schemaVersion 回退 1")
    }

    func testGoalScopeDedupeKeyIgnoresReviewIDAndCutoff() {
        let base = HoloAgentGoalScope(goalID: goalID, planRevisionID: revisionID, reviewID: reviewID,
                                      windowStart: date("2026-10-01T00:00:00+08:00"),
                                      windowEndExclusive: date("2026-10-15T00:00:00+08:00"),
                                      snapshotCutoffAt: date("2026-10-15T09:00:00+08:00"),
                                      timeZoneID: "Asia/Shanghai", sourceDigest: "d1")
        var retry = base
        retry.reviewID = UUID()
        retry.snapshotCutoffAt = date("2026-10-15T09:05:00+08:00")
        XCTAssertEqual(base.dedupeKey, retry.dedupeKey, "点击时间不能成为去重键")
        var changed = base
        changed.sourceDigest = "d2"
        XCTAssertNotEqual(base.dedupeKey, changed.dedupeKey, "依据变化生成新报告")
    }

    // MARK: - 修正操作白名单

    func testAdjustmentOperationShapeValidation() {
        var op = GoalAdjustmentOperationV2(id: "op-1", kind: .createTask)
        XCTAssertThrowsError(try op.validateShape(), "create_task 缺 spec/draftRef 应被拒")
        op.draftRef = "t1"
        op.taskSpec = GoalAdjustmentTaskSpecV2(title: "预约课程")
        XCTAssertNoThrow(try op.validateShape())

        var end = GoalAdjustmentOperationV2(id: "op-2", kind: .endBinding)
        XCTAssertThrowsError(try end.validateShape())
        end.targetBindingID = UUID()
        XCTAssertNoThrow(try end.validateShape())

        var fund = GoalAdjustmentOperationV2(id: "op-3", kind: .updateFundSchedule, fundSchedule: [])
        XCTAssertThrowsError(try fund.validateShape(), "空期次不接受")
        fund.fundSchedule = [GoalFundInstallmentV2(dueDate: Date(), amount: 3300)]
        XCTAssertNoThrow(try fund.validateShape())

        let criteria = GoalAdjustmentOperationV2(id: "op-4", kind: .changeSuccessCriteria,
                                                 criteriaChange: GoalAdjustmentCriteriaChangeV2(newTargetValue: 15000))
        XCTAssertNoThrow(try criteria.validateShape())
        XCTAssertTrue(criteria.kind.requiresSeparateConfirmation, "改成果标准必须单独确认")
        XCTAssertFalse(GoalAdjustmentOperationKind.updateHabit.requiresSeparateConfirmation)
    }

    func testAdjustmentDraftExpiryAndSelection() {
        let created = date("2026-10-20T10:00:00+08:00")
        let draft = GoalAdjustmentDraftV2(
            draftID: UUID(), goalID: goalID, baseRevisionID: revisionID, sourceReportMessageID: UUID(),
            sourceDigest: "d1", createdAt: created, expiresAt: created.addingTimeInterval(GoalAdjustmentDraftV2.defaultValidity),
            operations: [
                GoalAdjustmentOperationV2(id: "a", kind: .updateReview, isSelected: true, review: GoalPlanReviewV2.weeklyDefault(now: created)),
                GoalAdjustmentOperationV2(id: "b", kind: .changeSuccessCriteria, isSelected: false,
                                          criteriaChange: GoalAdjustmentCriteriaChangeV2(newDeadline: created)),
            ],
            expectedObservation: nil
        )
        XCTAssertFalse(draft.isExpired(at: created.addingTimeInterval(3600)))
        XCTAssertTrue(draft.isExpired(at: created.addingTimeInterval(GoalAdjustmentDraftV2.defaultValidity)))
        XCTAssertEqual(draft.selectedOperations.map(\.id), ["a"], "取消的操作不进提交")
        XCTAssertFalse(draft.containsSeparateConfirmationChanges, "未选中的成果变更不触发单独确认")
    }

    // MARK: - 资金期次演算（R26 / R27）

    private func schedule() -> [GoalFundInstallmentV2] {
        ["2026-09-25", "2026-10-25", "2026-11-25", "2026-12-25", "2027-01-25", "2027-02-10"].map {
            GoalFundInstallmentV2(dueDate: date("\($0)T00:00:00+08:00"), amount: 3000)
        }
    }

    func testTwoPeriodsIn_4800_yields_3300_perRemainingInstallment() {
        let outcome = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 4800, schedule: schedule(),
                                                    cutoff: date("2026-11-01T09:00:00+08:00"),
                                                    deadline: date("2027-02-14T00:00:00+08:00"))
        XCTAssertEqual(outcome.plannedToDate, 6000)
        XCTAssertEqual(outcome.shortfallToDate, 1200)
        XCTAssertEqual(outcome.remainingInstallments.count, 4)
        XCTAssertEqual(outcome.remainingAmount, 13200)
        XCTAssertEqual(outcome.suggestedPerInstallment, 3300)
        XCTAssertEqual(outcome.status, .behind)
    }

    func testReplenishedTo_6000_recomputes_3000() {
        let outcome = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 6000, schedule: schedule(),
                                                    cutoff: date("2026-11-01T09:00:00+08:00"),
                                                    deadline: date("2027-02-14T00:00:00+08:00"))
        XCTAssertEqual(outcome.suggestedPerInstallment, 3000, "补记后旧 3300 建议失效")
        XCTAssertEqual(outcome.shortfallToDate, 0)
        XCTAssertEqual(outcome.status, .onTrack)
    }

    func testNoRemainingInstallmentsDoesNotDivideByZero() {
        let outcome = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 10000, schedule: schedule(),
                                                    cutoff: date("2027-02-11T00:00:00+08:00"), deadline: nil)
        XCTAssertEqual(outcome.status, .noRemainingInstallments)
        XCTAssertNil(outcome.suggestedPerInstallment)
        XCTAssertEqual(outcome.remainingAmount, 8000)
    }

    func testDeadlinePassedAndAchieved() {
        let passed = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 10000, schedule: schedule(),
                                                   cutoff: date("2027-02-14T00:00:00+08:00"),
                                                   deadline: date("2027-02-14T00:00:00+08:00"))
        XCTAssertEqual(passed.status, .deadlinePassed, "截止当日视为已过截止")
        XCTAssertNil(passed.suggestedPerInstallment)

        let achieved = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 18000, schedule: schedule(),
                                                     cutoff: date("2026-11-01T00:00:00+08:00"), deadline: nil)
        XCTAssertEqual(achieved.status, .achieved)
        XCTAssertEqual(achieved.remainingAmount, 0)
    }

    func testAheadStatusAndRoundingToTwoDecimals() {
        let ahead = GoalFundScheduleMath.evaluate(target: 18000, currentFunds: 7000, schedule: schedule(),
                                                  cutoff: date("2026-11-01T00:00:00+08:00"), deadline: nil)
        XCTAssertEqual(ahead.status, .ahead)
        XCTAssertEqual(ahead.suggestedPerInstallment, 2750)
        let odd = GoalFundScheduleMath.evaluate(target: 10000, currentFunds: 0, schedule: Array(schedule().suffix(3)),
                                                cutoff: date("2026-11-01T00:00:00+08:00"), deadline: nil)
        XCTAssertEqual(odd.suggestedPerInstallment, Decimal(string: "3333.33"))
    }

    func testFeasibilityHighlightsUncoveredGap() {
        let feasibility = GoalFundScheduleMath.feasibility(suggestedPerInstallment: 3300,
                                                           historicalContributions: [2400, 2400],
                                                           expectedReliefPerInstallment: 600)
        XCTAssertEqual(feasibility.historicalAverage, 2400)
        XCTAssertEqual(feasibility.increaseOverHistory, 900)
        XCTAssertEqual(feasibility.uncoveredAfterRelief, 300, "预计省 600 仍差 300，不能记成到账")
        let none = GoalFundScheduleMath.feasibility(suggestedPerInstallment: nil, historicalContributions: [1], expectedReliefPerInstallment: nil)
        XCTAssertNil(none.historicalAverage)
    }

    // MARK: - 时间窗口（R12）

    func testObservationWindowIsHalfOpenAndCutoffBounded() {
        let window = GoalObservationWindow(start: date("2026-10-01T00:00:00+08:00"),
                                           endExclusive: date("2026-10-15T00:00:00+08:00"),
                                           cutoff: date("2026-10-10T09:00:00+08:00"),
                                           timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(window.effectiveEndExclusive, date("2026-10-10T09:00:00+08:00"), "上界取 min(endExclusive, cutoff)")
        XCTAssertTrue(window.contains(date("2026-10-01T00:00:00+08:00")))
        XCTAssertFalse(window.contains(date("2026-09-30T23:59:59+08:00")))
        XCTAssertFalse(window.contains(date("2026-10-10T09:00:00+08:00")), "cutoff 当刻不含")
        XCTAssertFalse(window.contains(date("2026-10-12T00:00:00+08:00")), "cutoff 之后的未来记录不含")
    }

    func testTrailingDaysWindowRespectsTimeZoneDayBoundary() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let cutoff = date("2026-10-20T15:30:00+08:00")
        let window = GoalObservationWindow.trailingDays(14, cutoff: cutoff, timeZone: tz)
        XCTAssertEqual(window.start, date("2026-10-07T00:00:00+08:00"))
        XCTAssertEqual(window.endExclusive, date("2026-10-21T00:00:00+08:00"))
        XCTAssertEqual(window.effectiveEndExclusive, cutoff)
    }
}
