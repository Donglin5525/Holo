//
//  DailySummary.swift
//  Holo
//
//  单日收支汇总 - 月历视图专用的内存层聚合数据结构
//

import Foundation

/// 单日收支汇总
struct DailySummary: Identifiable {
    var id: Date { date }
    let date: Date
    let totalExpense: Decimal
    let totalIncome: Decimal
    let transactionCount: Int
    
    var hasTransactions: Bool { transactionCount > 0 }
    
    /// 无交易的空汇总
    static func empty(for date: Date) -> DailySummary {
        DailySummary(date: date, totalExpense: 0, totalIncome: 0, transactionCount: 0)
    }
}
