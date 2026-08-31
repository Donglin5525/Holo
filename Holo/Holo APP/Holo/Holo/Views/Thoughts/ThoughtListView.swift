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

    /// 筛选状态
    @State private var selectedTagName: String? = nil
    @State private var searchText: String = ""
    /// Cmd+F 聚焦搜索栏（硬件键盘快捷键）
    @FocusState private var searchFieldFocused: Bool
    @State private var showFilterSheet: Bool = false
    @State private var currentFilters: ThoughtFilters? = nil

    /// 浏览模式：timeline 想法 / knowledge 知识树。
    /// 每次进入固定回到「想法」，不记忆上次的浏览模式（产品要求默认落在想法列表）。
    @State private var browseMode: String = "timeline"

    /// 知识树模式下的主题管理 sheet
    @State private var showTopicManagement: Bool = false

    /// 清空想法数据 sheet（数据清理功能，进 30 天回收站）
    @State private var showClearThoughtSheet: Bool = false

    /// 待确认池（想法列表 banner 入口）
    @State private var showConfirmationQueue: Bool = false

    /// 待确认数量（banner 徽章用）
    @State private var pendingConfirmationCount: Int = 0

    /// 选中的想法（用于进入详情）
    @State private var selectedThoughtId: UUID? = nil

    /// 双击卡片直接进入编辑器
    @State private var editingThoughtId: UUID? = nil

    /// 所有想法
    @State private var thoughts: [Thought] = []

    /// 是否已完成首次加载（避免入场时空态先闪现、再被列表替换的分批出现感）
    @State private var hasLoadedOnce = false

    /// 所有标签
    @State private var allTags: [ThoughtTag] = []

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

    /// 用户从外层「自动整理」启动批量标签整理后，完成时继续归纳主题
    @State private var shouldRunTopicConvergenceAfterBatch: Bool = false

    /// 列表刷新节流任务（避免批量整理时通知风暴拖卡主线程）
    @State private var refreshTask: Task<Void, Never>?
    /// P0 卡片分级判定：用户认可标签集合（归一化 key），列表层一次查询避免逐卡片 N+1
    @State private var recognizedTagKeys: Set<String> = []

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

        // 按搜索文本筛选
        if !searchText.isEmpty {
            result = result.filter { thought in
                thought.content.localizedCaseInsensitiveContains(searchText) ||
                (thought.tagArray.map(\.name) + thought.visibleAITagNames).contains {
                    $0.localizedCaseInsensitiveContains(searchText)
                }
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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerView

            // 想法 / 知识树 切换
            browseModeSegment

            if isKnowledgeMode {
                ThoughtKnowledgeTreeView(
                    thoughtRepository: thoughtRepository,
                    topicRepository: topicRepository,
                    onNavigateToList: { node in
                        browseMode = "timeline"
                        // 同值重复赋值不触发 onChange，需手动重载（否则停留在旧数据）
                        let isSameNode = drawerSelection == node
                        drawerSelection = node
                        if isSameNode {
                            reloadByDrawer()
                        }
                    },
                    onAIOrganize: { onAIOrganize() }
                )
            } else {
                // 搜索栏
                searchBarView

                // AI 归纳状态条
                aiOrganizationBanner

                // 筛选栏
                filterBarView

                // 想法列表
                if filteredThoughts.isEmpty && hasLoadedOnce {
                    emptyStateView
                } else {
                    thoughtListView
                }
            }
        }
        // 主列表先进入详情，阅读、引用关系与编辑入口保持同一条产品路径。
        // 编辑器仍由详情页的「编辑」动作打开，避免列表入口绕过反向链接。
        .fullScreenCover(item: $selectedThoughtId) { thoughtId in
            ThoughtDetailView(
                thoughtId: thoughtId,
                thoughtRepository: ThoughtRepository(),
                showsDismissButton: true
            )
            .holoContentColumn()
        }
        .fullScreenCover(item: $editingThoughtId) { thoughtId in
            ThoughtEditorView(
                onSave: {
                    loadThoughts()
                    loadTags()
                    loadUnprocessedCount()
                },
                editingThoughtId: thoughtId,
                autoFocusExistingThought: true
            )
            .holoContentColumn()
        }
        // ThoughtDetailView 点「问问 Holo」后通知关闭整个 fullScreenCover，
        // 否则 cover 仍盖在 AI 页之上（dismiss 只能 pop 一层 NavigationStack）。
        .onReceive(NotificationCenter.default.publisher(for: .holoRequestCloseThoughtEditor)) { _ in
            selectedThoughtId = nil
        }
        .sheet(isPresented: $showFilterSheet) {
            ThoughtFilterSheetView(onApplyFilters: { filters in
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
            // 想法模块已常驻时，任务页再次跳转也要能打开新的详情。
            if let newValue {
                selectedThoughtId = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            // 节流：批量整理每条完成都发通知，合并 500ms 后统一刷新，避免主线程卡顿
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
        .onChange(of: drawerSelection) { _, newValue in
            // 外部筛选请求（如编辑器/详情页「查看标签」）只有想法列表能承载；
            // 用户停在知识树时先切回列表，再执行筛选重载。
            if newValue != nil, newValue != .aiOrganize, isKnowledgeMode {
                browseMode = "timeline"
            }
            reloadByDrawer()
        }
        .onChange(of: orgQueue.isBatchOrganizing) { oldValue, newValue in
            guard oldValue, !newValue, shouldRunTopicConvergenceAfterBatch else { return }
            shouldRunTopicConvergenceAfterBatch = false
            loadUnprocessedCount()

            guard !orgQueue.dailyLimitHit else {
                batchOrganizeNotice = "标签整理已暂停，配额恢复后再继续归纳主题"
                return
            }

            batchOrganizeNotice = "标签整理完成，正在归纳主题"
            onAIOrganize()
        }
    }

    // MARK: - AI 归纳状态条

    /// 是否有想法正在被 AI 处理（单条增量整理）
    private var hasProcessingThoughts: Bool {
        thoughts.contains { $0.organizedStatus == "processing" }
    }

    /// AI 归纳状态条（批量进度 / 配额耗尽 / 单条增量三态）
    private var aiOrganizationBanner: some View {
        Group {
            if orgQueue.isBatchOrganizing, let total = orgQueue.batchTotal {
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
        .animation(.easeInOut(duration: 0.3), value: orgQueue.isBatchOrganizing)
        .animation(.easeInOut(duration: 0.3), value: orgQueue.dailyLimitHit)
        .animation(.easeInOut(duration: 0.3), value: pendingConfirmationCount)
        .animation(.easeInOut(duration: 0.3), value: hasProcessingThoughts)
    }

    // MARK: - 数据加载

    private func loadThoughts() {
        // 抽屉筛选生效时保持筛选语义（删除/归档/通知后的刷新也走这里，不能退回全部）
        if drawerSelection != nil, drawerSelection != .aiOrganize {
            reloadByDrawer()
            return
        }
        do {
            thoughts = try thoughtRepository.fetchAll()
            currentFilters = nil
            recognizedTagKeys = Set(thoughtRepository.fetchUserRecognizedTagNames()
                .map { ThoughtTagNormalizer.key($0) })
        } catch {
            logger.error("加载想法失败：\(error)")
            thoughts = []
        }
        hasLoadedOnce = true
    }

    /// 抽屉节点变化时按筛选意图重新加载（P1.4）
    private func reloadByDrawer() {
        // 互斥：抽屉主导时清 chip 标签筛选
        if drawerSelection != nil {
            selectedTagName = nil
        }
        currentFilters = nil
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
            case .topic(let topicId):
                thoughts = try topicRepository.fetchThoughts(byTopic: topicId)
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
                // 否则使用筛选方法加载
                var allThoughts = try thoughtRepository.fetchAll()

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
    }

    // MARK: - 批量自动整理

    /// 加载待整理数量（chip 徽章）
    private func loadUnprocessedCount() {
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
            batchOrganizeNotice = "今日 AI 额度已用尽，剩余条目明天自动续做"
            return
        }
        if unprocessedCount == 0 {
            batchOrganizeNotice = "正在归纳主题"
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
                batchOrganizeNotice = "没有需要整理的想法"
                return
            }
            try thoughtRepository.markBatchPending(thoughtIds: ids)
            shouldRunTopicConvergenceAfterBatch = true
            orgQueue.enqueueBatch(thoughtIds: ids)
            batchOrganizeNotice = "已开始整理 \(ids.count) 条想法，完成后会归纳主题"
        } catch {
            logger.error("启动批量整理失败：\(error)")
            batchOrganizeNotice = "启动失败，请稍后重试"
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
            }
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
            Text("观点")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

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
            segmentItem(title: "想法", icon: "lightbulb.fill", key: "timeline")
            segmentItem(title: "知识树", icon: "folder.fill", key: "knowledge")
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
            withAnimation(.easeInOut(duration: 0.2)) {
                browseMode = key
            }
            HapticManager.light()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .white : .holoTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm + 2)
                    .fill(isSelected ? Color.holoPrimary : Color.clear)
            )
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

    // MARK: - 筛选栏

    private var filterBarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 全部标签
                HoloFilterChip(
                    title: "全部",
                    iconColor: .holoPrimary,
                    isSelected: selectedTagName == nil
                ) {
                    selectedTagName = nil
                    drawerSelection = nil
                }

                // 自动整理动作 chip（橙色主操作 + 小型紫色 AI 来源标识）
                ThoughtOrganizeActionChip(
                    pendingCount: unprocessedCount,
                    isOrganizing: orgQueue.isBatchOrganizing
                ) {
                    handleOrganizeChipTap()
                }

                // 从卡片点击的非常用标签也要在顶部显示当前筛选状态。
                if let selectedTagName,
                   !frequentTags.contains(where: {
                       ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key(selectedTagName)
                   }) {
                    HoloFilterChip(
                        title: selectedTagName,
                        iconColor: .holoPrimary,
                        isSelected: true
                    ) {
                        self.selectedTagName = nil
                    }
                }

                // 常用标签
                ForEach(frequentTags) { tag in
                    HoloFilterChip(
                        title: tag.name,
                        iconColor: tag.tagColor,
                        isSelected: selectedTagName == tag.name
                    ) {
                        selectedTagName = tag.name
                        drawerSelection = nil
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
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }

    // MARK: - 想法列表

    private var thoughtListView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(filteredThoughts) { thought in
                    SwipeActionView(
                        isRevealed: Binding(
                            get: { revealedThoughtId == thought.id },
                            set: { if $0 { revealedThoughtId = thought.id } else { revealedThoughtId = nil } }
                        ),
                        isEnabled: true,
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
                                onEdit: {
                                    // 双击识别晚于单击时，先撤销可能已经排队的详情 cover，
                                    // 保证最终只呈现编辑器，不出现详情和编辑器叠层。
                                    selectedThoughtId = nil
                                    revealedThoughtId = nil
                                    editingThoughtId = thought.id
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
                                onRetryOrganize: thought.organizedStatus == "failed" ? {
                                    ThoughtOrganizationQueue.shared.enqueueManual(thoughtId: thought.id)
                                } : nil,
                                onDelete: {
                                    deleteThought(thought)
                                },
                                archiveActionTitle: isArchivedView ? "恢复" : "归档",
                                recognizedTagKeys: recognizedTagKeys
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
        let prefill = "关于这条想法「\(snippet)」，帮我展开想想，或者拆成可执行的待办"
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
            loadThoughts()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("归档/恢复想法失败: \(error.localizedDescription)")
            HoloToastCenter.shared.show("操作失败，请重试", type: .error)
        }
    }

    /// 删除想法
    private func deleteThought(_ thought: Thought) {
        do {
            try thoughtRepository.delete(thought.id)
            revealedThoughtId = nil
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            loadThoughts()
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("删除想法失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lightbulb")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text("暂无想法")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("点右下角 + 记录第一条想法")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

// MARK: - Preview

#Preview {
    ThoughtsView()
}
