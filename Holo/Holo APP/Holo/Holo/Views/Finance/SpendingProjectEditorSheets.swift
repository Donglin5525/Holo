//
//  SpendingProjectEditorSheets.swift
//  Holo
//
//  固定支出新建与编辑表单：
//  - AddSpendingProjectSheet：顶部简洁三段「订阅 | 分期 | 大件」+ 融合外观 + 独立到期提醒 + 自动记账 + 扣款账户
//  - SpendingProjectEndConditionSheet：编辑订阅 / 分期
//  - SpendingProjectOneOffEditorSheet：编辑大件
//

import SwiftUI
import CoreData

// MARK: - 新建类型（仅 UI 呈现三类心智，底层仍落 SpendingProject）

enum SpendingProjectCreationMode: String, CaseIterable, Identifiable {
    case subscription
    case installment
    case asset

    var id: String { rawValue }
    var title: String {
        switch self {
        case .subscription: String(localized: "订阅")
        case .installment: String(localized: "分期")
        case .asset: String(localized: "大件")
        }
    }
}

// MARK: - AddSpendingProjectSheet

struct AddSpendingProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialMode: SpendingProjectCreationMode
    let onSaved: () -> Void

    @State private var mode: SpendingProjectCreationMode
    @State private var name = ""
    @State private var amount = ""
    @State private var frequency: SpendingProjectFrequency = .monthly
    @State private var startDate = Date()
    @State private var totalOccurrences = "12"
    @State private var autoGenerateTransaction = true
    @State private var reminderEnabled = false
    @State private var reminderLeadDays: Int32 = Int32(BillDueReminderScheduler.shared.advance)
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var accounts: [Account] = []
    @State private var appearanceSelection: SpendingProjectAppearanceSelection = .unchanged
    @State private var hasManuallyPickedAppearance = false
    @State private var showAppearancePicker = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focusedField: Bool

    init(initialMode: SpendingProjectCreationMode = .subscription, onSaved: @escaping () -> Void) {
        self.initialMode = initialMode
        self.onSaved = onSaved
        _mode = State(initialValue: initialMode)
    }

    private var canSaveProject: Bool {
        guard !isSaving else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let value = Decimal(string: amount), value > 0 else { return false }
        if mode == .installment, (Int32(totalOccurrences) ?? 0) <= 0 { return false }
        return selectedCategory != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $mode) {
                        ForEach(SpendingProjectCreationMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                Section {
                    Button {
                        showAppearancePicker = true
                    } label: {
                        HStack(spacing: HoloSpacing.md) {
                            SpendingProjectAppearancePreviewSlot(
                                selection: appearanceSelection,
                                fallbackCategory: selectedCategory,
                                size: 40
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("外观图标")
                                    .font(.holoBody)
                                    .foregroundStyle(Color.holoToolText)
                                Text(appearanceSubtitle)
                                    .font(.holoLabel)
                                    .foregroundStyle(Color.holoToolTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .holoIconSize(.xs)
                                .foregroundStyle(Color.holoToolTextSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)

                    TextField(namePlaceholder, text: $name)
                        .focused($focusedField)

                    TextField(mode == .asset ? String(localized: "购入总价") : String(localized: "每期金额"), text: $amount)
                        .keyboardType(.decimalPad)
                        .focused($focusedField)
                }
                .listRowBackground(Color.holoToolSurface)

                Section("消费分类") {
                    CategoryPicker(selectedCategory: $selectedCategory, transactionType: .constant(.expense), showsTypeTabs: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.holoToolSurface)
                }

                if mode == .asset {
                    Section("购置信息") {
                        DatePicker(String(localized: "购买日期"), selection: $startDate, displayedComponents: .date)
                        Text("仅用于计算持有天数与日均成本，不会自动生成账本流水。")
                            .font(.holoLabel)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .listRowBackground(Color.holoToolSurface)
                } else {
                    Section("周期与扣款") {
                        Picker("周期", selection: $frequency) {
                            ForEach(SpendingProjectFrequency.allCases, id: \.self) { freq in
                                Text(freq.title).tag(freq)
                            }
                        }

                        if mode == .installment {
                            HStack {
                                Text("总期数")
                                Spacer()
                                TextField("12", text: $totalOccurrences)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    .focused($focusedField)
                                Text("期")
                                    .foregroundStyle(Color.holoToolTextSecondary)
                            }
                        }

                        DatePicker(
                            mode == .subscription ? String(localized: "开始 / 下次扣款日") : String(localized: "首期扣款日"),
                            selection: $startDate,
                            displayedComponents: .date
                        )

                        Toggle("到期自动写入账本", isOn: $autoGenerateTransaction)
                            .tint(Color.holoToolAction)

                        if autoGenerateTransaction, !accounts.isEmpty {
                            Picker("扣款账户", selection: $selectedAccount) {
                                ForEach(accounts.renderable, id: \.objectID) { acc in
                                    Text(acc.name).tag(Optional(acc))
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.holoToolSurface)

                    Section("到期提醒") {
                        Toggle("续费前提醒我", isOn: Binding(
                            get: { reminderEnabled },
                            set: { handleReminderToggle($0) }
                        ))
                        .tint(Color.holoToolAction)

                        if reminderEnabled {
                            Picker("提前提醒", selection: $reminderLeadDays) {
                                ForEach(BillDueReminderScheduler.leadDayOptions, id: \.self) { days in
                                    Text(days == 0 ? String(localized: "当天") : String(localized: "提前 \(days) 天"))
                                        .tag(days)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.holoToolSurface)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(Color.holoToolError)
                    }
                    .listRowBackground(Color.holoToolSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .tint(Color.holoToolAction)
            .navigationTitle("添加固定支出")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .holoIconSize(.sm)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSaveProject)
                }
            }
            .sheet(isPresented: $showAppearancePicker) {
                SpendingProjectAppearancePicker(
                    currentPlacement: .none,
                    currentIcon: selectedIconKey
                ) { selection in
                    hasManuallyPickedAppearance = true
                    appearanceSelection = selection
                }
            }
            .onChange(of: name) { _, newValue in
                guard !hasManuallyPickedAppearance else { return }
                if let matched = SubscriptionBrandIconCatalog.match(for: newValue) {
                    appearanceSelection = .icon(matched.id)
                } else if case .icon(let key) = appearanceSelection, key.hasPrefix("sub_") {
                    appearanceSelection = .unchanged
                }
            }
            .onAppear {
                accounts = FinanceRepository.shared.getAccounts()
                if selectedAccount == nil {
                    selectedAccount = FinanceRepository.shared.getDefaultAccountSync() ?? accounts.first
                }
            }
            .presentationBackground(Color.holoToolBackground)
        }
    }

    private var namePlaceholder: String {
        switch mode {
        case .subscription: return String(localized: "名称")
        case .installment: return String(localized: "名称")
        case .asset: return String(localized: "物品名称")
        }
    }

    private var selectedIconKey: String? {
        if case .icon(let key) = appearanceSelection { return key }
        return nil
    }

    private var appearanceSubtitle: String {
        switch appearanceSelection {
        case .sticker: return String(localized: "已选贴纸")
        case .icon(let key):
            if let brand = SubscriptionBrandIconCatalog.brand(for: key) {
                return brand.name
            }
            return EmojiCatalog.isEmojiIcon(key) ? String(localized: "Emoji · \(key)") : String(localized: "已选经典图标")
        case .clearToDefault, .unchanged:
            return String(localized: "品牌、贴纸、Emoji 或经典图标")
        }
    }

    private func handleReminderToggle(_ newValue: Bool) {
        if newValue, !BillDueReminderScheduler.canEnableReminder(for: nil) {
            HoloPlusActionCoordinator.shared.requirePlus(context: .subscriptionReminder) {
                await MainActor.run {
                    reminderEnabled = true
                    BillDueReminderScheduler.requestAuthorizationIfNeeded()
                }
            }
            return
        }
        reminderEnabled = newValue
        if newValue {
            BillDueReminderScheduler.requestAuthorizationIfNeeded()
        }
    }

    private func save() {
        guard !isSaving else { return }
        guard let value = Decimal(string: amount), value > 0 else {
            errorMessage = String(localized: "请输入有效金额")
            return
        }
        guard let selectedCategory else {
            errorMessage = String(localized: "请选择消费分类")
            return
        }

        let kind: SpendingProjectKind = mode == .asset ? .oneOff : .recurring
        let maxOccurrences: Int32 = mode == .installment ? (Int32(totalOccurrences) ?? 0) : 0
        let account = (kind == .recurring && autoGenerateTransaction)
            ? (selectedAccount ?? FinanceRepository.shared.getDefaultAccountSync())
            : nil
        let customIcon: String? = {
            if case .icon(let key) = appearanceSelection { return key }
            return nil
        }()

        do {
            isSaving = true
            let project = try SpendingProjectRepository.shared.create(
                name: name,
                kind: kind,
                amount: value,
                frequency: kind == .recurring ? frequency : nil,
                startDate: startDate,
                endDate: nil,
                maxOccurrences: maxOccurrences,
                plannedLifespanDays: 0,
                category: selectedCategory,
                account: account,
                autoGenerateTransaction: kind == .recurring ? autoGenerateTransaction : false,
                reminderEnabled: kind == .recurring ? reminderEnabled : false,
                reminderLeadDays: reminderLeadDays,
                icon: customIcon
            )

            if case .sticker = appearanceSelection {
                Task { @MainActor in
                    do {
                        try await SpendingProjectRepository.shared.applyAppearance(appearanceSelection, for: project)
                    } catch {
                        HoloToastCenter.shared.show(String(localized: "项目已保存，但贴纸未绑定成功"), type: .error)
                    }
                    BillDueReminderScheduler.shared.refresh()
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } else {
                BillDueReminderScheduler.shared.refresh()
                isSaving = false
                onSaved()
                dismiss()
            }
        } catch {
            isSaving = false
            errorMessage = String(localized: "保存失败，请稍后重试")
        }
    }
}

// MARK: - 编辑订阅 / 分期

struct SpendingProjectEndConditionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void

    @State private var name: String
    @State private var amount: String
    @State private var frequency: SpendingProjectFrequency
    @State private var startDate: Date
    @State private var mode: SpendingProjectEndMode
    @State private var endDate: Date
    @State private var totalOccurrences: String
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var accounts: [Account] = []
    @State private var errorMessage: String?

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _amount = State(initialValue: NSDecimalNumber(decimal: project.amountDecimal).stringValue)
        _frequency = State(initialValue: project.resolvedFrequency)
        _startDate = State(initialValue: project.startDate)
        _endDate = State(initialValue: project.endDate ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        _totalOccurrences = State(initialValue: project.maxOccurrences > 0 ? "\(project.maxOccurrences)" : "12")
        _selectedCategory = State(initialValue: project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) })
        _selectedAccount = State(initialValue: project.accountId.flatMap { FinanceRepository.shared.findAccount(by: $0) })
        if project.maxOccurrences > 0 {
            _mode = State(initialValue: .occurrenceCount)
        } else if project.endDate != nil {
            _mode = State(initialValue: .endDate)
        } else {
            _mode = State(initialValue: .forever)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("每期金额", text: $amount)
                        .keyboardType(.decimalPad)
                    Picker("周期", selection: $frequency) {
                        ForEach(SpendingProjectFrequency.allCases, id: \.self) { freq in
                            Text(freq.title).tag(freq)
                        }
                    }
                    DatePicker("开始 / 扣款日", selection: $startDate, displayedComponents: .date)
                    if !accounts.isEmpty {
                        Picker("扣款账户", selection: $selectedAccount) {
                            ForEach(accounts.renderable, id: \.objectID) { acc in
                                Text(acc.name).tag(Optional(acc))
                            }
                        }
                    }
                }
                .listRowBackground(Color.holoToolSurface)

                Section("结束条件") {
                    Picker("结束条件", selection: $mode) {
                        ForEach(SpendingProjectEndMode.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if mode == .endDate {
                        DatePicker("结束日期", selection: $endDate, in: project.startDate..., displayedComponents: .date)
                    }
                    if mode == .occurrenceCount {
                        TextField("总期数", text: $totalOccurrences)
                            .keyboardType(.numberPad)
                    }
                }
                .listRowBackground(Color.holoToolSurface)

                Section("消费分类") {
                    CategoryPicker(selectedCategory: $selectedCategory, transactionType: .constant(.expense), showsTypeTabs: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.holoToolSurface)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.holoToolError) }
                        .listRowBackground(Color.holoToolSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .tint(Color.holoToolAction)
            .navigationTitle("编辑项目")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                accounts = FinanceRepository.shared.getAccounts()
            }
            .presentationBackground(Color.holoToolBackground)
        }
    }

    private func save() {
        guard let value = Decimal(string: amount), value > 0 else {
            errorMessage = String(localized: "请输入有效每期金额")
            return
        }
        let maxOccurrences = mode == .occurrenceCount ? (Int32(totalOccurrences) ?? 0) : 0
        let finalEndDate = mode == .endDate ? endDate : nil
        if mode == .occurrenceCount, maxOccurrences <= 0 {
            errorMessage = String(localized: "请输入有效总期数")
            return
        }
        do {
            try SpendingProjectRepository.shared.updateRecurringProject(
                project,
                name: name,
                amount: value,
                frequency: frequency,
                startDate: startDate,
                endDate: finalEndDate,
                maxOccurrences: maxOccurrences,
                category: selectedCategory,
                account: selectedAccount
            )
            BillDueReminderScheduler.shared.refresh()
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(localized: "保存失败")
        }
    }
}

// MARK: - 编辑大件

struct SpendingProjectOneOffEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void

    @State private var name: String
    @State private var amount: String
    @State private var purchaseDate: Date
    @State private var selectedCategory: Category?
    @State private var errorMessage: String?

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _amount = State(initialValue: NSDecimalNumber(decimal: project.amountDecimal).stringValue)
        _purchaseDate = State(initialValue: project.startDate)
        _selectedCategory = State(initialValue: project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("物品名称", text: $name)
                    TextField("购入总价", text: $amount)
                        .keyboardType(.decimalPad)
                    DatePicker("购买日期", selection: $purchaseDate, displayedComponents: .date)
                }
                .listRowBackground(Color.holoToolSurface)

                Section("消费分类") {
                    CategoryPicker(selectedCategory: $selectedCategory, transactionType: .constant(.expense), showsTypeTabs: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.holoToolSurface)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.holoToolError) }
                        .listRowBackground(Color.holoToolSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .tint(Color.holoToolAction)
            .navigationTitle("编辑大件")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .presentationBackground(Color.holoToolBackground)
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "请输入名称")
            return
        }
        guard let value = Decimal(string: amount), value > 0 else {
            errorMessage = String(localized: "请输入有效金额")
            return
        }
        guard let selectedCategory else {
            errorMessage = String(localized: "请选择消费分类")
            return
        }
        do {
            try SpendingProjectRepository.shared.updateOneOffProject(
                project,
                name: name,
                amount: value,
                purchaseDate: purchaseDate,
                category: selectedCategory
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(localized: "保存失败")
        }
    }
}
