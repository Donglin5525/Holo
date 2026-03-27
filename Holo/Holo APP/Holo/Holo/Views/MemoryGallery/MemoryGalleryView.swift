//
//  MemoryGalleryView.swift
//  Holo
//
//  记忆长廊主视图
//  以瀑布流形式展示用户在所有模块中的历史记录
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

    // MARK: - Subviews

    /// 顶部导航栏
    private var navigationBar: some View {
        HStack {
            // 返回按钮
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
            }

            Spacer()

            // 标题
            Text("记忆长廊")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 筛选按钮
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

    /// 筛选栏
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

    /// 主内容区域
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.sections.isEmpty {
            // 首次加载中
            loadingView
        } else if viewModel.sections.isEmpty {
            // 空状态
            emptyView
        } else {
            // 瀑布流列表
            memoryList
        }
    }

    /// 加载中视图
    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))
            Text("加载中...")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空状态视图
    private var emptyView: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.holoTextPlaceholder)

            VStack(spacing: HoloSpacing.xs) {
                Text("暂无记录")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("开始记录你的生活轨迹吧")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 记忆列表
    private var memoryList: some View {
        ScrollView {
            LazyVStack(spacing: HoloSpacing.lg) {
                ForEach(viewModel.sections) { section in
                    sectionView(for: section)
                }

                // 加载更多指示器
                if viewModel.hasMoreData {
                    loadMoreIndicator
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    /// 加载更多指示器
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

    /// 分组视图
    @ViewBuilder
    private func sectionView(for section: MemoryItemSection) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 日期标题
            Text(section.displayTitle)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .padding(.leading, HoloSpacing.xs)

            // 瀑布流网格
            waterfallGrid(for: section.items)
        }
    }

    /// 瀑布流网格布局
    @ViewBuilder
    private func waterfallGrid(for items: [MemoryItem]) -> some View {
        // 使用两列布局
        let columns = 2
        let chunkedItems = items.chunked(into: columns)

        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            ForEach(0..<columns, id: \.self) { columnIndex in
                LazyVStack(spacing: HoloSpacing.sm) {
                    ForEach(chunkedItems[columnIndex] ?? []) { item in
                        MemoryCardView(memory: item)
                            .onTapGesture {
                                selectedMemory = item
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Filter Chip

/// 筛选标签
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

// MARK: - Array Extension

private extension Array {
    /// 将数组分割成指定数量的子数组（用于瀑布流布局）
    func chunked(into columns: Int) -> [[Element]] {
        // 创建空结果数组
        var result: [[Element]] = []
        for _ in 0..<columns {
            result.append([])
        }

        // 分配元素到各列
        for (index, element) in enumerated() {
            let columnIndex = index % columns
            result[columnIndex].append(element)
        }

        return result
    }
}

// MARK: - Preview

#Preview {
    MemoryGalleryView()
}
