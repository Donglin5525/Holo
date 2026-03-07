//
//  AddTransactionSheet.swift
//  Holo
//
//  添加/编辑交易弹窗 - 底部弹出的 Sheet 样式
//  包含金额输入、分类选择、数字键盘
//

import SwiftUI

/// 添加/编辑交易 Sheet
struct AddTransactionSheet: View {
    
    // MARK: - Properties
    
    /// 环境变量
    @Environment(\.dismiss) var dismiss
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    /// 正在编辑的交易（nil 表示新增模式）
    let editingTransaction: Transaction?
    
    /// 保存完成回调
    let onSave: () -> Void
    
    // MARK: - State
    
    /// 交易类型
    @State private var transactionType: TransactionType = .expense
    
    /// 金额字符串
    @State private var amountString: String = "0"
    
    /// 选中的分类
    @State private var selectedCategory: Category?
    
    /// 备注
    @State private var note: String = ""
    
    /// 是否正在保存
    @State private var isSaving: Bool = false
    
    /// 是否显示删除确认
    @State private var showDeleteConfirm: Bool = false
    
    /// 是否正在删除
    @State private var isDeleting: Bool = false
    
    /// 光标闪烁动画
    @State private var cursorOpacity: Double = 1.0
    
    /// 是否为编辑模式
    private var isEditMode: Bool {
        editingTransaction != nil
    }
    
    // MARK: - Initialization
    
    init(editingTransaction: Transaction?, onSave: @escaping () -> Void) {
        self.editingTransaction = editingTransaction
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
                            
                            // 备注输入
                            noteSection
                                .padding(.horizontal, HoloSpacing.lg)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    
                    // 数字键盘
                    numericKeypad
                    
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
        }
        .onAppear {
            if let transaction = editingTransaction {
                populateFromTransaction(transaction)
            }
            startCursorAnimation()
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
                .background(Color.white)
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
            // 关闭按钮
            Button {
                dismiss()
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
            
            // 占位，保持对称
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.white)
    }
    
    // MARK: - Amount Section
    
    /// 金额显示区域
    private var amountSection: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text("金额")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.holoTextSecondary)
                
                HStack(spacing: 0) {
                    // 金额显示
                    Text(amountString)
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
        .background(Color.white)
    }
    
    // MARK: - Category Section
    
    /// 分类选择区域 — 使用 CategoryPicker 组件，支持一级→二级下钻
    private var categorySection: some View {
        CategoryPicker(
            selectedCategory: $selectedCategory,
            transactionType: $transactionType
        )
    }
    
    // MARK: - Note Section
    
    /// 备注输入区域
    private var noteSection: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            
            TextField("添加备注（选填）...", text: $note)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .padding(HoloSpacing.md)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
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
        .background(Color.white)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: -4)
    }
    
    /// 键盘布局
    private let keypadLayout: [[String]] = [
        ["7", "8", "9", "AC"],
        ["4", "5", "6", "+"],
        ["1", "2", "3", "-"],
        [".", "0", "⌫", "✓"]
    ]
    
    // MARK: - Methods
    
    /// 从交易填充数据（编辑模式）
    private func populateFromTransaction(_ transaction: Transaction) {
        transactionType = transaction.transactionType
        amountString = String(describing: transaction.amount.decimalValue)
        selectedCategory = transaction.category
        note = transaction.note ?? ""
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
            // 清空
            amountString = "0"
            
        case "⌫":
            // 删除
            if amountString.count > 1 {
                amountString.removeLast()
            } else {
                amountString = "0"
            }
            
        case "✓":
            // 确认保存
            saveTransaction()
            
        case "+", "-":
            // 加减运算（暂不支持，直接追加）
            if amountString != "0" {
                amountString += key
            }
            
        case ".":
            // 小数点
            if !amountString.contains(".") {
                amountString += "."
            }
            
        default:
            // 数字
            if amountString == "0" {
                amountString = key
            } else {
                // 限制小数位数
                if let dotIndex = amountString.firstIndex(of: ".") {
                    let decimalPart = amountString[amountString.index(after: dotIndex)...]
                    if decimalPart.count >= 2 {
                        return // 最多两位小数
                    }
                }
                amountString += key
            }
        }
    }
    
    /// 保存交易
    private func saveTransaction() {
        guard let amount = Decimal(string: amountString), amount > 0,
        amountString != "0" else {
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
                // 获取默认账户
                guard let defaultAccount = try await repository.getDefaultAccount() else {
                    print("未找到默认账户")
                    isSaving = false
                    return
                }
                
                if let transaction = editingTransaction {
                    // 编辑模式：更新交易
                    var updates = TransactionUpdates()
                    updates.amount = amount
                    updates.category = category
                    updates.note = note.isEmpty ? nil : note
                    
                    try await repository.updateTransaction(transaction, updates: updates)
                } else {
                    // 新增模式：添加交易
                    _ = try await repository.addTransaction(
                        amount: Decimal(string: amountString)!,
                        type: transactionType,
                        category: category,
                        account: defaultAccount,
                        date: Date(),
                        note: note.isEmpty ? nil : note,
                        tags: nil
                    )
                }
                
                // 保存成功，调用回调
                onSave()
                dismiss()
                
            } catch {
                print("保存失败：\(error.localizedDescription)")
            }
            
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
                    
                case "+", "-":
                    Image(systemName: key == "+" ? "plus" : "minus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                    
                default:
                    Text(key)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(key == "✓" ? Color.holoPrimary : (key == "AC" || key == "+" || key == "-" || key == "⌫" ? Color.holoBackground : Color.white))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(key == "✓" && false) // TODO: 添加保存条件判断
    }
}

// MARK: - Preview

#Preview {
    AddTransactionSheet(editingTransaction: nil) {}
}
