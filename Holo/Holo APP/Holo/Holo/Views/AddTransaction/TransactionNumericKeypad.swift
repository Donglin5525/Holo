//
//  TransactionNumericKeypad.swift
//  Holo
//
//  AddTransactionSheet 数字键盘：通用组件薄壳（键盘本体与求值见 HoloAmountKeypad）
//

import SwiftUI

// MARK: - 键盘视图

extension AddTransactionSheet {

    /// 数字键盘：✓ = 算式求值成结果 / 纯数字确认保存（两段式见 HoloAmountKeypad）；↩︎ = 收键盘跳名称输入
    var numericKeypad: some View {
        HoloAmountKeypad(
            amountText: $amountString,
            onConfirm: {
                saveTransaction()
            },
            onNext: {
                showNumericKeypad = false
                isNoteFocused = true
            }
        )
    }

}
