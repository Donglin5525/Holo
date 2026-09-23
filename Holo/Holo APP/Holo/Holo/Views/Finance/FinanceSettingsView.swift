//
//  FinanceSettingsView.swift
//  Holo
//
//  财务设置视图（2026-09-19 重设计：全区块收敛到 HoloSettingsSection 统一卡片语言）
//

import SwiftUI

struct FinanceSettingsView: View {
    let onBack: () -> Void
    @ObservedObject private var displaySettings = FinanceDisplaySettings.shared
    @ObservedObject private var periodSettings = FinancePeriodSettings.shared
    @ObservedObject private var budgetSettings = FinanceBudgetSettings.shared
    @State private var showClearFinanceSheet = false
    /// 图片自动记账待复核数量（§11 角标）
    @State private var receiptDraftCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            // 顶部栏
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

                Text("设置")
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, 0)
            .padding(.bottom, HoloSpacing.md)

            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    // 记账周期模块
                    billingCycleSection

                    // 图片自动记账（快捷指令入口，2026-09-14 方案 §11）
                    automationSection

                    // 预算模块
                    strictBudgetSection

                    // 显示设置模块
                    displaySection

                    // 数据导入导出模块
                    ImportExportView()

                    // 危险区：清空财务数据（进 30 天回收站，设置-数据管理-最近删除可恢复）
                    clearDataSection

                    // 分类管理模块
                    categorySection
                }
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .background(Color.holoBackground)
        }
    }
}

// MARK: - 记账周期设置

private extension FinanceSettingsView {

    var billingCycleSection: some View {
        HoloSettingsSection(title: "记账周期") {
            HoloSettingsRow(
                icon: "calendar.badge.clock",
                title: "每月起始日",
                subtitle: cycleDescription
            ) {
                // 周期账单为 Plus 权益：非 Plus 只读展示当前生效值，点击升级
                if HoloEntitlementState.shared.isPlusActive {
                    Stepper(
                        "\(periodSettings.billingCycleStartDay) 号",
                        value: $periodSettings.billingCycleStartDay,
                        in: 1...31
                    )
                    .labelsHidden()
                } else {
                    Button {
                        HoloPlusActionCoordinator.shared.requirePlus(context: .billingCycle)
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(periodSettings.billingCycleStartDay) 号")
                                .font(.system(size: 15))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 起始日的文字说明
    var cycleDescription: String {
        if periodSettings.isNaturalMonth {
            return String(localized: "当前按自然月（1 号到月底）统计")
        }
        let day = periodSettings.billingCycleStartDay
        return String(localized: "统计按 \(day) 号 → 次月 \(day - 1) 号计算，与信用卡账单对齐")
    }
}

// MARK: - 图片自动记账入口

private extension FinanceSettingsView {

    var automationSection: some View {
        HoloSettingsSection(title: "自动化") {
            NavigationLink {
                ReceiptBookingSettingsView()
            } label: {
                HoloSettingsRow(
                    icon: "photo.badge.checkmark",
                    title: "图片自动记账",
                    subtitle: "操作按钮一按，自动识别账户与项目"
                ) {
                    HStack(spacing: HoloSpacing.sm) {
                        // 待复核角标（§11）：存在待复核项时显示数量
                        if receiptDraftCount > 0 {
                            HoloSettingsBadge(count: receiptDraftCount)
                        }
                        HoloSettingsChevron()
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            receiptDraftCount = ReceiptBookingResultStore.shared.loadDrafts().count
        }
    }
}

// MARK: - 显示设置

private extension FinanceSettingsView {

    var displaySection: some View {
        HoloSettingsSection(title: "显示设置") {
            HoloSettingsRow(
                icon: "arrow.down.right",
                iconColor: .holoError,
                title: String(localized: "本月支出")
            ) {
                Toggle("", isOn: $displaySettings.showMonthlyExpense)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            HoloSettingsDivider()

            HoloSettingsRow(
                icon: "arrow.up.right",
                iconColor: .holoSuccess,
                title: String(localized: "本月收入")
            ) {
                Toggle("", isOn: $displaySettings.showMonthlyIncome)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            if displaySettings.showMonthlyExpense && displaySettings.showMonthlyIncome {
                HoloSettingsFootnote(text: String(localized: "双卡并排时隐藏「今日」金额，仅单独展示时显示"))
            }
        }
    }
}

// MARK: - 危险区（清空财务数据）

private extension FinanceSettingsView {

    var clearDataSection: some View {
        HoloSettingsSection {
            Button {
                showClearFinanceSheet = true
            } label: {
                HoloSettingsRow(
                    icon: "trash.circle",
                    iconColor: .holoError,
                    title: "清空财务数据",
                    titleColor: .holoError,
                    subtitle: "可选仅清交易或全部清空；30 天内可在最近删除恢复"
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .sheet(isPresented: $showClearFinanceSheet) {
            ModuleClearSheet(module: .finance)
        }
    }
}

// MARK: - 分类管理入口

private extension FinanceSettingsView {

    var categorySection: some View {
        HoloSettingsSection(title: "分类管理") {
            NavigationLink {
                CategoryManagementView()
            } label: {
                HoloSettingsRow(icon: "folder.fill", title: "分类") {
                    HoloSettingsChevron()
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 严格预算模式设置（账户粒度）

private extension FinanceSettingsView {

    var strictBudgetSection: some View {
        let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
        guard !accounts.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(HoloSettingsSection(title: "严格预算模式") {
            ForEach(accounts, id: \.id) { account in
                strictModeToggleRow(account)
                if account.id != accounts.last?.id {
                    HoloSettingsDivider()
                }
            }

            HoloSettingsFootnote(text: String(localized: "超支多少，下个月的预算额度就扣多少（最低扣到 0）；省下的钱不累积，下月不超支就自动恢复原额度。"))
        })
    }

    private func strictModeToggleRow(_ account: Account) -> some View {
        HoloSettingsRow(
            icon: account.icon,
            iconColor: account.swiftUIColor,
            title: account.name
        ) {
            Toggle("", isOn: strictModeBinding(for: account))
                .labelsHidden()
                .tint(.holoPrimary)
        }
    }

    private func strictModeBinding(for account: Account) -> Binding<Bool> {
        Binding(
            get: { budgetSettings.isEnabled(for: account.id) },
            set: { $0 ? budgetSettings.enable(for: account.id) : budgetSettings.disable(for: account.id) }
        )
    }
}
