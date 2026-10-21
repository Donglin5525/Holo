//
//  GoalPlanCommitV2Tests.swift
//  HoloTests
//
//  目标闭环·首次建立提交 v2（最终规格 §3.1 / §6.1 / §6.5；验收 R04 R05 R06 R07 R08 R32 R33 R34）
//  - 预算与目标/任务/习惯/版本同一事务：预算构造失败不留半套数据
//  - 同账户同周期已有预算：冲突拒绝，不静默新建第二份；明确复用则只建绑定
//  - 复用既有习惯只建逻辑绑定，不抢它原来的 goal 父引用
//  - 新建数值习惯按草案聚合落库（体重 latest）
//  - v2 payload 版本行：operationID = 会话 id；幂等重放不升版、回执带 revisionID
//  - 资金期次 / 行为限制 / 待补齐来源进入生效计划
//  - 校验器：授权候选内的引用放行，候选外拒绝，未知枚举/越界拒绝
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalPlanCommitV2Tests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, [
            "GoalWorkshopSessionMO", "GoalPlanRevisionMO", "GoalReviewLinkMO",
            "Goal", "TodoTask", "Habit", "HabitRecord", "Account", "Budget", "TodoList", "CheckItem",
        ])
        resetHooks()
    }

    override func tearDown() async throws {
        resetHooks()
    }

    private func resetHooks() {
        GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex = nil
        GoalWorkshopCommitHooks.shared.shouldFailBudget = nil
        GoalWorkshopCommitHooks.shared.shouldFailSave = nil
    }

    // MARK: - 夹具

    private func count(_ entity: String, _ predicate: NSPredicate? = nil) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        return (try? context.count(for: request)) ?? -1
    }

    private func fetchGoal(id: UUID) -> Goal? {
        let request = NSFetchRequest<Goal>(entityName: "Goal")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func makeAccount(name: String = "旅行基金") -> Account {
        Account.create(in: context, name: name, type: AccountType.bank.rawValue)
    }

    private func makeDraft(title: String = "北海道旅行资金",
                           habits: [GoalHabitDraft] = [],
                           tasks: [GoalTaskDraft] = [GoalTaskDraft(id: "t1", isSelected: true, title: "本月存入 3000", dueDateText: "2026-11-25", priority: 1, note: nil)]) -> GoalDraft {
        GoalDraft(id: "d1", title: title, summary: nil, domain: .finance, iconEmoji: nil,
                  desiredOutcome: "出发前专款 18000", motivation: nil, deadlineText: "2027-02-10",
                  tasks: tasks, habits: habits, missingInfoWarnings: [])
    }

    private func ledgerConfirmation(accountID: UUID?, now: Date = Date()) -> GoalPlanConfirmation {
        var confirmation = GoalPlanConfirmation.defaults(from: makeDraft(), successEvidence: "出发前专款 18000 元", now: now)
        confirmation.resultSource = GoalPlanResultSourceV2(
            sourceType: .ledger, sourceID: accountID, unit: "元", aggregation: .sum, comparison: .reach,
            targetValue: 18000, baselineValue: nil, baselineObservedAt: nil, freshnessDays: nil,
            ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: accountID)
        )
        confirmation.fundSchedule = (1...6).map { index in
            GoalFundInstallmentV2(dueDate: Calendar.current.date(byAdding: .month, value: index, to: now)!, amount: 3000, note: nil)
        }
        return confirmation
    }

    @discardableResult
    private func commit(draft: GoalDraft, sessionID: UUID? = UUID(), confirmation: GoalPlanConfirmation?) throws -> GoalWorkshopCommitReceipt {
        try GoalWorkshopCommitService.performCommit(
            draft: draft, allowAIContext: true, source: "goalWorkshop", sourceSessionID: sessionID,
            successEvidence: confirmation?.successCriteria ?? "x", assumptions: [], selectedRouteTitle: nil,
            confirmation: confirmation, in: context
        )
    }

    private func latestPayload(goalID: UUID) throws -> GoalPlanPayloadV2 {
        let row = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goalID, in: context))
        return try XCTUnwrap(row.planPayloadV2)
    }

    // MARK: - 预算同事务（R07 / R33 / R32）

    func testBudgetCreatedInSameTransactionWithBindingAndPayload() throws {
        let account = makeAccount()
        try context.save()
        var confirmation = ledgerConfirmation(accountID: account.id)
        confirmation.budget = GoalBudgetConfirmation(id: UUID(), isSelected: true, title: "餐饮预算", accountID: account.id,
                                                     categoryID: nil, amount: 1500, period: "month",
                                                     startDate: Date(), reuseExistingBudgetID: nil)
        let receipt = try commit(draft: makeDraft(), confirmation: confirmation)

        XCTAssertEqual(receipt.createdBudgetCount, 1)
        XCTAssertEqual(count("Budget"), 1)
        XCTAssertEqual(count("Goal"), 1)
        let payload = try latestPayload(goalID: receipt.goalID)
        let rule = try XCTUnwrap(payload.budgetRule)
        XCTAssertEqual(rule.accountID, account.id)
        XCTAssertEqual(rule.amount, 1500)
        XCTAssertNil(rule.reuseExistingBudgetID)
        let binding = try XCTUnwrap(payload.binding(id: rule.bindingID))
        XCTAssertEqual(binding.entityType, .budget)
        XCTAssertEqual(binding.role, .constraint)
        XCTAssertTrue(binding.isGoalOwned)
        XCTAssertEqual(payload.fundSchedule.count, 6)
        XCTAssertEqual(payload.resultSource?.resolvedLedgerScope, .accountBalance)
        XCTAssertEqual(payload.resultSource?.ledgerScope?.accountID, account.id)
    }

    func testBudgetFailureLeavesNoPartialData() throws {
        let account = makeAccount()
        try context.save()
        var confirmation = ledgerConfirmation(accountID: account.id)
        confirmation.budget = GoalBudgetConfirmation(id: UUID(), isSelected: true, title: "餐饮预算", accountID: account.id,
                                                     categoryID: nil, amount: 1500, period: "month",
                                                     startDate: Date(), reuseExistingBudgetID: nil)
        GoalWorkshopCommitHooks.shared.shouldFailBudget = { true }

        XCTAssertThrowsError(try commit(draft: makeDraft(), confirmation: confirmation))
        context.rollback()
        XCTAssertEqual(count("Goal"), 0, "目标不得半成功")
        XCTAssertEqual(count("TodoTask"), 0)
        XCTAssertEqual(count("Budget"), 0)
        XCTAssertEqual(count("GoalPlanRevisionMO"), 0)
        XCTAssertEqual(count("Account"), 1, "别处已保存的数据不受影响")
    }

    func testExistingBudgetSamePeriodIsRejectedUnlessReused() throws {
        let account = makeAccount()
        _ = Budget.create(in: context, accountId: account.id, amount: NSDecimalNumber(value: 2000), period: .month, startDate: Date())
        try context.save()
        var confirmation = ledgerConfirmation(accountID: account.id)
        confirmation.budget = GoalBudgetConfirmation(id: UUID(), isSelected: true, title: "餐饮预算", accountID: account.id,
                                                     categoryID: nil, amount: 1500, period: "month",
                                                     startDate: Date(), reuseExistingBudgetID: nil)

        XCTAssertThrowsError(try commit(draft: makeDraft(), confirmation: confirmation)) { error in
            XCTAssertEqual(error as? GoalWorkshopCommitService.CommitError, .budgetConflict)
        }
        context.rollback()
        XCTAssertEqual(count("Goal"), 0)
        XCTAssertEqual(count("Budget"), 1, "不新建第二份预算")

        // 明确复用：只建绑定，不改既有预算金额
        let existing = try XCTUnwrap(GoalWorkshopCommitService.fetchBudget(accountID: account.id, categoryID: nil, period: "month", in: context))
        confirmation.budget?.reuseExistingBudgetID = existing.id
        let receipt = try commit(draft: makeDraft(), confirmation: confirmation)
        XCTAssertEqual(receipt.createdBudgetCount, 0)
        XCTAssertEqual(count("Budget"), 1)
        XCTAssertEqual(existing.amount.decimalValue, 2000, "复用不偷改既有预算")
        let payload = try latestPayload(goalID: receipt.goalID)
        XCTAssertEqual(payload.budgetRule?.reuseExistingBudgetID, existing.id)
        XCTAssertEqual(payload.budgetRule?.amount, 2000)
        XCTAssertEqual(payload.binding(id: payload.budgetRule!.bindingID)?.isGoalOwned, false)
    }

    func testUnselectedBudgetIsNotCommitted() throws {
        let account = makeAccount()
        try context.save()
        var confirmation = ledgerConfirmation(accountID: account.id)
        confirmation.budget = GoalBudgetConfirmation(id: UUID(), isSelected: false, title: "餐饮预算", accountID: account.id,
                                                     categoryID: nil, amount: 1500, period: "month",
                                                     startDate: Date(), reuseExistingBudgetID: nil)
        let receipt = try commit(draft: makeDraft(), confirmation: confirmation)
        XCTAssertEqual(count("Budget"), 0, "用户取消的预算不得偷偷提交")
        XCTAssertNil(try latestPayload(goalID: receipt.goalID).budgetRule)
    }

    // MARK: - 复用既有习惯不抢父引用（R06 / R30）

    func testReusedHabitKeepsOriginalGoalParentAndGetsLogicalBinding() throws {
        let otherGoal = Goal.create(in: context, title: "别的目标", summary: nil, domain: .health,
                                    desiredOutcome: nil, motivation: nil, deadline: nil, allowAIContext: true)
        let shared = Habit.create(in: context, name: "体重", icon: "scalemass", color: "#000", type: .numeric,
                                  unit: "kg", aggregationType: .latest)
        shared.goal = otherGoal
        try context.save()

        let draft = makeDraft(title: "减重到 65kg", habits: [
            GoalHabitDraft(id: "h-weight", isSelected: true, name: "体重", frequency: "daily", targetCount: 1, type: "numeric",
                           unit: "kg", targetValue: nil, isBadHabit: false, successRule: nil,
                           reuseHabitRef: "habit:\(shared.id.uuidString)", aggregation: "latest"),
            GoalHabitDraft(id: "h-run", isSelected: true, name: "慢跑", frequency: "weekly", targetCount: 3, type: "checkIn",
                           unit: nil, targetValue: nil, isBadHabit: false, successRule: nil),
        ], tasks: [])
        var confirmation = GoalPlanConfirmation.defaults(from: draft, successEvidence: "体重到 65kg", now: Date())
        confirmation.resultSource = GoalPlanResultSourceV2(sourceType: .habit, sourceID: shared.id, unit: "kg", aggregation: .latest,
                                                           comparison: .trendDown, targetValue: 65, baselineValue: 72,
                                                           baselineObservedAt: nil, freshnessDays: 14, ledgerScope: nil)
        let receipt = try commit(draft: draft, confirmation: confirmation)

        XCTAssertEqual(receipt.createdHabitCount, 1, "只新建慢跑")
        XCTAssertEqual(receipt.reusedHabitCount, 1)
        XCTAssertEqual(shared.goal?.id, otherGoal.id, "共享习惯父引用不被抢走")
        let newGoal = try XCTUnwrap(fetchGoal(id: receipt.goalID))
        XCTAssertEqual(newGoal.sortedHabits.map(\.name), ["慢跑"])
        XCTAssertEqual(newGoal.sourceHabitId, shared.id, "Goal 当前量化配置同步到共享来源")
        XCTAssertEqual(newGoal.goalKindEnum, .target)

        let payload = try latestPayload(goalID: receipt.goalID)
        let weightBinding = try XCTUnwrap(payload.bindings.first { $0.entityID == shared.id })
        XCTAssertEqual(weightBinding.role, .result)
        XCTAssertFalse(weightBinding.isGoalOwned)
        let runBinding = try XCTUnwrap(payload.bindings.first { $0.displayTitle == "慢跑" })
        XCTAssertTrue(runBinding.isGoalOwned)
        XCTAssertEqual(runBinding.role, .action)

        // 统一绑定解析：两者都可见、各一次
        let resolved = GoalPlanResolver.resolveBindings(goal: newGoal, payload: payload, at: Date())
        XCTAssertEqual(resolved.count, 2)
    }

    func testCreatedNumericHabitUsesDraftAggregation() throws {
        let draft = makeDraft(title: "减重", habits: [
            GoalHabitDraft(id: "h-weight", isSelected: true, name: "体重", frequency: "daily", targetCount: 1, type: "numeric",
                           unit: "kg", targetValue: nil, isBadHabit: false, successRule: nil, aggregation: "latest"),
            GoalHabitDraft(id: "h-read", isSelected: true, name: "听读", frequency: "daily", targetCount: 1, type: "numeric",
                           unit: "分钟", targetValue: 20, isBadHabit: false, successRule: nil),
        ], tasks: [])
        var confirmation = GoalPlanConfirmation.defaults(from: draft, successEvidence: "体重到 65kg", now: Date())
        confirmation.resultSource = GoalPlanResultSourceV2(sourceType: .habit, sourceID: nil, unit: "kg", aggregation: .latest,
                                                           comparison: .trendDown, targetValue: 65, baselineValue: 72,
                                                           baselineObservedAt: nil, freshnessDays: 14, ledgerScope: nil)
        confirmation.resultSourceHabitDraftID = "h-weight"
        let receipt = try commit(draft: draft, confirmation: confirmation)

        let habits = try context.fetch(NSFetchRequest<Habit>(entityName: "Habit"))
        let weight = try XCTUnwrap(habits.first { $0.name == "体重" })
        let reading = try XCTUnwrap(habits.first { $0.name == "听读" })
        XCTAssertEqual(weight.aggregationType, HabitAggregationType.latest.rawValue, "体重按 latest，不再固定 sum")
        XCTAssertEqual(reading.aggregationType, HabitAggregationType.sum.rawValue)

        let payload = try latestPayload(goalID: receipt.goalID)
        XCTAssertEqual(payload.resultSource?.sourceID, weight.id, "草案内新建习惯解析为真实 id")
        XCTAssertEqual(payload.resultSource?.isPending, false)
        XCTAssertEqual(payload.bindings.first { $0.entityID == weight.id }?.role, .result)
        XCTAssertFalse(receipt.resultSourcePending)
    }

    // MARK: - 版本行与幂等（R34）

    func testRevisionRowCarriesV2PayloadAndIdempotentReplayReturnsSameRevision() throws {
        let account = makeAccount()
        try context.save()
        let sessionID = UUID()
        let confirmation = ledgerConfirmation(accountID: account.id)
        let first = try commit(draft: makeDraft(), sessionID: sessionID, confirmation: confirmation)
        let row = try XCTUnwrap(GoalPlanRevisionStore.revisionRow(id: try XCTUnwrap(first.revisionID), in: context))
        XCTAssertEqual(row.operationID, sessionID)
        XCTAssertEqual(row.revisionNumber, 1)
        XCTAssertNil(row.baseRevisionID)
        XCTAssertNotNil(row.effectiveFrom)
        XCTAssertFalse(row.decisionSummaryJSON.isEmpty, "旧读者仍可读 v1 摘要")
        XCTAssertEqual(row.planPayloadDecodeResult, .current(try latestPayload(goalID: first.goalID)))

        let replay = try commit(draft: makeDraft(), sessionID: sessionID, confirmation: confirmation)
        XCTAssertTrue(replay.wasIdempotentReplay)
        XCTAssertEqual(replay.goalID, first.goalID)
        XCTAssertEqual(replay.revisionID, first.revisionID)
        XCTAssertEqual(count("Goal"), 1)
        XCTAssertEqual(count("GoalPlanRevisionMO"), 1, "重放不升版")
    }

    func testPayloadIntentAndOriginFromGoalWorkshop() throws {
        let account = makeAccount()
        try context.save()
        let receipt = try commit(draft: makeDraft(), confirmation: ledgerConfirmation(accountID: account.id))
        let payload = try latestPayload(goalID: receipt.goalID)
        XCTAssertEqual(payload.intent.successCriteria, "出发前专款 18000 元")
        XCTAssertEqual(payload.basis.origin, .workshop)
        XCTAssertEqual(payload.review?.cadenceDays, 7)
        XCTAssertEqual(payload.bindings.filter { $0.entityType == .task }.count, 1)
        XCTAssertEqual(payload.bindings.first { $0.entityType == .account }?.entityID, account.id)
        let goal = try XCTUnwrap(fetchGoal(id: receipt.goalID))
        XCTAssertEqual(goal.ledgerScope, GoalLedgerScopeKind.accountBalance.rawValue, "ledgerScope 从本期开始真实写入")
        XCTAssertEqual(goal.metricSourceEnum, .ledger)
        XCTAssertEqual(goal.metricTargetValueDouble, 18000)
    }

    // MARK: - 来源待补齐（R05）

    func testPendingAccountSourceStillCreatesPlan() throws {
        let receipt = try commit(draft: makeDraft(), confirmation: ledgerConfirmation(accountID: nil))
        XCTAssertTrue(receipt.resultSourcePending)
        XCTAssertEqual(count("Goal"), 1)
        XCTAssertEqual(count("TodoTask"), 1, "来源待补仍能开始执行")
        let payload = try latestPayload(goalID: receipt.goalID)
        XCTAssertEqual(payload.resultSource?.isPending, true)
        XCTAssertNil(payload.resultSource?.ledgerScope?.accountID)
        XCTAssertTrue(payload.bindings.filter { $0.entityType == .account }.isEmpty)
    }

    func testMissingAccountIsRejectedNotTreatedAsPending() throws {
        XCTAssertThrowsError(try commit(draft: makeDraft(), confirmation: ledgerConfirmation(accountID: UUID()))) { error in
            guard case .validation(let reason)? = error as? GoalWorkshopCommitService.CommitError else {
                return XCTFail("应为 validation 错误：\(error)")
            }
            XCTAssertTrue(reason.contains("账户"))
        }
        context.rollback()
        XCTAssertEqual(count("Goal"), 0)
    }

    // MARK: - 行为限制（R11 落库）

    func testConstraintsResolveDraftHabitsAndPersist() throws {
        let draft = makeDraft(title: "北海道旅行资金", habits: [
            GoalHabitDraft(id: "h-tea", isSelected: true, name: "奶茶", frequency: "daily", targetCount: 1, type: "numeric",
                           unit: "杯", targetValue: nil, isBadHabit: true, successRule: nil),
        ])
        let account = makeAccount()
        try context.save()
        var confirmation = ledgerConfirmation(accountID: account.id)
        let bindingID = UUID()
        let through = Calendar.current.date(byAdding: .day, value: 28, to: Date())
        confirmation.constraints = [
            GoalConstraintConfirmation(id: bindingID, isSelected: true, title: "奶茶每周不超过 2 杯", habitDraftID: "h-tea",
                                       habitID: nil, limitValue: 2, unit: "杯", windowDays: 7, effectiveThrough: through),
            GoalConstraintConfirmation(id: UUID(), isSelected: false, title: "已取消的限制", habitDraftID: "h-tea",
                                       habitID: nil, limitValue: 1, unit: "杯", windowDays: 7, effectiveThrough: nil),
        ]
        let receipt = try commit(draft: draft, confirmation: confirmation)
        let payload = try latestPayload(goalID: receipt.goalID)
        XCTAssertEqual(payload.constraints.count, 1, "取消的限制不提交")
        let rule = try XCTUnwrap(payload.constraints.first)
        let tea = try XCTUnwrap(try context.fetch(NSFetchRequest<Habit>(entityName: "Habit")).first { $0.name == "奶茶" })
        XCTAssertEqual(rule.habitID, tea.id)
        XCTAssertEqual(rule.limitValue, 2)
        XCTAssertEqual(rule.windowDays, 7)
        let binding = try XCTUnwrap(payload.binding(id: bindingID))
        XCTAssertEqual(binding.role, .constraint)
        XCTAssertEqual(try XCTUnwrap(binding.effectiveThrough).timeIntervalSince1970,
                       try XCTUnwrap(through).timeIntervalSince1970, accuracy: 0.001, "阶段性要求带结束日（毫秒精度落库）")
        XCTAssertTrue(binding.isGoalOwned)
    }

    // MARK: - 校验器放行/拒绝（R06）

    private func makeSession(candidates: GoalWorkshopAuthorizedCandidates?) -> GoalWorkshopSessionV1 {
        var session = GoalWorkshopSessionV1(originalText: "想攒钱去北海道", authorizedCandidates: candidates)
        session.phase = .choosing
        session.revision = 3
        return session
    }

    private func makePlanResponse(session: GoalWorkshopSessionV1, mutate: (inout GoalWorkshopPlan) -> Void) -> GoalWorkshopResponseV1 {
        var plan = GoalWorkshopPlan(
            draft: GoalDraft(id: "d", title: "北海道旅行资金", summary: nil, domain: .finance, iconEmoji: nil,
                             desiredOutcome: nil, motivation: nil, deadlineText: "2027-02-10",
                             tasks: [], habits: [
                                GoalHabitDraft(id: "h-tea", isSelected: true, name: "奶茶", frequency: "daily", targetCount: 1,
                                               type: "numeric", unit: "杯", targetValue: nil, isBadHabit: true, successRule: nil),
                             ], missingInfoWarnings: []),
            successEvidence: "出发前专款 18000", milestones: [], firstActionID: nil, assumptions: [], reviewDateText: nil
        )
        mutate(&plan)
        return GoalWorkshopResponseV1(sessionID: session.id, revision: session.revision, kind: .plan, plan: plan)
    }

    func testValidatorAllowsAuthorizedCandidatesAndRejectsOthers() throws {
        let habitID = UUID()
        let accountID = UUID()
        let candidates = GoalWorkshopAuthorizedCandidates(
            habits: [GoalWorkshopHabitCandidate(id: habitID, name: "体重", type: "numeric", unit: "kg", aggregation: "latest", isBadHabit: false)],
            accounts: [GoalWorkshopAccountCandidate(id: accountID, name: "旅行基金", type: "bank", isCreditLiability: false)]
        )
        let session = makeSession(candidates: candidates)

        // 放行：授权账户作为余额来源 + 期次 + 预算 + 限制指向草案习惯
        let ok = makePlanResponse(session: session) { plan in
            plan.resultSource = GoalWorkshopResultSourceDraft(sourceType: "ledger", ledgerScope: "account_balance",
                                                              candidateRef: "account:\(accountID.uuidString)", habitDraftID: nil,
                                                              unit: "元", aggregation: "sum", comparison: "reach",
                                                              targetValue: 18000, baselineValue: nil, isPending: nil)
            plan.fundSchedule = [GoalWorkshopFundInstallmentDraft(dueDateText: "2026-11-25", amount: 3000)]
            plan.budget = GoalWorkshopBudgetDraft(isSelected: true, amount: 1500, period: "month",
                                                  accountCandidateRef: "account:\(accountID.uuidString)", categoryName: "餐饮", note: nil)
            plan.constraints = [GoalWorkshopConstraintDraft(id: "c1", isSelected: true, title: "奶茶上限", habitDraftID: "h-tea",
                                                            habitCandidateRef: nil, limitValue: 2, unit: "杯", windowDays: 7)]
            plan.reviewCadenceDays = 7
        }
        XCTAssertNoThrow(try GoalWorkshopValidator.validate(ok, for: session))

        // 放行：授权习惯作为 sourceHabitId
        let okHabit = makePlanResponse(session: session) { plan in
            plan.draft.sourceHabitId = habitID
            plan.draft.habits[0].reuseHabitRef = "habit:\(habitID.uuidString)"
        }
        XCTAssertNoThrow(try GoalWorkshopValidator.validate(okHabit, for: session))

        // 拒绝：候选外的账户 / 习惯
        let badAccount = makePlanResponse(session: session) { plan in
            plan.resultSource = GoalWorkshopResultSourceDraft(sourceType: "ledger", ledgerScope: "account_balance",
                                                              candidateRef: "account:\(UUID().uuidString)", habitDraftID: nil,
                                                              unit: nil, aggregation: nil, comparison: nil, targetValue: nil, baselineValue: nil, isPending: nil)
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badAccount, for: session)) { error in
            guard case .unauthorizedCandidateReference? = error as? GoalWorkshopValidationError else { return XCTFail("\(error)") }
        }
        let badHabit = makePlanResponse(session: session) { plan in plan.draft.sourceHabitId = UUID() }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badHabit, for: session)) { error in
            XCTAssertEqual(error as? GoalWorkshopValidationError, .unauthorizedHabitReference)
        }
        // 无候选的旧会话：任何既有习惯引用都拒绝（旧行为保持）
        let legacy = makeSession(candidates: nil)
        let legacyResponse = makePlanResponse(session: legacy) { plan in plan.draft.sourceHabitId = habitID }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(legacyResponse, for: legacy))
    }

    func testValidatorRejectsUnknownEnumsAndOutOfBounds() throws {
        let session = makeSession(candidates: .empty)
        let badEnum = makePlanResponse(session: session) { plan in
            plan.resultSource = GoalWorkshopResultSourceDraft(sourceType: "crypto", ledgerScope: nil, candidateRef: nil, habitDraftID: nil,
                                                              unit: nil, aggregation: nil, comparison: nil, targetValue: nil, baselineValue: nil, isPending: nil)
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badEnum, for: session)) { error in
            guard case .unknownEnumValue(let field, _)? = error as? GoalWorkshopValidationError else { return XCTFail("\(error)") }
            XCTAssertEqual(field, "resultSource.sourceType")
        }
        let badWindow = makePlanResponse(session: session) { plan in
            plan.constraints = [GoalWorkshopConstraintDraft(id: "c1", isSelected: true, title: "x", habitDraftID: "h-tea",
                                                            habitCandidateRef: nil, limitValue: 2, unit: nil, windowDays: 400)]
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badWindow, for: session))
        let badPeriod = makePlanResponse(session: session) { plan in
            plan.budget = GoalWorkshopBudgetDraft(isSelected: true, amount: 100, period: "decade", accountCandidateRef: nil, categoryName: nil, note: nil)
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badPeriod, for: session))
        let badInstallment = makePlanResponse(session: session) { plan in
            plan.fundSchedule = [GoalWorkshopFundInstallmentDraft(dueDateText: "2026/11/25", amount: 3000)]
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(badInstallment, for: session)) { error in
            XCTAssertEqual(error as? GoalWorkshopValidationError, .invalidDateText("2026/11/25"))
        }
        let danglingDraft = makePlanResponse(session: session) { plan in
            plan.resultSource = GoalWorkshopResultSourceDraft(sourceType: "habit", ledgerScope: nil, candidateRef: nil, habitDraftID: "h-missing",
                                                              unit: nil, aggregation: "latest", comparison: nil, targetValue: nil, baselineValue: nil, isPending: nil)
        }
        XCTAssertThrowsError(try GoalWorkshopValidator.validate(danglingDraft, for: session)) { error in
            XCTAssertEqual(error as? GoalWorkshopValidationError, .danglingHabitDraftReference("h-missing"))
        }
    }

    func testV1PlanResponseWithoutExtensionsStillDecodes() throws {
        let session = makeSession(candidates: nil)
        let json = """
        {"schemaVersion":1,"sessionID":"\(session.id.uuidString)","revision":3,"kind":"plan",
         "plan":{"draft":{"id":"d","title":"旧草案","domain":"finance","tasks":[],"habits":[],"missingInfoWarnings":[]},
                 "successEvidence":"x","milestones":[],"assumptions":[]}}
        """
        let response = try JSONDecoder().decode(GoalWorkshopResponseV1.self, from: Data(json.utf8))
        XCTAssertNil(response.plan?.resultSource)
        XCTAssertNil(response.plan?.budget)
        XCTAssertNil(response.plan?.constraints)
        XCTAssertNoThrow(try GoalWorkshopValidator.validate(response, for: session))
        let confirmation = GoalPlanConfirmation.from(plan: response.plan!, candidates: .empty, now: Date())
        XCTAssertNil(confirmation.resultSource, "过程型旧草案无结果量")
        XCTAssertEqual(confirmation.review.cadenceDays, 7)
    }

    func testAuthorizedCandidateContextRefsCarryOnlySummaries() {
        let candidates = GoalWorkshopAuthorizedCandidates(
            habits: [GoalWorkshopHabitCandidate(id: UUID(), name: "体重", type: "numeric", unit: "kg", aggregation: "latest", isBadHabit: false)],
            accounts: [GoalWorkshopAccountCandidate(id: UUID(), name: "信用卡", type: "creditCard", isCreditLiability: true)]
        )
        let refs = candidates.contextRefs()
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs[0].sourceID.hasPrefix("habit:"))
        XCTAssertTrue(refs[0].summary.contains("体重") && refs[0].summary.contains("kg"))
        XCTAssertTrue(refs[1].summary.contains("信用负债"), "负债账户带标记，不能默认为专款")
        XCTAssertNotNil(candidates.habit(ref: refs[0].sourceID))
        XCTAssertNil(candidates.habit(ref: "habit:not-a-uuid"))
        XCTAssertNil(candidates.account(ref: refs[0].sourceID), "前缀不匹配不得串用")
    }
}
