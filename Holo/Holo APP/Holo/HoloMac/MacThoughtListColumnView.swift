//
//  MacThoughtListColumnView.swift
//  HoloMac
//
//  三栏工作台 · 中栏：想法列表（只读浏览）
//
//  列表卡片直接复用 ThoughtCardView（纸感渲染/标签 chips/附件/状态徽章同一套），
//  数据查询复用 MacThoughtsBrowserModel（ThoughtRepository/TopicRepository 谓词）。
//  卡片点按 = 选中并联动右栏详情；Phase C：卡片右键菜单「编辑」直达编辑器
//  （iOS「…」菜单的编辑兜底入口在 Mac 以右键形态承载）。
//  卡片右键另承载「归档/移出归档」（iOS 列表左滑的对位）与「删除想法」
//  （destructive + 二次确认，删除走软删进 30 天回收站，与 iOS 同口径）；
//  写库与选中态联动由工作台统一承担，列表经 .thoughtDataDidChange 通知刷新。
//  AI 整理（Phase E）：列表头「发现新主题」入口 + 待确认池计数横幅
//  （TopicConfirmationQueueView，与 iOS ThoughtListView 同一数据源与文案）。
//

import SwiftUI

struct MacThoughtListColumnView: View {

    @ObservedObject var model: MacThoughtsBrowserModel
    /// 点选联动右栏（由工作台持有，跨栏唯一选中态）
    @Binding var selectedThoughtId: UUID?
    /// 卡片右键「编辑」：打开编辑器（由工作台持有 sheet）
    var onEditThought: (UUID) -> Void = { _ in }
    /// 卡片右键「归档/移出归档」：写库与选中态联动由工作台统一承担
    var onArchiveThought: (Thought) -> Void = { _ in }
    /// 卡片右键「删除想法」：二次确认后由工作台软删（与 iOS 同口径）
    var onDeleteThought: (Thought) -> Void = { _ in }
    /// 「发现新主题」：触发跨想法归并确认（由工作台持有 ConvergenceConfirmView sheet）
    var onDiscoverTopics: () -> Void = {}

    @FocusState private var searchFieldFocused: Bool
    /// 标签 emoji 图标变更只刷显示层（Store 读内存字典，tick 驱动列表重算）
    @State private var emojiDisplayTick = 0

    // MARK: - AI 整理（Phase E，与 iOS ThoughtListView 同一组入口状态）

    private let thoughtRepository = ThoughtRepository()
    private let topicRepository = TopicRepository()
    /// 待确认池计数（AI 低置信主题归属；iOS 列表头同一数据源）
    @State private var pendingConfirmationCount: Int = 0
    @State private var showConfirmationQueue = false
    /// 右键「删除想法」待确认的想法（非 nil 即弹二次确认）
    @State private var deleteConfirmThought: Thought?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            confirmationBanner
            Divider()
            if model.thoughts.isEmpty, model.hasLoadedOnce {
                emptyStateView
            } else {
                thoughtListView
            }
        }
        .background(Color.holoToolBackground)
        .onChange(of: model.searchText) { _, _ in
            // 输入节流合并进 model（300ms），避免逐字全量查询
            model.scheduleReload()
        }
        .onChange(of: model.sortOption) { _, _ in
            model.reload()
        }
        // ⌘F：菜单栏「视图 > 搜索想法」广播 → 聚焦搜索框（沿用全 App 快捷键总线）
        .onReceive(HoloShortcutBus.shared.$lastEvent) { event in
            guard event?.action == .searchInCurrentModule else { return }
            searchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ThoughtTagEmojiStore.didChangeNotification)) { _ in
            emojiDisplayTick &+= 1
        }
        // AI 归类/主题归属结果落库后刷新待确认计数（与 iOS loadPendingConfirmationCount 触发源一致）
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            loadPendingConfirmationCount()
        }
        .task {
            await CoreDataStack.shared.waitUntilReady()
            loadPendingConfirmationCount()
        }
        .sheet(isPresented: $showConfirmationQueue, onDismiss: {
            loadPendingConfirmationCount()
        }) {
            TopicConfirmationQueueView(
                thoughtRepository: thoughtRepository,
                topicRepository: topicRepository,
                onQueueDrained: { loadPendingConfirmationCount() })
                .frame(minWidth: 460, minHeight: 520)
        }
        // 右键「删除想法」二次确认（标题/按钮/正文与 iOS 编辑器删除确认同一文案）
        .confirmationDialog(
            "删除这条想法？",
            isPresented: Binding(
                get: { deleteConfirmThought != nil },
                set: { if !$0 { deleteConfirmThought = nil } }),
            titleVisibility: .visible,
            presenting: deleteConfirmThought
        ) { thought in
            Button("删除", role: .destructive) {
                onDeleteThought(thought)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            // 单条删除已建批次进回收站（2026-09-06 拍板），30 天内可在最近删除自助恢复
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。"))
        }
    }

    // MARK: - 顶部（范围标题 + 搜索 + 排序）

    private var headerView: some View {
        HStack(spacing: HoloSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text(String(localized: "\(model.thoughts.count) 条想法"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer(minLength: HoloSpacing.md)

            searchBarView

            // 发现新主题（Phase E）：跨想法归并确认入口（iOS 知识树入口的 Mac 对位）
            Button {
                onDiscoverTopics()
            } label: {
                Label(String(localized: "发现新主题"), systemImage: "sparkles")
                    .font(.holoLabel)
                    .foregroundColor(Color.holoToolAction)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.thought.discoverTopicsButton")

            sortPicker
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolBackground)
    }

    // MARK: - AI 整理入口横幅（与 iOS ThoughtListView 列表头同款）

    /// 待确认池入口：AI 低置信主题归属（有计数才出现，处理完自动消失）
    @ViewBuilder
    private var confirmationBanner: some View {
        if pendingConfirmationCount > 0 {
            Button {
                showConfirmationQueue = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(Color.holoToolAction)

                    Text("AI 有 \(pendingConfirmationCount) 条主题归属想跟你确认")
                        .holoText(.supporting)
                        .foregroundColor(.holoToolTextSecondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoToolAction.opacity(0.06))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.thought.confirmationQueueButton")
        }
    }

    private func loadPendingConfirmationCount() {
        pendingConfirmationCount =
            (try? thoughtRepository.fetchThoughtsPendingTopicConfirmation().count) ?? 0
    }

    /// 当前范围标题（与 iOS 列表 sidebarScopeTitle 同口径）
    private var scopeTitle: String {
        switch model.scope {
        case .all:
            return String(localized: "全部想法")
        case .topic(let topicId):
            return model.topicTitleCache[topicId] ?? String(localized: "主题")
        case .userTag(let pathKey):
            return "#" + pathKey.split(separator: "/").map(String.init).joined(separator: "/")
        case .archived:
            return String(localized: "已归档")
        }
    }

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)

            TextField(String(localized: "搜索想法或标签…"), text: $model.searchText)
                .focused($searchFieldFocused)
                .textFieldStyle(.plain)
                .holoText(.supporting)
                .foregroundColor(.holoToolText)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "清空搜索"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolInset))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoToolBorder, lineWidth: 1))
        .frame(width: 220)
    }

    private var sortPicker: some View {
        Picker(String(localized: "排序"), selection: $model.sortOption) {
            Text(String(localized: "最新创建")).tag(ThoughtSortOption.createdAtDescending)
            Text(String(localized: "最早创建")).tag(ThoughtSortOption.createdAtAscending)
            Text(String(localized: "最近更新")).tag(ThoughtSortOption.updatedAtDescending)
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    // MARK: - 列表

    private var thoughtListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.thoughts) { thought in
                    ThoughtCardView(
                        thought: thought,
                        onNavigate: {
                            // Mac 语义：点卡片正文 = 选中并联动右栏（编辑器 Phase C）
                            selectedThoughtId = thought.id
                        },
                        onTagTap: { tagName in
                            // 与右栏标签 chips 同一跳转口径：切到该标签的浏览范围
                            model.scope = .userTag(
                                pathKey: ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(tagName)))
                        },
                        recognizedTagKeys: model.recognizedTagKeys)
                    .overlay {
                        if selectedThoughtId == thought.id {
                            RoundedRectangle(cornerRadius: HoloRadius.lg)
                                .strokeBorder(Color.holoPrimary, lineWidth: 1.5)
                        }
                    }
                    .contextMenu {
                        // Phase C：卡片右键直达编辑（iOS「…」菜单编辑兜底入口的 Mac 形态）
                        Button {
                            onEditThought(thought.id)
                        } label: {
                            Label(String(localized: "编辑"), systemImage: "pencil")
                        }
                        // 归档/移出归档（iOS 列表左滑的对位；文案按归档态切换）
                        Button {
                            onArchiveThought(thought)
                        } label: {
                            Label(
                                thought.isArchived
                                    ? String(localized: "移出归档")
                                    : String(localized: "归档"),
                                systemImage: "archivebox")
                        }
                        Divider()
                        Button {
                            copyThoughtToPasteboard(thought)
                        } label: {
                            Label(String(localized: "复制"), systemImage: "doc.on.doc")
                        }
                        Divider()
                        // 删除：destructive + 二次确认，软删进 30 天回收站（与 iOS 同口径）
                        Button(role: .destructive) {
                            deleteConfirmThought = thought
                        } label: {
                            Label(String(localized: "删除想法"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.xl)
        }
    }

    // MARK: - 空态（区分「搜索/范围无结果」与「没有想法」）

    private var emptyStateView: some View {
        let isSearching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let icon = isSearching ? "magnifyingglass" : "lightbulb"
        let title = isSearching ? String(localized: "没有找到相关想法") : String(localized: "该范围内暂无想法")
        let caption = isSearching ? String(localized: "换个关键词试试") : String(localized: "换个范围，或清空搜索再看看")
        return VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.3))

            Text(title)
                .holoText(.body)
                .foregroundColor(.holoToolTextSecondary)

            Text(caption)
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary.opacity(0.7))

            if ICloudSyncStatusService.shared.isInitialSyncPending {
                Text("正在从 iCloud 恢复数据，稍等片刻就会显示")
                    .holoText(.supporting)
                    .foregroundColor(.holoInfo)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
