//
//  GoalDetailView.swift
//  Holo
//
//  目标详情视图：Hero 进度闭环 + 分段查看 + 统一编辑与轻量「目标管理」入口
//

import SwiftUI
import CoreData

private enum GoalDetailSheetRoute: Identifiable {
    case edit
    case management
    case quickTask
    case newHabit
    case linkExisting
    case planEditor
    case workshopAdvice(GoalWorkshopLaunch)

    var id: String {
        switch self {
        case .edit: return "edit"
        case .management: return "management"
        case .quickTask: return "quickTask"
        case .newHabit: return "newHabit"
        case .linkExisting: return "linkExisting"
        case .planEditor: return "planEditor"
        case .workshopAdvice(let launch): return "workshop-\(launch.id)"
        }
    }
}

struct GoalDetailView: View {
    @ObservedObject var goal: Goal
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    /// 删除确认回调（第二参 = 是否连带删除目标创建的习惯/任务）
    let onDeleteRequested: (UUID, Bool) -> Void

    @State private var workshopEnabled = HoloAIFeatureFlags.goalWorkshopEnabled
    @State private var closedLoopEnabled = HoloAIFeatureFlags.goalClosedLoopEnabled
    @State private var activeSheet: GoalDetailSheetRoute?
    @State private var pendingSheet: GoalDetailSheetRoute?
    @State private var showAchievementCelebration = false

    init(
        goal: Goal,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        onDeleteRequested: @escaping (UUID, Bool) -> Void = { _, _ in }
    ) {
        self.goal = goal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self.onDeleteRequested = onDeleteRequested
    }

    var body: some View {
        if goal.managedObjectContext == nil || goal.isDeleted || goal.deletedAt != nil {
            Text("这个目标已删除")
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolTextSecondary)
        } else {
            ScrollView(showsIndicators: false) {
                GoalProgressScrollSection(
                    goal: goal,
                    closedLoopEnabled: closedLoopEnabled,
                    onOpenLinkedEntity: onOpenLinkedEntity,
                    onNewTask: { activeSheet = .quickTask },
                    onNewHabit: { activeSheet = .newHabit },
                    onLinkExisting: { activeSheet = .linkExisting },
                    onOpenPlanEditor: { activeSheet = .planEditor }
                )
                .padding(.horizontal, GoalJourneyStyle.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("目标详情")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .tint(GoalJourneyStyle.action)
            .toolbar {
                ToolbarItemGroup(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button("编辑") { activeSheet = .edit }
                        .accessibilityIdentifier("goal-detail-edit")
                    Button { activeSheet = .management } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("目标管理")
                    .accessibilityIdentifier("goal-detail-manage")
                }
            }
            .sheet(item: $activeSheet, onDismiss: {
                if let next = pendingSheet {
                    pendingSheet = nil
                    activeSheet = next
                }
            }) { route in
                sheetContent(for: route)
            }
            .onReceive(NotificationCenter.default.publisher(for: .holoServerFlagsDidUpdate)) { _ in
                workshopEnabled = HoloAIFeatureFlags.goalWorkshopEnabled
                closedLoopEnabled = HoloAIFeatureFlags.goalClosedLoopEnabled
            }
            .task(id: goal.id) {
                if goal.metricSourceEnum == .healthKit {
                    await GoalHealthKitCache.shared.refreshIfNeeded(for: goal)
                }
                checkAchievementCelebrationIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in
                checkAchievementCelebrationIfNeeded()
            }
            .sheet(isPresented: $showAchievementCelebration) {
                GoalAchievementCelebrationSheet(
                    goal: goal,
                    onMarkCompleted: {
                        try? GoalRepository.shared.updateStatus(goal, status: .completed)
                        GoalNotificationService.broadcastGoalDataChange()
                        showAchievementCelebration = false
                    },
                    onKeepActive: {
                        showAchievementCelebration = false
                    }
                )
            }
        }
    }

    private func checkAchievementCelebrationIfNeeded() {
        guard goal.goalStatus == .active,
              goal.isQuantitative,
              let metric = GoalMetricEvaluator.evaluate(goal: goal),
              metric.isAchieved else {
            return
        }
        let key = "holo.goal.celebrated.\(goal.id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showAchievementCelebration = true
    }

    @ViewBuilder
    private func sheetContent(for route: GoalDetailSheetRoute) -> some View {
        switch route {
        case .edit:
            GoalEditSheet(goal: goal) {
                activeSheet = nil
            }
        case .management:
            GoalManagementSheet(
                goal: goal,
                workshopEnabled: workshopEnabled,
                onEditGoal: { switchSheet(to: .edit) },
                onOpenPlanEditor: { switchSheet(to: .planEditor) },
                onOpenWorkshopAdvice: {
                    switchSheet(to: .workshopAdvice(.existingGoalAdvice(goalID: goal.id, goalTitle: goal.title)))
                },
                onDeleteConfirmed: onDeleteRequested
            )
        case .quickTask:
            GoalQuickTaskSheet(goal: goal)
        case .newHabit:
            AddHabitSheet(prefill: HabitPrefillDraft(goalId: goal.id))
        case .linkExisting:
            GoalLinkManagerSheet(goal: goal)
        case .planEditor:
            GoalPlanEditorSheet(goal: goal)
        case .workshopAdvice(let launch):
            GoalWorkshopFlowView(launch: launch)
        }
    }

    /// 先关闭当前弹窗，在 onDismiss 完成后再弹出目标弹窗，避免 SwiftUI 并发 presentation 冲突
    private func switchSheet(to next: GoalDetailSheetRoute) {
        pendingSheet = next
        activeSheet = nil
    }
}

// MARK: - 统一编辑目标 Sheet

struct GoalEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal
    @State private var draft: GoalDraft
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var criteriaConfirmed = false
    /// 是否存在活跃账本账户（红队 U1）：无账户时账本源不可保存；
    /// 与 GoalEditForm.loadAccounts 同源，onAppear 取一次不在 body 里反复 fetch
    @State private var hasActiveLedgerAccounts = true
    private let baseRevisionID: UUID?
    let onSaved: () -> Void

    init(goal: Goal, onSaved: @escaping () -> Void) {
        self.goal = goal
        self.baseRevisionID = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: CoreDataStack.shared.viewContext)?.id
        self.onSaved = onSaved
        self._draft = State(initialValue: GoalEditForm.draft(from: goal))
    }

    private var canSave: Bool {
        !isSaving
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts)
            && (!criteriaChanged || criteriaConfirmed)
    }

    private var criteriaChanged: Bool {
        let before = GoalEditForm.draft(from: goal)
        return draft.desiredOutcome != before.desiredOutcome || draft.deadlineText != before.deadlineText
            || draft.goalKind != before.goalKind || draft.metricTargetValue != before.metricTargetValue
            || draft.metricSource != before.metricSource || draft.sourceHabitId != before.sourceHabitId
            || draft.ledgerScope != before.ledgerScope
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "编辑目标"),
            onClose: { dismiss() },
            primaryTitle: isSaving ? String(localized: "保存中") : String(localized: "保存"),
            primaryAction: { save() },
            primaryDisabled: !canSave,
            primaryHint: isSaving ? nil : GoalEditForm.disabledHint(
                for: draft,
                hasActiveLedgerAccounts: hasActiveLedgerAccounts,
                criteriaUnconfirmed: criteriaChanged && !criteriaConfirmed
            ),
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream,
            primaryAccessory: {
                if criteriaChanged {
                    Toggle("我确认修改成功条件、来源或期限", isOn: $criteriaConfirmed)
                        .holoText(.supporting)
                }
            }
        ) {
            ScrollView(showsIndicators: false) {
                GoalEditForm(draft: $draft, showsExtendedFields: true)
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            hasActiveLedgerAccounts = !FinanceRepository.shared.getAccounts().isEmpty
        }
        .presentationDetents([.large])
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                let parsedDeadline: Date?? = {
                    guard let text = draft.deadlineText, !text.isEmpty else { return .some(nil) }
                    return .some(GoalEditForm.parseDeadlineText(text))
                }()
                try GoalRepository.shared.updateFields(
                    goal,
                    title: draft.title,
                    summary: draft.summary,
                    domain: draft.domain,
                    iconEmoji: draft.iconEmoji,
                    desiredOutcome: draft.desiredOutcome,
                    motivation: draft.motivation,
                    deadline: parsedDeadline,
                    goalKind: draft.goalKind,
                    metricUnit: draft.isQuantitative ? .some(draft.metricUnit) : nil,
                    metricTargetValue: draft.isQuantitative ? .some(draft.metricTargetValue) : nil,
                    metricBaselineValue: (draft.isQuantitative && draft.goalKind == .target)
                        ? .some(draft.metricBaselineValue) : nil,
                    metricSource: draft.isQuantitative ? draft.metricSource : nil,
                    sourceHabitId: draft.isQuantitative
                        ? .some(draft.metricSource == .habit ? draft.sourceHabitId : nil) : nil,
                    ledgerScope: draft.isQuantitative
                        ? .some(draft.metricSource == .ledger ? draft.ledgerScope : nil) : nil,
                    expectedPlanRevisionID: baseRevisionID
                )
                isSaving = false
                GoalNotificationService.broadcastGoalDataChange()
                HapticManager.success()
                onSaved()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - 目标达成庆祝弹窗（成果回顾 + 一键结项归档）

private struct GoalAchievementCelebrationSheet: View {
    let goal: Goal
    let onMarkCompleted: () -> Void
    let onKeepActive: () -> Void

    private var elapsedDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: goal.createdAt, to: Date()).day ?? 1)
    }

    private var completedTaskCount: Int {
        goal.sortedTasks.filter(\.completed).count
    }

    private var linkedHabitCount: Int {
        goal.sortedHabits.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.xl) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(GoalJourneyStyle.action.opacity(0.12))
                        .frame(width: 96, height: 96)
                    Text(goal.displayIcon)
                        .font(.system(size: 46))
                }

                VStack(spacing: HoloSpacing.sm) {
                    Text("目标达成")
                        .font(.holoTitle)
                        .foregroundColor(.holoToolText)
                    Text("「\(goal.title)」已经达成你的设定目标")
                        .font(.holoBody)
                        .foregroundColor(.holoToolTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: HoloSpacing.md) {
                    statTile(title: String(localized: "坚持天数"), value: "\(elapsedDays) 天")
                    statTile(title: String(localized: "完成任务"), value: "\(completedTaskCount) 项")
                    statTile(title: String(localized: "关联习惯"), value: "\(linkedHabitCount) 个")
                }
                .padding(.horizontal, HoloSpacing.md)

                Spacer()

                VStack(spacing: HoloSpacing.sm) {
                    Button(action: onMarkCompleted) {
                        Text("标记为已完成")
                            .font(.holoBody)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(GoalJourneyStyle.action)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }

                    Button(action: onKeepActive) {
                        Text("继续保持进行中")
                            .font(.holoCaption)
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.lg)
            }
            .background(Color.holoToolBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}
