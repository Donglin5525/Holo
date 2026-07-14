//
//  FinanceMemorySignalBuilder.swift
//  Holo
//
//  财务记忆只使用本地确定性统计；AI 不参与金额、占比或预算偏离计算。
//

import Foundation

nonisolated struct FinanceMemoryTransactionInput: Equatable, Sendable {
    var id: String
    var amount: Double
    var isExpense: Bool
    var categoryID: String
    var categoryName: String
    var merchant: String?
    var occurredAt: Date
    var revisionDigest: String
}

nonisolated struct FinanceMemoryBudgetInput: Equatable, Sendable {
    var id: String
    var categoryID: String?
    var categoryName: String
    var budgetAmount: Double
    var spentAmount: Double
    var revisionDigest: String
}

nonisolated struct FinanceMemorySnapshotInput: Equatable, Sendable {
    var currentTransactions: [FinanceMemoryTransactionInput]
    var previousTransactions: [FinanceMemoryTransactionInput]
    var budgets: [FinanceMemoryBudgetInput]
    var windowStart: Date
    var windowEnd: Date
}

nonisolated enum FinanceMemorySignalBuilder {
    private static let boundaries = [
        "不得推断用户收入、资产、阶层或人格",
        "不得在财务领域建立与健康、目标或其他领域的冲突和因果"
    ]

    static func build(from snapshot: FinanceMemorySnapshotInput) -> [HoloDomainMemorySignal] {
        let current = snapshot.currentTransactions.filter(\.isExpense)
        var signals: [HoloDomainMemorySignal] = []
        signals += repeatedMerchantSignals(current, snapshot: snapshot)
        signals += repeatedCategorySignals(current, snapshot: snapshot)
        signals += fixedExpenseSignals(current, snapshot: snapshot)
        signals += budgetSignals(snapshot.budgets, snapshot: snapshot)
        signals += structureShiftSignals(current: current, previous: snapshot.previousTransactions.filter(\.isExpense), snapshot: snapshot)
        return Dictionary(grouping: signals, by: \.id).compactMap { $0.value.first }.sorted { $0.id < $1.id }
    }

    private static func repeatedMerchantSignals(
        _ transactions: [FinanceMemoryTransactionInput],
        snapshot: FinanceMemorySnapshotInput
    ) -> [HoloDomainMemorySignal] {
        Dictionary(grouping: transactions) { normalized($0.merchant) }
            .compactMap { merchant, items in
                guard !merchant.isEmpty, items.count >= 3 else { return nil }
                return makeAggregateSignal(
                    id: "finance-repeated-merchant-\(merchant)",
                    items: items,
                    snapshot: snapshot,
                    anchorType: .merchant,
                    anchorValue: merchant,
                    anchorLabel: items.first?.merchant,
                    facts: [
                        "transactionCount": Double(items.count),
                        "totalAmount": items.reduce(0) { $0 + $1.amount }
                    ]
                )
            }
    }

    private static func repeatedCategorySignals(
        _ transactions: [FinanceMemoryTransactionInput],
        snapshot: FinanceMemorySnapshotInput
    ) -> [HoloDomainMemorySignal] {
        Dictionary(grouping: transactions, by: \.categoryID).compactMap { categoryID, items in
            guard items.count >= 4, let first = items.first else { return nil }
            return makeAggregateSignal(
                id: "finance-repeated-category-\(categoryID)",
                items: items,
                snapshot: snapshot,
                anchorType: .financeCategory,
                anchorValue: categoryID,
                anchorLabel: first.categoryName,
                facts: [
                    "transactionCount": Double(items.count),
                    "totalAmount": items.reduce(0) { $0 + $1.amount }
                ]
            )
        }
    }

    private static func fixedExpenseSignals(
        _ transactions: [FinanceMemoryTransactionInput],
        snapshot: FinanceMemorySnapshotInput
    ) -> [HoloDomainMemorySignal] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Dictionary(grouping: transactions) { normalized($0.merchant) }.compactMap { merchant, items in
            guard !merchant.isEmpty, items.count >= 3 else { return nil }
            let months = Set(items.map {
                let components = calendar.dateComponents([.year, .month], from: $0.occurredAt)
                return "\(components.year ?? 0)-\(components.month ?? 0)"
            })
            let mean = items.reduce(0) { $0 + $1.amount } / Double(items.count)
            let maximumDeviation = items.map { abs($0.amount - mean) }.max() ?? .infinity
            guard months.count >= 3, mean > 0, maximumDeviation / mean <= 0.1 else { return nil }
            return makeAggregateSignal(
                id: "finance-fixed-expense-\(merchant)",
                items: items,
                snapshot: snapshot,
                anchorType: .merchant,
                anchorValue: merchant,
                anchorLabel: items.first?.merchant,
                facts: [
                    "occurrenceCount": Double(items.count),
                    "monthCount": Double(months.count),
                    "averageAmount": mean
                ]
            )
        }
    }

    private static func budgetSignals(
        _ budgets: [FinanceMemoryBudgetInput],
        snapshot: FinanceMemorySnapshotInput
    ) -> [HoloDomainMemorySignal] {
        budgets.compactMap { budget in
            guard budget.budgetAmount > 0,
                  budget.spentAmount / budget.budgetAmount >= 1.15 else { return nil }
            let anchorValue = budget.categoryID ?? "total-budget"
            guard let anchor = try? HoloMemoryAnchorRef(
                type: .financeCategory,
                value: anchorValue,
                displayLabel: budget.categoryName
            ) else { return nil }
            let evidence = HoloMemoryEvidenceRef(
                id: "finance-budget-\(budget.id)-\(budget.revisionDigest)",
                kind: .entityRef,
                sourceDomain: .finance,
                lineageKey: "finance:budget:\(budget.id)",
                sourceID: budget.id,
                revisionDigest: budget.revisionDigest,
                observedAt: snapshot.windowEnd,
                validFrom: snapshot.windowStart,
                validTo: snapshot.windowEnd
            )
            return try? HoloDomainSignalBuilder.make(
                id: "finance-budget-deviation-\(budget.id)",
                domain: .finance,
                kind: .entity,
                evidence: evidence,
                anchors: [anchor],
                numericFacts: [
                    "budgetAmount": budget.budgetAmount,
                    "spentAmount": budget.spentAmount,
                    "deviationRatio": budget.spentAmount / budget.budgetAmount
                ],
                prohibitedInferences: boundaries
            )
        }
    }

    private static func structureShiftSignals(
        current: [FinanceMemoryTransactionInput],
        previous: [FinanceMemoryTransactionInput],
        snapshot: FinanceMemorySnapshotInput
    ) -> [HoloDomainMemorySignal] {
        let currentTotal = current.reduce(0) { $0 + $1.amount }
        let previousTotal = previous.reduce(0) { $0 + $1.amount }
        guard currentTotal > 0, previousTotal > 0 else { return [] }
        let currentGroups = Dictionary(grouping: current, by: \.categoryID)
        let previousGroups = Dictionary(grouping: previous, by: \.categoryID)
        return currentGroups.compactMap { categoryID, items in
            guard items.count >= 2, let first = items.first else { return nil }
            let currentShare = items.reduce(0) { $0 + $1.amount } / currentTotal
            let previousShare = (previousGroups[categoryID] ?? []).reduce(0) { $0 + $1.amount } / previousTotal
            guard abs(currentShare - previousShare) >= 0.15 else { return nil }
            return makeAggregateSignal(
                id: "finance-structure-shift-\(categoryID)",
                items: items,
                snapshot: snapshot,
                anchorType: .financeCategory,
                anchorValue: categoryID,
                anchorLabel: first.categoryName,
                facts: ["currentShare": currentShare, "previousShare": previousShare]
            )
        }
    }

    private static func makeAggregateSignal(
        id: String,
        items: [FinanceMemoryTransactionInput],
        snapshot: FinanceMemorySnapshotInput,
        anchorType: HoloMemoryAnchorType,
        anchorValue: String,
        anchorLabel: String?,
        facts: [String: Double]
    ) -> HoloDomainMemorySignal? {
        guard let anchor = try? HoloMemoryAnchorRef(
            type: anchorType,
            value: anchorValue,
            displayLabel: anchorLabel
        ) else { return nil }
        let digest = digestFor(items)
        let evidence = HoloMemoryEvidenceRef(
            id: "\(id)-\(digest)",
            kind: .aggregateSnapshot,
            sourceDomain: .finance,
            lineageKey: id,
            revisionDigest: digest,
            observedAt: snapshot.windowEnd,
            validFrom: snapshot.windowStart,
            validTo: snapshot.windowEnd,
            aggregateDefinition: "由本地交易 ID、金额、类别与时间窗口确定性聚合",
            sampleCount: items.count
        )
        return try? HoloDomainSignalBuilder.make(
            id: id,
            domain: .finance,
            kind: .aggregate,
            evidence: evidence,
            anchors: [anchor],
            numericFacts: facts,
            prohibitedInferences: boundaries
        )
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func digestFor(_ items: [FinanceMemoryTransactionInput]) -> String {
        let value = items.sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.revisionDigest)" }
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
