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
        try CoreDataTestSupport.clearEntities(context, ["Goal", "GoalPlanRevisionMO"])
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
}
