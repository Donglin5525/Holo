//
//  HoloQueryRowFormatter.swift
//  Holo
//
//  把 HoloQueryRow 格式化为用户可读的简短摘要，用于数据样本透明展示。
//

import Foundation

nonisolated enum HoloQueryRowFormatter {
    /// 把一行查询数据格式化为简短描述（如「7月16日 购物 烟 -¥230」）。
    static func summary(_ row: HoloQueryRow) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let dateText = formatter.string(from: row.occurredAt)

        let category = row.fields["category"]?.textValue
        let note = row.fields["text"]?.textValue
        let amount = row.fields["amount"]?.numberValue

        var parts: [String] = [dateText]
        if let category, !category.isEmpty { parts.append(category) }
        if let note, !note.isEmpty { parts.append(note) }
        if let amount {
            let amountText = amount.rounded() == amount
                ? String(format: "%.0f", amount)
                : String(format: "%.2f", amount)
            parts.append("-¥\(amountText)")
        }
        return parts.joined(separator: " ")
    }
}
