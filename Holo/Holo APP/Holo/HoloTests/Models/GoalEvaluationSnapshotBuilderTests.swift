//
//  GoalEvaluationSnapshotBuilderTests.swift
//  HoloTests
//
//  目标闭环·统一事实快照（最终规格 §6.2 / §6.3；验收 R08 R09 R10 R11 R12 R26 + legacy 基线幂等）
//  - 体重按 latest 读取，不受习惯自身 sum 聚合影响；无观测 = 未知不是 0
//  - 单账户余额：账户不存在是 unavailable，不是 0 元；全账本增量名称准确
//  - 数字习惯限制：记录 3 杯超出上限 2 杯；无记录判未知
//  - 结果独立：完成任务不改变资金
//  - 期次演算：两期后 4800 → 剩 4 期每期 3300
//  - legacy 基线：多次解析只建一版，绑定含既有专属任务/习惯
//  - 半开窗口：endExclusive 当刻与 cutoff 之后的记录不计
//

import XCTest
import CoreData
@testable import Holo

@MainActor
extension GoalEvaluationSnapshotBuilderTests {
    func testDailyConfirmationKeepsZeroDistinctFromUnknown() throws {
        let habit = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum, unit: "杯")
        habit.createdAt = daysAgo(30); habit.isBadHabit = true; try context.save()
        let day = calendar.startOfDay(for: daysAgo(1))
        XCTAssertNil(try habits.dailyConfirmation(for: habit, on: day))
        try habits.confirmDay(habitID: habit.id, day: day, status: .none)
        XCTAssertEqual(try habits.dailyConfirmation(for: habit, on: day)?.status, HabitDailyConfirmationStatus.none)
        XCTAssertTrue(try habits.dailyConfirmation(for: habit, on: day)?.isValid == true)
        XCTAssertTrue(habits.records(for: habit, on: day).isEmpty)
    }

    func testEditingQuantityInvalidatesConfirmationButNoteDoesNot() throws {
        let habit = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30); habit.isBadHabit = true
        let row = record(habit, daysAgo: 1, value: 1); try context.save()
        let day = row.attributedDay(dayEndMinutes: habit.dayEndMinutes)
        try habits.confirmDay(habitID: habit.id, day: day, status: .complete)
        row.note = "补充说明"; try context.save()
        XCTAssertEqual(try habits.dailyConfirmation(for: habit, on: day)?.isValid, true)
        row.valueDouble = 2; try context.save()
        XCTAssertEqual(try habits.dailyConfirmation(for: habit, on: day)?.isValid, false)
        XCTAssertThrowsError(try habits.confirmDay(habitID: habit.id, day: day, status: .none))
    }

    func testCurrentDayCannotBecomeACompleteZeroDay() throws {
        let habit = makeHabit(name: "宵夜", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30); habit.isBadHabit = true; try context.save()
        let day = habit.currentDay()
        XCTAssertThrowsError(try habits.confirmDay(habitID: habit.id, day: day, status: .none))
        try habits.confirmDay(habitID: habit.id, day: day, status: .asOf)
        XCTAssertEqual(try habits.dailyConfirmation(for: habit, on: day)?.status, .asOf)
        try habits.confirmDay(habitID: habit.id, day: day, status: .withdrawn)
        XCTAssertNil(try habits.dailyConfirmation(for: habit, on: day))
    }

    func testDailyConfirmationCannotInventCheckInOrEraseIt() throws {
        let habit = makeHabit(name: "按时上床", type: .checkIn, aggregation: .sum)
        habit.createdAt = daysAgo(30); try context.save()
        let day = calendar.startOfDay(for: daysAgo(1))
        XCTAssertThrowsError(try habits.confirmDay(habitID: habit.id, day: day, status: .met))
        try habits.confirmDay(habitID: habit.id, day: day, status: .notMet)
        XCTAssertTrue(habits.records(for: habit, on: day).isEmpty)
        _ = record(habit, daysAgo: 1); try context.save()
        XCTAssertThrowsError(try habits.confirmDay(habitID: habit.id, day: day, status: .notMet))
    }

    func testRequirementWindowUsesHabitSettlementDayBeforeDawn() throws {
        let habit = makeHabit(name: "凌晨结算", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30); habit.dayEndHour = 4
        let cutoff = calendar.date(byAdding: .hour, value: 2, to: calendar.startOfDay(for: now))!
        let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .action,
            requirement: GoalBindingRequirement(metric: .sum, target: 30))
        let observed = try XCTUnwrap(GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: cutoff))
        XCTAssertEqual(observed.windowEndExclusive, calendar.startOfDay(for: now))
        XCTAssertEqual(observed.expectedDays, 7)
        XCTAssertEqual(observed.windowStart, calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)))
    }

    func testOneActivityFeedsEventCountAndDistanceWithoutDuplication() throws {
        let habit = makeHabit(name: "跑步", type: .numeric, aggregation: .sum, unit: "公里")
        habit.createdAt = daysAgo(30)
        _ = record(habit, daysAgo: 1, value: 10); _ = record(habit, daysAgo: 2, value: 5); try context.save()
        let count = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            requirement: GoalBindingRequirement(metric: .eventCount, target: 3))
        let distance = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            requirement: GoalBindingRequirement(metric: .sum, target: 40))
        XCTAssertEqual(try GoalRequirementEvaluator.evaluate(binding: count, repository: habits, context: context, cutoff: now)?.value, 2)
        XCTAssertEqual(try GoalRequirementEvaluator.evaluate(binding: distance, repository: habits, context: context, cutoff: now)?.value, 15)
        XCTAssertEqual(habits.records(for: habit, from: daysAgo(6), through: now).count, 2)
    }

    func testLatestRequirementKeepsRealZeroAndNeverSumsMeasurements() throws {
        let habit = makeHabit(name: "测量", type: .numeric, aggregation: .latest)
        habit.createdAt = daysAgo(30)
        let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            requirement: GoalBindingRequirement(metric: .latest, target: 60))
        XCTAssertNil(try GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: now)?.value)
        _ = record(habit, daysAgo: 2, value: 60); _ = record(habit, daysAgo: 1, value: 0); try context.save()
        XCTAssertEqual(try GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: now)?.value, 0)
    }

    func testAsOfZeroIsKnownSoFarWithoutDeclaringDayComplete() throws {
        let habit = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum, unit: "杯")
        habit.createdAt = daysAgo(30); habit.isBadHabit = true; try context.save()
        try habits.confirmDay(habitID: habit.id, day: habit.currentDay(), status: .asOf)
        let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .constraint,
            requirement: GoalBindingRequirement(metric: .sum, target: 0, comparison: .stayBelow))
        let observation = try GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: now)
        XCTAssertEqual(observation?.value, 0)
        XCTAssertEqual(observation?.confirmedDays, 0)
        XCTAssertEqual(observation?.state, .observing)
        XCTAssertTrue(habits.records(for: habit, on: habit.currentDay()).isEmpty)
    }

    func testLocalRequirementExcludesRecordsBeforeBindingBecameEffective() throws {
        let habit = makeHabit(name: "跑步", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30)
        _ = record(habit, daysAgo: 5, value: 30); _ = record(habit, daysAgo: 1, value: 5); try context.save()
        let start = daysAgo(2, hour: 0)
        let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            effectiveFrom: start, requirement: GoalBindingRequirement(metric: .sum, target: 40))
        let observation = try GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: now)
        XCTAssertEqual(observation?.value, 5)
        XCTAssertEqual(observation?.recordNotBefore, start)
    }

    func testLatestMeasurementUpperLimitUsesObservationRatherThanDailyCoverage() throws {
        let habit = makeHabit(name: "体重", type: .numeric, aggregation: .latest)
        habit.createdAt = daysAgo(30)
        _ = record(habit, daysAgo: 1, value: 65); try context.save()
        let binding = GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            requirement: GoalBindingRequirement(metric: .latest, target: 66, comparison: .stayBelow))
        let observation = try GoalRequirementEvaluator.evaluate(binding: binding, repository: habits, context: context, cutoff: now)
        XCTAssertEqual(observation?.value, 65)
        XCTAssertEqual(observation?.state, .met)
    }

    func testGoalLocalPlanEditKeepsSharedHabitDefaultsAndCreatesOneVersion() throws {
        let goal = makeGoal(), habit = makeHabit(name: "运动", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30); habit.targetValue = 9; try context.save()
        let base = try GoalPlanResolver.resolveCurrentPlan(goal: goal, in: context, persist: true)
        var payload = base.payload
        payload.bindings.append(GoalPlanBindingV2(id: UUID(), entityType: .habit, entityID: habit.id, role: .result,
            requirement: GoalBindingRequirement(metric: .eventCount, target: 2)))
        let op = UUID()
        XCTAssertThrowsError(try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: base.revisionID,
            payload: payload, operationID: op, successChangeConfirmed: false, in: context))
        try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: base.revisionID,
            payload: payload, operationID: op, successChangeConfirmed: true, in: context)
        try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: base.revisionID,
            payload: payload, operationID: op, successChangeConfirmed: true, in: context)
        XCTAssertEqual(habit.targetValue?.doubleValue, 9)
        XCTAssertNil(habit.goal)
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 2)
    }

    func testDeletingHabitCascadesDailyConfirmations() throws {
        let habit = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum)
        habit.createdAt = daysAgo(30); habit.isBadHabit = true; try context.save()
        try habits.confirmDay(habitID: habit.id, day: calendar.startOfDay(for: daysAgo(1)), status: .none)
        context.delete(habit); try context.save()
        let request = NSFetchRequest<HabitDailyConfirmationMO>(entityName: "HabitDailyConfirmationMO")
        XCTAssertEqual(try context.count(for: request), 0)
    }
}

@MainActor
final class GoalEvaluationSnapshotBuilderTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var finance: FinanceRepository!
    private var budget: BudgetRepository!
    private var habits: HabitRepository!
    private var builder: GoalEvaluationSnapshotBuilder!
    private let calendar = Calendar.current
    private let timeZone = TimeZone.current

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, [
            "Goal", "GoalMetricLog", "GoalPlanRevisionMO", "GoalReviewLinkMO", "GoalWorkshopSessionMO",
            "Habit", "HabitRecord", "TodoTask", "Account", "Transaction", "Budget",
        ])
        finance = FinanceRepository(context: context)
        budget = BudgetRepository(testContext: context)
        habits = HabitRepository(context: context, observesRemoteChanges: false)
        CoreDataTestSupport.retain(finance, budget, habits)
        builder = GoalEvaluationSnapshotBuilder(context: context,
                                                financeRepository: finance,
                                                budgetRepository: budget,
                                                habitRepository: habits,
                                                calendar: calendar)
        CoreDataTestSupport.retain(builder)
    }

    // MARK: - 夹具

    private var now: Date { Date() }

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }

    private func makeGoal(title: String = "测试目标",
                          kind: GoalKind = .process,
                          source: GoalMetricSource = .manual,
                          target: Double? = nil,
                          sourceHabitId: UUID? = nil) -> Goal {
        let goal = Goal.create(in: context, title: title, summary: nil, domain: .finance,
                               desiredOutcome: "想要的结果", motivation: nil, deadline: nil, allowAIContext: true)
        goal.goalKindEnum = kind
        if kind != .process {
            goal.metricSourceEnum = source
            goal.metricTargetValueDouble = target
            goal.sourceHabitId = sourceHabitId
            goal.baselineDate = daysAgo(60)
        }
        return goal
    }

    private func makeHabit(name: String, type: HabitType, aggregation: HabitAggregationType, unit: String? = nil) -> Habit {
        Habit.create(in: context, name: name, icon: "drop.fill", color: "#3B82F6", type: type,
                     frequency: .daily, targetCount: 1, targetValue: nil, unit: unit, aggregationType: aggregation)
    }

    @discardableResult
    private func record(_ habit: Habit, daysAgo days: Int, value: Double? = nil, completed: Bool = true, at date: Date? = nil) -> HabitRecord {
        let r = NSEntityDescription.insertNewObject(forEntityName: "HabitRecord", into: context) as! HabitRecord
        r.id = UUID()
        r.habitId = habit.id
        r.habit = habit
        r.date = date ?? daysAgo(days)
        r.isCompleted = completed
        r.value = value.map { NSNumber(value: $0) }
        r.createdAt = r.date
        return r
    }

    private func makeAccount(name: String = "旅行", type: AccountType = .bank, initial: Decimal = 0) -> Account {
        Account.create(in: context, name: name, type: type.rawValue, initialBalance: NSDecimalNumber(decimal: initial))
    }

    @discardableResult
    private func income(_ amount: Decimal, account: Account, daysAgo days: Int) -> Transaction {
        let tx = Transaction(context: context)
        tx.id = UUID()
        tx.amount = NSDecimalNumber(decimal: amount)
        tx.type = TransactionType.income.rawValue
        tx.date = daysAgo(days)
        tx.account = account
        tx.createdAt = tx.date
        tx.updatedAt = tx.date
        return tx
    }

    private func plan(for goal: Goal, payload: GoalPlanPayloadV2) throws -> GoalResolvedPlan {
        let row = try GoalPlanRevisionStore.makeRevisionRow(in: context, goalID: goal.id, sourceSessionID: nil,
                                                            revisionNumber: 1, baseRevisionID: nil, operationID: nil,
                                                            effectiveFrom: daysAgo(60), payload: payload, legacySummary: nil)
        try context.save()
        return GoalResolvedPlan(revisionID: row.id, revisionNumber: 1, payload: payload, didCreateBaseline: false)
    }

    private func basis() -> GoalPlanDecisionBasisV2 {
        GoalPlanDecisionBasisV2(origin: .workshop, sourceSessionID: nil, sourceReportMessageID: nil, confirmedAt: daysAgo(60))
    }

    private func window(days: Int = 14) -> GoalObservationWindow {
        GoalObservationWindow.trailingDays(days, cutoff: now, timeZone: timeZone)
    }

    private func fundSchedule() -> [GoalFundInstallmentV2] {
        [-40, -10, 20, 50, 80, 110].map { offset in
            GoalFundInstallmentV2(dueDate: calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!, amount: 3000)
        }
    }

    // MARK: - R08 体重

    func testWeightUsesLatestObservationEvenWhenHabitIsSumAggregated() throws {
        let weight = makeHabit(name: "体重", type: .numeric, aggregation: .sum, unit: "kg")
        record(weight, daysAgo: 3, value: 70)
        record(weight, daysAgo: 1, value: 69.5)
        let goal = makeGoal(kind: .target, source: .habit, target: 65, sourceHabitId: weight.id)
        try context.save()

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(successCriteria: "体重到 65kg"),
            resultSource: GoalPlanResultSourceV2(sourceType: .habit, sourceID: weight.id, unit: "kg", aggregation: .latest,
                                                 comparison: .trendDown, targetValue: 65, baselineValue: 72,
                                                 baselineObservedAt: daysAgo(60), freshnessDays: 14, ledgerScope: nil),
            bindings: [], basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())

        XCTAssertEqual(snapshot.result.status, .observed)
        XCTAssertEqual(snapshot.result.value, 69.5, "体重取最新观测，不是 139.5 的 sum")
        XCTAssertEqual(snapshot.result.sourceLabel, "体重")
        XCTAssertEqual(snapshot.result.progressFraction.map { ($0 * 1000).rounded() / 1000 }, (2.5 / 7.0 * 1000).rounded() / 1000)
    }

    func testWeightWithoutObservationIsMissingNotZero() throws {
        let weight = makeHabit(name: "体重", type: .numeric, aggregation: .latest, unit: "kg")
        let goal = makeGoal(kind: .target, source: .habit, target: 65, sourceHabitId: weight.id)
        try context.save()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(successCriteria: "体重到 65kg"),
            resultSource: GoalPlanResultSourceV2(sourceType: .habit, sourceID: weight.id, unit: "kg", aggregation: .latest,
                                                 comparison: .trendDown, targetValue: 65, baselineValue: 72,
                                                 baselineObservedAt: daysAgo(60), freshnessDays: 14, ledgerScope: nil),
            bindings: [], basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())
        XCTAssertEqual(snapshot.result.status, .missing)
        XCTAssertNil(snapshot.result.value, "缺测不是 0kg")
        XCTAssertNil(snapshot.result.progressFraction)
        XCTAssertTrue(snapshot.coverage.unknown.contains { $0.contains("体重") })
    }

    func testStaleObservationIsFlagged() throws {
        let weight = makeHabit(name: "体重", type: .numeric, aggregation: .latest, unit: "kg")
        record(weight, daysAgo: 30, value: 71)
        let goal = makeGoal(kind: .target, source: .habit, target: 65, sourceHabitId: weight.id)
        try context.save()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(),
            resultSource: GoalPlanResultSourceV2(sourceType: .habit, sourceID: weight.id, unit: "kg", aggregation: .latest,
                                                 comparison: .trendDown, targetValue: 65, baselineValue: 72,
                                                 baselineObservedAt: daysAgo(60), freshnessDays: 14, ledgerScope: nil),
            bindings: [], basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())
        XCTAssertEqual(snapshot.result.status, .stale)
        XCTAssertEqual(snapshot.result.value, 71, "过期观测仍展示，但不冒充最新")
    }

    // MARK: - R09 资金来源

    func testMissingAccountIsUnavailableNotZero() throws {
        let goal = makeGoal(kind: .cumulative, source: .ledger, target: 18000)
        try context.save()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(successCriteria: "专款 18000"),
            resultSource: GoalPlanResultSourceV2(sourceType: .ledger, sourceID: nil, unit: "元", aggregation: .sum,
                                                 comparison: .reach, targetValue: 18000, baselineValue: nil, baselineObservedAt: nil,
                                                 freshnessDays: nil, ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: UUID())),
            bindings: [], basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())
        XCTAssertEqual(snapshot.result.status, .unavailable)
        XCTAssertNil(snapshot.result.moneyValue, "账户不存在不是 0 元")
        XCTAssertEqual(snapshot.result.sourceLabel, "单账户余额")
        XCTAssertNil(snapshot.fundPlan, "无期次计划不输出资金演算")
    }

    func testDeletedAccountIsUnavailable() throws {
        let account = makeAccount()
        account.deletedAt = now
        let goal = makeGoal(kind: .cumulative, source: .ledger, target: 18000)
        try context.save()
        XCTAssertEqual(finance.accountBalanceObservation(accountId: account.id, before: now), .accountDeleted)
        XCTAssertEqual(finance.accountBalanceObservation(accountId: UUID(), before: now), .accountMissing)
        XCTAssertEqual(finance.getAccountCumulativeBalance(accountId: UUID(), before: now), 0, "统计页旧行为保持：缺失返回 0")
        _ = goal
    }

    func testAccountBalanceAndInstallmentMathYield3300() throws {
        let account = makeAccount(name: "旅行基金")
        income(2400, account: account, daysAgo: 35)
        income(2400, account: account, daysAgo: 5)
        let goal = makeGoal(title: "北海道旅行资金", kind: .cumulative, source: .ledger, target: 18000)
        goal.deadline = calendar.date(byAdding: .day, value: 120, to: now)
        try context.save()

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(successCriteria: "出发前专款 18000 元", deadline: goal.deadline),
            resultSource: GoalPlanResultSourceV2(sourceType: .ledger, sourceID: account.id, unit: "元", aggregation: .sum,
                                                 comparison: .reach, targetValue: 18000, baselineValue: nil, baselineObservedAt: nil,
                                                 freshnessDays: nil, ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)),
            bindings: [], fundSchedule: fundSchedule(), basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())

        XCTAssertEqual(snapshot.result.status, .observed)
        XCTAssertEqual(snapshot.result.moneyValue, 4800)
        XCTAssertEqual(snapshot.result.sourceLabel, "账户「旅行基金」余额")
        let fund = try XCTUnwrap(snapshot.fundPlan)
        XCTAssertEqual(fund.installmentsPast, 2)
        XCTAssertEqual(fund.outcome?.shortfallToDate, 1200)
        XCTAssertEqual(fund.outcome?.suggestedPerInstallment, 3300)
        XCTAssertEqual(fund.outcome?.status, .behind)
        XCTAssertFalse(snapshot.sourceDigest.isEmpty)
    }

    func testLegacyLedgerGoalReadsWholeLedgerDeltaWithAccurateName() throws {
        let account = makeAccount(name: "工资卡")
        income(500, account: account, daysAgo: 20)
        let goal = makeGoal(kind: .cumulative, source: .ledger, target: 1000)
        try context.save()

        let plan = try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)
        XCTAssertTrue(plan.didCreateBaseline)
        XCTAssertNil(plan.payload.resultSource?.ledgerScope, "老目标空 scope 不得静默切账户余额")
        XCTAssertEqual(plan.payload.resultSource?.resolvedLedgerScope, .wholeLedgerDelta)
        XCTAssertEqual(plan.payload.basis.origin, .legacy)

        let snapshot = builder.build(goal: goal, plan: plan, window: window())
        XCTAssertEqual(snapshot.result.sourceLabel, "全账本净结余增加")
        XCTAssertEqual(snapshot.result.moneyValue, 500)
        XCTAssertTrue(snapshot.result.note?.contains("不是专项旅行资金") == true)
    }

    // MARK: - R10 结果独立于执行

    func testCompletingSavingTaskDoesNotChangeFunds() throws {
        let account = makeAccount()
        income(4800, account: account, daysAgo: 5)
        let goal = makeGoal(kind: .cumulative, source: .ledger, target: 18000)
        let task = TodoTask.create(in: context, title: "本月存 3000", dueDate: daysAgo(1))
        task.goal = goal
        try context.save()

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(),
            resultSource: GoalPlanResultSourceV2(sourceType: .ledger, sourceID: account.id, unit: "元", aggregation: .sum,
                                                 comparison: .reach, targetValue: 18000, baselineValue: nil, baselineObservedAt: nil,
                                                 freshnessDays: nil, ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)),
            bindings: [GoalPlanBindingV2(id: UUID(), entityType: .task, entityID: task.id, draftRef: nil, role: .action,
                                         effectiveFrom: nil, effectiveThrough: nil, displayTitle: task.title)],
            basis: basis()
        )
        let resolved = try plan(for: goal, payload: payload)
        let before = builder.build(goal: goal, plan: resolved, window: window())
        XCTAssertEqual(before.executionSummary.tasksCompleted, 0)
        XCTAssertEqual(before.execution.first?.taskIsOverdue, true)

        task.completed = true
        task.completedAt = now
        try context.save()
        let after = builder.build(goal: goal, plan: resolved, window: window())
        XCTAssertEqual(after.executionSummary.tasksCompleted, 1, "执行侧变化")
        XCTAssertEqual(after.result.moneyValue, before.result.moneyValue, "完成存钱任务不增加资金")
        XCTAssertEqual(after.result.moneyValue, 4800)
        XCTAssertNotEqual(after.sourceDigest, before.sourceDigest, "执行变化属于依据变化")
    }

    // MARK: - R11 数字习惯限制

    func testThreeCupsBreachLimitWhileNoRecordsIsUnknown() throws {
        let milkTea = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum, unit: "杯")
        record(milkTea, daysAgo: 1, value: 1)
        record(milkTea, daysAgo: 2, value: 1)
        record(milkTea, daysAgo: 3, value: 1)
        let snack = makeHabit(name: "宵夜", type: .numeric, aggregation: .sum, unit: "次")
        let goal = makeGoal()
        try context.save()

        let teaBinding = UUID()
        let snackBinding = UUID()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(),
            resultSource: nil,
            bindings: [
                GoalPlanBindingV2(id: teaBinding, entityType: .habit, entityID: milkTea.id, draftRef: nil, role: .constraint,
                                  effectiveFrom: daysAgo(30), effectiveThrough: nil, displayTitle: "奶茶上限", isGoalOwned: false),
                GoalPlanBindingV2(id: snackBinding, entityType: .habit, entityID: snack.id, draftRef: nil, role: .constraint,
                                  effectiveFrom: daysAgo(30), effectiveThrough: nil, displayTitle: "宵夜上限", isGoalOwned: false),
            ],
            constraints: [
                GoalConstraintRuleV2(bindingID: teaBinding, habitID: milkTea.id, draftRef: nil, limitValue: 2, unit: "杯", windowDays: 7, displayTitle: "奶茶上限"),
                GoalConstraintRuleV2(bindingID: snackBinding, habitID: snack.id, draftRef: nil, limitValue: 1, unit: "次", windowDays: 7, displayTitle: "宵夜上限"),
            ],
            basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())

        XCTAssertEqual(snapshot.result.status, .notApplicable, "过程型目标没有结果量")
        let tea = try XCTUnwrap(snapshot.constraints.first { $0.id == teaBinding })
        XCTAssertEqual(tea.observedValue, 3)
        XCTAssertEqual(tea.isBreached, true, "记录 3 杯违反每周上限 2 杯")
        XCTAssertTrue(tea.hasRecords)
        let snackStatus = try XCTUnwrap(snapshot.constraints.first { $0.id == snackBinding })
        XCTAssertNil(snackStatus.isBreached, "缺记录不等于 0 次，无法判断")
        XCTAssertFalse(snackStatus.hasRecords)
        // 全局「今天有记录即算完成」规则不受影响：奶茶习惯昨天有记录
        XCTAssertEqual(snapshot.execution.first { $0.entityID == milkTea.id }?.habitRecordedDays, 3)
    }

    func testExplicitZeroRecordCountsAsRecordedNotMissing() throws {
        let milkTea = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum, unit: "杯")
        record(milkTea, daysAgo: 1, value: 0)
        let goal = makeGoal()
        try context.save()
        let bindingID = UUID()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(), resultSource: nil,
            bindings: [GoalPlanBindingV2(id: bindingID, entityType: .habit, entityID: milkTea.id, draftRef: nil, role: .constraint,
                                         effectiveFrom: daysAgo(30), effectiveThrough: nil, displayTitle: "奶茶上限", isGoalOwned: false)],
            constraints: [GoalConstraintRuleV2(bindingID: bindingID, habitID: milkTea.id, draftRef: nil, limitValue: 2, unit: "杯", windowDays: 7, displayTitle: "奶茶上限")],
            basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())
        let tea = try XCTUnwrap(snapshot.constraints.first)
        XCTAssertTrue(tea.hasRecords, "显式记录 0 杯是记录")
        XCTAssertEqual(tea.observedValue, 0)
        XCTAssertNil(tea.isBreached, "有真实零记录，但周期未结束不提前达成")
    }

    func testConstraintOnlyCountsRecordsAfterBindingEffectiveFrom() throws {
        let milkTea = makeHabit(name: "奶茶", type: .numeric, aggregation: .sum, unit: "杯")
        record(milkTea, daysAgo: 5, value: 5)   // 阶段生效前
        record(milkTea, daysAgo: 1, value: 1)   // 阶段生效后
        let goal = makeGoal()
        try context.save()
        let bindingID = UUID()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(), resultSource: nil,
            bindings: [GoalPlanBindingV2(id: bindingID, entityType: .habit, entityID: milkTea.id, draftRef: nil, role: .constraint,
                                         effectiveFrom: daysAgo(2, hour: 0), effectiveThrough: nil, displayTitle: "奶茶上限", isGoalOwned: false)],
            constraints: [GoalConstraintRuleV2(bindingID: bindingID, habitID: milkTea.id, draftRef: nil, limitValue: 2, unit: "杯", windowDays: 7, displayTitle: "奶茶上限")],
            basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window())
        XCTAssertEqual(snapshot.constraints.first?.observedValue, 1, "历史记录不按新规则重算")
        XCTAssertNil(snapshot.constraints.first?.isBreached, "周期未结束，不提前判定上限条件达成")
    }

    // MARK: - legacy 基线幂等（§6.1）

    func testLegacyBaselineIsCreatedOnceAndMergesOwnedObjects() throws {
        let goal = makeGoal(title: "旧目标")
        goal.source = "manual"
        let task = TodoTask.create(in: context, title: "旧任务")
        task.goal = goal
        let habit = makeHabit(name: "旧习惯", type: .checkIn, aggregation: .sum)
        habit.goal = goal
        try context.save()

        let first = try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)
        let second = try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)
        XCTAssertTrue(first.didCreateBaseline)
        XCTAssertFalse(second.didCreateBaseline)
        XCTAssertEqual(first.revisionID, second.revisionID)
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 1)
        XCTAssertEqual(first.payload.basis.origin, .manual)
        XCTAssertEqual(first.payload.review?.cadenceDays, 7, "默认每周回顾")

        let bindings = GoalPlanResolver.resolveBindings(goal: goal, payload: first.payload, at: now)
        XCTAssertEqual(bindings.count, 2)
        XCTAssertTrue(bindings.allSatisfy { $0.isOwnedByGoalRelationship && $0.binding.role == .action })
        XCTAssertEqual(Set(bindings.compactMap(\.binding.entityID)), [task.id, habit.id])
        // 原对象未被改写
        XCTAssertEqual(goal.source, "manual")
        XCTAssertEqual(task.goal?.id, goal.id)
    }

    func testOldWorkshopRevisionUpgradesWithSuccessEvidenceAndKeepsLineage() throws {
        let goal = makeGoal(title: "旧共创目标")
        let sessionID = UUID()
        goal.sourceSessionID = sessionID
        // 直接用 MO 工厂造 v1 行：避免在测试宿主内实例化第二个 Store（iOS 26.3 模拟器 malloc 双重释放已知坑）
        let v1 = GoalPlanRevisionMO.make(
            in: context, goalID: goal.id, sourceSessionID: sessionID, revisionNumber: 1,
            summary: GoalWorkshopDecisionSummaryV1(definition: nil, selectedRouteTitle: nil, planTitle: "旧共创目标",
                                                   successEvidence: "连续四周周会发言", assumptions: [],
                                                   firstActionTitle: nil, selectedTaskTitles: [], selectedHabitNames: [],
                                                   allowAIContext: true)
        )
        try context.save()

        let resolved = try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)
        XCTAssertTrue(resolved.didCreateBaseline)
        XCTAssertEqual(resolved.revisionNumber, 2)
        XCTAssertEqual(resolved.payload.intent.successCriteria, "连续四周周会发言")
        XCTAssertEqual(resolved.payload.basis.origin, .legacy)
        let row = try XCTUnwrap(GoalPlanRevisionStore.revisionRow(id: resolved.revisionID, in: context))
        XCTAssertEqual(row.baseRevisionID, v1.id, "保留 lineage")
        XCTAssertEqual(row.sourceSessionID, sessionID)
        // 旧 v1 行仍可读，且不被改写
        let rows = GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try rows[0].decodeSummary().successEvidence, "连续四周周会发言")
        XCTAssertEqual(rows[0].planPayloadDecodeResult, .legacyDecisionSummary)
    }

    func testFutureSchemaRevisionIsReadOnly() throws {
        let goal = makeGoal()
        try context.save()
        let row = GoalPlanRevisionMO(context: context)
        row.id = UUID()
        row.schemaVersion = 1
        row.goalID = goal.id
        row.sourceSessionID = GoalWorkshopSchemaDefaults.zeroUUID
        row.revisionNumber = 1
        row.decisionSummaryJSON = ""
        row.planPayloadJSON = #"{"schemaVersion":7,"future":true}"#
        row.createdAt = now
        row.updatedAt = now
        try context.save()

        XCTAssertThrowsError(try GoalPlanResolver.resolveCurrentPlan(goal: goal, now: now, in: context, persist: true)) { error in
            XCTAssertEqual(error as? GoalPlanResolveError, .unsupportedFutureSchema(version: 7))
        }
        XCTAssertEqual(GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: context).count, 1, "不得用空计划覆盖未来版本")
    }

    // MARK: - R12 半开窗口

    func testWindowExcludesRecordAtEndExclusiveAndAfterCutoff() throws {
        let reading = makeHabit(name: "听读", type: .numeric, aggregation: .sum, unit: "分钟")
        let cutoff = daysAgo(0, hour: 12)
        let window = GoalObservationWindow.trailingDays(7, cutoff: cutoff, timeZone: timeZone)
        record(reading, daysAgo: 0, value: 20, at: window.start)                                 // 起点含
        record(reading, daysAgo: 0, value: 30, at: cutoff.addingTimeInterval(-60))               // cutoff 前含
        record(reading, daysAgo: 0, value: 40, at: cutoff.addingTimeInterval(60))                // cutoff 后不含
        record(reading, daysAgo: 0, value: 50, at: window.endExclusive)                          // endExclusive 当刻不含
        record(reading, daysAgo: 0, value: 60, at: window.start.addingTimeInterval(-1))          // 起点前不含
        let goal = makeGoal(kind: .cumulative, source: .habit, target: 600, sourceHabitId: reading.id)
        try context.save()

        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(),
            resultSource: GoalPlanResultSourceV2(sourceType: .habit, sourceID: reading.id, unit: "分钟", aggregation: .sum,
                                                 comparison: .reach, targetValue: 600, baselineValue: nil, baselineObservedAt: nil,
                                                 freshnessDays: nil, ledgerScope: nil),
            bindings: [], basis: basis()
        )
        let snapshot = builder.build(goal: goal, plan: try plan(for: goal, payload: payload), window: window)
        XCTAssertEqual(snapshot.result.value, 50, "只计 [start, cutoff) 内的 20+30")
        XCTAssertEqual(snapshot.snapshotCutoffAt, cutoff)
        XCTAssertEqual(snapshot.timeZoneID, timeZone.identifier)
    }

    // MARK: - 回顾到期

    func testReviewDueState() throws {
        let goal = makeGoal()
        try context.save()
        let due = GoalPlanPayloadV2(intent: GoalPlanIntentV2(), resultSource: nil, bindings: [],
                                    review: GoalPlanReviewV2(cadenceDays: 7, nextReviewAt: daysAgo(1), observationWindowDays: 14, verificationFocus: []),
                                    basis: basis())
        XCTAssertTrue(builder.build(goal: goal, plan: try plan(for: goal, payload: due), window: window()).review.isDue)

        let off = GoalPlanPayloadV2(intent: GoalPlanIntentV2(), resultSource: nil, bindings: [],
                                    review: GoalPlanReviewV2(cadenceDays: nil, nextReviewAt: daysAgo(1), observationWindowDays: 14, verificationFocus: []),
                                    basis: basis())
        XCTAssertFalse(builder.build(goal: goal, plan: try plan(for: goal, payload: off), window: window()).review.isDue, "关闭定期回顾不再到期")
    }

    func testSourceDigestIsStableForSameFacts() throws {
        let weight = makeHabit(name: "体重", type: .numeric, aggregation: .latest, unit: "kg")
        record(weight, daysAgo: 1, value: 70)
        let goal = makeGoal(kind: .target, source: .habit, target: 65, sourceHabitId: weight.id)
        try context.save()
        let payload = GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(),
            resultSource: GoalPlanResultSourceV2(sourceType: .habit, sourceID: weight.id, unit: "kg", aggregation: .latest,
                                                 comparison: .trendDown, targetValue: 65, baselineValue: 72, baselineObservedAt: nil,
                                                 freshnessDays: nil, ledgerScope: nil),
            bindings: [], basis: basis()
        )
        let resolved = try plan(for: goal, payload: payload)
        let a = builder.build(goal: goal, plan: resolved, window: window(), now: now)
        let b = builder.build(goal: goal, plan: resolved, window: window(), now: now.addingTimeInterval(120))
        XCTAssertEqual(a.sourceDigest, b.sourceDigest, "生成时间不进摘要")
        record(weight, daysAgo: 0, value: 69, at: now.addingTimeInterval(-30))
        try context.save()
        let c = builder.build(goal: goal, plan: resolved, window: window())
        XCTAssertNotEqual(a.sourceDigest, c.sourceDigest, "新观测改变依据")
    }
}
