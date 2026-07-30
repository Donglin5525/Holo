//
//  GoalDetailView.swift
//  Holo
//
//  目标详情视图：状态操作、关联任务/习惯、AI 授权开关
//

import SwiftUI

struct GoalDetailView: View {
    @ObservedObject private var repository = GoalRepository.shared
    @ObservedObject var goal: Goal
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    let onDeleteRequested: (UUID) -> Void
    @State private var showDeleteConfirm = false
    @State private var operationError: String?

    init(
        goal: Goal,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        onDeleteRequested: @escaping (UUID) -> Void = { _ in }
    ) {
        self.goal = goal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self.onDeleteRequested = onDeleteRequested
    }

    var body: some View {
        let progress = GoalProgressEvaluator.evaluate(goal: goal)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                header(progress)
                aiContextToggle
                taskSection
                habitSection
                actionSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle("目标详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除目标", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除目标", role: .destructive) {
                onDeleteRequested(goal.id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。")
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

    private func header(_ progress: GoalProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(goal.title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            if let summary = goal.summary, !summary.isEmpty {
                Text(summary)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            Text("\(progress.state.displayName) · \(progress.taskSummary) · \(progress.habitSummary)")
                .font(.system(size: 13))
                .foregroundColor(.holoPrimary)
        }
    }

    private var aiContextToggle: some View {
        Toggle("允许 HoloAI 后续参考此目标", isOn: Binding(
            get: { goal.allowAIContext },
            set: { newValue in
                perform {
                    try repository.updateAIContext(goal, allow: newValue)
                }
            }
        ))
        .font(.holoBody)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("关联任务").font(.holoBody).fontWeight(.semibold)
            if goal.sortedTasks.isEmpty {
                Text("暂无关联任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedTasks, id: \.id) { task in
                    linkedEntityRow(title: task.title, icon: "checklist") {
                        onOpenLinkedEntity(.taskDetail(taskId: task.id))
                    }
                }
            }
        }
    }

    private var habitSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("关联习惯").font(.holoBody).fontWeight(.semibold)
            if goal.sortedHabits.isEmpty {
                Text("暂无关联习惯")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                ForEach(goal.sortedHabits, id: \.id) { habit in
                    linkedEntityRow(title: habit.name, icon: "checkmark.circle") {
                        onOpenLinkedEntity(.habitDetail(habitId: habit.id))
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            if goal.goalStatus == .active {
                Button("暂停目标") {
                    perform { try repository.updateStatus(goal, status: .paused) }
                }
            } else if goal.goalStatus == .paused {
                Button("恢复目标") {
                    perform { try repository.updateStatus(goal, status: .active) }
                }
            }
            if goal.goalStatus != .completed {
                Button("标记完成") {
                    perform { try repository.updateStatus(goal, status: .completed) }
                }
            }
            Button("删除目标", role: .destructive) { showDeleteConfirm = true }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkedEntityRow(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(.holoPrimary)
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            operationError = error.localizedDescription
        }
    }
}
