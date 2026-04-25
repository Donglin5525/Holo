//
//  AccountDetailView.swift
//  Holo
//
//  账户详情页 - 账户信息、月度统计、交易历史
//

import SwiftUI

struct AccountDetailView: View {

    let account: Account

    @State private var balance: Decimal = 0
    @State private var monthlySummary: (income: Decimal, expense: Decimal, net: Decimal) = (0, 0, 0)
    @State private var transactions: [Transaction] = []
    @State private var budgetStatus: BudgetStatus?
    @State private var showEditSheet = false
    @State private var showAdjustBalance = false
    @State private var showBudgetSettings = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false

    // 分类预算相关
    @State private var categoryBudgetStatuses: [(budget: Budget, status: BudgetStatus)] = []
    @State private var showCategoryBudgetSheet = false
    @State private var editingCategoryBudget: Budget?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xl) {
                // 账户信息头部
                accountHeader

                // 月度预算卡片
                budgetCard

                // 分类预算列表
                categoryBudgetSection

                // 月度统计
                monthlyStatsCard

                // 交易历史
                transactionListSection
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button {
                        showAdjustBalance = true
                    } label: {
                        Label("调整余额", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        showBudgetSettings = true
                    } label: {
                        Label("预算设置", systemImage: "chart.line.uptrend.xyaxis")
                    }

                    if account.isDefault {
                        Button {} label: {
                            Label("设为默认（当前默认）", systemImage: "star.fill")
                        }
                        .disabled(true)
                    } else {
                        Button {
                            FinanceRepository.shared.setDefaultAccount(account)
                            loadData()
                        } label: {
                            Label("设为默认", systemImage: "star")
                        }
                    }

                    Divider()

                    if !account.isArchived {
                        Button(role: .destructive) {
                            do {
                                try FinanceRepository.shared.archiveAccount(account)
                                loadData()
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        } label: {
                            Label("归档", systemImage: "archivebox")
                        }
                    } else {
                        Button {
                            FinanceRepository.shared.unarchiveAccount(account)
                            loadData()
                        } label: {
                            Label("取消归档", systemImage: "archivebox.fill")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddAccountSheet(mode: .edit(account)) { _ in
                loadData()
            }
        }
        .sheet(isPresented: $showAdjustBalance) {
            AdjustBalanceSheet(account: account) {
                loadData()
            }
        }
        .sheet(isPresented: $showBudgetSettings) {
            BudgetSettingsSheet(
                account: account,
                existingBudget: budgetStatus?.budget
            ) {
                loadData()
            }
        }
        .sheet(isPresented: $showCategoryBudgetSheet) {
            BudgetSettingsSheet(
                account: account,
                existingBudget: editingCategoryBudget,
                initialMode: .category
            ) {
                loadData()
                editingCategoryBudget = nil
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do {
                    try FinanceRepository.shared.deleteAccount(account)
                    // 返回上一页
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        } message: {
            Text("确定要删除账户「\(account.name)」吗？")
        }
        .alert("操作失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onAppear {
            loadData()
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        VStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(account.swiftUIColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: account.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(account.swiftUIColor)
            }

            Text(account.name)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            Text(formatAmount(balance))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(balance >= 0 ? .holoTextPrimary : .holoError)

            HStack(spacing: HoloSpacing.sm) {
                Text(account.accountType.displayName)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.holoGlassBackground)
                    .clipShape(Capsule())

                if account.isDefault {
                    Text("默认账户")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Budget Card

    private var budgetCard: some View {
        Group {
            if let status = budgetStatus {
                // 有预算：显示进度卡片
                budgetProgressCard(status)
            } else {
                // 无预算：显示引导卡片
                budgetEmptyCard
            }
        }
    }

    private func budgetProgressCard(_ status: BudgetStatus) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Text("月度预算")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.holoDivider.opacity(0.3))
                        .frame(height: 12)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(budgetProgressColor(status.progress))
                        .frame(
                            width: geometry.size.width * min(CGFloat(status.progress), 1.0),
                            height: 12
                        )
                }
            }
            .frame(height: 12)

            // 金额和进度百分比
            HStack {
                Text("\(formatAmount(status.spentAmount)) / \(formatAmount(status.budgetAmount))")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("\(Int(status.progress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(budgetProgressColor(status.progress))
            }

            // 剩余信息
            HStack {
                if status.isOverBudget {
                    Text("已超支 \(formatAmount(abs(status.remainingAmount)))")
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                } else {
                    Text("剩余 \(formatAmount(status.remainingAmount))")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Text("·")
                    .foregroundColor(.holoTextSecondary)

                Text("\(status.remainingDays)天")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    private var budgetEmptyCard: some View {
        Button {
            showBudgetSettings = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundColor(.holoTextSecondary)

                Text("点击设置月度预算")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        }
    }

    /// 根据进度返回对应颜色
    private func budgetProgressColor(_ progress: Double) -> Color {
        if progress >= 1.0 {
            return .holoError
        } else if progress >= 0.8 {
            return .holoPrimary
        } else if progress >= 0.6 {
            return .holoChart8
        } else {
            return .holoSuccess
        }
    }

    // MARK: - Category Budget Section

    /// 分类预算列表区域
    private var categoryBudgetSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题行 + 添加按钮
            HStack {
                Text("分类预算")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    editingCategoryBudget = nil
                    showCategoryBudgetSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text("添加")
                            .font(.holoCaption)
                    }
                    .foregroundColor(.holoPrimary)
                }
            }

            if categoryBudgetStatuses.isEmpty {
                // 空状态
                VStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 24))
                        .foregroundColor(.holoTextSecondary.opacity(0.4))
                    Text("暂无分类预算")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.lg)
            } else {
                // 分类预算行
                ForEach(categoryBudgetStatuses, id: \.budget.id) { item in
                    categoryBudgetRow(budget: item.budget, status: item.status)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 单个分类预算行
    private func categoryBudgetRow(budget: Budget, status: BudgetStatus) -> some View {
        Button {
            editingCategoryBudget = budget
            showCategoryBudgetSheet = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                // 分类图标
                categoryIconForBudget(budget)

                // 名称 + mini 进度条
                VStack(alignment: .leading, spacing: 4) {
                    Text(categoryNameForBudget(budget))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.holoBorder.opacity(0.3))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(budgetProgressColor(status.progress))
                                .frame(
                                    width: geo.size.width * min(CGFloat(status.progress), 1.0),
                                    height: 4
                                )
                        }
                    }
                    .frame(height: 4)
                }

                Spacer()

                // 百分比 + 剩余/超支
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(status.progress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(budgetProgressColor(status.progress))
                    if status.isOverBudget {
                        Text("超支 \(formatAmount(status.remainingAmount))")
                            .font(.system(size: 10))
                            .foregroundColor(.holoError)
                    } else {
                        Text("剩余 \(formatAmount(status.remainingAmount))")
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                deleteCategoryBudget(budget)
            } label: {
                Label("删除预算", systemImage: "trash")
            }
        }
    }

    /// 分类预算行的分类名称
    private func categoryNameForBudget(_ budget: Budget) -> String {
        guard let catId = budget.categoryId else { return "总预算" }
        return BudgetRepository.shared.findCategory(by: catId)?.name ?? "未知分类"
    }

    /// 分类预算行的分类图标
    private func categoryIconForBudget(_ budget: Budget) -> some View {
        let category = budget.categoryId.flatMap { BudgetRepository.shared.findCategory(by: $0) }
        return ZStack {
            Circle()
                .fill((category?.swiftUIColor ?? .holoTextSecondary).opacity(0.12))
                .frame(width: 32, height: 32)
            Image(systemName: category?.icon ?? "chart.pie")
                .font(.system(size: 14))
                .foregroundColor(category?.swiftUIColor ?? .holoTextSecondary)
        }
    }

    /// 删除分类预算
    private func deleteCategoryBudget(_ budget: Budget) {
        do {
            try BudgetRepository.shared.deleteBudget(budget)
            HapticManager.success()
            loadData()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - Monthly Stats

    private var monthlyStatsCard: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("本月统计")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                VStack(spacing: HoloSpacing.xs) {
                    Text("收入")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.income))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoSuccess)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 36)

                VStack(spacing: HoloSpacing.xs) {
                    Text("支出")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.expense))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoError)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 36)

                VStack(spacing: HoloSpacing.xs) {
                    Text("净变动")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(monthlySummary.net))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(monthlySummary.net >= 0 ? .holoSuccess : .holoError)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Transaction List

    private var transactionListSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("交易记录")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            if transactions.isEmpty {
                VStack(spacing: HoloSpacing.md) {
                    Image(systemName: "receipt")
                        .font(.system(size: 32))
                        .foregroundColor(.holoTextSecondary)
                    Text("暂无交易记录")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(HoloSpacing.xl)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            } else {
                // 按日期分组
                let grouped = groupByDate(transactions)
                ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                    if let dayTransactions = grouped[date] {
                        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                            Text(formatDate(date))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .padding(.leading, HoloSpacing.sm)

                            ForEach(dayTransactions, id: \.objectID) { tx in
                                transactionRow(tx)
                            }
                        }
                    }
                }
            }
        }
    }

    private func transactionRow(_ tx: Transaction) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(tx.category.swiftUIColor.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: tx.category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tx.category.swiftUIColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.note ?? tx.category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                if tx.category.isSystem {
                    Text("[余额调整]")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            let amount = tx.amount.decimalValue
            Text(tx.transactionType == .income ? "+\(formatAmount(amount))" : "-\(formatAmount(amount))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(tx.transactionType == .income ? .holoSuccess : .holoError)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func loadData() {
        balance = FinanceRepository.shared.getAccountBalance(account)
        monthlySummary = FinanceRepository.shared.getAccountMonthlySummary(
            accountId: account.id,
            month: Date()
        )
        transactions = FinanceRepository.shared.getAccountTransactions(accountId: account.id)
        budgetStatus = BudgetRepository.shared.computeTotalBudgetStatus(
            forAccount: account.id,
            period: .month
        )

        // 加载分类预算
        let categoryBudgets = BudgetRepository.shared.getCategoryBudgets(forAccount: account.id)
        categoryBudgetStatuses = categoryBudgets.compactMap { budget in
            guard let status = BudgetRepository.shared.computeBudgetStatus(budget: budget) else {
                return nil
            }
            return (budget, status)
        }
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: abs(amount))) ?? "¥0.00"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    private func groupByDate(_ transactions: [Transaction]) -> [Date: [Transaction]] {
        var groups: [Date: [Transaction]] = [:]
        for tx in transactions {
            let key = Calendar.current.startOfDay(for: tx.date)
            groups[key, default: []].append(tx)
        }
        return groups
    }
}
