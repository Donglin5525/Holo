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
}
