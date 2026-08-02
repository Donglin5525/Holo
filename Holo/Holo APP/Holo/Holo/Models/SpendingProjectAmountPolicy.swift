//
//  SpendingProjectAmountPolicy.swift
//  Holo
//
//  周期项目金额口径与每期入账金额的唯一真相源。
//

import Foundation

nonisolated enum SpendingProjectFrequency: String, CaseIterable, Sendable {
    case monthly
    case yearly

    var title: String {
        switch self {
        case .monthly: return "每月"
        case .yearly: return "每年"
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
        case .perOccurrence: return "每期金额"
        case .projectTotal: return "项目总额"
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
        return frequency == .yearly ? perOccurrence / 12 : perOccurrence
    }

    private static func roundedCurrency(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .plain)
        return result
    }
}
