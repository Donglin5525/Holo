//
//  GoalPickerSheet.swift
//  Holo
//
//  归属目标单选器：从任务/习惯详情页改归属目标（含「无归属」）
//

import SwiftUI

struct GoalPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 当前归属目标 ID（决定哪行打勾；「无归属」行据此显示移除语义）
    let currentGoalId: UUID?
    /// 选中目标回调；nil 表示「无归属」（移除当前关联）
    let onSelect: (Goal?) -> Void

    @State private var goals: [Goal] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(goals, id: \.id) { goal in
                    Button {
                        onSelect(goal)
                        dismiss()
                    } label: {
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: goal.goalDomain.icon)
                                .foregroundColor(.holoPrimary)
                                .frame(width: 22)
                            Text(goal.title)
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(1)
                            Spacer()
                            if goal.id == currentGoalId {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                    }
                }

                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label("无归属", systemImage: "square.dashed")
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .listStyle(.plain)
            .navigationTitle("选择目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear {
            // goals 只在目标列表页加载，从任务/习惯侧进入时需主动刷新
            GoalRepository.shared.loadGoals()
            goals = GoalRepository.shared.goals.filter { $0.goalStatus == .active }
        }
    }
}
