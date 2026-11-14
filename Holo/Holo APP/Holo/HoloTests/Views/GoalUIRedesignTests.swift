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
            "Habit", "HabitRecord", "TodoTask",
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

    func testCumulativeHintNumberExtraction() {
        XCTAssertEqual(GoalEditForm.cumulativeHintNumber(inTitle: "今年跑满 300 公里"), 300)
        XCTAssertEqual(GoalEditForm.cumulativeHintNumber(inTitle: "攒 30 万"), 30) // 阈值边界：≥30 触发
        XCTAssertNil(GoalEditForm.cumulativeHintNumber(inTitle: "每天睡前读 20 分钟书"))
        XCTAssertNil(GoalEditForm.cumulativeHintNumber(inTitle: "读三百页")) // 中文数字不触发
        XCTAssertNil(GoalEditForm.cumulativeHintNumber(inTitle: "跑３００公里")) // 全角数字不触发
        XCTAssertEqual(GoalEditForm.cumulativeHintNumber(inTitle: "每天走 10000 步"), 10000)
        // 多个数字串取首个达到阈值的
        XCTAssertEqual(GoalEditForm.cumulativeHintNumber(inTitle: "跑 20 次累计 400 分钟"), 400)
    }

    func testShowsCumulativeHintRule() {
        var draft = GoalEditForm.emptyDraft()
        draft.title = "今年跑满 300 公里"
        XCTAssertTrue(GoalEditForm.showsCumulativeHint(in: draft)) // 过程型+数字达标：出现
        draft.goalKind = .cumulative
        XCTAssertFalse(GoalEditForm.showsCumulativeHint(in: draft)) // 切走类型：消失
        draft.goalKind = .target
        XCTAssertFalse(GoalEditForm.showsCumulativeHint(in: draft))
        draft.goalKind = .process
        draft.metricTargetValue = 300
        XCTAssertFalse(GoalEditForm.showsCumulativeHint(in: draft)) // 数字已出现：消失
        draft.metricTargetValue = nil
        draft.title = "每天睡前读 20 分钟书"
        XCTAssertFalse(GoalEditForm.showsCumulativeHint(in: draft)) // 数字 < 阈值：不出现
    }

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
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft), "预填后可直接保存")
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

    func testMetricValidationUnitOptional() {
        // 累积型：数字有效+标题在（canSave 侧）即可保存，单位空不拦
        var draft = GoalEditForm.emptyDraft()
        draft.title = "今年跑满 300 公里"
        draft.goalKind = .cumulative
        draft.metricTargetValue = 300
        draft.metricUnit = nil
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft), "单位空合法（规格 B5）")
        XCTAssertNil(GoalEditForm.disabledHint(for: draft), "单位空不应报「数字还没填完」")

        // 达标型同理
        draft.goalKind = .target
        draft.metricBaselineValue = 75
        draft.metricTargetValue = 70
        draft.metricUnit = nil
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft))
        XCTAssertNil(GoalEditForm.disabledHint(for: draft))

        // 数字缺失才报数字空（三态之一）
        draft.metricTargetValue = nil
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft))
        XCTAssertEqual(GoalEditForm.disabledHint(for: draft), "数字还没填完")
    }

    func testUnitKeywordMapping() {
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "今年跑满 300 公里"), "km")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "减到 70KG"), "kg")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "减到 70公斤"), "kg")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "存 3 万元应急金"), "¥")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "攒 5000 块"), "¥")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "今年读 30 本书"), "本")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "去 50 次健身房"), "次")
        XCTAssertEqual(GoalEditForm.unitKeyword(in: "每天读 40 页"), "页")
        XCTAssertNil(GoalEditForm.unitKeyword(in: "完成一场全马"), "不命中留空")
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
        XCTAssertEqual(GoalMetricSource.selectable(for: .cumulative), [.manual, .habit, .ledger])
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
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft))
        XCTAssertTrue(GoalEditForm.metricFieldsValid(in: draft))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: UUID())
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountDelta, accountID: nil)
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft), "账户净结余口径必须带账户")

        // 达标型：账户余额必选具体账户
        draft.goalKind = .target
        draft.metricBaselineValue = 1000
        draft.metricTargetValue = 1500
        draft.ledgerScope = GoalLedgerScopePayload(kind: .accountBalance, accountID: UUID())
        XCTAssertTrue(GoalEditForm.hasValidLedgerScope(in: draft))
        draft.ledgerScope = GoalLedgerScopePayload(kind: .wholeLedgerDelta, accountID: nil)
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft), "达标型不提供全账本口径")
        XCTAssertFalse(GoalEditForm.metricFieldsValid(in: draft), "范围不合法不可保存")
        XCTAssertNotNil(GoalEditForm.disabledHint(for: draft), "范围不合法给出禁用文案")

        // 范围缺失同样拦保存
        draft.ledgerScope = nil
        XCTAssertFalse(GoalEditForm.hasValidLedgerScope(in: draft))
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
}
