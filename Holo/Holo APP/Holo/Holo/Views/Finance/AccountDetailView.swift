//
//  AccountDetailView.swift
//  Holo
//
//  账户详情页 - 账户信息、月度统计、交易历史
//

import SwiftUI
import CoreData

struct AccountDetailView: View {

    let account: Account

    @State private var balance: Decimal = 0
    @State private var monthlySummary: (income: Decimal, expense: Decimal, net: Decimal) = (0, 0, 0)
    @State private var transactions: [Transaction] = []
    // 信用卡账单信息（loadData 里取一次；body 内查库会让转场掉帧）
    @State private var creditCycleRange: (start: Date, end: Date)?
    @State private var creditStatement: (income: Decimal, expense: Decimal, net: Decimal) = (0, 0, 0)
    @State private var creditDaysToDue: Int?
    @State private var budgetStatus: BudgetStatus?
    @State private var showEditSheet = false
    @State private var showAdjustBalance = false
    @State private var showBudgetSettings = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// 正在编辑的交易（点击交易行进入编辑）
    @State private var editingTransaction: Transaction?
    /// 待删除的交易
    @State private var transactionToDelete: Transaction?
    /// 是否显示分期删除选项
    @State private var showInstallmentDeleteOptions = false
    /// 正在复制的交易
    @State private var copyingTransaction: Transaction?
    /// 复制目标日期
    @State private var copyTargetDate = Date()

    // 分类预算相关
    @State private var categoryBudgetStatuses: [(budget: Budget, status: BudgetStatus)] = []
    @State private var showCategoryBudgetSheet = false
    @State private var editingCategoryBudget: Budget?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.xl) {
                // 账户信息头部
                accountHeader

                // 信用卡本期账单（仅信用卡）
                if account.accountType.isCreditCard {
                    creditCardStatementCard
                }

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
        // 背景必须贯穿到导航栏/状态栏后面：否则 iOS 26 玻璃导航栏底下
        // 露出系统窗口黑底，页面顶部出现黑色片区
        .background(Color.holoBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 88)
        }
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
                        gateBudget { showBudgetSettings = true }
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
        // 编辑交易
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in
                loadData()
            }
        }
        // 复制交易日期选择
        .sheet(item: $copyingTransaction) { tx in
            NavigationStack {
                DatePicker(
                    "",
                    selection: $copyTargetDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, HoloSpacing.lg)
                .navigationTitle("复制到")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            copyingTransaction = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            performCopyTransaction(tx, targetDate: copyTargetDate)
                            copyingTransaction = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        // 普通交易删除确认
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { transactionToDelete != nil && !showInstallmentDeleteOptions },
                set: { if !$0 { transactionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除这笔交易", role: .destructive) {
                if let tx = transactionToDelete {
                    deleteTransaction(tx)
                }
            }
            Button("取消", role: .cancel) {
                transactionToDelete = nil
            }
        } message: {
            Text("删除后无法恢复，确定要删除吗？")
        }
        // 分期交易删除选项
        .confirmationDialog(
            "删除分期交易",
            isPresented: $showInstallmentDeleteOptions,
            titleVisibility: .visible
        ) {
            Button("仅删除此期", role: .destructive) {
                if let tx = transactionToDelete {
                    deleteTransaction(tx)
                }
            }
            Button("删除全部分期", role: .destructive) {
                if let tx = transactionToDelete, let groupId = tx.installmentGroupId {
                    deleteInstallmentGroup(groupId)
                }
            }
            Button("取消", role: .cancel) {
                transactionToDelete = nil
            }
        } message: {
            if let tx = transactionToDelete {
                Text("这是一笔分期交易（\(tx.installmentLabel ?? "")），请选择删除方式")
            }
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

            // 金额和进度百分比（分母为严格模式有效额度）
            HStack {
                Text("\(formatAmount(status.spentAmount)) / \(formatAmount(status.effectiveAmount))")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text("\(Int(status.progress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(budgetProgressColor(status.progress))
            }

            // 严格预算模式：让用户看懂「设了 10000 为什么显示 7000」
            if status.carryoverDeduction > 0 {
                HStack {
                    Text("上月超支结转 −\(formatAmount(status.carryoverDeduction)) · 原额度 \(formatAmount(status.budgetAmount))")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextPlaceholder)
                    Spacer()
                }
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
            gateBudget { showBudgetSettings = true }
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
                    gateBudget {
                        editingCategoryBudget = nil
                        showCategoryBudgetSheet = true
                    }
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

    /// 预算为 Plus 权益：非 Plus 弹付费墙，购买成功后回开原入口；存量预算展示不受影响
    private func gateBudget(_ open: @escaping () -> Void) {
        guard HoloEntitlementState.shared.isPlusActive else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .budget, resume: open)
            return
        }
        open()
    }

    /// 单个分类预算行
    private func categoryBudgetRow(budget: Budget, status: BudgetStatus) -> some View {
        Button {
            gateBudget {
                editingCategoryBudget = budget
                showCategoryBudgetSheet = true
            }
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
        return CategoryIconBadge(
            iconName: category?.icon ?? "chart.pie",
            color: category?.swiftUIColor ?? .holoTextSecondary,
            diameter: 32
        )
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

    // MARK: - Credit Card Statement

    /// 信用卡本期账单卡片
    private var creditCardStatementCard: some View {
        // 数据在 loadData() 里取（@State），body 内直接查库会让每次重画都
        // 同步跑一遍 Core Data 查询——页面转场时主线程被占住直接掉帧
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack {
                Text("账单信息")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                if let cycleRange = creditCycleRange {
                    Text(cycleRangeText(cycleRange))
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }

            // 账单日和还款日是账户的长期属性，放在详情页常驻展示。
            HStack(spacing: 0) {
                billingDateSummary(label: "账单日", day: account.billingDayInt)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .frame(height: 30)

                billingDateSummary(label: "还款日", day: account.dueDayInt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 本期账单总额
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoError)
                Text(formatAmount(creditStatement.expense))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }

            HStack(spacing: HoloSpacing.xl) {
                // 还款日倒计时
                if let days = creditDaysToDue {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("距还款日")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                        Text(days > 0 ? "\(days) 天" : days == 0 ? "今天" : "已逾期 \(-days) 天")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(days < 0 ? .holoError : (days <= 3 ? .holoError : .holoTextPrimary))
                    }
                }

                // 可用额度
                if let limit = account.creditLimitDecimal {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("可用额度")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                        Text(formatAmount(max(limit - creditStatement.expense, 0)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }
                }

                Spacer()
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    /// 展示信用卡的固定账单日期。
    private func billingDateSummary(label: String, day: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
            Text(day.map { "每月 \($0) 号" } ?? "未设置")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(day == nil ? .holoTextPlaceholder : .holoTextPrimary)
                .monospacedDigit()
        }
    }

    /// 信用卡当前账单周期范围（按该账户自己的 billingDay）
    private var creditCardCycleRange: (start: Date, end: Date) {
        let billingDay = account.billingDayInt ?? 1
        return BillingCycleCalculator.currentCycleRange(startDay: billingDay, reference: Date())
    }

    /// 账单周期文字描述
    private func cycleRangeText(_ range: (start: Date, end: Date)) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        // end 是半开区间（次周期起始日），显示前一天作为周期末尾
        let lastDay = Calendar.current.date(byAdding: .second, value: -1, to: range.end) ?? range.end
        return "\(fmt.string(from: range.start)) - \(fmt.string(from: lastDay))"
    }

    /// 距还款日天数（负数=已逾期）
    private func daysUntilRepayment(cycleRange: (start: Date, end: Date)) -> Int? {
        guard let billingDay = account.billingDayInt, let dueDay = account.dueDayInt else { return nil }
        let dueDate = BillingCycleCalculator.dueDate(
            billingDay: billingDay,
            dueDay: dueDay,
            cycleStart: cycleRange.start
        )
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dueDayStart = cal.startOfDay(for: dueDate)
        return cal.dateComponents([.day], from: today, to: dueDayStart).day ?? 0
    }

    // MARK: - Monthly Stats

    private var monthlyStatsCard: some View {
        VStack(spacing: HoloSpacing.md) {
            Text("本期统计")
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
                                TransactionRowView(transaction: tx) {
                                    editingTransaction = tx
                                }
                                .contextMenu {
                                    Button {
                                        editingTransaction = tx
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }

                                    Button {
                                        copyingTransaction = tx
                                        copyTargetDate = tx.date
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }

                                    Button(role: .destructive) {
                                        transactionToDelete = tx
                                        if tx.isInstallment {
                                            showInstallmentDeleteOptions = true
                                        }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadData() {
        balance = FinanceRepository.shared.getAccountBalance(account)
        monthlySummary = FinanceRepository.shared.getAccountMonthlySummary(
            accountId: account.id,
            month: Date()
        )
        transactions = FinanceRepository.shared.getAccountTransactions(accountId: account.id)

        // 信用卡账单信息（一次取好，body 只读状态）
        if account.accountType.isCreditCard {
            let range = creditCardCycleRange
            creditCycleRange = range
            creditStatement = FinanceRepository.shared.getAccountSummary(
                accountId: account.id,
                from: range.start,
                to: range.end
            )
            creditDaysToDue = daysUntilRepayment(cycleRange: range)
        } else {
            creditCycleRange = nil
            creditDaysToDue = nil
        }

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

    /// 同年分组标题：「8月22日 星期六」
    private static let sameYearDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    /// 跨年分组标题：「2027年1月5日 星期二」，不带年份会分不清归属年份
    private static let crossYearDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return Self.sameYearDateFormatter.string(from: date)
        }
        return Self.crossYearDateFormatter.string(from: date)
    }

    private func groupByDate(_ transactions: [Transaction]) -> [Date: [Transaction]] {
        var groups: [Date: [Transaction]] = [:]
        for tx in transactions {
            let key = Calendar.current.startOfDay(for: tx.date)
            groups[key, default: []].append(tx)
        }
        return groups
    }

    // MARK: - 交易编辑/删除/复制

    /// 删除单笔交易
    private func deleteTransaction(_ transaction: Transaction) {
        Task {
            do {
                try await FinanceRepository.shared.deleteTransaction(transaction)
                loadData()
            } catch {
                errorMessage = "删除失败：\(error.localizedDescription)"
                showError = true
            }
            transactionToDelete = nil
            showInstallmentDeleteOptions = false
        }
    }

    /// 删除整个分期组
    private func deleteInstallmentGroup(_ groupId: UUID) {
        Task {
            do {
                try await FinanceRepository.shared.deleteInstallmentGroup(groupId: groupId)
                loadData()
            } catch {
                errorMessage = "删除失败：\(error.localizedDescription)"
                showError = true
            }
            transactionToDelete = nil
            showInstallmentDeleteOptions = false
        }
    }

    /// 复制交易到指定日期
    private func performCopyTransaction(_ original: Transaction, targetDate: Date) {
        Task {
            do {
                guard let category = original.category,
                      let account = original.account else { return }
                _ = try await FinanceRepository.shared.addTransaction(
                    amount: abs(original.amount.decimalValue),
                    type: original.transactionType,
                    category: category,
                    account: account,
                    date: targetDate,
                    note: original.note,
                    remark: original.remark,
                    tags: original.tags
                )
                loadData()
            } catch {
                errorMessage = "复制失败：\(error.localizedDescription)"
                showError = true
            }
        }
    }
}
