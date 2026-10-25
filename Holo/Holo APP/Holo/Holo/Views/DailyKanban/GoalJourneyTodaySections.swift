import SwiftUI
import CoreData

/// 原型里的其他安排保留为连续行，完整任务视图仍走原入口。
struct GoalJourneyTodayAgenda: View {
    let items: [HoloTodayAgendaItem]
    var sectionState: HoloTodaySectionState? = nil
    let onItem: (HoloTodayAgendaItem) -> Void
    let onComplete: (HoloTodayAgendaItem) -> Void
    var pendingUndoTaskID: UUID? = nil
    var onUndo: () -> Void = {}
    @State private var showTasks = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("其他安排").goalJourneyText(.body).foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Button("全部任务") { showTasks = true }.goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action).frame(minHeight: 44)
            }
            if case .failed = sectionState {
                Text("安排暂时读取失败，请稍后重试。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolError).padding(.vertical, 16)
            } else if items.isEmpty {
                Text("今天没有其他待处理安排。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.vertical, 16)
            }
            ForEach(items.prefix(3)) { item in
                GoalJourneySourceRow(title: item.title, value: status(item), note: item.matterTitle ?? "") { onItem(item) }
                    .contextMenu {
                        if isPending(item) { Button("撤回完成", action: onUndo) }
                        else if case .openTask = item.action, !item.isCompleted { Button("完成任务") { onComplete(item) } }
                    }
                if isPending(item) {
                    HStack {
                        Text("已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回").foregroundStyle(Color.holoToolTextSecondary)
                        Spacer()
                        Button("撤回", action: onUndo).foregroundStyle(GoalJourneyStyle.action).frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("today-agenda-undo")
                    }.goalJourneyText(.supporting)
                }
            }
        }
        .sheet(isPresented: $showTasks) { TasksView().environment(\.holoDismiss, { showTasks = false }) }
    }
    private func status(_ item: HoloTodayAgendaItem) -> String {
        if item.isCompleted || isPending(item) { return "已完成" }
        if item.kind == .taskOverdue, let date = item.timeAt {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
            return days > 0 ? "逾期\(days)天" : "已过截止"
        }
        if item.kind == .scheduleOngoing { return "进行中" }
        if let date = item.timeAt { return date.formatted(.dateTime.hour().minute()) }
        return "待办"
    }
    private func isPending(_ item: HoloTodayAgendaItem) -> Bool {
        if case .openTask(let id) = item.action { return pendingUndoTaskID == id }
        return false
    }
}

struct GoalJourneyTodayLinks: View {
    var onOpenAI: () -> Void
    var onPlanGoal: () -> Void
    var onOpenFinance: () -> Void
    @ObservedObject private var goals = GoalRepository.shared
    @State private var showHabits = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("日常入口").goalJourneyText(.body).foregroundStyle(Color.holoToolTextSecondary).padding(.top, 20).padding(.bottom, 6)
            GoalJourneySourceRow(title: "全部习惯", value: "查看", note: "点一项，查看对应周期的明细与记录") { showHabits = true }
            NavigationLink {
                GoalListView(onPlanGoal: onPlanGoal, onOpenLinkedEntity: { DeepLinkState.shared.navigate(to: $0) })
            } label: {
                HStack {
                    Text("所有目标").goalJourneyText(.row); Spacer()
                    Text("\(goals.goals.filter { !$0.isDeleted && $0.deletedAt == nil }.count) 个").goalJourneyText(.rowValue)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Color.holoToolTextSecondary)
                }.foregroundStyle(Color.holoToolText).frame(minHeight: 68).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
            }.buttonStyle(.plain)
            HStack(spacing: 4) {
                Button(action: onOpenFinance) { Label("记账", systemImage: "wallet.bifold") }
                    .frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(Color.holoToolText)
                Button(action: onOpenAI) { Label("对 Holo 说", systemImage: "sparkles") }
                    .frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(GoalJourneyStyle.action)
            }.goalJourneyText(.metadata).padding(.top, 18)
        }
        .sheet(isPresented: $showHabits) { HabitModuleContainer().environment(\.holoDismiss, { showHabits = false }) }
    }
}
