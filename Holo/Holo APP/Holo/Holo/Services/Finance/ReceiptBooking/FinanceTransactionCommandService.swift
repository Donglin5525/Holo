//
//  FinanceTransactionCommandService.swift
//  Holo
//
//  图片快捷指令自动记账 · 原子写账服务（2026-09-14 完整方案 §6.2/§23.1/§24.5）
//  所有入口（聊天确认 / 快捷指令自动 / 复核页确认）的落账都走这里，
//  不得再另写一套保存代码。
//
//  提交顺序（方案 §24.5）：
//  1. 幂等查询 2. 创建交易（含目标账户/分类/项目/AI 来源）3. 单次保存
//  4. 结果回执 5. 发布数据变更通知（小组件快照服务自监听刷新）6. 通知（M3）
//  步骤 4-6 失败不回滚已成功的交易；同图重跑经来源键返回原交易。
//

import Foundation
import CoreData

@MainActor
final class FinanceTransactionCommandService {

    static let shared = FinanceTransactionCommandService()

    private init() {}

    struct CommitResult: Sendable, Equatable {
        let transactionID: UUID
        /// false = 命中精确来源键，返回的是既有交易（幂等）
        let created: Bool
    }

    enum CommitError: LocalizedError {
        case categoryMissing(UUID)
        case accountMissing(UUID)

        var errorDescription: String? {
            switch self {
            case .categoryMissing(let id):
                return "分类不存在或已删除：\(id)"
            case .accountMissing(let id):
                return "账户不存在或已删除：\(id)"
            }
        }
    }

    /// 把纯值草案原子落库。跨 await 只传 UUID 纯值，Core Data 对象不出本方法。
    /// - Parameter postNotification: 复核页/聊天等 UI 内调用可关（页面自会刷新）；
    ///   后台自动路径必须开（驱动列表刷新与小组件快照）
    /// - Parameter repository: 默认生产共享仓库；测试注入独立内存栈
    ///   （生产调用点一律用默认值，不感知此参数）
    func commit(
        draft: ResolvedTransactionDraft,
        postNotification: Bool = true,
        repository: FinanceRepository = .shared
    ) throws -> CommitResult {
        let repo = repository
        guard let category = repo.findCategory(by: draft.categoryID) else {
            throw CommitError.categoryMissing(draft.categoryID)
        }
        guard let account = repo.findAccount(by: draft.accountID) else {
            throw CommitError.accountMissing(draft.accountID)
        }

        let (transaction, created) = try repo.bookTransactionAtomically(
            amount: draft.amount,
            type: draft.typeIsIncome ? .income : .expense,
            category: category,
            account: account,
            date: draft.date,
            note: draft.note,
            remark: draft.remark,
            financeProjectId: draft.financeProjectID,
            aiCandidate: draft.aiCandidate,
            aiSourceMessageId: draft.sourceKey,
            aiSourceItemId: draft.itemKey
        )

        // 已入账交易之后的副作用：失败不回滚（方案 §24.5 步骤 4-6 语义）
        if created && postNotification {
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
        }
        return CommitResult(transactionID: transaction.id, created: created)
    }
}
