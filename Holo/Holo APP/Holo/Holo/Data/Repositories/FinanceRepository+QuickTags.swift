//
//  FinanceRepository+QuickTags.swift
//  Holo
//
//  智能快捷标签数据查询
//  按科目查询历史金额和名称，用于 Quick Tag Bar 展示
//

import Foundation
import CoreData

// MARK: - Quick Tag Types

/// 快捷标签类型
enum QuickTagKind {
    case amount
    case note
}

/// 快捷标签数据项
struct QuickTagItem: Identifiable, Equatable {
    let id = UUID()
    let value: String
    let kind: QuickTagKind
    let frequency: Int

    static func == (lhs: QuickTagItem, rhs: QuickTagItem) -> Bool {
        lhs.value == rhs.value && lhs.kind == rhs.kind
    }
}

// MARK: - Repository Extension

extension FinanceRepository {

    /// 查询历史不同金额值
    /// - Parameters:
    ///   - category: 目标科目，nil 时查询所有科目
    ///   - limit: 最多返回多少个不同金额，默认 6
    /// - Returns: 按（频次降序, 金额降序）排序的 (金额, 频次) 数组
    func getHistoricalAmounts(
        for category: Category?,
        limit: Int = 6
    ) -> [(amount: Decimal, frequency: Int)] {
        let request = Transaction.fetchRequest()
        if let category = category {
            request.predicate = NSPredicate(format: "category == %@", category)
        }

        guard let transactions = try? context.fetch(request) else {
            return []
        }

        var frequencyMap: [Decimal: Int] = [:]
        for tx in transactions {
            let decimal = tx.amount.decimalValue
            let rounded = (decimal as NSDecimalNumber).rounding(
                accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain,
                    scale: 2,
                    raiseOnExactness: false,
                    raiseOnOverflow: false,
                    raiseOnUnderflow: false,
                    raiseOnDivideByZero: false
                )
            ).decimalValue
            frequencyMap[rounded, default: 0] += 1
        }

        return frequencyMap
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key > rhs.key
            }
            .prefix(limit)
            .map { (amount: $0.key, frequency: $0.value) }
    }

    /// 查询历史不同名称值
    /// - Parameters:
    ///   - category: 目标科目，nil 时查询所有科目
    ///   - limit: 最多返回多少个不同名称，默认 6
    /// - Returns: 按频次降序排序的 (名称, 频次) 数组
    func getHistoricalNotes(
        for category: Category?,
        limit: Int = 6
    ) -> [(note: String, frequency: Int)] {
        let request = Transaction.fetchRequest()
        if let category = category {
            request.predicate = NSPredicate(
                format: "category == %@ AND note != nil AND note != ''",
                category
            )
        } else {
            request.predicate = NSPredicate(format: "note != nil AND note != ''")
        }

        guard let transactions = try? context.fetch(request) else {
            return []
        }

        var frequencyMap: [String: Int] = [:]
        for tx in transactions {
            guard let noteValue = tx.note?.trimmingCharacters(in: .whitespaces),
                  !noteValue.isEmpty else { continue }
            frequencyMap[noteValue, default: 0] += 1
        }

        return frequencyMap
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (note: $0.key, frequency: $0.value) }
    }

    /// 格式化金额为标签显示文本（整数或最多2位小数，不带 ¥）
    func formatAmountTag(_ amount: Decimal) -> String {
        let rounded = (amount as NSDecimalNumber).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 2,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        let stringValue = rounded.stringValue
        if stringValue.hasSuffix(".00") {
            return String(stringValue.dropLast(3))
        }
        if stringValue.hasSuffix("0") && stringValue.contains(".") {
            return String(stringValue.dropLast())
        }
        return stringValue
    }
}
