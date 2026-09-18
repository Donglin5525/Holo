//
//  GoalWorkshopCommitService.swift
//  Holo
//
//  目标共创·原子提交（方案任务 6 / §2.4）
//
//  - 确认页保存 = 一次数据库事务：Goal + 关联任务/习惯 + 决策版本 + 会话回执，
//    只调用一次 context.save()；中途任何失败 rollback，不落半套数据。
//  - 幂等：同会话已提交（Goal.sourceSessionID 已存在）直接返回已有回执；
//    重复点击/重试/跨设备同逻辑 ID 均不重复创建。
//  - 通知/提醒/看板纳入/列表刷新只在保存成功后发生，不在构造过程中发。
//  - 旧手建与旧 AI 草案（GoalRepository.saveDraft）复用同一事务。
//

import Foundation
import CoreData

struct GoalWorkshopCommitReceipt: Equatable {
    let goalID: UUID
    let createdTaskCount: Int
    let createdHabitCount: Int
    let revisionNumber: Int
    /// 命中幂等（未创建新数据）时为 true
    let wasIdempotentReplay: Bool
}

struct GoalWorkshopCommitInput {
    let session: GoalWorkshopSessionV1
    /// 用户在确认页最终编辑后的草案
    let draft: GoalDraft
    let successEvidence: String
    let assumptions: [String]
    let allowAIContext: Bool
}

@MainActor
final class GoalWorkshopCommitService {

    static let shared = GoalWorkshopCommitService()

    private init() {}

    enum CommitError: Error, Equatable {
        case sessionAlreadyApplied(goalID: UUID)
        case validation(String)
        case saveFailed(String)
    }

    /// 会话确认：后台上下文单事务提交 + 保存成功后的统一副作用
    func commitWorkshop(_ input: GoalWorkshopCommitInput) async throws -> GoalWorkshopCommitReceipt {
        let context = CoreDataStack.shared.newBackgroundContext()
        let receipt = try await context.perform {
            try Self.performCommit(
                draft: input.draft,
                allowAIContext: input.allowAIContext,
                source: "goalWorkshop",
                sourceSessionID: input.session.id,
                successEvidence: input.successEvidence,
                assumptions: input.assumptions,
                selectedRouteTitle: input.session.routeOptions
                    .first { $0.id == input.session.selectedRouteID }?.title,
                in: context
            )
        }
        guard !receipt.wasIdempotentReplay else { return receipt }
        await Self.postSaveSideEffects(receipt: receipt)
        return receipt
    }

    /// 保存成功后的统一出口：刷新列表、发数据变更通知、习惯入看板。
    /// 各模块通知只在保存成功后发出（§2.4），失败路径不会到达这里。
    nonisolated static func postSaveSideEffects(receipt: GoalWorkshopCommitReceipt) async {
        await MainActor.run {
            TodoRepository.shared.loadActiveTasks()
            HabitRepository.shared.loadActiveHabits()
            GoalRepository.shared.loadGoals()
            GoalNotificationService.broadcastGoalDataChange()
            // 新习惯纳入看板（与 HabitRepository.createHabit 同口径）：按目标关联反查习惯 id
            let request = NSFetchRequest<Habit>(entityName: "Habit")
            request.predicate = NSPredicate(format: "goal.id == %@ AND deletedAt == nil", receipt.goalID as CVarArg)
            for habit in (try? CoreDataStack.shared.viewContext.fetch(request)) ?? [] {
                HabitStatsDisplaySettings.shared.addDashboardHabitIfNeeded(habit.id)
            }
        }
    }

    // MARK: - 单事务核心（同步、context 无关；saveDraft 与会话提交共用）

    /// 在给定 context 内构造 Goal/任务/习惯/决策版本/会话回执并只保存一次。
    /// 任何一步失败抛错，context 由调用方 rollback/丢弃。
    static func performCommit(
        draft: GoalDraft,
        allowAIContext: Bool,
        source: String,
        sourceSessionID: UUID?,
        successEvidence: String,
        assumptions: [String],
        selectedRouteTitle: String?,
        in context: NSManagedObjectContext
    ) throws -> GoalWorkshopCommitReceipt {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CommitError.validation("目标标题不能为空")
        }
        // 日期严格校验与响应契约同口径（确认页可能改动日期）
        var dateTexts: [String] = []
        if let deadline = draft.deadlineText { dateTexts.append(deadline) }
        for task in draft.tasks where task.isSelected {
            if let due = task.dueDateText { dateTexts.append(due) }
        }
        for text in dateTexts where !GoalWorkshopValidator.isValidStrictDay(text) {
            throw CommitError.validation("日期格式应为 yyyy-MM-dd：\(text)")
        }

        // 幂等：同会话已提交过 → 返回已有回执，不再创建
        if let sourceSessionID,
           let existing = fetchGoalIDBySessionID(sourceSessionID, in: context) {
            return GoalWorkshopCommitReceipt(
                goalID: existing,
                createdTaskCount: 0,
                createdHabitCount: 0,
                revisionNumber: 0,
                wasIdempotentReplay: true
            )
        }

        // 构造 Goal（不保存）
        let goal = Goal.create(
            in: context,
            title: trimmedTitle,
            summary: draft.summary,
            domain: draft.domain,
            desiredOutcome: draft.desiredOutcome,
            motivation: draft.motivation,
            deadline: Self.parseDay(draft.deadlineText),
            allowAIContext: allowAIContext
        )
        goal.iconEmoji = draft.iconEmoji
        goal.source = source
        goal.sourceSessionID = sourceSessionID
        Self.applyQuantitativeFields(from: draft, to: goal, now: Date())

        // 构造任务/习惯（业务映射唯一真源在 GoalRepository 的无保存构造器）
        var taskCount = 0
        for (index, taskDraft) in draft.tasks.enumerated() where taskDraft.isSelected {
            #if DEBUG
            if GoalWorkshopCommitHooks.shared.shouldFailTaskAtIndex?(index) == true {
                throw CommitError.saveFailed("任务构造失败（测试注入）#\(index)")
            }
            #endif
            let task = GoalRepository.makeTask(from: taskDraft, goal: goal, in: context)
            taskCount += 1
        }
        var habitCount = 0
        for (index, habitDraft) in draft.habits.enumerated() where habitDraft.isSelected {
            #if DEBUG
            if GoalWorkshopCommitHooks.shared.shouldFailHabitAtIndex?(index) == true {
                throw CommitError.saveFailed("习惯构造失败（测试注入）#\(index)")
            }
            #endif
            let habit = GoalRepository.makeHabit(from: habitDraft, goal: goal, in: context)
            habitCount += 1
        }

        // 决策版本（goalID + sessionID + revision 稳定计算；新建目标首版恒为 1，重规划在 P1 起递增）
        let revisionNumber = 1
        if let sourceSessionID {
            _ = GoalPlanRevisionMO.make(
                in: context,
                goalID: goal.id,
                sourceSessionID: sourceSessionID,
                revisionNumber: revisionNumber,
                summary: GoalWorkshopDecisionSummaryV1(
                    definition: GoalWorkshopGoalDefinition(
                        title: trimmedTitle,
                        desiredOutcome: draft.desiredOutcome,
                        motivation: draft.motivation,
                        deadlineText: draft.deadlineText
                    ),
                    selectedRouteTitle: selectedRouteTitle,
                    planTitle: trimmedTitle,
                    successEvidence: successEvidence,
                    assumptions: assumptions,
                    firstActionTitle: nil,
                    selectedTaskTitles: draft.tasks.filter(\.isSelected).map(\.title),
                    selectedHabitNames: draft.habits.filter(\.isSelected).map(\.name),
                    allowAIContext: allowAIContext
                )
            )
        }

        // 会话回执（同事务）
        if let sourceSessionID {
            Self.applySessionReceipt(sessionID: sourceSessionID, goalID: goal.id, in: context)
        }

        #if DEBUG
        if GoalWorkshopCommitHooks.shared.shouldFailSave?() == true {
            throw CommitError.saveFailed("context.save 失败（测试注入）")
        }
        #endif

        try context.save()
        return GoalWorkshopCommitReceipt(
            goalID: goal.id,
            createdTaskCount: taskCount,
            createdHabitCount: habitCount,
            revisionNumber: revisionNumber,
            wasIdempotentReplay: false
        )
    }

    // MARK: - 私有

    static func fetchGoalIDBySessionID(_ sessionID: UUID, in context: NSManagedObjectContext) -> UUID? {
        let request = NSFetchRequest<Goal>(entityName: "Goal")
        request.predicate = NSPredicate(
            format: "sourceSessionID == %@ AND deletedAt == nil",
            sessionID as CVarArg
        )
        request.fetchLimit = 1
        // iCloud 副本天然同 id：取任一即可（同 sourceSessionID 即同一逻辑目标）
        return (try? context.fetch(request))?.first?.id
    }

    static func applySessionReceipt(sessionID: UUID, goalID: UUID, in context: NSManagedObjectContext) {
        let request = NSFetchRequest<GoalWorkshopSessionMO>(entityName: "GoalWorkshopSessionMO")
        request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
        for row in (try? context.fetch(request)) ?? [] {
            row.appliedGoalID = goalID
            row.phase = .saved
            row.updatedAt = Date()
        }
    }

    /// 与旧链路一致的宽松日解析（yyyy-MM-dd）；响应侧严格校验已在上游完成
    static func parseDay(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return GoalWorkshopValidator.strictDayFormatter.date(from: text)
    }

    static func applyQuantitativeFields(from draft: GoalDraft, to goal: Goal, now: Date) {
        goal.goalKindEnum = draft.goalKind
        guard draft.isQuantitative else { return }
        goal.metricSourceEnum = draft.metricSource
        goal.metricUnit = draft.metricUnit
        goal.metricTargetValueDouble = draft.metricTargetValue
        goal.baselineValueDouble = draft.goalKind == .target ? draft.metricBaselineValue : nil
        goal.sourceHabitId = draft.metricSource == .habit ? draft.sourceHabitId : nil
        goal.baselineDate = now
    }
}

#if DEBUG
/// 失败注入钩子（仅测试使用；生产构建不存在）
final class GoalWorkshopCommitHooks {
    static let shared = GoalWorkshopCommitHooks()
    var shouldFailTaskAtIndex: ((Int) -> Bool)?
    var shouldFailHabitAtIndex: ((Int) -> Bool)?
    var shouldFailSave: (() -> Bool)?
}
#endif
