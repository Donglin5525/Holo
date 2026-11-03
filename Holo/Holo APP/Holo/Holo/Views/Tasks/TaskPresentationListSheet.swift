//
//  TaskPresentationListSheet.swift
//  Holo
//
//  多视图通用任务列表 sheet（多视图方案 §5.3/§5.2-8）：待安排、逾期、冲突组、
//  单格完整列表共用；每项可详情、安排时间、完成；复用 TaskExperienceRow。
//

import SwiftUI

struct TaskPresentationListSheet: View {

    let title: String
    let members: [TaskRecordSnapshot]
    @ObservedObject var model: TaskExperienceViewModel
    let actions: TaskRowActionHandlers
    /// 撤回动作（传 nil 的入口无完成操作，不显示撤回条）
    var onUndoCompletion: (() -> Void)? = nil
    /// 标题下的一行说明（待安排/逾期各有固定文案）
    var footnote: String? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    var body: some View {
        NavigationStack {
            Group {
                if members.isEmpty {
                    VStack(spacing: HoloSpacing.md) {
                        Text("这里暂时没有任务")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Text("可以继续查看其他日期或范围。")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if let footnote {
                                Text(footnote)
                                    .font(.system(size: 12))
                                    .foregroundColor(.holoTextSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, HoloSpacing.xs)
                            }
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
                        .padding(.top, HoloSpacing.xs)
                        .padding(.bottom, 100)
                    }
                }
            }
            .background(Color.holoBackground)
            .navigationTitle(title)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
            // 弹层会盖住主页面的撤回 banner：pending 期间在弹层内就地显示撤回条（§8）
            .overlay(alignment: .bottom) {
                if completionCoordinator.pending != nil, let onUndoCompletion {
                    HoloUndoToast(
                        message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                        onUndo: onUndoCompletion
                    )
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
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
