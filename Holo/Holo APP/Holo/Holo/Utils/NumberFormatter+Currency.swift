//
//  NumberFormatter+Currency.swift
//  Holo
//
//  NumberFormatter 扩展 - 货币格式化
//

import Foundation

extension NumberFormatter {
    /// 人民币货币格式化器
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// 紧凑货币格式化（万/亿单位），用于空间受限场景
    /// - ¥9,999.00 → ¥9,999.00（万元以下保持原样）
    /// - ¥100,000.00 → ¥10.0万
    /// - ¥100,000,000.00 → ¥1.00亿
    static func compactCurrency(_ amount: Decimal) -> String {
        let absAmount = abs(amount)
        let tenThousand: Decimal = 10_000
        let hundredMillion: Decimal = 100_000_000

        if absAmount >= hundredMillion {
            let value = NSDecimalNumber(decimal: amount / hundredMillion).doubleValue
            return String(format: "¥%.2f亿", value)
        } else if absAmount >= tenThousand {
            let value = NSDecimalNumber(decimal: amount / tenThousand).doubleValue
            return String(format: "¥%.1f万", value)
        } else {
            return currency.string(from: amount as NSDecimalNumber) ?? "¥0.00"
        }
    }
}
