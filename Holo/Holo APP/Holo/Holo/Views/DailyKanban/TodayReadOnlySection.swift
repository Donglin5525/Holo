import SwiftUI

/// 一个连续的只读概览；点击定位原模块，原模块保存后仍停留在原模块。
struct TodayReadOnlySection: View {
    let snapshot: HoloTodaySnapshot
    let onItem: (HoloTodayAgendaItem) -> Void
    let onRefresh: () -> Void
    @State private var destination: Destination?
    private enum Destination: Identifiable {
        case tasks, habits, finance, habit(HabitSourceRoute)
        var id: String {
            switch self { case .tasks: return "tasks"; case .habits: return "habits"; case .finance: return "finance"; case .habit(let route): return route.id }
        }
    }
    private var items: [HoloTodayAgendaItem] { HoloTodayReadOnlyProjection.agenda(snapshot) }
    private var hasFacts: Bool { !snapshot.routine.habitRows.isEmpty || (snapshot.overview.spentToday ?? 0) > 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            introduction
            TodayGoalFocusSection()
            if items.isEmpty && !hasFacts {
                emptyOverview
            } else {
                arrangements
                recentFacts
            }
        }
        .sheet(item: $destination, onDismiss: onRefresh) { target in
            switch target {
            case .tasks: TasksView().environment(\.holoDismiss, { destination = nil })
            case .habits: HabitModuleContainer().environment(\.holoDismiss, { destination = nil })
            case .finance: FinanceView().environment(\.holoDismiss, { destination = nil })
            case .habit(let route): HabitSourceDetailView(route: route)
            }
        }
    }
    private var introduction: some View {
        let tasks = items.filter { if case .openTask = $0.action { return true }; return false }.count
        let schedules = items.count - tasks
        let failed: Bool
        if case .failed = snapshot.sectionStates[.agenda] { failed = true } else { failed = false }
        let title = failed && items.isEmpty ? "今天的安排暂不可用。" : items.isEmpty ? "今天还没有新的安排。" : [tasks > 0 ? "\(tasks) 件待办" : nil, schedules > 0 ? "\(schedules) 个日程" : nil].compactMap { $0 }.joined(separator: "，") + "。"
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).goalJourneyText(.title).foregroundStyle(Color.holoToolText).accessibilityIdentifier("today-overview-headline")
            Text(planMessage ?? (failed ? "安排读取失败，可以前往原模块核对。" : items.isEmpty ? "安排和记录更新后，会在这里看到当天概况。" : "当天安排与原模块保持同步。"))
                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
        }
    }
    private var arrangements: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今天的安排").goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Button("查看全部任务") { destination = .tasks }.goalJourneyText(.metadata)
                    .foregroundStyle(GoalJourneyStyle.action).frame(minHeight: 44).accessibilityIdentifier("today-open-tasks")
            }
            if case .failed = snapshot.sectionStates[.agenda] {
                Text("安排暂时读取失败，请到任务模块核对。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolError).padding(.vertical, 12)
            }
            if items.isEmpty {
                Text("今天暂时没有待处理安排。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.vertical, 12)
            }
            ForEach(items.prefix(3)) { item in
                GoalJourneySourceRow(title: item.title, value: status(item), note: item.matterTitle ?? "任务",
                    identifier: "today-agenda-" + item.id) { onItem(item) }
            }
            if let message = planMessage {
                Text(message).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary).padding(.top, 10)
            }
        }
    }
    @ViewBuilder private var recentFacts: some View {
        if hasFacts {
            VStack(alignment: .leading, spacing: 0) {
                Text("当天近况").goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.bottom, 6)
                ForEach(snapshot.routine.habitRows.prefix(2)) { row in
                    GoalJourneySourceRow(title: row.name, value: row.isDone ? (row.progressText ?? "已有记录") : "尚未记录",
                        note: "习惯 · 今天的原记录", identifier: "today-habit-" + row.id.uuidString) {
                        let start = HabitRepository.shared.findHabit(by: row.id)?.currentDay(now: snapshot.referenceTime) ?? snapshot.dayStart
                        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? snapshot.dayEnd
                        destination = .habit(HabitSourceRoute(habitID: row.id, start: start, endExclusive: end))
                    }
                }
                if let spent = snapshot.overview.spentToday, spent > 0 {
                    GoalJourneySourceRow(title: "今日支出", value: GoalJourneyNarrative.money(spent), note: "记账 · 今天的收支", identifier: "today-open-finance") { destination = .finance }
                }
            }
        }
    }
    private var emptyOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("可以先去任务模块安排一件事，或去习惯、记账模块留下记录。")
                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).lineSpacing(5)
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(GoalJourneyStyle.inset, in: RoundedRectangle(cornerRadius: 13)).padding(.bottom, 10)
            GoalJourneySourceRow(title: "任务", value: "前往", note: "查看与安排任务", identifier: "today-open-tasks") { destination = .tasks }
            GoalJourneySourceRow(title: "习惯", value: "前往", note: "查看与建立日常习惯", identifier: "today-open-habits") { destination = .habits }
            GoalJourneySourceRow(title: "记账", value: "前往", note: "管理收支与账户", identifier: "today-open-finance") { destination = .finance }
        }
    }
    private var planMessage: String? {
        switch snapshot.plan.state {
        case .conflict: return "已保存的今日安排有不同版本，请到任务模块核对。"
        case .syncing: return "已保存的今日安排正在同步，当前显示可核对的来源事实。"
        case .unavailable: return "已保存的今日安排暂不可用，请到任务模块核对。"
        default: return nil
        }
    }
    private func status(_ item: HoloTodayAgendaItem) -> String {
        if item.kind == .scheduleOngoing { return "进行中" }
        if item.kind == .taskOverdue { return "已过截止" }
        if case .openSchedule = item.action {
            guard let date = item.timeAt else { return "全天" }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        return "待办"
    }
}
