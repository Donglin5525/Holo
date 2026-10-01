//
//  ThoughtListView.swift
//  Holo
//
//  观点模块 - 列表视图
//  展示所有想法的列表，支持筛选
//

import SwiftUI
import CoreData
import OSLog

// MARK: - DrawerNode 筛选节点

/// 列表筛选意图载体（知识树视图/快捷入口通过它驱动列表重载）
enum DrawerNode: Hashable {
    case allNotes          // 全部笔记
    case unclassified      // 未归类（未进入任何 Topic）
    case aiTag(String)     // 标签池某标签（tagName，手动/正文/AI 同名统一）
    case topic(UUID)       // 某主题（topicId）
    case aiOrganize        // 归纳主题入口（非筛选，触发跨观点收敛）
    case archived          // 已归档（可找回、可恢复）
    case userTag(String)   // 侧栏「我的 #标签」（归一化全路径 key，§6.5 全路径口径）
}

// MARK: - ThoughtListView

/// 想法列表视图
struct ThoughtListView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtListView")

    // MARK: - Properties

    let onBack: () -> Void
    let onAIOrganize: () -> Void
    @Binding var showAddThought: Bool
    @Binding var drawerSelection: DrawerNode?
    let thoughtRepository: ThoughtRepository
    let topicRepository: TopicRepository
    let initialThoughtId: UUID?
    /// 侧栏形态：左上菜单按钮回调（打开抽屉侧栏）。nil = 旧导航形态。
    var onOpenSidebar: (() -> Void)? = nil
    /// 卡片滑动手势开关（侧栏开启/拖动中必须为 false：SwipeActionView 的 pan 挂
    /// window 上只认手指位置，遮罩拦不住，不禁会抢关闭手势并带出归档/删除）
    var swipeGesturesEnabled: Bool = true
    /// 卡片左滑按钮展开状态上报（三段分区：展开时「中部右斯拉侧栏」让位给收按钮）
    var onRevealedCardChange: ((Bool) -> Void)? = nil

    /// 筛选状态
    @State private var selectedTagName: String? = nil
    @State private var searchText: String = ""
    /// 语义搜索命中（id → 相似度；混合召回的语义半场）
    @State private var semanticSearchHits: [UUID: Float] = [:]
    /// 语义搜索防抖任务
    @State private var semanticSearchTask: Task<Void, Never>?
    /// Cmd+F 聚焦搜索栏（硬件键盘快捷键）
    @FocusState private var searchFieldFocused: Bool
    @State private var showFilterSheet: Bool = false
    @State private var currentFilters: ThoughtFilters? = nil

    /// 浏览模式：timeline 想法 / knowledge 知识树。
    /// 每次进入固定回到「想法」，不记忆上次的浏览模式（产品要求默认落在想法列表）。
    @State private var browseMode: String = "timeline"
    /// 浏览模式分段选中块的滑动命名空间
    @Namespace private var browseModeNamespace

    /// 知识树模式下的主题管理 sheet
    @State private var showTopicManagement: Bool = false

    /// 清空想法数据 sheet（数据清理功能，进 30 天回收站）
    @State private var showClearThoughtSheet: Bool = false

    /// 待确认池（想法列表 banner 入口）
    @State private var showConfirmationQueue: Bool = false

    /// 待确认数量（banner 徽章用）
    @State private var pendingConfirmationCount: Int = 0

    /// 选中的想法（窄屏全屏进编辑器；宽屏内联右栏）
    @State private var selectedThoughtId: UUID? = nil
    /// 从卡片「待确认」徽章进入编辑器时滚动到 AI 归类确认区（普通点卡片不滚动）
    @State private var selectedThoughtFocusConfirmation = false

    /// 所有想法
    @State private var thoughts: [Thought] = []

    /// 是否已完成首次加载（避免入场时空态先闪现、再被列表替换的分批出现感）
    @State private var hasLoadedOnce = false

    /// 所有标签
    @State private var allTags: [ThoughtTag] = []

    /// V3 新 UI：主题筛选 chips 的候选（可见主题，按最近活跃排序）
    @State private var filterTopics: [Topic] = []

    /// 侧栏形态：主题 id → 标题缓存（范围标题显示用）
    @State private var topicTitleCache: [UUID: String] = [:]
    /// 从侧栏选中主题后进入已有的主题详情，而不是只停留在筛选列表。
    @State private var selectedTopicId: UUID? = nil

    /// 右滑展开的卡片 ID
    @State private var revealedThoughtId: UUID? = nil

    /// 移入主题 sheet（P1.5.6）
    @State private var showTopicPicker: Bool = false
    @State private var topicPickerThoughtId: UUID? = nil

    /// 自动整理队列（观察批量进度）
    @ObservedObject private var orgQueue = ThoughtOrganizationQueue.shared

    /// 待整理数量（chip 徽章用）
    @State private var unprocessedCount: Int = 0

    /// 是否显示批量整理确认 Sheet
    @State private var showBatchOrganizeSheet: Bool = false

    /// 批量整理提示文案（toast，nil 不显示）
    @State private var batchOrganizeNotice: String? = nil

    /// P1 归入回执：AI 主题归类落库后的一次性短暂 toast（主题标题，nil 不显示）
    @State private var topicReceiptTitle: String? = nil
    @State private var topicReceiptTask: Task<Void, Never>? = nil

    /// 用户从外层「自动整理」启动批量标签整理后，完成时继续归纳主题
    @State private var shouldRunTopicConvergenceAfterBatch: Bool = false

    /// 列表刷新节流任务（避免批量整理时通知风暴拖卡主线程）
    @State private var refreshTask: Task<Void, Never>?
    /// 标签 emoji 显示刷新 tick（2026-09-26 emoji 功能）
    @State private var emojiDisplayTick: Int = 0
    /// P0 卡片分级判定：用户认可标签集合（归一化 key），列表层一次查询避免逐卡片 N+1
    @State private var recognizedTagKeys: Set<String> = []

    /// 宽屏双栏（v2 设计稿③）：expanded 档列表+详情同屏（46:54），不再全屏跳转；
    /// 11 寸竖屏/medium 档与手机维持「点卡片全屏详情」
    @Environment(\.holoContentWidth) private var thoughtWindowWidth
    private var isWideLayout: Bool { HoloAdaptiveLayout.isExpandedWidth(thoughtWindowWidth) }

    /// 全屏编辑器 cover 的门控绑定：宽屏编辑器常驻右栏，cover 恒 nil 不弹；
    /// 窄屏保持 item 语义（选中即全屏进编辑器）
    private var editorCoverBinding: Binding<UUID?> {
        Binding(
            get: { isWideLayout ? nil : selectedThoughtId },
            set: { newValue in
                selectedThoughtId = newValue
                if newValue == nil { selectedThoughtFocusConfirmation = false }
            }
        )
    }

    // MARK: - Computed Properties

    private var isKnowledgeMode: Bool { browseMode == "knowledge" }

    /// 筛选后的想法列表
    var filteredThoughts: [Thought] {
        var result = thoughts

        // 按标签筛选
        if let tagName = selectedTagName {
            result = result.filter { thought in
                ThoughtTagPresentation.matches(
                    tagName,
                    manualNames: thought.tagArray.map(\.name),
                    aiNames: thought.visibleAITagNames
                )
            }
        }

        // 混合搜索（C 阶段 §8.C.1）：关键词命中优先，语义命中（不含关键词的
        // 近义表达）补充在后；语义召回离线/未索引自动缺席，纯关键词照常
        if !searchText.isEmpty {
            let query = searchText
            let keywordMatches = result.filter { thought in
                thought.content.localizedCaseInsensitiveContains(query) ||
                (thought.tagArray.map(\.name) + thought.visibleAITagNames).contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
            }
            if semanticSearchHits.isEmpty {
                result = keywordMatches
            } else {
                let keywordIDs = Set(keywordMatches.map(\.id))
                let semanticOnly = result.filter {
                    semanticSearchHits[$0.id] != nil && !keywordIDs.contains($0.id)
                }
                result = keywordMatches + semanticOnly
            }
        }

        return result
    }

    /// 常用标签（使用次数前 5）
    var frequentTags: [ThoughtTag] {
        allTags
            .sorted { lhs, rhs in
                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(5)
            .map { $0 }
    }

    /// 当前生效的标签筛选名。两个入口一套状态：顶部 chip（selectedTagName）和
    /// 知识树/详情页跳转（drawerSelection 的 aiTag）；筛选条的选中指示必须都认，
    /// 否则抽屉筛选生效时「全部」仍高亮、用户看不出列表被过滤了。
    var activeTagFilterName: String? {
        if let selectedTagName { return selectedTagName }
        if case .aiTag(let name) = drawerSelection { return name }
        return nil
    }

    /// V3 新 UI：当前主题筛选（抽屉通道 drawerSelection 的 topic case）
    var activeTopicFilterID: UUID? {
        if case .topic(let id) = drawerSelection { return id }
        return nil
    }

    /// 主题 chip 选中判定
    func isTopicFilterSelected(_ topic: Topic) -> Bool {
        activeTopicFilterID == topic.id
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerView

            // 想法 / 知识树 切换（侧栏形态删除：单内容流，方案 2026-09-25 导航决策）
            if !ThoughtSidebarRollout.isEnabled {
                browseModeSegment
            }

            if isKnowledgeMode && !ThoughtSidebarRollout.isEnabled {
                ThoughtKnowledgeTreeView(
                    thoughtRepository: thoughtRepository,
                    topicRepository: topicRepository,
                    onNavigateToList: { node in
                        withAnimation(HoloAnimation.standard) {
                            browseMode = "timeline"
                        }
                        // 同值重复赋值不触发 onChange，需手动重载（否则停留在旧数据）
                        let isSameNode = drawerSelection == node
                        drawerSelection = node
                        if isSameNode {
                            reloadByDrawer()
                        }
                    },
                    onAIOrganize: { onAIOrganize() }
                )
                // 档位内容方向性过渡：知识树在右侧段，从右缘进
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                // 单列（窄/iPhone）与双栏（内容宽 ≥860）同一份结构：
                // HoloListDetailSplit 窄档只渲染列表列，宽屏轻点卡片右栏即展详情
                HoloListDetailSplit {
                    VStack(spacing: 0) {
                        searchBarView
                        aiOrganizationBanner
                        // 侧栏形态：混排导航 chip 退场（浏览范围由侧栏承载，§5.7），
                        // 面板筛选入口收进搜索行、已选条件在下方摘要行回显（flomo 改版批3）
                        if !ThoughtSidebarRollout.isEnabled {
                            filterBarView
                        } else {
                            activeFilterSummaryRow
                            topicScopeRow
                            // P1 §3.3 交集桥：#标签范围内给出与主题的真实交集入口
                            // （双向理解「同一想法既可有标签也可属主题」；无交集不占位）
                            tagTopicBridgeRow
                        }

                        if filteredThoughts.isEmpty && hasLoadedOnce {
                            emptyStateView
                        } else {
                            thoughtListView
                        }
                    }
                } detail: {
                    thoughtDetailPane
                }
                // 想法流在左侧段，从左缘进；离场统一纯淡出避免双向位移叠加的晃动
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        // 点卡片直达编辑器（详情页已下线，阅读与编辑合流到同一页面）。
        // 窄屏全屏 cover、宽屏内联右栏，同一个选中态驱动；
        // 编辑器内保存/删除通过通知与 onSave 回调刷新列表。
        .fullScreenCover(item: editorCoverBinding, onDismiss: {
            selectedThoughtFocusConfirmation = false
        }) { thoughtId in
            ThoughtEditorView(
                onSave: {
                    loadThoughts()
                    loadTags()
                    loadUnprocessedCount()
                },
                editingThoughtId: thoughtId,
                focusAIConfirmation: selectedThoughtFocusConfirmation
            )
            .holoContentColumn()
        }
        // 编辑器内发起的跨模块跳转（如「问问 Holo」）请求关闭整个 fullScreenCover，
        // 否则 cover 仍盖在目标页之上（dismiss 只能 pop 一层 NavigationStack）。
        .onReceive(NotificationCenter.default.publisher(for: .holoRequestCloseThoughtEditor)) { _ in
            selectedThoughtId = nil
        }
        // 编辑器「你之前也写过」点旧想法：切换编辑器目标（cover 重建、宽屏右栏切换）
        .onReceive(NotificationCenter.default.publisher(for: .thoughtRequestOpenEditor)) { note in
            guard let targetId = note.object as? UUID, targetId != selectedThoughtId else { return }
            selectedThoughtId = targetId
        }
        .sheet(isPresented: $showFilterSheet) {
            ThoughtFilterSheetView(initialFilters: currentFilters, onApplyFilters: { filters in
                currentFilters = filters
                loadThoughtsWithFilters()
            })
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBatchOrganizeSheet) {
            batchOrganizeConfirmationSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTopicPicker) {
            if let thoughtId = topicPickerThoughtId {
                TopicPickerView(thoughtId: thoughtId, topicRepository: topicRepository) {
                    NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                }
            }
        }
        .fullScreenCover(item: $selectedTopicId, onDismiss: {
            reloadByDrawer()
        }) { topicId in
            TopicDetailView(
                topicId: topicId,
                topicRepository: topicRepository,
                thoughtRepository: thoughtRepository,
                onTopicDeleted: {
                    selectedTopicId = nil
                    drawerSelection = nil
                }
            )
            .holoContentColumn()
        }
        .sheet(isPresented: $showTopicManagement, onDismiss: {
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        }) {
            NavigationStack {
                TopicManagementView(topicRepository: topicRepository, thoughtRepository: thoughtRepository)
            }
        }
        .fullScreenCover(isPresented: $showConfirmationQueue, onDismiss: {
            loadPendingConfirmationCount()
        }) {
            TopicConfirmationQueueView(
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                onQueueDrained: { loadPendingConfirmationCount() }
            )
            .holoContentColumn()
        }
        // Cmd+F：聚焦搜索栏；知识树视图下先切回列表视图（搜索栏只在列表视图）
        .onReceive(HoloShortcutBus.shared.$lastEvent) { event in
            guard event?.action == .searchInCurrentModule else { return }
            browseMode = "timeline"
            searchFieldFocused = true
        }
        .overlay(alignment: .top) {
            noticeToast
        }
        .onAppear {
            // Core Data 未就绪时 fetch 静默返回空，首次加载交给 .task 等就绪后执行
            guard CoreDataStack.shared.isReady else { return }
            loadThoughts()
            loadTags()
            loadUnprocessedCount()
            if let initialThoughtId {
                selectedThoughtId = initialThoughtId
            }
        }
        .task {
            // 等 Core Data 就绪后再做首次加载，避免入场时空态/内容分批出现
            await CoreDataStack.shared.waitUntilReady()
            loadThoughts()
            loadTags()
            loadUnprocessedCount()
            if let initialThoughtId {
                selectedThoughtId = initialThoughtId
            }
        }
        .onChange(of: initialThoughtId) { _, newValue in
            // 想法模块已常驻时，任务页/小组件再次跳转也要能打开新的编辑器。
            if let newValue {
                selectedThoughtId = newValue
            }
        }
        // 卡片展开状态上报（三段分区：展开时中部右滑让位给收按钮，防双动）。
        // 挂 onChange 而非 Binding set，覆盖删除/切范围等所有置空路径。
        .onChange(of: revealedThoughtId) { _, newValue in
            onRevealedCardChange?(newValue != nil)
        }
        // P1 §3.2 归入回执：AI 落库成功广播 → 该想法在当前列表时给一次短暂 toast
        // （不用常驻进度条；离线/未授权/无匹配是合法静默，不产生本事件）
        .onReceive(NotificationCenter.default.publisher(for: .thoughtTopicLinkDidCommit)) { note in
            guard let payload = note.object as? [String: Any],
                  let thoughtId = payload["thoughtId"] as? UUID,
                  let topicTitle = payload["topicTitle"] as? String,
                  thoughts.contains(where: { $0.id == thoughtId }) else { return }
            topicReceiptTitle = topicTitle
            topicReceiptTask?.cancel()
            topicReceiptTask = Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                if !Task.isCancelled { topicReceiptTitle = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            scheduleListRefreshAfterDataChange()
        }
        // 标签 emoji 图标变更只刷显示层（Store 读内存字典，无需重查库）
        .onReceive(NotificationCenter.default.publisher(for: ThoughtTagEmojiStore.didChangeNotification)) { _ in
            emojiDisplayTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoCloudDataDidSync)) { _ in
            // iCloud 云端数据到达：新设备上后台导入晚于首载，收到广播即刷新列表
            scheduleListRefreshAfterDataChange()
        }
        .onChange(of: drawerSelection) { _, newValue in
            // 外部筛选请求（如编辑器/详情页「查看标签」）只有想法列表能承载；
            // 用户停在知识树时先切回列表，再执行筛选重载。
            if newValue != nil, newValue != .aiOrganize, isKnowledgeMode {
                browseMode = "timeline"
            }
            // 切浏览范围 = 换一组内容的上下文，面板筛选（日期/整理状态）随之明确清空；
            // 之前由 reloadByDrawer 静默清，现收到唯一入口（flomo 改版批3：切范围语义可预期）
            currentFilters = nil
            reloadByDrawer()
        }
        .onChange(of: orgQueue.isBatchOrganizing) { oldValue, newValue in
            guard oldValue, !newValue, shouldRunTopicConvergenceAfterBatch else { return }
            shouldRunTopicConvergenceAfterBatch = false
            loadUnprocessedCount()

            guard !orgQueue.dailyLimitHit else {
                batchOrganizeNotice = String(localized: "标签整理已暂停，配额恢复后再继续归纳主题")
                return
            }

            batchOrganizeNotice = String(localized: "标签整理完成，正在归纳主题")
            onAIOrganize()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSemanticSearch(newValue)
        }
        .onChange(of: thoughts) { _, updatedThoughts in
            // 宽屏双栏：选中的想法被删除后右栏退回引导位（编辑器内联模式 dismiss() 不生效）
            guard let selectedThoughtId,
                  !updatedThoughts.contains(where: { $0.id == selectedThoughtId }) else { return }
            self.selectedThoughtId = nil
        }
    }

    // MARK: - 宽屏右栏编辑器（v2 设计稿③）

    @ViewBuilder
    private var thoughtDetailPane: some View {
        if let thoughtId = selectedThoughtId {
            ThoughtEditorView(
                onSave: {
                    loadThoughts()
                    loadTags()
                    loadUnprocessedCount()
                },
                editingThoughtId: thoughtId,
                focusAIConfirmation: selectedThoughtFocusConfirmation,
                onRequestClose: { selectedThoughtId = nil }
            )
            // 切换想法重建编辑器：滚动位置、光标与编辑态不跨想法残留
            .id(thoughtId)
        } else {
            detailPlaceholder
        }
    }

    /// 无选中时的引导位（设计稿②：编辑器常驻，不留白板）
    private var detailPlaceholder: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 30))
                .foregroundColor(.holoTextPlaceholder)
            Text("选一条想法打开")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("在左侧轻点卡片，在这里展开编辑")
                .font(.holoCaption)
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
        .accessibilityElement(children: .combine)
    }

    // MARK: - AI 归纳状态条

    /// 是否有想法正在被 AI 处理（单条增量整理）
    private var hasProcessingThoughts: Bool {
        thoughts.contains { $0.organizedStatus == "processing" }
    }

    /// AI 归纳状态条（批量进度 / 配额耗尽 / 单条增量三态）
    private var aiOrganizationBanner: some View {
        Group {
            if ThoughtSemanticFeatureFlags.uiEnabled {
                // V3 新 UI：AI 整理进度/配额/待确认不进主路径
            } else if shouldShowAIEducation {
                aiEducationBanner
            } else if orgQueue.isBatchOrganizing, let total = orgQueue.batchTotal {
                // 批量整理进度
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.holoPrimary)

                    Text("AI 自动归纳中（\(orgQueue.batchCompleted)/\(total)）")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.06))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if orgQueue.dailyLimitHit {
                // 配额耗尽暂停
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)

                    Text("今日 AI 额度已用尽，剩余条目明天自动续做")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.06))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if pendingConfirmationCount > 0 {
                // 待确认池入口（AI 低置信主题归属）
                Button {
                    showConfirmationQueue = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundColor(.holoAI)

                        Text("AI 有 \(pendingConfirmationCount) 条主题归属想跟你确认")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, 6)
                    .background(Color.holoAI.opacity(0.06))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                .buttonStyle(.plain)
            } else if hasProcessingThoughts {
                // 单条增量整理（保存想法时）
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.holoPrimary)

                    Text("AI 自动归纳中...")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.04))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(HoloAnimation.smooth, value: orgQueue.isBatchOrganizing)
        .animation(HoloAnimation.smooth, value: orgQueue.dailyLimitHit)
        .animation(HoloAnimation.smooth, value: pendingConfirmationCount)
        .animation(HoloAnimation.smooth, value: hasProcessingThoughts)
    }

    // MARK: - 首次教育（第一条 AI 建议出现时，一次性）

    /// 必须用 @AppStorage：UserDefaults 裸写不是 SwiftUI 观察源，
    /// 点击「知道了」后浮条不会消失（验收实测踩过）
    @AppStorage("thoughtsAIEducationShownV1")
    private var aiEducationShown: Bool = false

    /// 触发时机：用户刚好看见第一条 AI 建议时才解释它——
    /// 首次打开模块时没有上下文，说了也记不住
    private var shouldShowAIEducation: Bool {
        !aiEducationShown && thoughts.contains { !$0.visibleAITagNames.isEmpty }
    }

    private var aiEducationBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(.holoAI)

            // 信息排序：是什么 → 可以拒绝 → 可以不管（最后一句卸下心理负担）
            Text("Holo 会自动为想法打标签、归主题。不合适的建议点 ✗ 即可，不管它也没关系。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(HoloAnimation.quick) {
                    aiEducationShown = true
                }
            } label: {
                Text("知道了")
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoAI.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoAI.opacity(0.22), lineWidth: 1)
                )
        )
        .padding(.horizontal, HoloSpacing.lg)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 语义搜索（C 阶段 §8.C.1：同义问法找回，关键词优先）

    /// 防抖 600ms 后发起语义召回；空词/两字以下清空语义命中。
    /// 后端不可用/未索引静默缺席——关键词路径不受影响。
    private func scheduleSemanticSearch(_ query: String) {
        semanticSearchTask?.cancel()
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            semanticSearchHits = [:]
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        semanticSearchTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let hits = await SemanticSearchHelper.search(query: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(HoloAnimation.quick) {
                    semanticSearchHits = hits ?? [:]
                }
            }
        }
    }

    // MARK: - 数据加载

    /// 节流：批量整理每条完成都发通知，合并 500ms 后统一刷新，避免主线程卡顿；
    /// iCloud 云端数据到达广播也走同一条链路
    private func scheduleListRefreshAfterDataChange() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled {
                loadThoughts()
                loadTags()
                loadUnprocessedCount()
            }
        }
    }

    private func loadThoughts() {
        // 面板筛选（日期/整理状态）生效时刷新必须保持同一口径，
        // 不能静默退回全部（flomo 改版批3：刷新不再丢筛选）
        if currentFilters != nil {
            loadThoughtsWithFilters()
            return
        }
        // 抽屉筛选生效时保持筛选语义（删除/归档/通知后的刷新也走这里，不能退回全部）
        if drawerSelection != nil, drawerSelection != .aiOrganize {
            reloadByDrawer()
            return
        }
        do {
            thoughts = try thoughtRepository.fetchAll()
            recognizedTagKeys = Set(thoughtRepository.fetchUserRecognizedTagNames()
                .map { ThoughtTagNormalizer.key($0) })
        } catch {
            logger.error("加载想法失败：\(error)")
            thoughts = []
        }
        hasLoadedOnce = true
    }

    /// 清空标签筛选（顶部「全部」chip 与临时筛选 chip 共用）：
    /// 同时退出抽屉筛选态（drawerSelection 变化触发重载回全部列表）
    private func clearTagFilter() {
        selectedTagName = nil
        if drawerSelection != nil {
            drawerSelection = nil
        } else {
            loadThoughts()
        }
    }

    /// 抽屉节点变化时按筛选意图重新加载（P1.4）
    private func reloadByDrawer() {
        // 互斥：抽屉主导时清 chip 标签筛选
        if drawerSelection != nil {
            selectedTagName = nil
        }
        // currentFilters 由唯一入口清空（onChange(of: drawerSelection) 切范围时），
        // 这里不再动它——本方法也承载刷新路径，无条件清会静默丢筛选
        // 与 loadThoughts 的全量路径保持同一份 P0 分级判定数据
        recognizedTagKeys = Set(thoughtRepository.fetchUserRecognizedTagNames()
            .map { ThoughtTagNormalizer.key($0) })
        do {
            switch drawerSelection {
            case nil, .allNotes:
                thoughts = try thoughtRepository.fetchAll()
            case .unclassified:
                thoughts = try thoughtRepository.fetchUnclassifiedThoughts()
            case .aiTag(let tagName):
                thoughts = try thoughtRepository.fetchThoughtsByAITag(tagName)
            case .userTag(let pathKey):
                thoughts = try thoughtRepository.fetchThoughtsByUserTag(pathKey: pathKey)
            case .topic(let topicId):
                thoughts = try topicRepository.fetchThoughts(byTopic: topicId)
                if let topic = try? topicRepository.fetchTopicById(topicId) {
                    topicTitleCache[topicId] = topic.title
                }
            case .archived:
                thoughts = try thoughtRepository.fetchArchived()
            case .aiOrganize:
                // 非筛选（抽屉内弹预告），不改变列表
                return
            }
        } catch {
            logger.error("抽屉筛选加载失败：\(error)")
            thoughts = []
        }
    }

    private func loadThoughtsWithFilters() {
        guard let filters = currentFilters else {
            loadThoughts()
            return
        }

        do {
            // 如果有搜索文本，使用搜索方法
            if !searchText.isEmpty {
                var results = try thoughtRepository.search(query: searchText, filters: filters)
                // P1（FR-10）：search 谓词不识别整理状态，与非搜索路径同语义做内存过滤
                if let state = filters.organizationState {
                    results = results.filter { matchesOrganizationState($0, state: state) }
                }
                thoughts = results
            } else {
                // 面板筛选叠加在当前浏览范围之上（flomo 改版批3补丁）：
                // 在主题/标签/归档范围内应用日期/状态筛选，结果必须仍落在该范围内，
                // 否则标题显示范围名、列表却变成全部——口径分裂
                var allThoughts = try baseThoughtsForCurrentScope()

                // 按日期范围筛选
                if let startDate = filters.startDate {
                    allThoughts = allThoughts.filter { $0.createdAt >= startDate }
                }
                if let endDate = filters.endDate {
                    // 将结束日期设置为当天 23:59:59
                    let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
                    allThoughts = allThoughts.filter { $0.createdAt <= endOfDay }
                }

                // P1（FR-10）：整理状态筛选
                if let state = filters.organizationState {
                    allThoughts = allThoughts.filter { matchesOrganizationState($0, state: state) }
                }

                thoughts = allThoughts
            }
        } catch {
            logger.error("加载想法失败：\(error)")
            thoughts = []
        }
    }

    /// 当前浏览范围的基集（抽屉范围优先；nil = 全部想法）。
    /// 面板筛选与刷新共用，保证「范围内叠加条件」的口径一致。
    private func baseThoughtsForCurrentScope() throws -> [Thought] {
        if let drawerSelection, drawerSelection != .aiOrganize {
            var scoped: [Thought] = []
            switch drawerSelection {
            case nil, .allNotes:
                scoped = try thoughtRepository.fetchAll()
            case .unclassified:
                scoped = try thoughtRepository.fetchUnclassifiedThoughts()
            case .aiTag(let tagName):
                scoped = try thoughtRepository.fetchThoughtsByAITag(tagName)
            case .userTag(let pathKey):
                scoped = try thoughtRepository.fetchThoughtsByUserTag(pathKey: pathKey)
            case .topic(let topicId):
                scoped = try topicRepository.fetchThoughts(byTopic: topicId)
            case .archived:
                scoped = try thoughtRepository.fetchArchived()
            case .aiOrganize:
                scoped = try thoughtRepository.fetchAll()
            }
            return scoped
        }
        return try thoughtRepository.fetchAll()
    }

    /// P1：整理状态匹配（待确认判定复用 Policy，认可集合为列表层缓存）
    private func matchesOrganizationState(_ thought: Thought, state: OrganizationStateFilter) -> Bool {
        switch state {
        case .failed:
            return thought.organizedStatus == "failed"
        case .unclassified:
            return thought.organizedStatus == "organized" && !thought.hasActiveTopic
        case .pendingConfirmation:
            // 与卡片「等待确认」同口径：低置信主题 或 含新标签的 AI 建议（D-07′）
            guard thought.organizedStatus == "organized" else { return false }
            let lowConfidenceTopic = thought.topicConfidence > 0
                && thought.topicConfidence < ThoughtRepository.topicConfirmationThreshold
            if lowConfidenceTopic { return true }
            let hasNewTag = !thought.visibleAITagNames.isEmpty
                && ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                    hasAITagAssignments: true,
                    aiTagNames: thought.visibleAITagNames,
                    recognizedTagKeys: recognizedTagKeys
                ) == .pendingConfirmation
            return hasNewTag
        }
    }

    private func loadTags() {
        do {
            allTags = try thoughtRepository.getAllTags()
        } catch {
            logger.error("加载标签失败：\(error)")
            allTags = []
        }
        loadFilterTopics()
    }

    /// V3 新 UI：主题筛选 chips 候选（可见主题；上限 6 个，抽屉选中的主题必在列）
    private func loadFilterTopics() {
        guard ThoughtSemanticFeatureFlags.uiEnabled else {
            filterTopics = []
            return
        }
        let topics = (try? topicRepository.fetchVisibleTopics()) ?? []
        if let selectedID = activeTopicFilterID,
           !topics.contains(where: { $0.id == selectedID }),
           let selected = topics.first(where: { $0.id == selectedID }) {
            filterTopics = [selected] + Array(topics.prefix(5))
        } else {
            filterTopics = Array(topics.prefix(6))
        }
    }

    // MARK: - 批量自动整理

    /// 加载待整理数量（chip 徽章）
    private func loadUnprocessedCount() {
        // V3 新 UI：AI 整理进度不进主路径，跳过计数查询
        guard !ThoughtSemanticFeatureFlags.uiEnabled else {
            unprocessedCount = 0
            pendingConfirmationCount = 0
            return
        }
        do {
            unprocessedCount = try thoughtRepository.countUnprocessed()
        } catch {
            logger.error("加载未整理计数失败：\(error)")
            unprocessedCount = 0
        }
        loadPendingConfirmationCount()
    }

    /// 加载待确认数量（想法列表 banner 徽章）
    private func loadPendingConfirmationCount() {
        pendingConfirmationCount = (try? thoughtRepository.fetchThoughtsPendingTopicConfirmation().count) ?? 0
    }

    /// 点击「自动整理」chip
    private func handleOrganizeChipTap() {
        if orgQueue.isBatchOrganizing {
            // 正在批量整理，banner 已显示进度，不重复触发
            return
        }
        if orgQueue.dailyLimitHit {
            batchOrganizeNotice = String(localized: "今日 AI 额度已用尽，剩余条目明天自动续做")
            return
        }
        if unprocessedCount == 0 {
            batchOrganizeNotice = String(localized: "正在归纳主题")
            onAIOrganize()
            return
        }
        showBatchOrganizeSheet = true
    }

    /// 开始批量整理
    private func startBatchOrganize() {
        showBatchOrganizeSheet = false
        do {
            let ids = try thoughtRepository.fetchUnprocessedThoughtIds()
            guard !ids.isEmpty else {
                batchOrganizeNotice = String(localized: "没有需要整理的想法")
                return
            }
            try thoughtRepository.markBatchPending(thoughtIds: ids)
            shouldRunTopicConvergenceAfterBatch = true
            orgQueue.enqueueBatch(thoughtIds: ids)
            batchOrganizeNotice = String(localized: "已开始整理 \(ids.count) 条想法，完成后会归纳主题")
        } catch {
            logger.error("启动批量整理失败：\(error)")
            batchOrganizeNotice = String(localized: "启动失败，请稍后重试")
        }
    }

    /// 批量整理确认 Sheet
    private var batchOrganizeConfirmationSheet: some View {
        VStack(spacing: HoloSpacing.lg) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundColor(.holoAI)
                Text("批量 AI 整理")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }

            // 说明
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("将为 **\(unprocessedCount)** 条未整理想法生成 AI 标签")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text("每条想法会产生 ≤3 个标签建议，可在详情页确认或拒绝。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 配额提示
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.holoPrimary)
                    .font(.system(size: 12))
                Text("后台串行整理，受每日配额限制，会占用今日 AI 额度（与聊天等共享，可能影响新想法当天的自动整理）；多余条目会在后续打开 App 时自动续做。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoPrimary.opacity(0.06))
            .cornerRadius(HoloRadius.md)

            Spacer()

            // 按钮
            HStack(spacing: HoloSpacing.md) {
                Button("取消") {
                    showBatchOrganizeSheet = false
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("开始整理") {
                    startBatchOrganize()
                }
                .buttonStyle(.borderedProminent)
                .tint(.holoPrimary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(HoloSpacing.lg)
    }

    /// 提示 toast（自动消失）
    private var noticeToast: some View {
        Group {
            if let notice = batchOrganizeNotice {
                Text(notice)
                    .font(.holoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(HoloRadius.md)
                    .padding(.top, HoloSpacing.xl)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.easeInOut) { batchOrganizeNotice = nil }
                    }
            } else if let receipt = topicReceiptTitle {
                // P1 归入回执：AI 落库后的一次性短暂提示（绿色主题语义，来源可感知）
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(localized: "已归入「\(receipt)」"))
                        .font(.holoCaption)
                }
                .foregroundColor(Color.holoSuccess)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
                .background(Color.holoCardBackground.opacity(0.97))
                .overlay(Capsule().stroke(Color.holoSuccess.opacity(0.3), lineWidth: 1))
                .clipShape(Capsule())
                .padding(.top, HoloSpacing.xl)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel(String(localized: "Holo 已将这条想法归入主题\(receipt)"))
            }
        }
    }

    // MARK: - 顶部导航栏

    @ViewBuilder
    private var headerView: some View {
        if let onOpenSidebar {
            // 侧栏形态：左上菜单 + 当前范围标题（点标题也可开侧栏）+ 右上独立返回 Holo
            // 左缘右滑沿用全 App 的返回手势；侧栏由菜单或标题打开。
            HStack(spacing: 0) {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "打开导航侧栏"))

                Button {
                    onOpenSidebar()
                } label: {
                    HStack(spacing: 4) {
                        Text(sidebarScopeTitle)
                            .font(.holoHeading)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "当前范围：\(sidebarScopeTitle)"))

                Spacer()

                if isWideLayout {
                    Button {
                        showAddThought = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text("新建")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.holoPrimary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "新增想法"))
                }

                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "返回 Holo"))
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoBackground)
        } else {
            legacyHeaderView
        }
    }

    /// 侧栏形态的当前范围标题（§5.7：标题、列表、搜索范围一致）
    private var sidebarScopeTitle: String {
        switch drawerSelection {
        case nil, .allNotes, .aiOrganize:
            return String(localized: "全部想法")
        case .topic(let topicId):
            return topicTitleCache[topicId] ?? String(localized: "主题")
        case .userTag(let pathKey):
            return "#" + (pathKey.split(separator: "/").map(String.init).joined(separator: "/"))
        case .aiTag(let name):
            return "#" + name
        case .unclassified:
            return String(localized: "未归类")
        case .archived:
            return String(localized: "已归档")
        }
    }

    private var legacyHeaderView: some View {
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
            Text("想法")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 宽屏双栏下右下角 FAB 退役（会挡双栏内容），新建入口上移到顶部（设计稿④）
            if isWideLayout {
                Button {
                    showAddThought = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("新建")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "新增想法"))
            }

            // 右上「…」菜单：知识树模式含主题管理；清空想法数据（数据清理）两种模式均提供
            Menu {
                if isKnowledgeMode {
                    Button {
                        showTopicManagement = true
                    } label: {
                        Label("主题管理", systemImage: "folder.badge.gearshape")
                    }
                }
                Button(role: .destructive) {
                    showClearThoughtSheet = true
                } label: {
                    Label("清空想法数据…", systemImage: "trash.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .sheet(isPresented: $showClearThoughtSheet) {
                ModuleClearSheet(module: .thought)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 浏览模式切换（想法 / 知识树）

    private var browseModeSegment: some View {
        HStack(spacing: 3) {
            segmentItem(title: String(localized: "想法"), icon: "lightbulb.fill", key: "timeline")
            segmentItem(title: String(localized: "主题"), icon: "folder.fill", key: "knowledge")
        }
        .padding(3)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.sm)
    }

    private func segmentItem(title: String, icon: String, key: String) -> some View {
        let isSelected = browseMode == key
        return Button {
            withAnimation(HoloAnimation.standard) {
                browseMode = key
            }
            HapticManager.light()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .white : .holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: HoloRadius.sm + 2)
                        .fill(Color.holoPrimary)
                        .matchedGeometryEffect(id: "browseModeSegment", in: browseModeNamespace)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索栏

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索想法或标签...", text: $searchText)
                .focused($searchFieldFocused)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            // 侧栏形态：筛选面板入口收进搜索行（旧形态的入口在筛选 chips 行尾，不重复放）
            // （flomo 改版批3：新形态下日期/整理状态筛选原本完全不可达）
            if ThoughtSidebarRollout.isEnabled {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14))
                        .foregroundColor(hasActivePanelFilters ? .holoPrimary : .holoTextSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if hasActivePanelFilters {
                                Circle()
                                    .fill(Color.holoPrimary)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: 0)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "筛选"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - 已选筛选摘要行（侧栏形态）

    /// 面板是否携带有效条件（mood 恒 nil 不算；全空时筛选应整体清掉）
    private var hasActivePanelFilters: Bool {
        guard let filters = currentFilters else { return false }
        return filters.startDate != nil || filters.endDate != nil || filters.organizationState != nil
    }

    /// 面板日期条件的摘要文案：「3月1日 起」「截至 3月5日」「3月1日 – 3月5日」
    private var panelDateRangeText: String? {
        guard let filters = currentFilters,
              filters.startDate != nil || filters.endDate != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        switch (filters.startDate, filters.endDate) {
        case let (start?, end?):
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        case let (start?, nil):
            return "\(formatter.string(from: start)) 起"
        case let (nil, end?):
            return "截至 \(formatter.string(from: end))"
        default:
            return nil
        }
    }

    /// 搜索行下方的已选条件回显：单项 × 清除 + 一键清空
    /// （flomo 改版批3：「正在看什么」必须一眼可见、容易退出）
    @ViewBuilder
    private var activeFilterSummaryRow: some View {
        if ThoughtSidebarRollout.isEnabled, hasActivePanelFilters {
            HStack(spacing: 8) {
                if let dateText = panelDateRangeText {
                    summaryChip(text: dateText) {
                        clearDateRangeFilter()
                    }
                }
                if let state = currentFilters?.organizationState {
                    summaryChip(text: state.rawValue) {
                        clearOrganizationStateFilter()
                    }
                }
                Spacer(minLength: 0)
                Button {
                    clearAllPanelFilters()
                } label: {
                    Text("清除筛选")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// 标签只负责按用户写下的词找回想法；主题多一个跨时间回看入口。
    /// 保持同一内容流，避免重新引入「想法 / 知识树」双首页。
    @ViewBuilder
    private var topicScopeRow: some View {
        if case .topic(let topicId) = drawerSelection {
            Button {
                selectedTopicId = topicId
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.holoSuccess)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.holoSuccess.opacity(0.1)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("主题脉络")
                            .font(.holoCaption)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)
                        Text(topicScopeDescription)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Text("查看")
                        .font(.holoCaption)
                        .foregroundColor(.holoSuccess)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoSuccess)
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
                .background(RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoSuccess.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.xs)
            .accessibilityLabel(String(localized: "查看主题脉络"))
        }
    }

    // MARK: - 标签×主题交集桥（P1 §3.3，2026-09-27）

    /// 当前 #标签范围与各主题的真实交集（最多 3 个，按条数降序）。
    /// 计数与卡片/侧栏同源（effectiveTopics 投影裁决）；无交集返回空，不占位。
    private var tagTopicIntersections: [(topic: Topic, count: Int)] {
        guard case .userTag = drawerSelection else { return [] }
        var counts: [UUID: (Topic, Int)] = [:]
        for thought in filteredThoughts {
            for topic in ThoughtTopicLinkProjection.effectiveTopics(for: thought)
            where topic.statusEnum == .active || topic.statusEnum == .classification {
                if let existing = counts[topic.id] {
                    counts[topic.id] = (existing.0, existing.1 + 1)
                } else {
                    counts[topic.id] = (topic, 1)
                }
            }
        }
        return counts.values
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { (topic: $0.0, count: $0.1) }
    }

    @ViewBuilder
    private var tagTopicBridgeRow: some View {
        let intersections = tagTopicIntersections
        if !intersections.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(intersections, id: \.topic.id) { item in
                        Button {
                            selectedTopicId = item.topic.id
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "leaf.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(localized: "其中 \(item.count) 条也在「\(item.topic.title)」"))
                                    .font(.holoCaption)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(Color.holoSuccess)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: HoloRadius.md)
                                .fill(Color.holoSuccess.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md)
                                .stroke(Color.holoSuccess.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "\(item.count) 条想法也在主题\(item.topic.title)，点按查看"))
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
            }
            .padding(.bottom, HoloSpacing.xs)
        }
    }

    private var topicScopeDescription: String {
        guard currentFilters == nil, searchText.isEmpty, thoughts.count > 1,
              let earliest = thoughts.compactMap(\.createdAt).min(),
              let latest = thoughts.compactMap(\.createdAt).max() else {
            return String(localized: "查看这个主题中的想法与回顾")
        }
        let calendar = Calendar.current
        let days = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest),
                                                     to: calendar.startOfDay(for: latest)).day ?? 0) + 1)
        return String(localized: "\(thoughts.count) 条想法 · 横跨 \(days) 天")
    }

    private func summaryChip(text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.holoLabel)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "移除筛选 \(text)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.holoPrimary.opacity(0.08))
        .cornerRadius(HoloRadius.full)
    }

    /// 清掉面板的日期条件；剩余条件全空则整体退筛
    private func clearDateRangeFilter() {
        guard var filters = currentFilters else { return }
        filters.startDate = nil
        filters.endDate = nil
        applyPanelFilters(filters)
    }

    /// 清掉面板的整理状态条件；剩余条件全空则整体退筛
    private func clearOrganizationStateFilter() {
        guard var filters = currentFilters else { return }
        filters.organizationState = nil
        applyPanelFilters(filters)
    }

    private func clearAllPanelFilters() {
        currentFilters = nil
        loadThoughts()
    }

    /// 摘要行单项清除后的重装：条件全空则整体退筛，否则按剩余条件刷新
    private func applyPanelFilters(_ filters: ThoughtFilters) {
        let remaining = filters.startDate != nil || filters.endDate != nil || filters.organizationState != nil
        currentFilters = remaining ? filters : nil
        loadThoughts()
    }

    // MARK: - 筛选栏

    private var filterBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 全部标签（两套筛选入口都没选中时才算「全部」）
                HoloFilterChip(
                    title: String(localized: "全部"),
                    iconColor: .holoPrimary,
                    isSelected: activeTagFilterName == nil && activeTopicFilterID == nil
                ) {
                    clearTagFilter()
                }

                // 自动整理动作 chip（橙色主操作 + 小型紫色 AI 来源标识）
                // V3 新 UI：AI 整理入口退出主路径
                if !ThoughtSemanticFeatureFlags.uiEnabled {
                    ThoughtOrganizeActionChip(
                        pendingCount: unprocessedCount,
                        isOrganizing: orgQueue.isBatchOrganizing
                    ) {
                        handleOrganizeChipTap()
                    }
                }

                // 从卡片/详情页跳转的非常用标签也要在顶部显示当前筛选状态。
                if let activeTagFilterName,
                   !frequentTags.contains(where: {
                       ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key(activeTagFilterName)
                   }) {
                    HoloFilterChip(
                        title: activeTagFilterName,
                        iconColor: .holoPrimary,
                        isSelected: true
                    ) {
                        clearTagFilter()
                    }
                }

                // 常用标签
                ForEach(frequentTags) { tag in
                    HoloFilterChip(
                        title: tag.name,
                        iconColor: tag.tagColor,
                        isSelected: activeTagFilterName != nil
                            && ThoughtTagNormalizer.sharesIdentity(activeTagFilterName!, tag.name)
                    ) {
                        selectedTagName = tag.name
                        drawerSelection = nil
                    }
                }

                // V3 新 UI：主题筛选 chips（与用户 #标签混排一行）
                if ThoughtSemanticFeatureFlags.uiEnabled {
                    ForEach(Array(filterTopics), id: \.id) { topic in
                        Button {
                            let node = DrawerNode.topic(topic.id)
                            let isSame = drawerSelection == node
                            drawerSelection = node
                            selectedTagName = nil
                            if isSame {
                                reloadByDrawer()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "leaf.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(topic.title)
                                    .font(.holoLabel)
                                    .lineLimit(1)
                            }
                            .foregroundColor(isTopicFilterSelected(topic)
                                             ? .white : Color.holoSuccess.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isTopicFilterSelected(topic)
                                        ? Color.holoSuccess.opacity(0.85)
                                        : Color.holoSuccess.opacity(0.09))
                            .cornerRadius(HoloRadius.full)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 更多筛选按钮
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoCardBackground)
                        .cornerRadius(HoloRadius.full)
                        .overlay(
                            Capsule()
                                .stroke(Color.holoDivider, lineWidth: 1)
                        )
                }
                .accessibilityLabel(String(localized: "筛选"))
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }

    // MARK: - 想法列表

    private var thoughtListView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(Array(filteredThoughts.enumerated()), id: \.element) { index, thought in
                    SwipeActionView(
                        isRevealed: Binding(
                            get: { revealedThoughtId == thought.id },
                            set: { if $0 { revealedThoughtId = thought.id } else { revealedThoughtId = nil } }
                        ),
                        isEnabled: swipeGesturesEnabled,
                        content: {
                            ThoughtCardView(
                                thought: thought,
                                onNavigate: {
                                    if revealedThoughtId == thought.id {
                                        revealedThoughtId = nil
                                    } else {
                                        selectedThoughtId = thought.id
                                    }
                                },
                                onConfirmNavigate: {
                                    // 待确认徽章：进编辑器并直达 AI 归类确认位
                                    revealedThoughtId = nil
                                    selectedThoughtFocusConfirmation = true
                                    selectedThoughtId = thought.id
                                },
                                onTagTap: { tagName in
                                    selectedTagName = ThoughtTagNormalizer.displayName(tagName)
                                    drawerSelection = nil
                                    revealedThoughtId = nil
                                },
                                onMoveToTopic: {
                                    topicPickerThoughtId = thought.id
                                    showTopicPicker = true
                                },
                                onArchive: {
                                    archiveThought(thought)
                                },
                                onRetryOrganize: (thought.organizedStatus == "failed" && !ThoughtSemanticFeatureFlags.uiEnabled) ? {
                                    ThoughtOrganizationQueue.shared.enqueueManual(thoughtId: thought.id)
                                } : nil,
                                onDelete: {
                                    deleteThought(thought)
                                },
                                archiveActionTitle: isArchivedView ? String(localized: "恢复") : String(localized: "归档"),
                                recognizedTagKeys: recognizedTagKeys,
                                onChangeTopic: {
                                    // V3：主题徽章「更改主题」复用移入主题选择器
                                    topicPickerThoughtId = thought.id
                                    showTopicPicker = true
                                },
                                onRemoveTopic: { topic in
                                    removeThoughtLocally(thought, topic: topic)
                                },
                                onOpenTopic: { topic in
                                    // P1：轻点主题行进主题详情（纠错收进长按）
                                    revealedThoughtId = nil
                                    selectedTopicId = topic.id
                                }
                            )
                            .contextMenu {
                                Button {
                                    askHoloAboutThought(thought)
                                } label: {
                                    Label("问问 Holo", systemImage: "sparkles")
                                }

                                Button {
                                    topicPickerThoughtId = thought.id
                                    showTopicPicker = true
                                } label: {
                                    Label("移入主题", systemImage: "folder")
                                }
                            }
                        },
                        onArchive: {
                            archiveThought(thought)
                        },
                        onDelete: {
                            deleteThought(thought)
                        }
                    )
                    // 行离场（删除/归档）向右滑出淡出；插入侧保持轻淡入
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .move(edge: .trailing))
                    ))
                    .holoStaggeredAppear(index: index)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, 90) // 给浮动按钮留位
        }
        .refreshable {
            await refresh()
        }
        .scrollDismissesKeyboard(.interactively)  // 下滑列表时收起键盘（跟随手指，松手才确认）
    }

    // MARK: - 刷新功能

    @MainActor
    private func refresh() async {
        // 模拟短暂延迟，提供更好的用户体验
        try? await Task.sleep(nanoseconds: 500_000_000)
        loadThoughts()
        loadTags()
    }

    // MARK: - 滑动操作

    /// 当前是否处于「已归档」视图（决定归档/恢复操作语义）
    private var isArchivedView: Bool {
        if case .archived = drawerSelection { return true }
        return false
    }

    /// 跨模块入口：把这条想法的上下文预填到 AI 聊天输入框，跳转到 AI 页（不自动发送）。
    /// 想法列表的长按菜单入口——这是用户「看到一条想法想问 AI」最高频的场景。
    private func askHoloAboutThought(_ thought: Thought) {
        let snippet = thought.firstLine ?? String(thought.content.prefix(30))
        let prefill = String(localized: "关于这条想法「\(snippet)」，帮我展开想想，或者拆成可执行的待办")
        DeepLinkState.shared.navigate(to: .chat(prefill: prefill))
    }

    /// 归档 / 恢复（在归档视图下自动变为恢复）
    private func archiveThought(_ thought: Thought) {
        do {
            if isArchivedView {
                try thoughtRepository.unarchive(thought.id)
            } else {
                try thoughtRepository.archive(thought.id)
            }
            revealedThoughtId = nil
            withAnimation(HoloAnimation.grounded) {
                loadThoughts()
            }
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("归档/恢复想法失败: \(error.localizedDescription)")
            HoloToastCenter.shared.show(String(localized: "操作失败，请重试"), type: .error)
        }
    }

    /// 删除想法
    private func deleteThought(_ thought: Thought) {
        do {
            // 先从本地数组移除再删库（团队纪律）：当前 delete 是软删所以删库先后都安全，
            // 但若将来换成硬删，先删库会让本页继续渲染已删对象而闪退
            withAnimation(HoloAnimation.grounded) {
                thoughts.removeAll { $0.id == thought.id }
            }
            try thoughtRepository.delete(thought.id)
            revealedThoughtId = nil
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            loadThoughts()
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("删除想法失败: \(error.localizedDescription)")
        }
    }

    /// V3：主题徽章「从这条移除」——写 rejected 墓碑，同一错误不会立刻重现
    private func removeThoughtLocally(_ thought: Thought, topic: Topic) {
        do {
            try topicRepository.remove(thoughtId: thought.id, fromTopic: topic.id)
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            if case .topic(let id) = drawerSelection, id == topic.id {
                // 正按该主题筛选时移除，就地从列表消失
                withAnimation(HoloAnimation.grounded) {
                    thoughts.removeAll { $0.id == thought.id }
                }
            } else {
                loadThoughts()
            }
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("移除主题归属失败: \(error.localizedDescription)")
            HoloToastCenter.shared.show(String(localized: "操作失败，请重试"), type: .error)
        }
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        // 空态按语境区分（R3 体检实锤）：搜索/筛选无结果 ≠ 一条想法都没有——
        // 前两者引导换关键词/换范围，只有真·零想法才引导「记录第一条」，
        // 否则搜索落空时出现「记录第一条想法」按钮语义错位
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let isFiltering = currentFilters != nil
            || selectedTagName != nil
            || (drawerSelection != nil && drawerSelection != .aiOrganize)
        let icon = isSearching ? "magnifyingglass" : "lightbulb"
        let title = isSearching ? "没有找到相关想法" : (isFiltering ? "该范围内暂无想法" : "暂无想法")
        let caption = isSearching ? "换个关键词试试"
            : (isFiltering ? "换个范围，或清空筛选再看看" : "一闪而过的念头，都值得留下来")
        return VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text(caption)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))

            // 空态行动按钮（激活方案 §3.2）：一键直达编辑器，替代「找右下角 +」
            // 仅真·零想法出现（搜索/筛选空态点它不符合用户当下意图）
            if !isSearching && !isFiltering {
                Button {
                    showAddThought = true
                } label: {
                    Label(String(localized: "记录第一条想法"), systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.holoPrimary)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityIdentifier("thoughtEmptyCta")
            }

            if ICloudSyncStatusService.shared.isInitialSyncPending {
                Text("正在从 iCloud 恢复数据，稍等片刻就会显示")
                    .font(.holoCaption)
                    .foregroundColor(.holoInfo)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

// MARK: - Preview

#Preview {
    ThoughtsView()
}
