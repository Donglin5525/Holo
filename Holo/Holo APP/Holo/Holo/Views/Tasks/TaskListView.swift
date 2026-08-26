//
//  TaskListView.swift
//  Holo
//
//  任务首页 —— 今日仪表 + 时间分组任务流
//  设计语言与习惯打卡页同源（进度头条 / 渐变 / 庆祝时刻），原型见 task-home-redesign-prototype.html
//

import SwiftUI
import CoreData
import OSLog

// MARK: - 筛选类型

/// 任务筛选类型
enum TaskFilterType: Equatable {
    case all
    case inbox
    case today
    case completed
    case overdue
    case list(UUID)  // 清单筛选

    var title: String {
        switch self {
        case .all: return "全部"
        case .inbox: return "收件箱"
        case .today: return "今日"
        case .completed: return "已完成"
        case .overdue: return "已过期"
        case .list: return "清单"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full.fill"
        case .inbox: return "tray"
        case .today: return "sun.max.fill"
        case .completed: return "checkmark.circle.fill"
        case .overdue: return "exclamationmark.triangle.fill"
        case .list: return "folder"
        }
    }

    /// 是否是预设筛选（非清单）
    var isPreset: Bool {
        switch self {
        case .all, .inbox, .today, .completed, .overdue: return true
        case .list: return false
        }
    }
}

// MARK: - 时间分组

/// 任务按到期时间的展示分组（过期置顶，远期组默认折叠降噪）
enum TaskTimeGroup: String, CaseIterable, Hashable {
    case overdue
    case today
    case tomorrow
    case thisWeek
    case later
    case unscheduled

    var title: String {
        switch self {
        case .overdue: return "已过期"
        case .today: return "今天"
        case .tomorrow: return "明天"
        case .thisWeek: return "本周"
        case .later: return "稍后"
        case .unscheduled: return "未安排"
        }
    }

    var dotColor: Color {
        switch self {
        case .overdue: return .holoError
        case .today: return .holoPrimary
        case .tomorrow: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .thisWeek: return Color(red: 0.77, green: 0.77, blue: 0.77)
        case .later: return Color(red: 0.89, green: 0.89, blue: 0.89)
        case .unscheduled: return Color(red: 0.89, green: 0.89, blue: 0.89)
        }
    }

    /// 远期组默认折叠：首屏聚焦「现在的事」
    var foldsByDefault: Bool {
        switch self {
        case .thisWeek, .later, .unscheduled: return true
        default: return false
        }
    }

    /// 纯按时间归类（不看成败——今日视图里已完成任务也要留在组内展示）
    static func group(for task: TodoTask) -> TaskTimeGroup {
        if task.isOverdue { return .overdue }
        if task.isDueToday { return .today }
        if task.isDueTomorrow { return .tomorrow }
        if let due = task.dueDate,
           Calendar.current.isDate(due, equalTo: Date(), toGranularity: .weekOfYear) {
            return .thisWeek
        }
        if task.dueDate != nil { return .later }
        return .unscheduled
    }
}

// MARK: - TaskListView

/// 任务首页
struct TaskListView: View {

    // MARK: - Properties

    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void
    /// 把当前筛选上下文传给外层新增入口，保证新增任务继承当前视图语义。
    var onFilterChanged: ((TaskFilterType) -> Void)? = nil
    /// Cmd+F 触发计数（TasksView 转发）：变化即打开任务搜索
    var searchTrigger: Int = 0

    /// 任务列表（本地缓存）
    @State private var tasks: [TodoTask] = []
    /// 是否已完成首次加载（避免入场时空态先闪现、再被列表替换的分批出现感）
    @State private var hasLoadedOnce = false
    /// 今日进度
    @State private var todayProgress: (completed: Int, total: Int) = (0, 0)
    /// 持久化的预设筛选类型（不含清单，清单每次重选）；默认落在「今日」
    @AppStorage("taskList.selectedPresetFilter") private var selectedPresetFilterRaw: String = "today"
    /// 当前筛选（从持久化恢复）
    @State private var selectedFilter: TaskFilterType = .all
    /// 排序偏好分两个槽位持久化：主列表与已完成页语义不同（已完成页默认「完成时间·最近在前」）
    @AppStorage("taskList.sortOption") private var mainSortOptionRaw: String = TaskSortOption.due.rawValue
    @AppStorage("taskList.sortAscending") private var mainSortAscendingRaw: Bool = true
    @AppStorage("taskList.completedSortOption") private var completedSortOptionRaw: String = TaskSortOption.completed.rawValue
    @AppStorage("taskList.completedSortAscending") private var completedSortAscendingRaw: Bool = false
    /// 当前排序方式与方向（切筛选时从对应槽位装填）
    @State private var sortOption: TaskSortOption = .due
    @State private var sortAscending = true
    /// 排序弹层
    @State private var showSortSheet = false
    /// 缓存的过滤结果
    @State private var cachedFilteredTasks: [TodoTask] = []
    /// 手动折叠的分组（默认折叠集在 onAppear 初始化，之后完全由用户掌控；key 兼容时间组与优先级组）
    @State private var collapsedGroups: Set<String> = []

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        var lists = repository.unfiledLists
        lists.append(contentsOf: repository.folders.flatMap { $0.listsArray })
        return lists
    }

    /// 选中的任务（用于 sheet 展示）
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection? = nil

    /// 是否显示归档管理页面
    @State private var showArchiveManagement = false
    /// 是否显示通知设置页面
    @State private var showNotificationSettings = false
    /// 是否显示搜索页面
    @State private var showSearchView = false

    /// 最近已完成是否展开
    @State private var isRecentlyCompletedExpanded = false

    /// Hero 入场
    @State private var heroAppeared = false

    /// 右滑展开的卡片 ID
    @State private var revealedTaskId: UUID? = nil

    /// 正在完成中的任务 ID（来自 repository 全局撤回状态）
    private var pendingCompletionTaskId: UUID? { repository.pendingCompletionTaskId }

    /// 未完成的过期任务数（Hero 副行警示）
    private var overdueCount: Int {
        tasks.filter { $0.isOverdue }.count
    }

    /// Deep Link 状态（通知点击跳转）
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ZStack(alignment: .bottom) {
                // 点击空白区域收起左滑展开的行
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if revealedTaskId != nil {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                revealedTaskId = nil
                            }
                        }
                    }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        heroSection

                        filterPickerView

                        if selectedFilter == .completed {
                            // 已完成 tab：按周分组展示
                            completedTabContent
                        } else {
                            // 其他 tab：时间分组任务流
                            otherTabContent
                        }

                        if cachedFilteredTasks.isEmpty && hasLoadedOnce {
                            emptyStateView
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.xs)
                    .padding(.bottom, pendingCompletionTaskId != nil ? 80 : 100)
                }

                // 撤回 banner
                if pendingCompletionTaskId != nil {
                    undoBanner
                }
            }
        }
        .onAppear {
            // 从持久化恢复筛选状态
            switch selectedPresetFilterRaw {
            case "inbox": selectedFilter = .inbox
            case "today": selectedFilter = .today
            case "completed": selectedFilter = .completed
            case "overdue": selectedFilter = .overdue
            default: selectedFilter = .all
            }
            onFilterChanged?(selectedFilter)
            // 恢复当前筛选对应的排序偏好槽位
            restoreSortPreference()
            // 首次进入初始化默认折叠集（远期组收起降噪）
            if collapsedGroups.isEmpty {
                collapsedGroups = Set(TaskTimeGroup.allCases.filter(\.foldsByDefault).map(\.rawValue))
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                heroAppeared = true
            }
            // Core Data 未就绪时 fetch 静默返回空，首次加载交给 .task 等就绪后执行
            guard CoreDataStack.shared.isReady else { return }
            loadTasks()
        }
        .task {
            // 等 Core Data 就绪 + 仓库初始化后再加载，避免入场时列表空态/内容分批出现
            await CoreDataStack.shared.waitUntilReady()
            repository.setup()
            loadTasks()
        }
        // 监听 Deep Link：冷启动时 onAppear 读取已有值
        .onAppear { handleDeepLink() }
        // 监听 Deep Link：热启动/后台时 onChange 检测变化
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            handleDeepLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            loadTasks()
        }
        .onChange(of: selectedFilter) { _, newFilter in
            updateFilteredTasks()
            onFilterChanged?(newFilter)
            // 切筛选时装填对应槽位的排序偏好（主列表 / 已完成页各一份）
            restoreSortPreference()
            // 持久化预设筛选（清单筛选不持久化，每次重选）
            switch newFilter {
            case .all: selectedPresetFilterRaw = "all"
            case .inbox: selectedPresetFilterRaw = "inbox"
            case .today: selectedPresetFilterRaw = "today"
            case .completed: selectedPresetFilterRaw = "completed"
            case .overdue: selectedPresetFilterRaw = "overdue"
            case .list: break
            }
        }
        .onChange(of: tasks) { _, _ in
            updateFilteredTasks()
        }
        .onChange(of: pendingCompletionTaskId) { _, _ in
            // 撤回/确认完成时同步 Hero 数字
            loadTodayProgress()
        }
        .sheet(item: $selectedTask, onDismiss: {
            // 复位选中状态，确保下次 DeepLink 命中相同 taskId 时能重新触发 sheet
            selectedTask = nil
        }) { selection in
            if let task = tasks.first(where: { $0.id == selection.id }) ?? repository.findTask(by: selection.id) {
                TaskDetailView(task: task, repository: repository)
            } else {
                // 找不到任务（可能落库未完成或已删除）：不能弹无返回按钮的 ProgressView，
                // 否则用户会被困在 sheet 里无法返回。
                TaskNotFoundView(onDismiss: { selectedTask = nil })
            }
        }
        .sheet(isPresented: $showSortSheet) {
            TaskSortSheet(
                availableOptions: availableSortOptions,
                sortOption: $sortOption,
                sortAscending: $sortAscending,
                onPick: { option, ascending in
                    applySort(option, ascending: ascending)
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showArchiveManagement) {
            ArchiveManagementView(repository: repository)
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
        .fullScreenCover(isPresented: $showSearchView) {
            TaskSearchView(repository: repository)
                .holoContentColumn()
        }
        .onChange(of: searchTrigger) { _, _ in
            showSearchView = true
        }
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        ZStack {
            // 居中标题
            Text("任务")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
                // 返回按钮
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 44, height: 44)
                }

                Spacer()

                // 右侧按钮组（今日进度已升级进 Hero 仪表区）
                HStack(spacing: 0) {
                    Button {
                        showSearchView = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 32, height: 44)
                    }

                    Button {
                        showNotificationSettings = true
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 32, height: 44)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - Hero 今日仪表

    /// 撤回窗口期间乐观计数：正在完成中的今日任务直接计入完成数
    private var heroProgress: (completed: Int, total: Int) {
        var progress = todayProgress
        if let pendingId = pendingCompletionTaskId,
           let task = tasks.first(where: { $0.id == pendingId }),
           !task.completed, task.isDueToday {
            progress.completed += 1
        }
        return progress
    }

    private var isHeroAllDone: Bool {
        heroProgress.total > 0 && heroProgress.completed >= heroProgress.total
            && pendingCompletionTaskId == nil
    }

    @ViewBuilder
    private var heroSection: some View {
        let ratio: CGFloat = heroProgress.total > 0
            ? CGFloat(heroProgress.completed) / CGFloat(heroProgress.total)
            : 0

        Group {
            if isHeroAllDone {
                heroCelebrateCard(total: heroProgress.total)
            } else {
                heroRegularCard(ratio: ratio)
            }
        }
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 14)
        .padding(.top, HoloSpacing.md)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isHeroAllDone)
    }

    /// 常规态：日期行 + 大数字进度 + 环形进度 + 渐变条 + 过期警示
    private func heroRegularCard(ratio: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heroDateString)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("今日进度")
                        .font(.system(size: 12.5))
                        .foregroundColor(.holoTextSecondary)

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(heroProgress.completed)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundColor(.holoPrimary)
                        Text("/")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                        Text("\(heroProgress.total)")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }

                    HStack(spacing: 10) {
                        if heroProgress.total > 0 {
                            Text("还剩 ") + Text("\(heroProgress.total - heroProgress.completed)")
                                .foregroundColor(.holoPrimary)
                                .fontWeight(.bold)
                                + Text(" 项")
                        } else {
                            Text("今天暂无到期任务")
                        }

                        if overdueCount > 0 {
                            Text("\(overdueCount) 项已过期")
                                .foregroundColor(.holoError)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 0)

                heroRing(ratio: ratio)
            }

            heroProgressBar(ratio: ratio)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.holoCardBackground)
                // 左上暖色光晕（与习惯页进度头同源的暖调）
                LinearGradient(
                    colors: [Color.holoPrimary.opacity(0.07), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    /// 环形进度（品牌橙渐变描边）
    private func heroRing(ratio: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.holoPrimary.opacity(0.10), lineWidth: 7)

            Circle()
                .trim(from: 0, to: ratio)
                .stroke(
                    AngularGradient(
                        colors: [.holoPrimary, .holoPrimaryDark],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundColor(.holoPrimary)
        }
        .frame(width: 72, height: 72)
        .animation(.easeOut(duration: 0.5), value: ratio)
    }

    private func heroProgressBar(ratio: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoBorder)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimary, .holoPrimaryDark],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 6)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.5), value: ratio)
    }

    private var heroDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date()) + " · 今天"
    }

    /// 庆祝态：今日清零，整块变品牌橙渐变（与习惯页「今天全部点亮」同一语言）
    private func heroCelebrateCard(total: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("今天全部完成")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundColor(.white)
                    Text("✨")
                        .font(.system(size: 16))
                }

                Text(celebrateSubtitle(total: total))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.88))
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.holoPrimary, .holoPrimaryDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: Color.holoPrimary.opacity(0.32), radius: 14, x: 0, y: 6)
    }

    /// 庆祝卡副行：有次日任务时预告明天，给一天画上句点
    private func celebrateSubtitle(total: Int) -> String {
        let tomorrowCount = tasks.filter { $0.isDueTomorrow && !$0.completed }.count
        if tomorrowCount > 0 {
            return "共 \(total) 项全部清零 · 明天还有 \(tomorrowCount) 项等着你"
        }
        return "共 \(total) 项任务全部清零 · 享受你的夜晚吧"
    }

    // MARK: - 筛选器

    private var filterPickerView: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 「今日」为第一视图（任务模块最高频视角）
                    filterChip(.today)
                    filterChip(.inbox)
                    filterChip(.all)
                    filterChip(.completed)

                    // 过期：带红色计数角标
                    filterChip(.overdue)
                        .overlay(alignment: .topTrailing) {
                            if overdueCount > 0 {
                                Text("\(overdueCount)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.holoError))
                                    .offset(x: 5, y: -5)
                                    .allowsHitTesting(false)
                            }
                        }

                    // 清单筛选收纳为单入口
                    listMenuChip

                    // 归档入口
                    Button {
                        showArchiveManagement = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 12, weight: .medium))
                            Text("归档")
                                .font(.holoCaption)
                        }
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.holoCardBackground)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            style: StrokeStyle(lineWidth: 1, dash: [4])
                                        )
                                        .foregroundColor(.holoDivider)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, HoloSpacing.xs)
            }

            // 排序入口固定筛选条右端：不随过滤胶囊滚动、始终可见
            // （非默认排序时高亮显示当前排法，让排序状态可见、可改）
            sortChip
        }
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoBackground)
    }

    /// 排序胶囊：默认与过滤胶囊同族样式；用户改过排序后浅橙底 + 橙字显示当前排法
    private var sortChip: some View {
        let isDefault = sortOption == contextDefaultSort
            && sortAscending == contextDefaultSort.defaultAscending

        return Button {
            showSortSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(isDefault
                     ? "排序"
                     : "\(sortOption.title) · \(sortOption.directionLabel(ascending: sortAscending))")
                    .font(.holoCaption)
                    .lineLimit(1)
            }
            .foregroundColor(isDefault ? .holoTextSecondary : .holoPrimaryDark)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isDefault ? Color.holoCardBackground : Color.holoPrimary.opacity(0.10)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isDefault ? Color.holoDivider : Color.holoPrimary.opacity(0.35),
                    lineWidth: 1
                )
            )
            // 排序文案随选择变宽，fixedSize 防止胶囊被压成省略号（同清单胶囊）
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    /// 筛选胶囊：选中态为品牌橙渐变实底 + 轻投影（与 Hero 同源语言）
    private func filterChip(_ filter: TaskFilterType) -> some View {
        let isSelected = selectedFilter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(filter.title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .white : .holoTextSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(LinearGradient(colors: [.holoPrimary, .holoPrimaryDark], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.holoCardBackground)
                )
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.holoPrimary.opacity(0.26) : .clear, radius: 6, x: 0, y: 3)
            // 横向滚动条中的胶囊按内容取宽，避免父级宽度提案裁掉首字符或图标
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    /// 清单筛选：Menu 收纳，选中后胶囊显示清单色点与名称
    private var listMenuChip: some View {
        let selectedList: TodoList? = {
            if case .list(let id) = selectedFilter {
                return allLists.first(where: { $0.id == id })
            }
            return nil
        }()

        return Menu {
            ForEach(allLists, id: \.id) { list in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedFilter = .list(list.id)
                    }
                } label: {
                    HStack {
                        Text(list.name)
                        if selectedFilter == .list(list.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let list = selectedList {
                    Circle()
                        .fill(Color(hex: list.color ?? "#007AFF"))
                        .frame(width: 8, height: 8)
                    Text(list.name)
                        .font(.holoCaption)
                        .lineLimit(1)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("清单")
                        .font(.holoCaption)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(selectedList != nil ? .white : .holoTextSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    selectedList != nil
                        ? AnyShapeStyle(LinearGradient(colors: [.holoPrimary, .holoPrimaryDark], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.holoCardBackground)
                )
            )
            .overlay(
                Capsule().strokeBorder(selectedList != nil ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
            // Menu 换 label 内容时可能沿用旧的宽度提案；按内容取宽，且在清单切换时重建
            // Menu，避免旧的短文案布局缓存把新名称的首字符或色点裁掉。
            .fixedSize(horizontal: true, vertical: false)
        }
        .id(selectedList?.id)
    }

    // MARK: - 时间分组任务流（非完成 tab）

    /// 今日视图：过期 + 今天（含已完成卡，组内展示完成态）
    /// 其他视图：未完成进分组、最近已完成走折叠抽屉（现状）
    @ViewBuilder
    private var otherTabContent: some View {
        let groupingTasks = selectedFilter == .today
            ? cachedFilteredTasks
            : cachedFilteredTasks.filter { !$0.completed }

        // 排序方案自带分组策略：截止时间→时间分组；优先级→四分组；创建时间→平铺
        switch sortOption.grouping {
        case .time:
            timeGroupedContent(groupingTasks)
        case .priority:
            priorityGroupedContent(groupingTasks)
        case .flat:
            flatContent(groupingTasks)
        case .week:
            // 完成时间排序仅已完成页可选，其他页不会出现；按时间分组兜底
            timeGroupedContent(groupingTasks)
        }

        // 最近已完成折叠抽屉（非今日视图；今日视图的完成卡已直接展示在组内）
        if selectedFilter != .today {
            let recentlyCompleted = cachedFilteredTasks.filter { $0.completed && isCompletedRecently($0) }
            if !recentlyCompleted.isEmpty {
                recentlyCompletedSection(recentlyCompleted)
            }
        }
    }

    /// 时间分组流（现版本结构：组序固定为信息架构，方向只作用于组内排序）
    @ViewBuilder
    private func timeGroupedContent(_ groupingTasks: [TodoTask]) -> some View {
        let groups = Dictionary(grouping: groupingTasks, by: { TaskTimeGroup.group(for: $0) })

        ForEach(TaskTimeGroup.allCases, id: \.self) { group in
            if let members = groups[group], !members.isEmpty {
                groupHeader(
                    id: group.rawValue,
                    title: group.title,
                    dotColor: group.dotColor,
                    count: members.count
                )

                if !collapsedGroups.contains(group.rawValue) {
                    ForEach(sortedMembers(members), id: \.id) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    /// 优先级分组流：紧急/高/中/低四组，方向翻转组序；同级内按截止时间早→晚
    @ViewBuilder
    private func priorityGroupedContent(_ groupingTasks: [TodoTask]) -> some View {
        let priorities = sortAscending
            ? TaskPriority.allCasesSorted.reversed()
            : TaskPriority.allCasesSorted

        ForEach(priorities, id: \.rawValue) { priority in
            let members = groupingTasks.filter { $0.taskPriority == priority }
            if !members.isEmpty {
                groupHeader(
                    id: "priority-\(priority.rawValue)",
                    title: priority.displayTitle,
                    dotColor: priority.color,
                    count: members.count
                )

                if !collapsedGroups.contains("priority-\(priority.rawValue)") {
                    ForEach(sortedMembers(members), id: \.id) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    /// 平铺流：不分组，全量按当前排序排
    @ViewBuilder
    private func flatContent(_ groupingTasks: [TodoTask]) -> some View {
        let sorted = sortedMembers(groupingTasks)
        if !sorted.isEmpty {
            SectionHeaderView(title: "按\(sortOption.title)排列", count: sorted.count)
            ForEach(sorted, id: \.id) { task in
                taskRow(task)
            }
        }
    }

    /// 组内排序：按当前排序方式（空值恒沉底、并列次级兜底由比较器保证）
    private func sortedMembers(_ members: [TodoTask]) -> [TodoTask] {
        members.sorted { sortOption.areInOrder($0, $1, ascending: sortAscending) }
    }

    /// 分组头：语义色点 + 组名 + 计数 + 折叠箭头
    private func groupHeader(id: String, title: String, dotColor: Color, count: Int) -> some View {
        let isCollapsed = collapsedGroups.contains(id)

        return Button {
            HapticManager.selection()
            withAnimation(.easeInOut(duration: 0.22)) {
                if isCollapsed {
                    collapsedGroups.remove(id)
                } else {
                    collapsedGroups.insert(id)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.holoBorder))

                if isCollapsed && count > 3 {
                    Text("已折叠")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.77))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, HoloSpacing.xs)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 已完成 Tab 内容

    /// 已完成 tab：按周分组展示（周序固定近→远），组内顺序由当前排序决定
    @ViewBuilder
    private var completedTabContent: some View {
        let weekGroups = completedTasksGroupedByWeek
        ForEach(weekGroups, id: \.title) { group in
            SectionHeaderView(title: group.title, count: group.tasks.count)
            ForEach(sortedMembers(group.tasks), id: \.id) { task in
                taskRow(task)
            }
        }
    }

    // MARK: - 任务行组件

    /// 可复用的任务卡片行（含滑动操作）
    private func taskRow(_ task: TodoTask) -> some View {
        SwipeActionView(
            isRevealed: Binding(
                get: { revealedTaskId == task.id },
                set: { if $0 { revealedTaskId = task.id } else { revealedTaskId = nil } }
            ),
            content: {
                TaskCardView(
                    task: task,
                    repository: repository,
                    onNavigate: {
                        if revealedTaskId == task.id {
                            revealedTaskId = nil
                        } else {
                            selectedTask = TaskSelection(id: task.id)
                        }
                    },
                    isCompleting: pendingCompletionTaskId == task.id,
                    onToggleCompletion: {
                        if task.completed {
                            // 已完成 → 直接取消完成
                            do {
                                try repository.toggleTaskCompletion(task)
                                HapticManager.medium()
                            } catch {
                                Logger(subsystem: "com.holo.app", category: "TaskListView").error("取消完成失败: \(error.localizedDescription)")
                            }
                        } else if pendingCompletionTaskId == task.id {
                            // 撤回窗口内再点完成圈/反勾子项 → 撤回完成
                            undoCompletion()
                        } else {
                            // 未完成 → 走撤回流程
                            handleTaskCompletion(task)
                        }
                    }
                )
            },
            onArchive: {
                archiveTask(task)
            },
            onDelete: {
                deleteTask(task)
            }
        )
        .padding(.bottom, 10)
    }

    // MARK: - 撤回 banner

    private var undoBanner: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoSuccess)
                Text("任务已完成")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }

            Spacer()

            Button {
                undoCompletion()
            } label: {
                Text("撤回")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - 数据加载

    /// 处理 Deep Link 跳转
    /// 冷启动由 .onAppear 触发，热启动/后台由 .onChange 触发
    private func handleDeepLink() {
        guard case .taskDetail(let taskId) = deepLinkState.pendingTarget else { return }
        // 延迟确保 fullScreenCover 视图层级完全就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 防御性清空：确保 sheet 能重新弹出（避免 @State 残留导致相同值不触发）
            if self.selectedTask != nil {
                self.selectedTask = nil
                DispatchQueue.main.async {
                    self.selectedTask = TaskSelection(id: taskId)
                }
            } else {
                self.selectedTask = TaskSelection(id: taskId)
            }
            self.deepLinkState.pendingTarget = nil
        }
    }

    private func loadTasks() {
        tasks = repository.activeTasks
        loadTodayProgress()
        updateFilteredTasks()
        hasLoadedOnce = true
    }

    private func loadTodayProgress() {
        todayProgress = repository.getTodayTaskProgress()
    }

    // MARK: - 完成任务（带撤回，使用全局撤回状态）

    /// 处理任务完成：启动 3 秒撤回窗口（全局状态，跨界面一致）
    private func handleTaskCompletion(_ task: TodoTask) {
        repository.startPendingCompletion(for: task)
        HapticManager.taskCompletion()
    }

    /// 撤回任务完成
    private func undoCompletion() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            repository.undoPendingCompletion()
        }
        HapticManager.light()
    }

    // MARK: - 滑动操作

    /// 归档任务
    private func archiveTask(_ task: TodoTask) {
        do {
            try repository.archiveTask(task)
            withAnimation(.easeInOut(duration: 0.25)) {
                revealedTaskId = nil
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "TaskListView").error("归档任务失败: \(error.localizedDescription)")
        }
    }

    /// 删除任务
    private func deleteTask(_ task: TodoTask) {
        do {
            try repository.deleteTask(task)
            withAnimation(.easeInOut(duration: 0.25)) {
                revealedTaskId = nil
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "TaskListView").error("删除任务失败: \(error.localizedDescription)")
        }
    }

    /// 更新过滤结果（缓存）
    private func updateFilteredTasks() {
        let pendingId = pendingCompletionTaskId
        switch selectedFilter {
        case .all:
            cachedFilteredTasks = tasks
        case .inbox:
            cachedFilteredTasks = tasks.filter { $0.list == nil }
        case .today:
            // 今日视图 = 今天到期 + 未完成的过期任务（拖过来的事也是今天的事）
            cachedFilteredTasks = tasks.filter { $0.isDueToday || $0.isOverdue }
        case .completed:
            cachedFilteredTasks = tasks.filter { $0.completed }
        case .overdue:
            // 撤回窗口期间，把 pending 任务从过期列表中排除（它在视觉上已完成）
            cachedFilteredTasks = tasks.filter { $0.isOverdue && $0.id != pendingId }
        case .list(let listId):
            cachedFilteredTasks = tasks.filter { $0.list?.id == listId }
        }
    }

    // MARK: - 排序偏好

    /// 当前上下文的默认排序（主列表=截止时间早→晚，已完成页=完成时间最近在前）
    private var contextDefaultSort: TaskSortOption {
        selectedFilter == .completed ? .completed : .due
    }

    /// 当前筛选下可选的排序方式（完成时间只在已完成页出现并置顶）
    private var availableSortOptions: [TaskSortOption] {
        if selectedFilter == .completed {
            return [.completed, .due, .priority, .created]
        }
        return [.due, .priority, .created]
    }

    /// 从持久化槽位装填当前筛选的排序偏好（主列表与已完成页各一份）
    private func restoreSortPreference() {
        if selectedFilter == .completed {
            sortOption = TaskSortOption(rawValue: completedSortOptionRaw) ?? .completed
            sortAscending = completedSortAscendingRaw
        } else {
            sortOption = TaskSortOption(rawValue: mainSortOptionRaw) ?? .due
            sortAscending = mainSortAscendingRaw
        }
    }

    /// 应用排序选择：立即持久化到当前上下文对应槽位，并带重排动画
    private func applySort(_ option: TaskSortOption, ascending: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            sortOption = option
            sortAscending = ascending
        }
        if selectedFilter == .completed {
            completedSortOptionRaw = option.rawValue
            completedSortAscendingRaw = ascending
        } else {
            mainSortOptionRaw = option.rawValue
            mainSortAscendingRaw = ascending
        }
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            if selectedFilter == .today {
                Image(systemName: "sparkles")
                    .font(.system(size: 52, weight: .light))
                    .foregroundColor(.holoPrimary.opacity(0.6))

                Text("今天没有待办")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)

                Text("享受轻松的一天，或点右下角 + 计划一件事")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            } else {
                Image(systemName: "checklist")
                    .font(.system(size: 60, weight: .light))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                Text("暂无任务")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)

                Text("点击右下角 + 创建第一个任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            }
        }
        .padding(.top, 80)
    }

    // MARK: - 已完成任务按周分组

    /// 已完成任务按周分组（用于「已完成」tab）；组内排序统一交给 sortedMembers
    private var completedTasksGroupedByWeek: [(title: String, tasks: [TodoTask])] {
        let completedTasks = cachedFilteredTasks.filter { $0.completed }

        let calendar = Calendar.current
        var groups: [Date: [TodoTask]] = [:]

        for task in completedTasks {
            guard let completedAt = task.completedAt else {
                groups[.distantPast, default: []].append(task)
                continue
            }
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: completedAt)
            )!
            groups[weekStart, default: []].append(task)
        }

        let sortedWeeks = groups.keys.sorted(by: >)
        return sortedWeeks.map { weekStart in
            (title: weekTitle(for: weekStart), tasks: groups[weekStart]!)
        }
    }

    /// 生成周标题
    private func weekTitle(for weekStart: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let currentWeekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        )!

        if weekStart == currentWeekStart {
            return "本周"
        }

        if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeekStart),
           weekStart == lastWeekStart {
            return "上周"
        }

        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"
    }

    /// 最近已完成折叠抽屉
    @ViewBuilder
    private func recentlyCompletedSection(_ tasks: [TodoTask]) -> some View {
        let maxCollapsed = 3
        let needsCollapse = tasks.count > maxCollapsed

        VStack(spacing: 0) {
            // 标题栏（可点击折叠/展开）
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isRecentlyCompletedExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("最近已完成")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Text("\(tasks.count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)

                    if needsCollapse {
                        Image(systemName: isRecentlyCompletedExpanded ? "chevron.up" : "chevron.down")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, HoloSpacing.md)

            // 任务列表
            let displayed = isRecentlyCompletedExpanded ? tasks : Array(tasks.prefix(maxCollapsed))
            ForEach(displayed, id: \.id) { task in
                taskRow(task)
            }

            // 展开/收起按钮
            if needsCollapse && !isRecentlyCompletedExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isRecentlyCompletedExpanded = true
                    }
                } label: {
                    Text("还有 \(tasks.count - maxCollapsed) 项")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isRecentlyCompletedExpanded)
    }

    /// 判断任务是否在最近一周内完成
    private func isCompletedRecently(_ task: TodoTask) -> Bool {
        guard let completedAt = task.completedAt else { return false }
        return completedAt >= Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    }
}

// MARK: - Task Sort Sheet

/// 排序方式弹层：选项随当前筛选动态增减，即点即生效（不关闭，方便继续调方向）
/// 视觉语言与记账弹层同源：居中标题 + 左关闭/右完成、卡片白底、行间细分隔线
private struct TaskSortSheet: View {
    let availableOptions: [TaskSortOption]
    @Binding var sortOption: TaskSortOption
    @Binding var sortAscending: Bool
    let onPick: (TaskSortOption, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
                .padding(.bottom, HoloSpacing.sm)

            Divider()
                .overlay(Color.holoDivider)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(availableOptions) { option in
                        optionRow(option)
                    }

                    directionSection

                    Divider()
                        .overlay(Color.holoDivider)
                        .padding(.top, HoloSpacing.md)

                    resetButton
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.xs)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // detent 区域整体铺卡片白，杜绝内容不满时露出系统底色的断层
        .background(Color.holoCardBackground)
    }

    /// 顶栏：居中标题 + 左关闭 + 右完成（与记账弹层同构）
    private var topBar: some View {
        ZStack {
            Text("排序方式")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.holoBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.holoBody)
                        .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 44)
    }

    /// 方向切换：文案随维度说人话
    private var directionSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("「\(sortOption.title)」的排列方向")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Picker("", selection: directionBinding) {
                Text(sortOption.directionLabel(ascending: true)).tag(true)
                Text(sortOption.directionLabel(ascending: false)).tag(false)
            }
            .pickerStyle(.segmented)
        }
        .padding(.top, HoloSpacing.md)
    }

    /// 恢复当前上下文的默认排序
    private var resetButton: some View {
        Button {
            let defaultOption = availableOptions.first == TaskSortOption.completed
                ? TaskSortOption.completed
                : TaskSortOption.due
            onPick(defaultOption, defaultOption.defaultAscending)
        } label: {
            Text("恢复默认排序")
                .font(.holoBody)
                .foregroundColor(.holoError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    /// 方向切换的 binding：切方向时保持当前排序方式
    private var directionBinding: Binding<Bool> {
        Binding(
            get: { sortAscending },
            set: { ascending in
                onPick(sortOption, ascending)
            }
        )
    }

    @ViewBuilder
    private func optionRow(_ option: TaskSortOption) -> some View {
        let isSelected = sortOption == option

        Button {
            // 换排序方式时方向重置为该维度的直觉默认方向
            onPick(option, option.defaultAscending)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: option.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? Color.holoPrimary.opacity(0.10) : Color.holoBackground)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.holoBody.weight(isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .holoPrimaryDark : .holoTextPrimary)
                        Text(option.subtitle)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.holoPrimary)
                    }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())

                // 行间细分隔线，与文字左缘对齐
                Rectangle()
                    .fill(Color.holoDivider)
                    .frame(height: 0.5)
                    .padding(.leading, 44)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section Header View

/// 分组标题视图（已完成 tab 按周分组用）
private struct SectionHeaderView: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            Text("\(count)")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.top, HoloSpacing.md)
    }
}

// MARK: - Task Not Found Fallback

/// DeepLink 目标任务未找到时的兜底视图
/// 短暂等待（落库可能稍后完成），仍找不到则自动关闭 sheet，避免用户被困在无返回按钮的页面
private struct TaskNotFoundView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "trash.slash")
                .font(.system(size: 28))
                .foregroundColor(.holoTextSecondary)
            Text("该任务已被删除")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground.ignoresSafeArea())
        .onAppear {
            // 短暂展示「已删除」后自动关闭
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                onDismiss()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TaskListView(repository: TodoRepository.shared, onBack: {})
}
