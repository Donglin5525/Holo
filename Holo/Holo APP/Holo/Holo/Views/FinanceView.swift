//
//  FinanceView.swift
//  Holo
//
//  记账功能首页 - 包含底部导航栏（账本/统计/固定支出/设置）
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Finance Tab 枚举

/// 财务模块底部 Tab 枚举
/// 顺序：账户 → 账本（默认落地）→ 统计 → 固定支出 → 设置
/// 纯 UI 枚举（未持久化）：rawValue 用英文标识，中文文案走 displayName
enum FinanceTab: String, CaseIterable {
    case accounts
    case ledger
    case analysis
    case spending
    case settings

    /// Tab 显示名（进词表）
    var displayName: String {
        switch self {
        case .accounts: return String(localized: "账户")
        case .ledger: return String(localized: "账本")
        case .analysis: return String(localized: "统计")
        case .spending: return String(localized: "固定支出")
        case .settings: return String(localized: "设置")
        }
    }

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .accounts: return "creditcard.fill"
        case .ledger: return "wallet.pass.fill"
        case .analysis: return "chart.pie.fill"
        case .spending: return "repeat"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - FinanceView

/// 记账功能首页视图（容器）
/// 管理五个子 Tab：账户、账本、统计分析、固定支出、设置
/// 支持从左边缘向右滑动返回首页
struct FinanceView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 当前窗口宽度（v2 断点判断用）
    @Environment(\.holoWindowWidth) private var holoWindowWidth
    /// expanded 宽度（≥1024pt）：内部 Tab 上移顶部，底部导航栏退役
    private var isExpandedWidth: Bool {
        HoloAdaptiveLayout.isExpandedWidth(holoWindowWidth)
    }
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @State private var selectedTab: FinanceTab
    @State private var showAddTransaction: Bool = false
    /// Cmd+F 触发计数：切到账本 Tab 并转发给 FinanceLedgerView 打开搜索
    @State private var searchTrigger: Int = 0
    @State private var deepLinkedTransaction: Transaction?
    @State private var analysisDeepLink: FinanceAnalysisDeepLink?
    @State private var evidenceReviewDeepLink: FinanceEvidenceReviewDeepLink?
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    /// 日历状态提升到此层级，避免切换 Tab 时被销毁
    @StateObject private var calendarState = CalendarState()
    /// 统计状态由模块根视图持有，切换 Tab 或跨模块返回时保留时间范围与下钻现场。
    @StateObject private var analysisState = FinanceAnalysisState()
    @State private var selectedAnalysisTab: AnalysisTab = .overview

    init(
        initialAnalysisDeepLink: FinanceAnalysisDeepLink? = nil,
        initialEvidenceReviewDeepLink: FinanceEvidenceReviewDeepLink? = nil
    ) {
        _selectedTab = State(initialValue: initialAnalysisDeepLink == nil ? .ledger : .analysis)
        _analysisDeepLink = State(initialValue: initialAnalysisDeepLink)
        _evidenceReviewDeepLink = State(initialValue: initialEvidenceReviewDeepLink)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                if let evidenceReviewDeepLink {
                    FinanceEvidenceReviewView(
                        link: evidenceReviewDeepLink,
                        onBack: { close() },
                        onBackToAI: {
                            // ZStack 常驻：navigate 触发 HomeView 切换 activeScreen 到 .ai，
                            // FinanceView 自动隐藏，无需手动 close()。
                            DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
                        },
                        onOpenAnalysis: { link in
                            selectedTab = .analysis
                            analysisDeepLink = link
                            self.evidenceReviewDeepLink = nil
                        }
                    )
                } else {
                    switch selectedTab {
                    case .accounts:
                        AccountListView(onBack: { close() })
                    case .analysis:
                        FinanceAnalysisView(
                            state: analysisState,
                            selectedTab: $selectedAnalysisTab,
                            onBack: { close() },
                            externalDeepLink: $analysisDeepLink
                        )
                    case .ledger:
                        FinanceLedgerView(
                            calendarState: calendarState,
                            onBack: { close() },
                            showAddTransaction: $showAddTransaction,
                            searchTrigger: searchTrigger
                        )
                    case .spending:
                        SpendingProjectsView(onBack: { close() })
                    case .settings:
                        FinanceSettingsView(onBack: { close() })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss(isResidentScreenRoot: true) { close() }
        .task {
            FinanceRepository.shared.setup()
        }
        // Cmd+F：切到账本 Tab（FinanceLedgerView 是 switch 销毁式，须先建活）再转发触发
        .onReceive(HoloShortcutBus.shared.$lastEvent) { event in
            guard event?.action == .searchInCurrentModule else { return }
            selectedTab = .ledger
            searchTrigger += 1
        }
        // v2：expanded 宽度 Tab 上移顶部（胶囊切换条），iPhone/窄屏保持吸底导航栏
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isExpandedWidth, evidenceReviewDeepLink == nil {
                financeTabBarOnly
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isExpandedWidth, evidenceReviewDeepLink == nil {
                financeTopTabBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 「记一笔」只在账本/账户两个页有语义；统计/固定支出/设置页
            // 各有自己的新增入口，且设置页内容会延伸到 FAB 区域造成遮挡。
            if evidenceReviewDeepLink == nil,
               selectedTab == .ledger || selectedTab == .accounts {
                addTransactionFAB
            }
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(editingTransaction: nil) { _ in
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        }
        .sheet(item: $deepLinkedTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        }
        .onAppear {
            handleDeepLink(deepLinkState.pendingTarget)
        }
        .onChange(of: deepLinkState.pendingTarget) { _, target in
            handleDeepLink(target)
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        switch target {
        case .transactionDetail(let transactionId):
            selectedTab = .ledger
            if let transaction = FinanceRepository.shared.findTransaction(by: transactionId) {
                deepLinkedTransaction = transaction
            } else {
                HoloToastCenter.shared.show(String(localized: "该交易已被清除"), type: .info)
            }
            deepLinkState.pendingTarget = nil
        case .financeAnalysis(let link):
            evidenceReviewDeepLink = nil
            selectedTab = .analysis
            analysisDeepLink = link
            deepLinkState.pendingTarget = nil
        case .financeEvidenceReview(let link):
            evidenceReviewDeepLink = link
            deepLinkState.pendingTarget = nil
        default:
            return
        }
    }
    
    // MARK: - 底部 Tab 栏（fixed bottom-0 left-0 w-full，无浮动圆角）

    /// 底部导航栏：吸底全宽，5 个平等 Tab（账户/账本/统计/固定支出/设置）
    /// 骨架层（ContentView）已限宽 720：iPad 上整条栏跟随内容列宽，iPhone 撑满
    private var financeTabBarOnly: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                ForEach(FinanceTab.allCases, id: \.self) { tab in
                    financeTabButton(tab)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, bottomInset)
            .background(
                Color.holoCardBackground
                    .shadow(color: HoloShadow.card, radius: 10, x: 0, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground.ignoresSafeArea(edges: .bottom))
        .zIndex(40)
    }

    /// 悬浮「记一笔」按钮：浮在 Tab 栏上方右下角，任意页面均可触发
    private var addTransactionFAB: some View {
        Button {
            showAddTransaction = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(Color.holoPrimary)
                .clipShape(Circle())
                .shadow(color: Color.holoPrimary.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.trailing, 20)
        // 吸底 Tab 栏在位时抬高避开（88pt）；顶部切换条形态（v2 expanded）贴底即可
        .padding(.bottom, isExpandedWidth ? 24 : 104)
    }

    /// v2 expanded 顶部切换条：胶囊式，替代吸底导航栏
    private var financeTopTabBar: some View {
        HStack(spacing: 8) {
            ForEach(FinanceTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(tab.displayName)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            selectedTab == tab
                                ? Color.holoPrimary.opacity(0.15)
                                : Color.holoCardBackground
                        )
                    )
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    /// 单个 Tab 按钮
    private func financeTabButton(_ tab: FinanceTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)

                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)

                Text(tab.displayName)
                    .font(.holoTinyLabel)
                    .fontWeight(selectedTab == tab ? .bold : .medium)
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 圆角辅助（仅指定部分角）
