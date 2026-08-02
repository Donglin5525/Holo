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
enum FinanceTab: String, CaseIterable {
    case accounts = "账户"
    case ledger = "账本"
    case analysis = "统计"
    case spending = "固定支出"
    case settings = "设置"

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
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @State private var selectedTab: FinanceTab
    @State private var showAddTransaction: Bool = false
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
                            showAddTransaction: $showAddTransaction
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if evidenceReviewDeepLink == nil {
                financeTabBarOnly
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if evidenceReviewDeepLink == nil {
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
            deepLinkedTransaction = FinanceRepository.shared.findTransaction(by: transactionId)
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
        .padding(.bottom, 104) // 抬高到 88pt Tab 栏之上
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

                Text(tab.rawValue)
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
