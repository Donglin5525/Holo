//
//  DimensionSwitcherSheet.swift
//  Holo
//
//  统计分析页维度视角切换层（2026-10-03 东林定稿交互）：
//  点页面标题「统计分析」唤起，全部 / 账户 / 项目 三段单选，
//  选定后标题变为「统计 · 维度名」，三页签数据全部联动。
//  单视角语义：账户与项目互斥，不再叠加交集。
//

import SwiftUI

struct DimensionSwitcherSheet: View {
    @ObservedObject var state: FinanceAnalysisState
    @Environment(\.dismiss) private var dismiss

    /// 本期各账户支出（行尾金额；排行口径不受账户筛选影响，金额稳定）
    private var expenseByAccount: [UUID: Decimal] {
        Dictionary(state.accountAggregations.map { ($0.account.id, $0.expense) },
                   uniquingKeysWith: { $0 + $1 })
    }

    /// 本期各项目支出
    private var expenseByProject: [UUID: Decimal] {
        Dictionary(state.financeProjectAggregations.map { ($0.project.id, $0.expense) },
                   uniquingKeysWith: { $0 + $1 })
    }

    private var activeAccounts: [Account] {
        state.availableAccounts.filter { !$0.isArchived }
    }

    private var archivedAccounts: [Account] {
        state.availableAccounts.filter { $0.isArchived }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    // 第一段：全部
                    allRow

                    // 第二段：账户
                    sectionTitle(String(localized: "账户"))
                    ForEach(activeAccounts, id: \.id) { account in
                        accountRow(account)
                    }
                    if !archivedAccounts.isEmpty {
                        sectionTitle(String(localized: "已归档"))
                        ForEach(archivedAccounts, id: \.id) { account in
                            accountRow(account, isArchived: true)
                        }
                    }

                    // 第三段：项目
                    sectionTitle(String(localized: "项目"))
                    if state.availableFinanceProjects.isEmpty {
                        Text(String(localized: "还没有项目，记账时可以把交易挂到项目上（如旅行、装修）"))
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.vertical, HoloSpacing.sm)
                    } else {
                        ForEach(state.availableFinanceProjects, id: \.id) { project in
                            projectRow(project)
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xl)
            }
        }
        .holoSheetShell()
    }

    // MARK: - 头部

    private var sheetHeader: some View {
        ZStack {
            Text(String(localized: "选择账户或项目"))
                .font(.holoTitle3)
                .foregroundColor(.holoTextPrimary)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.holoCardBackground))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "关闭")))
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.md)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.top, HoloSpacing.sm)
    }

    // MARK: - 行

    private var allRow: some View {
        dimensionRow(
            icon: AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.14))
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
                .frame(width: 30, height: 30)
            ),
            title: String(localized: "全部"),
            subtitle: String(localized: "汇总所有账户与项目"),
            badge: nil,
            amount: nil,
            isSelected: !state.isScopeFiltered
        ) {
            state.setAccountFilter(nil)
            dismiss()
        }
    }

    private func accountRow(_ account: Account, isArchived: Bool = false) -> some View {
        dimensionRow(
            icon: AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(account.swiftUIColor.opacity(0.16))
                    Image(systemName: account.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(account.swiftUIColor)
                }
                .frame(width: 30, height: 30)
            ),
            title: account.name,
            subtitle: nil,
            badge: isArchived ? String(localized: "已归档") : nil,
            amount: expenseByAccount[account.id],
            isSelected: state.selectedAccountId == account.id
        ) {
            state.setAccountFilter(account.id)
            dismiss()
        }
    }

    private func projectRow(_ project: FinanceProject) -> some View {
        let expense = expenseByProject[project.id]
        let budget = project.budgetDecimal
        var subtitle: String? {
            if let expense, let budget {
                return "\(NumberFormatter.compactCurrency(expense)) / \(NumberFormatter.compactCurrency(budget))"
            }
            return nil
        }

        return dimensionRow(
            icon: AnyView(
                Text(project.icon)
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(hex: project.color).opacity(0.14))
                    )
            ),
            title: project.name,
            subtitle: subtitle,
            badge: nil,
            amount: expense,
            isSelected: state.selectedFinanceProjectId == project.id
        ) {
            state.setFinanceProjectFilter(project.id)
            dismiss()
        }
    }

    /// 三段共用的单选行：图标 + 名称（+副标题/徽标）+ 本期支出 + 选中勾
    private func dimensionRow(
        icon: AnyView,
        title: String,
        subtitle: String?,
        badge: String?,
        amount: Decimal?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                icon

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
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
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: HoloSpacing.sm)

                if let amount {
                    Text(NumberFormatter.compactCurrency(amount))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize()
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextPlaceholder.opacity(0.5))
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.07) : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .strokeBorder(isSelected ? Color.holoPrimary.opacity(0.35) : Color.holoDivider.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
