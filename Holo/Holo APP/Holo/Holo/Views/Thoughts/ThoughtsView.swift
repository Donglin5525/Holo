//
//  ThoughtsView.swift
//  Holo
//
//  观点模块 - 根视图容器
//  从首页 fullScreenCover 进入，顶部有返回按钮
//  知识树 v1：浏览切换收进 ThoughtListView（想法|知识树），旧侧边抽屉已移除
//  2026-09-24 方案 A1：侧栏形态（单内容流+抽屉侧栏）替代「想法/主题」双主模式。
//  侧栏已对所有用户开放，旧结构暂留作发布级回滚准备。
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
    /// 宽屏双栏判定：FAB 只在窄屏/手机出现（宽屏新建入口在列表顶部）
    @Environment(\.holoContentWidth) private var thoughtsWindowWidth
    private var isWideLayout: Bool { HoloAdaptiveLayout.isExpandedWidth(thoughtsWindowWidth) }

    /// 列表筛选意图（知识树视图「未归类/已归档」等入口驱动列表重载）
    @State private var drawerSelection: DrawerNode? = nil

    /// 侧栏形态：浏览范围唯一事实源（方案 §6.5）与开合状态
    @State private var scope: ThoughtBrowseScope = .all
    /// 侧栏位移唯一事实源（0=收起 … sidebarWidth=停靠开）。单一 CGFloat 保证
    /// 拖拽跟手、松手停靠/弹回全部可插值动画；旧的 Bool+dragOffset 合成会在
    /// 停靠瞬间瞬跳（Bool 不可插值）。
    @State private var sidebarOffset: CGFloat = 0
    /// 有卡片左滑按钮展开时，拉出侧栏手势让位（右滑优先收按钮，防双动）
    @State private var hasRevealedCard: Bool = false

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
        Group {
            if ThoughtSidebarRollout.isEnabled {
                sidebarContainerBody
            } else {
                legacyBody
            }
        }
        .task {
            // P1.5.7: 进入想法页时合并 CloudKit 同步产生的重复 Topic（幂等）
            _ = try? topicRepository.mergeDuplicateTopics()
            // 冷启动新心智的存量切换：撤掉创建超 7 天仍无想法的空预设主题（幂等，
            // 有想法的主题——用户真正建立过的体系——分毫不动）
            _ = try? topicRepository.pruneEmptyPresetTopics()
        }
        // fullScreenCover：编辑器作为完整页面承载，避免 sheet 下滑误触丢内容。
        // 必须显式写 onSave: —— 编辑器有多个可选闭包参数，trailing closure 会绑错
        // （实测绑到 onRequestClose，导致纸飞机退出失效、边缘手势被禁）。
        .fullScreenCover(isPresented: $showAddThought) {
            ThoughtEditorView(onSave: {
                // 保存后刷新列表
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            })
            .holoContentColumn()
        }
        .sheet(isPresented: $showConvergence) {
            ConvergenceConfirmView(
                job: convergenceJob,
                topicRepository: topicRepository,
                rejectionRepository: ConvergenceRejectionRepository()
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtRequestTagFilter)) { notification in
            // 编辑器/详情页「查看标签」：按该标签全路径筛选
            guard let path = notification.object as? String else { return }
            if ThoughtSidebarRollout.isEnabled {
                scope = .userTag(pathKey: ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(path)))
            } else {
                drawerSelection = .aiTag(path)
            }
        }
    }

    // MARK: - 侧栏形态容器（2026-09-24 方案 §5.5-5.10）

    /// 展开宽度：约容器 80%，上限 340（§5.8 首轮参数，真机校准）
    private var sidebarWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.8, 340)
    }

    /// 当前进度 0...1（拖拽中跟手，停靠后为 0 或 1）
    private var sidebarProgress: CGFloat {
        min(max(sidebarOffset / sidebarWidth, 0), 1)
    }

    /// 停靠开：进度到顶才算「开」，交互/AX/遮罩按它判（拖拽中不打开交互，
    /// 保持 2026-09-26「关闭态三通道全关」规则不回退）
    private var isSidebarDocked: Bool {
        sidebarOffset >= sidebarWidth - 0.5
    }

    private var currentContentOffset: CGFloat {
        sidebarProgress * sidebarWidth
    }

    private var sidebarContainerBody: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.holoBackground.ignoresSafeArea()

                // 底层：侧栏内容保持原宽，外层可见宽度与笔记层共用同一位移。
                // 拖动时只裁切，不重排标签行，避免文字换行和列表跳动。
                // z 序条件调换：开启态侧栏提到内容层之上——offset 只挪渲染不挪布局帧，
                // 内容层名义帧仍全屏盖着侧栏，若靠 allowsHitTesting(false) 穿透，
                // VoiceOver 焦点也进不了侧栏（§5.10 要求开启后焦点在侧栏）
                // 安全区（2026-09-25 真机修复）：内容遵守安全区（顶部让出状态栏、底部让出
                // home 横条），铺满全屏的只有背景色——曾整体 ignoresSafeArea 导致状态栏
                // 文字叠在侧栏行上、数据清理贴穿底部
                ThoughtSidebarView(
                    scope: $scope,
                    onSelect: { closeSidebar() })
                .frame(width: sidebarWidth)
                .background(Color.holoCardBackground.ignoresSafeArea())
                .frame(width: currentContentOffset, alignment: .leading)
                .clipShape(UnevenRoundedRectangle(
                    bottomTrailingRadius: HoloRadius.lg * sidebarProgress,
                    topTrailingRadius: HoloRadius.lg * sidebarProgress))
                // 可见范围跟着边界即时收缩；关闭态仍保持视觉、触摸、AX 三通道全关。
                .opacity(sidebarProgress > 0 ? 1 : 0)
                .allowsHitTesting(isSidebarDocked)
                .accessibilityHidden(!isSidebarDocked)
                .zIndex(sidebarProgress > 0.01 ? 1 : 0)

                // 前景：内容层整体跟手右移（列表+搜索+浮动"+"同一层，§5.5）
                contentLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.holoBackground)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: HoloRadius.lg * sidebarProgress,
                        bottomLeadingRadius: HoloRadius.lg * sidebarProgress))
                    .offset(x: currentContentOffset)
                    .shadow(color: .black.opacity(0.22 * Double(sidebarProgress)),
                            radius: 14, x: -4, y: 0)
                    .zIndex(sidebarProgress > 0.01 ? 0 : 1)
                    // 停靠开：遮罩挡住内容层交互（§5.9 侧栏开启时正文不响应点击/滚动），
                    // 点它即收起。横向关闭拖动由容器统一的 UIKit pan 处理，
                    // 不给侧栏 ScrollView 再叠 SwiftUI DragGesture。
                    .overlay {
                        if isSidebarDocked {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { closeSidebar() }
                                .accessibilityHidden(true)
                        }
                    }
            }
            // 抽屉只在宿主可见区域内排版。列表内容或侧栏节点的理想宽度
            // 不能反向撑大 ZStack，否则父容器居中后会让侧栏逐次右移。
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
        }
        // 侧栏开启后整个区域的左滑统一关闭；方向锁使标签树纵向滚动不受影响。
        .modifier(SidebarClosePanModifier(
            isEnabled: sidebarOffset > 0,
            onTranslate: { sidebarOffset = min(max(sidebarWidth + $0, 0), sidebarWidth) },
            onEnd: { translation, velocity in
                let shouldClose = sidebarWidth + translation < sidebarWidth * 0.62
                    || velocity < -600
                withAnimation(shouldClose ? HoloAnimation.snappy : HoloAnimation.grounded) {
                    sidebarOffset = shouldClose ? 0 : sidebarWidth
                }
            }))
        // 三段分区（中部右滑=拉出标签树）：停靠开/有展开卡片/宽屏时不启用；
        // 左缘 28pt 与横滚容器（筛选 chips）的让位在 modifier 内部判定。
        // 拖动中卡片滑动已被下方 swipeGesturesEnabled 门控掐掉。
        .modifier(SidebarOpenPanModifier(
            isEnabled: !isSidebarDocked && !hasRevealedCard && !isWideLayout,
            onTranslate: { sidebarOffset = min(max($0, 0), sidebarWidth) },
            onEnd: { translation, velocity in
                let shouldOpen = translation > sidebarWidth * 0.25 || velocity > 500
                withAnimation(shouldOpen ? HoloAnimation.snappy : HoloAnimation.grounded) {
                    sidebarOffset = shouldOpen ? sidebarWidth : 0
                }
            }))
        // 左缘右滑遵循全 App 的返回手势。三段分区（2026-09-26 东林拍板）：
        // 恒可用——侧栏开着也从左缘右滑一步直达首页，侧栏随模块整体退场，
        // 退场后重置侧栏，再次进入是干净的想法流。
        .swipeBackToDismiss(isEnabled: true, isResidentScreenRoot: true) {
            close()
            sidebarOffset = 0
        }
    }

    private func closeSidebar() {
        withAnimation(HoloAnimation.snappy) {
            sidebarOffset = 0
        }
    }

    /// scope ↔ 既有 DrawerNode 通道桥（复用列表筛选重载链 reloadByDrawer）
    private var scopeDrawerBinding: Binding<DrawerNode?> {
        Binding(
            get: { scope.drawerNode },
            set: { newValue in
                if let node = newValue, let converted = ThoughtBrowseScope(from: node) {
                    scope = converted
                } else if newValue == nil {
                    scope = .all
                }
                // aiOrganize/unclassified 等侧栏没有的节点：不动 scope（防御，当前无触发源）
            })
    }

    private var contentLayer: some View {
        // 侧栏开启/拖动中（progress>1%）必须掐掉卡片滑动手势，见下方 SwipeActionView 注释
        let gateEnabled = sidebarProgress < 0.01
        return ZStack {
            ThoughtListView(
                onBack: { close() },
                onAIOrganize: { startTopicConvergence() },
                showAddThought: $showAddThought,
                drawerSelection: scopeDrawerBinding,
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                initialThoughtId: initialThoughtId,
                onOpenSidebar: { withAnimation(HoloAnimation.snappy) { sidebarOffset = sidebarWidth } },
                // 侧栏开启/拖动中必须掐掉卡片滑动手势：SwipeActionView 的 pan 挂在
                // window 上只认「手指位置在卡片区域」，遮罩拦不住它——不禁用的话
                // 关侧栏的左拖会被当成卡片左滑，100% 带出归档/删除按钮（2026-09-26 真机实报）
                swipeGesturesEnabled: gateEnabled,
                // 卡片按钮展开状态上报：展开时中部右滑让位给「收按钮」（防双动）
                onRevealedCardChange: { hasRevealedCard = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右下角浮动新增按钮：属于内容层，随层移动（§5.5）；宽屏退役（入口在列表顶部）
            if !isWideLayout {
                addButton
                    .zIndex(30)
            }
        }
    }

    // MARK: - 旧导航形态（回滚通道，结构保持原样）

    private var legacyBody: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            ThoughtListView(
                onBack: { close() },
                onAIOrganize: { startTopicConvergence() },
                showAddThought: $showAddThought,
                drawerSelection: $drawerSelection,
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                initialThoughtId: initialThoughtId)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右下角浮动新增按钮（替代原来的假 Tab）。
            // 宽屏双栏下退役（挡双栏内容），新建入口上移到列表顶部——设计稿④
            if !isWideLayout {
                addButton
                    .zIndex(30)
            }
        }
        .swipeBackToDismiss(isEnabled: true, isResidentScreenRoot: true) { close() }
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
                .accessibilityLabel(String(localized: "新增想法"))
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
