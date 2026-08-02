//
//  AccountListView.swift
//  Holo
//
//  账户总览页 - 财务模块底部第 1 个 Tab，展示净资产、按类型分组的账户列表
//

import SwiftUI
import Charts

struct AccountListView: View {

    /// 返回上一级（与其他 Tab 一致的返回交互）
    let onBack: () -> Void

    @State private var accounts: [Account] = []
    @State private var showAddAccount = false
    @State private var netWorthData: (assets: Decimal, liabilities: Decimal, netWorth: Decimal) = (0, 0, 0)
    @State private var netWorthSnapshots: [NetWorthSnapshot] = []

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    // 净资产总览卡片（内含趋势曲线）
                    netWorthCard

                    // 按类型分组的账户列表
                    accountListSection
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 88)
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet(mode: .create) { _ in
                    loadData()
                }
            }
            .onAppear {
                loadData()
                // 进入账户页时捕获当月净资产快照 + 首次回填历史
                // 放在此处而非 App 启动时，避免 schema 迁移期间的高风险查询阻塞启动
                NetWorthSnapshotService.shared.backfillHistory()
                NetWorthSnapshotService.shared.captureCurrentSnapshot()
            }
        }
    }

    // MARK: - 净资产卡片（含趋势曲线）

    private var netWorthCard: some View {
        // 计算本月变化（与上一个月净资产对比）
        let monthChange: Decimal? = {
            guard netWorthSnapshots.count >= 2 else { return nil }
            let current = netWorthSnapshots.last?.netWorthDecimal ?? 0
            let previous = netWorthSnapshots.dropLast().last?.netWorthDecimal ?? 0
            return current - previous
        }()

        return VStack(spacing: HoloSpacing.md) {
            // 顶部：标签 + 本月变化
            HStack(alignment: .firstTextBaseline) {
                Text("净资产")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                if let monthChange {
                    HStack(spacing: 2) {
                        Image(systemName: monthChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(formatChangeAmount(monthChange))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(monthChange >= 0 ? .holoSuccess : .holoError)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((monthChange >= 0 ? Color.holoSuccess : Color.holoError).opacity(0.08))
                    .clipShape(Capsule())
                }
            }

            // 净资产大数字
            Text(formatAmount(netWorthData.netWorth))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(netWorthData.netWorth >= 0 ? .holoTextPrimary : .holoError)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 趋势曲线（融入卡片，≥2 个数据点才显示）
            if netWorthSnapshots.count >= 2 {
                netWorthTrendChart
                    .frame(height: 100)
            }

            // 底部：总资产 / 总负债
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总资产")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(netWorthData.assets))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoSuccess)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("总负债")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                    Text(formatAmount(netWorthData.liabilities))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoError)
                }
            }
            .padding(.top, 2)
        }
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    // MARK: - Account List（分组连续卡片）

    private var accountListSection: some View {
        VStack(spacing: HoloSpacing.md) {
            ForEach(groupedAccounts.keys.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { accountType in
                if let typeAccounts = groupedAccounts[accountType], !typeAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                        Text(accountType.displayName)
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                            .padding(.leading, HoloSpacing.xs)

                        // 同组账户共用一个卡片容器，行间用 Divider 连续，视觉更像「列表」而非散落卡片
                        VStack(spacing: 0) {
                            ForEach(Array(typeAccounts.enumerated()), id: \.element.objectID) { index, account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    accountRow(account)
                                }
                                .buttonStyle(PlainButtonStyle())

                                // 组内最后一行不画分隔线
                                if index < typeAccounts.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                        .background(Color.holoDivider.opacity(0.3))
                                }
                            }
                        }
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let balance = FinanceRepository.shared.getAccountBalance(account)

        return HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(account.swiftUIColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: account.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(account.swiftUIColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    if account.isDefault {
                        Text("默认")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if account.isArchived {
                        Text("已归档")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.holoGlassBackground)
                            .clipShape(Capsule())
                    }
                }

                // 信用卡显示额度信息，其他显示类型名
                if account.accountType.isCreditCard, account.creditLimitDecimal > 0 {
                    Text("额度 \(formatAmount(account.creditLimitDecimal))")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text(account.accountType.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatAmount(balance))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(balance >= 0 ? .holoTextPrimary : .holoError)

                // 信用卡显示可用额度
                if account.accountType.isCreditCard, let available = account.availableCredit(balance: balance) {
                    Text("可用 \(formatAmount(available))")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var groupedAccounts: [AccountType: [Account]] {
        var groups: [AccountType: [Account]] = [:]
        for account in accounts {
            let type = account.accountType
            groups[type, default: []].append(account)
        }
        return groups
    }

    private func loadData() {
        accounts = FinanceRepository.shared.getAccounts(includeArchived: true)
        netWorthData = FinanceRepository.shared.getTotalNetWorth()
        netWorthSnapshots = NetWorthSnapshotService.shared.fetchRecentSnapshots(months: 6)
    }

    // MARK: - 净资产趋势曲线（Swift Charts，与分析页同级质量）

    /// 图表数据点
    private var trendDataPoints: [(date: Date, value: Double)] {
        netWorthSnapshots.map {
            ($0.monthStart, NSDecimalNumber(decimal: $0.netWorthDecimal).doubleValue)
        }
    }

    /// Y 轴范围（稳定，向上取整到整齐刻度）
    private var yAxisDomain: ClosedRange<Double> {
        let values = trendDataPoints.map(\.value)
        guard !values.isEmpty else { return 0...1 }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        // 基于最小值向下、最大值向上各留 15% 余量
        let padding = max((maxVal - minVal) * 0.15, 1)
        return (minVal - padding)...(maxVal + padding)
    }

    private var netWorthTrendChart: some View {
        Chart(trendDataPoints, id: \.date) { point in
            // 渐变面积
            AreaMark(
                x: .value("月份", point.date),
                yStart: .value("基线", yAxisDomain.lowerBound),
                yEnd: .value("净资产", point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.holoPrimary.opacity(0.18), Color.holoPrimary.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            // 折线
            LineMark(
                x: .value("月份", point.date),
                y: .value("净资产", point.value)
            )
            .foregroundStyle(Color.holoPrimary)
            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartYScale(domain: yAxisDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel() {
                    if let date = value.as(Date.self) {
                        Text(formatMonth(date))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.holoDivider.opacity(0.32))
                AxisValueLabel() {
                    if let val = value.as(Double.self) {
                        Text(formatAxisValue(val))
                            .font(.system(size: 10))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(Color.clear)
        }
    }

    private func formatMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月"
        return f.string(from: date)
    }

    private func formatAxisValue(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 10_000 {
            return String(format: "%.1f万", value / 10_000)
        } else if absValue >= 1 {
            return String(format: "%.0f", value)
        } else {
            return ""
        }
    }

    private func formatChangeAmount(_ amount: Decimal) -> String {
        let absAmount = abs(amount)
        let formatted = NumberFormatter.currency.string(from: absAmount as NSDecimalNumber) ?? ""
        return "\(amount >= 0 ? "+" : "-")\(formatted)"
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}
