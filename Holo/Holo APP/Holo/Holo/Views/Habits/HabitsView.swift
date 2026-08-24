//
//  HabitsView.swift
//  Holo
//
//  习惯功能首页 - 包含底部导航栏（统计/习惯/设置）
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI

// MARK: - Habit Tab 枚举

/// 习惯模块底部 Tab 枚举
enum HabitTab: String, CaseIterable {
    case stats = "统计"
    case habits = "习惯"
    case settings = "设置"

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .stats: return "chart.bar.fill"
        case .habits: return "checkmark.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - HabitsView

/// 习惯功能首页视图（容器）
/// 管理三个子 Tab：统计分析、习惯列表、设置
/// 支持从左边缘向右滑动返回首页
struct HabitsView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @State private var selectedTab: HabitTab = .habits
    @State private var previousTab: HabitTab = .habits
    /// 新建习惯入口（nil = 关闭；带内容的草稿来自空状态示例磁贴）
    @State private var addHabitDraft: HabitPrefillDraft? = nil
    /// 统计状态由模块根视图持有，切换 Tab 后保留月份与展开项。
    @StateObject private var statsState = HabitStatsState()
    @ObservedObject private var deepLinkState = DeepLinkState.shared
    @State private var requestedHabitId: UUID?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .stats:
                    HabitStatsView(onBack: { close() }, state: statsState)
                case .habits:
                    HabitListView(
                        onBack: { close() },
                        addHabitDraft: $addHabitDraft,
                        requestedHabitId: $requestedHabitId
                    )
                case .settings:
                    HabitStatsSettingsView(onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = previousTab
                        }
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss(isResidentScreenRoot: true) { close() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            habitTabBar
        }
        .sheet(item: $addHabitDraft) { draft in
            AddHabitSheet(prefill: draft)
        }
        .onAppear {
            handleDeepLink(deepLinkState.pendingTarget)
        }
        .onChange(of: deepLinkState.pendingTarget) { _, target in
            handleDeepLink(target)
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        guard case .habitDetail(let habitId) = target else { return }
        selectedTab = .habits
        requestedHabitId = habitId
        deepLinkState.pendingTarget = nil
    }

    // MARK: - 底部 Tab 栏

    /// 底部导航栏：统计 / 习惯 / 设置
    private var habitTabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                ForEach(HabitTab.allCases, id: \.self) { tab in
                    habitTabButton(tab)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, bottomInset)
            .background(
                Color.holoCardBackground
                    .shadow(color: HoloShadow.card, radius: 10, x: 0, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground.ignoresSafeArea(edges: .bottom))
        .zIndex(40)
    }

    /// Tab 按钮
    private func habitTabButton(_ tab: HabitTab) -> some View {
        Button {
            if tab != selectedTab {
                previousTab = selectedTab
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)

                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)

                Text(tab.rawValue)
                    .font(.holoTinyLabel)
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 待执行操作

/// 习惯删除/归档的待执行操作（在 sheet onDismiss 中执行）
enum PendingHabitAction {
    case delete(UUID)
    case archive(UUID)
}

// MARK: - HabitListView

/// 习惯列表页面（磁贴墙版）
struct HabitListView: View {

    // MARK: - Properties

    let onBack: () -> Void
    @Binding var addHabitDraft: HabitPrefillDraft?
    @Binding var requestedHabitId: UUID?
    @StateObject private var repository = HabitRepository.shared

    /// 习惯列表（本地缓存，避免直接绑定 @MainActor 单例）
    @State private var habits: [Habit] = []
    /// 今日进度
    @State private var todayProgress: (completed: Int, total: Int) = (0, 0)
    /// 本周点阵预缓存（habitId -> 逐日完成情况），磁贴渲染不单独查库
    @State private var weekPatterns: [UUID: [Bool]] = [:]
    /// 是否已完成首次加载（避免入场时空态先闪现、再被列表替换的分批出现感）
    @State private var hasLoadedOnce = false
    /// 庆祝波浪令牌：今日进度首次达到全部完成时 +1
    @State private var waveToken: Int = 0

    /// 选中的习惯（用于 sheet 展示，避免删除后持有已释放对象）
    private struct HabitSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedHabit: HabitSelection? = nil
    /// 长按菜单「编辑」的目标
    @State private var editTarget: Habit? = nil
    /// 待执行操作（在 onDismiss 中执行，确保 sheet 完全销毁后再操作 Core Data）
    @State private var pendingAction: PendingHabitAction? = nil

    /// 磁贴墙两列
    private let tileColumns = [
        GridItem(.flexible(), spacing: HoloSpacing.md),
        GridItem(.flexible(), spacing: HoloSpacing.md)
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                LazyVStack(spacing: HoloSpacing.md) {
                    // 还没有任何习惯时进度条无意义，直接进入空状态
                    if todayProgress.total > 0 {
                        HabitProgressHeader(
                            completed: todayProgress.completed,
                            total: todayProgress.total
                        )
                    }

                    if habits.isEmpty && hasLoadedOnce {
                        emptyStateView
                    } else {
                        LazyVGrid(columns: tileColumns, spacing: HoloSpacing.md) {
                            ForEach(Array(habits.enumerated()), id: \.element.id) { index, habit in
                                HabitTileView(
                                    habit: habit,
                                    index: index,
                                    weekPattern: weekPatterns[habit.id] ?? [],
                                    waveToken: waveToken,
                                    onOpenDetail: { selectedHabit = HabitSelection(id: habit.id) },
                                    onEdit: { editTarget = habit }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            // 编辑 sheet 必须挂在 ScrollView 节点：与详情 sheet 分属不同节点，
            // 同一视图挂两个 .sheet 会互相吞掉（踩坑速查表「sheet 关闭后界面异常」）
            .sheet(item: $editTarget) { habit in
                AddHabitSheet(editingHabit: habit)
            }
        }
        .task {
            guard !repository.isReady else {
                loadHabits()
                return
            }

            Task.detached(priority: .utility) {
                _ = CoreDataStack.shared.persistentContainer

                await MainActor.run {
                    repository.setup()
                    loadHabits()
                }
            }
        }
        .onAppear {
            loadHabits()
            openRequestedHabitIfNeeded()
        }
        .onChange(of: requestedHabitId) { _, _ in
            openRequestedHabitIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            loadHabits()
        }
        .sheet(item: $selectedHabit, onDismiss: {
            // 仅执行待执行操作，让通知系统自动更新 UI（避免 ForEach 问题）
            if let action = pendingAction {
                // 延迟执行，确保 sheet 完全销毁
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Task { @MainActor in
                        switch action {
                        case .delete(let id): try? HabitRepository.shared.deleteHabitById(id)
                        case .archive(let id): try? HabitRepository.shared.archiveHabitById(id)
                        }
                    }
                }
                pendingAction = nil
            }
            selectedHabit = nil
        }) { selection in
            if let habit = habits.first(where: { $0.id == selection.id }) {
                HabitDetailView(habit: habit, onWillDelete: { action in
                    pendingAction = action
                    selectedHabit = nil
                })
            } else {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 数据加载

    private func loadHabits() {
        // 必须同步执行：@Published activeHabits 更新会触发 objectWillChange，
        // 导致 SwiftUI 重渲染。如果用 Task 延迟更新 habits 数组，
        // 重渲染时 ForEach 会用旧数组（含已删除的 Core Data 对象）→ 崩溃
        if !repository.isReady {
            habits = []
            todayProgress = (0, 0)
            weekPatterns = [:]
            return
        }

        habits = repository.activeHabits
        let newProgress = repository.getTodayCheckInProgress()
        // 「从未全部完成 → 全部完成」的跳变触发庆祝波浪（仅一次）
        if newProgress.total > 0,
           todayProgress.total == newProgress.total,
           todayProgress.completed < newProgress.total,
           newProgress.completed == newProgress.total {
            waveToken += 1
        }
        todayProgress = newProgress
        weekPatterns = repository.getWeekCompletionPatterns()
        hasLoadedOnce = true
        openRequestedHabitIfNeeded()
    }

    private func openRequestedHabitIfNeeded() {
        guard let requestedHabitId else { return }
        if habits.contains(where: { $0.id == requestedHabitId }) {
            selectedHabit = HabitSelection(id: requestedHabitId)
            self.requestedHabitId = nil
        } else if hasLoadedOnce {
            // 列表已加载仍找不到：习惯已被删除/清除
            HoloToastCenter.shared.show("该习惯已被删除", type: .info)
            self.requestedHabitId = nil
        }
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Text("习惯")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 新增按钮（从底部导航移入习惯 Tab 内部）
            Button {
                addHabitDraft = HabitPrefillDraft()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.holoPrimary)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 空状态（示例磁贴）

    private struct SampleHabitTile: Identifiable {
        let name: String
        let icon: String
        let color: String
        var id: String { name }
    }

    private let sampleTiles = [
        SampleHabitTile(name: "散步", icon: "figure.walk", color: "#22C55E"),
        SampleHabitTile(name: "阅读", icon: "book.fill", color: "#F97316"),
        SampleHabitTile(name: "早睡", icon: "moon.fill", color: "#8B5CF6")
    ]

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.lg) {
            LazyVGrid(columns: tileColumns, spacing: HoloSpacing.md) {
                ForEach(sampleTiles) { sample in
                    Button {
                        addHabitDraft = HabitPrefillDraft(
                            name: sample.name,
                            icon: sample.icon,
                            color: sample.color
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: sample.icon)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(Color(hex: sample.color))

                            Text(sample.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.holoTextPrimary)

                            Text("点击创建")
                                .font(.system(size: 10))
                                .foregroundColor(.holoTextSecondary.opacity(0.8))

                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(minHeight: 118, alignment: .top)
                        .background(Color.holoCardBackground.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                                .stroke(
                                    Color(hex: sample.color).opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                )
                        )
                    }
                }
            }

            Text("点一块快速开始，或点右上角 ＋ 自定义")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .padding(.top, 40)
    }
}

// MARK: - Preview

#Preview {
    HabitsView()
}
