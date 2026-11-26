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
    /// 分类明细 push 覆盖层：总览点分类不再切页签，而是推入明细页。
    /// 底层各页签子树全程在场不被销毁，返回时列表位置原样保留（2026-10-16 东林需求）。
    @State private var pushedCategory: Category?
    /// 账户/项目子视图的分类下钻 push（子视图上报请求，本层统一渲染，
    /// 与 pushedCategory 同层保证盖住整个分析页头部）
    @State private var pushedScopeDrillDown: ScopeDrillDownRequest?

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
        ZStack {
            VStack(spacing: 0) {
                // 顶部栏（返回 + 居中日期胶囊，省去多余「统计分析」整行大标题）
                headerView

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

                // Tab 栏 + 0.5pt 暖灰细线
                tabBar
                HoloHairlineDivider()

                // 内容区
                tabContentBody
                    .overlay { if state.isLoading { loadingView } }
            }

            // 分类明细 push 层：必须盖住整个分析页（含自身头部与页签），
            // 只盖内容区会露出底层「‹ 统计分析」返回钮形成双返回，误触即退出整个模块
            // （2026-10-16 走查实锤）。底层子树全程在场不被替换，返回即回原位。
            if let category = pushedCategory {
                CategoryDetailPushPage(state: state, category: category) {
                    state.selectDetailCategory(nil)
                    withAnimation(HoloAnimation.standard) {
                        pushedCategory = nil
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }

            // 账户/项目子视图的分类下钻 push：同层渲染，同一全屏覆盖语义
            if let drill = pushedScopeDrillDown {
                ScopeCategoryDrillDownView(
                    payload: drill.payload,
                    scope: drill.scope,
                    dateRange: { state.currentDateRange }
                ) {
                    withAnimation(HoloAnimation.standard) {
                        pushedScopeDrillDown = nil
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
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
        // 深链带自己的时间范围语义，覆盖层若还开着先收回，避免旧分类筛选横在深链结果上
        withAnimation(HoloAnimation.standard) {
            pushedCategory = nil
            pushedScopeDrillDown = nil
        }
        state.applyDeepLink(link)
        externalDeepLink = nil
    }

    // MARK: - 顶部栏

    private var headerView: some View {
        HStack(spacing: HoloSpacing.sm) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .holoIconSize(.sm, weight: .semibold)
                    .foregroundColor(.holoToolText)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolSurface)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "返回"))

            Spacer(minLength: 4)

            TimeRangeLabel(state: state, isCompactHeader: true) {
                withAnimation(HoloAnimation.standard) {
                    showTimeFilterBlock.toggle()
                }
            }

            Spacer(minLength: 4)

            // 占位保持日期胶囊严格居中
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 4)
        .padding(.bottom, HoloSpacing.xs)
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AnalysisTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 2)
    }

    private func tabButton(_ tab: AnalysisTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(HoloAnimation.standard) {
                selectedTab = tab
            }
        } label: {
            Text(tab.displayName)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color.holoPrimary)
                            .frame(width: 28, height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 内容

    /// 各页签内容。加载态不能走 if/else 分支替换：isLoading 每次刷新（含「看项目全程」
    /// 切范围、记账后数据变更）都会翻真，换分支会把整个页签子树拆掉重建，项目/账户
    /// 子视图的选中态随之丢失、被弹回列表（2026-10-03 模拟器实锤）。
    /// 内容常驻、加载指示做覆盖层，子树身份才稳定。
    @ViewBuilder
    private var tabContentBody: some View {
        switch selectedTab {
        case .overview:
            OverviewTabView(state: state) { category in
                state.selectDetailCategory(category)
                withAnimation(HoloAnimation.standard) {
                    pushedCategory = category
                }
            }
        case .detail:
            DetailTabView(state: state)
        case .category:
            CategoryTabView(state: state)
        case .project:
            ProjectTabView(state: state, onDrillDownCategory: pushScopeDrillDown)
        case .account:
            AccountTabView(state: state, onDrillDownCategory: pushScopeDrillDown)
        }
    }

    private func pushScopeDrillDown(_ request: ScopeDrillDownRequest) {
        withAnimation(HoloAnimation.standard) {
            pushedScopeDrillDown = request
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

// MARK: - 分类明细 push 页

/// 总览「分类排行」点入的分类明细页：返回栏 + 明细内容（趋势图/交易明细）。
/// 内容复用 DetailTabView（isPushed 模式下其自带筛选横幅让位给本页返回栏）。
private struct CategoryDetailPushPage: View {
    @ObservedObject var state: FinanceAnalysisState
    let category: Category
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScopeSubHeaderView(title: category.name, onBack: onBack)

            DetailTabView(state: state, isPushed: true)
        }
        .background(Color.holoToolBackground)
    }
}

// MARK: - Finance Settings View
