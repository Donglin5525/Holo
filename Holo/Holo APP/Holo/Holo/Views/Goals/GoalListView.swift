//
//  GoalListView.swift
//  Holo
//
//  「我的目标」列表视图
//

import SwiftUI

struct GoalListView: View {
    @ObservedObject private var repository = GoalRepository.shared
    let onPlanGoal: () -> Void
    @Binding var pendingGoalDetailId: UUID?
    @State private var selectedGoalRoute: GoalDetailRoute?

    init(
        onPlanGoal: @escaping () -> Void,
        pendingGoalDetailId: Binding<UUID?> = .constant(nil)
    ) {
        self.onPlanGoal = onPlanGoal
        self._pendingGoalDetailId = pendingGoalDetailId
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                if repository.goals.isEmpty {
                    emptyState
                } else {
                    ForEach(repository.goals, id: \.id) { goal in
                        NavigationLink {
                            GoalDetailView(goal: goal)
                        } label: {
                            goalRow(goal)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle("我的目标")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedGoalRoute) { route in
            if let goal = repository.findGoal(by: route.id) {
                GoalDetailView(goal: goal)
            } else {
                Text("目标不存在或已被删除")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .onAppear {
            repository.loadGoals()
            openPendingGoalIfNeeded()
        }
        .onChange(of: pendingGoalDetailId) { _, _ in
            openPendingGoalIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundColor(.holoPrimary)
            Text("还没有目标")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            Text("让 HoloAI 帮你把想法拆成任务和习惯")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            Button {
                onPlanGoal()
            } label: {
                Text("让 HoloAI 规划目标")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.holoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func goalRow(_ goal: Goal) -> some View {
        let progress = GoalProgressEvaluator.evaluate(goal: goal)
        return HStack(spacing: HoloSpacing.md) {
            Image(systemName: goal.goalDomain.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 40, height: 40)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title)
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                Text("\(progress.state.displayName) · \(progress.taskSummary) · \(progress.habitSummary)")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func openPendingGoalIfNeeded() {
        guard let goalId = pendingGoalDetailId else { return }
        selectedGoalRoute = GoalDetailRoute(id: goalId)
        pendingGoalDetailId = nil
    }
}

private struct GoalDetailRoute: Identifiable, Hashable {
    let id: UUID
}
