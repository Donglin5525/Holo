//
//  TaskQuadrantExpandedSheet.swift
//  Holo
//
//  单格完整列表（多视图方案 §6.4）：象限名 + 语义/范围/数量副标题 + 右上新增；
//  连续完整任务列表复用 TaskExperienceRow（子任务、分类、时间、Today、完成）。
//  任务移出当前格该行自然消失；最后一项移走显示空态，sheet 不突然关闭。
//

import SwiftUI

/// 任务行动作句柄：多视图各 surface 共用同一套行回调（由 TaskExperienceView 组装）
struct TaskRowActionHandlers {
    let onToggleCompletion: (TaskRecordSnapshot) -> Void
    let onOpenDetail: (TaskRecordSnapshot) -> Void
    let onClassify: (TaskRecordSnapshot) -> Void
    let onChangeDue: (TaskRecordSnapshot) -> Void
    let onPlanRange: (TaskRecordSnapshot) -> Void
    let onToggleToday: (TaskRecordSnapshot) -> Void
    let onArchive: (TaskRecordSnapshot) -> Void
    let onDelete: (TaskRecordSnapshot) -> Void
    let onToggleCheckItem: (TaskRecordSnapshot, CheckItemSnapshot) -> Void
    let onAddCheckItem: (TaskRecordSnapshot, String) -> Bool
}

struct TaskQuadrantExpandedSheet: View {

    let quadrant: TaskQuadrant
    @ObservedObject var model: TaskExperienceViewModel
    let repository: TodoRepository
    let actions: TaskRowActionHandlers
    let onCreateInQuadrant: (TaskQuadrant) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    init(
        quadrant: TaskQuadrant,
        model: TaskExperienceViewModel,
        repository: TodoRepository,
        actions: TaskRowActionHandlers,
        onCreateInQuadrant: @escaping (TaskQuadrant) -> Void
    ) {
        self.quadrant = quadrant
        self.model = model
        self.repository = repository
        self.actions = actions
        self.onCreateInQuadrant = onCreateInQuadrant
    }

    // 兼容旧签名（无行动作时仅展示）——board 直接传外层句柄
    init(
        quadrant: TaskQuadrant,
        model: TaskExperienceViewModel,
        repository: TodoRepository,
        onOpenDetail: @escaping (UUID) -> Void,
        onCreateInQuadrant: @escaping (TaskQuadrant) -> Void
    ) {
        self.init(
            quadrant: quadrant,
            model: model,
            repository: repository,
            actions: TaskRowActionHandlers(
                onToggleCompletion: { _ in },
                onOpenDetail: { onOpenDetail($0.id) },
                onClassify: { _ in },
                onChangeDue: { _ in },
                onPlanRange: { _ in },
                onToggleToday: { _ in },
                onArchive: { _ in },
                onDelete: { _ in },
                onToggleCheckItem: { _, _ in },
                onAddCheckItem: { _, _ in false }
            ),
            onCreateInQuadrant: onCreateInQuadrant
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                VStack(spacing: 0) {
                    Text(subtitleText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HoloSpacing.page)
                        .padding(.top, HoloSpacing.sm)
                        .padding(.bottom, HoloSpacing.xs)
                    if members.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(members) { member in
                                    row(member)
                                    if member.id != members.last?.id {
                                        Rectangle()
                                            .fill(Color.holoDivider.opacity(0.5))
                                            .frame(height: 0.5)
                                            .padding(.leading, TaskExperienceRowLayout.textInset)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .padding(.horizontal, HoloSpacing.page)
                            .padding(.bottom, 100)
                        }
                    }
                }
            }
            .background(Color.holoBackground)
            .navigationTitle(quadrant.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onCreateInQuadrant(quadrant)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 44, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "在\(quadrant.displayTitle)中新增任务"))
                }
            }
            // 弹层会盖住主页面的撤回 banner：pending 期间在弹层内就地显示撤回条（§8）
            .overlay(alignment: .bottom) {
                if completionCoordinator.pending != nil {
                    HoloUndoToast(
                        message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                        onUndo: {
                            completionCoordinator.undo(in: repository)
                            HapticManager.light()
                        }
                    )
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// 当前格成员（每次 body 重算：移出后行消失、数量同步）
    private var members: [TaskRecordSnapshot] {
        model.groupedMembers.first { $0.quadrant == quadrant }?.members ?? []
    }

    private var subtitleText: String {
        "\(quadrant.subtitleText) · \(model.scopeTitle) · \(members.count)项"
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Text("这个象限暂无任务")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Button {
                onCreateInQuadrant(quadrant)
            } label: {
                Text("在此添加任务")
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ member: TaskRecordSnapshot) -> some View {
        TaskExperienceRow(
            member: member,
            calendar: model.calendar,
            now: model.now,
            isCompleting: model.pendingCompletionTaskID == member.id,
            isCompleted: member.completed,
            isInTodayPlan: model.todayEntryIDs.contains(member.id),
            onToggleCompletion: { actions.onToggleCompletion(member) },
            onOpenDetail: { actions.onOpenDetail(member) },
            onClassify: { actions.onClassify(member) },
            onChangeDue: { actions.onChangeDue(member) },
            onPlanRange: { actions.onPlanRange(member) },
            onToggleToday: { actions.onToggleToday(member) },
            onArchive: { actions.onArchive(member) },
            onDelete: { actions.onDelete(member) },
            onToggleCheckItem: { actions.onToggleCheckItem(member, $0) },
            onAddCheckItem: { actions.onAddCheckItem(member, $0) }
        )
        .id("task-\(member.id.uuidString)")
    }
}
