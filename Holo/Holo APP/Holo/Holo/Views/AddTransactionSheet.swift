//
//  AddTransactionSheet.swift
//  Holo
//
//  添加/编辑交易弹窗 - 底部弹出的 Sheet 样式
//  包含金额输入、分类选择、数字键盘
//

import SwiftUI
import CoreData

/// 添加/编辑交易 Sheet
struct AddTransactionSheet: View {
    
    // MARK: - Properties
    
    /// 环境变量
    @Environment(\.dismiss) var dismiss
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    /// 正在编辑的交易（nil 表示新增模式）
    let editingTransaction: Transaction?
    
    /// 预设日期（长按日历日期快速记账时传入，nil 表示使用当天）
    let presetDate: Date?
    
    /// 保存完成回调
    let onSave: () -> Void
    
    // MARK: - State
    
    /// 交易类型
    @State private var transactionType: TransactionType = .expense
    
    /// 金额字符串
    @State private var amountString: String = "0"
    
    /// 选中的分类
    @State private var selectedCategory: Category?
    
    /// 备注（名称）
    @State private var note: String = ""

    /// 备注（补充信息）
    @State private var remark: String = ""
    
    /// 交易日期（编辑/新增时可修改）
    @State private var selectedDate: Date = Date()
    
    /// 是否展开日期选择器
    @State private var showDatePicker: Bool = false
    
    /// 是否正在保存
    @State private var isSaving: Bool = false
    
    /// 是否显示删除确认
    @State private var showDeleteConfirm: Bool = false
    
    /// 是否正在删除
    @State private var isDeleting: Bool = false
    
    /// 光标闪烁动画
    @State private var cursorOpacity: Double = 1.0

    /// 是否显示未保存修改确认弹窗
    @State private var showDismissAlert: Bool = false

    /// 是否显示数字键盘（默认显示，新开页面时弹出）
    @State private var showNumericKeypad: Bool = true
    
    /// 备注输入框是否获得焦点（用于控制键盘切换）
    @FocusState private var isNoteFocused: Bool

    /// 选中的账户（nil 时使用默认账户）
    @State private var selectedAccount: Account?

    /// 记住上次选择的账户
    @AppStorage("lastSelectedAccountId") private var lastSelectedAccountId: String?

    /// 账户选择器是否展开
    @State private var showAccountPicker: Bool = false

    // 分期设置
    @State private var isInstallment: Bool = false
    @State private var installmentPeriods: Int = 12
    @State private var feePerPeriod: String = ""
    @State private var showCustomPeriods: Bool = false
    @State private var customPeriodsText: String = ""

    // 下拉保存相关
    /// 下拉偏移量
    @State private var pullOffset: CGFloat = 0
    /// 是否正在执行下拉保存
    @State private var isPullSaving: Bool = false
    
    /// 是否为编辑模式
    private var isEditMode: Bool {
        editingTransaction != nil
    }

    /// 是否有未保存的修改
    private var hasUnsavedChanges: Bool {
        if isEditMode {
            // 编辑模式：比较与原始交易的差异
            guard let transaction = editingTransaction else { return false }
            let originalAmount = String(describing: abs(transaction.amount.decimalValue))
            return amountString != originalAmount
                || selectedCategory != transaction.category
                || selectedAccount?.objectID != transaction.account.objectID
                || note != (transaction.note ?? "")
                || !Calendar.current.isDate(selectedDate, inSameDayAs: transaction.date)
        } else {
            // 新增模式：检查是否输入了内容
            return amountString != "0" || selectedCategory != nil || !note.isEmpty
        }
    }
    
    /// 用于显示的金额字符串（取绝对值，去除开头的负号）
    /// 无论收入还是支出，前端显示都不带正负号
    /// 注意：不减号作为运算符时保留，只移除结果前的负号
    private var displayAmountString: String {
        // 如果字符串以 "-" 开头（表示负数结果），移除开头的负号
        if amountString.hasPrefix("-") {
            return String(amountString.dropFirst())
        }
        return amountString
    }
    
    // MARK: - Initialization
    
    init(editingTransaction: Transaction?, presetDate: Date? = nil, onSave: @escaping () -> Void) {
        self.editingTransaction = editingTransaction
        self.presetDate = presetDate
        self.onSave = onSave
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 拖动指示条
                    dragIndicator
                    
                    // 顶部区域：关闭按钮 + 标题
                    headerSection
                    
                    // 金额显示区域
                    amountSection
                    
                    // 滚动区域：分类 + 备注
                    ScrollView {
                        VStack(spacing: HoloSpacing.lg) {
                            // 分类选择（CategoryPicker 自带内边距）
                            categorySection

                            // 账户选择
                            accountSection
                                .padding(.horizontal, HoloSpacing.lg)

                            // 名称输入
                            noteSection
                                .padding(.horizontal, HoloSpacing.lg)

                            // 备注输入
                            remarkSection
                                .padding(.horizontal, HoloSpacing.lg)

                            // 日期选择
                            dateSection
                                .padding(.horizontal, HoloSpacing.lg)

                            // 分期设置（仅新增模式）
                            if !isEditMode {
                                installmentSection
                                    .padding(.horizontal, HoloSpacing.lg)
                            }
                        }
                        // 使用 contentShape 定义整个区域可点击
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 点击滚动区域空白处：收起数字键盘
                            showNumericKeypad = false
                            isNoteFocused = false
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .refreshable {
                        // 下拉保存记账
                        if canSave && !isSaving {
                            await MainActor.run {
                                calculateExpression()
                            }
                            await saveTransactionAsync()
                        }
                    }
                    
                    // 数字键盘（仅在显示时渲染）
                    if showNumericKeypad {
                        numericKeypad
                    }
                    
                    // 编辑模式下显示删除按钮
                    if isEditMode {
                        deleteButton
                    }
                }
            }
            .navigationBarHidden(true)
            .confirmationDialog("确认删除", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除这笔交易", role: .destructive) {
                    deleteTransaction()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复，确定要删除吗？")
            }
            .swipeBackToDismiss {
                if hasUnsavedChanges {
                    showDismissAlert = true
                } else {
                    dismiss()
                }
            }
        }
        .onAppear {
            if let transaction = editingTransaction {
                populateFromTransaction(transaction)
            } else {
                // 新增模式：加载默认/上次选择的账户
                loadDefaultAccount()
                if let preset = presetDate {
                    // 长按日历日期进入：使用预设日期
                    selectedDate = preset
                }
            }
            startCursorAnimation()
        }
        .onChange(of: selectedCategory) { _, newValue in
            // 选择分类后，收起数字键盘
            if newValue != nil {
                showNumericKeypad = false
            }
        }
        .onChange(of: isNoteFocused) { _, newValue in
            // 备注输入框获得焦点时，隐藏数字键盘（让系统键盘显示）
            if newValue {
                showNumericKeypad = false
            }
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
    }
    
    // MARK: - Delete Button
    
    /// 删除按钮（仅在编辑模式显示）
    private var deleteButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("删除交易")
                .font(.holoBody)
                .foregroundColor(.holoError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoCardBackground)
        }
    }
    
    // MARK: - Drag Indicator
    
    /// 拖动指示条
    private var dragIndicator: some View {
        Capsule()
            .fill(Color.holoTextSecondary.opacity(0.3))
            .frame(width: 36, height: 5)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }
    
    // MARK: - Header Section

    /// 顶部区域
    private var headerSection: some View {
        HStack {
            // 关闭按钮（取消，不保存）
            Button {
                if hasUnsavedChanges {
                    showDismissAlert = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoBackground)
                    .clipShape(Circle())
            }

            Spacer()

            // 标题（类型切换已移至 CategoryPicker 内部）
            Text(isEditMode ? "编辑交易" : "记一笔")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 保存按钮（✓）
            Button {
                // 先计算表达式（如果有），然后保存
                calculateExpression()
                saveTransaction()
            } label: {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(width: 32, height: 32)
                        .background(canSave ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3))
                        .clipShape(Circle())
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(canSave ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .disabled(!canSave || isSaving)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
    }

    /// 是否可以保存（金额 > 0 且已选择分类）
    private var canSave: Bool {
        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0" else {
            return false
        }
        return selectedCategory != nil
    }
    
    // MARK: - Amount Section
    
    /// 金额显示区域（含分类图标）
    private var amountSection: some View {
        VStack(spacing: HoloSpacing.xs) {
            // 分类图标 + 名称（动态展示当前选中分类）
            if let category = selectedCategory {
                HStack(spacing: HoloSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(category.swiftUIColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                        transactionCategoryIcon(category, size: 20)
                    }
                    Text(category.name)
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: selectedCategory?.id)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.holoTextSecondary)
                
                HStack(spacing: 0) {
                    // 金额显示（取绝对值，不显示正负号）
                    Text(displayAmountString)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    
                    // 光标
                    Rectangle()
                        .fill(Color.holoPrimary)
                        .frame(width: 2, height: 36)
                        .opacity(cursorOpacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .onTapGesture {
            // 点击金额区域时：收起备注输入焦点（系统键盘），显示数字键盘
            isNoteFocused = false
            showNumericKeypad = true
        }
    }
    
    // MARK: - Category Section

    /// 分类选择区域 — 使用 CategoryPicker 组件，支持一级→二级下钻
    private var categorySection: some View {
        CategoryPicker(
            selectedCategory: $selectedCategory,
            transactionType: $transactionType
        )
    }

    // MARK: - Account Section

    /// 账户选择区域
    private var accountSection: some View {
        VStack(spacing: 0) {
            // 账户选择按钮
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAccountPicker.toggle()
                    if showAccountPicker {
                        showNumericKeypad = false
                        isNoteFocused = false
                    }
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: selectedAccount?.icon ?? "wallet.pass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(selectedAccount?.swiftUIColor ?? .holoTextSecondary)

                    Text(selectedAccount?.name ?? "默认账户")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Image(systemName: showAccountPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())

            // 展开的账户选择列表
            if showAccountPicker {
                let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
                VStack(spacing: HoloSpacing.xs) {
                    ForEach(accounts, id: \.objectID) { account in
                        Button {
                            selectedAccount = account
                            lastSelectedAccountId = account.id.uuidString
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showAccountPicker = false
                            }
                        } label: {
                            HStack(spacing: HoloSpacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(account.swiftUIColor.opacity(0.1))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: account.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(account.swiftUIColor)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                        .font(.holoBody)
                                        .foregroundColor(
                                            selectedAccount?.objectID == account.objectID
                                                ? .holoPrimary : .holoTextPrimary
                                        )
                                    Text(account.accountType.displayName)
                                        .font(.holoCaption)
                                        .foregroundColor(.holoTextSecondary)
                                }

                                Spacer()

                                if selectedAccount?.objectID == account.objectID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                            .padding(HoloSpacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.sm)
                                    .fill(
                                        selectedAccount?.objectID == account.objectID
                                            ? Color.holoPrimary.opacity(0.05) : Color.clear
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(HoloSpacing.sm)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    // MARK: - Date Section
    
    /// 日期选择区域 — 点击展开/收起日期选择器
    private var dateSection: some View {
        VStack(spacing: 0) {
            // 日期显示行
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showDatePicker.toggle()
                    // 展开日期选择器时隐藏数字键盘、收起备注焦点
                    if showDatePicker {
                        showNumericKeypad = false
                        isNoteFocused = false
                    }
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    
                    Text(formattedSelectedDate)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    
                    Spacer()
                    
                    Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            
            // 展开的日期选择器
            if showDatePicker {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.top, HoloSpacing.sm)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    /// 格式化的日期显示文字（X月X日 周X）
    private var formattedSelectedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        let text = f.string(from: selectedDate)
        if selectedDate.isToday { return "\(text)（今天）" }
        return text
    }
    
    // MARK: - Note Section

    /// 名称输入区域
    private var noteSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            TextField("添加名称...", text: $note)
                .font(.holoBody)
                .foregroundColor(.primary)
                .focused($isNoteFocused)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Remark Section

    /// 备注输入区域
    private var remarkSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            TextField("添加备注（选填）...", text: $remark)
                .font(.holoBody)
                .foregroundColor(.primary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
    
    // MARK: - Installment Section

    /// 分期设置区域
    private var installmentSection: some View {
        VStack(spacing: 0) {
            // 分期开关
            HStack {
                Image(systemName: "repeat")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("分期付款")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: $isInstallment)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }
            .padding(HoloSpacing.md)

            // 展开后显示详细设置
            if isInstallment {
                VStack(spacing: HoloSpacing.md) {
                    Divider()

                    // 期数快捷选择
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("期数")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: HoloSpacing.sm) {
                            ForEach([3, 6, 12, 24], id: \.self) { period in
                                Button {
                                    installmentPeriods = period
                                    showCustomPeriods = false
                                } label: {
                                    Text("\(period)期")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(
                                            !showCustomPeriods && installmentPeriods == period
                                                ? .white : .holoTextPrimary
                                        )
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            !showCustomPeriods && installmentPeriods == period
                                                ? Color.holoPrimary
                                                : Color.holoBackground
                                        )
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }

                            // 自定义按钮
                            Button {
                                showCustomPeriods = true
                            } label: {
                                if showCustomPeriods {
                                    HStack(spacing: 2) {
                                        TextField("", text: $customPeriodsText)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.white)
                                            .keyboardType(.numberPad)
                                            .frame(width: 30)
                                            .multilineTextAlignment(.center)
                                            .onChange(of: customPeriodsText) { _, newValue in
                                                if let val = Int(newValue), val > 0 {
                                                    installmentPeriods = val
                                                }
                                            }
                                        Text("期")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.holoPrimary)
                                    .clipShape(Capsule())
                                } else {
                                    Text("自定义")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.holoTextSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.holoBackground)
                                        .clipShape(Capsule())
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    // 每期手续费
                    HStack(spacing: HoloSpacing.sm) {
                        Text("手续费")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: 4) {
                            Text("¥")
                                .font(.holoBody)
                                .foregroundColor(.holoTextSecondary)
                            TextField("0.00", text: $feePerPeriod)
                                .font(.holoBody)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.holoBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

                        Text("/每期")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        Spacer()
                    }

                    Divider()

                    // 实时计算预览
                    installmentPreview
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.md)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// 分期预览信息
    private var installmentPreview: some View {
        let totalAmount = Decimal(string: displayAmountString) ?? 0
        let fee = Decimal(string: feePerPeriod) ?? 0
        let periods = max(installmentPeriods, 1)
        let perPeriod = totalAmount / Decimal(periods) + fee
        let totalFee = fee * Decimal(periods)
        let totalCost = totalAmount + totalFee

        return VStack(spacing: HoloSpacing.xs) {
            installmentPreviewRow(label: "每期金额", value: formatPreviewAmount(perPeriod))
            installmentPreviewRow(label: "总手续费", value: formatPreviewAmount(totalFee))
            installmentPreviewRow(label: "实际总支出", value: formatPreviewAmount(totalCost))
        }
    }

    private func installmentPreviewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
        }
    }

    private func formatPreviewAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter.currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "¥0.00"
    }

    // MARK: - Numeric Keypad
    
    /// 数字键盘
    private var numericKeypad: some View {
        VStack(spacing: 4) {
            ForEach(keypadLayout, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        KeypadButton(key: key) {
                            handleKeypadPress(key)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.holoCardBackground)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: -4)
    }
    
    /// 键盘布局（5行4列，支持四则运算）
    /// 设计说明：顶行运算符，中间数字，右侧功能键，底部确认
    /// ÷×-+=四则运算, ⌫=删除, AC=清空, ↩︎=预留(置灰), 00=双零, ✓=保存
    private let keypadLayout: [[String]] = [
        ["÷", "×", "-", "+"],
        ["7", "8", "9", "⌫"],
        ["4", "5", "6", "AC"],
        ["1", "2", "3", "↩︎"],
        [".", "0", "00", "✓"]
    ]
    
    // MARK: - Methods
    
    /// 从交易填充数据（编辑模式）
    private func populateFromTransaction(_ transaction: Transaction) {
        transactionType = transaction.transactionType
        let absoluteAmount = abs(transaction.amount.decimalValue)
        amountString = String(describing: absoluteAmount)
        selectedCategory = transaction.category
        selectedAccount = transaction.account
        note = transaction.note ?? ""
        remark = transaction.remark ?? ""
        selectedDate = transaction.date
    }

    /// 加载默认/上次选择的账户（新增模式）
    private func loadDefaultAccount() {
        // 优先恢复上次选择
        if let lastId = lastSelectedAccountId,
           let uuid = UUID(uuidString: lastId) {
            let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
            if let matched = accounts.first(where: { $0.id == uuid }) {
                selectedAccount = matched
                return
            }
        }
        // 回退到默认账户
        selectedAccount = FinanceRepository.shared.getDefaultAccountSync()
    }
    
    /// 启动光标闪烁动画
    private func startCursorAnimation() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            cursorOpacity = 0
        }
    }
    
    /// 处理键盘按键
    private func handleKeypadPress(_ key: String) {
        switch key {
        case "AC":
            // 清空金额
            amountString = "0"
            
        case "⌫":
            // 删除最后一个字符
            if amountString.count > 1 {
                amountString.removeLast()
            } else {
                amountString = "0"
            }
            
        case "✓":
            // 确认保存（如果当前是表达式，先计算结果）
            calculateExpression()
            saveTransaction()
            
        case "+", "-", "×", "÷":
            // 四则运算符：追加到表达式末尾
            handleOperator(key)
            
        case "↩︎":
            // 跳转到下一个可输入区域（备注输入框）
            showNumericKeypad = false
            isNoteFocused = true
            
        case ".":
            // 小数点：确保当前数字段没有小数点
            handleDecimalPoint()
            
        case "00":
            // 双零输入
            handleDigit("0")
            handleDigit("0")
            
        default:
            // 数字输入
            handleDigit(key)
        }
    }
    
    // MARK: - 计算逻辑辅助方法
    
    /// 处理运算符输入
    private func handleOperator(_ op: String) {
        // 如果当前是 "0"，不能直接加运算符
        if amountString == "0" {
            return
        }
        
        // 获取最后一个字符
        let lastChar = amountString.last
        
        // 如果最后一个字符已经是运算符，替换为新运算符
        if ["+", "-", "×", "÷"].contains(lastChar) {
            amountString.removeLast()
        }
        
        // 追加运算符
        amountString += op
    }
    
    /// 处理小数点输入
    private func handleDecimalPoint() {
        // 找到当前正在输入的数字段（最后一个运算符之后的部分）
        let operators = ["+", "-", "×", "÷"]
        if let lastOperatorIndex = amountString.lastIndex(where: { operators.contains(String($0)) }) {
            // 存在运算符，检查最后一个数字段
            let startIndex = amountString.index(after: lastOperatorIndex)
            let lastNumberPart = String(amountString[startIndex...])
            if lastNumberPart.contains(".") {
                return  // 当前数字段已有小数点
            }
        } else {
            // 没有运算符，检查整个字符串
            if amountString.contains(".") {
                return
            }
        }
        
        // 追加小数点
        amountString += "."
    }
    
    /// 处理数字输入
    private func handleDigit(_ digit: String) {
        // 如果当前是 "0" 且没有运算符，替换为输入的数字
        if amountString == "0" {
            amountString = digit
            return
        }
        
        // 检查当前数字段的小数位数限制
        let operators = ["+", "-", "×", "÷"]
        var currentNumberPart = amountString
        
        if let lastOperatorIndex = amountString.lastIndex(where: { operators.contains(String($0)) }) {
            let startIndex = amountString.index(after: lastOperatorIndex)
            currentNumberPart = String(amountString[startIndex...])
        }
        
        // 限制小数位数为2位
        if let dotIndex = currentNumberPart.firstIndex(of: ".") {
            let decimalPart = currentNumberPart[currentNumberPart.index(after: dotIndex)...]
            if decimalPart.count >= 2 {
                return
            }
        }
        
        // 追加数字
        amountString += digit
    }
    
    /// 计算表达式结果
    /// 支持四则运算：+、-、×、÷，遵循运算优先级（先乘除后加减）
    private func calculateExpression() {
        // 如果不包含运算符，直接返回
        let operators = ["×", "÷", "+", "-"]
        var hasOperator = false
        for op in operators {
            if amountString.contains(op) {
                hasOperator = true
                break
            }
        }
        
        if !hasOperator {
            return
        }
        
        // 将表达式转换为可计算的格式
        var expression = amountString
        expression = expression.replacingOccurrences(of: "×", with: "*")
        expression = expression.replacingOccurrences(of: "÷", with: "/")
        
        // 使用 Double 进行精确的浮点数计算
        // 先解析表达式，然后按运算优先级计算
        if let result = evaluateExpression(expression) {
            // 格式化结果：保留最多2位小数
            let formatted = formatAmount(Decimal(result))
            amountString = formatted
        } else {
            print("表达式计算失败: \(expression)")
        }
    }
    
    /// 解析并计算表达式（支持四则运算，遵循优先级）
    /// - Parameter expression: 表达式字符串（如 "23/32" 或 "10+5*2"）
    /// - Returns: 计算结果，失败返回 nil
    private func evaluateExpression(_ expression: String) -> Double? {
        // 将表达式拆分为数字和运算符
        var tokens: [String] = []
        var currentToken = ""
        
        for char in expression {
            if "+-*/".contains(char) {
                if !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
                tokens.append(String(char))
            } else {
                currentToken.append(char)
            }
        }
        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }
        
        // 如果没有有效的 token，返回 nil
        if tokens.isEmpty {
            return nil
        }
        
        // 第一遍：处理乘除
        var processedTokens = tokens
        var i = 0
        while i < processedTokens.count {
            let token = processedTokens[i]
            if token == "*" || token == "/" {
                // 获取左右操作数
                guard i > 0, i < processedTokens.count - 1 else { return nil }
                guard let left = Double(processedTokens[i - 1]),
                      let right = Double(processedTokens[i + 1]) else { return nil }
                
                // 计算结果
                let result: Double
                if token == "*" {
                    result = left * right
                } else {
                    guard right != 0 else { return nil } // 防止除以零
                    result = left / right
                }
                
                // 替换三个 token 为计算结果
                processedTokens.replaceSubrange(i - 1...i + 1, with: [String(result)])
                // 不增加 i，因为当前索引现在是下一个待处理的 token
            } else {
                i += 1
            }
        }
        
        // 第二遍：处理加减
        var finalResult = Double(processedTokens[0]) ?? 0
        i = 1
        while i < processedTokens.count {
            let token = processedTokens[i]
            if token == "+" || token == "-" {
                guard i < processedTokens.count - 1 else { break }
                guard let right = Double(processedTokens[i + 1]) else { break }
                
                if token == "+" {
                    finalResult += right
                } else {
                    finalResult -= right
                }
                i += 2
            } else {
                i += 1
            }
        }
        
        return finalResult
    }
    
    /// 格式化金额：保留最多2位小数，去除尾部多余的0
    private func formatAmount(_ amount: Decimal) -> String {
        // 四舍五入到2位小数
        let rounded = (amount as NSDecimalNumber).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 2, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        
        // 转换为字符串
        var result = rounded.stringValue
        
        // 去除尾部多余的0（如 "12.50" -> "12.5"，"12.00" -> "12"）
        if result.contains(".") {
            while result.last == "0" {
                result.removeLast()
            }
            if result.last == "." {
                result.removeLast()
            }
        }
        
        return result
    }
    
    /// 保存交易
    private func saveTransaction() {
        // 保存前先计算表达式（如果有）
        calculateExpression()
        
        // 获取金额（取绝对值，因为类型由 transactionType 决定）
        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0" else {
            // 金额无效，不保存
            return
        }
        
        guard let category = selectedCategory else {
            // 未选择分类
            return
        }
        
        isSaving = true

        Task {
            do {
                // 使用选中的账户，回退到默认账户
                let account: Account
                if let selected = selectedAccount {
                    account = selected
                } else if let defaultAcc = try await repository.getDefaultAccount() {
                    account = defaultAcc
                } else {
                    isSaving = false
                    return
                }

                if let transaction = editingTransaction {
                    // 编辑模式：更新交易（含日期和账户变更）
                    var updates = TransactionUpdates()
                    updates.amount = amount
                    updates.category = category
                    updates.account = account
                    updates.note = note.isEmpty ? nil : note
                    updates.remark = remark.isEmpty ? nil : remark
                    updates.date = selectedDate

                    try await repository.updateTransaction(transaction, updates: updates)
                } else if isInstallment {
                    // 分期模式：一次创建多笔交易
                    let fee = Decimal(string: feePerPeriod) ?? 0
                    _ = try await repository.addInstallmentTransactions(
                        totalAmount: amount,
                        feePerPeriod: fee,
                        periods: installmentPeriods,
                        type: transactionType,
                        category: category,
                        account: account,
                        startDate: selectedDate,
                        note: note.isEmpty ? nil : note,
                        remark: remark.isEmpty ? nil : remark
                    )
                } else {
                    // 新增模式：使用 selectedDate（默认今天，长按日历时为指定日期）
                    _ = try await repository.addTransaction(
                        amount: amount,
                        type: transactionType,
                        category: category,
                        account: account,
                        date: selectedDate,
                        note: note.isEmpty ? nil : note,
                        remark: remark.isEmpty ? nil : remark,
                        tags: nil
                    )
                }
                
                // 保存成功，调用回调
                HapticManager.success()
                onSave()
                dismiss()

            } catch {
                print("保存失败：\(error.localizedDescription)")
            }
            
            isSaving = false
        }
    }

    /// 异步保存交易（用于下拉刷新）
    private func saveTransactionAsync() async {
        // 获取金额（取绝对值，因为类型由 transactionType 决定）
        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0" else {
            return
        }

        guard let category = selectedCategory else {
            return
        }

        await MainActor.run {
            isSaving = true
        }

        do {
            // 使用选中的账户，回退到默认账户
            let account: Account
            if let selected = selectedAccount {
                account = selected
            } else if let defaultAcc = try await repository.getDefaultAccount() {
                account = defaultAcc
            } else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }

            if let transaction = editingTransaction {
                // 编辑模式：更新交易
                var updates = TransactionUpdates()
                updates.amount = amount
                updates.category = category
                updates.account = account
                updates.note = note.isEmpty ? nil : note
                updates.remark = remark.isEmpty ? nil : remark
                updates.date = selectedDate

                try await repository.updateTransaction(transaction, updates: updates)
            } else if isInstallment {
                // 分期模式
                let fee = Decimal(string: feePerPeriod) ?? 0
                _ = try await repository.addInstallmentTransactions(
                    totalAmount: amount,
                    feePerPeriod: fee,
                    periods: installmentPeriods,
                    type: transactionType,
                    category: category,
                    account: account,
                    startDate: selectedDate,
                    note: note.isEmpty ? nil : note,
                    remark: remark.isEmpty ? nil : remark
                )
            } else {
                // 新增模式
                _ = try await repository.addTransaction(
                    amount: amount,
                    type: transactionType,
                    category: category,
                    account: account,
                    date: selectedDate,
                    note: note.isEmpty ? nil : note,
                    remark: remark.isEmpty ? nil : remark,
                    tags: nil
                )
            }

            // 保存成功
            await MainActor.run {
                HapticManager.success()
                onSave()
                dismiss()
            }

        } catch {
            print("保存失败：\(error.localizedDescription)")
        }

        await MainActor.run {
            isSaving = false
        }
    }
    
    /// 删除交易（仅编辑模式）
    private func deleteTransaction() {
        guard let transaction = editingTransaction else { return }
        
        isDeleting = true
        
        Task {
            do {
                try await repository.deleteTransaction(transaction)
                onSave()
                dismiss()
            } catch {
                print("删除失败：\(error.localizedDescription)")
            }
            isDeleting = false
        }
    }
}

// MARK: - Keypad Button

/// 键盘按钮
struct KeypadButton: View {
    let key: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Group {
                switch key {
                case "AC":
                    Text("AC")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.holoError)
                    
                case "⌫":
                    Image(systemName: "delete.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    
                case "✓":
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                case "+", "-", "×", "÷":
                    // 四则运算符
                    Text(key)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    
                case "↩︎":
                    // 跳转到下一个输入区域
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    
                case "00":
                    // 双零按钮
                    Text("00")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                    
                default:
                    Text(key)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(buttonBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    /// 根据按键类型返回背景颜色
    private var buttonBackgroundColor: Color {
        switch key {
        case "✓":
            return Color.holoPrimary
        case "÷", "×", "-", "+", "⌫", "AC", "↩︎":
            return Color.holoBackground
        default:
            return Color.holoCardBackground
        }
    }
}

// MARK: - Preview

#Preview {
    AddTransactionSheet(editingTransaction: nil) {}
}
