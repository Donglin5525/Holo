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

    // MARK: - Properties

    let onBack: () -> Void
    @Binding var showAddThought: Bool
    let thoughtRepository: ThoughtRepository

    /// 筛选状态
    @State private var selectedTagName: String? = nil
    @State private var searchText: String = ""
    @State private var showFilterSheet: Bool = false
    @State private var currentFilters: ThoughtFilters? = nil

    /// 选中的想法（用于跳转详情）
    @State private var selectedThoughtId: UUID? = nil

    /// 所有想法
    @State private var thoughts: [Thought] = []

    /// 所有标签
    @State private var allTags: [ThoughtTag] = []

    /// 右滑展开的卡片 ID
    @State private var revealedThoughtId: UUID? = nil

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
            ThoughtDetailView(
                thoughtId: thoughtId,
                thoughtRepository: thoughtRepository
            )
        }
        .sheet(isPresented: $showFilterSheet) {
            ThoughtFilterSheetView(onApplyFilters: { filters in
                currentFilters = filters
                loadThoughtsWithFilters()
            })
                .presentationDetents([.medium])
        }
        .onAppear {
            loadThoughts()
            loadTags()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thoughtDataDidChange)) { _ in
            loadThoughts()
            loadTags()
        }
    }

    // MARK: - 数据加载

    private func loadThoughts() {
        do {
            thoughts = try thoughtRepository.fetchAll()
            currentFilters = nil
        } catch {
            print("[ThoughtListView] 加载想法失败：\(error)")
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
            print("[ThoughtListView] 加载想法失败：\(error)")
            thoughts = []
        }
    }

    private func loadTags() {
        do {
            allTags = try thoughtRepository.getAllTags()
        } catch {
            print("[ThoughtListView] 加载标签失败：\(error)")
            allTags = []
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
                            ThoughtCardView(thought: thought)
                        },
                        onArchive: {
                            archiveThought(thought)
                        },
                        onDelete: {
                            deleteThought(thought)
                        }
                    )
                    .onTapGesture {
                        if revealedThoughtId == thought.id {
                            revealedThoughtId = nil
                        } else {
                            selectedThoughtId = thought.id
                        }
                    }
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
