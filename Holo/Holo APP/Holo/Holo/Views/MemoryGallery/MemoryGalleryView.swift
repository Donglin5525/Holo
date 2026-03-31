//
//  MemoryGalleryView.swift
//  Holo
//
//  记忆长廊主视图 — 垂直时间线布局
//  三层叙事结构：日摘要 → 高亮 → 里程碑
//

import SwiftUI

/// 记忆长廊主视图
struct MemoryGalleryView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var viewModel = MemoryGalleryViewModel()

    /// 选中的记忆条目（用于跳转详情）
    @State private var selectedMemory: MemoryItem?

    // MARK: - Body

    var body: some View {
        ZStack {
            // 背景色
            Color.holoBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏
                navigationBar

                // 筛选器
                if viewModel.showFilter {
                    filterBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // 主内容
                mainContent
            }
        }
        .swipeBackToDismiss { dismiss() }
        .sheet(item: $selectedMemory) { memory in
            MemoryDetailView(memory: memory)
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
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

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.showFilter.toggle()
                }
            } label: {
                Image(systemName: viewModel.showFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.showFilter ? .holoPrimary : .holoTextSecondary)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoBackground)
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

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.timelineSections.isEmpty {
            // 首次加载骨架屏
            skeletonView
        } else if viewModel.timelineSections.isEmpty {
            // 空状态
            emptyView
        } else {
            // 时间线列表
            timelineList
        }
    }

    // MARK: - Skeleton View

    private var skeletonView: some View {
        ScrollView {
            VStack(spacing: HoloSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    skeletonCard
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline List

    private var timelineList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.timelineSections) { section in
                    timelineSectionView(for: section)
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
            // 日期头
            TimelineDateHeader(section: section)

            // 节点列表（带时间线竖线）
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.nodes) { node in
                    nodeView(for: node)
                        .padding(.leading, 22)
                }
            }
            .padding(.top, 12)
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
    MemoryGalleryView()
}
