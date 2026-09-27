//
//  TransactionNumericKeypad.swift
//  Holo
//
//  AddTransactionSheet 数字键盘：通用组件薄壳（键盘本体与求值见 HoloAmountKeypad）
//

import SwiftUI

// MARK: - 键盘视图

extension AddTransactionSheet {

    /// 数字键盘：✓ = 求值并保存；↩︎ = 收键盘跳名称输入
    var numericKeypad: some View {
        HoloAmountKeypad(
            amountText: $amountString,
            onConfirm: {
                calculateExpression()
                saveTransaction()
            },
            onNext: {
                showNumericKeypad = false
                isNoteFocused = true
            }
        )
    }

}
