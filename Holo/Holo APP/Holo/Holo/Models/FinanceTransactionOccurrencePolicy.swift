//
//  FinanceTransactionOccurrencePolicy.swift
//  Holo
//
//  统一定义“计划流水”和“已发生流水”的时间边界。
//

import Foundation

nonisolated enum FinanceTransactionProjectPostingState: String, Sendable {
    /// 已实际发生的周期项目流水，可以参与余额与统计。
    case confirmed
}

/// `Transaction` 里可以保存未来分期，供编辑完整分期计划使用；
/// 但余额、统计、预算和 AI 历史事实只能消费截至快照时刻已经发生的流水。
nonisolated enum FinanceTransactionOccurrencePolicy {
    static let recurringRemark = "长期成本·自动生成"
    static let oneOffRemark = "长期成本·一次性购买"

    static func hasOccurred(_ transactionDate: Date, asOf snapshotDate: Date = Date()) -> Bool {
        transactionDate <= snapshotDate
    }

    /// 手工流水正常参与统计；固定支出只允许“已确认且已实际发生”的周期流水参与。
    /// 一次性购买只是持有成本卡，即使旧版本留下了关联流水也永远不进入余额。
    static func isHistoricallyEligible(
        spendingProjectId: UUID?,
        projectPostingState: String?,
        remark: String?
    ) -> Bool {
        guard spendingProjectId != nil else { return true }
        return projectPostingState == FinanceTransactionProjectPostingState.confirmed.rawValue &&
            remark == recurringRemark
    }

    /// Core Data 查询统一复用该条件，避免余额、统计、预算和 AI 各自维护一套“已发生”口径。
    /// 对项目流水采用 fail-closed：只有明确的周期自动流水可以进入历史统计。
    static func occurredPredicate(
        dateKey: String = "date",
        asOf snapshotDate: Date = Date()
    ) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K <= %@", dateKey, snapshotDate as NSDate),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "spendingProjectId == nil"),
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(
                        format: "projectPostingState == %@",
                        FinanceTransactionProjectPostingState.confirmed.rawValue
                    ),
                    NSPredicate(format: "remark == %@", recurringRemark)
                ])
            ])
        ])
    }

    static func effectiveHistoricalEnd(requestedEnd: Date, asOf snapshotDate: Date = Date()) -> Date {
        min(requestedEnd, snapshotDate)
    }

    /// 收支统计口径统一排除「对账调整」流水：它参与余额计算（否则对账失去意义），
    /// 但不是真实消费，计入月度收支/预算/分类聚合会虚增支出或收入。
    /// 只在统计聚合取数点挂载；明细列表与余额计算不挂（见 docs/finance/plans/余额对账功能方案.md §2.2）。
    static func reconciliationExclusionPredicate() -> NSPredicate {
        NSPredicate(format: "isReconciliationAdjustment == NO")
    }
}
