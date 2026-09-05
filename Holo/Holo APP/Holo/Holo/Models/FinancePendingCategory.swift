//
//  FinancePendingCategory.swift
//  Holo
//
//  Shared naming for finance transactions that cannot be matched confidently.
//

import Foundation

nonisolated enum FinancePendingCategory {
    /// 兜底分类的落库名：按当前 App 语言取三语词表（待分类 / 待分類 / Uncategorized）。
    /// 行种下后即为用户数据，不随系统语言切换重写。
    static var currentName: String { FinanceSeedVocabulary.pending.currentValue }
    /// 历史版本的落库名，仅用于识别/迁移老数据（当年的行就叫「待确认」），永不变更
    static let legacyName = "待确认"
}
