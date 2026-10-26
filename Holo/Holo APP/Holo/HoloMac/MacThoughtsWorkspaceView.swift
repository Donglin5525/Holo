//
//  MacThoughtsWorkspaceView.swift
//  HoloMac
//
//  想法模块三栏浏览工作台（Phase B：只读浏览/搜索/查看，编辑器 Phase C 交付）
//
//  - 侧栏：macOS 原生 List(.sidebar) 承载浏览范围树；数据层全量复用 iOS 侧栏
//    （ThoughtBrowseScope 范围唯一事实源、ThoughtSidebarTagTreeBuilder 标签树、
//    ThoughtSidebarPreference 置顶/展开本机导航偏好），不用 iOS 的抽屉拖拽形态
//  - 中栏：MacThoughtListColumnView（复用 ThoughtCardView 渲染 + Repository 谓词）
//  - 右栏：MacThoughtDetailView（Mac 专属只读详情）
//  编辑（Phase C 交付）：工具栏「新建想法」(⌘N)、卡片右键「编辑」、右栏「编辑」
//  统一大 sheet 打开 MacThoughtEditorView；保存走 +EditorCommit 管线，列表经
//  .thoughtDataDidChange 通知自动刷新。
//  AI 整理（Phase E）：工具栏齿轮开想法设置；中栏列表头「发现新主题」触发跨想法
//  归并确认（ConvergenceConfirmView）；归并任务与建议缓存复用 iOS 同一单例/存储。
//

import SwiftUI
import Combine
import CoreData
import OSLog

// MARK: - 浏览模型

/// 中栏列表数据源。范围 → 查询与 ThoughtListView.reloadByDrawer 同一套
/// Repository 谓词（fetchAll / fetchThoughts(byTopic:) / fetchThoughtsByUserTag /
/// fetchArchived）；「全部想法」下搜索直接走 ThoughtRepository.search 的既有
/// 谓词，其余范围内沿同一 CONTAINS 语义做内存过滤（范围与搜索叠加不退回全库）。
/// 不显式标 @MainActor：工程默认 MainActor 隔离 + InferIsolatedConformances 下，
/// 显式标注会把 ObservableObject conformance 变成隔离 conformance 而无法满足。
final class MacThoughtsBrowserModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacThoughtsWorkspace")

    @Published var scope: ThoughtBrowseScope = .all
    @Published var searchText: String = ""
    @Published var sortOption: ThoughtSortOption = .createdAtDescending
    @Published private(set) var thoughts: [Thought] = []
    /// 首次加载完成标志（避免入场时空态先闪现，同 ThoughtListView 口径）
    @Published private(set) var hasLoadedOnce = false
    /// P0 卡片分级判定输入：用户认可标签集合（与 reloadByDrawer 同源）
    @Published private(set) var recognizedTagKeys: Set<String> = []
    /// 主题 id → 标题缓存（中栏范围标题显示用）
    @Published var topicTitleCache: [UUID: String] = [:]

    private let thoughtRepository = ThoughtRepository()
    private let topicRepository = TopicRepository()
    /// 刷新节流任务（AI 整理/iCloud 同步会成串广播，与 iOS 列表同理由合并处理）
    private var reloadTask: Task<Void, Never>?

    /// 搜索输入与通知刷新的统一节流入口（300ms 内合并）
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        guard CoreDataStack.shared.isReady else { return }
        recognizedTagKeys = Set(thoughtRepository.fetchUserRecognizedTagNames()
            .map { ThoughtTagNormalizer.key($0) })

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Thought]
        do {
            switch scope {
            case .all:
                result = query.isEmpty
                    ? try thoughtRepository.fetchAll()
                    : try thoughtRepository.search(query: query)
            case .topic(let topicId):
                result = try topicRepository.fetchThoughts(byTopic: topicId)
                if let topic = try? topicRepository.fetchTopicById(topicId) {
                    topicTitleCache[topicId] = topic.title
                }
            case .userTag(let pathKey):
                result = try thoughtRepository.fetchThoughtsByUserTag(pathKey: pathKey)
            case .archived:
                result = try thoughtRepository.fetchArchived()
            }
            if !query.isEmpty, scope != .all {
                result = Self.keywordMatches(result, query: query)
            }
        } catch {
            Self.logger.error("加载想法失败：\(error)")
            result = []
        }
        thoughts = Self.sorted(result, by: sortOption)
        hasLoadedOnce = true
    }

    /// 与 ThoughtRepository.search 谓词同语义的内存过滤（正文 / 标签名 CONTAINS[cd]）。
    /// search 谓词不带范围条件，主题/标签/归档范围内必须保持结果仍落在该范围内。
    private static func keywordMatches(_ thoughts: [Thought], query: String) -> [Thought] {
        thoughts.filter { thought in
            thought.content.localizedCaseInsensitiveContains(query)
                || thought.tagArray.map(\.name).contains { $0.localizedCaseInsensitiveContains(query) }
                || thought.visibleAITagNames.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private static func sorted(_ thoughts: [Thought], by option: ThoughtSortOption) -> [Thought] {
        switch option {
        case .createdAtDescending: return thoughts.sorted { $0.createdAt > $1.createdAt }
        case .createdAtAscending: return thoughts.sorted { $0.createdAt < $1.createdAt }
        case .updatedAtDescending: return thoughts.sorted { $0.updatedAt > $1.updatedAt }
        case .mood: return thoughts.sorted { ($0.mood ?? "") < ($1.mood ?? "") }
        }
    }
}

// MARK: - 工作台根视图

struct MacThoughtsWorkspaceView: View {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacThoughtsWorkspace")

    @StateObject private var model = MacThoughtsBrowserModel()
    /// 中栏点选 → 右栏详情联动（跨栏唯一选中态）
    @State private var selectedThoughtId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 编辑器会话（nil = 无编辑器打开；thoughtId == nil = 新建）
    @State private var editorRequest: MacThoughtEditorRequest?

    // MARK: - AI 整理（Phase E，与 iOS ThoughtsView 同一组宿主状态）

    /// 跨想法标签归并确认任务（复用 iOS 单例：持久化待确认建议冷启动即恢复）
    @StateObject private var convergenceJob: ThoughtTagConvergenceJob
    @State private var showConvergence = false
    /// 整理设置（ThoughtOrganizationSettingsView 跨平台直接宿主）
    @State private var showOrganizationSettings = false

    private let topicRepository = TopicRepository()
    /// 归档/删除写库（与 iOS 列表左滑、编辑器「…」菜单同一 Repository 管线）
    private let thoughtRepository = ThoughtRepository()

    init() {
        self._convergenceJob = StateObject(wrappedValue: ThoughtTagConvergenceJob.shared)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacThoughtsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            MacThoughtListColumnView(
                model: model,
                selectedThoughtId: $selectedThoughtId,
                onEditThought: { thoughtId in
                    editorRequest = MacThoughtEditorRequest(thoughtId: thoughtId)
                },
                onArchiveThought: toggleArchiveThought,
                onDeleteThought: deleteThought,
                onDiscoverTopics: {
                    startTopicConvergence()
                })
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 620)
        } detail: {
            MacThoughtDetailView(
                thoughtId: selectedThoughtId,
                listThoughts: model.thoughts,
                onOpenThought: { selectedThoughtId = $0 },
                onEditThought: { thoughtId in
                    editorRequest = MacThoughtEditorRequest(thoughtId: thoughtId)
                },
                onArchiveThought: toggleArchiveThought,
                onDeleteThought: deleteThought,
                onTagTap: { tagName in
                    model.scope = .userTag(
                        pathKey: ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(tagName)))
                })
        }
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar {
            // 新建想法（Phase C）：⌘N 直达编辑器；对齐 Mac 惯例的主操作位
            ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                Button {
                    editorRequest = MacThoughtEditorRequest(thoughtId: nil)
                } label: {
                    Label(String(localized: "新建想法"), systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("mac.thought.newButton")
            }
            // 整理设置（Phase E）：工具栏齿轮打开想法设置（开关与 iPhone 同一存储口径）
            ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                Button {
                    showOrganizationSettings = true
                } label: {
                    Label(String(localized: "想法设置"), systemImage: "gearshape")
                }
                .accessibilityIdentifier("mac.thought.settingsButton")
            }
        }
        // 大编辑窗（对齐 iOS fullScreenCover 的全屏语义，Mac 用大 sheet 承载）
        .sheet(item: $editorRequest) { request in
            MacThoughtEditorView(
                editingThoughtId: request.thoughtId,
                onBrowseTag: { path in
                    // Token 菜单「查看标签」：切浏览范围（编辑器会自行关闭）
                    model.scope = .userTag(
                        pathKey: ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(path)))
                },
                onDeleteThought: { thoughtId in
                    // 编辑器删除的正是右栏选中时收掉选中态（列表经通知自动刷新）
                    if selectedThoughtId == thoughtId { selectedThoughtId = nil }
                })
        }
        // 跨想法标签归并确认（Phase E：ConvergenceConfirmView 跨平台，直接宿主）
        .sheet(isPresented: $showConvergence) {
            ConvergenceConfirmView(
                job: convergenceJob,
                topicRepository: topicRepository,
                rejectionRepository: ConvergenceRejectionRepository())
                .frame(minWidth: 460, minHeight: 560)
        }
        // 整理设置（Phase E：与 iPhone 共用同一 UserDefaults 开关口径）
        .sheet(isPresented: $showOrganizationSettings) {
            ThoughtOrganizationSettingsView()
                .frame(minWidth: 480, minHeight: 560)
        }
        .task {
            // 与 MacSyncVerifyView/HoloApp 相同的启动序：先触发容器懒加载再等就绪
            CoreDataStack.shared.prepareIfNeeded()
            await CoreDataStack.shared.waitUntilReady()
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            model.scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoCloudDataDidSync)) { _ in
            // iCloud 云端数据到达：新设备后台导入晚于首载，收到广播即刷新
            model.scheduleReload()
        }
        .onChange(of: model.scope) { _, _ in
            // 切浏览范围 = 换一组内容：右栏退回引导位（选中想法多半不在新范围内）
            selectedThoughtId = nil
        }
    }

    /// 统一的主题归纳入口（与 iOS ThoughtsView.startTopicConvergence 同逻辑）：
    /// 已有可确认建议时直接展示，否则触发一次归并生成（绝不自动应用）。
    private func startTopicConvergence() {
        showConvergence = true
        if case .ready = convergenceJob.state { return }
        Task { await convergenceJob.run(autoApply: false, persist: false) }
    }

    // MARK: - 归档 / 删除（卡片右键、右栏头部、编辑器「…」菜单共用）

    /// 归档/移出归档（ThoughtRepository.archive/unarchive，与 iOS 列表左滑同通道；
    /// 文案按 thought.isArchived 切换）。归档态变化后卡片会离开当前浏览范围：
    /// 若正是右栏选中项，右栏回空态。
    private func toggleArchiveThought(_ thought: Thought) {
        do {
            if thought.isArchived {
                try thoughtRepository.unarchive(thought.id)
            } else {
                try thoughtRepository.archive(thought.id)
            }
        } catch {
            Self.logger.error("归档/移出归档失败：\(error.localizedDescription)")
            return
        }
        if selectedThoughtId == thought.id {
            selectedThoughtId = nil
        }
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }

    /// 删除想法（ThoughtRepository.delete 软删进 30 天回收站，与 iOS 同口径）。
    /// 各入口先经二次确认再调到这里。
    private func deleteThought(_ thought: Thought) {
        do {
            try thoughtRepository.delete(thought.id)
        } catch {
            Self.logger.error("删除想法失败：\(error.localizedDescription)")
            return
        }
        if selectedThoughtId == thought.id {
            selectedThoughtId = nil
        }
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
    }
}

// MARK: - 侧栏（浏览范围树）

/// 侧栏 UI 壳为 macOS 原生 List(.sidebar)；数据与持久化逻辑复用
/// ThoughtSidebarView 的数据层（主题/标签树/置顶/展开），主题候选建议簇
/// （含建立/忽略写入）不带入 Phase B。
struct MacThoughtsSidebar: View {

    @ObservedObject var model: MacThoughtsBrowserModel

    private let thoughtRepository = ThoughtRepository()
    private let topicRepository = TopicRepository()

    @State private var topics: [Topic] = []
    @State private var tagTree: [ThoughtSidebarTagNode] = []
    @State private var pins: [ThoughtSidebarPin] = []
    @State private var expandedPaths: Set<String> = []
    /// 标签名 → 展示名缓存（置顶行显示用，与 iOS 侧栏同构）
    @State private var tagDisplayByKey: [String: String] = [:]
    /// emoji 图标变更只刷显示层（行内读 Store 内存字典，tick 驱动重算）
    @State private var emojiTick = 0
    /// 通知刷新节流任务（与 iOS 侧栏同样合并 400ms 内的重复通知）
    @State private var refreshTask: Task<Void, Never>?

    private var scopeSelection: Binding<ThoughtBrowseScope?> {
        Binding(
            get: { model.scope },
            set: { model.scope = $0 ?? .all })
    }

    var body: some View {
        List(selection: scopeSelection) {
            Section(String(localized: "想法")) {
                Label(String(localized: "全部想法"), systemImage: "tray.full")
                    .tag(ThoughtBrowseScope.all)
            }

            if !pins.isEmpty {
                Section(String(localized: "置顶")) {
                    ForEach(pins) { pin in
                        if let pinScope = pin.scope {
                            sidebarPinRow(pin, scope: pinScope)
                        }
                    }
                }
            }

            Section(String(localized: "主题")) {
                ForEach(topics, id: \.id) { topic in
                    topicRow(topic)
                }
            }

            Section(String(localized: "我的 #标签")) {
                ForEach(tagTree) { node in
                    MacSidebarTagNodeRow(
                        node: node,
                        expandedPaths: $expandedPaths,
                        isPinned: isPinned,
                        onTogglePin: togglePin)
                }
            }

            Section {
                Label(String(localized: "已归档"), systemImage: "archivebox")
                    .tag(ThoughtBrowseScope.archived)
            }
        }
        .listStyle(.sidebar)
        .task {
            await CoreDataStack.shared.waitUntilReady()
            loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoCloudDataDidSync)) { _ in
            scheduleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: ThoughtTagEmojiStore.didChangeNotification)) { _ in
            emojiTick &+= 1
        }
    }

    // MARK: - 数据（与 ThoughtSidebarView.loadData 同源，去掉语义建议簇）

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            loadData()
        }
    }

    private func loadData() {
        guard CoreDataStack.shared.isReady else { return }
        // 侧栏是回看入口：空的预设主题留在管理页，不占据找回内容的空间
        topics = ((try? topicRepository.fetchVisibleTopics()) ?? [])
            .filter { topicRepository.thoughtCount(of: $0) > 0 }
        let names = thoughtRepository.fetchUserRecognizedTagNames(limit: 400)
        tagTree = ThoughtSidebarTagTreeBuilder.build(from: names)
        var displayByKey: [String: String] = [:]
        for name in names {
            displayByKey[ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(name))] =
                ThoughtTagNormalizer.displayPath(name)
        }
        tagDisplayByKey = displayByKey
        pins = ThoughtSidebarPreference.loadPins().filter { pin in
            // 置顶指向的节点不存在时静默清理（主题已删/标签已改名）
            switch pin.kind {
            case .topic: return topics.contains { $0.id == pin.topicID }
            case .userTag:
                guard let key = pin.tagPathKey else { return false }
                return displayByKey[key] != nil
            }
        }
        expandedPaths = ThoughtSidebarPreference.loadExpandedTagPaths()
    }

    // MARK: - 行

    private func topicRow(_ topic: Topic) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.holoSuccessText)
            VStack(alignment: .leading, spacing: 1) {
                Text(topic.title)
                    .lineLimit(1)
                // 与 iOS 侧栏同口径的投影计数
                Text(String(localized: "\(ThoughtTopicLinkProjection.effectiveActiveThoughtCount(of: topic)) 条想法"))
                    .font(.holoTinyLabel)
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(ThoughtBrowseScope.topic(topic.id))
        .contextMenu {
            pinMenuButton(ThoughtSidebarPin(kind: .topic, topicID: topic.id, tagPathKey: nil))
        }
    }

    private func sidebarPinRow(_ pin: ThoughtSidebarPin, scope: ThoughtBrowseScope) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pin.kind == .topic ? "leaf.fill" : "number")
                .font(.system(size: 11))
                .foregroundStyle(pin.kind == .topic ? Color.holoSuccessText : Color.secondary)
            Text(pinDisplayTitle(pin))
                .lineLimit(1)
        }
        .tag(scope)
        .contextMenu {
            Button {
                togglePin(pin)
            } label: {
                Label("取消置顶", systemImage: "pin.slash")
            }
        }
    }

    /// 置顶行显示名（与 ThoughtSidebarView.pinDisplayTitle 同逻辑：主题查标题、
    /// 标签查展示名缓存，有 emoji 图标时以图标开头）
    private func pinDisplayTitle(_ pin: ThoughtSidebarPin) -> String {
        switch pin.kind {
        case .topic:
            return topics.first { $0.id == pin.topicID }?.title ?? ""
        case .userTag:
            guard let key = pin.tagPathKey else { return "" }
            let display = tagDisplayByKey[key] ?? key
            if let emoji = ThoughtTagEmojiStore.emoji(forKey: key) {
                return "\(emoji) \(display)"
            }
            return display
        }
    }

    // MARK: - 置顶（导航偏好，本机持久化，复用 iOS 同一套存储）

    private func isPinned(_ pin: ThoughtSidebarPin) -> Bool {
        pins.contains { $0.id == pin.id }
    }

    private func togglePin(_ pin: ThoughtSidebarPin) {
        if isPinned(pin) {
            pins.removeAll { $0.id == pin.id }
        } else {
            pins.append(pin)
        }
        ThoughtSidebarPreference.savePins(pins)
    }

    @ViewBuilder
    private func pinMenuButton(_ pin: ThoughtSidebarPin) -> some View {
        Button {
            togglePin(pin)
        } label: {
            if isPinned(pin) {
                Label("取消置顶", systemImage: "pin.slash")
            } else {
                Label("置顶", systemImage: "pin")
            }
        }
    }
}

// MARK: - 标签树节点（递归 DisclosureGroup，展开态复用 ThoughtSidebarPreference）

private struct MacSidebarTagNodeRow: View {

    let node: ThoughtSidebarTagNode
    @Binding var expandedPaths: Set<String>
    let isPinned: (ThoughtSidebarPin) -> Bool
    let onTogglePin: (ThoughtSidebarPin) -> Void

    private var scope: ThoughtBrowseScope {
        .userTag(pathKey: node.fullPathKey)
    }

    /// 有 emoji 图标时以图标代替 # 前缀（与 iOS 标签树一致）
    private var emoji: String? {
        ThoughtTagEmojiStore.emoji(forKey: node.fullPathKey)
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expandedPaths.contains(node.fullPathKey) },
            set: { isExpanded in
                if isExpanded {
                    expandedPaths.insert(node.fullPathKey)
                } else {
                    expandedPaths.remove(node.fullPathKey)
                }
                ThoughtSidebarPreference.saveExpandedTagPaths(expandedPaths)
            })
    }

    var body: some View {
        if node.children.isEmpty {
            tagLabel
                .tag(scope)
                .contextMenu { pinMenu() }
        } else {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    MacSidebarTagNodeRow(
                        node: child,
                        expandedPaths: $expandedPaths,
                        isPinned: isPinned,
                        onTogglePin: onTogglePin)
                }
            } label: {
                tagLabel
                    .tag(scope)
                    .contextMenu { pinMenu() }
            }
        }
    }

    private var tagLabel: some View {
        HStack(spacing: 6) {
            if let emoji {
                Text(emoji)
                    .font(.system(size: 12))
            } else {
                Image(systemName: "number")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
            Text(node.displayName)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func pinMenu() -> some View {
        let pin = ThoughtSidebarPin(kind: .userTag, topicID: nil, tagPathKey: node.fullPathKey)
        Button {
            onTogglePin(pin)
        } label: {
            if isPinned(pin) {
                Label("取消置顶", systemImage: "pin.slash")
            } else {
                Label("置顶", systemImage: "pin")
            }
        }
    }
}
