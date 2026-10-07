//
//  HoloAmountKeypad.swift
//  Holo
//
//  通用金额计算键盘：5行4列，四则运算表达式 + 两位小数限制。
//  从 AddTransactionSheet 抽出（原 TransactionNumericKeypad），记账/退款等金额输入场景共用。
//

import SwiftUI

// MARK: - 键盘视图

/// 计算键盘：直接读写调用方的金额串（可含 +−×÷ 表达式，如 "100-30"）
/// - onConfirm：✓ 键（调用方负责先求值再保存，与记账页同语义）
/// - onNext：↩︎ 键（记账页=跳名称输入；退款层=收起键盘）
struct HoloAmountKeypad: View {
    @Binding var amountText: String
    var onConfirm: () -> Void
    var onNext: () -> Void

    /// 键盘布局（5行4列，支持四则运算）
    static let layout: [[String]] = [
        ["÷", "×", "-", "+"],
        ["7", "8", "9", "⌫"],
        ["4", "5", "6", "AC"],
        ["1", "2", "3", "↩︎"],
        [".", "0", "00", "✓"]
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.layout, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in
                        KeypadButton(key: key) {
                            handlePress(key)
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    // MARK: - 按键处理

    private func handlePress(_ key: String) {
        // 每次按键即时触觉反馈，确保明确的交互震动
        HapticManager.light()
        switch key {
        case "AC":
            amountText = "0"

        case "⌫":
            if amountText.count > 1 {
                amountText.removeLast()
            } else {
                amountText = "0"
            }

        case "✓":
            onConfirm()

        case "+", "-", "×", "÷":
            handleOperator(key)

        case "↩︎":
            onNext()

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
    private func handleOperator(_ op: String) {
        if amountText == "0" {
            return
        }

        let lastChar = amountText.last
        if ["+", "-", "×", "÷"].contains(lastChar) {
            amountText.removeLast()
        }

        amountText += op
    }

    /// 处理小数点输入
    private func handleDecimalPoint() {
        let operators = ["+", "-", "×", "÷"]
        if let lastOperatorIndex = amountText.lastIndex(where: { operators.contains(String($0)) }) {
            let startIndex = amountText.index(after: lastOperatorIndex)
            let lastNumberPart = String(amountText[startIndex...])
            if lastNumberPart.contains(".") {
                return
            }
        } else {
            if amountText.contains(".") {
                return
            }
        }

        amountText += "."
    }

    /// 处理数字输入（每个操作数最多两位小数）
    private func handleDigit(_ digit: String) {
        if amountText == "0" {
            amountText = digit
            return
        }

        let operators = ["+", "-", "×", "÷"]
        var currentNumberPart = amountText

        if let lastOperatorIndex = amountText.lastIndex(where: { operators.contains(String($0)) }) {
            let startIndex = amountText.index(after: lastOperatorIndex)
            currentNumberPart = String(amountText[startIndex...])
        }

        if let dotIndex = currentNumberPart.firstIndex(of: ".") {
            let decimalPart = currentNumberPart[currentNumberPart.index(after: dotIndex)...]
            if decimalPart.count >= 2 {
                return
            }
        }

        amountText += digit
    }
}

// MARK: - 表达式求值

/// 金额表达式求值 + 两位小数格式化（迁移自 AddTransactionSheet，键盘使用方共用）
enum AmountMath {

    /// 四则运算符（键盘符号形态）
    static let operators = ["×", "÷", "+", "-"]

    /// 是否含运算符（决定要不要求值）
    static func containsOperator(_ text: String) -> Bool {
        operators.contains { text.contains($0) }
    }

    /// 含运算符时求值并格式化为两位小数；不含运算符或求值失败时原样返回
    static func resolve(_ text: String) -> String {
        guard containsOperator(text) else { return text }
        let expression = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        guard let result = evaluate(expression) else { return text }
        return format(Decimal(result))
    }

    /// 解析并计算表达式（支持四则运算，遵循优先级）
    static func evaluate(_ expression: String) -> Double? {
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
    static func format(_ amount: Decimal) -> String {
        let rounded = (amount as NSDecimalNumber).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 2, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return rounded.stringValue
    }
}
