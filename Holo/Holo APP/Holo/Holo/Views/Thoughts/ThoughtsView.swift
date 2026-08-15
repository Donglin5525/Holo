//
//  ThoughtsView.swift
//  Holo
//
//  观点模块 - 根视图容器
//  从首页 fullScreenCover 进入，顶部有返回按钮
//  知识树 v1：浏览切换收进 ThoughtListView（时间流|知识树），旧侧边抽屉已移除
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

    /// 列表筛选意图（知识树视图「未归类/已归档」等入口驱动列表重载）
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
                onAIOrganize: { startTopicConvergence() },
                showAddThought: $showAddThought,
                drawerSelection: $drawerSelection,
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                initialThoughtId: initialThoughtId
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右下角浮动新增按钮（替代原来的假 Tab）
            addButton
                .zIndex(30)
        }
        .task {
            // P1.5.7: 进入观点页时合并 CloudKit 同步产生的重复 Topic（幂等）
            _ = try? topicRepository.mergeDuplicateTopics()
        }
        .swipeBackToDismiss(isEnabled: true, isResidentScreenRoot: true) { close() }
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
            UserDefaults.standard.set("timeline", forKey: ThoughtListView.browseModeStorageKey)
            drawerSelection = .aiTag(path)
        }
    }

    /// 统一的主题归纳入口：知识树「发现新主题」走这里
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
