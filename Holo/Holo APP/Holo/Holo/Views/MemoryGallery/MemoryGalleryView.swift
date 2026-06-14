//
//  MemoryGalleryView.swift
//  Holo
//
//  记忆长廊主视图 — 洞察 / 明细结构
//  洞察（热力图 + AI 回放 + 里程碑高光）/ 明细（完整时间线）
//

import SwiftUI

/// 记忆长廊主视图
struct MemoryGalleryView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var viewModel = MemoryGalleryViewModel()
    @State private var selectedTab: MemoryGalleryTab = .insight

    /// 跳转记账回调
    let onNavigateToFinance: (() -> Void)?

    /// 跳转 AI 对话回调（携带预填文本）
    let onNavigateToChat: ((String) -> Void)?

    /// 选中的记忆条目（用于跳转详情）
    @State private var selectedMemory: MemoryItem?

    #if DEBUG
    /// 是否显示 AI 设置页
    @State private var showAISettings = false
    #endif

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
        #if DEBUG
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
            }
        }
        #endif
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
        case .insight:
            insightTab
        case .detail:
            detailTab
        }
    }

    // MARK: - 洞察 Tab

    @ViewBuilder
    private var insightTab: some View {
        if viewModel.isLoading && viewModel.timelineSections.isEmpty {
            skeletonView
        } else if let errorMessage = viewModel.errorMessage {
            errorView(message: errorMessage)
        } else if viewModel.timelineSections.isEmpty && viewModel.errorMessage == nil {
            emptyView
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    // Daily Sense 状态卡片
                    if InsightFeatureFlags.dailySenseEnabled,
                       let snapshot = viewModel.dailySenseSnapshot,
                       !snapshot.signals.isEmpty {
                        DailySenseStatusCard(snapshot: snapshot)
                    }

                    // Agent 深度分析结果卡片（Phase 6.3，agentMemoryGalleryEnabled 灰度）
                    if let agentResult = viewModel.agentRenderedResult {
                        HoloAgentResultCard(result: agentResult)
                    }

                    MemoryInsightHeroCard(
                        state: viewModel.insightGenerationState,
                        selectedPeriod: viewModel.selectedInsightPeriod,
                        insight: viewModel.currentInsight,
                        weeklyIsFallback: viewModel.weeklyIsFallback,
                        monthlyIsFallback: viewModel.monthlyIsFallback,
                        customStartDate: $viewModel.customInsightStartDate,
                        customEndDate: $viewModel.customInsightEndDate,
                        fallbackTitle: viewModel.fallbackReplayTitle,
                        fallbackSummary: viewModel.fallbackReplaySummary,
                        onPeriodChange: { period in
                            Task { await viewModel.switchInsightPeriod(to: period) }
                        },
                        onCustomRangeChange: { start, end in
                            Task { await viewModel.updateCustomInsightRange(start: start, end: end) }
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
                            #if DEBUG
                            showAISettings = true
                            #endif
                        }
                    )

                    featuredStoriesSection
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.md)
            }
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

            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text(dateStr)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 0)

                Text("当天轨迹")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            if let section = viewModel.timelineSections.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: date)
            }) {
                let summary = section.nodes.compactMap { node -> DailySummaryData? in
                    if case .summary(let data) = node.data { return data }
                    return nil
                }.first

                if let summary = summary {
                    selectedDateStats(summary)
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

    @ViewBuilder
    private func selectedDateStats(_ summary: DailySummaryData) -> some View {
        let stats = selectedDateStatItems(summary)

        if stats.isEmpty {
            Text("当天暂无记录")
                .font(.holoCaption)
                .foregroundColor(.holoTextPlaceholder)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: HoloSpacing.sm)], spacing: HoloSpacing.sm) {
                ForEach(stats) { stat in
                    previewStat(stat)
                }
            }
        }
    }

    private func previewStat(_ stat: MemoryPreviewStatItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: stat.icon)
                .font(.system(size: 12))
                .foregroundColor(stat.color)

            Text(stat.value)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(stat.label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
        .padding(HoloSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stat.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    private func selectedDateStatItems(_ summary: DailySummaryData) -> [MemoryPreviewStatItem] {
        var stats: [MemoryPreviewStatItem] = []

        if let expense = summary.totalExpense {
            stats.append(MemoryPreviewStatItem(
                icon: "yensign.circle",
                value: formatExpense(expense),
                label: "支出",
                color: .holoPrimary
            ))
        }

        if summary.habitsTotal > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "figure.run",
                value: "\(summary.habitsCompleted)/\(summary.habitsTotal)",
                label: "习惯",
                color: .holoSuccess
            ))
        }

        if summary.tasksCompleted > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "checkmark.circle",
                value: "\(summary.tasksCompleted)",
                label: "任务",
                color: .holoPrimary
            ))
        }

        if summary.thoughtCount > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "bubble.left",
                value: "\(summary.thoughtCount)",
                label: "观点",
                color: .holoPurple
            ))
        }

        return stats
    }

    @ViewBuilder
    private var featuredStoriesSection: some View {
        let stories = featuredNarrativeNodes

        if !stories.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                sectionHeading(title: "里程碑与高光", icon: "flag.fill")

                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    ForEach(stories) { item in
                        featuredStoryRow(item)
                    }
                }
            }
        }
    }

    private var featuredNarrativeNodes: [FeaturedMemoryNode] {
        var stories: [FeaturedMemoryNode] = []
        let range = viewModel.selectedInsightDateRange

        for section in viewModel.timelineSections {
            guard section.date >= range.start && section.date <= range.end else {
                continue
            }

            for node in section.nodes where node.type == .milestone || node.type == .highlight {
                stories.append(FeaturedMemoryNode(section: section, node: node))
            }
        }

        return Array(stories.prefix(2))
    }

    private func sectionHeading(title: String, icon: String) -> some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoPrimary)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featuredStoryRow(_ item: FeaturedMemoryNode) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Text(item.section.formattedDate)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Text(item.section.displayLabel)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.xs)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }

            switch item.node.data {
            case .milestone(let milestoneData):
                MilestoneNode(data: milestoneData)
            case .highlight(let highlightData):
                HighlightNode(data: highlightData)
            case .summary:
                EmptyView()
            }
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
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    MemoryHeatmapView(
                        data: viewModel.heatmapData,
                        selectedDate: viewModel.selectedHeatmapDate
                    ) { date in
                        viewModel.selectedHeatmapDate = date
                        Task { await viewModel.ensureWeekLoaded(date) }
                    }

                    if let selectedDate = viewModel.selectedHeatmapDate {
                        selectedDatePreview(date: selectedDate)
                    }

                    if viewModel.showFilter {
                        filterBar
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    timelineList
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.md)
            }
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

// MARK: - Supporting Models

private struct MemoryPreviewStatItem: Identifiable {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var id: String { label }
}

private struct FeaturedMemoryNode: Identifiable {
    let section: TimelineSection
    let node: MemoryTimelineNode

    var id: UUID { node.id }
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
