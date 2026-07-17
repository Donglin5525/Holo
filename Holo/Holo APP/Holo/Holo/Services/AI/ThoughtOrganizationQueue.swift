//
//  ThoughtOrganizationQueue.swift
//  Holo
//
//  想法 AI 整理串行队列
//  最多 1 个并发请求，支持重试、超时恢复、前后台切换、批量进度、配额耗尽暂停
//

import Foundation
import Combine
import os.log

@MainActor
final class ThoughtOrganizationQueue: ObservableObject {

    // MARK: - Singleton

    static let shared = ThoughtOrganizationQueue(service: ThoughtOrganizationService())

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtOrgQueue")
    let service: ThoughtOrganizationService

    /// 内存中的待处理队列（thoughtId + 重试次数）
    private var pendingItems: [QueueItem] = []
    /// 当前是否正在处理
    private var isProcessing = false
    /// 当前处理的 item
    private var currentItem: QueueItem?

    /// 最大重试次数
    private let maxRetryCount = 3
    /// 重试间隔（秒）：指数退避 5s → 30s → 120s
    private let retryIntervals: [TimeInterval] = [5, 30, 120]
    /// 条目间隔（秒）：4s = 15/分钟，留 25% 余量避开后端 20/分钟限额
    private let itemInterval: TimeInterval = 4

    // MARK: - 批量进度（供 UI 观察）

    /// 批量模式总量（enqueueBatch 时设置，非批量为 nil）
    @Published private(set) var batchTotal: Int?
    /// 批量模式已完成数（成功 + 跳过 + 终态 failed；重试中不计）
    @Published private(set) var batchCompleted: Int = 0
    /// 当日配额耗尽标记：撞 rateLimited 后置 true，processNext 短路不再取下一条
    /// App 重启后重置（靠 rebuildFromDatabase 续做 pending）
    @Published private(set) var dailyLimitHit: Bool = false

    // MARK: - Init

    init(service: ThoughtOrganizationService) {
        self.service = service
    }

    // MARK: - Queue Operations

    /// 将单条想法加入队列（增量整理用，保存想法时触发）
    /// - Parameter thoughtId: 想法 UUID
    func enqueue(thoughtId: UUID) {
        guard ThoughtAIClassificationPolicy.isEnabled() else {
            logger.info("自动分类已关闭，跳过新想法入队：\(thoughtId)")
            return
        }
        // 批量进行中时，新想法也计入批量总量（保证进度准确）
        if let total = batchTotal {
            self.batchTotal = total + 1
        }
        guard appendIfNotQueued(thoughtId) else { return }
        processNext()
    }

    /// 批量入队（「自动整理」入口用）
    /// 设置批量进度追踪，串行处理全部
    /// - Parameter thoughtIds: 待整理想法 ID 列表
    func enqueueBatch(thoughtIds: [UUID]) {
        guard !thoughtIds.isEmpty else { return }

        // 用户主动触发，重置配额暂停标记
        self.dailyLimitHit = false

        let isFreshBatch = batchTotal == nil || (pendingItems.isEmpty && currentItem == nil && !isProcessing)
        if isFreshBatch {
            self.batchTotal = thoughtIds.count
            self.batchCompleted = 0
        } else {
            self.batchTotal = (batchTotal ?? 0) + thoughtIds.count
        }

        for thoughtId in thoughtIds {
            appendIfNotQueued(thoughtId)
        }
        logger.info("批量入队：\(thoughtIds.count) 条，总量：\(self.batchTotal ?? 0)")

        processNext()
    }

    /// 去重追加（enqueue/enqueueBatch 共用）
    @discardableResult
    private func appendIfNotQueued(_ thoughtId: UUID) -> Bool {
        let alreadyQueued = pendingItems.contains { $0.thoughtId == thoughtId }
        let isCurrent = currentItem?.thoughtId == thoughtId
        guard !alreadyQueued && !isCurrent else { return false }

        pendingItems.append(QueueItem(thoughtId: thoughtId, retryCount: 0))
        return true
    }

    /// App 启动时重建队列（从 Core Data 恢复 pending 想法）
    func rebuildFromDatabase() {
        let repository = ThoughtRepository()

        // 先恢复 processing 超时
        repository.recoverStaleProcessingThoughts()

        // 自动分类关闭时不恢复后台队列；用户仍可从“批量 AI 整理”主动处理。
        guard ThoughtAIClassificationPolicy.isEnabled() else {
            logger.info("自动分类已关闭，跳过 pending 队列恢复")
            return
        }

        // 读取 pending 想法（批量整理被配额暂停后留下的，次日续做）
        do {
            let pendingIds = try repository.fetchPendingThoughtIds()
            for id in pendingIds {
                let alreadyQueued = pendingItems.contains { $0.thoughtId == id }
                if !alreadyQueued {
                    pendingItems.append(QueueItem(thoughtId: id, retryCount: 0))
                }
            }
            if !pendingIds.isEmpty {
                logger.info("重建队列：\(pendingIds.count) 条 pending 想法")
            }
        } catch {
            logger.error("重建队列失败：\(error.localizedDescription)")
        }

        processNext()
    }

    // MARK: - Processing

    /// 处理队列中的下一个 item
    private func processNext() {
        guard !isProcessing else { return }

        // 配额耗尽暂停：不再取下一条（靠 App 重启 rebuild 续做）
        guard !dailyLimitHit else { return }

        guard let item = pendingItems.first else {
            // 队列清空：批量模式若已完成全部，进度会在 onItemDone 里清空
            return
        }

        pendingItems.removeFirst()
        currentItem = item
        isProcessing = true

        let thoughtId = item.thoughtId
        let retryCount = item.retryCount
        let maxRetries = maxRetryCount
        let intervals = retryIntervals
        let interval = itemInterval

        logger.info("开始处理：\(thoughtId)，重试次数：\(retryCount)")

        Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.service.organizeThought(thoughtId: thoughtId)
                self.logger.info("处理成功：\(thoughtId)")
                self.onItemDone(isTerminal: true)
            } catch let error as APIError {
                if case .rateLimited = error {
                    // 配额耗尽：当前条回退 pending（次日 rebuild 续做），当日整体暂停
                    self.logger.warning("配额耗尽，\(thoughtId) 回退 pending，当日暂停")
                    self.handleRateLimited(thoughtId: thoughtId)
                    self.onItemDone(isTerminal: false)
                } else {
                    // 其他 API 错误（网络/超时/serverError），可重试
                    self.handleFailure(
                        thoughtId: thoughtId, error: error,
                        retryCount: retryCount, maxRetries: maxRetries, intervals: intervals
                    )
                }
            } catch {
                // 其他错误，可重试
                self.handleFailure(
                    thoughtId: thoughtId, error: error,
                    retryCount: retryCount, maxRetries: maxRetries, intervals: intervals
                )
            }

            self.currentItem = nil
            self.isProcessing = false

            // 继续处理下一个（间隔节流，避开后端分钟限额）
            if !self.pendingItems.isEmpty && !self.dailyLimitHit {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self.processNext()
            }
        }
    }

    // MARK: - 配额耗尽处理

    /// 配额耗尽：当前条回退 pending（状态已是 pending，此处幂等确认），整体暂停
    private func handleRateLimited(thoughtId: UUID) {
        let repository = ThoughtRepository()
        do {
            try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "pending")
        } catch {
            logger.error("回退 pending 失败：\(thoughtId) \(error.localizedDescription)")
        }
        self.dailyLimitHit = true
    }

    // MARK: - 失败重试处理

    /// 处理失败：重试或标记 failed
    private func handleFailure(
        thoughtId: UUID,
        error: Error,
        retryCount: Int,
        maxRetries: Int,
        intervals: [TimeInterval]
    ) {
        let nextRetry = retryCount + 1

        if nextRetry <= maxRetries {
            // 重试：放回队列头部，带延迟
            let interval = intervals[min(retryCount, intervals.count - 1)]
            logger.info("重试 \(nextRetry)/\(maxRetries)：\(thoughtId)，等待 \(interval)s，错误：\(error.localizedDescription)")

            let retryItem = QueueItem(thoughtId: thoughtId, retryCount: nextRetry)

            Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self.pendingItems.insert(retryItem, at: 0)
                self.processNext()
            }
        } else {
            logger.warning("超过最大重试次数，标记 failed：\(thoughtId)")
            // Service 透传错误不再标 failed，由 Queue 在重试耗尽时标记终态
            let repository = ThoughtRepository()
            do {
                try repository.updateOrganizedStatus(thoughtId: thoughtId, status: "failed")
            } catch {
                logger.error("标记 failed 失败：\(thoughtId) \(error.localizedDescription)")
            }
            onItemDone(isTerminal: true)
        }
    }

    // MARK: - 进度更新

    /// 单条处理结束更新批量进度
    /// - Parameter isTerminal: 是否终态（成功/跳过/终态failed）；重试中传 false 不计数
    private func onItemDone(isTerminal: Bool) {
        guard isTerminal, batchTotal != nil else { return }
        self.batchCompleted += 1

        // 批量全部完成：清空进度（banner 随 batchTotal==nil 消失，列表已刷新显示新标签）
        if batchCompleted >= (batchTotal ?? 0) {
            logger.info("批量整理全部完成：\(self.batchCompleted) 条")
            self.batchTotal = nil
            self.batchCompleted = 0
        }
    }

    // MARK: - Queue State

    /// 当前队列长度
    var count: Int {
        pendingItems.count + (isProcessing ? 1 : 0)
    }

    /// 队列是否为空
    var isEmpty: Bool {
        pendingItems.isEmpty && !isProcessing
    }

    /// 是否正在批量整理（UI 据此显示批量进度 banner）
    var isBatchOrganizing: Bool {
        batchTotal != nil && !isEmpty
    }
}

// MARK: - Queue Item

/// 队列条目
private struct QueueItem {
    let thoughtId: UUID
    let retryCount: Int
}
