//
//  AddTransactionView.swift
//  Holo
//
//  添加交易记录页面
//  包含金额输入、分类选择、账户选择、备注和标签
//

import SwiftUI

/// 添加交易记录视图
struct AddTransactionView: View {
    
    // MARK: - Properties
    
    /// 环境变量：dismiss
    @Environment(\.dismiss) var dismiss
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    // MARK: - State
    
    /// 金额输入
    @State private var amount: String = ""
    
    /// 交易类型
    @State private var transactionType: TransactionType = .expense
    
    /// 选中的分类
    @State private var selectedCategory: Category?
    
    /// 选中的账户
    @State private var selectedAccount: Account?
    
    /// 日期
    @State private var selectedDate: Date = Date()
    
    /// 备注
    @State private var note: String = ""
    
    /// 标签
    @State private var selectedTags: [String] = []
    
    /// 是否显示日期选择器
    @State private var showDatePicker: Bool = false
    
    /// 是否正在保存
    @State private var isSaving: Bool = false
    
    /// 错误信息
    @State private var errorMessage: String?
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 金额输入
                    AmountInput(amount: $amount, transactionType: $transactionType)
                        .padding(.horizontal, HoloSpacing.lg)
                    
                    // 快速记账模板
                    if amount.isEmpty {
                        QuickTemplateView(selectedAccount: $selectedAccount) { quickAmount, quickType, quickCategory in
                            amount = "\(quickAmount)"
                            transactionType = quickType
                            selectedCategory = quickCategory
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                    }
                    
                    // 表单内容
                    VStack(spacing: 0) {
                        // 分类选择（Binding 联动收入/支出类型切换）
                        CategoryPicker(
                            selectedCategory: $selectedCategory,
                            transactionType: $transactionType
                        )
                        .background(Color.holoCardBackground)
                        
                        Divider()
                            .padding(.horizontal, HoloSpacing.lg)
                        
                        // 账户选择
                        AccountPicker(selectedAccount: $selectedAccount)
                            .background(Color.holoCardBackground)
                        
                        Divider()
                            .padding(.horizontal, HoloSpacing.lg)
                        
                        // 日期选择
                        DatePickerRow(
                            date: $selectedDate,
                            showPicker: $showDatePicker
                        )
                        .padding(HoloSpacing.md)
                        .background(Color.holoCardBackground)
                        
                        Divider()
                            .padding(.horizontal, HoloSpacing.lg)
                        
                        // 备注输入
                        NoteInput(note: $note)
                            .padding(HoloSpacing.md)
                            .background(Color.holoCardBackground)
                        
                        Divider()
                            .padding(.horizontal, HoloSpacing.lg)
                        
                        // 标签选择
                        TagSelector(selectedTags: $selectedTags)
                            .background(Color.holoCardBackground)
                    }
                    .background(Color.holoBackground)
                    
                    // 保存按钮
                    SaveButton(
                        isLoading: isSaving,
                        isEnabled: canSave
                    ) {
                        await saveTransaction()
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.xl)
                }
                .padding(.top, HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// 是否可以保存
    private var canSave: Bool {
        !amount.isEmpty &&
        (Decimal(string: amount) ?? 0) > 0 &&
        selectedCategory != nil &&
        selectedAccount != nil
    }
    
    // MARK: - Methods
    
    /// 保存交易记录
    @MainActor
    private func saveTransaction() async {
        guard canSave else { return }
        
        isSaving = true
        
        do {
            let amountValue = Decimal(string: amount) ?? 0
            
            try await repository.addTransaction(
                amount: amountValue,
                type: transactionType,
                category: selectedCategory!,
                account: selectedAccount!,
                date: selectedDate,
                note: note.isEmpty ? nil : note,
                tags: selectedTags.isEmpty ? nil : selectedTags
            )
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isSaving = false
    }
}

// MARK: - Date Picker Row

/// 日期选择器行
struct DatePickerRow: View {
    
    // MARK: - Properties
    
    /// 选中的日期
    @Binding var date: Date
    
    /// 是否显示选择器
    @Binding var showPicker: Bool
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Button {
                withAnimation {
                    showPicker.toggle()
                }
            } label: {
                HStack {
                    Text("日期")
                        .foregroundColor(.holoTextSecondary)
                    
                    Spacer()
                    
                    Text(date, style: .date)
                        .foregroundColor(.holoTextPrimary)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .rotationEffect(.degrees(showPicker ? 180 : 0))
                }
            }
            
            if showPicker {
                DatePicker(
                    "",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
            }
        }
    }
}

// MARK: - Note Input

/// 备注输入框
struct NoteInput: View {
    
    // MARK: - Properties
    
    /// 备注文字
    @Binding var note: String
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("备注")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            TextField("添加备注...", text: $note)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
    }
}

// MARK: - Save Button

/// 保存按钮
struct SaveButton: View {
    
    // MARK: - Properties
    
    /// 是否正在加载
    let isLoading: Bool
    
    /// 是否启用
    let isEnabled: Bool
    
    /// 点击回调
    let action: () async -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text("保存")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                isEnabled ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.3),
                in: RoundedRectangle(cornerRadius: HoloRadius.lg)
            )
            .foregroundColor(.white)
            .shadow(
                color: isEnabled ? Color.holoPrimary.opacity(0.3) : .clear,
                radius: 10,
                x: 0,
                y: 4
            )
        }
        .disabled(!isEnabled || isLoading)
    }
}

// MARK: - Preview

#Preview {
    AddTransactionView()
}