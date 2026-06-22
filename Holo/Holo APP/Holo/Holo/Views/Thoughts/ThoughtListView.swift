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

// MARK: - ThoughtListView

/// 想法列表视图
struct ThoughtListView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtListView")

    // MARK: - Properties

    let onBack: () -> Void
    @Binding var showAddThought: Bool
    let thoughtRepository: ThoughtRepository
    let initialThoughtId: UUID?

    /// 筛选状态
    @State private var selectedTagName: String? = nil
    @State private var searchText: String = ""
    @State private var showFilterSheet: Bool = false
    @State private var currentFilters: ThoughtFilters? = nil

    /// 选中的想法（用于直接编辑）
    @State private var selectedThoughtId: UUID? = nil

    /// 所有想法
    @State private var thoughts: [Thought] = []

    /// 所有标签
    @State private var allTags: [ThoughtTag] = []

    /// 右滑展开的卡片 ID
    @State private var revealedThoughtId: UUID? = nil

    /// 自动整理队列（观察批量进度）
    @ObservedObject private var orgQueue = ThoughtOrganizationQueue.shared

    /// 待整理数量（chip 徽章用）
    @State private var unprocessedCount: Int = 0

    /// 是否显示批量整理确认 Sheet
    @State private var showBatchOrganizeSheet: Bool = false

    /// 批量整理提示文案（toast，nil 不显示）
    @State private var batchOrganizeNotice: String? = nil

    /// 列表刷新节流任务（避免批量整理时通知风暴拖卡主线程）
    @State private var refreshTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// 筛选后的想法列表
    var filteredThoughts: [Thought] {
        var result = thoughts

        // 按标签筛选
        if let tagName = selectedTagName {
            result = result.filter { thought in
                thought.tagArray.contains { $0.name == tagName }
            }
        }

        // 按搜索文本筛选
        if !searchText.isEmpty {
            result = result.filter { thought in
                thought.content.localizedCaseInsensitiveContains(searchText) ||
                thought.tagArray.contains { $0.name.localizedCaseInsensitiveContains(searchText) }
            }
        }

        return result
    }

    /// 常用标签（使用次数前 5）
    var frequentTags: [ThoughtTag] {
        let tagCounts = allTags.reduce(into: [ThoughtTag: Int]()) { result, tag in
            result[tag, default: 0] += Int(tag.usageCount)
        }
        return tagCounts.sorted { $0.value > $1.value }.prefix(5).map { $0.key }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            headerView

            // 搜索栏
            searchBarView

            // AI 归纳状态条
            aiOrganizationBanner

            // 筛选栏
            filterBarView

            // 想法列表
            if filteredThoughts.isEmpty {
                emptyStateView
            } else {
                thoughtListView
            }
        }
        .sheet(item: $selectedThoughtId) { thoughtId in
            ThoughtEditorView(editingThoughtId: thoughtId)
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
        .overlay(alignment: .top) {
            noticeToast
        }
        .onAppear {
            loadThoughts()
            loadTags()
            loadUnprocessedCount()
            if let initialThoughtId {
                selectedThoughtId = initialThoughtId
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
                        .tint(.holoAI)

                    Text("AI 自动归纳中（\(orgQueue.batchCompleted)/\(total)）")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoAI.opacity(0.06))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if orgQueue.dailyLimitHit {
                // 配额耗尽暂停
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.holoAI)

                    Text("今日整理配额已用尽，剩余条目明天自动续做")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 6)
                .background(Color.holoAI.opacity(0.06))
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        .animation(.easeInOut(duration: 0.3), value: hasProcessingThoughts)
    }

    // MARK: - 数据加载

    private func loadThoughts() {
        do {
            thoughts = try thoughtRepository.fetchAll()
            currentFilters = nil
        } catch {
            logger.error("加载想法失败：\(error)")
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
                thoughts = try thoughtRepository.search(query: searchText, filters: filters)
            } else {
                // 否则使用筛选方法加载
                var allThoughts: [Thought] = []

                // 按心情筛选
                if let mood = filters.mood {
                    allThoughts = try thoughtRepository.fetchByMood(mood)
                } else {
                    allThoughts = try thoughtRepository.fetchAll()
                }

                // 按日期范围筛选
                if let startDate = filters.startDate {
                    allThoughts = allThoughts.filter { $0.createdAt >= startDate }
                }
                if let endDate = filters.endDate {
                    // 将结束日期设置为当天 23:59:59
                    let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
                    allThoughts = allThoughts.filter { $0.createdAt <= endOfDay }
                }

                thoughts = allThoughts
            }
        } catch {
            logger.error("加载想法失败：\(error)")
            thoughts = []
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
    }

    /// 点击「自动整理」chip
    private func handleOrganizeChipTap() {
        if orgQueue.isBatchOrganizing {
            // 正在批量整理，banner 已显示进度，不重复触发
            return
        }
        if orgQueue.dailyLimitHit {
            batchOrganizeNotice = "今日整理配额已用尽，剩余条目会在明天自动续做"
            return
        }
        if unprocessedCount == 0 {
            batchOrganizeNotice = "所有想法都已整理过啦"
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
            orgQueue.enqueueBatch(thoughtIds: ids)
            batchOrganizeNotice = "已开始整理 \(ids.count) 条想法"
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
                Text("后台串行整理，受每日配额限制，会占用今日整理配额（可能影响新想法当天的自动整理）；多余条目会在后续打开 App 时自动续做。")
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
                .tint(.holoAI)
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

            // 搜索按钮
            Button {
                // TODO: 聚焦搜索框
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 搜索栏

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索想法或标签...", text: $searchText)
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
                }

                // 自动整理动作 chip（紫色 AI 标识，区别于筛选 chip）
                ThoughtOrganizeActionChip(
                    pendingCount: unprocessedCount,
                    isOrganizing: orgQueue.isBatchOrganizing
                ) {
                    handleOrganizeChipTap()
                }

                // 常用标签
                ForEach(frequentTags) { tag in
                    HoloFilterChip(
                        title: tag.name,
                        iconColor: tag.tagColor,
                        isSelected: selectedTagName == tag.name
                    ) {
                        selectedTagName = tag.name
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
                        content: {
                            ThoughtCardView(thought: thought) {
                                if revealedThoughtId == thought.id {
                                    revealedThoughtId = nil
                                } else {
                                    selectedThoughtId = thought.id
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
            .padding(.bottom, 100) // 底部 Tab 栏高度
        }
        .refreshable {
            await refresh()
        }
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

    /// 归档想法
    private func archiveThought(_ thought: Thought) {
        do {
            try thoughtRepository.archive(thought.id)
            revealedThoughtId = nil
            loadThoughts()
        } catch {
            Logger(subsystem: "com.holo.app", category: "ThoughtListView").error("归档想法失败: \(error.localizedDescription)")
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

            Text("点击右下角 + 记录第一条想法")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }
}

// MARK: - Preview

#Preview {
    ThoughtsView()
}
