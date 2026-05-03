//
//  FinanceAggregation.swift
//  Holo
//
//  财务分析模块的聚合数据模型
//  包含图表数据点、分类聚合、周期汇总等
//

import Foundation
import SwiftUI

// MARK: - 时间范围枚举

/// 时间范围选择
enum TimeRange: String, CaseIterable, Identifiable {
    case day = "日"
    case week = "周"
    case month = "月"
    case quarter = "季度"
    case year = "年"
    case custom = "自定义"

    var id: String { rawValue }

    /// 时间范围的图标
    var icon: String? {
        switch self {
        case .day: return "sun.max.fill"
        case .week: return "calendar.badge.clock"
        case .month: return "calendar"
        case .quarter: return "calendar.circle"
        case .year: return "calendar.badge.plus"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// 计算时间范围的起止日期
    func dateRange() -> (start: Date, end: Date) {
        let now = Date()
        let calendar = Calendar.current

        switch self {
        case .day:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                return (start, now)
            }
            return (start, end)

        case .week:
            let start = now.startOfWeek
            guard let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                return (start, now)
            }
            return (start, end)

        case .month:
            let start = now.startOfMonth
            guard let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                return (start, now)
            }
            return (start, end)

        case .quarter:
            let month = calendar.component(.month, from: now)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: now)
            components.month = quarterStartMonth
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .month, value: 3, to: start) else {
                return (now.startOfMonth, now)
            }
            return (start, end)

        case .year:
            var components = calendar.dateComponents([.year], from: now)
            components.month = 1
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else {
                return (now.startOfMonth, now)
            }
            return (start, end)

        case .custom:
            return (now.startOfMonth, now)
        }
    }
}

// MARK: - X 轴粒度

/// 图表 X 轴粒度（根据时间跨度自动切换）
enum ChartGranularity {
    case hour    // <= 1 天
    case day     // 2-14 天
    case week    // 15-90 天
    case month   // > 90 天

    /// 根据天数判断粒度
    static func from(dayCount: Int) -> ChartGranularity {
        if dayCount <= 1 { return .hour }
        if dayCount <= 14 { return .day }
        if dayCount <= 90 { return .week }
        return .month
    }
}

// MARK: - 图表数据点

/// 图表数据点（用于柱状图和折线图）
struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let label: String           // X 轴标签
    let expense: Decimal
    let income: Decimal
    let transactionCount: Int
    var balance: Decimal = 0    // 累计余额（净收入累计值）

    /// 净收入（收入 - 支出）
    var netIncome: Decimal { income - expense }

    /// 是否有交易
    var hasTransactions: Bool { transactionCount > 0 }
}

// MARK: - 图表触摸命中

/// Swift Charts 的坐标读取以 plot area 为基准，触摸点也必须先换算到同一坐标系。
struct ChartTouchSelection {
    static func nearestPointIndex(
        touchXInPlot: CGFloat,
        plotWidth: CGFloat,
        pointXPositions: [CGFloat]
    ) -> Int? {
        guard plotWidth > 0, !pointXPositions.isEmpty else { return nil }

        let maxSnapDistance = plotWidth / CGFloat(pointXPositions.count) * 0.6
        var closestIndex: Int?
        var closestDistance = CGFloat.infinity

        for (index, pointX) in pointXPositions.enumerated() {
            let distance = abs(touchXInPlot - pointX)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        guard closestDistance <= maxSnapDistance else { return nil }
        return closestIndex
    }
}

// MARK: - 余额趋势坐标缩放

/// 将余额趋势映射到收入/支出金额轴，供单个图表叠加展示双刻度使用。
struct BalanceChartScale {
    let amountAxisMin: Double
    let amountAxisMax: Double
    let balanceAxisMin: Double
    let balanceAxisMax: Double

    init(amountValues: [Double], balanceValues: [Double]) {
        let maxAmount = amountValues.map(abs).max() ?? 0
        amountAxisMin = 0
        amountAxisMax = max(maxAmount * 1.15, 1)

        let minBalance = balanceValues.min() ?? 0
        let maxBalance = balanceValues.max() ?? 0

        if minBalance == maxBalance {
            balanceAxisMin = min(0, minBalance)
            balanceAxisMax = max(1, maxBalance)
        } else {
            balanceAxisMin = minBalance
            balanceAxisMax = maxBalance
        }
    }

    func scaledBalance(_ balance: Double) -> Double {
        let balanceRange = balanceAxisMax - balanceAxisMin
        guard balanceRange > 0 else { return amountAxisMin }

        let normalized = (balance - balanceAxisMin) / balanceRange
        return amountAxisMin + normalized * (amountAxisMax - amountAxisMin)
    }

    func balanceValue(forScaledAmount scaledAmount: Double) -> Double {
        let amountRange = amountAxisMax - amountAxisMin
        guard amountRange > 0 else { return balanceAxisMin }

        let normalized = (scaledAmount - amountAxisMin) / amountRange
        return balanceAxisMin + normalized * (balanceAxisMax - balanceAxisMin)
    }
}

// MARK: - 分类聚合

/// 分类聚合数据（用于饼图和 TOP3 卡片）
struct CategoryAggregation: Identifiable {
    let id = UUID()
    let category: Category
    let amount: Decimal
    let percentage: Double      // 占比百分比 (0-100)
    let transactionCount: Int

    /// 格式化金额
    var formattedAmount: String {
        NumberFormatter.currency.string(from: amount as NSDecimalNumber) ?? "¥0.00"
    }

    /// 紧凑格式化金额（用于空间受限场景，自动使用万/亿单位）
    var formattedCompactAmount: String {
        NumberFormatter.compactCurrency(amount)
    }

    /// 格式化占比
    var formattedPercentage: String {
        String(format: "%.1f%%", percentage)
    }
}

// MARK: - 周期汇总

/// 周期汇总数据（用于概览统计）
struct PeriodSummary {
    let totalExpense: Decimal
    let totalIncome: Decimal
    let transactionCount: Int
    let averageDailyExpense: Decimal
    let averageDailyIncome: Decimal
    let dayCount: Int

    /// 净收入
    var netIncome: Decimal { totalIncome - totalExpense }

    /// 格式化支出
    var formattedExpense: String {
        NumberFormatter.currency.string(from: totalExpense as NSDecimalNumber) ?? "¥0.00"
    }

    /// 格式化收入
    var formattedIncome: String {
        NumberFormatter.currency.string(from: totalIncome as NSDecimalNumber) ?? "¥0.00"
    }

    /// 格式化净收入
    var formattedNetIncome: String {
        let prefix = netIncome >= 0 ? "+" : ""
        return prefix + (NumberFormatter.currency.string(from: netIncome as NSDecimalNumber) ?? "¥0.00")
    }

    /// 空汇总
    static func empty(dayCount: Int = 1) -> PeriodSummary {
        PeriodSummary(
            totalExpense: 0,
            totalIncome: 0,
            transactionCount: 0,
            averageDailyExpense: 0,
            averageDailyIncome: 0,
            dayCount: dayCount
        )
    }
}
