//
//  TasksView.swift
//  Holo
//
//  待办模块入口视图 - 包含底部导航栏（统计/任务/新增）
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI

// MARK: - Todo Tab 枚举

/// 待办模块底部 Tab 枚举
enum TodoTab: String, CaseIterable {
    case stats = "统计"
    case tasks = "任务"
    case anniversary = "纪念日"
    case add = "新增"

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .stats: return "chart.bar.fill"
        case .tasks: return "checklist"
        case .anniversary: return "heart.text.square.fill"
        case .add: return "plus"
        }
    }

    /// 是否是新增按钮（特殊样式）
    var isAddButton: Bool {
        self == .add
    }
}

// MARK: - TasksView

/// 待办功能首页视图（容器）
/// 管理三个子 Tab：统计分析、任务列表、新增
/// 支持从左边缘向右滑动返回首页
struct TasksView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @State private var selectedTab: TodoTab = .tasks
    @State private var showAddTask: Bool = false
    @State private var showNotificationSettings: Bool = false
    /// 任务列表当前筛选，用于底部新增按钮继承「今日」或具体清单上下文。
    @State private var selectedTaskFilter: TaskFilterType = .today

    /// 直接使用单例，避免 @StateObject 创建新实例
    private var repository: TodoRepository { TodoRepository.shared }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .stats:
                    TaskStatsView(repository: repository, onBack: { close() })
                case .tasks:
                    TaskListView(
                        repository: repository,
                        onBack: { close() },
                        onFilterChanged: { selectedTaskFilter = $0 }
                    )
                case .anniversary:
                    AnniversaryListView(onBack: { close() })
                case .add:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss(isResidentScreenRoot: true) { close() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            todoTabBar
        }
        .sheet(isPresented: $showAddTask) {
            TaskDetailView(
                repository: repository,
                list: selectedListForNewTask,
                defaultDueDate: defaultDueDateForNewTask
            )
        }
    }

    /// 当前位于具体清单时，新任务直接归入该清单。
    private var selectedListForNewTask: TodoList? {
        guard case .list(let listId) = selectedTaskFilter else { return nil }
        return repository.findList(by: listId)
    }

    /// 当前位于「今日」时，新任务默认带上今天的全天截止日期。
    private var defaultDueDateForNewTask: Date? {
        guard selectedTaskFilter == .today else { return nil }
        return Calendar.current.startOfDay(for: Date())
    }

    // MARK: - 底部 Tab 栏

    /// 底部导航栏：吸底全宽，右侧为「+」新增
    private var todoTabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                ForEach(TodoTab.allCases, id: \.self) { tab in
                    todoTabButton(tab)
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

    /// 统一的 Tab 按钮
    private func todoTabButton(_ tab: TodoTab) -> some View {
        Button {
            if tab.isAddButton {
                if selectedTab == .anniversary {
                    // 纪念日 Tab：转发给纪念日页自带的新增 sheet（TasksView 若也挂 sheet
                    // 会与子视图的 sheet 叠层，导致不可见层拦截触摸）
                    NotificationCenter.default.post(name: .anniversaryRequestAdd, object: nil)
                } else {
                    showAddTask = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = tab
                }
            }
        } label: {
            VStack(spacing: 4) {
                // 顶部指示点（新增按钮不显示）
                Circle()
                    .fill(selectedTab == tab && !tab.isAddButton ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)

                // 图标
                if tab.isAddButton {
                    // 新增按钮特殊样式
                    Image(systemName: tab.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
                }

                // 标签
                Text(tab.rawValue)
                    .font(.holoTinyLabel)
                    .foregroundColor(tab.isAddButton ? .holoPrimary : (selectedTab == tab ? .holoPrimary : .holoTextSecondary))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview {
    TasksView()
}
