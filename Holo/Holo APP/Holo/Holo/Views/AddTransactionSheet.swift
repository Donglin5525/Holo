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

    /// 预设挂靠的财务项目（从项目详情「记一笔」进入时使用，nil 表示按上次记忆）
    let presetFinanceProject: FinanceProject?

    /// 保存完成回调（传入本次创建/编辑后的交易，nil 表示删除或多笔分期等场景）
    let onSave: (Transaction?) -> Void

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

    /// 保存被拦截时的抖动触发器（递增值驱动一次抖动动画）
    @State var saveBlockShake: Int = 0

    /// 是否显示删除确认
    @State var showDeleteConfirm: Bool = false

    /// 是否显示复制日期选择器
    @State var showCopyDatePicker: Bool = false

    /// 复制目标日期
    @State var copyTargetDate: Date = Date()

    /// 是否正在删除
    @State var isDeleting: Bool = false


    /// 是否显示未保存修改确认弹窗
    @State var showDismissAlert: Bool = false

    /// 是否显示数字键盘（默认显示，新开页面时弹出；UITest 直通模式可不弹以排除键盘遮挡变量）
    @State var showNumericKeypad: Bool = !ProcessInfo.processInfo.arguments.contains("UITEST_NO_KEYPAD")

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

    /// 选中的财务项目（nil=不挂项目；仅支出类型可选）
    @State var selectedProject: FinanceProject?

    /// 项目选择器是否展开
    @State var showProjectPicker: Bool = false

    /// 进行中的项目清单（选择器选项）
    @State var financeProjects: [FinanceProject] = []

    /// 记住上次挂靠的项目（完结的项目自动失效回落「不挂」）
    @AppStorage("lastSelectedFinanceProjectId") var lastSelectedFinanceProjectId: String?

    /// 补充备注焦点（用于关闭数字键盘）
    @FocusState var isRemarkFocused: Bool

    // 票根（照片附件）
    /// 新建模式待贴票根（保存交易时统一落库）
    @State var pendingReceipts: [PendingReceipt] = []
    /// 票根显示项（已落库 + 待贴合成，缩略图异步回填）
    @State var receiptItems: [ReceiptDisplayItem] = []
    /// 选图来源覆盖弹窗（拍照/从相册）
    @State var showReceiptSourcePicker = false
    /// 系统相册 picker
    @State var showReceiptPhotoPicker = false
    /// 相机全屏页
    @State var showReceiptCamera = false
    /// 相机权限拒绝提示
    @State var showReceiptPermissionAlert = false
    @State var receiptPermissionMessage = ""
    /// 全屏查看
    @State var showReceiptGallery = false
    @State var receiptGalleryStart = 0

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
                || note != (InstallmentNoteSanitizer.clean(transaction.note) ?? "")
                || !Calendar.current.isDate(selectedDate, inSameDayAs: transaction.date)
                || selectedProject?.id != transaction.financeProjectId
        } else {
            return amountString != "0" || selectedCategory != nil || !note.isEmpty || !pendingReceipts.isEmpty
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
    
    init(editingTransaction: Transaction?, presetDate: Date? = nil, pendingPrefill: PendingTransactionPrefill? = nil, presetFinanceProject: FinanceProject? = nil, onSave: @escaping (Transaction?) -> Void) {
        self.editingTransaction = editingTransaction
        self.presetDate = presetDate
        self.pendingPrefill = pendingPrefill
        self.presetFinanceProject = presetFinanceProject
        self.onSave = onSave
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoToolBackground.ignoresSafeArea()
                    // 票根选图服务（系统相册/相机页；来源选择走 receiptSourcePopup）
                    .receiptImagePickerServices(
                        showPhotoPicker: $showReceiptPhotoPicker,
                        showCamera: $showReceiptCamera,
                        remainingSlots: Transaction.maxReceiptCount - receiptItems.count,
                        onSelect: handleReceiptSelected
                    )

                VStack(spacing: 0) {
                    // 1. 顶部操作栏
                    topBar

                    // 2. 类型 Tab（支出/收入下划线样式）
                    typeTabBar

                    // 3. 固定输入区：浏览和选择科目时始终保留金额与名称
                    transactionEntryInputs
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .modifier(ShakeEffect(animatableData: CGFloat(saveBlockShake)))

                    // 4. 中间滚动区（分类 + 信息）
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            categoryGrid
                                .padding(.horizontal, 16)

                            // 票根区：有票才出现（打印机出票舞台；空态唯一入口在信息卡「票根」行）
                            if !receiptItems.isEmpty {
                                receiptSlotSection
                                    .padding(.horizontal, 16)
                            }

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

                    // 5. 数字键盘托盘（快捷金额 + 键盘）
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
                if showProjectPicker { projectPopup }
                if showReceiptSourcePicker { receiptSourcePopup }
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
                if let date = prefill.date {
                    selectedDate = date
                }
                loadDefaultAccount()
                Task {
                    await loadCategories()
                    if let category = prefill.category {
                        selectedCategory = category
                    }
                }
            } else {
                loadDefaultAccount()
                loadDefaultProject()
                if let preset = presetDate {
                    selectedDate = preset
                }
            }
            accounts = repository.getAccounts(includeArchived: false)
            financeProjects = FinanceProjectRepository.shared.activeProjects()
            loadQuickTags(for: selectedCategory)
            reloadReceiptItems()
            Task { await loadCategories() }

            // UITest 专用直通：绕过 sheet 内信息行（模拟器合成触摸点不动，HEAD 对照实证为环境限制），
            // 直接打开系统相册 picker 验证「选图→落库→出票」链路
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UITEST_AUTO_OPEN_RECEIPT_PICKER") {
                showReceiptPhotoPicker = true
            }
            #endif
        }
        .onChange(of: selectedCategory) { _, newValue in
            loadQuickTags(for: newValue)
        }
        .onChange(of: transactionType) { _, newValue in
            // 挂靠记忆只在支出域生效（防「上次项目」误挂到收入——2026-10 bug 根源）：
            // 新增流程切收入清掉预选值；编辑流程切型保留（正在编辑的这笔归属用户最清楚）。
            // 切回支出时编辑模式回原交易挂靠、新增模式恢复上次记忆（preset 优先）
            if newValue == .income {
                if editingTransaction == nil {
                    selectedProject = nil
                }
            } else if let transaction = editingTransaction {
                selectedProject = transaction.financeProjectId.flatMap {
                    FinanceProjectRepository.shared.findProject(by: $0)
                }
            } else {
                loadDefaultProject()
            }
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
        // 无改动时保留系统下拉关闭；有改动时拦下并走「放弃修改？」确认
        .interactiveDismissDisabled(hasUnsavedChanges)
        .sheetDismissGuard { showDismissAlert = true }
        .alert(String(localized: "无法访问"), isPresented: $showReceiptPermissionAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "去设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(receiptPermissionMessage)
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
        .fullScreenCover(isPresented: $showReceiptGallery) {
            receiptGalleryCover
        }
    }

    // MARK: - Top Bar

    /// 顶部操作栏（关闭 + 标题 + 保存）
    private var topBar: some View {
        ZStack {
            Text(isEditMode ? String(localized: "编辑交易") : String(localized: "记一笔"))
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

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
                        .foregroundColor(.holoToolTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.holoToolBackground)
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
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(width: 32, height: 32)
                            .background(Color.holoToolBackground)
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
                            .background(canSave ? Color.holoPrimary : Color.holoToolTextSecondary.opacity(0.3))
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(canSave ? Color.holoPrimary : Color.holoToolTextSecondary.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .disabled(!canSave || isSaving)
                .accessibilityIdentifier("transactionSheet.saveButton")
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoToolSurface)
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
                Text(amountString == "0" ? String(localized: "金额") : String(localized: "¥ \(displayAmountString)"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(amountString == "0" ? .holoToolTextSecondary : .holoToolText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityIdentifier("transactionSheet.amountDisplay")

                if showNumericKeypad {
                    Rectangle()
                        .fill(Color.holoPrimary)
                        .frame(width: 2, height: 20)
                        .holoAmbientOpacity()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.holoToolSurface)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(showNumericKeypad ? Color.holoPrimary.opacity(0.75) : Color.holoToolTextSecondary.opacity(0.12), lineWidth: 1)
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
                .foregroundColor(.holoToolText)
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
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.holoToolSurface)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(isNoteFocused ? Color.holoPrimary.opacity(0.75) : Color.holoToolTextSecondary.opacity(0.12), lineWidth: 1)
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
                .background(Color.holoToolSurface)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }
}

// MARK: - Preview

#Preview {
    AddTransactionSheet(editingTransaction: nil) { _ in }
}

// MARK: - Pending Transaction Prefill

struct PendingTransactionPrefill {
    let amount: String
    let note: String?
    let type: TransactionType
    let category: Category?
    let date: Date?
}

// MARK: - 退款录入弹层

/// 记退款 / 编辑退款：金额默认全额（扣已退）、日期默认到账日、账户默认原账户。
/// 退款单独成笔挂回原支出（统计口径冲减原分类、冲到账当月），支持多次部分退款，累计不超原额。
struct RefundEntrySheet: View {
    /// 被退的原支出交易
    let original: Transaction
    /// 编辑已有退款笔时非 nil（此时金额/日期/账户预填该笔）
    var editingRefund: Transaction? = nil

    @State private var amountText: String = ""
    @State private var refundDate: Date = Date()
    @State private var selectedAccount: Account?
    @State private var remarkText: String = ""
    /// 除编辑中这笔之外的累计已退（编辑模式排除自身）
    @State private var otherRefunded: Decimal = 0
    @State private var accounts: [Account] = []
    @State private var isSaving = false
    /// 计算键盘显隐（金额行点击唤起，其他输入聚焦时收起）
    @State private var showKeypad = false
    /// 退款层内就地编辑原交易（弹通用编辑表单，东林 9-26：已退款记录也要能改原信息）
    @State private var showOriginalEditor = false
    @FocusState private var remarkFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private let repository = FinanceRepository.shared

    private var originalAmount: Decimal { original.amountAsDecimal }
    private var maxRefundable: Decimal { originalAmount - otherRefunded }
    private var refundAmount: Decimal? {
        guard let value = Decimal(string: amountText), value > 0 else { return nil }
        return value
    }
    private var exceedsLimit: Bool {
        guard let refundAmount else { return false }
        return refundAmount > maxRefundable
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                        originalCard
                        fieldCard
                        refundProgress
                        if exceedsLimit {
                            limitWarning
                        }
                        Text(String(localized: "退款单独成一笔流水，自动冲减\(original.category?.name ?? "原")分类支出；原交易金额保持不变。"))
                            .font(.holoCaption)
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .padding(HoloSpacing.lg)
                }
                if showKeypad {
                    keypadTray
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .background(Color.holoToolBackground)
            .navigationTitle(editingRefund == nil ? String(localized: "记退款") : String(localized: "编辑退款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(String(localized: "保存"))
                        }
                    }
                    .disabled(refundAmount == nil || exceedsLimit || isSaving)
                }
            }
        }
        .presentationDetents([.large])
        .task { await load() }
        .onChange(of: remarkFocused) { _, focused in
            if focused { showKeypad = false }
        }
        // 原交易编辑保存后刷新可退上限（账户列表一并重取）
        .sheet(isPresented: $showOriginalEditor, onDismiss: {
            Task { await load() }
        }) {
            AddTransactionSheet(editingTransaction: original) { _ in
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            }
            .holoSheetWidth(.form)
        }
    }

    // MARK: - 子视图

    /// 原交易信息卡
    private var originalCard: some View {
        HStack(spacing: HoloSpacing.md) {
            CategoryIconBadge(
                iconName: original.category?.icon ?? "cart",
                color: original.category?.swiftUIColor ?? .holoPrimary,
                diameter: 40
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(original.note?.isEmpty == false ? original.note! : (original.category?.name ?? String(localized: "未分类")))
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text("\(shortDateText(original.date)) · \(original.category?.name ?? "") · \(original.account?.name ?? "")")
                    .font(.holoCaption)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HoloSpacing.sm)
            // 原交易可就地编辑（弹通用编辑表单，回来自动刷新可退上限）
            Button {
                remarkFocused = false
                showOriginalEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.holoNestedCardBackground))
            }
            .buttonStyle(.plain)
            // formattedAmount 自带货币符号，不要再拼 ¥（会双符号）
            Text(original.formattedAmount)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.holoToolText)
        }
        .padding(HoloSpacing.md)
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
    }

    /// 退款金额 / 到账日期 / 到账账户 / 备注
    private var fieldCard: some View {
        VStack(spacing: 0) {
            Button {
                remarkFocused = false
                withAnimation(HoloAnimation.quick) { showKeypad = true }
            } label: {
                HStack {
                    Text(String(localized: "退款金额"))
                        .font(.holoBody)
                        .foregroundColor(.holoToolTextSecondary)
                    Spacer()
                    Text(amountText == "0" || amountText.isEmpty
                         ? String(localized: "¥ 0")
                         : String(localized: "¥ \(amountText)"))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(amountText == "0" || amountText.isEmpty ? .holoToolTextSecondary : .holoPrimaryDark)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("refundSheet.amountDisplay")
                    if showKeypad {
                        Rectangle()
                            .fill(Color.holoPrimary)
                            .frame(width: 2, height: 22)
                            .holoAmbientOpacity()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(HoloSpacing.md)

            Divider().padding(.leading, HoloSpacing.md)

            HStack {
                Text(String(localized: "到账日期"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                DatePicker(
                    "",
                    selection: $refundDate,
                    displayedComponents: .date
                )
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
            }
            .padding(HoloSpacing.md)

            Divider().padding(.leading, HoloSpacing.md)

            HStack {
                Text(String(localized: "到账账户"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Menu {
                    ForEach(accounts, id: \.id) { account in
                        Button(account.name ?? "") {
                            selectedAccount = account
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedAccount?.name ?? String(localized: "未指定"))
                            .font(.holoBody)
                            .foregroundColor(.holoToolText)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
            }
            .padding(HoloSpacing.md)

            Divider().padding(.leading, HoloSpacing.md)

            HStack {
                Text(String(localized: "备注"))
                    .font(.holoBody)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                TextField(String(localized: "选填"), text: $remarkText)
                    .font(.holoBody)
                    .multilineTextAlignment(.trailing)
                    .focused($remarkFocused)
                    .submitLabel(.done)
                    .onSubmit { remarkFocused = false }
            }
            .padding(HoloSpacing.md)
        }
        .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoToolSurface))
    }

    /// 计算键盘托盘：全额快捷键 + 通用计算键盘（与记账同款，支持四则运算）
    private var keypadTray: some View {
        VStack(spacing: 0) {
            if maxRefundable > 0 {
                fullRefundChip
            }
            HoloAmountKeypad(
                amountText: $amountText,
                onConfirm: {
                    save()
                },
                onNext: {
                    withAnimation(HoloAnimation.quick) { showKeypad = false }
                }
            )
        }
        .background(Color.transactionKeypadTrayBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: -4)
    }

    /// 全额快捷：一键填入还可退余额（记退款最高频动作）
    private var fullRefundChip: some View {
        Button {
            HapticManager.light()
            amountText = maxRefundable.description
        } label: {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 14))
                Text(String(localized: "全额 \(maxRefundable.formattedAsCurrency())"))
                    .font(.holoCaption.weight(.semibold))
            }
            .foregroundColor(.holoSuccessDark)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.holoSuccess.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
    }

    /// 已退进度：文案 + 进度条
    private var refundProgress: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack {
                Text(String(localized: "已退 \(otherRefunded.formattedAsCurrency()) / \(original.formattedAmount)"))
                    .font(.holoCaption)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Text(String(localized: "还可退 \(maxRefundable.formattedAsCurrency())"))
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(maxRefundable > 0 ? .holoSuccessDark : .holoToolTextSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.holoNestedCardBackground)
                    Capsule()
                        .fill(Color.holoSuccess)
                        .frame(width: proxy.size.width * refundProgressRatio)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, HoloSpacing.xs)
    }

    /// 已退比例（0~1，Double 便于直接驱动进度条宽度）
    private var refundProgressRatio: CGFloat {
        guard originalAmount > 0 else { return 0 }
        let ratio = Double(truncating: (otherRefunded / originalAmount) as NSDecimalNumber)
        return CGFloat(min(max(ratio, 0), 1))
    }

    private var limitWarning: some View {        Text(String(localized: "超出可退金额：这笔支出最多还可退 \(maxRefundable.formattedAsCurrency())"))
            .font(.holoCaption.weight(.semibold))
            .foregroundColor(.holoError)
            .padding(HoloSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoErrorLight))
    }

    // MARK: - 数据与保存

    private func load() async {
        accounts = (try? await repository.getAllAccounts()) ?? []
        let refunds = (try? await repository.getRefunds(for: original)) ?? []
        if let editingRefund {
            otherRefunded = refunds
                .filter { $0.id != editingRefund.id }
                .reduce(Decimal(0)) { $0 + $1.amountAsDecimal }
            amountText = editingRefund.amount.stringValue
            refundDate = editingRefund.date
            selectedAccount = editingRefund.account
            remarkText = editingRefund.remark ?? ""
        } else {
            otherRefunded = refunds.reduce(Decimal(0)) { $0 + $1.amountAsDecimal }
            // 默认全额（剩余可退部分）；已退满时不预填，避免直接保存超额
            amountText = maxRefundable > 0 ? maxRefundable.description : ""
            refundDate = Date()
            selectedAccount = original.account
        }
    }

    private func save() {
        // 表达式中间态兜底求值（如 "100-30" → "70"），纯数字原样
        amountText = AmountMath.resolve(amountText)
        guard let refundAmount, !exceedsLimit else { return }
        isSaving = true
        Task {
            do {
                if let editingRefund {
                    var updates = TransactionUpdates()
                    updates.amount = refundAmount
                    updates.date = refundDate
                    // remark 空串=清空（与通用编辑同一约定）
                    updates.remark = remarkText
                    if let selectedAccount { updates.account = selectedAccount }
                    try await repository.updateTransaction(editingRefund, updates: updates)
                } else {
                    try await repository.addRefundTransaction(
                        original: original,
                        amount: refundAmount,
                        date: refundDate,
                        account: selectedAccount,
                        remark: remarkText.isEmpty ? nil : remarkText
                    )
                }
                HapticManager.success()
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                dismiss()
            } catch {
                HoloToastCenter.shared.show(error.localizedDescription, type: .error)
                isSaving = false
            }
        }
    }

    private func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("MEd")
        return formatter.string(from: date)
    }
}

// MARK: - 退款选择弹层

/// 原交易名下退款列表：详情面板「退款 · X 笔」进入，选一笔去编辑（单笔多笔同交互）
struct RefundPickerSheet: View {
    let original: Transaction
    let onSelect: (Transaction) -> Void

    @State private var refunds: [Transaction] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(refunds, id: \.objectID) { refund in
                    Button {
                        onSelect(refund)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "退 ¥\(refund.amountAsDecimal.formattedAsCurrency())"))
                                    .font(.holoBody.weight(.semibold))
                                    .foregroundColor(.holoToolText)
                                Text("\(shortDateText(refund.date)) · \(refund.account?.name ?? String(localized: "未指定"))")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoToolTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .navigationTitle(String(localized: "退款记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            refunds = (try? await FinanceRepository.shared.getRefunds(for: original)) ?? []
        }
    }

    private func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("MEd")
        return formatter.string(from: date)
    }
}

extension Decimal {
    /// 金额文案（本地化数字，无货币符号），退款徽章/进度文案用
    func formattedAsCurrency() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: self as NSDecimalNumber) ?? "0.00"
    }
}
