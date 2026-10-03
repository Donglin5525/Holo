//
//  FinanceProjectIncomeDetachBootstrap.swift
//  Holo
//
//  一次性清洗：收入交易解除项目挂靠（2026-10-04 拍板）。
//  手动表单「记住上次项目」曾不分收支预选，收入模式项目行隐藏无从取消，
//  存量收入被静默挂上项目；表单侧已修，本清洗追溯存量。
//  独立薄文件（只被 App 引用）：清洗本体在 FinanceProjectRepository 纯 context 函数，
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
                UserDefaults.standard.set(true, forKey: onceKey)
                logger.info("收入项目挂靠清洗完成 detached=\(detached)")
                if detached > 0 {
                    await MainActor.run {
                        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                    }
                }
            } catch {
                logger.error("收入项目挂靠清洗失败，下次启动重试：\(error.localizedDescription)")
            }
        }
    }
}
