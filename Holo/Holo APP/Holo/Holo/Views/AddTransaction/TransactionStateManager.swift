//
//  TransactionStateManager.swift
//  Holo
//
//  AddTransactionSheet 状态管理 — 数据加载、计算属性、快捷标签
//

import SwiftUI

// MARK: - 数据加载

extension AddTransactionSheet {

    /// 从交易填充数据（编辑模式）
    func populateFromTransaction(_ transaction: Transaction) {
        transactionType = transaction.transactionType
        let absoluteAmount = abs(transaction.amount.decimalValue)
        amountString = formatAmount(absoluteAmount)
        selectedCategory = transaction.category
        selectedAccount = transaction.account
        note = InstallmentNoteSanitizer.clean(transaction.note) ?? ""
        remark = transaction.remark ?? ""
        selectedDate = transaction.date

        // 分期状态初始化
        if transaction.isInstallment {
            isInstallment = true
            installmentPeriods = max(Int(transaction.installmentTotal), 2)
            // 无法从存储数据恢复原始手续费，默认 0
        }
    }

    /// 加载默认/上次选择的账户（新增模式）
    func loadDefaultAccount() {
        if let lastId = lastSelectedAccountId,
           let uuid = UUID(uuidString: lastId) {
            let accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
            if let matched = accounts.first(where: { $0.id == uuid }) {
                selectedAccount = matched
                return
            }
        }
        selectedAccount = FinanceRepository.shared.getDefaultAccountSync()
    }

    /// 启动光标闪烁动画
    func startCursorAnimation() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            cursorOpacity = 0
        }
    }
}

// MARK: - 快捷标签

extension AddTransactionSheet {

    /// 加载快捷标签数据（科目为 nil 时查询所有科目）
    func loadQuickTags(for category: Category?) {
        let repo = FinanceRepository.shared
        var newTags: [QuickTagItem] = []

        let amounts = repo.getHistoricalAmounts(for: category)
        for item in amounts {
            let formatted = repo.formatAmountTag(item.amount)
            newTags.append(QuickTagItem(value: formatted, kind: .amount, frequency: item.frequency))
        }

        let notes = repo.getHistoricalNotes(for: category)
        for item in notes {
            newTags.append(QuickTagItem(value: item.note, kind: .note, frequency: item.frequency))
        }

        newTags.sort { $0.frequency > $1.frequency }
        quickTags = Array(newTags.prefix(10))
    }

    /// 处理快捷标签点击
    func handleQuickTagTap(value: String, kind: QuickTagKind) {
        switch kind {
        case .amount:
            let numericString = value.replacingOccurrences(of: ",", with: "")
            if Decimal(string: numericString) != nil {
                amountString = numericString
            }
            showNumericKeypad = true
        case .note:
            note = value
            isNoteFocused = true
        }
    }
}
