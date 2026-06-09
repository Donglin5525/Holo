//
//  ThoughtOrganizationQueue.swift
//  Holo
//
//  想法 AI 整理串行队列
//  最多 1 个并发请求，支持重试、超时恢复、前后台切换
//

import Foundation
import os.log

@MainActor
final class ThoughtOrganizationQueue {

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

    // MARK: - Init

    init(service: ThoughtOrganizationService) {
        self.service = service
    }

    // MARK: - Queue Operations

    /// 将想法加入队列
    /// - Parameter thoughtId: 想法 UUID
    func enqueue(thoughtId: UUID) {
        // 去重
        let alreadyQueued = self.pendingItems.contains { $0.thoughtId == thoughtId }
        let isCurrent = self.currentItem?.thoughtId == thoughtId
        guard !alreadyQueued && !isCurrent else { return }

        self.pendingItems.append(QueueItem(thoughtId: thoughtId, retryCount: 0))
        logger.info("入队：\(thoughtId)，队列长度：\(self.pendingItems.count)")

        processNext()
    }

    /// App 启动时重建队列（从 Core Data 恢复 pending 想法）
    func rebuildFromDatabase() {
        let repository = ThoughtRepository()

        // 先恢复 processing 超时
        repository.recoverStaleProcessingThoughts()

        // 读取 pending 想法
        do {
            let pendingIds = try repository.fetchPendingThoughtIds()
            for id in pendingIds {
                let alreadyQueued = self.pendingItems.contains { $0.thoughtId == id }
                if !alreadyQueued {
                    self.pendingItems.append(QueueItem(thoughtId: id, retryCount: 0))
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

        guard let item = self.pendingItems.first else {
            // 队列清空
            return
        }

        self.pendingItems.removeFirst()
        self.currentItem = item
        self.isProcessing = true

        let thoughtId = item.thoughtId
        let retryCount = item.retryCount
        let maxRetries = self.maxRetryCount
        let intervals = self.retryIntervals

        logger.info("开始处理：\(thoughtId)，重试次数：\(retryCount)")

        Task { [weak self] in
            guard let self = self else { return }

            let success = await self.service.organizeThought(thoughtId: thoughtId)

            if success {
                self.logger.info("处理成功：\(thoughtId)")
            } else {
                self.handleFailure(thoughtId: thoughtId, retryCount: retryCount, maxRetries: maxRetries, intervals: intervals)
            }

            self.currentItem = nil
            self.isProcessing = false

            // 继续处理下一个（间隔 2 秒，共享 chat 限额节流）
            if !self.pendingItems.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.processNext()
            }
        }
    }

    /// 处理失败：重试或标记 failed
    private func handleFailure(thoughtId: UUID, retryCount: Int, maxRetries: Int, intervals: [TimeInterval]) {
        let nextRetry = retryCount + 1

        if nextRetry <= maxRetries {
            // 重试：放回队列头部，带延迟
            let interval = intervals[min(retryCount, intervals.count - 1)]
            logger.info("重试 \(nextRetry)/\(maxRetries)：\(thoughtId)，等待 \(interval)s")

            let retryItem = QueueItem(thoughtId: thoughtId, retryCount: nextRetry)

            Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self.pendingItems.insert(retryItem, at: 0)
                self.processNext()
            }
        } else {
            logger.warning("超过最大重试次数，放弃：\(thoughtId)")
            // Repository 的 organizeThought 已标记 failed
        }
    }

    // MARK: - Queue State

    /// 当前队列长度
    var count: Int {
        self.pendingItems.count + (isProcessing ? 1 : 0)
    }

    /// 队列是否为空
    var isEmpty: Bool {
        self.pendingItems.isEmpty && !isProcessing
    }
}

// MARK: - Queue Item

/// 队列条目
private struct QueueItem {
    let thoughtId: UUID
    let retryCount: Int
}
