//
//  FinanceAggregation.swift
//  Holo
//
//  财务分析模块的聚合数据模型
//  包含图表数据点、分类聚合、周期汇总等
//

import Foundation
import SwiftUI

// MARK: - 年度口径

/// 年档统计口径：自然年（1/1–12/31）或记账年（跟随全局记账起始日）。
/// 记账起始日为 1 号时两者等价，统计页不提供切换（低频选项收在区间弹层内）。
enum FinanceYearBasis: String, CaseIterable, Identifiable {
    case calendar   // 自然年
    case billing    // 记账年

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calendar: return String(localized: "自然年")
        case .billing: return String(localized: "记账年")
        }
    }

    /// 同比基准的称呼（汇总卡 badge / 对照卡标题用）
    var previousYearLabel: String {
        switch self {
        case .calendar: return String(localized: "去年同期")
        case .billing: return String(localized: "上一个记账年")
        }
    }

    /// 弹层选项的说明小字
    var subtitle: String {
        switch self {
        case .calendar: return String(localized: "1月1日 – 12月31日 · 对外总结常用")
        case .billing: return String(localized: "跟随记账起始日 · 与月档同一把尺，月加总 = 年")
        }
    }

    // MARK: 持久化（口径选择记忆到下次进入）

    private static let storageKey = "financeYearBasis"

    static func loadDefault() -> FinanceYearBasis {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return FinanceYearBasis(rawValue: raw ?? "") ?? .billing
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

// MARK: - 时间范围枚举

/// 时间范围选择
enum TimeRange: String, CaseIterable, Identifiable {
    case day = "day"
    case week = "week"
    case month = "month"
    case quarter = "quarter"
    case year = "year"
    case custom = "custom"

    var id: String { rawValue }

    /// 显示名称（rawValue 仅作标识，不落库不传输，显示一律走 displayName）
    var displayName: String {
        switch self {
        case .day: return String(localized: "日")
        case .week: return String(localized: "周")
        case .month: return String(localized: "月")
        case .quarter: return String(localized: "季度")
        case .year: return String(localized: "年")
        case .custom: return String(localized: "自定义")
        }
    }

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
            // 按全局记账周期起始日计算（startDay=1 时等价于自然月）
            let range = FinancePeriodSettings.shared.currentCycleRange(reference: now)
            return range

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

    /// 年档区间按口径计算：自然年 = 1/1–12/31；记账年 = 跟随全局记账起始日
    ///（起始日为 1 时两种口径等价）。dateRange() 的 .year 始终是自然年，
    /// AI/分析上下文等既有链路行为不变；口径切换只作用于统计页年档。
    func yearDateRange(basis: FinanceYearBasis) -> (start: Date, end: Date) {
        switch basis {
        case .calendar:
            return dateRange()
        case .billing:
            return BillingCycleCalculator.billingYearRange(
                startDay: FinancePeriodSettings.storedBillingCycleStartDay
            )
        }
    }

    // MARK: 胶囊短文案

    /// 统计页顶部胶囊短文案（最小信息原则：年/季只标档位语义，其余标日期区间；end 为开区间）。
    /// 年档中文环境模板 "y" 自带「年」字（输出 2026年），不可再手拼后缀。
    static func pillLabel(timeRange: TimeRange, start: Date, end: Date) -> String {
        let df = DateFormatter()
        switch timeRange {
        case .year:
            df.setLocalizedDateFormatFromTemplate("y")
            return df.string(from: start)
        case .quarter:
            let calendar = Calendar.current
            // 年份先转 String：LocalizationValue 直接插 Int 会被数字本地化格式化成「2,025」
            let year = String(calendar.component(.year, from: start))
            let quarter = (calendar.component(.month, from: start) - 1) / 3 + 1
            return String(localized: "\(year)年第\(quarter)季度")
        default:
            df.setLocalizedDateFormatFromTemplate("MMMd")
            let startStr = df.string(from: start)
            let endStr = df.string(from: end.addingDays(-1)) // end 是开区间，显示前一天
            return "\(startStr) - \(endStr)"
        }
    }
}

// MARK: - X 轴粒度

/// 图表 X 轴粒度（根据时间跨度自动切换）
enum ChartGranularity {
    case hour    // 预留：按小时（当前 from 不会返回，单天改按天呈现，避免满图空柱）
    case day     // 1-31 天
    case week    // 32-90 天
    case month   // > 90 天

    /// 根据天数判断粒度
    static func from(dayCount: Int) -> ChartGranularity {
        // 单天也按天呈现：财务分析不需要把一天拆成 24 小时（否则得到满图空柱）
        // ≤31 天按天：与明细页趋势图同一画法，避免「月总览一根周桶柱、明细两根日柱」的分裂
        if dayCount <= 31 { return .day }
        if dayCount <= 90 { return .week }
        return .month
    }
}

// MARK: - 触摸态日期标注

/// 触摸态 tooltip 的日期行：按数据点间距自适应粒度
/// 日粒度（间距1天）→「9月1日 周二」；周粒度（间距7天）→「9月1日 当周」；月粒度（间距约30天）→「2026年9月」
enum ChartTooltipDateLabel {
    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 EEE"
        return df
    }()

    private static let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月"
        return df
    }()

    static func string(for point: ChartDataPoint, points: [ChartDataPoint]) -> String {
        guard points.count > 1 else { return dayFormatter.string(from: point.date) }
        let spacing = points[1].date.timeIntervalSince(points[0].date)
        if spacing < 1.5 * 86400 { return dayFormatter.string(from: point.date) }
        if spacing < 1.5 * 7 * 86400 { return dayFormatter.string(from: point.date) + String(localized: " 当周") }
        return monthFormatter.string(from: point.date)
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

// MARK: - 饼图交互样式

struct PieChartInteractionStyle {
    static func sectorOpacity(isFocused _: Bool, hasFocusedCategory _: Bool) -> Double {
        1.0
    }

    static func labelOpacity(isFocused _: Bool, hasFocusedCategory _: Bool) -> Double {
        1.0
    }

    static func shouldTrackHighlight(translation: CGSize) -> Bool {
        guard translation.width != 0 || translation.height != 0 else { return true }
        var lock = HorizontalGestureLock()
        return lock.update(translation: translation) != .vertical
    }

    static func sectorInsetAngle(spanAngle: Double, preferredInset: Double) -> Double {
        guard spanAngle > 0, preferredInset > 0 else { return 0 }
        return min(preferredInset, spanAngle * 0.45)
    }
}

struct FinanceCategoryChartColor {
    static func shouldUseChartPaletteForCategoryAnalysis() -> Bool {
        true
    }

    static func shouldUseChartPalette(hex: String) -> Bool {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "#64748B" || normalized == "#6B7280" || normalized == "#9CA3AF"
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

        // 余额轴始终包含 0：全为正数时保留“从零开始”的金额语义，
        // 全为负数时也保留零基线，避免最低/最高余额被误画成满幅波动。
        balanceAxisMin = min(0, minBalance)
        balanceAxisMax = max(1, maxBalance)
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

// MARK: - 财务图表轴刻度

struct FinanceChartAxisTicks {
    static let overviewTickCount = 5

    static func amountTicks(min: Double, max: Double) -> [Double] {
        evenlySpacedTicks(min: min, max: max, count: overviewTickCount)
    }

    static func balanceTicks(for scale: BalanceChartScale) -> [(balance: Double, scaledAmount: Double)] {
        evenlySpacedTicks(
            min: scale.balanceAxisMin,
            max: scale.balanceAxisMax,
            count: overviewTickCount
        ).map { balance in
            (balance: balance, scaledAmount: scale.scaledBalance(balance))
        }
    }

    private static func evenlySpacedTicks(min: Double, max: Double, count: Int) -> [Double] {
        guard count > 1 else { return [min] }
        guard max > min else { return Array(repeating: min, count: count) }

        let step = (max - min) / Double(count - 1)
        return (0..<count).map { min + step * Double($0) }
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

// MARK: - 账户聚合

/// 账户维度聚合数据（统计页「本期账户排行」卡）
struct AccountAggregation: Identifiable {
    let id = UUID()
    let account: Account
    let expense: Decimal
    let income: Decimal
    let percentage: Double      // 支出占总支出比 (0-100)
    let transactionCount: Int

    var formattedExpense: String {
        NumberFormatter.currency.string(from: expense as NSDecimalNumber) ?? "¥0.00"
    }

    var formattedCompactExpense: String {
        NumberFormatter.compactCurrency(expense)
    }
}

// MARK: - 财务项目聚合

/// 项目维度聚合数据（统计页「项目」页签列表；项目=一件事的资金全景，收支同权）
struct FinanceProjectAggregation: Identifiable {
    let id = UUID()
    let project: FinanceProject
    /// 支出侧合计（statisticsAmount 口径：退款负冲在内）
    let expense: Decimal
    /// 收入侧合计（非退款收入）
    let income: Decimal
    let percentage: Double      // 支出占总支出比 (0-100)
    let transactionCount: Int

    /// 净投入 = 支出 − 收入（负值即项目回血超过投入）
    var netAmount: Decimal { expense - income }

    /// 项目预算（未设置为 nil，UI 不显示进度）
    var budget: Decimal? { project.budgetDecimal }

    /// 预算使用进度 (0-1，可超 1)；预算只约束支出
    var budgetProgress: Double? {
        guard let budget, budget > 0 else { return nil }
        return Double(truncating: (expense / budget) as NSDecimalNumber)
    }

    var formattedCompactExpense: String {
        NumberFormatter.compactCurrency(expense)
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
    /// 已过周期数（月/账期桶，年视图月均口径用；0 = 未提供，UI 回退日均）
    var elapsedPeriodCount: Int = 0

    /// 净收入
    var netIncome: Decimal { totalIncome - totalExpense }

    /// 月均支出（年视图口径：总额 ÷ 已过周期数，进行中的一期也计入）
    var averageMonthlyExpense: Decimal {
        totalExpense / Decimal(max(elapsedPeriodCount, 1))
    }

    /// 月均收入
    var averageMonthlyIncome: Decimal {
        totalIncome / Decimal(max(elapsedPeriodCount, 1))
    }

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

// MARK: - 年度同比对照点

/// 年档同比图表数据：今年与上一个同口径年按月/账期逐桶配对（支出侧）
struct YearComparisonPoint: Identifiable {
    let id = UUID()
    let label: String          // X 轴短标签（"1月"）
    let rangeText: String?     // 记账年口径的完整桶区间（"1/25–2/24"）；自然年为 nil
    let current: Decimal       // 今年该期支出
    let previous: Decimal      // 上一个同口径年该期支出
    let isFuture: Bool         // 桶起点晚于今天（空位，不画对照百分比）
    let isOngoing: Bool        // 今天落在桶内（进行中）

    /// 同比涨跌（0…100 百分数；上期为 0 时无意义返回 nil）
    var changePercentage: Double? {
        guard previous > 0 else { return nil }
        let diff = Double(truncating: (current - previous) as NSDecimalNumber)
        let base = Double(truncating: previous as NSDecimalNumber)
        return diff / base * 100
    }
}
