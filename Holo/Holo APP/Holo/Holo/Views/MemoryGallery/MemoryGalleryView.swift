//
//  MemoryGalleryView.swift
//  Holo
//
//  记忆长廊主视图 — 三 Tab 结构
//  回放（HeroCard + 展柜 + 封面流）/ 地图（统计 + 热力图）/ 明细（时间线）
//

import SwiftUI

/// 记忆长廊主视图
struct MemoryGalleryView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var viewModel = MemoryGalleryViewModel()
    @State private var selectedTab: MemoryGalleryTab = .replay

    /// 跳转记账回调
    let onNavigateToFinance: (() -> Void)?

    /// 跳转 AI 对话回调（携带预填文本）
    let onNavigateToChat: ((String) -> Void)?

    /// 选中的记忆条目（用于跳转详情）
    @State private var selectedMemory: MemoryItem?

    /// 是否显示 AI 设置页
    @State private var showAISettings = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            navigationBar

            // Tab 切换器
            MemorySegmentedTabs(selectedTab: $selectedTab)
                .padding(.vertical, HoloSpacing.sm)

            // 主内容区
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoBackground.ignoresSafeArea())
        .swipeBackToDismiss { dismiss() }
        .sheet(item: $selectedMemory) { memory in
            MemoryDetailView(memory: memory)
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
            }
        }
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            Spacer()

            Text("记忆长廊")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 明细 Tab 显示筛选按钮
            if selectedTab == .detail {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.showFilter.toggle()
                    }
                } label: {
                    Image(systemName: viewModel.showFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20))
                        .foregroundColor(viewModel.showFilter ? .holoPrimary : .holoTextSecondary)
                }
            } else {
                // 占位保持标题居中
                Color.clear
                    .frame(width: 20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoBackground)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .replay:
            replayTab
        case .map:
            mapTab
        case .detail:
            detailTab
        }
    }

    // MARK: - 回放 Tab

    @ViewBuilder
    private var replayTab: some View {
        if viewModel.isLoading && viewModel.timelineSections.isEmpty {
            skeletonView
        } else if viewModel.timelineSections.isEmpty && viewModel.errorMessage == nil {
            emptyView
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    // AI 洞察 Hero 卡片
                    MemoryInsightHeroCard(
                        state: viewModel.insightGenerationState,
                        selectedPeriod: viewModel.selectedInsightPeriod,
                        insight: viewModel.currentInsight,
                        weeklyIsFallback: viewModel.weeklyIsFallback,
                        monthlyIsFallback: viewModel.monthlyIsFallback,
                        fallbackTitle: viewModel.fallbackReplayTitle,
                        fallbackSummary: viewModel.fallbackReplaySummary,
                        onPeriodChange: { period in
                            Task { await viewModel.switchInsightPeriod(to: period) }
                        },
                        onGenerate: {
                            Task { await viewModel.generateCurrentInsight() }
                        },
                        onRefresh: {
                            Task { await viewModel.refreshInsight(force: true) }
                        },
                        onContinueInChat: {
                            if let prompt = viewModel.buildContinueInChatPrompt() {
                                onNavigateToChat?(prompt)
                            }
                        },
                        onGoToAISettings: {
                            showAISettings = true
                        }
                    )

                    // 今日展柜
                    TodayMemoryCabinetCard(
                        summary: viewModel.todaySummary
                    )

                    // 最近日子封面流
                    RecentDayCoverView(
                        sections: Array(viewModel.timelineSections.prefix(7))
                    )
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.md)
            }
        }
    }

    // MARK: - 地图 Tab

    private var mapTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                // 统计概览
                MemoryStatsSummaryView(
                    memoryCount: viewModel.totalMemoryCount,
                    recordedDays: viewModel.totalRecordedDays,
                    insightCount: viewModel.totalInsights
                )

                // 热力图
                MemoryHeatmapView(
                    data: viewModel.heatmapData,
                    selectedDate: viewModel.selectedHeatmapDate
                ) { date in
                    viewModel.selectedHeatmapDate = date
                }

                // 选中日期预览
                if let selectedDate = viewModel.selectedHeatmapDate {
                    selectedDatePreview(date: selectedDate)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    /// 选中日期预览卡片
    private func selectedDatePreview(date: Date) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            let formatter = DateFormatter()
            let dateStr: String = {
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 EEEE"
                return formatter.string(from: date)
            }()

            Text(dateStr)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            if let section = viewModel.timelineSections.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: date)
            }) {
                let summary = section.nodes.compactMap { node -> DailySummaryData? in
                    if case .summary(let data) = node.data { return data }
                    return nil
                }.first

                if let summary = summary {
                    HStack(spacing: HoloSpacing.md) {
                        if let expense = summary.totalExpense {
                            previewStat(
                                icon: "yensign.circle",
                                value: formatExpense(expense),
                                color: .holoPrimary
                            )
                        }
                        if summary.habitsTotal > 0 {
                            previewStat(
                                icon: "figure.run",
                                value: "\(summary.habitsCompleted)/\(summary.habitsTotal)",
                                color: .holoSuccess
                            )
                        }
                        if summary.tasksCompleted > 0 {
                            previewStat(
                                icon: "checkmark.circle",
                                value: "\(summary.tasksCompleted) 任务",
                                color: .holoInfo
                            )
                        }
                        if summary.thoughtCount > 0 {
                            previewStat(
                                icon: "bubble.left",
                                value: "\(summary.thoughtCount) 观点",
                                color: .holoInfo
                            )
                        }
                    }
                } else {
                    Text("当天暂无记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                }
            } else {
                Text("当天暂无记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    private func previewStat(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(value)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - 明细 Tab

    @ViewBuilder
    private var detailTab: some View {
        if let errorMessage = viewModel.errorMessage {
            errorView(message: errorMessage)
        } else if viewModel.isLoading && viewModel.timelineSections.isEmpty {
            skeletonView
        } else if viewModel.timelineSections.isEmpty {
            emptyView
        } else {
            // 筛选器
            if viewModel.showFilter {
                filterBar
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 时间线列表
            timelineList
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                ForEach(MemoryModuleFilter.allCases) { filter in
                    FilterChip(
                        title: filter.displayName,
                        isSelected: viewModel.moduleFilter == filter
                    ) {
                        Task {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.moduleFilter = filter
                            }
                            await viewModel.setModuleFilter(filter)
                        }
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoCardBackground)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 36))
                .foregroundColor(.holoTextPlaceholder)

            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("重试")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.xl)
                    .padding(.vertical, HoloSpacing.sm)
                    .overlay(
                        Capsule().stroke(Color.holoPrimary, lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Skeleton View

    private var skeletonView: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    skeletonCard
                        .shimmer()
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.lg)
        }
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.holoBorder)
                    .frame(width: 12, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.holoBorder)
                    .frame(width: 100, height: 14)
            }

            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 80, height: 20)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 60, height: 20)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 40, height: 20)
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: HoloSpacing.lg) {
            VStack(spacing: 0) {
                Circle()
                    .strokeBorder(Color.holoTextPlaceholder, style: StrokeStyle(lineWidth: 2, dash: [4]))
                    .frame(width: 40, height: 40)

                Rectangle()
                    .fill(Color.holoTextPlaceholder.opacity(0.3))
                    .frame(width: 2, height: 60)
                    .padding(.top, -2)
            }

            VStack(spacing: HoloSpacing.xs) {
                Text("暂无记录")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("记录你的第一笔，开启记忆长廊")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            if onNavigateToFinance != nil {
                Button {
                    onNavigateToFinance?()
                } label: {
                    Text("去记账")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .padding(.horizontal, HoloSpacing.xl)
                        .padding(.vertical, HoloSpacing.md)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }
                .padding(.top, HoloSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline List

    private var timelineList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.timelineSections) { section in
                    timelineSectionView(for: section)
                        .id(section.id)
                        .transition(.opacity)
                }

                if viewModel.hasMoreData {
                    loadMoreIndicator
                } else {
                    Text("已加载全部")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.lg)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    // MARK: - Timeline Section

    @ViewBuilder
    private func timelineSectionView(for section: TimelineSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineDateHeader(section: section)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.holoBorder)
                    .frame(width: 2)
                    .padding(.leading, 5)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.nodes) { node in
                        nodeView(for: node)
                            .padding(.leading, 22)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Node View

    @ViewBuilder
    private func nodeView(for node: MemoryTimelineNode) -> some View {
        switch node.data {
        case .summary(let summaryData):
            DailySummaryNode(
                data: summaryData,
                moduleFilter: viewModel.moduleFilter
            )

        case .highlight(let highlightData):
            HighlightNode(data: highlightData)
                .padding(.leading, 8)

        case .milestone(let milestoneData):
            MilestoneNode(data: milestoneData)
        }
    }

    // MARK: - Load More

    private var loadMoreIndicator: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMore {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
                    .padding(.vertical, HoloSpacing.md)
            }
            Spacer()
        }
        .onAppear {
            Task {
                await viewModel.loadMore()
            }
        }
    }

    // MARK: - Formatter

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.xs)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.holoPrimary : Color.holoGlassBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.holoBorder, lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    MemoryGalleryView(onNavigateToFinance: nil, onNavigateToChat: nil)
}
