//
//  HabitsView.swift
//  Holo
//
//  习惯功能首页 - 包含底部导航栏（统计/习惯/新增）
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI

// MARK: - Habit Tab 枚举

/// 习惯模块底部 Tab 枚举
enum HabitTab: String, CaseIterable {
    case stats = "统计"
    case habits = "习惯"
    case add = "新增"
    
    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .stats: return "chart.bar.fill"
        case .habits: return "checkmark.circle.fill"
        case .add: return "plus"
        }
    }
}

// MARK: - HabitsView

/// 习惯功能首页视图（容器）
/// 管理三个子 Tab：统计分析、习惯列表、新增
/// 支持从左边缘向右滑动返回首页
struct HabitsView: View {
    
    // MARK: - Properties
    
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: HabitTab = .habits
    @State private var showAddHabit: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .stats:
                    HabitStatsView(onBack: { dismiss() })
                case .habits:
                    HabitListView(
                        onBack: { dismiss() },
                        showAddHabit: $showAddHabit
                    )
                case .add:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss { dismiss() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            habitTabBar
        }
        .sheet(isPresented: $showAddHabit) {
            AddHabitSheet()
        }
    }
    
    // MARK: - 底部 Tab 栏
    
    /// 底部导航栏：吸底全宽，右侧为「+」新增
    private var habitTabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                habitTabButton(.stats)
                habitCenterTabButton
                habitAddButton
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
    
    /// 普通 Tab 按钮
    private func habitTabButton(_ tab: HabitTab) -> some View {
        Button {
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
    
    /// 中间 Tab：习惯列表
    private var habitCenterTabButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = .habits
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == .habits ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)
                
                Image(systemName: HabitTab.habits.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selectedTab == .habits ? .holoPrimary : .holoTextSecondary)
                
                Text(HabitTab.habits.rawValue)
                    .font(.holoTinyLabel)
                    .foregroundColor(selectedTab == .habits ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    /// 右侧新增按钮
    private var habitAddButton: some View {
        Button {
            showAddHabit = true
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 4, height: 4)
                
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.holoPrimary)
                    .clipShape(Circle())
                
                Text("新增")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
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

/// 习惯列表页面
struct HabitListView: View {
    
    // MARK: - Properties
    
    let onBack: () -> Void
    @Binding var showAddHabit: Bool
    
    /// 习惯列表（本地缓存，避免直接绑定 @MainActor 单例）
    @State private var habits: [Habit] = []
    /// 今日进度
    @State private var todayProgress: (completed: Int, total: Int) = (0, 0)
    
    /// 选中的习惯（用于 sheet 展示，避免删除后持有已释放对象）
    private struct HabitSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedHabit: HabitSelection? = nil
    /// 待执行操作（在 onDismiss 中执行，确保 sheet 完全销毁后再操作 Core Data）
    @State private var pendingAction: PendingHabitAction? = nil
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(habits) { habit in
                        HabitCardView(habit: habit)
                            .onTapGesture {
                                selectedHabit = HabitSelection(id: habit.id)
                            }
                    }
                    
                    if habits.isEmpty {
                        emptyStateView
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .onAppear {
            loadHabits()
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
        Task { @MainActor in
            let repo = HabitRepository.shared
            habits = repo.activeHabits
            todayProgress = repo.getTodayCheckInProgress()
        }
    }
    
    // MARK: - 顶部导航栏
    
    private var headerView: some View {
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
            
            // 标题
            Text("习惯")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            
            Spacer()
            
            // 今日进度
            Text("\(todayProgress.completed)/\(todayProgress.total)")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }
    
    // MARK: - 空状态
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            
            Text("还没有习惯")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            
            Text("点击右下角 + 创建第一个习惯")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .padding(.top, 80)
    }
}

// MARK: - Preview

#Preview {
    HabitsView()
}
