//
//  TaskSearchView.swift
//  Holo
//
//  任务搜索全屏视图
//  支持按标题、描述、标签名、清单名搜索任务
//

import SwiftUI

/// 任务搜索全屏视图
struct TaskSearchView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @ObservedObject var repository: TodoRepository

    // MARK: - State

    /// 搜索关键词
    @State private var searchText: String = ""

    /// 搜索结果
    @State private var searchResults: [TodoTask] = []

    /// 是否正在搜索
    @State private var isSearching: Bool = false

    /// 搜索框自动聚焦
    @FocusState private var isSearchFocused: Bool

    /// 最近搜索词（持久化存储，最多 5 条）
    @AppStorage("recentTaskSearchKeywords") private var recentSearchData: String = ""

    /// 当前搜索任务（用于防抖取消）
    @State private var searchTask: Task<Void, Never>?

    /// 选中的任务（用于 sheet 展示）
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection?

    // MARK: - Computed

    /// 解析最近搜索词
    private var recentSearchKeywords: [String] {
        guard !recentSearchData.isEmpty else { return [] }
        return recentSearchData.components(separatedBy: "|||")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            searchBar

            Divider()

            // 内容区域
            ScrollView {
                if searchText.isEmpty {
                    recentSearchSection
                } else if isSearching {
                    searchingIndicator
                } else if searchResults.isEmpty {
                    emptyResultView
                } else {
                    searchResultList
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.holoBackground)
        .swipeBackToDismiss { dismiss() }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, newValue in
            performDebouncedSearch(keyword: newValue)
        }
        .sheet(item: $selectedTask) { selection in
            if let task = searchResults.first(where: { $0.id == selection.id }) {
                TaskDetailView(repository: repository, task: task)
            } else if let task = repository.findTask(by: selection.id) {
                TaskDetailView(repository: repository, task: task)
            } else {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            // 返回按钮
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
            }

            // 搜索输入框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                TextField("搜索任务...", text: $searchText)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .focused($isSearchFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.holoBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
    }

    // MARK: - Recent Search

    private var recentSearchSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if !recentSearchKeywords.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)

                    Spacer()

                    Button {
                        recentSearchData = ""
                    } label: {
                        Text("清除")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ForEach(recentSearchKeywords, id: \.self) { keyword in
                    Button {
                        searchText = keyword
                    } label: {
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "clock")
                                .font(.system(size: 14))
                                .foregroundColor(.holoTextSecondary)

                            Text(keyword)
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.lg)
    }

    // MARK: - Searching Indicator

    private var searchingIndicator: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
                .tint(.holoPrimary)
            Text("搜索中...")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Empty Result

    private var emptyResultView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text("未找到相关任务")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("试试其他关键词")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Search Result List

    private var searchResultList: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("找到 \(searchResults.count) 条结果")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)

            LazyVStack(spacing: HoloSpacing.sm) {
                ForEach(searchResults, id: \.id) { task in
                    TaskCardView(task: task, repository: repository)
                        .onTapGesture {
                            selectedTask = TaskSelection(id: task.id)
                        }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.lg)
        }
    }

    // MARK: - Search Logic

    /// 防抖搜索：延迟 0.3 秒后执行
    private func performDebouncedSearch(keyword: String) {
        searchTask?.cancel()

        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 秒

            guard !Task.isCancelled else { return }

            performSearch(keyword: keyword)
        }
    }

    /// 执行搜索
    private func performSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let results = repository.searchTasks(keyword: trimmed)
        searchResults = results
        isSearching = false

        // 保存到最近搜索
        saveRecentKeyword(trimmed)
    }

    /// 保存最近搜索词（最多 5 条，去重）
    private func saveRecentKeyword(_ keyword: String) {
        var keywords = recentSearchKeywords.filter { $0 != keyword }
        keywords.insert(keyword, at: 0)
        if keywords.count > 5 {
            keywords = Array(keywords.prefix(5))
        }
        recentSearchData = keywords.joined(separator: "|||")
    }
}

// MARK: - Preview

#Preview {
    TaskSearchView(repository: TodoRepository.shared)
}
