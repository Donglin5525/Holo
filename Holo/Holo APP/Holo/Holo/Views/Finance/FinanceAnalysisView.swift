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
    /// 顶部筛选面板展开态（时间/账户/项目互斥：同一时刻至多展开一个）
    @State private var activeFilterPanel: AnalysisFilterPanel = .none

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
                    activeFilterPanel = activeFilterPanel == .time ? .none : .time
                }
            }

            // 维度筛选胶囊行（账户/项目），三个页签数据全部随维度联动
            ScopeFilterBar(state: state, activePanel: $activeFilterPanel)

            // 内联时间筛选条：点档位立即生效并收起，数据区全程可见
            if activeFilterPanel == .time {
                TimeFilterBlock(state: state) {
                    withAnimation(HoloAnimation.standard) {
                        activeFilterPanel = .none
                    }
                } onCustomTap: {
                    withAnimation(HoloAnimation.standard) {
                        activeFilterPanel = .none
                    }
                    showCustomDateSheet = true
                }
            }

            // 账户选择面板：点选即生效并收起
            if activeFilterPanel == .account {
                AccountScopePanel(state: state) {
                    withAnimation(HoloAnimation.standard) {
                        activeFilterPanel = .none
                    }
                }
            }

            // 项目选择面板：点选即生效并收起
            if activeFilterPanel == .project {
                ProjectScopePanel(state: state) {
                    withAnimation(HoloAnimation.standard) {
                        activeFilterPanel = .none
                    }
                }
            }

            // Tab 栏
            tabBar

            // 内容区
            tabContent
        }
        .background(Color.holoBackground)
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
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.holoCardBackground)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }

            Spacer()

            Text("统计分析")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

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
                .font(.holoCaption)
                .fontWeight(selectedTab == tab ? .semibold : .medium)
                .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
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

    @ViewBuilder
    private var tabContent: some View {
        if state.isLoading {
            loadingView
        } else {
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
            }
        }
    }

    // MARK: - 加载状态

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
}

// MARK: - Finance Settings View
