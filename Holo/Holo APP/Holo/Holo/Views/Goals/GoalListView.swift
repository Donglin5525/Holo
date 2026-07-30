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
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    @Binding var pendingGoalDetailId: UUID?
    @State private var selectedGoalRoute: GoalDetailRoute?
    @State private var operationError: String?

    /// 是否已完成首次加载（避免冷启动时空态先闪现、再被真实列表替换）
    @State private var hasLoadedOnce = false

    init(
        onPlanGoal: @escaping () -> Void,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        pendingGoalDetailId: Binding<UUID?> = .constant(nil)
    ) {
        self.onPlanGoal = onPlanGoal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self._pendingGoalDetailId = pendingGoalDetailId
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                if !hasLoadedOnce {
                    // 首次加载前显示轻量占位，避免空态闪现
                    ProgressView()
                        .padding(.top, 80)
                } else if repository.goals.isEmpty {
                    emptyState
                } else {
                    ForEach(repository.goals, id: \.id) { goal in
                        Button {
                            selectedGoalRoute = GoalDetailRoute(id: goal.id)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onPlanGoal()
                } label: {
                    Label("规划目标", systemImage: "plus")
                }
                .accessibilityLabel("规划新目标")
            }
        }
        .navigationDestination(item: $selectedGoalRoute) { route in
            if let goal = repository.findGoal(by: route.id) {
                GoalDetailView(
                    goal: goal,
                    onOpenLinkedEntity: onOpenLinkedEntity,
                    onDeleteRequested: requestDelete
                )
            } else {
                Text("目标不存在或已被删除")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .onAppear {
            // Core Data 未就绪时 fetch 静默返回空，首次加载交给 .task 等就绪后执行
            guard CoreDataStack.shared.isReady else {
                openPendingGoalIfNeeded()
                return
            }
            repository.loadGoals()
            hasLoadedOnce = true
            openPendingGoalIfNeeded()
        }
        .task {
            // 等 Core Data 就绪后再加载，避免入场时空态闪现
            await CoreDataStack.shared.waitUntilReady()
            repository.loadGoals()
            hasLoadedOnce = true
        }
        .onChange(of: pendingGoalDetailId) { _, _ in
            openPendingGoalIfNeeded()
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
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

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
        .holoCard()
    }

    private func openPendingGoalIfNeeded() {
        guard let goalId = pendingGoalDetailId else { return }
        selectedGoalRoute = GoalDetailRoute(id: goalId)
        pendingGoalDetailId = nil
    }

    private func requestDelete(_ goalId: UUID) {
        selectedGoalRoute = nil
        DispatchQueue.main.async {
            do {
                try repository.deleteGoal(id: goalId)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct GoalDetailRoute: Identifiable, Hashable {
    let id: UUID
}
