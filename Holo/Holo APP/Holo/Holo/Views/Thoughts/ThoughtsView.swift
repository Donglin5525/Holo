//
//  ThoughtsView.swift
//  Holo
//
//  观点模块 - 根视图容器
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI
import CoreData

// MARK: - Thought Tab 枚举

/// 观点模块底部 Tab 枚举
enum ThoughtTab: String, CaseIterable {
    case list = "列表"
    case add = "新增"

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .add: return "plus"
        }
    }
}

// MARK: - ThoughtsView

/// 观点模块根视图
/// 管理观点模块的主界面
struct ThoughtsView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: ThoughtTab = .list
    @State private var showAddThought: Bool = false

    /// 知识树抽屉开关
    @State private var isDrawerOpen: Bool = false
    /// 抽屉当前选中节点（右侧列表筛选意图）
    @State private var drawerSelection: DrawerNode? = nil

    /// P2.3: 跨观点归并任务（「AI 整理」触发）
    @StateObject private var convergenceJob: ThoughtTagConvergenceJob
    /// P2.3: 归并确认页开关
    @State private var showConvergence: Bool = false

    private let thoughtRepository = ThoughtRepository()
    private let topicRepository = TopicRepository()
    let initialThoughtId: UUID?

    init(initialThoughtId: UUID? = nil) {
        self.initialThoughtId = initialThoughtId
        self._convergenceJob = StateObject(wrappedValue: ThoughtTagConvergenceJob.shared)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .list:
                    ThoughtListView(
                        onBack: { dismiss() },
                        onMenuTap: { openDrawer() },
                        onAIOrganize: { startTopicConvergence(autoApply: true) },
                        showAddThought: $showAddThought,
                        drawerSelection: $drawerSelection,
                        thoughtRepository: thoughtRepository,
                        topicRepository: topicRepository,
                        initialThoughtId: initialThoughtId,
                        swipeActionsEnabled: !isDrawerOpen
                    )
                case .add:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!isDrawerOpen)  // 抽屉打开时禁用下层观点列表交互，防误触发卡片右滑删除

            drawerLayer
        }
        .task {
            // P1.5.7: 进入观点页时合并 CloudKit 同步产生的重复 Topic（幂等）
            _ = try? topicRepository.mergeDuplicateTopics()
        }
        .swipeBackToDismiss(isEnabled: !isDrawerOpen) { dismiss() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            thoughtTabBar
        }
        .sheet(isPresented: $showAddThought) {
            ThoughtEditorView {
                // 保存后刷新列表
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            }
        }
        .sheet(isPresented: $showConvergence) {
            ConvergenceConfirmView(
                job: convergenceJob,
                topicRepository: topicRepository,
                rejectionRepository: ConvergenceRejectionRepository()
            )
        }
    }

    // MARK: - 抽屉控制

    /// 打开知识树抽屉
    private func openDrawer() {
        withAnimation(.easeInOut(duration: 0.25)) { isDrawerOpen = true }
    }

    /// 关闭知识树抽屉
    private func closeDrawer() {
        withAnimation(.easeInOut(duration: 0.25)) { isDrawerOpen = false }
    }

    /// 知识树抽屉层：打开后固定吸附左侧，不跟随内容区手势漂移。
    @ViewBuilder
    private var drawerLayer: some View {
        if isDrawerOpen {
            ZStack(alignment: .leading) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }

                ThoughtKnowledgeDrawerView(
                    selection: $drawerSelection,
                    thoughtRepository: thoughtRepository,
                    topicRepository: topicRepository,
                    onSelect: { node in
                        drawerSelection = node
                        closeDrawer()  // 点筛选节点立即收起抽屉，让用户看右侧列表
                    },
                    onAIOrganize: {
                        closeDrawer()
                        startTopicConvergence(autoApply: true)
                    }
                )

                RightEdgeCloseOverlay(isEnabled: true, onClose: closeDrawer)
                    .ignoresSafeArea()
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// 统一的主题归纳入口：外层「自动整理」和知识树「归纳主题」都走这里
    private func startTopicConvergence(autoApply: Bool) {
        Task { await convergenceJob.run(autoApply: autoApply, persist: autoApply) }
        showConvergence = true
    }

    // MARK: - 底部 Tab 栏

    /// 底部导航栏
    private var thoughtTabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                // 列表 Tab
                thoughtTabButton(.list)

                // 新增按钮
                thoughtAddButton
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
    private func thoughtTabButton(_ tab: ThoughtTab) -> some View {
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

    /// 右侧新增按钮
    private var thoughtAddButton: some View {
        Button {
            showAddThought = true
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

// MARK: - Preview

#Preview {
    ThoughtsView()
}
