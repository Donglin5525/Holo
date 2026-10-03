//
//  FinanceProjectIncomeDetachBootstrap.swift
//  Holo
//
//  一次性迁移：项目挂靠口径对齐「项目=一件事的资金全景」（2026-10-04 定稿）。
//  两步串行（同一后台队列）：①清洗——收入交易解除挂靠（清「记住上次项目」bug 的
//  存量误挂）；②回填——退款笔挂靠继承原交易（项目支出负冲与全局对账）。
//  表单/AI/票根侧同批已放开收入挂靠；本迁移只处理存量。清洗在前回填在后：
//  先清掉全部误挂，再把「有主」的退款按不变式补回。
//  独立薄文件（只被 App 引用）：迁移本体在 FinanceProjectRepository 纯 context 函数，
//  便于单测不依赖启动链。
//

import CoreData
import Foundation
import OSLog

enum FinanceProjectIncomeDetachBootstrap {

    private static let onceKey = "financeProject.incomeDetachDone"
    private static let logger = Logger(subsystem: "com.holo.Holo", category: "FinanceProject")

    /// App 启动后台调用（幂等，per 设备一次）。失败不打标记，下次启动重试。
    static func performIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: onceKey) else { return }
        Task.detached(priority: .utility) {
            let stack = CoreDataStack.shared
            await stack.waitUntilReady()
            do {
                let detached: Int = try await stack.performBackgroundTask { context in
                    try FinanceProjectRepository.detachProjectsFromIncomeTransactions(in: context)
                }
                let backfilled: Int = try await stack.performBackgroundTask { context in
                    try FinanceProjectRepository.backfillRefundProjectAttachments(in: context)
                }
                UserDefaults.standard.set(true, forKey: onceKey)
                logger.info("项目挂靠口径迁移完成 detached=\(detached) refundBackfilled=\(backfilled)")
                if detached > 0 || backfilled > 0 {
                    await MainActor.run {
                        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                    }
                }
            } catch {
                logger.error("项目挂靠口径迁移失败，下次启动重试：\(error.localizedDescription)")
            }
        }
    }
}
