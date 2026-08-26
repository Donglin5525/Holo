//
//  ChatReportTabView.swift
//  Holo
//
//  Holo AI 页「报告」Tab：搜索栏 + 报告档案（按月分组）/ 空态橱窗。
//  发起不在本 Tab——报告只读，发起统一回对话页（预填话术、用户自己确认发送）。
//  Tab 切换由 ChatView 的 ZStack 常驻模式承载（本视图只在首次切到时构建）。
//

import SwiftUI

struct ChatReportTabView: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    @ObservedObject var viewModel: ChatReportTabViewModel
    /// 档案行点击：按类型分流（深度分析 → 全屏报告详情；周期回放 → 全屏阅读版）。
    var onOpenEntry: (ReportArchiveDTO) -> Void
    /// 空态橱窗 CTA：切回对话 Tab 并预填发起话术（不自动发送，确认权在用户）。
    var onLaunchInChat: () -> Void

    @State private var showFavorites = false

    private var isSearchMode: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

            if !isSearchMode && !viewModel.availableScenarioFilters.isEmpty {
                scenarioFilterRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if isSearchMode {
                searchResultList
            } else if shouldShowEmptyState {
                ReportEmptyStateView {
                    onLaunchInChat()
                }
            } else {
                archiveList
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .fullScreenCover(isPresented: $showFavorites) {
            ReportFavoritesView(
                chatViewModel: viewModel.boundChatViewModel,
                onFavoritesChanged: {
                    Task { await viewModel.refreshFavoritesCount() }
                }
            )
            .holoContentColumn()
        }
        .confirmationDialog(
            "删除这份报告？",
            isPresented: Binding(
                get: { viewModel.pendingDeleteEntry != nil },
                set: { if !$0 { viewModel.pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除报告与对应对话", role: .destructive) {
                if let entry = viewModel.pendingDeleteEntry {
                    viewModel.deleteReport(entry)
                }
                viewModel.pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                viewModel.pendingDeleteEntry = nil
            }
        } message: {
            if let entry = viewModel.pendingDeleteEntry {
                Text("「\(entry.scopeLabel ?? "报告")」及聊天里的提问和回答都会删除，此操作不可撤销。")
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索提问、结论或正文", text: $viewModel.searchText)
                .font(.system(size: 13.5))
                .foregroundColor(.holoTextPrimary)
                .autocorrectionDisabled()
                .accessibilityLabel("搜索报告")

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.holoCardBackground, in: Capsule())
        .overlay(
            Capsule().stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
        )
    }

    // MARK: - 场景筛选

    /// 按场景筛档案：全部 + 档案中实际存在的场景（动态出链，不摆空选项）
    private var scenarioFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "全部", tag: nil)
                ForEach(viewModel.availableScenarioFilters, id: \.rawValue) { tag in
                    filterChip(label: tag.label, tag: tag)
                }
            }
        }
    }

    private func filterChip(label: String, tag: ReportScenarioTag?) -> some View {
        let isSelected = viewModel.selectedScenarioFilter == tag
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectedScenarioFilter = tag
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? Color.holoPrimary : .holoTextSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.holoPrimary.opacity(0.12) : Color.holoCardBackground,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.holoPrimary.opacity(0.35) : Color.holoDivider.opacity(0.5),
                        lineWidth: 0.8
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 列表

    /// 空态判定：首屏加载完成 + 无已完成报告 + 无生成中任务 + 不在搜索态。
    private var shouldShowEmptyState: Bool {
        viewModel.hasLoadedOnce
            && viewModel.entries.isEmpty
            && viewModel.inProgressAnalysis == nil
    }

    private var archiveList: some View {
        List {
            // 收藏入口：有收藏才出现（无收藏不摆空入口，保持档案干净）
            if viewModel.favoritesCount > 0 {
                Button {
                    showFavorites = true
                } label: {
                    favoritesEntryRow
                }
                .reportRowChrome()
            }

            if let inProgress = viewModel.inProgressAnalysis {
                ReportInProgressCard(message: inProgress)
                    .reportRowChrome()
            }

            if viewModel.isLoading && viewModel.entries.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView("正在翻档案…")
                        .font(.system(size: 12))
                    Spacer()
                }
                .reportRowChrome()
            } else if viewModel.selectedScenarioFilter != nil && viewModel.displayEntries.isEmpty {
                VStack(spacing: 7) {
                    Text("这个场景还没有报告")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                    Text("回到「全部」看看，或去对话里发起一次")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .reportRowChrome()
            } else {
                // 按月分组：档案有「越攒越厚」的时间节奏
                ForEach(viewModel.groupedEntries, id: \.monthLabel) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            archiveRow(entry)
                        }
                    } header: {
                        monthHeader(group.monthLabel)
                    }
                }

                if !viewModel.reachedEnd {
                    // 触底哨兵：出现即加载下一页
                    Color.clear
                        .frame(height: 1)
                        .reportRowChrome()
                        .onAppear {
                            Task { await viewModel.loadNextPage() }
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.reload()
        }
    }

    /// 月份分组头：月份词 + 分隔细线（List Section header 形态）。
    private func monthHeader(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.holoTextSecondary)
            Rectangle()
                .fill(Color.holoDivider.opacity(0.6))
                .frame(height: 0.7)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .alignmentGuide(.listRowSeparatorLeading) { _ in -16 }
        .accessibilityAddTraits(.isHeader)
    }

    /// 收藏入口条：星形图标 + 说明 + 数量。视觉上比报告卡轻一档，不抢档案主体。
    /// 配色走双模式（holoCardBackground / holoStarTint），深色模式下不发灰。
    private var favoritesEntryRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.holoStarTint)
                .frame(width: 30, height: 30)
                .background(Color.holoStarTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1.5) {
                Text("我的收藏")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                Text("值得反复看的好报告都在这")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: 8)

            Text("\(viewModel.favoritesCount)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color.holoStarTint)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .stroke(Color.holoStarTint.opacity(0.32), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private var searchResultList: some View {
        List {
            if viewModel.isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 24)
                    .reportRowChrome()
            } else if viewModel.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                    Text("没有匹配「\(viewModel.searchText)」的报告")
                        .font(.system(size: 12.5))
                        .foregroundColor(.holoTextSecondary)
                    Text("试试换个关键词：提问里的词、结论里的词都能搜到")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .reportRowChrome()
            } else {
                Text("找到 \(viewModel.searchResults.count) 份报告")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reportRowChrome()

                ForEach(viewModel.searchResults) { entry in
                    archiveRow(entry)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func archiveRow(_ entry: ReportArchiveDTO) -> some View {
        ReportArchiveCard(entry: entry) {
            onOpenEntry(entry)
        }
        .reportRowChrome()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                viewModel.toggleFavorite(entry)
                // 反馈=星标亮起 + 轻触觉。不弹全局 toast：toast 浮层窗口有吞触摸的
                // 前科（开发守则「纪念日卡死事故」），写操作成功反馈一律不用它。
                if !entry.isFavorited {
                    HapticManager.success()
                }
            } label: {
                Label(
                    entry.isFavorited ? "取消收藏" : "收藏",
                    systemImage: entry.isFavorited ? "star.slash" : "star.fill"
                )
            }
            .tint(Color.holoPrimary)

            Button(role: .destructive) {
                viewModel.pendingDeleteEntry = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                viewModel.toggleFavorite(entry)
            } label: {
                Label(
                    entry.isFavorited ? "取消收藏" : "收藏",
                    systemImage: entry.isFavorited ? "star.slash" : "star.fill"
                )
            }
            Button(role: .destructive) {
                viewModel.pendingDeleteEntry = entry
            } label: {
                Label("删除报告", systemImage: "trash")
            }
        }
    }
}

/// List 行的统一外观：透明背景、无系统分隔线、卡片间距由上下 inset 提供
/// （6+6=12，与迁移前 LazyVStack spacing 一致）。
private extension View {
    func reportRowChrome() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
