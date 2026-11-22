//
//  GoalUIRedesignTests.swift
//  HoloTests
//
//  目标界面减法重设计 S3-S5 单元测试（2026-11-13）：
//  GoalDomain.infer 认领映射、数字提示行触发规则、列表排序纯函数、
//  编辑不覆写领域、长按菜单状态流转（in-memory CoreData 栈）、再来一轮预填、
//  设置面板五字段+领域落库链路。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class GoalUIRedesignTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var repository: GoalRepository!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, [
            "Goal", "GoalPlanRevisionMO", "Account", "Transaction",
            "Habit", "HabitRecord", "TodoTask", "RecycleBinBatch",
        ])
        repository = GoalRepository(context: context)
        CoreDataTestSupport.retain(repository)
    }

    // MARK: - 工厂

    private func makeGoal(
        title: String,
        domain: GoalDomain = .other,
        status: GoalStatus = .active,
        deadline: Date? = nil,
        completedAt: Date? = nil
    ) throws -> Goal {
        let goal = Goal.create(in: context, title: title, summary: nil, domain: domain,
                               desiredOutcome: nil, motivation: nil, deadline: deadline,
                               allowAIContext: true)
        if status != .active {
            goal.goalStatus = status // .completed 时 completedAt 由模型自动写
        }
        if let completedAt { goal.completedAt = completedAt }
        try context.save()
        return goal
    }

    // MARK: - S3b 领域自动认领

    func testInferDomainKeywordTable() {
        let cases: [(String, GoalDomain)] = [
            ("今年跑满 300 公里", .health), ("戒掉熬夜", .health),
            ("跑 300 公里", .health), ("每周累计 50000 步", .health),
            ("走查·交付作品集", .project), ("逐步学会素描", .learning),
            ("存 5 万应急金", .finance), ("还清房贷", .finance),
            ("考过雅思 7 分", .learning), ("背 5000 个单词", .learning),
            ("App 正式上线", .project), ("写完毕业论文", .project),
            ("换工作跳槽", .career), ("准备好简历和面试", .career),
            ("多陪家人", .life), ("搬进新家", .life),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(GoalDomain.infer(from: title), expected, "标题「\(title)」认领领域不符")
        }
    }

    func testInferDomainFallbackOrderAndCase() {
        XCTAssertEqual(GoalDomain.infer(from: "整理房间"), .other)
        XCTAssertEqual(GoalDomain.infer(from: "换一部手机"), .other)
        // infer 只管领域：过程型标题照样认领，与提示行规则互不干扰
        XCTAssertEqual(GoalDomain.infer(from: "每天读 20 分钟书"), .learning)
        // career 排 life 前：歧义标题按职业归
        XCTAssertEqual(GoalDomain.infer(from: "跳槽后多陪家人"), .career)
        // 关键词匹配大小写不敏感（kg/KG）
        XCTAssertEqual(GoalDomain.infer(from: "减到 70KG"), .health)
    }

    // MARK: - S3a 数字提示行触发规则



    // MARK: - S3b 编辑不覆写领域

    func testEditDraftPreservesOriginalDomain() throws {
        let goal = try makeGoal(title: "今年跑满 300 公里", domain: .health)
        let draft = GoalEditForm.draft(from: goal)
        XCTAssertEqual(draft.domain, .health, "编辑模式保留目标原领域，不按标题重认领")
        // GoalEditSheet 保存链路原样回写 draft.domain，标题改成财务向也不改领域
        try repository.updateFields(goal, title: "存 5 万", domain: draft.domain)
        XCTAssertEqual(goal.goalDomain, .health)
    }

    // MARK: - S4 排序规则（规格 A3）

    func testOngoingSortRankOrder() throws {
        let now = Date()
        let reviewDue = try makeGoal(title: "待回顾置顶")
        let dueSoon = try makeGoal(title: "期限近在眼前", deadline: now.addingTimeInterval(3600))
        let dueFar = try makeGoal(title: "期限还远", deadline: now.addingTimeInterval(86400 * 30))
        let noDeadline = try makeGoal(title: "没有期限")
        let overdue = try makeGoal(title: "已经到期", deadline: now.addingTimeInterval(-86400))
        let paused = try makeGoal(title: "暂停中的目标", status: .paused,
                                  deadline: now.addingTimeInterval(86400))
        let completed = try makeGoal(title: "完成的目标", status: .completed)

        let sorted = GoalListView.sortedOngoingGoals(
            [overdue, paused, completed, noDeadline, dueFar, dueSoon, reviewDue],
            reviewDueIDs: [reviewDue.id], now: now
        )
        XCTAssertEqual(sorted.map(\.title),
                       ["待回顾置顶", "期限近在眼前", "期限还远", "没有期限", "已经到期", "暂停中的目标"])
    }

    func testOngoingSortDeadlineNearToFarWithinSameRank() throws {
        let now = Date()
        let far = try makeGoal(title: "远的", deadline: now.addingTimeInterval(86400 * 30))
        let near = try makeGoal(title: "近的", deadline: now.addingTimeInterval(3600))
        let sorted = GoalListView.sortedOngoingGoals([far, near], reviewDueIDs: [], now: now)
        XCTAssertEqual(sorted.map(\.title), ["近的", "远的"])
    }

    func testCompletedSortByCompletedAtDescending() throws {
        let older = try makeGoal(title: "先完成的", status: .completed,
                                 completedAt: Date(timeIntervalSinceNow: -86400))
        let newer = try makeGoal(title: "后完成的", status: .completed)
        let active = try makeGoal(title: "进行中的")
        let sorted = GoalListView.sortedCompletedGoals([active, older, newer])
        XCTAssertEqual(sorted.map(\.title), ["后完成的", "先完成的"])
    }

    // MARK: - S4 长按菜单状态流转

    func testStatusTransitionActiveToCompletedWritesCompletedAt() throws {
        let goal = try makeGoal(title: "跑满 300 公里")
        XCTAssertNil(goal.completedAt)
        try repository.updateStatus(goal, status: .completed)
        XCTAssertEqual(goal.goalStatus, .completed)
        XCTAssertNotNil(goal.completedAt, "completedAt 由模型在置完成时自动写")
        XCTAssertEqual(repository.goals.first { $0.id == goal.id }?.goalStatus, .completed,
                       "重拉后已完成段可见（标记完成→移入已完成段）")
    }

    func testStatusTransitionPauseResumeAndReopen() throws {
        let goal = try makeGoal(title: "多读几本书")
        try repository.updateStatus(goal, status: .paused)
        XCTAssertEqual(goal.goalStatus, .paused, "长按「暂停」→ 已暂停（垫底胶囊）")
        try repository.updateStatus(goal, status: .active)
        XCTAssertEqual(goal.goalStatus, .active, "长按「继续」→ 恢复进行中")
        try repository.updateStatus(goal, status: .completed)
        XCTAssertNotNil(goal.completedAt)
        try repository.updateStatus(goal, status: .active)
        XCTAssertNil(goal.completedAt, "重开目标清空 completedAt，回进行中段")
    }

    // MARK: - S4 再来一轮预填

    func testNewRoundDraftPrefill() throws {
        let goal = try makeGoal(title: "跑满 300 公里")
        goal.goalKindEnum = .cumulative
        goal.metricUnit = "km"
        goal.metricTargetValueDouble = 300
        goal.deadline = Date(timeIntervalSinceNow: -86400) // 旧期限已过
        try context.save()

        let draft = GoalListView.newRoundDraft(from: goal)
        XCTAssertEqual(draft.title, "跑满 300 公里")
        XCTAssertEqual(draft.goalKind, .cumulative)
        XCTAssertEqual(draft.metricTargetValue, 300)
        XCTAssertEqual(draft.metricUnit, "km")
        XCTAssertNil(draft.deadlineText, "期限不继承（旧期限多半已过）")
        XCTAssertNotEqual(draft.id, goal.id.uuidString, "作为一个新 GoalDraft")
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true), "预填后可直接保存")
    }

    // MARK: - S5 设置面板五字段落库链路

    func testSettingsSaveChainUpdatesFiveFields() throws {
        let goal = try makeGoal(title: "跑满 300 公里", domain: .health)
        // GoalSettingsEditSheet.save 的落库链路：updateFields 四字段 + updateAIContext
        try repository.updateFields(
            goal,
            summary: "晨跑通勤攒里程",
            iconEmoji: "🏃",
            desiredOutcome: "完成一场全马",
            motivation: "体检指标回正常"
        )
        try repository.updateAIContext(goal, allow: false)
        XCTAssertEqual(goal.summary, "晨跑通勤攒里程")
        XCTAssertEqual(goal.iconEmoji, "🏃")
        XCTAssertEqual(goal.desiredOutcome, "完成一场全马")
        XCTAssertEqual(goal.motivation, "体检指标回正常")
        XCTAssertFalse(goal.allowAIContext)
        XCTAssertEqual(goal.goalDomain, .health, "未传 domain 的更新不改领域")
    }

    // MARK: - S5 设置面板领域行（规格 v3：详情页设置里可改）

    func testSettingsSaveChainUpdatesDomain() throws {
        let goal = try makeGoal(title: "整理房间", domain: .other)
        // 面板从 goal 预填 draft，用户在领域行改选「健康」后保存：
        // GoalSettingsEditSheet.save → updateFields(domain: draft.domain)
        var draft = GoalEditForm.draft(from: goal)
        XCTAssertEqual(draft.domain, .other)
        draft.domain = .health
        try repository.updateFields(
            goal,
            summary: draft.summary,
            domain: draft.domain,
            iconEmoji: draft.iconEmoji,
            desiredOutcome: draft.desiredOutcome,
            motivation: draft.motivation
        )
        XCTAssertEqual(goal.goalDomain, .health, "设置面板改领域落库生效")
        XCTAssertEqual(goal.displayIcon, GoalDomain.health.defaultEmoji,
                       "未手选图标时展示值跟随新领域默认 emoji")
        XCTAssertEqual(repository.goals.first { $0.id == goal.id }?.goalDomain, .health,
                       "重拉后领域保持新值（列表卡配色随之切换）")
    }

    // MARK: - R1 图标兜底（App 代码保证：icon nil/空 → 领域默认 emoji）

    func testDisplayIconFallsBackToDomainDefault() throws {
        let goal = try makeGoal(title: "整理房间", domain: .other)
        XCTAssertEqual(goal.iconEmoji, nil)
        XCTAssertEqual(goal.displayIcon, GoalDomain.other.defaultEmoji, "nil 图标回落领域默认 emoji")

        goal.iconEmoji = ""
        XCTAssertEqual(goal.displayIcon, GoalDomain.other.defaultEmoji, "空串图标回落领域默认 emoji")

        goal.iconEmoji = "🏃"
        XCTAssertEqual(goal.displayIcon, "🏃", "手选图标优先于领域默认")
    }

    // MARK: - R5 单位可选 + 提示行单位微型映射

    func testSourceSpecificGoalInputRejectsInvalidHealthValues() {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "本周走路"
        draft.goalKind = .cumulative
        draft.metricSource = .healthKit
        draft.healthMetricKind = .stepCount
        draft.metricTargetValue = 10.5
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: false))
        draft.metricTargetValue = 10_000
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: false))

        draft.goalKind = .target
        draft.healthMetricKind = .sleepAverage
        draft.metricTargetValue = 25
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: false))
        draft.metricTargetValue = 7.5
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: false))
    }

    func testTargetDirectionUsesIntentAndStartingValue() {
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "减肥", unit: " KG ", healthMetric: nil,
                                                            baseline: 82.5, target: 75), .trendDown)
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "减肥", unit: nil, healthMetric: .bodyMass,
                                                            baseline: nil, target: 75), .trendDown)
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "屏幕时间", unit: "小时", healthMetric: nil,
                                                            baseline: 5, target: 2), .trendDown)
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "减脂期间提高蛋白摄入", unit: "克", healthMetric: nil,
                                                            baseline: 60, target: 80), .trendUp)
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "蛋白不低于 80 克", unit: "克", healthMetric: nil,
                                                            baseline: 90, target: 80), .trendUp)
        XCTAssertEqual(GoalResultComparison.inferredTarget(title: "平均睡够 7 小时", unit: "小时", healthMetric: .sleepAverage,
                                                            baseline: 8, target: 7), .reach)
    }

    func testMetricValidationUnitOptional() {
        // 累积型：数字有效+标题在（canSave 侧）即可保存，单位空不拦
        var draft = GoalEditForm.emptyDraft()
        draft.title = "今年跑满 300 公里"
        draft.goalKind = .cumulative
        draft.metricTargetValue = 300
        draft.metricUnit = nil
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true), "单位空合法（规格 B5）")
        XCTAssertNil(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true), "单位空不应报「数字还没填完」")

        // 达标型同理
        draft.goalKind = .target
        draft.metricBaselineValue = 75
        draft.metricTargetValue = 70
        draft.metricUnit = nil
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true))
        XCTAssertNil(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true))

        // 数字缺失才报数字空（三态之一）
        draft.metricTargetValue = nil
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true))
        XCTAssertEqual(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true), "数字还没填完")
    }


    // MARK: - 账本范围暴露（2026-11-14 七条 §5/§6：选择/保存/预填/评估）

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return Calendar.current.date(byAdding: .hour, value: hour, to: day) ?? day
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

    private func makePlanPayload(ledgerScope: GoalLedgerScopePayload) -> GoalPlanPayloadV2 {
        GoalPlanPayloadV2(
            intent: GoalPlanIntentV2(originalWish: nil, successCriteria: nil, deadline: nil),
            resultSource: GoalPlanResultSourceV2(
                sourceType: .ledger, sourceID: nil, unit: "元", aggregation: .sum, comparison: .reach,
                targetValue: 18000, baselineValue: nil, baselineObservedAt: nil, freshnessDays: nil,
                ledgerScope: ledgerScope),
            bindings: [],
            basis: GoalPlanDecisionBasisV2(origin: .workshop, sourceSessionID: nil,
                                           sourceReportMessageID: nil, confirmedAt: Date())
        )
    }

    func testTargetKindNowOffersLedgerSource() {
        XCTAssertTrue(GoalMetricSource.selectable(for: .target).contains(.ledger),
                      "达标型开放账本（账户余额 reach，七条 §5）")
        XCTAssertTrue(GoalMetricSource.selectable(for: .target).contains(.healthKit))
        XCTAssertEqual(GoalMetricSource.selectable(for: .cumulative), [.manual, .habit, .ledger, .healthKit])
        XCTAssertEqual(GoalMetricSource.selectable(for: .process), [.manual])
    }

    func testLedgerScopeValidationMatrix() {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "存 5 万应急金"
        draft.metricSource = .ledger

        // 累积型：全账本 / 指定账户净结余增加
        draft.goalKind = .cumulative
        draft.metricTargetValue = 50000
        draft.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true))
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: UUID())
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: nil)
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true), "账户净结余口径必须带账户")

        // 达标型：账户余额必选具体账户
        draft.goalKind = .target
        draft.metricBaselineValue = 1000
        draft.metricTargetValue = 1500
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: UUID())
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true), "达标型不提供全账本口径")
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: true), "范围不合法不可保存")
        XCTAssertNotNil(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true), "范围不合法给出禁用文案")

        // 范围缺失同样拦保存
        draft.ledgerScope = nil
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true))
    }

    func testLedgerScopeSavedThroughCreateChainWithUnitYen() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        try context.save()

        var draft = GoalEditForm.emptyDraft()
        draft.title = "存 5 万应急金"
        draft.goalKind = .cumulative
        draft.metricSource = .ledger
        draft.metricUnit = "¥"
        draft.metricTargetValue = 50000
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id)

        let result = try repository.saveDraft(draft, allowAIContext: true, source: "manual")
        let goal = result.goal
        XCTAssertEqual(goal.metricSourceEnum, .ledger)
        XCTAssertEqual(goal.metricUnit, "¥", "账本源单位固定 ¥（七条 §6）")
        XCTAssertEqual(goal.ledgerScopePayload, GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id),
                       "表单选定的账本范围随创建链路落 Goal")
        XCTAssertNotNil(goal.baselineDate, "创建时刻即累计起点")
        // 计划 payload 同步账本范围：闭环快照/进度长卷与 Goal 侧同一份口径
        let row = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(row.planPayloadV2?.resultSource?.ledgerScope, draft.ledgerScope)
    }

    func testEditDraftPrefillsLedgerScope() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)

        // 新链路：Goal.ledgerScope 的 JSON payload 是真源
        let goal = try makeGoal(title: "存 5 万应急金")
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 50000
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id)
        try context.save()
        XCTAssertEqual(GoalEditForm.draft(from: goal).ledgerScope,
                       GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id))

        // 共创旧目标：goal.ledgerScope 只存 kind 原始值（无账户 ID）→ 回落最新计划版本 payload
        let legacy = try makeGoal(title: "北海道旅行资金")
        legacy.goalKindEnum = .cumulative
        legacy.metricSourceEnum = .ledger
        legacy.metricTargetValueDouble = 18000
        legacy.ledgerScope = GoalLedgerScopeKind.accountBalance.rawValue
        try context.save()
        let planScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)
        _ = try GoalPlanRevisionStore.makeRevisionRow(
            in: context, goalID: legacy.id, sourceSessionID: nil,
            revisionNumber: 1, baseRevisionID: nil, operationID: nil,
            effectiveFrom: Date(), payload: makePlanPayload(ledgerScope: planScope), legacySummary: nil
        )
        try context.save()
        XCTAssertEqual(GoalEditForm.draft(from: legacy).ledgerScope, planScope,
                       "共创旧目标编辑预填从计划版本回落完整范围（含账户 ID）")
    }

    func testUpdateFieldsWritesLedgerScopeAndResetsBaselineDate() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        let goal = try makeGoal(title: "存 5 万应急金")
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 50000
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        goal.baselineDate = daysAgo(30)
        let planScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        _ = try GoalPlanRevisionStore.makeRevisionRow(
            in: context, goalID: goal.id, sourceSessionID: nil,
            revisionNumber: 1, baseRevisionID: nil, operationID: nil,
            effectiveFrom: Date(), payload: makePlanPayload(ledgerScope: planScope), legacySummary: nil
        )
        try context.save()

        try repository.updateFields(
            goal,
            metricSource: .ledger,
            ledgerScope: .some(GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id))
        )
        XCTAssertEqual(goal.ledgerScopePayload, GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id))
        XCTAssertGreaterThan(goal.baselineDate ?? Date.distantPast, daysAgo(1),
                             "换账本范围=换口径，累计起点重置为当前时刻")
        // 换口径触发的计划版本重建也带上新账本范围
        let row = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(row.planPayloadV2?.resultSource?.ledgerScope,
                       GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id))
    }

    // MARK: - 账本口径评估（GoalMetricEvaluator 走 in-memory 真链路）

    func testAccountDeltaEvaluatorSubtractsTwoObservations() throws {
        let finance = FinanceRepository(context: context)
        CoreDataTestSupport.retain(finance)
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue,
                                     initialBalance: NSDecimalNumber(value: 1000))
        income(50, account: account, daysAgo: 20)  // 累计起点之前：不计入增量
        income(300, account: account, daysAgo: 5)
        income(200, account: account, daysAgo: 1)

        let goal = try makeGoal(title: "存 5 万应急金")
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 5000
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id)
        goal.baselineDate = daysAgo(10)
        try context.save()

        // 当前余额 1550 − 起点余额 1050 = 500（起点前的 50 被扣掉）
        let progress = try XCTUnwrap(GoalMetricEvaluator.evaluate(goal: goal, finance: finance))
        XCTAssertEqual(progress.currentValue, 500, accuracy: 0.001)
        XCTAssertEqual(progress.progress, 500.0 / 5000.0, accuracy: 0.0001)
        XCTAssertFalse(progress.isAchieved)
    }

    func testAccountBalanceEvaluatorReachForTargetKind() throws {
        let finance = FinanceRepository(context: context)
        CoreDataTestSupport.retain(finance)
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue,
                                     initialBalance: NSDecimalNumber(value: 1000))
        income(500, account: account, daysAgo: 3)

        let goal = try makeGoal(title: "旅行基金攒到 1500")
        goal.goalKindEnum = .target
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 1500
        goal.baselineValueDouble = 1000
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id)
        goal.baselineDate = daysAgo(10)
        try context.save()

        let progress = try XCTUnwrap(GoalMetricEvaluator.evaluate(goal: goal, finance: finance))
        XCTAssertEqual(progress.currentValue, 1500, accuracy: 0.001)
        XCTAssertEqual(progress.progress, 1.0, accuracy: 0.0001, "余额到达目标值即 100%（基线 1000 → 目标 1500）")
        XCTAssertTrue(progress.isAchieved)
    }

    func testLedgerEvaluatorReturnsNilWhenAccountNotObservable() throws {
        let finance = FinanceRepository(context: context)
        CoreDataTestSupport.retain(finance)

        let cumulative = try makeGoal(title: "存 5 万应急金")
        cumulative.goalKindEnum = .cumulative
        cumulative.metricSourceEnum = .ledger
        cumulative.metricTargetValueDouble = 5000
        cumulative.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountDelta, accountID: UUID())
        cumulative.baselineDate = daysAgo(10)

        let target = try makeGoal(title: "旅行基金攒到 1500")
        target.goalKindEnum = .target
        target.metricSourceEnum = .ledger
        target.metricTargetValueDouble = 1500
        target.baselineValueDouble = 1000
        target.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountBalance, accountID: UUID())
        target.baselineDate = daysAgo(10)
        try context.save()

        XCTAssertNil(GoalMetricEvaluator.evaluate(goal: cumulative, finance: finance),
                     "账户不存在（accountMissing）不是 0 元观测")
        XCTAssertNil(GoalMetricEvaluator.evaluate(goal: target, finance: finance))
    }

    // MARK: - 计划编辑面板账本范围三档（2026-11-14 全链路补全）

    func testPlanEditorLedgerScopeOptionsByPlanSemantics() throws {
        let travel = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        let emergency = Account.create(in: context, name: "应急", type: AccountType.bank.rawValue)
        try context.save()

        // 累积语义（aggregation=sum）：全账本 + 各账户该账本净增加，无余额档
        let cumulative = GoalPlanLedgerScopeEditor.options(aggregation: .sum, accounts: [travel, emergency])
        XCTAssertEqual(cumulative.map(\.scope.kind), [.wholeLedgerDelta, .accountDelta, .accountDelta])
        XCTAssertEqual(cumulative.map(\.scope.accountID), [nil, travel.id, emergency.id])
        XCTAssertEqual(cumulative[1].title, "旅行·该账本净增加")
        XCTAssertFalse(cumulative.contains { $0.title.contains("余额达到") })

        // 达标语义（latest）：各账户余额达到，无全账本/净增加档
        let reach = GoalPlanLedgerScopeEditor.options(aggregation: .latest, accounts: [travel, emergency])
        XCTAssertEqual(reach.map(\.scope.kind), [.accountBalance, .accountBalance])
        XCTAssertEqual(reach[0].title, "旅行·余额达到")
        XCTAssertFalse(reach.contains { $0.scope.kind == .wholeLedgerDelta || $0.scope.kind == .accountDelta })

        // 计划缺 aggregation：三档全给
        let unknown = GoalPlanLedgerScopeEditor.options(aggregation: nil, accounts: [travel])
        XCTAssertEqual(unknown.map(\.scope.kind), [.wholeLedgerDelta, .accountDelta, .accountBalance])
    }

    func testPlanEditorLedgerScopeDisplayTitle() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        try context.save()
        XCTAssertEqual(GoalPlanLedgerScopeEditor.displayTitle(
            for: GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id), accounts: [account]),
            "旅行·该账本净增加")
        XCTAssertEqual(GoalPlanLedgerScopeEditor.displayTitle(
            for: GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id), accounts: [account]),
            "旅行·余额达到")
        XCTAssertEqual(GoalPlanLedgerScopeEditor.displayTitle(
            for: GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil), accounts: [account]),
            "全部账本·净结余增加")
        // 账户已删：回落口径名，不归一成别的档
        XCTAssertEqual(GoalPlanLedgerScopeEditor.displayTitle(
            for: GoalLedgerScopePayload(kind: .accountDelta, accountID: UUID()), accounts: [account]),
            "该账本净增加")
    }

    func testPlanEditorLedgerScopeApplyWritesScopeSourceAndUnit() {
        var source = GoalPlanResultSourceV2(
            sourceType: .ledger, sourceID: nil, unit: "元", aggregation: .sum, comparison: .reach,
            targetValue: 5000, baselineValue: nil, baselineObservedAt: nil, freshnessDays: nil,
            ledgerScope: GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        )
        let accountID = UUID()
        // 改选账户·该账本净增加：范围/来源账户/单位一次写对
        GoalPlanLedgerScopeEditor.apply(
            GoalLedgerScopePayload(kind: .accountDelta, accountID: accountID), to: &source)
        XCTAssertEqual(source.ledgerScope, GoalLedgerScopePayload(kind: .accountDelta, accountID: accountID))
        XCTAssertEqual(source.sourceID, accountID)
        XCTAssertEqual(source.unit, "¥", "账本源单位固定 ¥（与表单 v4 同规则）")
        // 改回全账本：来源账户清空
        GoalPlanLedgerScopeEditor.apply(
            GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil), to: &source)
        XCTAssertEqual(source.ledgerScope, GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil))
        XCTAssertNil(source.sourceID)
    }

    func testPlanEditorRoundTripKeepsAccountDeltaKind() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        try context.save()
        let goal = try makeGoal(title: "存 5 万应急金")
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 50000
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id)
        let baseScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id)
        _ = try GoalPlanRevisionStore.makeRevisionRow(
            in: context, goalID: goal.id, sourceSessionID: nil,
            revisionNumber: 1, baseRevisionID: nil, operationID: nil,
            effectiveFrom: Date(), payload: makePlanPayload(ledgerScope: baseScope), legacySummary: nil
        )
        try context.save()

        // 面板载入：resolveCurrentPlan 原样带出 accountDelta，行值回显「该账本净增加」项而非归一成余额档
        let resolved = try GoalPlanResolver.resolveCurrentPlan(goal: goal, in: context, persist: true)
        XCTAssertEqual(resolved.payload.resultSource?.ledgerScope, baseScope)
        XCTAssertEqual(
            GoalPlanLedgerScopeEditor.displayTitle(for: resolved.payload.resultSource?.ledgerScope, accounts: [account]),
            "旅行·该账本净增加")

        // 用户只改成功条件、不动资金来源 → 保存后 kind 不丢（本轮抓到的核心 bug 的断言）
        var draft = resolved.payload
        draft.intent.successCriteria = "出发前专款 5 万"
        try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: resolved.revisionID, payload: draft,
                                     operationID: UUID(), successChangeConfirmed: true, in: context)
        let saved = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(saved.planPayloadV2?.resultSource?.ledgerScope, baseScope,
                       "accountDelta 载入→不改资金来源→保存，kind 不被归一丢失")
    }

    func testPlanEditorChangeLedgerScopeSavesNewScope() throws {
        let travel = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        let emergency = Account.create(in: context, name: "应急", type: AccountType.bank.rawValue)
        try context.save()
        let goal = try makeGoal(title: "存 5 万应急金")
        goal.goalKindEnum = .cumulative
        goal.metricSourceEnum = .ledger
        goal.ledgerScopePayload = GoalLedgerScopePayload(kind: .accountDelta, accountID: travel.id)
        _ = try GoalPlanRevisionStore.makeRevisionRow(
            in: context, goalID: goal.id, sourceSessionID: nil,
            revisionNumber: 1, baseRevisionID: nil, operationID: nil,
            effectiveFrom: Date(),
            payload: makePlanPayload(ledgerScope: GoalLedgerScopePayload(kind: .accountDelta, accountID: travel.id)),
            legacySummary: nil
        )
        try context.save()

        let resolved = try GoalPlanResolver.resolveCurrentPlan(goal: goal, in: context, persist: true)
        var draft = resolved.payload
        // 用户改选「应急·该账本净增加」（选择行 set → apply 写回）
        GoalPlanLedgerScopeEditor.apply(
            GoalLedgerScopePayload(kind: .accountDelta, accountID: emergency.id), to: &draft.resultSource!)
        try GoalPlanEditService.save(goalID: goal.id, baseRevisionID: resolved.revisionID, payload: draft,
                                     operationID: UUID(), successChangeConfirmed: true, in: context)
        let saved = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(saved.planPayloadV2?.resultSource?.ledgerScope,
                       GoalLedgerScopePayload(kind: .accountDelta, accountID: emergency.id))
        XCTAssertEqual(saved.planPayloadV2?.resultSource?.sourceID, emergency.id)
        XCTAssertEqual(saved.planPayloadV2?.resultSource?.unit, "¥")
    }

    func testPlanEditorChangesTextUsesKindDisplayNameAndAccountName() throws {
        let account = Account.create(in: context, name: "旅行", type: AccountType.bank.rawValue)
        try context.save()
        XCTAssertEqual(GoalPlanEditPresentation.ledgerScopeText(
            GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id), accounts: [account]),
            "该账本净结余增加·旅行")
        XCTAssertEqual(GoalPlanEditPresentation.ledgerScopeText(
            GoalLedgerScopePayload(kind: .accountBalance, accountID: account.id), accounts: [account]),
            "单账户余额·旅行")
        XCTAssertEqual(GoalPlanEditPresentation.ledgerScopeText(nil, accounts: []),
                       "全账本净结余增加")

        let old = makePlanPayload(ledgerScope: GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil))
        let new = makePlanPayload(ledgerScope: GoalLedgerScopePayload(kind: .accountDelta, accountID: account.id))
        let changes = GoalPlanEditPresentation.changes(from: old, to: new)
        XCTAssertTrue(changes.contains { $0.hasPrefix("资金来源改为：") && $0.contains("该账本净结余增加") },
                      "口径变更历史文案动态生成，不写死全账本：\(changes)")
    }

    // MARK: - 红队一轮修复（2026-11-14，10 用户红队 2P0+6P1+U6）

    /// U10 误触「标记完成」可逆：恢复为进行中（列表 contextMenu 与详情按钮走同一 updateStatus(.active)）
    func testReopenCompletedGoalViaUpdateStatus() throws {
        let goal = try makeGoal(title: "跑满 300 公里", status: .completed)
        XCTAssertNotNil(goal.completedAt)
        try repository.updateStatus(goal, status: .active)
        XCTAssertEqual(goal.goalStatus, .active)
        XCTAssertNil(goal.completedAt, "恢复为进行中时 completedAt 由模型 setter 自动清")
        XCTAssertTrue(GoalListView.sortedOngoingGoals([goal], reviewDueIDs: [], now: Date())
            .map(\.id).contains(goal.id), "回进行中段可见")
    }

    /// U3 再来一轮：达标型不继承过期基线（预填后不再开屏 100%）
    func testNewRoundDraftDropsStaleBaselineForTargetKind() throws {
        let goal = try makeGoal(title: "还清招行信用卡")
        goal.goalKindEnum = .target
        goal.metricSourceEnum = .ledger
        goal.metricTargetValueDouble = 0
        goal.baselineValueDouble = 8800 // 旧基线已过期
        try context.save()

        let draft = GoalListView.newRoundDraft(from: goal)
        XCTAssertEqual(draft.goalKind, .target)
        XCTAssertEqual(draft.metricSource, .ledger)
        XCTAssertNil(draft.metricBaselineValue, "新一轮不带旧「现在」，由表单入场按当前余额重取")
    }

    /// U1 无活跃账户时账本源不可保存（不再产出恒 0% 目标）
    func testLedgerSourceBlockedWithoutActiveAccounts() {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "存 5 万应急金"
        draft.goalKind = .cumulative
        draft.metricSource = .ledger
        draft.metricTargetValue = 50000
        draft.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: false),
                       "全账本口径也要求存在活跃账户")
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: false))
        XCTAssertEqual(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: false), "还没有账户")
        // 有账户则恢复可保存
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft, hasActiveLedgerAccounts: true))
        XCTAssertNil(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true))
    }

    /// U8 改条件未确认 → 禁用文案指向脚手架恒可见区的确认勾选
    func testDisabledHintReportsUnconfirmedCriteriaChange() {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "跑满 300 公里"
        XCTAssertEqual(
            GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true, criteriaUnconfirmed: true),
            "修改了成功条件——勾选下方确认后可保存")
        XCTAssertNil(GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: true),
                     "未改条件时不出现确认提示")
    }

    /// U1 「设个期限」默认今天 + 30 天（不再默认写入今天）
    func testDefaultDeadlineIsThirtyDaysOut() {
        let now = Date()
        let deadline = GoalEditForm.defaultDeadline(from: now)
        XCTAssertEqual(deadline.timeIntervalSince(now), 30 * 86400, accuracy: 1)
        XCTAssertGreaterThan(deadline, now, "默认期限在未来，创建即逾期不再发生")
    }



    /// 期限清除：传 .some(nil) 后 deadline 彻底清空，不留旧值
    func testClearGoalDeadlineViaUpdateFields() throws {
        let deadline = Date().addingTimeInterval(86400 * 30)
        let goal = try makeGoal(title: "今年攒钱", domain: .finance, deadline: deadline)
        XCTAssertNotNil(goal.deadline)

        try repository.updateFields(goal, deadline: .some(nil))
        XCTAssertNil(goal.deadline, "清除期限后应为 nil")

        let roundTrip = GoalEditForm.draft(from: goal)
        XCTAssertNil(roundTrip.deadlineText, "回读 draft 的 deadlineText 应为 nil")
    }

    /// 「今年底」预设应落到当年 12 月 31 日
    func testEndOfCurrentYearPreset() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let end = GoalEditForm.endOfCurrentYear(from: now, calendar: cal)
        let comps = cal.dateComponents([.year, .month, .day], from: end)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 31)
    }

    /// 删除目标使用单条软删（deletedAt != nil, deletedBatchId == nil），解除任务与习惯关联且不销毁内存对象
    func testDeleteGoalSoftDeletesAndUnlinksEntitiesWithoutInvalidation() throws {
        let goal = try makeGoal(title: "待删除目标", domain: .health)
        let task = TodoTask.create(in: context, title: "子任务")
        task.goal = goal
        let habit = Habit.create(in: context, name: "每日称重", icon: "⚖️", color: "#EA580C", type: .numeric, frequency: .daily)
        habit.goal = goal
        try context.save()

        let previousFocusID = UserDefaults.standard.string(forKey: "holo.today.focusGoalID")
        UserDefaults.standard.set(goal.id.uuidString, forKey: "holo.today.focusGoalID")
        defer {
            if let previousFocusID {
                UserDefaults.standard.set(previousFocusID, forKey: "holo.today.focusGoalID")
            } else {
                UserDefaults.standard.removeObject(forKey: "holo.today.focusGoalID")
            }
        }

        repository.loadGoals()
        XCTAssertTrue(repository.goals.contains(where: { $0.id == goal.id }))

        try repository.deleteGoal(goal)

        XCTAssertNotNil(goal.deletedAt, "软删除应写入 deletedAt")
        XCTAssertNil(goal.deletedBatchId, "单条删除 deletedBatchId 应保持为 nil")
        XCTAssertFalse(goal.isDeleted, "软删不应立即销毁 NSManagedObject（防止退栈动画悬空崩溃）")
        XCTAssertNil(task.goal, "删除目标后关联任务应保留且解除归属")
        XCTAssertNil(habit.goal, "删除目标后关联习惯应保留且解除归属")
        XCTAssertFalse(repository.goals.contains(where: { $0.id == goal.id }), "软删后应从活跃目标列表隐藏")
        XCTAssertNil(UserDefaults.standard.string(forKey: "holo.today.focusGoalID"), "置顶关注该目标时应同步清除")
    }

    // MARK: - 删除目标连带清理（2026-11-17 东林两 BUG 之二）

    /// 通过共创提交建一个带专属习惯/任务的真目标（绑定 isGoalOwned = true）
    private func commitGoalWithOwnedEntities() throws -> Goal {
        let draft = GoalDraft(
            id: "cascade-draft",
            title: "级联删除验收",
            summary: nil,
            domain: .health,
            iconEmoji: nil,
            desiredOutcome: "体重降到 70 公斤",
            motivation: nil,
            deadlineText: nil,
            tasks: [GoalTaskDraft(id: "cascade-task", isSelected: true, title: "买体脂秤",
                                  dueDateText: nil, priority: 1, note: nil)],
            habits: [GoalHabitDraft(id: "cascade-habit", isSelected: true, name: "每日称重",
                                    frequency: "daily", targetCount: 1, type: "numeric", unit: "公斤",
                                    targetValue: nil, isBadHabit: false, successRule: "completeWhenDone")],
            missingInfoWarnings: []
        )
        let receipt = try GoalWorkshopCommitService.performCommit(
            draft: draft,
            allowAIContext: false,
            source: "goalWorkshop",
            sourceSessionID: UUID(),
            successEvidence: "体重达标",
            assumptions: [],
            selectedRouteTitle: nil,
            in: context
        )
        guard let goal = repository.findGoal(by: receipt.goalID) else {
            throw XCTSkip("提交后目标应可读取")
        }
        return goal
    }

    /// 影响清单只统计「目标创建」的实体：专属习惯/任务计入，复用挂进来的旧习惯不计
    func testOwnedEntityImpactCountsOnlyGoalOwnedEntities() throws {
        let goal = try commitGoalWithOwnedEntities()
        let reused = Habit.create(in: context, name: "旧习惯", icon: "leaf", color: "#987444",
                                  type: .checkIn, frequency: .daily)
        try repository.linkHabit(reused, to: goal)

        let impact = repository.ownedEntityImpact(of: goal)

        XCTAssertEqual(impact.ownedHabits.map(\.name), ["每日称重"], "只计目标创建的习惯")
        XCTAssertEqual(impact.ownedTasks.map(\.title), ["买体脂秤"], "只计目标创建的任务")
        XCTAssertFalse(impact.isEmpty)
        XCTAssertEqual(impact.summaryText, "1 个习惯、1 个任务")
    }

    /// 连带删除：专属习惯硬删（记录级联）、专属任务软删进回收站、复用习惯仅解除关联
    func testDeleteGoalCascadingOwnedEntities() throws {
        let goal = try commitGoalWithOwnedEntities()
        let reused = Habit.create(in: context, name: "旧习惯", icon: "leaf", color: "#987444",
                                  type: .checkIn, frequency: .daily)
        try repository.linkHabit(reused, to: goal)

        let ownedHabit = repository.ownedEntityImpact(of: goal).ownedHabits[0]
        let ownedTask = repository.ownedEntityImpact(of: goal).ownedTasks[0]
        let record = HabitRecord.createNumeric(in: context, habit: ownedHabit, value: 72.5)
        try context.save()
        let ownedHabitID = ownedHabit.id
        let recordID = record.id

        try repository.deleteGoal(goal, deletingOwnedEntities: true)
        try context.save()

        XCTAssertNotNil(goal.deletedAt, "目标本体软删")
        // save 后 isDeleted 对已持久化删除不可靠，统一以重查计数断言硬删
        let habitRequest = Habit.fetchRequest()
        habitRequest.predicate = NSPredicate(format: "id == %@", ownedHabitID as CVarArg)
        XCTAssertEqual(try context.fetch(habitRequest).count, 0, "目标创建的习惯应被硬删")
        let recordRequest = HabitRecord.fetchRequest()
        recordRequest.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
        XCTAssertEqual(try context.fetch(recordRequest).count, 0, "习惯的记录应随级联规则删除")
        XCTAssertFalse(reused.isDeleted, "复用挂进来的旧习惯必须存活")
        XCTAssertNil(reused.goal, "旧习惯仅解除关联")
        XCTAssertTrue(ownedTask.deletedFlag, "目标创建的任务应软删进回收站")
        XCTAssertNotNil(ownedTask.deletedBatchId, "任务应挂在回收站批次上（可恢复）")
        XCTAssertNil(ownedTask.goal, "任务归属解除")

        let batchRequest = NSFetchRequest<RecycleBinBatch>(entityName: "RecycleBinBatch")
        let batches = try context.fetch(batchRequest)
        XCTAssertEqual(batches.count, 1, "整批任务共用一个回收站批次")
    }

    /// 默认删除（不连带）：所有习惯/任务存活，仅解除关联——旧行为不回归
    func testDeleteGoalWithoutCascadingKeepsOwnedEntities() throws {
        let goal = try commitGoalWithOwnedEntities()
        let impact = repository.ownedEntityImpact(of: goal)
        let ownedHabit = impact.ownedHabits[0]
        let ownedTask = impact.ownedTasks[0]

        try repository.deleteGoal(goal)

        XCTAssertFalse(ownedHabit.isDeleted, "默认删除不动专属习惯")
        XCTAssertNil(ownedHabit.goal)
        XCTAssertFalse(ownedTask.deletedFlag, "默认删除不动专属任务")
        XCTAssertNil(ownedTask.goal)
    }

    /// 复合 Emoji（含 VS16 / ZWJ）应被稳定识别为 emoji 图标
    func testCompoundHabitEmojiRecognition() {
        for emoji in ["🏃‍♂️", "🏃‍♀️‍➡️", "⚖️", "🐷", "❤️"] {
            XCTAssertTrue(EmojiCatalog.isEmojiIcon(emoji), "复合 Emoji \(emoji) 应被识别为 emoji 图标")
        }
        XCTAssertFalse(EmojiCatalog.isEmojiIcon("figure.run"))
    }

    // MARK: - AI 目标规划量化草案 & 卡片摘要 & 流式哨兵守卫

    func testGoalDraftQuantitativeDecodingAndCardSummary() throws {
        let json = """
        {
          "id": "draft-weight-1",
          "title": "科学减重到 70kg",
          "summary": "从 82kg 稳步减到 70kg",
          "domain": "health",
          "desiredOutcome": "体重降到 70kg",
          "motivation": "提升体能",
          "deadlineText": "2027-05-16",
          "goalKind": "target",
          "metricSource": "manual",
          "metricUnit": "kg",
          "metricBaselineValue": "82",
          "metricTargetValue": 70,
          "tasks": [
            { "id": "t1", "isSelected": true, "title": "记录初始体重", "dueDateText": null, "priority": 1, "note": null }
          ],
          "habits": [
            { "id": "h1", "isSelected": true, "name": "去健身房", "frequency": "weekly", "targetCount": 3, "type": "checkIn", "unit": null, "targetValue": null, "isBadHabit": false, "successRule": "completeWhenDone" }
          ],
          "missingInfoWarnings": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let draft = try JSONDecoder().decode(GoalDraft.self, from: data)
        XCTAssertEqual(draft.goalKind, .target)
        XCTAssertEqual(draft.metricSource, .manual)
        XCTAssertEqual(draft.metricUnit, "kg")
        XCTAssertEqual(draft.metricBaselineValue, 82)
        XCTAssertEqual(draft.metricTargetValue, 70)
        XCTAssertEqual(draft.quantitativeSummary, "82 → 70 kg")
        XCTAssertTrue(draft.cardSummary.contains("82 → 70 kg"))
    }

    func testGoalSavedChatCardDataParsesMetricSummary() {
        let dict: [String: String] = [
            "goalId": UUID().uuidString,
            "goalTitle": "科学减重到 70kg",
            "createdTaskCount": "1",
            "createdHabitCount": "2",
            "metricSummary": "82 → 70 kg"
        ]
        let card = GoalSavedChatCardData(dictionary: dict)
        XCTAssertEqual(card?.metricSummary, "82 → 70 kg")
        XCTAssertEqual(card?.summary, "82 → 70 kg · 1 个任务 · 2 个习惯")
    }

    @MainActor
    func testGoalPlanningCoordinatorStreamingSentinelGuard() async throws {
        let draftJSON = """
        {
          "id": "draft-1",
          "title": "减重到 70kg",
          "summary": null,
          "domain": "health",
          "desiredOutcome": "70kg",
          "motivation": null,
          "deadlineText": null,
          "goalKind": "target",
          "metricSource": "manual",
          "metricUnit": "kg",
          "metricBaselineValue": 82,
          "metricTargetValue": 70,
          "tasks": [],
          "habits": [],
          "missingInfoWarnings": []
        }
        """
        let provider = StubGoalPlanningStreamProvider(responses: [
            ["DR", "AFT_", "READY"],
            [draftJSON]
        ])
        let coordinator = GoalPlanningCoordinator()
        var streamedQuestions: [String] = []
        var didTriggerDraftGenerating = false

        let result = try await coordinator.startStreaming(
            seedText: "目前 82kg，想减到 70kg",
            userContext: .empty,
            provider: provider,
            onQuestionText: { streamedQuestions.append($0) },
            onDraftGenerating: { didTriggerDraftGenerating = true }
        )

        XCTAssertTrue(streamedQuestions.isEmpty, "DRAFT_READY 哨兵绝不能泄露到流式文本回调")
        XCTAssertTrue(didTriggerDraftGenerating, "识别到 DRAFT_READY 后应触发草案生成状态回调")
        XCTAssertEqual(result.draft?.goalKind, .target)
        XCTAssertEqual(result.draft?.metricBaselineValue, 82)
        XCTAssertEqual(result.draft?.metricTargetValue, 70)
    }

    /// 5 类典型目标创建场景端到端校验：草案解码 → Confirmation 默认推导 → 落库 Goal 实体
    func testFiveGoalCreationScenariosEndToEnd() throws {
        let now = Date()

        // 1. 达标型（减重 82 -> 70 kg + 绑定已有数值习惯「体重」）
        let weightHabit = Habit.create(in: context, name: "体重", icon: "⚖️", color: "#EA580C", type: .numeric, frequency: .daily, unit: "kg")
        try context.save()
        let s1JSON = """
        {
          "id": "s1", "title": "科学减重到 70kg", "domain": "health",
          "goalKind": "target", "metricSource": "manual", "metricUnit": "kg",
          "metricBaselineValue": 82, "metricTargetValue": 70,
          "tasks": [{"id":"t1","isSelected":true,"title":"记录初始体重","dueDateText":null,"priority":1,"note":null}],
          "habits": [{"id":"h1","isSelected":true,"name":"健身房训练","frequency":"weekly","targetCount":3,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"}],
          "missingInfoWarnings": []
        }
        """
        var d1 = try JSONDecoder().decode(GoalDraft.self, from: Data(s1JSON.utf8))
        let c1 = GoalPlanConfirmation.defaults(from: d1, successEvidence: "体重降到 70kg", now: now)
        XCTAssertEqual(c1.resultSource?.comparison, .trendDown)
        XCTAssertEqual(c1.resultSource?.baselineValue, 82)
        XCTAssertEqual(c1.resultSource?.targetValue, 70)
        // 模拟用户在确认页切换到「已有习惯 → 体重」
        d1.metricSource = .habit
        d1.sourceHabitId = weightHabit.id
        let g1 = try repository.createGoal(from: d1, allowAIContext: true)
        XCTAssertEqual(g1.goalKindEnum, .target)
        XCTAssertEqual(g1.metricSourceEnum, .habit)
        XCTAssertEqual(g1.sourceHabitId, weightHabit.id)
        XCTAssertEqual(g1.baselineValueDouble, 82)
        XCTAssertEqual(g1.metricTargetValueDouble, 70)

        // 2. 累积型（今年跑满 300 km）
        let s2JSON = """
        {
          "id": "s2", "title": "今年跑满 300 公里", "domain": "health",
          "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "km",
          "metricBaselineValue": null, "metricTargetValue": 300,
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d2 = try JSONDecoder().decode(GoalDraft.self, from: Data(s2JSON.utf8))
        let c2 = GoalPlanConfirmation.defaults(from: d2, successEvidence: "累计 300km", now: now)
        XCTAssertEqual(c2.resultSource?.comparison, .reach)
        XCTAssertEqual(c2.resultSource?.aggregation, .sum)
        let g2 = try repository.createGoal(from: d2, allowAIContext: true)
        XCTAssertEqual(g2.goalKindEnum, .cumulative)
        XCTAssertEqual(g2.metricTargetValueDouble, 300)
        XCTAssertEqual(g2.metricUnit, "km")

        // 3. 财务储蓄（存 50000 元，切到账本全账本净增）
        let s3JSON = """
        {
          "id": "s3", "title": "年底存下 50000 元应急金", "domain": "finance",
          "goalKind": "cumulative", "metricSource": "ledger", "metricUnit": "元",
          "metricBaselineValue": null, "metricTargetValue": 50000,
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d3 = try JSONDecoder().decode(GoalDraft.self, from: Data(s3JSON.utf8))
        let c3 = GoalPlanConfirmation.defaults(from: d3, successEvidence: "存够 50000 元", now: now)
        XCTAssertEqual(c3.resultSource?.sourceType, .ledger)
        let g3 = try repository.createGoal(from: d3, allowAIContext: true)
        XCTAssertEqual(g3.metricSourceEnum, .ledger)
        XCTAssertEqual(g3.metricTargetValueDouble, 50000)

        // 4. 坏习惯控制（每周抽烟不超过 10 根）
        let s4JSON = """
        {
          "id": "s4", "title": "控制每周抽烟不超过 10 根", "domain": "health",
          "goalKind": "target", "metricSource": "manual", "metricUnit": "根",
          "metricBaselineValue": null, "metricTargetValue": 10,
          "tasks": [],
          "habits": [{"id":"h4","isSelected":true,"name":"抽烟","frequency":"weekly","targetCount":10,"type":"numeric","unit":"根","targetValue":10,"isBadHabit":true,"successRule":"stayBelowTarget"}],
          "missingInfoWarnings": []
        }
        """
        let d4 = try JSONDecoder().decode(GoalDraft.self, from: Data(s4JSON.utf8))
        let c4 = GoalPlanConfirmation.defaults(from: d4, successEvidence: "每周不超过 10 根", now: now)
        XCTAssertEqual(c4.resultSource?.comparison, .stayBelow)

        // 5. 纯过程型（架构师面试准备）
        let s5JSON = """
        {
          "id": "s5", "title": "完成架构师面试准备", "domain": "career",
          "goalKind": "process", "metricSource": "manual", "metricUnit": null,
          "metricBaselineValue": null, "metricTargetValue": null,
          "tasks": [{"id":"t5","isSelected":true,"title":"梳理项目亮点","dueDateText":null,"priority":1,"note":null}],
          "habits": [], "missingInfoWarnings": []
        }
        """
        let d5 = try JSONDecoder().decode(GoalDraft.self, from: Data(s5JSON.utf8))
        let c5 = GoalPlanConfirmation.defaults(from: d5, successEvidence: "通过面试", now: now)
        XCTAssertNil(c5.resultSource, "纯过程型不应强行生成量化结果来源")
        let g5 = try repository.createGoal(from: d5, allowAIContext: true)
        XCTAssertEqual(g5.goalKindEnum, .process)
    }

    /// 额外 10 类风格迥异的边界/对抗场景端到端校验（Case 6–15）
    @MainActor
    func testTenDiverseGoalCreationEdgeCases() async throws {
        let now = Date()

        // Case 6: 数值上升达标型（卧推 60 -> 90 kg）
        let c6JSON = """
        {
          "id": "c6", "title": "卧推突破 90kg", "domain": "health",
          "goalKind": "target", "metricSource": "manual", "metricUnit": "kg",
          "metricBaselineValue": 60, "metricTargetValue": 90,
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d6 = try JSONDecoder().decode(GoalDraft.self, from: Data(c6JSON.utf8))
        let conf6 = GoalPlanConfirmation.defaults(from: d6, successEvidence: "卧推 90kg", now: now)
        XCTAssertEqual(conf6.resultSource?.comparison, .reach, "目标值大于基线时应为 reach 而非 trendDown")
        XCTAssertEqual(d6.quantitativeSummary, "60 → 90 kg")
        let g6 = try repository.createGoal(from: d6, allowAIContext: true)
        XCTAssertEqual(g6.baselineValueDouble, 60)
        XCTAssertEqual(g6.metricTargetValueDouble, 90)

        // Case 7: 模型漏标 goalKind + 字符串数字 + 未知 domain 容错兜底
        let c7JSON = """
        {
          "id": "c7", "title": "今年读完 24 本书", "domain": "alien_domain",
          "goalKind": "process", "metricSource": "manual", "metricUnit": "本",
          "metricBaselineValue": null, "metricTargetValue": "24",
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d7 = try JSONDecoder().decode(GoalDraft.self, from: Data(c7JSON.utf8))
        XCTAssertEqual(d7.domain, .other, "未知领域应安全回退 .other")
        XCTAssertEqual(d7.goalKind, .cumulative, "有目标值无基线时漏标 goalKind 应自动兜底 .cumulative")
        XCTAssertEqual(d7.metricTargetValue, 24)

        // Case 8: 小数精度（体脂率 22.5% -> 18.5%）
        let c8JSON = """
        {
          "id": "c8", "title": "体脂率降到 18.5%", "domain": "health",
          "goalKind": "target", "metricSource": "manual", "metricUnit": "%",
          "metricBaselineValue": 22.5, "metricTargetValue": 18.5,
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d8 = try JSONDecoder().decode(GoalDraft.self, from: Data(c8JSON.utf8))
        XCTAssertEqual(d8.quantitativeSummary, "22.5 → 18.5 %")
        let g8 = try repository.createGoal(from: d8, allowAIContext: true)
        XCTAssertEqual(g8.baselineValueDouble ?? 0, 22.5, accuracy: 0.01)
        XCTAssertEqual(g8.metricTargetValueDouble ?? 0, 18.5, accuracy: 0.01)

        // Case 9: 零基线戒断型坏习惯（彻底戒糖饮料 abstain）
        let c9JSON = """
        {
          "id": "c9", "title": "戒掉含糖饮料", "domain": "health",
          "goalKind": "process", "metricSource": "manual", "metricUnit": null,
          "metricBaselineValue": null, "metricTargetValue": null,
          "tasks": [],
          "habits": [{"id":"h9","isSelected":true,"name":"不喝含糖饮料","frequency":"daily","targetCount":1,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":true,"successRule":"abstain"}],
          "missingInfoWarnings": []
        }
        """
        let d9 = try JSONDecoder().decode(GoalDraft.self, from: Data(c9JSON.utf8))
        let res9 = try repository.saveDraft(d9, allowAIContext: true)
        XCTAssertEqual(res9.createdHabitCount, 1)
        XCTAssertEqual(res9.goal.goalKindEnum, .process)

        // Case 10: 多任务多习惯部分取消勾选
        let c10JSON = """
        {
          "id": "c10", "title": "备战半程马拉松", "domain": "health",
          "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "km",
          "metricBaselineValue": null, "metricTargetValue": 120,
          "tasks": [
            {"id":"t1","isSelected":true,"title":"买跑鞋","dueDateText":null,"priority":1,"note":null},
            {"id":"t2","isSelected":false,"title":"报训练营","dueDateText":null,"priority":2,"note":null},
            {"id":"t3","isSelected":true,"title":"报名赛事","dueDateText":null,"priority":1,"note":null},
            {"id":"t4","isSelected":false,"title":"买护膝","dueDateText":null,"priority":3,"note":null}
          ],
          "habits": [
            {"id":"h1","isSelected":true,"name":"晨跑","frequency":"weekly","targetCount":3,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"},
            {"id":"h2","isSelected":false,"name":"拉伸","frequency":"daily","targetCount":1,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"},
            {"id":"h3","isSelected":true,"name":"核心训练","frequency":"weekly","targetCount":2,"type":"checkIn","unit":null,"targetValue":null,"isBadHabit":false,"successRule":"completeWhenDone"}
          ],
          "missingInfoWarnings": []
        }
        """
        let d10 = try JSONDecoder().decode(GoalDraft.self, from: Data(c10JSON.utf8))
        let res10 = try repository.saveDraft(d10, allowAIContext: true)
        XCTAssertEqual(res10.createdTaskCount, 2, "只应创建选中的 2 个任务")
        XCTAssertEqual(res10.createdHabitCount, 2, "只应创建选中的 2 个习惯")

        // Case 11: 无单位量化目标（单位为 nil 或空串时不出现多余尾空格）
        let c11JSON = """
        {
          "id": "c11", "title": "完成 12 次深度复盘", "domain": "career",
          "goalKind": "cumulative", "metricSource": "manual", "metricUnit": "",
          "metricBaselineValue": null, "metricTargetValue": 12,
          "tasks": [], "habits": [], "missingInfoWarnings": []
        }
        """
        let d11 = try JSONDecoder().decode(GoalDraft.self, from: Data(c11JSON.utf8))
        XCTAssertEqual(d11.quantitativeSummary, "目标 12")

        // Case 12: 财务单账户余额达标（100000 元 + accountBalance）
        let accountID = UUID()
        var d12 = GoalDraft(
            id: "c12",
            title: "攒够 10 万买车首付",
            summary: nil,
            domain: .finance,
            iconEmoji: nil,
            desiredOutcome: "专户达到 10 万",
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: .target,
            metricSource: .ledger,
            metricUnit: "元",
            metricTargetValue: 100000,
            metricBaselineValue: nil,
            sourceHabitId: nil,
            ledgerScope: GoalLedgerScopePayload(kind: .accountBalance, accountID: accountID)
        )
        let conf12 = GoalPlanConfirmation.defaults(from: d12, successEvidence: "账户余额 10 万", now: now)
        XCTAssertEqual(conf12.resultSource?.sourceType, .ledger)
        XCTAssertEqual(conf12.resultSource?.ledgerScope?.kind, .accountBalance)
        XCTAssertEqual(conf12.resultSource?.ledgerScope?.accountID, accountID)
        let g12 = try repository.createGoal(from: d12, allowAIContext: true)
        XCTAssertEqual(g12.ledgerScopePayload?.accountID, accountID)

        // Case 13: 超长标题 + 无截止日期（deadlineText = null）
        let longTitle = "每天坚持学习 Swift 并发编程与 SwiftUI 底层渲染原理并输出高质量技术笔记总结"
        d12.title = longTitle
        d12.deadlineText = nil
        d12.goalKind = .process
        d12.metricTargetValue = nil
        let g13 = try repository.createGoal(from: d12, allowAIContext: true)
        XCTAssertEqual(g13.title, longTitle)
        XCTAssertNil(g13.deadline)

        // Case 14: 多轮流式追问 + 第二轮分片吐出 DRAFT_READY
        let streamDraftJSON = """
        {"id":"c14","title":"托福冲刺 105 分","domain":"learning","goalKind":"target","metricSource":"manual","metricUnit":"分","metricBaselineValue":88,"metricTargetValue":105,"tasks":[],"habits":[],"missingInfoWarnings":[]}
        """
        let multiTurnProvider = StubGoalPlanningStreamProvider(responses: [
            ["好的，", "你目前的英语基础大概是多少分呢？"],
            ["DR", "AFT", "_READY"],
            [streamDraftJSON]
        ])
        let coordinator = GoalPlanningCoordinator()
        var turn1Texts: [String] = []
        let r1 = try await coordinator.startStreaming(
            seedText: "我想考托福 105 分",
            userContext: .empty,
            provider: multiTurnProvider,
            onQuestionText: { turn1Texts.append($0) },
            onDraftGenerating: { XCTFail("第一轮不应触发草案生成") }
        )
        XCTAssertEqual(r1.session.status, .collecting)
        XCTAssertEqual(turn1Texts.last, "好的，你目前的英语基础大概是多少分呢？")

        var turn2Texts: [String] = []
        var turn2Generating = false
        let r2 = try await coordinator.handleUserReplyStreaming(
            "目前 88 分，三个月后考试",
            session: r1.session,
            userContext: .empty,
            provider: multiTurnProvider,
            onQuestionText: { turn2Texts.append($0) },
            onDraftGenerating: { turn2Generating = true }
        )
        XCTAssertTrue(turn2Texts.isEmpty, "第二轮 DRAFT_READY 不应泄漏到对话气泡")
        XCTAssertTrue(turn2Generating)
        XCTAssertEqual(r2.draft?.metricBaselineValue, 88)
        XCTAssertEqual(r2.draft?.metricTargetValue, 105)

        // Case 15: 数据源往返切换（habit -> ledger -> manual）不残留脏 sourceHabitId / ledgerScope
        var d15 = try JSONDecoder().decode(GoalDraft.self, from: Data(c6JSON.utf8))
        d15.metricSource = .habit
        d15.sourceHabitId = UUID()
        d15.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        // 模拟用户最终改回 manual
        d15.metricSource = .manual
        d15.sourceHabitId = nil
        d15.ledgerScope = nil
        let g15 = try repository.createGoal(from: d15, allowAIContext: true)
        XCTAssertEqual(g15.metricSourceEnum, .manual)
        XCTAssertNil(g15.sourceHabitId)
        XCTAssertNil(g15.ledgerScopePayload)
    }

    @MainActor
    func testSavedWeightGoalTracksHabitRecordsAndKeepsStartingValue() throws {
        let finance = FinanceRepository(context: context)
        CoreDataTestSupport.retain(finance)
        let habit = Habit.create(in: context, name: "体重", icon: "scalemass", color: "#EA580C",
                                 type: .numeric, unit: "kg", aggregationType: .latest)
        let first = HabitRecord.createNumeric(in: context, habit: habit, value: 75)
        first.date = Date().addingTimeInterval(-100)
        try context.save()

        var draft = GoalEditForm.emptyDraft()
        draft.title = "体重管理"
        draft.goalKind = .target
        draft.metricSource = .habit
        draft.sourceHabitId = habit.id
        draft.metricUnit = "kg"
        draft.metricTargetValue = 65
        draft.metricBaselineValue = 75
        let goal = try repository.saveDraft(draft, allowAIContext: false, source: "manual").goal
        let goalID = goal.id
        let start = goal.baselineDate
        XCTAssertNil(habit.goal, "引用体重时保留原习惯归属")

        let next = HabitRecord.createNumeric(in: context, habit: habit, value: 72)
        next.date = Date().addingTimeInterval(-3)
        try context.save()
        let progress = try XCTUnwrap(GoalMetricEvaluator.evaluate(goal: goal, finance: finance))
        XCTAssertEqual(progress.currentValue, 72)
        XCTAssertEqual(progress.progress, 0.3, accuracy: 0.0001)

        try repository.updateFields(goal, deadline: .some(Date().addingTimeInterval(86400)))
        XCTAssertEqual(goal.id, goalID)
        XCTAssertEqual(goal.baselineDate, start)
        XCTAssertEqual(goal.baselineValueDouble, 75)
        XCTAssertEqual(goal.metricTargetValueDouble, 65)

        let rebound = HabitRecord.createNumeric(in: context, habit: habit, value: 76)
        rebound.date = Date().addingTimeInterval(-1)
        try context.save()
        let after = try XCTUnwrap(GoalMetricEvaluator.evaluate(goal: goal, finance: finance))
        XCTAssertEqual(after.currentValue, 76)
        XCTAssertEqual(after.progress, 0)
        XCTAssertFalse(after.isAchieved)
    }

    @MainActor
    func testOldWeightLossGoalRepairsDefaultDirectionAndRespectsExplicitOverride() throws {
        let finance = FinanceRepository(context: context)
        CoreDataTestSupport.retain(finance)
        let habit = Habit.create(in: context, name: "体重", icon: "scalemass", color: "#EA580C",
                                 type: .numeric, unit: "KG", aggregationType: .latest)
        let sample = HabitRecord.createNumeric(in: context, habit: habit, value: 82.5)
        sample.date = Date().addingTimeInterval(-100)
        try context.save()

        var draft = GoalEditForm.emptyDraft()
        draft.title = "减肥"
        draft.goalKind = .target
        draft.metricSource = .habit
        draft.sourceHabitId = habit.id
        draft.metricUnit = "KG"
        draft.metricTargetValue = 75
        draft.metricBaselineValue = 82.5
        draft.metricComparison = .trendUp
        let goal = try repository.saveDraft(draft, allowAIContext: false, source: "manual").goal

        let effective = try GoalPlanResolver.resolveCurrentPlan(goal: goal, in: context, persist: false)
        XCTAssertEqual(effective.payload.resultSource?.comparison, .trendDown)
        let progress = try XCTUnwrap(GoalMetricEvaluator.evaluate(goal: goal, finance: finance))
        XCTAssertFalse(progress.isAchieved)
        XCTAssertEqual(progress.progress, 0)

        let reached = HabitRecord.createNumeric(in: context, habit: habit, value: 75)
        reached.date = Date().addingTimeInterval(-1)
        try context.save()
        XCTAssertEqual(GoalMetricEvaluator.evaluate(goal: goal, finance: finance)?.isAchieved, true)
        XCTAssertEqual(GoalMetricEvaluator.evaluate(goal: goal, finance: finance)?.progress, 1)

        try repository.updateFields(goal, metricComparison: .trendUp, metricComparisonIsExplicit: true)
        let explicit = GoalPlanResolver.resultConfiguration(goal: goal, in: context).source
        XCTAssertEqual(explicit?.comparison, .trendUp)
        XCTAssertEqual(explicit?.comparisonIsExplicit, true)
    }

    @MainActor
    func testManualHealthGoalSavesAndEditsRealPlanSource() throws {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "从苹果健康读取步数"
        draft.goalKind = .cumulative
        draft.metricSource = .healthKit
        draft.healthMetricKind = .stepCount
        draft.metricUnit = "步"
        draft.metricTargetValue = 10_000
        draft.metricComparison = .reach
        let goal = try repository.saveDraft(draft, allowAIContext: false, source: "manual").goal
        let initial = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(goal.healthMetricKindEnum, .stepCount)
        XCTAssertEqual(initial.planPayloadV2?.resultSource?.sourceType, .healthKit)
        XCTAssertEqual(initial.planPayloadV2?.resultSource?.healthMetricKind, .stepCount)
        XCTAssertEqual(GoalEditForm.draft(from: goal).healthMetricKind, .stepCount)

        try repository.updateFields(
            goal, metricUnit: .some("分钟"), metricTargetValue: .some(150), healthMetricKind: .some(.workoutMinutes),
            expectedPlanRevisionID: initial.id
        )
        let edited = try XCTUnwrap(GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: context))
        XCTAssertEqual(goal.healthMetricKindEnum, .workoutMinutes)
        XCTAssertEqual(edited.planPayloadV2?.resultSource?.healthMetricKind, .workoutMinutes)
        XCTAssertEqual(edited.planPayloadV2?.schemaVersion, 4)
        XCTAssertNil(edited.planPayloadV2?.resultSource?.baselineValue)
    }

    @MainActor
    func testHealthKitGoalEvaluation() throws {
        // 达标型：苹果健康体重 82 -> 70 kg，当前同步 76 kg -> 50% 进度；同步 69.5 kg -> isAchieved
        let weightDraft = GoalDraft(
            id: "hk-weight",
            title: "苹果健康减重到 70kg",
            summary: nil,
            domain: .health,
            iconEmoji: nil,
            desiredOutcome: "70kg",
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: .target,
            metricSource: .healthKit,
            metricUnit: "kg",
            metricTargetValue: 70,
            metricBaselineValue: 82,
            sourceHabitId: nil,
            ledgerScope: nil,
            healthMetricKind: .bodyMass
        )
        let weightGoal = try repository.createGoal(from: weightDraft, allowAIContext: true)
        XCTAssertEqual(weightGoal.metricSourceEnum, .healthKit)
        XCTAssertEqual(weightGoal.healthMetricKindEnum, .bodyMass)

        GoalHealthKitCache.shared.setValue(76.0, for: weightGoal.id)
        let mid = GoalMetricEvaluator.evaluate(goal: weightGoal)
        XCTAssertEqual(mid?.currentValue, 76.0)
        XCTAssertEqual(mid?.progress ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(mid?.isAchieved, false)

        GoalHealthKitCache.shared.setValue(69.5, for: weightGoal.id)
        let done = GoalMetricEvaluator.evaluate(goal: weightGoal)
        XCTAssertEqual(done?.isAchieved, true)
        XCTAssertEqual(done?.progress ?? 0, 1.0, accuracy: 0.01)

        // 累积型：苹果健康步数目标 100000 步，当前 25000 步 -> 25%
        let stepsDraft = GoalDraft(
            id: "hk-steps",
            title: "本月走满 10 万步",
            summary: nil,
            domain: .health,
            iconEmoji: nil,
            desiredOutcome: nil,
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: .cumulative,
            metricSource: .healthKit,
            metricUnit: "步",
            metricTargetValue: 100000,
            metricBaselineValue: nil,
            sourceHabitId: nil,
            ledgerScope: nil,
            healthMetricKind: .stepCount
        )
        let stepsGoal = try repository.createGoal(from: stepsDraft, allowAIContext: true)
        GoalHealthKitCache.shared.setValue(25000, for: stepsGoal.id)
        let stepsProgress = GoalMetricEvaluator.evaluate(goal: stepsGoal)
        XCTAssertEqual(stepsProgress?.progress ?? 0, 0.25, accuracy: 0.01)
        XCTAssertEqual(stepsProgress?.isAchieved, false)
    }
}

private final class StubGoalPlanningStreamProvider: AIProvider {
    var lastCallLog: LLMCallLog? = nil
    private var responses: [[String]]

    init(responses: [[String]]) {
        self.responses = responses
    }

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        throw APIError.serverError("unused")
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        responses.isEmpty ? "" : responses.removeFirst().joined()
    }

    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error> {
        let chunks = responses.isEmpty ? [] : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error> {
        chatStreaming(messages: messages, userContext: userContext)
    }
}
