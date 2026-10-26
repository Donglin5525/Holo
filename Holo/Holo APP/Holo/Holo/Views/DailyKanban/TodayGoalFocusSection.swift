import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import CoreData
import Combine

struct TodayGoalFocusSection: View {
    @ObservedObject private var repository = GoalRepository.shared
    @AppStorage("holo.today.focusGoalID") private var focusID = ""
    @State private var operationError: String?
    private var selected: Goal? {
        let active = repository.goals.filter { !$0.isDeleted && $0.deletedAt == nil && $0.goalStatus == .active }
        return active.first { $0.id.uuidString == focusID } ?? active.first
    }
    var body: some View {
        if let goal = selected {
            TodayFocusedGoalCard(goal: goal, onDelete: { id in
                do { try repository.deleteGoal(id: id) }
                catch { operationError = error.localizedDescription }
            }).id(goal.id)
                .alert("操作失败", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                    Button("知道了", role: .cancel) {}
                } message: { Text(operationError ?? "") }
        }
    }
}

private struct TodayFocusedGoalCard: View {
    @ObservedObject var goal: Goal
    var onDelete: (UUID) -> Void
    @StateObject private var model = GoalProgressFactsModel()
    private let updates = NotificationCenter.default.publisher(for: .goalDataDidChange)
        .merge(with: NotificationCenter.default.publisher(for: .habitDataDidChange),
               NotificationCenter.default.publisher(for: .financeDataDidChange),
               NotificationCenter.default.publisher(for: .todoDataDidChange))
    var body: some View {
        NavigationLink {
            GoalDetailView(goal: goal, onOpenLinkedEntity: { DeepLinkState.shared.navigate(to: $0) }, onDeleteRequested: onDelete)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("关注中的目标").goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                Text(goal.title).goalJourneyText(.heading).foregroundStyle(Color.holoToolText)
                if model.error == nil, let snapshot = model.state?.snapshot {
                    metrics(snapshot)
                } else {
                    Text(model.error ?? "正在读取进展").goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
                HStack {
                    Text("查看进展长卷"); Spacer(); Image(systemName: "arrow.up.right")
                }.goalJourneyText(.metadata).foregroundStyle(GoalJourneyStyle.action).padding(.top, 2)
            }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
                .background(GoalJourneyStyle.inset, in: RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("today-focus-goal")
        .task { model.load(goal) }
        .onReceive(updates) { _ in model.load(goal) }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.load(goal) }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.load(goal) }
        #endif
    }
    @ViewBuilder private func metrics(_ snapshot: GoalEvaluationSnapshot) -> some View {
        let hasResult = snapshot.result.sourceKind != nil
        let requirements = Array((snapshot.requirements ?? []).prefix(hasResult ? 2 : 3))
        if hasResult {
            GoalJourneyMetricLabel(title: snapshot.result.sourceLabel, value: GoalFactsPresentation.result(snapshot),
                progress: GoalFactsPresentation.progress(snapshot.result), compact: true)
        }
        ForEach(requirements) { item in
            GoalJourneyMetricLabel(title: item.title, value: item.valueText,
                progress: GoalFactsPresentation.progress(item), evidence: GoalFactsPresentation.evidence(item), compact: true)
        }
        if !hasResult && requirements.isEmpty {
            Text(GoalFactsPresentation.result(snapshot)).goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
        }
        if let task = snapshot.execution.first(where: { candidate in candidate.entityType == .task && !candidate.isUnavailable && !(snapshot.requirements ?? []).contains(where: { $0.id == candidate.id }) }) {
            Text(task.title + "：" + (task.taskCompleted == true ? "已完成" : "待核对"))
                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolText)
        }
    }
}
