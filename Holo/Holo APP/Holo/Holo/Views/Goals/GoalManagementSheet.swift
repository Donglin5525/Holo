//
//  GoalManagementSheet.swift
//  Holo
//
//  目标管理弹窗（HoloSheetScaffold + HoloSettingsSection 家族）
//  承载：置顶「今天」、HoloAI 开关、编辑/高级规则入口、生命周期操作与删除。
//

import SwiftUI
import CoreData

struct GoalManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var repository = GoalRepository.shared
    @ObservedObject var goal: Goal
    @AppStorage("holo.today.focusGoalID") private var focusGoalID = ""

    let workshopEnabled: Bool
    let onEditGoal: () -> Void
    let onOpenPlanEditor: () -> Void
    let onOpenWorkshopAdvice: () -> Void
    /// 删除确认（第二参 = 是否连带删除目标创建的习惯/任务）
    let onDeleteConfirmed: (UUID, Bool) -> Void

    @State private var showDeleteConfirm = false
    @State private var operationError: String?

    var body: some View {
        if goal.managedObjectContext == nil || goal.isDeleted || goal.deletedAt != nil {
            EmptyView()
        } else {
        HoloSheetScaffold(
            title: String(localized: "目标管理"),
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    HoloSettingsSection(title: String(localized: "展示与协助")) {
                        if goal.goalStatus == .active {
                            HoloSettingsRow(
                                icon: "pin.fill",
                                iconColor: GoalJourneyStyle.action,
                                title: String(localized: "在「今天」置顶")
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { focusGoalID == goal.id.uuidString },
                                    set: { enabled in
                                        focusGoalID = enabled ? goal.id.uuidString : ""
                                        NotificationCenter.default.post(name: .goalDataDidChange, object: goal.id)
                                        HapticManager.light()
                                    }
                                ))
                                .labelsHidden()
                                .tint(GoalJourneyStyle.action)
                                .accessibilityIdentifier("goal-today-focus-toggle")
                            }
                            rowDivider
                        }

                        HoloSettingsRow(
                            icon: "sparkles",
                            iconColor: .holoAI,
                            title: String(localized: "允许 HoloAI 参考")
                        ) {
                            Toggle("", isOn: Binding(
                                get: { goal.allowAIContext },
                                set: { newValue in
                                    perform { try repository.updateAIContext(goal, allow: newValue) }
                                }
                            ))
                            .labelsHidden()
                            .tint(GoalJourneyStyle.action)
                        }

                        rowDivider

                        HoloSettingsRow(
                            icon: "bell.badge.fill",
                            iconColor: GoalJourneyStyle.action,
                            title: String(localized: "主动进度提醒"),
                            subtitle: goal.allowAIContext ? nil : String(localized: "需先开启「允许 HoloAI 参考」")
                        ) {
                            Toggle("", isOn: Binding(
                                get: { goal.allowAIContext && goal.proactiveNudge },
                                set: { newValue in
                                    perform { try repository.updateProactiveNudge(goal, enabled: newValue) }
                                }
                            ))
                            .labelsHidden()
                            .tint(GoalJourneyStyle.action)
                            .disabled(!goal.allowAIContext)
                        }
                    }

                    HoloSettingsSection(title: String(localized: "调整与状态")) {
                        Button(action: onEditGoal) {
                            HoloSettingsRow(
                                icon: "pencil",
                                iconColor: GoalJourneyStyle.action,
                                title: String(localized: "编辑目标内容、目标值与期限")
                            ) {
                                HoloSettingsChevron()
                            }
                        }
                        .buttonStyle(.plain)

                        rowDivider

                        Button(action: onOpenPlanEditor) {
                            HoloSettingsRow(
                                icon: "slider.horizontal.3",
                                iconColor: .holoToolTextSecondary,
                                title: String(localized: "周期与高级规则")
                            ) {
                                HoloSettingsChevron()
                            }
                        }
                        .buttonStyle(.plain)

                        if workshopEnabled {
                            rowDivider
                            Button(action: onOpenWorkshopAdvice) {
                                HoloSettingsRow(
                                    icon: "lightbulb.fill",
                                    iconColor: .holoAI,
                                    title: String(localized: "让 Holo 给调整建议")
                                ) {
                                    HoloSettingsChevron()
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        rowDivider

                        if goal.goalStatus == .active {
                            Button {
                                perform { try repository.updateStatus(goal, status: .paused) }
                            } label: {
                                HoloSettingsRow(
                                    icon: "pause.circle",
                                    iconColor: .holoToolTextSecondary,
                                    title: String(localized: "暂停目标")
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                perform { try repository.updateStatus(goal, status: .active) }
                            } label: {
                                HoloSettingsRow(
                                    icon: "play.circle.fill",
                                    iconColor: GoalJourneyStyle.action,
                                    title: String(localized: "恢复为进行中")
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if goal.goalStatus != .completed {
                            rowDivider
                            Button {
                                perform { try repository.updateStatus(goal, status: .completed) }
                                dismiss()
                            } label: {
                                HoloSettingsRow(
                                    icon: "checkmark.circle.fill",
                                    iconColor: .holoToolSuccess,
                                    title: String(localized: "标记为已完成"),
                                    titleColor: .holoToolSuccess
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HoloSettingsSection(title: nil) {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HoloSettingsRow(
                                icon: "trash",
                                iconColor: .holoToolError,
                                title: String(localized: "删除目标"),
                                titleColor: .holoToolError
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .presentationDetents([.height(580), .large])
        .confirmationDialog("删除目标", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            if !ownedImpact.isEmpty {
                Button("删除目标及其创建的习惯和任务", role: .destructive) {
                    confirmDelete(cascading: true)
                }
                Button("仅删除目标", role: .destructive) {
                    confirmDelete(cascading: false)
                }
            } else {
                Button("删除目标", role: .destructive) {
                    confirmDelete(cascading: false)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if !ownedImpact.isEmpty {
                Text("这个目标创建了\(ownedImpact.summaryText)。选「删除目标及其创建的习惯和任务」时：习惯及其全部记录将被永久删除，无法恢复；任务进入回收站，30 天内可恢复。只是手动关联的旧习惯和任务会保留，仅解除关联。")
            } else {
                Text("删除目标后，任务和习惯会保留，仅解除关联。")
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.holoToolBorder.opacity(0.6))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    /// 弹确认框时现算：这个目标「创建」了哪些习惯/任务（复用挂进来的不算）
    private var ownedImpact: GoalRepository.OwnedEntityImpact {
        repository.ownedEntityImpact(of: goal)
    }

    /// 先收管理弹窗，转场落定后再执行删除（沿用原节拍，避免叠转场）
    private func confirmDelete(cascading: Bool) {
        let id = goal.id
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDeleteConfirmed(id, cascading)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            GoalNotificationService.broadcastGoalDataChange()
        } catch {
            operationError = error.localizedDescription
        }
    }
}
