//
//  UnderstandingDataSource.swift
//  Holo
//
//  理解引擎 M2 真数据接入：真实仓库 → 观察输入适配（07-M2施工图「运行时侧负责」）。
//
//  铁律（工程稿 §5.2 数据边界）：
//  - 只读。不写任何业务库、不进 CloudKit、不进对话上下文。
//  - 授权门：AI 数据处理授权未开 → 空输入（影子引擎静默不跑）。
//  - 金额/精确数值不进观察（FinanceObservationInput 本身无金额字段）。
//  - 近 90 天窗口（07 施工图：一期只索引近 90 天+旧统计回指，历史靠主题探索补）。
//

import Foundation

nonisolated enum UnderstandingDataSource {

    /// 财务真实取数：近 90 天支出、排除退款与对账调整、带备注与类目。
    /// 取数口径与 MemorySignalDataAdapter.buildFinanceMemorySnapshotInput 同源
    ///（真实消费、退款不参与、对账调整不混入）。
    @MainActor
    static func financeInputs(now: Date = Date()) async -> [FinanceObservationInput] {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return [] }
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -90, to: now) else { return [] }
        let repository = FinanceRepository.shared
        guard let transactions = try? await repository.getAllTransactions() else { return [] }
        return transactions.compactMap { transaction in
            guard transaction.transactionType == .expense,
                  !transaction.isRefund,
                  !transaction.isReconciliationAdjustment,
                  transaction.date >= windowStart else { return nil }
            let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 类目可选：无类目的账单只带备注概念（观察不强求类目）。
            let categoryNames: String? = transaction.category.map { category in
                let names = repository.resolveCategoryNames(from: category)
                return names.sub ?? names.primary
            } ?? nil
            return FinanceObservationInput(
                id: transaction.id.uuidString,
                note: (note?.isEmpty == true) ? nil : note,
                occurredAt: transaction.date,
                recordedAt: transaction.createdAt ?? transaction.date,
                updatedAt: transaction.updatedAt ?? transaction.date,
                isRefund: false,
                categoryName: categoryNames
            )
        }
    }

    /// 想法真实取数：近 90 天、排除「不参与 AI」标签（ThoughtAIAudience 同口径）。
    /// 想法本体均为用户书写（AI 摘要不在 Thought 表），isAIDerived 恒 false。
    @MainActor
    static func thoughtInputs(now: Date = Date()) async -> [ThoughtObservationInput] {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return [] }
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -90, to: now) else { return [] }
        // 取数口径与 MemorySignalDataAdapter.buildThoughtMemoryInputs 同源：
        // fetchAll 服务 UI 与 AI，AI 侧用 aiVisibleOnly 过滤「不参与 AI」标签。
        let thoughts = ThoughtAIAudience.aiVisibleOnly((try? ThoughtRepository().fetchAll(limit: 500)) ?? [])
        return thoughts.compactMap { thought in
            guard thought.updatedAt >= windowStart else { return nil }
            let text = thought.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let created = thought.createdAt ?? thought.updatedAt
            return ThoughtObservationInput(
                id: thought.id.uuidString,
                text: text,
                createdAt: created,
                updatedAt: thought.updatedAt,
                isAIDerived: false
            )
        }
    }
}
