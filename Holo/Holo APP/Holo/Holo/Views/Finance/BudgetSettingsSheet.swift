//
//  BudgetSettingsSheet.swift
//  Holo
//
//  预算设置 Sheet - 新建/编辑账户预算（总预算 + 分类预算）
//

import SwiftUI
import CoreData

/// 预算设置模式
enum BudgetSheetMode: String, CaseIterable {
    case total = "总预算"
    case category = "分类预算"
}

struct BudgetSettingsSheet: View {

    let account: Account
    let existingBudget: Budget?
    let initialMode: BudgetSheetMode?
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss

    @State private var mode: BudgetSheetMode = .total
    @State private var amountString: String = ""
    @State private var selectedPeriod: BudgetPeriod = .month
    @State private var startDate: Date = Date()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirm = false

    // 分类预算相关
    @State private var selectedCategory: Category?
    @State private var categories: [Category] = []
    @State private var expandedParentId: UUID? = nil

    private var isEditMode: Bool { existingBudget != nil }

    private var isCategoryMode: Bool { mode == .category }

    private var budgetAmount: Decimal {
        guard !amountString.isEmpty,
              let value = Decimal(string: amountString),
              value > 0 else {
            return 0
        }
        return value
    }

    private var isAmountFormatValid: Bool {
        amountString.isEmpty || Decimal(string: amountString) != nil
    }

    private var isValid: Bool {
        guard budgetAmount > 0 else { return false }
        if isCategoryMode { return selectedCategory != nil }
        return true
    }

    init(
        account: Account,
        existingBudget: Budget? = nil,
        initialMode: BudgetSheetMode? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.account = account
        self.existingBudget = existingBudget
        self.initialMode = initialMode
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    // 模式选择器（非编辑模式才显示）
                    if !isEditMode {
                        modeSelector
                    }

                    // 分类选择器（仅分类模式）
                    if isCategoryMode {
                        CategoryBudgetPicker(
                            selectedCategory: $selectedCategory,
                            categories: categories,
                            expandedParentId: $expandedParentId
                        )
                    }

                    // 预算金额输入
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("预算金额")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: HoloSpacing.sm) {
                            Text("¥")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.holoTextPrimary)
                            TextField("0.00", text: $amountString)
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .keyboardType(.decimalPad)
                        }
                        .padding(HoloSpacing.md)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        if !amountString.isEmpty && !isAmountFormatValid {
                            Text("请输入有效的金额")
                                .font(.holoCaption)
                                .foregroundColor(.holoError)
                        }
                    }

                    // 预算周期选择
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("预算周期")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: HoloSpacing.sm) {
                            ForEach(BudgetPeriod.allCases) { period in
                                HoloFilterChip(
                                    title: period.displayName,
                                    isSelected: selectedPeriod == period,
                                    action: {
                                        if !isEditMode {
                                            selectedPeriod = period
                                        }
                                    }
                                )
                            }
                        }
                    }

                    // 起始日期
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        Text("起始日期")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        DatePicker(
                            "",
                            selection: $startDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .padding(HoloSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.holoCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }

                    // 编辑模式下显示删除按钮
                    if isEditMode {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("删除预算")
                            }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoError)
                            .frame(maxWidth: .infinity)
                            .padding(HoloSpacing.md)
                            .background(Color.holoError.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditMode ? "预算设置" : "新建预算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditMode ? "保存" : "创建") {
                        saveBudget()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isValid ? .holoPrimary : .holoTextSecondary)
                    .disabled(!isValid)
                }
            }
            .alert("操作失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .alert("确认删除", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteBudget()
                }
            } message: {
                Text("确定要删除该预算吗？删除后预算追踪将停止。")
            }
            .onAppear {
                // 加载分类列表（同步 Core Data fetch）
                let request = Category.fetchRequest()
                request.predicate = NSPredicate(format: "type == %@", TransactionType.expense.rawValue)
                request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
                categories = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []

                // 设置初始模式
                if let initialMode {
                    mode = initialMode
                }

                if let budget = existingBudget {
                    amountString = String(describing: budget.amount.decimalValue)
                    selectedPeriod = budget.budgetPeriod
                    startDate = budget.startDate

                    // 编辑分类预算时切换模式
                    if budget.categoryId != nil {
                        mode = .category
                        selectedCategory = BudgetRepository.shared.findCategory(by: budget.categoryId)
                    }
                } else {
                    // 新建模式：默认起始日期为下月1号
                    let cal = Calendar.current
                    let now = Date()
                    var components = cal.dateComponents([.year, .month], from: now)
                    components.month! += 1
                    components.day = 1
                    startDate = cal.date(from: components) ?? now
                }
            }
        }
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(BudgetSheetMode.allCases, id: \.self) { modeOption in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mode = modeOption
                        if modeOption == .total {
                            selectedCategory = nil
                        }
                    }
                } label: {
                    Text(modeOption.rawValue)
                        .font(.system(size: 13, weight: mode == modeOption ? .semibold : .regular))
                        .foregroundColor(mode == modeOption ? .white : .holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            mode == modeOption ? Color.holoPrimary : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(3)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func saveBudget() {
        do {
            if let budget = existingBudget {
                try BudgetRepository.shared.updateBudget(
                    budget,
                    amount: budgetAmount,
                    startDate: startDate
                )
            } else {
                if isCategoryMode {
                    guard let category = selectedCategory else {
                        errorMessage = "请选择一个分类"
                        showError = true
                        return
                    }
                    _ = try BudgetRepository.shared.addCategoryBudget(
                        accountId: account.id,
                        categoryId: category.id,
                        amount: budgetAmount,
                        period: selectedPeriod,
                        startDate: startDate
                    )
                } else {
                    _ = try BudgetRepository.shared.addBudget(
                        accountId: account.id,
                        amount: budgetAmount,
                        period: selectedPeriod,
                        startDate: startDate
                    )
                }
            }
            HapticManager.success()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteBudget() {
        guard let budget = existingBudget else { return }
        do {
            try BudgetRepository.shared.deleteBudget(budget)
            HapticManager.success()
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
