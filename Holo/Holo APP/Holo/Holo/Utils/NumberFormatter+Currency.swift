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

    /// 去尾零货币格式化器（通知文案用）：¥15 / ¥15.5 / ¥1,234.56
    static let currencyTrimmed: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// 紧凑货币格式化（万/亿单位），用于空间受限场景
    /// - ¥9,999.00 → ¥9,999.00（万元以下保持原样）
    /// - ¥100,000.00 → ¥10.0万
    /// - ¥100,000,000.00 → ¥1.00亿
    nonisolated static func compactCurrency(_ amount: Decimal) -> String {
        let absAmount = abs(amount)
        let tenThousand: Decimal = 10_000
        let hundredMillion: Decimal = 100_000_000

        if absAmount >= hundredMillion {
            let value = NSDecimalNumber(decimal: amount / hundredMillion).doubleValue
            return String(format: String(localized: "¥%.2f亿"), value)
        } else if absAmount >= tenThousand {
            let value = NSDecimalNumber(decimal: amount / tenThousand).doubleValue
            return String(format: String(localized: "¥%.1f万"), value)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "CNY"
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: amount as NSDecimalNumber) ?? "¥0.00"
        }
    }

    /// 紧凑刻度数值（图表轴刻度用，不带货币符号）：万 / 千 / 整数三档。
    /// 万 / 千不能固守一位小数——中档刻度常是轴上限的一半（2.5万图的 1.25万），
    /// %.1f 会写成「1.2万」，和顶格「2.5万」同图对不上账；按需保留到两位再裁尾零
    /// - 12,500 → 1.25万
    /// - 25,000 → 2.5万
    /// - 1,500 → 1.5千
    /// - 800 → 800
    nonisolated static func compactAxisAmount(_ value: Double) -> String {
        if abs(value) < 1 { return value == 0 ? "0" : "" }
        let absValue = abs(value)
        if absValue >= 10_000 {
            return String(format: String(localized: "%@万"), trimmedAmountText(value / 10_000))
        } else if absValue >= 1_000 {
            return String(format: String(localized: "%@千"), trimmedAmountText(value / 1_000))
        }
        return String(format: "%.0f", value)
    }

    /// 1.25 → "1.25"、1.5 → "1.5"、2 → "2"（按两位小数四舍五入后裁掉尾零）
    private nonisolated static func trimmedAmountText(_ scaled: Double) -> String {
        let rounded = (scaled * 100).rounded() / 100
        if rounded == 0 { return "0" }
        if rounded.rounded() == rounded { return String(format: "%.0f", rounded) }
        if (rounded * 10).rounded() == rounded * 10 { return String(format: "%.1f", rounded) }
        return String(format: "%.2f", rounded)
    }
}
