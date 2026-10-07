//
//  FinanceAnalysisView.swift
//  Holo
//
//  财务分析视图
//

import Combine
import SwiftUI

struct FinanceAnalysisView: View {
    let onBack: () -> Void
    @Binding var externalDeepLink: FinanceAnalysisDeepLink?

    @ObservedObject var state: FinanceAnalysisState
    @Binding var selectedTab: AnalysisTab
    @State private var showCustomDateSheet: Bool = false
    /// 顶部内联时间筛选条展开态（点胶囊切换，不弹抽屉）
    @State private var showTimeFilterBlock: Bool = false

    init(
        state: FinanceAnalysisState,
        selectedTab: Binding<AnalysisTab>,
        onBack: @escaping () -> Void,
        externalDeepLink: Binding<FinanceAnalysisDeepLink?> = .constant(nil)
    ) {
        self.state = state
        self._selectedTab = selectedTab
        self.onBack = onBack
        self._externalDeepLink = externalDeepLink
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            headerView

            // 时间范围标签（点击内联展开筛选条，不弹抽屉）
            TimeRangeLabel(state: state) {
                withAnimation(HoloAnimation.standard) {
                    showTimeFilterBlock.toggle()
                }
            }

            // 内联时间筛选条：点档位立即生效并收起，数据区全程可见
            if showTimeFilterBlock {
                TimeFilterBlock(state: state) {
                    withAnimation(HoloAnimation.standard) {
                        showTimeFilterBlock = false
                    }
                } onCustomTap: {
                    withAnimation(HoloAnimation.standard) {
                        showTimeFilterBlock = false
                    }
                    showCustomDateSheet = true
                }
            }

            // Tab 栏
            tabBar

            // 内容区
            tabContent
        }
        .background(Color.holoToolBackground)
        .sheet(isPresented: $showCustomDateSheet) {
            CustomDateSheet(
                startDate: .constant(state.currentDateRange.start),
                endDate: .constant(state.currentDateRange.end.addingDays(-1)),
                onConfirm: { start, end in
                    state.setCustomDateRange(start: start, end: end)
                }
            )
        }
        // 节流合并：同步/导入风暴时 financeDataDidChange 连发，每条都全量重算图表会打爆主线程；
        // 首发立即刷（保持「记一笔立刻可见」），风暴窗口内只保留最新一条，终态与逐条刷新一致（体检 R0-11）
        .onReceive(
            NotificationCenter.default
                .publisher(for: .financeDataDidChange)
                .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            state.refresh()
        }
        .onAppear {
            // 记账发生在账本页时本视图不在层级里，通知收不到；
            // 每次出现都主动对齐一次，保证「记一笔 → 切到统计」看到的是新数据。
            state.refresh()
            applyExternalDeepLinkIfNeeded()
        }
        .onChange(of: externalDeepLink) { _, _ in
            applyExternalDeepLinkIfNeeded()
        }
    }

    private func applyExternalDeepLinkIfNeeded() {
        guard let link = externalDeepLink else { return }
        state.applyDeepLink(link)
        externalDeepLink = nil
    }

    // MARK: - 顶部栏

    private var headerView: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .frame(width: 36, height: 36)
                    .background(Color.holoToolSurface)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }

            Spacer()

            Text("统计分析")
                .holoText(.pageTitle)
                .foregroundColor(.holoToolText)

            Spacer()

            // 占位保持对称
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, 0)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AnalysisTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
    }

    private func tabButton(_ tab: AnalysisTab) -> some View {
        Button {
            withAnimation(HoloAnimation.standard) {
                selectedTab = tab
            }
        } label: {
            Text(tab.displayName)
                .holoText(.supporting)
                .fontWeight(selectedTab == tab ? .semibold : .medium)
                .foregroundColor(selectedTab == tab ? .holoPrimary : .holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.xs)
                .background(
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                            .frame(height: 2)
                    }
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 内容

    /// 加载态不能走 if/else 分支替换：isLoading 每次刷新（含「看项目全程」切范围、
    /// 记账后数据变更）都会翻真，换分支会把整个页签子树拆掉重建，项目/账户
    /// 子视图的选中态随之丢失、被弹回列表（2026-10-03 模拟器实锤）。
    /// 内容常驻、加载指示做覆盖层，子树身份才稳定。
    private var tabContent: some View {
        tabContentBody
            .overlay { if state.isLoading { loadingView } }
    }

    @ViewBuilder
    private var tabContentBody: some View {
        switch selectedTab {
        case .overview:
            OverviewTabView(state: state) { category in
                state.selectDetailCategory(category)
                withAnimation(HoloAnimation.standard) {
                    selectedTab = .detail
                }
            }
        case .detail:
            DetailTabView(state: state)
        case .category:
            CategoryTabView(state: state)
        case .project:
            ProjectTabView(state: state)
        case .account:
            AccountTabView(state: state)
        }
    }

    // MARK: - 加载状态

    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .holoPrimary))

            Text("加载中...")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Finance Settings View
