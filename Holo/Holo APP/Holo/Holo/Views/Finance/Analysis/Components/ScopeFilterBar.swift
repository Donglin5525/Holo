//
//  ScopeFilterBar.swift
//  Holo
//
//  统计分析页顶部维度筛选（账户/项目）：
//  - 胶囊行常驻时间胶囊下方，未筛选时显示「全部账户/全部项目」
//  - 点胶囊在正下方内联展开选择面板（与 TimeFilterBlock 同一心智：点选即生效并收起，无确认按钮）
//  - 选定后胶囊高亮并显示所选名称，三个页签数据全部随维度联动
//

import SwiftUI

// MARK: - 筛选面板开合状态

/// 顶部筛选展开态：时间/账户/项目三个面板互斥，同一时刻至多展开一个
enum AnalysisFilterPanel: Equatable {
    case none
    case time
    case account
    case project
}

// MARK: - 维度筛选胶囊行

struct ScopeFilterBar: View {
    @ObservedObject var state: FinanceAnalysisState
    @Binding var activePanel: AnalysisFilterPanel

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            chip(
                title: state.selectedAccount?.name ?? String(localized: "全部账户"),
                icon: "creditcard",
                isFiltered: state.selectedAccountId != nil,
                isExpanded: activePanel == .account
            ) {
                withAnimation(HoloAnimation.standard) {
                    activePanel = activePanel == .account ? .none : .account
                }
            }

            chip(
                title: state.selectedFinanceProject?.name ?? String(localized: "全部项目"),
                icon: "flag",
                isFiltered: state.selectedFinanceProjectId != nil,
                isExpanded: activePanel == .project
            ) {
                withAnimation(HoloAnimation.standard) {
                    activePanel = activePanel == .project ? .none : .project
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.xs)
    }

    /// 筛选胶囊：未筛选=卡片底+边框；筛选生效=品牌色填充白字（明示「正在按此维度看」）
    private func chip(title: String, icon: String, isFiltered: Bool, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.holoCaption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundColor(isFiltered ? .white : .holoTextSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isFiltered ? Color.holoPrimary : Color.holoCardBackground)
            )
            .overlay(
                Capsule().stroke(isFiltered ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 账户选择面板

struct AccountScopePanel: View {
    @ObservedObject var state: FinanceAnalysisState
    /// 点选后收起面板
    var onSelection: () -> Void

    /// 本期各账户支出（选择器行尾金额；排行数据不受账户筛选影响，金额稳定）
    private var expenseByAccount: [UUID: Decimal] {
        Dictionary(state.accountAggregations.map { ($0.account.id, $0.expense) },
                   uniquingKeysWith: { $0 + $1 })
    }

    private var activeAccounts: [Account] {
        state.availableAccounts.filter { !$0.isArchived }
    }

    private var archivedAccounts: [Account] {
        state.availableAccounts.filter { $0.isArchived }
    }

    var body: some View {
        panelCard {
            Text(String(localized: "选择账户"))
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            allOptionRow(
                title: String(localized: "全部账户"),
                isSelected: state.selectedAccountId == nil
            ) {
                state.setAccountFilter(nil)
                onSelection()
            }

            ForEach(activeAccounts, id: \.id) { account in
                accountRow(account)
            }

            if !archivedAccounts.isEmpty {
                Text(String(localized: "已归档"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, HoloSpacing.sm)

                ForEach(archivedAccounts, id: \.id) { account in
                    accountRow(account, isArchived: true)
                }
            }
        }
    }

    private func accountRow(_ account: Account, isArchived: Bool = false) -> some View {
        optionRow(
            icon: AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(account.swiftUIColor.opacity(0.16))
                    Image(systemName: account.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(account.swiftUIColor)
                }
                .frame(width: 26, height: 26)
            ),
            title: account.name,
            badge: isArchived ? String(localized: "已归档") : nil,
            amount: expenseByAccount[account.id],
            isSelected: state.selectedAccountId == account.id
        ) {
            state.setAccountFilter(account.id)
            onSelection()
        }
    }

    @ViewBuilder
    private func allOptionRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        optionRow(
            icon: AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.14))
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
                .frame(width: 26, height: 26)
            ),
            title: title,
            badge: nil,
            amount: nil,
            isSelected: isSelected,
            action: action
        )
    }

    /// 面板通用行：「全部」与具体项共用一套选中态画法
    private func optionRow(icon: AnyView, title: String, badge: String?, amount: Decimal?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                icon

                Text(title)
                    .font(.holoCaption)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.holoBackground))
                }

                Spacer()

                if let amount {
                    Text(NumberFormatter.compactCurrency(amount))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 项目选择面板

struct ProjectScopePanel: View {
    @ObservedObject var state: FinanceAnalysisState
    var onSelection: () -> Void

    /// 本期各项目支出（受账户筛选影响：选了账户时显示的是该账户内的项目支出，与页面口径一致）
    private var expenseByProject: [UUID: Decimal] {
        Dictionary(state.financeProjectAggregations.map { ($0.project.id, $0.expense) },
                   uniquingKeysWith: { $0 + $1 })
    }

    var body: some View {
        panelCard {
            Text(String(localized: "选择项目"))
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.setFinanceProjectFilter(nil)
                onSelection()
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.holoPrimary.opacity(0.14))
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }
                    .frame(width: 26, height: 26)

                    Text(String(localized: "全部项目"))
                        .font(.holoCaption)
                        .fontWeight(state.selectedFinanceProjectId == nil ? .semibold : .medium)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    if state.selectedFinanceProjectId == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(state.selectedFinanceProjectId == nil ? Color.holoPrimary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if state.availableFinanceProjects.isEmpty {
                Text(String(localized: "还没有项目，记账时可以把交易挂到项目上（如旅行、装修）"))
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.vertical, HoloSpacing.md)
            } else {
                ForEach(state.availableFinanceProjects, id: \.id) { project in
                    projectRow(project)
                }
            }
        }
    }

    private func projectRow(_ project: FinanceProject) -> some View {
        let isSelected = state.selectedFinanceProjectId == project.id
        let expense = expenseByProject[project.id]
        let budget = project.budgetDecimal

        return Button {
            state.setFinanceProjectFilter(project.id)
            onSelection()
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Text(project.icon)
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: project.color).opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.holoCaption)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    if let budget, let expense {
                        // 预算进度小字：与项目详情页同一「已花/预算」语言
                        Text("\(NumberFormatter.compactCurrency(expense)) / \(NumberFormatter.compactCurrency(budget))")
                            .font(.system(size: 9))
                            .foregroundColor(expense > budget ? .holoError : .holoTextSecondary)
                    }
                }

                Spacer()

                if let expense {
                    Text(NumberFormatter.compactCurrency(expense))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text(String(localized: "本期无支出"))
                        .font(.system(size: 9))
                        .foregroundColor(.holoTextPlaceholder)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 面板容器（与 TimeFilterBlock 同一套卡片语言）

@ViewBuilder
private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .padding(HoloSpacing.md)
    }
    // ScrollView 是贪婪视图：不 fixedSize 会占满外层给的可用高度而非内容高度，
    // 少量账户时卡片被撑出空白、内容反而被压缩截断（信用卡行拦腰截断实锤）。
    // 先按内容收缩，再由 maxHeight 钳住多账户/多项目场景的滚动上限。
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxHeight: 340)
    .background(Color.holoCardBackground)
    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    .overlay(
        RoundedRectangle(cornerRadius: HoloRadius.md)
            .stroke(Color.holoDivider, lineWidth: 1)
    )
    .padding(.horizontal, HoloSpacing.lg)
    .padding(.top, HoloSpacing.xs)
}
