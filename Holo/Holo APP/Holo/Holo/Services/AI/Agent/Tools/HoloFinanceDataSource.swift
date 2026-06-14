//
//  HoloFinanceDataSource.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task #34 生产财务数据源
//  包裹真实 FinanceRepository，聚合本期/基线消费（晚间餐饮频次 / 分类次数 / 金额），
//  转为 FinanceTool 中性结构。依赖 Core Data，仅随 app 编译，不进入 standalone 测试。
//

import Foundation

struct HoloDefaultFinanceDataSource: HoloFinanceDataSource {

    func snapshot(timeRange: HoloAgentTimeRange?, baseline: HoloAgentTimeRange?) async -> HoloFinanceToolRecord? {
        let repo = FinanceRepository.shared
        let calendar = Calendar.current
        let today = timeRange?.end ?? calendar.startOfDay(for: Date())
        let currentStart = timeRange?.start ?? (calendar.date(byAdding: .day, value: -13, to: today) ?? today)
        let baselineEnd = baseline?.end ?? (calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart)
        let baselineStart = baseline?.start ?? (calendar.date(byAdding: .day, value: -13, to: baselineEnd) ?? baselineEnd)
        let current: [Transaction]
        let baseline: [Transaction]
        do {
            current = try await repo.getTransactions(from: currentStart, to: today)
            baseline = try await repo.getTransactions(from: baselineStart, to: baselineEnd)
        } catch {
            return nil
        }
        return HoloFinanceToolRecord(
            nighttimeMealCurrent: Self.nighttimeMealCount(current),
            nighttimeMealBaseline: Self.nighttimeMealCount(baseline),
            categoryCounts: Self.categoryCounts(current),
            totalCurrentAmount: Self.totalExpense(current),
            totalBaselineAmount: Self.totalExpense(baseline)
        )
    }

    /// 晚间（22:00–06:00）餐饮类支出笔数。
    private static func nighttimeMealCount(_ txs: [Transaction]) -> Int {
        let mealKeywords = ["餐", "食", "吃", "外卖", "宵夜", "饭", "饮"]
        let calendar = Calendar.current
        return txs.filter { tx in
            guard tx.transactionType == .expense else { return false }
            let hour = calendar.component(.hour, from: tx.date)
            let isNighttime = hour >= 22 || hour < 6
            let name = tx.category?.name ?? ""
            return isNighttime && mealKeywords.contains { name.contains($0) }
        }.count
    }

    /// 本期各分类支出笔数。
    private static func categoryCounts(_ txs: [Transaction]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tx in txs where tx.transactionType == .expense {
            let name = tx.category?.name ?? "未分类"
            counts[name, default: 0] += 1
        }
        return counts
    }

    private static func totalExpense(_ txs: [Transaction]) -> Double {
        txs.filter { $0.transactionType == .expense }.reduce(0.0) { $0 + $1.amount.doubleValue }
    }
}
