//
//  TransactionNumericKeypad.swift
//  Holo
//
//  AddTransactionSheet 数字键盘视图 + 按键处理逻辑
//

import SwiftUI

// MARK: - 键盘视图

extension AddTransactionSheet {

    /// 数字键盘
    var numericKeypad: some View {
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
        .background(Color.holoCardBackground)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: -4)
    }

}

// MARK: - 按键处理

extension AddTransactionSheet {

    /// 处理键盘按键
    func handleKeypadPress(_ key: String) {
        switch key {
        case "AC":
            amountString = "0"

        case "⌫":
            if amountString.count > 1 {
                amountString.removeLast()
            } else {
                amountString = "0"
            }

        case "✓":
            calculateExpression()
            saveTransaction()

        case "+", "-", "×", "÷":
            handleOperator(key)

        case "↩︎":
            showNumericKeypad = false
            isNoteFocused = true

        case ".":
            handleDecimalPoint()

        case "00":
            handleDigit("0")
            handleDigit("0")

        default:
            handleDigit(key)
        }
    }

    /// 处理运算符输入
    func handleOperator(_ op: String) {
        if amountString == "0" {
            return
        }

        let lastChar = amountString.last
        if ["+", "-", "×", "÷"].contains(lastChar) {
            amountString.removeLast()
        }

        amountString += op
    }

    /// 处理小数点输入
    func handleDecimalPoint() {
        let operators = ["+", "-", "×", "÷"]
        if let lastOperatorIndex = amountString.lastIndex(where: { operators.contains(String($0)) }) {
            let startIndex = amountString.index(after: lastOperatorIndex)
            let lastNumberPart = String(amountString[startIndex...])
            if lastNumberPart.contains(".") {
                return
            }
        } else {
            if amountString.contains(".") {
                return
            }
        }

        amountString += "."
    }

    /// 处理数字输入
    func handleDigit(_ digit: String) {
        if amountString == "0" {
            amountString = digit
            return
        }

        let operators = ["+", "-", "×", "÷"]
        var currentNumberPart = amountString

        if let lastOperatorIndex = amountString.lastIndex(where: { operators.contains(String($0)) }) {
            let startIndex = amountString.index(after: lastOperatorIndex)
            currentNumberPart = String(amountString[startIndex...])
        }

        if let dotIndex = currentNumberPart.firstIndex(of: ".") {
            let decimalPart = currentNumberPart[currentNumberPart.index(after: dotIndex)...]
            if decimalPart.count >= 2 {
                return
            }
        }

        amountString += digit
    }
}
