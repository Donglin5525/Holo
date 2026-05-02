//
//  FinanceAnalysisView.swift
//  Holo
//
//  财务分析视图
//

import SwiftUI

struct FinanceAnalysisView: View {
    let onBack: () -> Void

    @StateObject private var state = FinanceAnalysisState()
    @State private var selectedTab: AnalysisTab = .overview
    @State private var showCustomDateSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            headerView

            // 时间范围标签（含自定义按钮）
            TimeRangeLabel(state: state) {
                showCustomDateSheet = true
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
                endDate: .constant(state.currentDateRange.end.addingDays(-1))
            ) { start, end in
                state.setCustomDateRange(start: start, end: end)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            state.refresh()
        }
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
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
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
                OverviewTabView(state: state)
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
