//
//  ThoughtsView.swift
//  Holo
//
//  观点模块 - 根视图容器
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI
import CoreData

// MARK: - ThoughtsView

/// 观点模块根视图
/// 管理观点模块的主界面
struct ThoughtsView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
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

            ThoughtListView(
                onBack: { close() },
                onMenuTap: { openDrawer() },
                onAIOrganize: { startTopicConvergence() },
                showAddThought: $showAddThought,
                drawerSelection: $drawerSelection,
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                initialThoughtId: initialThoughtId,
                swipeActionsEnabled: !isDrawerOpen
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!isDrawerOpen)  // 抽屉打开时禁用下层观点列表交互，防误触发卡片右滑删除

            // 右下角浮动新增按钮（替代原来的假 Tab）
            if !isDrawerOpen {
                addButton
                    .zIndex(30)
            }

            drawerLayer
        }
        .task {
            // P1.5.7: 进入观点页时合并 CloudKit 同步产生的重复 Topic（幂等）
            _ = try? topicRepository.mergeDuplicateTopics()
        }
        .swipeBackToDismiss(isEnabled: !isDrawerOpen, isResidentScreenRoot: true) { close() }
        // fullScreenCover：编辑器作为完整页面承载，避免 sheet 下滑误触丢内容
        .fullScreenCover(isPresented: $showAddThought) {
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
        .onReceive(NotificationCenter.default.publisher(for: .thoughtRequestTagFilter)) { notification in
            // 编辑器/详情页「查看标签」：列表按该标签路径筛选
            guard let path = notification.object as? String else { return }
            drawerSelection = .aiTag(path)
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
                        startTopicConvergence()
                    }
                )

                RightEdgeCloseOverlay(isEnabled: true, onClose: closeDrawer)
                    .ignoresSafeArea()
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// 统一的主题归纳入口：外层「自动整理」和知识树「归纳主题」都走这里
    private func startTopicConvergence() {
        showConvergence = true
        // 自动观察已有建议时直接展示，避免重复调用覆盖 ready 状态。
        if case .ready = convergenceJob.state { return }
        Task { await convergenceJob.run(autoApply: false, persist: false) }
    }

    // MARK: - 底部 Tab 栏

    /// 右下角浮动新增按钮（替代原底部假 Tab）
    private var addButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showAddThought = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.holoPrimary.opacity(0.35), radius: 12, x: 0, y: 6)
                }
                .accessibilityLabel("新增想法")
                .padding(.trailing, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Preview

#Preview {
    ThoughtsView()
}
