//
//  MacTaskListColumnView.swift
//  HoloMac
//
//  任务中栏：头部（范围标题+计数+搜索+排序）→ 分组任务流（复用 TaskCardView）
//  → 撤回 toast 贴底。分组策略跟随排序选项：截止时间=时间六组、优先级=四组、
//  创建时间=平铺、已完成范围=按周（与 iOS 任务列表同语义）。
//

import SwiftUI

// MARK: - 分组模型

/// 中栏展示分组（统一承载时间/优先级/周三类分组）
struct MacTaskSection: Identifiable {
    let id: String
    let title: String
    let dotColor: Color?
    let tasks: [TodoTask]
    /// 过期组的「全部到今天」操作
    var isOverdueGroup = false
    /// 远期组默认折叠（首屏聚焦「现在的事」）
    var foldsByDefault = false

    static func build(
        tasks: [TodoTask],
        sortOption: TaskSortOption,
        isCompletedScope: Bool
    ) -> [MacTaskSection] {
        if isCompletedScope {
            return weekSections(tasks)
        }
        switch sortOption.grouping {
        case .time:
            return timeSections(tasks)
        case .priority:
            return prioritySections(tasks)
        case .flat, .week:
            return [MacTaskSection(
                id: "flat", title: "", dotColor: nil, tasks: tasks)]
        }
    }

    private static func timeSections(_ tasks: [TodoTask]) -> [MacTaskSection] {
        let order: [(TaskTimeGroup, String, Color?, Bool)] = [
            (.overdue, "已过期", .holoError, false),
            (.today, "今天", .holoPrimary, false),
            (.tomorrow, "明天", Color(red: 0.23, green: 0.51, blue: 0.96), false),
            (.thisWeek, "本周", Color(red: 0.77, green: 0.77, blue: 0.77), true),
            (.later, "稍后", Color(red: 0.89, green: 0.89, blue: 0.89), true),
            (.unscheduled, "未安排", Color(red: 0.89, green: 0.89, blue: 0.89), true),
        ]
        return order.compactMap { group, title, color, folds in
            let members = tasks.filter { TaskTimeGroup.group(for: $0) == group }
            guard !members.isEmpty else { return nil }
            return MacTaskSection(
                id: group.rawValue, title: title, dotColor: color,
                tasks: members, isOverdueGroup: group == .overdue, foldsByDefault: folds)
        }
    }

    private static func prioritySections(_ tasks: [TodoTask]) -> [MacTaskSection] {
        let order: [(TaskPriority, String, Color)] = [
            (.urgent, "十分紧急", .holoError),
            (.high, "高", .holoPrimary),
            (.medium, "中", Color(red: 0.77, green: 0.77, blue: 0.77)),
            (.low, "低", Color(red: 0.89, green: 0.89, blue: 0.89)),
        ]
        return order.compactMap { level, title, color in
            let members = tasks.filter { $0.taskPriority == level }
            guard !members.isEmpty else { return nil }
            return MacTaskSection(id: "p\(level.rawValue)", title: title, dotColor: color, tasks: members)
        }
    }

    private static func weekSections(_ tasks: [TodoTask]) -> [MacTaskSection] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"

        let today = calendar.startOfDay(for: Date())
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? today

        func isOnOrAfter(_ date: Date, _ boundary: Date) -> Bool {
            calendar.startOfDay(for: date) >= boundary
        }

        var sections: [MacTaskSection] = []
        let thisWeek = tasks.filter { task in
            guard let at = task.completedAt else { return false }
            return isOnOrAfter(at, thisWeekStart)
        }
        let lastWeek = tasks.filter { task in
            guard let at = task.completedAt else { return false }
            return isOnOrAfter(at, lastWeekStart) && !isOnOrAfter(at, thisWeekStart)
        }
        let earlier = tasks.filter { task in
            guard let at = task.completedAt else { return false }
            return !isOnOrAfter(at, lastWeekStart)
        }
        if !thisWeek.isEmpty {
            sections.append(MacTaskSection(id: "w0", title: String(localized: "本周"), dotColor: .holoSuccess, tasks: thisWeek))
        }
        if !lastWeek.isEmpty {
            sections.append(MacTaskSection(id: "w1", title: String(localized: "上周"), dotColor: nil, tasks: lastWeek))
        }
        if !earlier.isEmpty {
            let newest = earlier.compactMap(\.completedAt).max()
            let oldest = earlier.compactMap(\.completedAt).min()
            let title: String
            if let newest, let oldest {
                title = "\(formatter.string(from: oldest)) - \(formatter.string(from: newest))"
            } else {
                title = String(localized: "更早")
            }
            sections.append(MacTaskSection(id: "w2", title: title, dotColor: nil, tasks: earlier))
        }
        return sections
    }
}

// MARK: - 中栏视图

struct MacTaskListColumnView: View {

    @ObservedObject var model: MacTasksBrowserModel
    @Binding var selectedTaskId: UUID?
    /// ⌘F 聚焦脉冲（变化即聚焦搜索框）
    var searchTrigger: Int
    /// 撤回 toast（宿主为工作台根）
    var toastMessage: String?
    var toastAction: (() -> Void)?

    var onToggleCompletion: (TodoTask, (checkItemID: UUID, wasChecked: Bool)?) -> Void
    var onPostpone: (TodoTask) -> Void
    /// 批量延期由工作台执行（toast/撤回基建在工作台根；2026-10-31 审计 M3）
    var onPostponeAllOverdue: () -> Void = {}
    var onMoveToList: (TodoTask) -> Void
    var onArchive: (TodoTask) -> Void
    var onCopyTitle: (TodoTask) -> Void
    var onDelete: (TodoTask) -> Void

    @FocusState private var searchFieldFocused: Bool
    /// 折叠组（id 集合；初值=各默认折叠组，用户展开/收起自由掌控）
    @State private var collapsedSections: Set<String>?

    private var sections: [MacTaskSection] {
        MacTaskSection.build(
            tasks: model.tasks,
            sortOption: model.sortOption,
            isCompletedScope: model.scope == .completed)
    }

    private var effectiveCollapsed: Set<String> {
        if let collapsedSections {
            return collapsedSections
        }
        // 首次构建：默认折叠远期组
        return Set(sections.filter(\.foldsByDefault).map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if !model.hasLoadedOnce {
                Spacer()
                ProgressView()
                Spacer()
            } else if model.tasks.isEmpty {
                emptyStateView
            } else {
                taskListScroll
            }
        }
        .background(Color.holoToolBackground)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                undoToast(message: toastMessage)
            }
        }
        .onChange(of: searchTrigger) { _, _ in
            searchFieldFocused = true
        }
    }

    // MARK: - 头部

    private var headerView: some View {
        HStack(spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.scopeTitle)
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text(String(localized: "\(model.tasks.count) 项任务"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer(minLength: HoloSpacing.md)

            searchBarView

            sortMenu
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolBackground)
    }

    private var searchBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)

            TextField(String(localized: "搜索任务…"), text: $model.searchText)
                .focused($searchFieldFocused)
                .textFieldStyle(.plain)
                .holoText(.supporting)
                .foregroundColor(.holoToolText)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "清空搜索"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolInset))
        .onChange(of: model.searchText) { _, _ in
            model.scheduleReload()
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach([TaskSortOption.due, .priority, .created], id: \.self) { option in
                Button {
                    if model.sortOption == option {
                        model.sortAscending.toggle()
                    } else {
                        model.sortOption = option
                        model.sortAscending = option.defaultAscending
                    }
                    model.reloadNow()
                } label: {
                    if model.sortOption == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
            Divider()
            Button {
                model.sortAscending.toggle()
                model.reloadNow()
            } label: {
                Text(model.sortOption.directionLabel(ascending: model.sortAscending))
            }
        } label: {
            Label(
                String(localized: "排序：\(model.sortOption.title)"),
                systemImage: "arrow.up.arrow.down")
                .font(.holoLabel)
                .foregroundColor(Color.holoToolAction)
        }
        .accessibilityIdentifier("mac.task.sortMenu")
    }

    // MARK: - 任务流

    private var taskListScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(HoloSpacing.md)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MacTaskSection) -> some View {
        if section.id == "flat" {
            // 平铺（创建时间排序）：无组头
            ForEach(section.tasks, id: \.id) { task in
                cardView(task)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(section)
                if !effectiveCollapsed.contains(section.id) {
                    ForEach(section.tasks, id: \.id) { task in
                        cardView(task)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: MacTaskSection) -> some View {
        HStack(spacing: 8) {
            Button {
                if collapsedSections == nil {
                    collapsedSections = effectiveCollapsed
                }
                if collapsedSections!.contains(section.id) {
                    collapsedSections!.remove(section.id)
                } else {
                    collapsedSections!.insert(section.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: effectiveCollapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                    if let dot = section.dotColor {
                        Circle()
                            .fill(dot)
                            .frame(width: 7, height: 7)
                    }
                    Text(section.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoToolText)
                    Text(String(localized: "\(section.tasks.count)"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                    if effectiveCollapsed.contains(section.id) && section.tasks.count > 3 {
                        Text(String(localized: "已折叠"))
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            if section.isOverdueGroup {
                Button {
                    postponeAllOverdue()
                } label: {
                    Text(String(localized: "全部到今天"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.holoPrimaryDark)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.holoPrimary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mac.task.overdueToTodayButton")
            }

            Spacer()
        }
    }

    private func cardView(_ task: TodoTask) -> some View {
        let isSelected = selectedTaskId == task.id
        return TaskCardView(
            task: task,
            repository: model.repository,
            onNavigate: {
                selectedTaskId = task.id
            },
            onToggleCompletion: { trigger in
                onToggleCompletion(task, trigger)
            },
            onNavigateToAnniversary: nil,   // Mac V1 纪念日徽章只读
            onPostpone: canPostpone(task) ? { onPostpone(task) } : nil,
            onMoveToList: { onMoveToList(task) },
            onArchive: { onArchive(task) },
            onCopyTitle: { onCopyTitle(task) },
            onDelete: { onDelete(task) })
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .strokeBorder(isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1.5))
            .accessibilityIdentifier("mac.task.card")
    }

    /// 延期条件与 iOS 时间胶囊口径一致：有日期且未完成（重复任务不提供延期）
    private func canPostpone(_ task: TodoTask) -> Bool {
        task.dueDate != nil && !task.completed && task.repeatRule == nil
    }

    private func postponeAllOverdue() {
        onPostponeAllOverdue()
    }

    // MARK: - 空态（三态）

    private var emptyStateView: some View {
        let isSearching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let (icon, title, subtitle): (String, String, String) = {
            if isSearching {
                return ("magnifyingglass", String(localized: "没有找到相关任务"), String(localized: "换个关键词试试"))
            }
            if model.scope == .today {
                return ("sun.max", String(localized: "今天没有待办"),
                        String(localized: "按 ⌘N 记一件要做的事，或去侧栏换个范围看看"))
            }
            return ("tray", String(localized: "该范围内暂无任务"), String(localized: "换个范围，或按 ⌘N 新建"))
        }()

        return VStack(spacing: HoloSpacing.md) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            Text(title)
                .holoText(.sectionTitle)
                .foregroundColor(.holoToolText)
            Text(subtitle)
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)
                .multilineTextAlignment(.center)
            // 首装 iCloud 恢复期提示：挂活条件（此前挂 !hasLoadedOnce 恒假，是死分支；2026-10-31 审计 M6）
            if ICloudSyncStatusService.shared.isInitialSyncPending {
                Text(String(localized: "正在从 iCloud 恢复数据，稍等片刻就会显示"))
                    .font(.holoTinyLabel)
                    .foregroundColor(Color(red: 0.23, green: 0.51, blue: 0.96))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 撤回 toast

    private func undoToast(message: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Text(message)
                .font(.holoLabel)
                .foregroundColor(.holoToolText)
            if let toastAction {
                Button(String(localized: "撤回")) {
                    toastAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolInset)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2))
        .padding(.bottom, HoloSpacing.lg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
