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
    let repository = FinanceRepository.shared

    /// 正在编辑的交易（nil 表示新增模式）
    let editingTransaction: Transaction?

    /// 预设日期（长按日历日期快速记账时传入，nil 表示使用当天）
    let presetDate: Date?

    /// 待确认交易预填数据（从待确认卡片进入编辑时使用）
    let pendingPrefill: PendingTransactionPrefill?

    /// 保存完成回调
    let onSave: () -> Void

    // MARK: - State

    /// 交易类型
    @State var transactionType: TransactionType = .expense

    /// 金额字符串
    @State var amountString: String = "0"

    /// 选中的分类
    @State var selectedCategory: Category?

    /// 备注（名称）
    @State var note: String = ""

    /// 备注（补充信息）
    @State var remark: String = ""

    /// 交易日期（编辑/新增时可修改）
    @State var selectedDate: Date = Date()

    /// 是否展开日期选择器
    @State var showDatePicker: Bool = false

    /// 是否正在保存
    @State var isSaving: Bool = false

    /// 是否显示删除确认
    @State var showDeleteConfirm: Bool = false

    /// 是否显示复制日期选择器
    @State var showCopyDatePicker: Bool = false

    /// 复制目标日期
    @State var copyTargetDate: Date = Date()

    /// 是否正在删除
    @State var isDeleting: Bool = false

    /// 光标闪烁动画
    @State var cursorOpacity: Double = 1.0

    /// 是否显示未保存修改确认弹窗
    @State var showDismissAlert: Bool = false

    /// 是否显示数字键盘（默认显示，新开页面时弹出）
    @State var showNumericKeypad: Bool = true

    /// 备注输入框是否获得焦点（用于控制键盘切换）
    @FocusState var isNoteFocused: Bool

    /// 选中的账户（nil 时使用默认账户）
    @State var selectedAccount: Account?

    /// 记住上次选择的账户
    @AppStorage("lastSelectedAccountId") var lastSelectedAccountId: String?

    /// 账户选择器是否展开
    @State var showAccountPicker: Bool = false

    /// 可用账户列表
    @State var accounts: [Account] = []

    /// 补充备注焦点（用于关闭数字键盘）
    @FocusState var isRemarkFocused: Bool

    // 分期设置
    @State var isInstallment: Bool = false
    @State var installmentPeriods: Int = 12
    @State var feePerPeriod: String = ""
    @State var showCustomPeriods: Bool = false
    @State var customPeriodsText: String = ""

    /// 分期设置弹窗
    @State var showInstallmentSheet: Bool = false

    /// 智能快捷标签数据
    @State var quickTags: [QuickTagItem] = []

    // 分类网格相关
    /// 所有分类数据
    @State var categories: [Category] = []
    /// 最近常用二级子分类
    @State var recentCategories: [Category] = []
    /// 当前下钻的一级分类（nil = 一级总览）
    @State var drillDownParent: Category?
    /// 是否显示分类管理页面
    @State var showCategoryManagement = false
    /// 是否显示快速新增分类弹窗
    @State var showAddCategory = false
    /// 快速新增分类的父级，nil 表示新增一级分类
    @State var addCategoryParentId: UUID?

    // 下拉保存相关
    /// 下拉偏移量
    @State var pullOffset: CGFloat = 0
    /// 是否正在执行下拉保存
    @State var isPullSaving: Bool = false

    /// 是否为编辑模式
    var isEditMode: Bool {
        editingTransaction != nil
    }

    /// 是否有未保存的修改
    var hasUnsavedChanges: Bool {
        if isEditMode {
            guard let transaction = editingTransaction else { return false }
            let originalAmount = String(describing: abs(transaction.amount.decimalValue))
            return amountString != originalAmount
                || selectedCategory != transaction.category
                || selectedAccount?.objectID != transaction.account?.objectID
                || note != (transaction.note ?? "")
                || !Calendar.current.isDate(selectedDate, inSameDayAs: transaction.date)
        } else {
            return amountString != "0" || selectedCategory != nil || !note.isEmpty
        }
    }

    /// 用于显示的金额字符串（取绝对值，去除开头的负号）
    var displayAmountString: String {
        if amountString.hasPrefix("-") {
            return String(amountString.dropFirst())
        }
        return amountString
    }

    /// 当前输入模式下的金额快捷标签
    var amountTags: [QuickTagItem] {
        quickTags.filter { $0.kind == .amount }
    }

    /// 当前输入模式下的名称快捷标签
    var noteTags: [QuickTagItem] {
        quickTags.filter { $0.kind == .note }
    }
    
    // MARK: - Initialization
    
    init(editingTransaction: Transaction?, presetDate: Date? = nil, pendingPrefill: PendingTransactionPrefill? = nil, onSave: @escaping () -> Void) {
        self.editingTransaction = editingTransaction
        self.presetDate = presetDate
        self.pendingPrefill = pendingPrefill
        self.onSave = onSave
    }

    /// 键盘布局（5行4列，支持四则运算）
    let keypadLayout: [[String]] = [
        ["÷", "×", "-", "+"],
        ["7", "8", "9", "⌫"],
        ["4", "5", "6", "AC"],
        ["1", "2", "3", "↩︎"],
        [".", "0", "00", "✓"]
    ]
    
    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. 顶部操作栏
                    topBar

                    // 2. 类型 Tab（支出/收入下划线样式）
                    typeTabBar

                    // 3. 中间滚动区（输入 + 分类 + 信息）
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            transactionEntryInputs
                                .padding(.horizontal, 16)

                            categoryGrid
                                .padding(.horizontal, 16)

                            infoInputArea
                                .padding(.horizontal, 16)

                            // 编辑模式下显示删除按钮
                            if isEditMode {
                                deleteButton
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showNumericKeypad = false
                            isNoteFocused = false
                            isRemarkFocused = false
                        }
                    }
                    .refreshable {
                        if canSave && !isSaving {
                            await MainActor.run {
                                calculateExpression()
                            }
                            await saveTransactionAsync()
                        }
                    }

                    // 4. 数字键盘托盘（快捷金额 + 键盘）
                    if showNumericKeypad {
                        numericKeypadTray
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if isNoteFocused {
                        QuickTagBar(
                            tags: noteTags,
                            onTagTap: handleQuickTagTap
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                // 弹窗覆盖层
                if showAccountPicker { accountPopup }
                if showDatePicker { datePopup }
                if showInstallmentSheet { installmentPopup }
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
            } else if let prefill = pendingPrefill {
                transactionType = prefill.type
                amountString = prefill.amount
                note = prefill.note ?? ""
                loadDefaultAccount()
                Task {
                    await loadCategories()
                    if let category = prefill.category {
                        selectedCategory = category
                    }
                }
            } else {
                loadDefaultAccount()
                if let preset = presetDate {
                    selectedDate = preset
                }
            }
            accounts = repository.getAccounts(includeArchived: false)
            loadQuickTags(for: selectedCategory)
            startCursorAnimation()
            Task { await loadCategories() }
        }
        .onChange(of: selectedCategory) { _, newValue in
            loadQuickTags(for: newValue)
        }
        .onChange(of: isNoteFocused) { _, newValue in
            if newValue {
                showNumericKeypad = false
            }
        }
        .onChange(of: isRemarkFocused) { _, newValue in
            if newValue {
                showNumericKeypad = false
            }
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
        .sheet(isPresented: $showCopyDatePicker) {
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
                            showCopyDatePicker = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            performCopyFromEditPage(targetDate: copyTargetDate)
                            showCopyDatePicker = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Top Bar

    /// 顶部操作栏（关闭 + 标题 + 保存）
    private var topBar: some View {
        ZStack {
            Text(isEditMode ? "编辑交易" : "记一笔")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            HStack {
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

                if isEditMode {
                    Button {
                        copyTargetDate = editingTransaction?.date ?? selectedDate
                        showCopyDatePicker = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 32, height: 32)
                            .background(Color.holoBackground)
                            .clipShape(Circle())
                    }
                }

                Button {
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
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
    }

    /// 顶部紧凑输入区（金额 + 名称）
    private var transactionEntryInputs: some View {
        HStack(spacing: 10) {
            amountInputField
                .frame(maxWidth: .infinity)

            noteInputField
                .frame(maxWidth: .infinity)
        }
    }

    /// 金额输入框（点击唤出数字键盘）
    private var amountInputField: some View {
        Button {
            showNumericKeypad = true
            isNoteFocused = false
            isRemarkFocused = false
        } label: {
            HStack(spacing: 6) {
                Text(amountString == "0" ? "金额" : "¥ \(displayAmountString)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(amountString == "0" ? .holoTextSecondary : .holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if showNumericKeypad {
                    Rectangle()
                        .fill(Color.holoPrimary)
                        .frame(width: 2, height: 20)
                        .opacity(cursorOpacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.holoCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(showNumericKeypad ? Color.holoPrimary.opacity(0.75) : Color.holoTextSecondary.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
    }

    /// 名称输入框
    private var noteInputField: some View {
        HStack(spacing: 6) {
            TextField("名称", text: $note)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .focused($isNoteFocused)
                .lineLimit(1)
                .onTapGesture {
                    showNumericKeypad = false
                    isRemarkFocused = false
                }
                .onSubmit {
                    isNoteFocused = false
                }

            if !note.isEmpty {
                Button {
                    note = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.holoCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(isNoteFocused ? Color.holoPrimary.opacity(0.75) : Color.holoTextSecondary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 数字键盘托盘：统一承载快捷标签栏和键盘圆角
    private var numericKeypadTray: some View {
        VStack(spacing: 0) {
            QuickTagBar(
                tags: amountTags,
                onTagTap: handleQuickTagTap
            )

            numericKeypad
        }
        .background(Color.transactionKeypadTrayBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: -4)
    }

    /// 是否可以保存
    var canSave: Bool {
        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0" else {
            return false
        }
        return selectedCategory?.isSubCategory == true
    }

    /// 删除按钮
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
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }
}

// MARK: - Preview

#Preview {
    AddTransactionSheet(editingTransaction: nil) {}
}

// MARK: - Pending Transaction Prefill

struct PendingTransactionPrefill {
    let amount: String
    let note: String?
    let type: TransactionType
    let category: Category?
}
