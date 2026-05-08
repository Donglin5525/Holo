//
//  TransactionSaveHandler.swift
//  Holo
//
//  AddTransactionSheet 保存/删除/复制/表达式计算逻辑
//

import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: "com.holo.app", category: "TransactionSaveHandler")

// MARK: - Save / Delete / Copy

extension AddTransactionSheet {

    /// 保存交易
    func saveTransaction() {
        // 保存前先计算表达式（如果有）
        calculateExpression()

        // 获取金额（取绝对值，因为类型由 transactionType 决定）
        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0" else {
            return
        }

        guard let category = selectedCategory else {
            return
        }

        isSaving = true

        Task {
            do {
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
                    let oldCategory = transaction.category
                    var updates = TransactionUpdates()
                    updates.amount = amount
                    updates.category = category
                    updates.account = account
                    updates.note = note.isEmpty ? nil : note
                    updates.remark = remark.isEmpty ? nil : remark
                    updates.date = selectedDate

                    try await repository.updateTransaction(transaction, updates: updates)

                    learnCategoryMappingIfNeeded(
                        transaction: transaction,
                        oldCategory: oldCategory,
                        newCategory: category
                    )
                } else if isInstallment {
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

                HapticManager.success()
                onSave()
                dismiss()

            } catch {
                logger.error("保存失败：\(error.localizedDescription)")
            }

            isSaving = false
        }
    }

    /// 异步保存交易（用于下拉刷新）
    func saveTransactionAsync() async {
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
                let oldCategory = transaction.category
                var updates = TransactionUpdates()
                updates.amount = amount
                updates.category = category
                updates.account = account
                updates.note = note.isEmpty ? nil : note
                updates.remark = remark.isEmpty ? nil : remark
                updates.date = selectedDate

                try await repository.updateTransaction(transaction, updates: updates)

                learnCategoryMappingIfNeeded(
                    transaction: transaction,
                    oldCategory: oldCategory,
                    newCategory: category
                )
            } else if isInstallment {
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

            await MainActor.run {
                HapticManager.success()
                onSave()
                dismiss()
            }

        } catch {
            logger.error("保存失败：\(error.localizedDescription)")
        }

        await MainActor.run {
            isSaving = false
        }
    }

    /// 删除交易（仅编辑模式）
    func deleteTransaction() {
        guard let transaction = editingTransaction else { return }

        isDeleting = true

        Task {
            do {
                try await repository.deleteTransaction(transaction)
                onSave()
                dismiss()
            } catch {
                logger.error("删除失败：\(error.localizedDescription)")
            }
            isDeleting = false
        }
    }

    /// 从编辑页面复制交易到指定日期
    func performCopyFromEditPage(targetDate: Date) {
        calculateExpression()

        let absoluteAmountString = displayAmountString
        guard let amount = Decimal(string: absoluteAmountString), amount > 0,
              absoluteAmountString != "0",
              let category = selectedCategory else { return }

        Task {
            do {
                let account: Account
                if let selected = selectedAccount {
                    account = selected
                } else if let defaultAcc = try await repository.getDefaultAccount() {
                    account = defaultAcc
                } else {
                    return
                }

                _ = try await repository.addTransaction(
                    amount: amount,
                    type: transactionType,
                    category: category,
                    account: account,
                    date: targetDate,
                    note: note.isEmpty ? nil : note,
                    remark: remark.isEmpty ? nil : remark,
                    tags: editingTransaction?.tags
                )

                HapticManager.success()
                onSave()
            } catch {
                logger.error("复制交易失败: \(error)")
            }
        }
    }
}

// MARK: - 表达式计算

extension AddTransactionSheet {

    /// 计算表达式结果
    /// 支持四则运算：+、-、×、÷，遵循运算优先级（先乘除后加减）
    func calculateExpression() {
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

        var expression = amountString
        expression = expression.replacingOccurrences(of: "×", with: "*")
        expression = expression.replacingOccurrences(of: "÷", with: "/")

        if let result = evaluateExpression(expression) {
            let formatted = formatAmount(Decimal(result))
            amountString = formatted
        } else {
            logger.error("表达式计算失败: \(expression)")
        }
    }

    /// 解析并计算表达式（支持四则运算，遵循优先级）
    func evaluateExpression(_ expression: String) -> Double? {
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

        if tokens.isEmpty {
            return nil
        }

        // 第一遍：处理乘除
        var processedTokens = tokens
        var i = 0
        while i < processedTokens.count {
            let token = processedTokens[i]
            if token == "*" || token == "/" {
                guard i > 0, i < processedTokens.count - 1 else { return nil }
                guard let left = Double(processedTokens[i - 1]),
                      let right = Double(processedTokens[i + 1]) else { return nil }

                let result: Double
                if token == "*" {
                    result = left * right
                } else {
                    guard right != 0 else { return nil }
                    result = left / right
                }

                processedTokens.replaceSubrange(i - 1...i + 1, with: [String(result)])
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

    /// 格式化金额：四舍五入到2位小数
    func formatAmount(_ amount: Decimal) -> String {
        let rounded = (amount as NSDecimalNumber).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 2, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return rounded.stringValue
    }

    /// 当用户将「待确认」交易改为具体分类时，学习映射关系
    func learnCategoryMappingIfNeeded(
        transaction: Transaction,
        oldCategory: Category?,
        newCategory: Category
    ) {
        guard let oldCategory = oldCategory,
              oldCategory.name == "待确认",
              newCategory.name != "待确认",
              let candidateInfo = CategoryLearnedMapping.lookupTransactionCandidate(
                  transactionId: transaction.id
              ) else { return }

        CategoryLearnedMapping.record(
            candidate: candidateInfo.candidate,
            type: candidateInfo.type,
            targetPrimary: newCategory.name,
            targetSub: newCategory.name
        )
        CategoryLearnedMapping.removeTransactionCandidate(transactionId: transaction.id)
    }
}
