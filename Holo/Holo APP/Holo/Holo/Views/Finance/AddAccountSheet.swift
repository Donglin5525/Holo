//
//  AddAccountSheet.swift
//  Holo
//
//  添加/编辑账户 Sheet
//

import SwiftUI

/// 账户编辑模式
enum AccountEditMode {
    case create
    case edit(Account)
}

struct AddAccountSheet: View {

    let mode: AccountEditMode
    let onComplete: (Account) -> Void

    @Environment(\.dismiss) var dismiss
    /// 名额判定含会员状态：购买成功/过期即时刷新锁定态
    @ObservedObject private var entitlementState = HoloEntitlementState.shared

    // 表单状态
    @State private var name: String = ""
    @State private var selectedType: AccountType = .cash
    @State private var selectedColor: String = "#64748B"
    @State private var initialBalance: String = "0"
    @State private var notes: String = ""

    // 信用卡账单信息（仅信用卡类型使用）
    @State private var billingDay: Int = 5
    @State private var dueDay: Int = 25
    @State private var creditLimit: String = ""
    /// 还款提醒（区域的钥匙：开着才能编辑账单日/还款日；免费档限 3 张卡）
    @State private var dueReminderEnabled: Bool = false
    @State private var dueReminderLeadDays: Int = 1
    /// 免费档名额判定（不含会员短路），onAppear 算一次：弹层开着期间名额只会被本页改动，
    /// 不在 body 里每次重画都查库
    @State private var freeQuotaAllows: Bool = true

    // UI 状态
    /// 免费名额已满的说明弹窗（先解释再让用户选，不直接甩付费墙）
    @State private var showDueQuotaAlert = false
    @State private var showError = false
    @State private var errorMessage = ""
    /// 编辑模式改期初的余额跳变确认
    @State private var showInitialBalanceConfirm = false
    /// 编辑模式进入时的原期初（判断是否变化、预览余额变化）
    @State private var originalInitialBalance: Decimal = 0
    @State private var currentBalance: Decimal = 0
    @State private var hasReconciliationAnchor = false

    // 颜色预设
    private let colorPresets = [
        "#22C55E", "#07C160", "#1677FF", "#6366F1",
        "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6",
        "#14B8A6", "#F97316", "#64748B", "#0EA5E9"
    ]

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingAccount: Account? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    // 名称
                    nameSection

                    // 类型选择
                    typeSection

                    // 颜色选择
                    colorSection

                    // 初始余额（创建与编辑都可改；编辑改期初用于「差额来自更早历史」的对账场景）
                    balanceSection

                    // 信用卡账单信息（仅信用卡类型）
                    if selectedType.isCreditCard {
                        creditCardInfoSection
                    }

                    // 备注
                    notesSection
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(isEditMode ? "编辑账户" : "新建账户")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(.holoToolTextSecondary) }
                            .accessibilityLabel(Text("关闭"))
                        .foregroundColor(.holoToolTextSecondary)
                }
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button("保存") { save() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSave ? .holoPrimary : .holoToolTextSecondary)
                        .disabled(!canSave)
                }
            }
            .alert("保存失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .holoQuotaNotice(isPresented: $showDueQuotaAlert) {
                HoloPlusActionCoordinator.shared.requirePlus(
                    context: .creditCardReminder,
                    resume: { dueReminderEnabled = true }
                )
            }
            .alert("修改期初余额", isPresented: $showInitialBalanceConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认修改") { performSave() }
            } message: {
                Text("当前余额 \(AccountCardFormat.prefixed(currentBalance)) 将变为 \(AccountCardFormat.prefixed(currentBalance - originalInitialBalance + newInitialBalance))\(hasReconciliationAnchor ? "；已对过账的基准会失效，建议保存后再对一次账" : "")")
            }
            .onAppear {
                freeQuotaAllows = CreditCardDueReminderScheduler.freeQuotaAllows(for: editingAccount)
                if let account = editingAccount {
                    name = account.name
                    selectedType = account.accountType
                    selectedColor = account.color
                    notes = account.notes ?? ""
                    initialBalance = String(describing: account.initialBalance)
                    originalInitialBalance = account.initialBalance.decimalValue
                    currentBalance = FinanceRepository.shared.getAccountBalance(account)
                    hasReconciliationAnchor = account.lastReconciledAt != nil
                    // 加载信用卡账单信息
                    billingDay = account.billingDayInt ?? 5
                    dueDay = account.dueDayInt ?? 25
                    dueReminderEnabled = account.dueReminderEnabled
                    dueReminderLeadDays = account.dueReminderLeadDaysInt
                    if let limit = account.creditLimitDecimal, limit > 0 {
                        creditLimit = String(describing: limit)
                    }
                } else {
                    selectedColor = selectedType.defaultColor
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账户名称")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            TextField("例如：招商银行储蓄卡", text: $name)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账户类型")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        typeButton(for: type)
                    }
                }
            }
        }
    }

    private func typeButton(for type: AccountType) -> some View {
        let isSelected = selectedType == type
        let tintColor = Color(hex: type.defaultColor)

        return Button {
            selectedType = type
            if !isEditMode {
                selectedColor = type.defaultColor
            }
        } label: {
            VStack(spacing: HoloSpacing.xs) {
                ZStack {
                    Circle()
                        .fill(isSelected ? tintColor.opacity(0.15) : Color.holoGlassBackground)
                        .frame(width: 44, height: 44)
                    Image(systemName: type.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? tintColor : .holoToolTextSecondary)
                }
                Text(type.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .holoToolText : .holoToolTextSecondary)
            }
            .padding(HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? tintColor.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? tintColor.opacity(0.3) : Color.holoToolBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Color

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("颜色")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.sm), count: 6), spacing: HoloSpacing.sm) {
                ForEach(colorPresets, id: \.self) { hex in
                    Button {
                        selectedColor = hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 36, height: 36)
                            if selectedColor == hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    // MARK: - Balance

    private var newInitialBalance: Decimal {
        Decimal(string: initialBalance) ?? 0
    }

    /// 编辑模式下期初是否被修改
    private var initialBalanceChanged: Bool {
        isEditMode && newInitialBalance != originalInitialBalance
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(isEditMode ? "期初余额" : "初始余额")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                Text("¥")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoToolText)

                TextField("0.00", text: $initialBalance)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
            }
            .padding(HoloSpacing.md)
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            if isEditMode {
                if initialBalanceChanged {
                    // 余额预览：当前余额 − 旧期初 + 新期初
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前余额 \(AccountCardFormat.prefixed(currentBalance))，保存后将变为 \(AccountCardFormat.prefixed(currentBalance - originalInitialBalance + newInitialBalance))")
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                        if hasReconciliationAnchor {
                            Text("此账户已对过账：修改期初会使对账基准失效，建议保存后再对一次账")
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolError)
                        }
                    }
                } else {
                    Text("期初余额是「账从某时刻开始记」时的余额；日常对账请在账户的「对账」中进行")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
            } else {
                Text("创建后可在「对账」中修改")
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("备注")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            TextField("可选", text: $notes)
                .font(.holoBody)
                .padding(HoloSpacing.md)
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    // MARK: - Credit Card Info

    /// 免费档名额判定：能否在这张卡上开还款提醒（会员短路 + onAppear 算好的名额快照）。
    /// 与排程器共用同一口径，勿在视图里另写计数。
    private var canEditBillingInfo: Bool {
        entitlementState.isPlusActive || freeQuotaAllows
    }

    /// 账单日/还款日可编辑：Plus 恒可编辑（2026-11-09 东林拍板解绑，只看账单也要能设日期）；
    /// 免费跟随提醒开关与名额（编辑权随提醒走，共 3 张）
    private var canEditDates: Bool {
        if entitlementState.isPlusActive { return true }
        return dueReminderEnabled && canEditBillingInfo
    }

    /// 提前量行属于提醒配置本身：提醒开着且名额内才出现
    private var showsLeadDaysRow: Bool {
        dueReminderEnabled && canEditBillingInfo
    }

    private var creditCardInfoSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("账单信息")
                .font(.holoLabel)
                .foregroundColor(.holoToolTextSecondary)

            VStack(spacing: 0) {
                // 还款提醒（区域的钥匙：前 3 张静默可用，免费开第 4 张拨动即弹付费墙并回弹）
                HStack {
                    Text("还款提醒")
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    Toggle("", isOn: $dueReminderEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .onChange(of: dueReminderEnabled) { _, enabled in
                            guard enabled else { return }
                            if !canEditBillingInfo {
                                // 免费名额已满：回弹并先说明场景，升级由用户在弹窗里主动选择
                                dueReminderEnabled = false
                                showDueQuotaAlert = true
                            } else {
                                CreditCardDueReminderScheduler.requestAuthorizationIfNeeded()
                            }
                        }
                }
                .padding(.vertical, HoloSpacing.sm)

                Divider()

                // 账单日（开启提醒后可编辑）
                HStack {
                    Text("账单日")
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    dayStepperControl(value: $billingDay, storedDay: editingAccount?.billingDayInt)
                }
                .padding(.vertical, HoloSpacing.sm)

                Divider()

                // 还款日（开启提醒后可编辑）
                HStack {
                    Text("还款日")
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    dayStepperControl(value: $dueDay, storedDay: editingAccount?.dueDayInt)
                }
                .padding(.vertical, HoloSpacing.sm)

                if showsLeadDaysRow {
                    Divider()

                    // 提前提醒量
                    HStack {
                        Text("提前提醒")
                            .font(.holoBody)
                            .foregroundColor(.holoToolText)
                        Spacer()
                        Menu {
                            Picker("提前提醒", selection: $dueReminderLeadDays) {
                                ForEach([0, 1, 2, 3, 5, 7], id: \.self) { days in
                                    Text(leadDaysText(days)).tag(days)
                                }
                            }
                        } label: {
                            HStack(spacing: HoloSpacing.xs) {
                                Text(leadDaysText(dueReminderLeadDays))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.holoToolTextSecondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.holoTextPlaceholder)
                            }
                        }
                    }
                    .padding(.vertical, HoloSpacing.sm)
                }

                Divider()

                // 额度（选填）
                HStack {
                    Text("额度（可选）")
                        .font(.holoBody)
                        .foregroundColor(.holoToolText)
                    Spacer()
                    Text("¥")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.holoToolText)
                    TextField("如 30000", text: $creditLimit)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        #if canImport(UIKit)
                        .keyboardType(.decimalPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                .padding(.vertical, HoloSpacing.sm)
            }
            .padding(.horizontal, HoloSpacing.md)
        }
    }

    /// 提前量选项文案（与 Picker tag 值一致）
    private func leadDaysText(_ days: Int) -> String {
        days == 0 ? String(localized: "当天") : String(localized: "提前 \(days) 天")
    }

    /// 统一账单日/还款日的操作区宽度，避免日期文字长度变化造成按钮错位。
    /// 不可编辑时只读展示已存的值；从没配过显示「未设置」，不拿默认值冒充。
    private func dayStepperControl(value: Binding<Int>, storedDay: Int?) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            if canEditDates {
                Stepper("每月 \(value.wrappedValue) 号", value: value, in: 1...31)
                    .labelsHidden()
                    .frame(width: 92, height: 36)
            }

            Text(canEditDates || storedDay != nil ? "每月 \(value.wrappedValue) 号" : "未设置")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .frame(width: 186, alignment: .trailing)
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // 改期初会使余额直接跳变，先确认再保存
        if initialBalanceChanged {
            showInitialBalanceConfirm = true
            return
        }
        performSave()
    }

    private func performSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let limitDecimal: Decimal? = creditLimit.isEmpty ? nil : Decimal(string: creditLimit)

        // D01（2026-10-04 体检）：持久化成功才算保存成功——失败保留输入、
        // 弹错不关页，不让用户以为存好了重启却找不到
        do {
            switch mode {
            case .create:
                let balance = Decimal(string: initialBalance) ?? 0
                // 日期落库条件：开了提醒 / Plus（编辑权解绑，所见即所存）/ 存量本就配过。
                // 免费未开提醒的卡不写默认账单日/还款日（修历史假默认值：详情页凭空显示假倒计时）
                let reminderOn = selectedType.isCreditCard && dueReminderEnabled
                let datesPersistable = selectedType.isCreditCard && (
                    reminderOn || entitlementState.isPlusActive || editingAccount?.billingDayInt != nil
                )
                let account = try FinanceRepository.shared.addAccount(
                    name: trimmedName,
                    type: selectedType,
                    color: selectedColor,
                    initialBalance: balance,
                    notes: notes.isEmpty ? nil : notes,
                    billingDay: datesPersistable ? billingDay : nil,
                    dueDay: datesPersistable ? dueDay : nil,
                    creditLimit: selectedType.isCreditCard ? limitDecimal : nil,
                    dueReminderEnabled: reminderOn,
                    dueReminderLeadDays: reminderOn ? dueReminderLeadDays : nil
                )
                onComplete(account)
                dismiss()

            case .edit(let account):
                // 日期落库条件同创建：关掉提醒时若日期本就没配过则传 nil = 维持未配置
                let reminderOn = selectedType.isCreditCard && dueReminderEnabled
                let datesPersistable = selectedType.isCreditCard && (
                    reminderOn || entitlementState.isPlusActive || editingAccount?.billingDayInt != nil
                )
                try FinanceRepository.shared.updateAccount(
                    account,
                    name: trimmedName,
                    color: selectedColor,
                    notes: notes.isEmpty ? nil : notes,
                    billingDay: datesPersistable ? billingDay : nil,
                    dueDay: datesPersistable ? dueDay : nil,
                    creditLimit: selectedType.isCreditCard ? limitDecimal : nil,
                    initialBalance: initialBalanceChanged
                        ? .some(.some(newInitialBalance))
                        : nil,
                    dueReminderEnabled: reminderOn,
                    dueReminderLeadDays: reminderOn ? dueReminderLeadDays : nil
                )
                onComplete(account)
                dismiss()
            }
        } catch {
            errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
            showError = true
        }
    }
}
