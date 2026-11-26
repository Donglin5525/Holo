//
//  SpendingProjectAmountPolicy.swift
//  Holo
//
//  周期项目金额口径与每期入账金额的唯一真相源。
//

import Foundation

nonisolated enum SpendingProjectFrequency: String, CaseIterable, Sendable {
    case weekly
    case monthly
    case quarterly
    case yearly

    var title: String {
        switch self {
        case .weekly: return String(localized: "每周")
        case .monthly: return String(localized: "每月")
        case .quarterly: return String(localized: "每季")
        case .yearly: return String(localized: "每年")
        }
    }

    var shortUnitTitle: String {
        switch self {
        case .weekly: return String(localized: "周")
        case .monthly: return String(localized: "月")
        case .quarterly: return String(localized: "季")
        case .yearly: return String(localized: "年")
        }
    }

    /// 折合月均金额的换算倍率（周按 52/12 ≈ 4.3333，季按 1/3，年按 1/12）
    func monthlyAmount(from perOccurrence: Decimal) -> Decimal {
        switch self {
        case .weekly:
            return perOccurrence * Decimal(52) / Decimal(12)
        case .monthly:
            return perOccurrence
        case .quarterly:
            return perOccurrence / Decimal(3)
        case .yearly:
            return perOccurrence / Decimal(12)
        }
    }

    /// 按当前周期向后推进 1 期
    func advancing(_ date: Date, by periods: Int = 1, calendar: Calendar = .current) -> Date? {
        switch self {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * periods, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: periods, to: date)
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3 * periods, to: date)
        case .yearly:
            return calendar.date(byAdding: .year, value: periods, to: date)
        }
    }
}

nonisolated enum SpendingProjectAmountMode: String, CaseIterable, Sendable {
    /// 输入金额就是每次实际发生时的扣款金额，例如每月 20 元的订阅。
    case perOccurrence
    /// 输入金额是整个项目总额，例如 20 万元、36 期的购车分期。
    case projectTotal

    var title: String {
        switch self {
        case .perOccurrence: return String(localized: "每期金额")
        case .projectTotal: return String(localized: "项目总额")
        }
    }
}

nonisolated enum SpendingProjectAmountPolicy {
    /// 返回第 `occurrenceIndex` 期真正应写入账本的金额；索引从 0 开始。
    /// 项目总额按分精确拆分，最后一期吸收四舍五入尾差。
    static func occurrenceAmount(
        enteredAmount: Decimal,
        mode: SpendingProjectAmountMode,
        totalOccurrences: Int,
        occurrenceIndex: Int
    ) -> Decimal? {
        guard enteredAmount > 0, occurrenceIndex >= 0 else { return nil }

        switch mode {
        case .perOccurrence:
            return enteredAmount
        case .projectTotal:
            guard totalOccurrences > 0, occurrenceIndex < totalOccurrences else { return nil }
            let regularAmount = roundedCurrency(enteredAmount / Decimal(totalOccurrences))
            if occurrenceIndex == totalOccurrences - 1 {
                return enteredAmount - regularAmount * Decimal(totalOccurrences - 1)
            }
            return regularAmount
        }
    }

    static func monthlyCommitment(
        enteredAmount: Decimal,
        mode: SpendingProjectAmountMode,
        totalOccurrences: Int,
        frequency: SpendingProjectFrequency
    ) -> Decimal? {
        guard let perOccurrence = occurrenceAmount(
            enteredAmount: enteredAmount,
            mode: mode,
            totalOccurrences: totalOccurrences,
            occurrenceIndex: 0
        ) else { return nil }
        return frequency.monthlyAmount(from: perOccurrence)
    }

    private static func roundedCurrency(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .plain)
        return result
    }
}
