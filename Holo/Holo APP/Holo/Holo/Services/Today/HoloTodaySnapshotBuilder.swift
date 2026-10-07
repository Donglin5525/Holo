//
//  HoloTodaySnapshotBuilder.swift
//  Holo
//
//  「今天」统一快照构建器（今日看板 Matter 化方案 §6.2）
//
//  - 从 Schedule / Todo / Habit / Health / Finance / Matter 仓库拉轻量值快照；
//  - 统一日边界（referenceTime 冻结在同一次构建）；
//  - 解析真实 MatterLink，为任务附加 Matter 归属；task / Matter Next Action 同实体去重；
//  - 调用唯一 HoloTodayFocusResolver；局部失败写入 sectionStates，不让整页空白；
//  - 不发网络请求，不触发模型，不写业务数据；
//  - 一次 refresh 内每个仓库最多一轮查询。
//

import Foundation
import CoreData
import EventKit

@MainActor
enum HoloTodaySnapshotBuilder {

    /// 构建一次完整快照。局部模块失败不抛错，用 sectionStates 如实交代。
    static func build(referenceTime: Date = Date()) async -> HoloTodaySnapshot {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: referenceTime)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let scope = HoloTodayDayScope(
            referenceTime: referenceTime,
            calendar: calendar,
            timeZone: TimeZone.current
        )

        var sectionStates: [HoloTodaySection: HoloTodaySectionState] = [:]

        // MARK: Matter（active 最多读 20 个；attention 确定性重算）

        var matterItems: [HoloTodayMatterItem] = []
        var matterCandidates: [HoloTodayMatterCandidate] = []
        var taskMatterLookup: [UUID: (matterID: UUID, matterTitle: String)] = [:]

        if HoloMatterRolloutPolicy.storageEnabled {
            do {
                let matters = HoloMatterRepository.shared.matters(lifecycles: [.active]).prefix(20)
                for matter in matters {
                    let loopInputs = HoloMatterRepository.shared.attentionLoopInputs(matterID: matter.id)
                    let attention = HoloMatterAttentionPolicy.evaluate(
                        targetDate: matter.targetDate, loops: loopInputs, now: referenceTime
                    )
                    let projection = matter.projection
                    let isFresh = projection != nil && !matter.isProjectionStale
                        && projection?.sourceMatterRevision == matter.revision

                    // 真实链接任务集合（link 行 entityID）。
                    let linkedTaskIDs = Set(
                        HoloMatterRepository.shared.links(matterID: matter.id)
                            .filter { $0.entityType == .todoTask }
                            .compactMap { UUID(uuidString: $0.entityID) }
                    )
                    for taskID in linkedTaskIDs {
                        taskMatterLookup[taskID] = (matter.id, matter.title)
                    }

                    let candidate = HoloTodayMatterCandidate(
                        id: matter.id,
                        title: matter.title,
                        targetDate: matter.targetDate,
                        revision: matter.revision,
                        updatedAt: matter.updatedAt,
                        attention: attention.attention,
                        loops: loopInputs.map {
                            HoloTodayLoopCandidate(
                                id: $0.id ?? UUID(),
                                title: $0.title,
                                state: $0.state,
                                epistemic: $0.epistemic,
                                targetDate: $0.targetDate,
                                linkedTaskID: $0.linkedTaskID
                            )
                        },
                        nextAction: isFresh ? projection?.nextAction.map {
                            HoloTodayMatterActionCandidate(
                                kind: $0.kind,
                                entityID: $0.entityID.flatMap(UUID.init(uuidString:)),
                                title: $0.title,
                                targetDate: $0.targetDate,
                                sourceMatterRevision: projection?.sourceMatterRevision ?? 0
                            )
                        } : nil,
                        linkedTaskIDs: linkedTaskIDs
                    )
                    matterCandidates.append(candidate)

                    // V2 计划进度：planOrder 口径实时计算（§5.6），不依赖 projection。
                    let planTasks = MatterPlanQuery.planTasks(matterID: matter.id, repository: HoloMatterRepository.shared)
                    matterItems.append(HoloTodayMatterItem(
                        id: matter.id,
                        title: matter.title,
                        attention: attention.attention,
                        attentionReason: attention.reason,
                        summary: isFresh ? projection?.summary : nil,
                        nextActionTitle: isFresh ? projection?.nextAction?.title : nil,
                        nextAction: nextActionAction(from: projection?.nextAction, isFresh: isFresh, matterID: matter.id),
                        daysUntilTarget: matter.targetDate.flatMap {
                            calendar.dateComponents([.day], from: dayStart, to: calendar.startOfDay(for: $0)).day
                        },
                        suggestedCount: loopInputs.filter { $0.epistemic == .suggested && ($0.state == .open) }.count,
                        isFocus: false,
                        cardAction: .openMatter(matter.id, focusOpenLoopID: nil),
                        planDoneCount: planTasks.filter(\.completed).count,
                        planTotalCount: planTasks.count
                    ))
                }
                sectionStates[.matters] = matterItems.isEmpty ? .empty : .content
            } catch {
                sectionStates[.matters] = .failed(lastSuccessfulAt: nil)
            }
        } else {
            sectionStates[.matters] = .empty
        }

        // MARK: 日程 + 任务 → 任务候选 / Agenda

        var scheduleCandidates: [HoloTodayScheduleCandidate] = []
        var agendaItems: [HoloTodayAgendaItem] = []
        var sectionAgendaFailed = false

        // 日程：ScheduleStore 当日缓存（同步读取，不触发重新加载）。
        if ScheduleStore.shared.isEnabled, ScheduleStore.shared.authorizationStatus == .fullAccess {
            let schedules = ScheduleStore.shared.cachedSchedules(onDay: referenceTime)
            for item in schedules {
                scheduleCandidates.append(HoloTodayScheduleCandidate(
                    id: item.id,
                    title: item.title,
                    startAt: item.startDate,
                    endAt: item.endDate,
                    isAllDay: item.isAllDay
                ))
            }
        }

        // 任务：今日/逾期/无日期各一轮查询。
        let todoRepo = TodoRepository.shared
        let dueToday = todoRepo.getDueTodayTasks()
        let overdue = todoRepo.getOverdueTasks()
        let unplanned = todoRepo.getUnplannedOpenTasks(limit: 3)

        var taskCandidates: [HoloTodayTaskCandidate] = []
        var agendaTaskIDs = Set<UUID>()

        func pushTask(_ task: TodoTask, kind: HoloTodayAgendaKind, plannedForToday: Bool) {
            let id = task.id
            guard !task.completed, task.deletedAt == nil, !task.archived else { return }
            guard agendaTaskIDs.insert(id).inserted else { return }
            let matterRef = taskMatterLookup[id]
            taskCandidates.append(HoloTodayTaskCandidate(
                id: id,
                title: task.title,
                dueAt: task.dueDate,
                isCompleted: task.completed,
                priority: Int(task.priority),
                plannedForToday: plannedForToday,
                matterID: matterRef?.matterID,
                matterTitle: matterRef?.matterTitle,
                updatedAt: task.updatedAt
            ))
            agendaItems.append(HoloTodayAgendaItem(
                id: "task:\(id.uuidString)",
                kind: kind,
                title: task.title,
                timeAt: task.dueDate,
                isCompleted: task.completed,
                matterTitle: matterRef?.matterTitle,
                action: .openTask(id)
            ))
        }

        for task in overdue { pushTask(task, kind: .taskOverdue, plannedForToday: false) }
        for task in dueToday { pushTask(task, kind: .taskDueToday, plannedForToday: true) }
        for task in unplanned { pushTask(task, kind: .taskRecent, plannedForToday: false) }
        sectionStates[.agenda] = agendaItems.isEmpty && scheduleCandidates.isEmpty ? .empty : .content
        _ = sectionAgendaFailed

        // 日程进 Agenda：进行中 / 90 分钟内开始。
        for schedule in scheduleCandidates {
            let kind: HoloTodayAgendaKind
            if schedule.endAt <= referenceTime { continue }
            if schedule.startAt <= referenceTime {
                kind = .scheduleOngoing
            } else if schedule.startAt.timeIntervalSince(referenceTime) <= Double(HoloTodayFocusResolver.upcomingWindowMinutes * 60) {
                kind = .scheduleUpcoming
            } else {
                continue
            }
            agendaItems.append(HoloTodayAgendaItem(
                id: "schedule:\(schedule.id)",
                kind: kind,
                title: schedule.title,
                timeAt: schedule.startAt,
                isCompleted: false,
                matterTitle: nil,
                action: .openSchedule(schedule.id)
            ))
        }

        // MARK: 日计划（「今天减负」§9.1：读取 + 派生行 + 候选扩展）

        let planRepository = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext)
        let planRead = planRepository.currentPlan(scope: scope)
        var planContext: HoloTodayPlanResolverContext? = nil
        var planProjection = HoloTodayPlanProjection(
            state: .inheritBase, selectionRows: [], constraintRows: [], deferredRows: []
        )

        if case .active(let payload, let headRevisionIDs) = planRead.state,
           payload.selectionMode == .explicit {
            var planTaskIDs = Set(payload.entries.map(\.taskID))
            planTaskIDs.formUnion(payload.deferredTaskIDs)
            let planStepIDs = Set(payload.entries.compactMap { entry -> UUID? in
                if case .existingStep(let stepID, _, _) = entry.goal { return stepID }
                return nil
            })
            let planFacts = planRepository.facts(taskIDs: planTaskIDs, stepIDs: planStepIDs)

            // 选择行（按 entries 顺序；不可见任务不进活跃列表与数量）
            var selectionRows: [HoloTodayPlanSelectionRow] = []
            var orderedSelectable: [UUID] = []
            for entry in payload.entries {
                let state = HoloTodayReliefPolicy.goalState(entry: entry, facts: planFacts)
                if case .excluded = state { continue }
                let task = planFacts.tasks[entry.taskID]
                var stepActionText: String? = nil
                if case .existingStep(let stepID, _, _) = entry.goal {
                    stepActionText = planFacts.steps[stepID]?.actionText
                }
                selectionRows.append(HoloTodayPlanSelectionRow(
                    taskID: entry.taskID,
                    title: task?.title ?? "",
                    goal: entry.goal,
                    goalState: state,
                    dueAt: task?.dueDate,
                    isAllDay: task?.isAllDay ?? false,
                    stepActionText: stepActionText,
                    matterTitle: taskMatterLookup[entry.taskID]?.matterTitle
                ))
                if case .pending = state {
                    orderedSelectable.append(entry.taskID)
                }
            }

            // 放下行（风险确认是否仍有效）
            let deferredRows: [HoloTodayPlanDeferredRow] = payload.deferredTaskIDs.compactMap { taskID in
                guard let task = planFacts.tasks[taskID], task.visible else { return nil }
                let needsAck = HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
                    dueDate: task.dueDate, isAllDay: task.isAllDay, scope: scope
                )
                let ackValid = HoloTodayReliefPolicy.isAcknowledgementValid(
                    taskID: taskID, dueDate: task.dueDate, isAllDay: task.isAllDay, payload: payload
                )
                return HoloTodayPlanDeferredRow(
                    taskID: taskID,
                    title: task.title,
                    dueAt: task.dueDate,
                    isAllDay: task.isAllDay,
                    acknowledgementValid: !needsAck || ackValid
                )
            }
            let acknowledgedDeferred = Set(payload.deferredTaskIDs.filter { taskID in
                HoloTodayReliefPolicy.isAcknowledgementValid(
                    taskID: taskID,
                    dueDate: planFacts.tasks[taskID]?.dueDate,
                    isAllDay: planFacts.tasks[taskID]?.isAllDay ?? false,
                    payload: payload
                )
            })

            // 已选/放下任务必须进入 resolver 候选（未来截止也取到；§9.1）
            let existingCandidateIDs = Set(taskCandidates.map(\.id))
            let planTaskRequest = NSFetchRequest<TodoTask>(entityName: "TodoTask")
            planTaskRequest.predicate = NSPredicate(format: "id IN %@", planTaskIDs)
            if let planTasks = try? CoreDataStack.shared.viewContext.fetch(planTaskRequest) {
                for task in DuplicateRowFilter.deduplicatingCopies(planTasks) {
                    guard !task.completed, task.deletedAt == nil, !task.archived,
                          !existingCandidateIDs.contains(task.id) else { continue }
                    let matterRef = taskMatterLookup[task.id]
                    taskCandidates.append(HoloTodayTaskCandidate(
                        id: task.id,
                        title: task.title,
                        dueAt: task.dueDate,
                        isAllDay: task.isAllDay,
                        isCompleted: task.completed,
                        priority: Int(task.priority),
                        plannedForToday: payload.entries.contains { $0.taskID == task.id },
                        matterID: matterRef?.matterID,
                        matterTitle: matterRef?.matterTitle,
                        updatedAt: task.updatedAt
                    ))
                }
            }

            // 固定约束行：当日全部日程（不只 90 分钟窗）+ 当日计划执行时段 + 到期/逾期事实
            var constraintRows: [HoloTodayPlanConstraintRow] = []
            for schedule in scheduleCandidates {
                constraintRows.append(HoloTodayPlanConstraintRow(
                    id: "schedule:\(schedule.id)",
                    title: schedule.title,
                    kind: .schedule(start: schedule.startAt, end: schedule.endAt, isAllDay: schedule.isAllDay),
                    taskID: nil
                ))
            }
            let segmentRequest = NSFetchRequest<TodoTask>(entityName: "TodoTask")
            segmentRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "plannedStart != nil AND plannedStart >= %@ AND plannedStart < %@", dayStart as NSDate, dayEnd as NSDate),
                NSPredicate(format: "completed == false"),
                NSPredicate(format: "deletedAt == nil"),
                NSPredicate(format: "archived == false"),
            ])
            if let segmentTasks = try? CoreDataStack.shared.viewContext.fetch(segmentRequest) {
                for task in DuplicateRowFilter.deduplicatingCopies(segmentTasks) {
                    if let start = task.plannedStart, let end = task.plannedEnd {
                        constraintRows.append(HoloTodayPlanConstraintRow(
                            id: "segment:\(task.id.uuidString)",
                            title: task.title,
                            kind: .plannedSegment(start: start, end: end),
                            taskID: task.id
                        ))
                    }
                }
            }
            let selectedOrDeferred = planTaskIDs
            for task in overdue + dueToday {
                guard !selectedOrDeferred.contains(task.id) else { continue }
                constraintRows.append(HoloTodayPlanConstraintRow(
                    id: "deadline:\(task.id.uuidString)",
                    title: task.title,
                    kind: .deadline(dueAt: task.dueDate ?? dayEnd, isAllDay: task.isAllDay, isOverdue: (task.dueDate ?? dayEnd) < dayStart),
                    taskID: task.id
                ))
            }
            let selectedSet = Set(payload.entries.map(\.taskID))
            planContext = HoloTodayPlanResolverContext(
                orderedSelectableTaskIDs: orderedSelectable,
                deferredTaskIDs: Set(payload.deferredTaskIDs),
                acknowledgedDeferredTaskIDs: acknowledgedDeferred
            )
            _ = selectedSet
            planProjection = HoloTodayPlanProjection(
                state: .explicit(payload: payload, headRevisionIDs: headRevisionIDs),
                selectionRows: selectionRows,
                constraintRows: constraintRows,
                deferredRows: deferredRows
            )
        } else {
            // conflict / syncing / unavailable：约束事实继续展示，不回退假空态（§8.4）
            switch planRead.state {
            case .conflict(let candidates):
                planProjection = HoloTodayPlanProjection(
                    state: .conflict(candidates: candidates),
                    selectionRows: [], constraintRows: [], deferredRows: []
                )
            case .syncing(let reason):
                planProjection = HoloTodayPlanProjection(
                    state: .syncing(reason: reason),
                    selectionRows: [], constraintRows: [], deferredRows: []
                )
            case .unavailable(let reason):
                planProjection = HoloTodayPlanProjection(
                    state: .unavailable(reason: reason),
                    selectionRows: [], constraintRows: [], deferredRows: []
                )
            case .noPlan, .active:
                break
            }
        }

        // MARK: Focus（唯一 resolver）

        let focusInput = HoloTodayFocusInput(
            referenceTime: referenceTime,
            dayStart: dayStart,
            dayEnd: dayEnd,
            schedules: scheduleCandidates,
            tasks: taskCandidates,
            matters: matterCandidates,
            plan: planContext
        )
        var focus: HoloTodayFocus?
        do {
            focus = HoloTodayFocusResolver.resolve(input: focusInput)
            sectionStates[.focus] = .content
        } catch {
            sectionStates[.focus] = .failed(lastSuccessfulAt: nil)
        }

        // INV-06（全 App 只有一个「当下一步」）：Focus 已占用的任务从 Agenda 移除。
        if case .openTask(let focusTaskID) = focus?.action {
            agendaItems.removeAll { $0.id == "task:\(focusTaskID.uuidString)" }
        }

        // MARK: Matter 列表排序（复用 MatterHomeSurface 确定性排序，最多展示 3 件）

        let surfaceCandidates = matterCandidates.map { candidate in
            MatterHomeSurface.Candidate(
                id: candidate.id,
                title: candidate.title,
                targetDate: candidate.targetDate,
                updatedAt: candidate.updatedAt,
                nextActionTitle: candidate.nextAction?.title,
                nextActionTargetDate: candidate.nextAction?.targetDate,
                loops: candidate.loops.map {
                    HoloMatterAttentionPolicy.LoopInput(
                        id: $0.id, title: $0.title, state: $0.state,
                        epistemic: $0.epistemic, targetDate: $0.targetDate
                    )
                },
                projectionAttention: nil
            )
        }
        let orderedIDs = MatterHomeSurface.select(surfaceCandidates, now: referenceTime).map(\.id)
        var itemsByID = Dictionary(matterItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedMatters = orderedIDs.compactMap { itemsByID.removeValue(forKey: $0) }
        if orderedMatters.indices.contains(0) {
            var updated = orderedMatters
            updated[0] = HoloTodayMatterItem(
                id: updated[0].id, title: updated[0].title,
                attention: updated[0].attention, attentionReason: updated[0].attentionReason,
                summary: updated[0].summary, nextActionTitle: updated[0].nextActionTitle,
                nextAction: updated[0].nextAction, daysUntilTarget: updated[0].daysUntilTarget,
                suggestedCount: updated[0].suggestedCount,
                isFocus: true, cardAction: updated[0].cardAction
            )
            matterItems = updated
        }

        // MARK: 保持状态（习惯 + 健康紧凑）

        let habitRepo = HabitRepository.shared
        let healthRepo = HealthRepository.shared
        let visibleHabitIDs = HabitStatsDisplaySettings.shared.dashboardVisibleHabitIds
        let activeHabits = habitRepo.activeHabits.filter { !$0.isArchived }
        var habitRows: [HoloTodayHabitRow] = []
        var habitCompleted = 0
        var habitTotal = 0
        for habit in activeHabits {
            let isDone = habitRepo.isTodayCompleted(for: habit)
            let displayList = visibleHabitIDs
            if !displayList.isEmpty && habit.isCheckInType && !displayList.contains(habit.id) { continue }
            if habit.isCheckInType {
                habitTotal += habit.isBadHabit ? 0 : 1
                if isDone && !habit.isBadHabit { habitCompleted += 1 }
                if !isDone {
                    habitRows.append(HoloTodayHabitRow(
                        id: habit.id, name: habit.name, isDone: false,
                        isNegative: habit.isBadHabit, isMeasurable: false, progressText: nil
                    ))
                }
            } else if habit.isMeasureType {
                let value = habitRepo.getTodayValue(for: habit)
                let target = habit.targetValue?.doubleValue
                if target != nil && !habit.isBadHabit {
                    habitTotal += 1
                    if let value, let target, value >= target { habitCompleted += 1 }
                }
                if value == nil {
                    habitRows.append(HoloTodayHabitRow(
                        id: habit.id, name: habit.name, isDone: false,
                        isNegative: habit.isBadHabit, isMeasurable: true,
                        progressText: target.map { "0/\(Int($0))\(habit.unitText)" }
                    ))
                }
            }
        }
        let routine = HoloTodayRoutineSummary(
            habitCompleted: habitCompleted,
            habitTotal: habitTotal,
            habitRows: habitRows,
            sleepHours: healthRepo.todaySleep > 0 ? healthRepo.todaySleep : nil,
            steps: healthRepo.todaySteps > 0 ? Int(healthRepo.todaySteps) : nil,
            healthAuthorized: healthRepo.isAuthorized,
            hasHealthData: healthRepo.todaySteps > 0 || healthRepo.todaySleep > 0
        )
        sectionStates[.routine] = .content

        // MARK: 今日概况（预算 + 支出）

        var overview = HoloTodayOverview.unavailable
        do {
            let budgetSummary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
            let calendar2 = Calendar.current
            let start = calendar2.startOfDay(for: referenceTime)
            let end = calendar2.date(byAdding: .day, value: 1, to: start) ?? start
            let transactions = try await FinanceRepository.shared.getStatisticsTransactions(from: start, to: end)
            let spent = transactions
                .filter { $0.statisticsType == .expense }
                .reduce(Decimal.zero) { $0 + $1.statisticsAmount }
            overview = HoloTodayOverview(
                spentToday: spent,
                budgetAtRisk: budgetSummary?.isOverBudget == true,
                budgetConfigured: budgetSummary != nil
            )
            sectionStates[.overview] = .content
        } catch {
            // 支出取数失败：spentToday 保持 nil（显示 --，不误报 ¥0）。
            overview = HoloTodayOverview(
                spentToday: nil,
                budgetAtRisk: BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)?.isOverBudget == true,
                budgetConfigured: BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month) != nil
            )
            sectionStates[.overview] = .content
        }

        let failedCount = sectionStates.values.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        let freshness: HoloTodayFreshness = failedCount == 0 ? .fresh : (failedCount == HoloTodaySection.allCases.count ? .stale : .partial)

        return HoloTodaySnapshot(
            referenceTime: referenceTime,
            dayStart: dayStart,
            dayEnd: dayEnd,
            timeZoneIdentifier: TimeZone.current.identifier,
            generatedAt: Date(),
            freshness: freshness,
            primaryFocus: focus,
            matters: Array(matterItems.prefix(3)),
            agenda: agendaItems,
            routine: routine,
            overview: overview,
            sectionStates: sectionStates,
            plan: planProjection,
            focusInput: focusInput
        )
    }

    /// 投影 nextAction → Today 动作（与 MatterDetailView 同一解析语义）。
    private static func nextActionAction(
        from next: HoloMatterNextAction?,
        isFresh: Bool,
        matterID: UUID
    ) -> HoloTodayAction? {
        guard isFresh, let next else { return nil }
        switch next.kind {
        case .linkedTask:
            guard let id = next.entityID.flatMap(UUID.init(uuidString:)) else { return nil }
            return .openTask(id)
        case .openLoopAction:
            guard let id = next.entityID.flatMap(UUID.init(uuidString:)) else {
                // 无 loop ID：只能讨论（禁止标题匹配）。
                return nil
            }
            return .createTaskFromOpenLoop(matterID: matterID, openLoopID: id)
        case .suggestion:
            // 建议不作为可执行动作展示。
            return nil
        }
    }
}