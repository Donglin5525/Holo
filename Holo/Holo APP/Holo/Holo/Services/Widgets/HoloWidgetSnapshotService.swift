//
//  HoloWidgetSnapshotService.swift
//  Holo
//
//  生成桌面小组件使用的轻量数据快照。
//

import Foundation
import WidgetKit

@MainActor
final class HoloWidgetSnapshotService {
    static let shared = HoloWidgetSnapshotService()

    private let store: HoloWidgetSnapshotStore
    private var observers: [NSObjectProtocol] = []

    private init(store: HoloWidgetSnapshotStore = HoloWidgetSnapshotStore()) {
        self.store = store
    }

    func startObserving() {
        guard observers.isEmpty else { return }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .financeDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshFinanceSnapshot()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .thoughtDataDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshThoughtMemorySnapshot()
                }
            }
        )
    }

    func refreshAllSnapshots() async {
        writeQuickActionsSnapshot()
        await refreshFinanceSnapshot()
        refreshThoughtMemorySnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func writeQuickActionsSnapshot(date: Date = Date()) {
        try? store.writeQuickActions(.defaultSnapshot(date: date))
    }

    func refreshFinanceSnapshot(date: Date = Date()) async {
        FinanceRepository.shared.setup()

        let todayTransactions = (try? await FinanceRepository.shared.getTransactionsForDay(date)) ?? []
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let monthTransactions = (try? await FinanceRepository.shared.getTransactions(for: monthStart)) ?? []
        let budgetSummary = BudgetRepository.shared.computeGlobalTotalBudgetStatus(period: .month)
        let dayRange = calendar.range(of: .day, in: .month, for: date)

        let todayExpense = todayTransactions.amountSum(for: .expense)
        let todayIncome = todayTransactions.amountSum(for: .income)
        let monthExpense = budgetSummary?.totalSpentAmount.doubleValue
            ?? monthTransactions.amountSum(for: .expense)
        let monthBudget = budgetSummary?.totalBudgetAmount.doubleValue

        let snapshot = HoloWidgetFinanceSnapshot(
            todayExpense: todayExpense,
            todayIncome: todayIncome,
            monthExpense: monthExpense,
            monthBudget: monthBudget,
            dayOfMonth: calendar.component(.day, from: date),
            daysInMonth: dayRange?.count ?? 30,
            updatedAt: date
        )

        try? store.writeFinance(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.finance.rawValue)
    }

    func refreshThoughtMemorySnapshot(date: Date = Date()) {
        guard let snapshot = buildThoughtMemorySnapshot(date: date) else { return }
        try? store.writeThoughtMemory(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.thoughtMemory.rawValue)
    }

    private func buildThoughtMemorySnapshot(date: Date) -> HoloWidgetThoughtMemorySnapshot? {
        let repository = ThoughtRepository()
        let thoughts = (try? repository.fetchAll(limit: 120, sortBy: .createdAtDescending)) ?? []
        let candidates = thoughts
            .filter { !$0.isSoftDeleted && !$0.isArchived }
            .filter { $0.plainContent.count >= 8 }

        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { lhs, rhs in
            let lhsScore = thoughtWalkScore(lhs)
            let rhsScore = thoughtWalkScore(rhs)
            if lhsScore == rhsScore {
                return lhs.createdAt > rhs.createdAt
            }
            return lhsScore > rhsScore
        }

        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        let selected = sorted[(dayOfYear - 1) % sorted.count]
        let tags = Array(selected.tagArray.map(\.name).prefix(2))
        let excerpt = selected.plainContent.truncatedForWidget(maxLength: 72)

        return HoloWidgetThoughtMemorySnapshot(
            thoughtId: selected.id,
            createdAt: selected.createdAt,
            tags: tags,
            excerpt: excerpt,
            sourceHint: sourceHint(for: selected),
            showsOriginalExcerpt: HoloWidgetPrivacySettings.showsThoughtExcerpt
        )
    }

    private func thoughtWalkScore(_ thought: Thought) -> Int {
        let tagScore = min(thought.tagArray.count, 3) * 3
        let referencesScore = min(((thought.references?.count ?? 0) + (thought.referencedBy?.count ?? 0)), 3) * 4
        let lengthScore = thought.plainContent.count <= 180 ? 2 : 0
        return tagScore + referencesScore + lengthScore
    }

    private func sourceHint(for thought: Thought) -> String {
        let hour = Calendar.current.component(.hour, from: thought.createdAt)
        switch hour {
        case 0..<6: return "来自一次深夜记录"
        case 18..<24: return "来自一次夜间记录"
        default: return "来自一条过往想法"
        }
    }
}

enum HoloWidgetPrivacySettings {
    static let thoughtExcerptKey = "holoWidgetShowsThoughtExcerpt"

    static var showsThoughtExcerpt: Bool {
        UserDefaults.standard.bool(forKey: thoughtExcerptKey)
    }
}

private extension Array where Element == Transaction {
    func amountSum(for type: TransactionType) -> Double {
        filter { $0.transactionType == type }
            .reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
            .doubleValue
    }
}

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

private extension String {
    func truncatedForWidget(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
