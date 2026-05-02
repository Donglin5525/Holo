//
//  FinanceView.swift
//  Holo
//
//  记账功能首页 - 包含底部导航栏（统计/账本/设置）
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
enum FinanceTab: String, CaseIterable {
    case analysis = "统计"
    case ledger = "账本"
    case settings = "设置"
    
    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .analysis: return "chart.pie.fill"
        case .ledger: return "wallet.pass.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - FinanceView

/// 记账功能首页视图（容器）
/// 管理三个子 Tab：统计分析、账本列表、设置
/// 支持从左边缘向右滑动返回首页
struct FinanceView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: FinanceTab = .ledger
    @State private var showAddTransaction: Bool = false

    /// 日历状态提升到此层级，避免切换 Tab 时被销毁
    @StateObject private var calendarState = CalendarState()

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .analysis:
                    FinanceAnalysisView(onBack: { dismiss() })
                case .ledger:
                    FinanceLedgerView(
                        calendarState: calendarState,
                        onBack: { dismiss() },
                        showAddTransaction: $showAddTransaction
                    )
                case .settings:
                    FinanceSettingsView(onBack: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss { dismiss() }
        .task {
            FinanceRepository.shared.setup()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            financeTabBarOnly
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(editingTransaction: nil) {
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
        }
    }
    
    // MARK: - 底部 Tab 栏（fixed bottom-0 left-0 w-full，无浮动圆角）
    
    /// 底部导航栏：吸底全宽，中间为「账本」与「+」合一
    private var financeTabBarOnly: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                financeTabButton(.analysis)
                // 中间：在记账页展示 +，在统计/设置页展示账本
                financeCenterTabButton
                financeTabButton(.settings)
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
    
    /// 中间 Tab：在账本页显示 +（记一笔），在统计/设置页显示账本（切回账本）
    private var financeCenterTabButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedTab == .ledger {
                    showAddTransaction = true
                } else {
                    selectedTab = .ledger
                }
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == .ledger ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)
                
                Group {
                    if selectedTab == .ledger {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.holoPrimary)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: FinanceTab.ledger.icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                
                Text(selectedTab == .ledger ? "记一笔" : "账本")
                    .font(.holoTinyLabel)
                    .fontWeight(selectedTab == .ledger ? .bold : .medium)
                    .foregroundColor(selectedTab == .ledger ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 单个 Tab 按钮（统计 / 设置）
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

