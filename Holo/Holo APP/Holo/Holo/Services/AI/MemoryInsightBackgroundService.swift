//
//  MemoryInsightBackgroundService.swift
//  Holo
//
//  后台自动尝试生成洞察
//  使用 BGAppRefreshTask，不保证准时执行，仅作为 best-effort 增强
//

import Foundation
import BackgroundTasks
import os.log

@MainActor
final class MemoryInsightBackgroundService {

    static let shared = MemoryInsightBackgroundService()

    private let logger = Logger(subsystem: "com.holo.app", category: "MemoryInsightBackground")

    private let taskIdentifier = "com.holo.app.memoryInsightRefresh"

    private init() {}

    // MARK: - Registration

    /// 在 App 启动时注册后台任务
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                await self.handleBackgroundTask(task as! BGAppRefreshTask)
            }
        }
    }

    /// 调度后台任务（用户开启后台自动生成后调用）
    func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // 最早执行时间：1 小时后
        request.earliestBeginDate = Date().addingTimeInterval(3600)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("后台洞察生成任务已调度")
        } catch {
            logger.error("调度后台任务失败：\(error.localizedDescription)")
        }
    }

    /// 取消后台任务
    func cancelScheduledTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        logger.info("后台洞察生成任务已取消")
    }

    // MARK: - Task Handler

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // 设置过期处理
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        let settings = MemoryInsightScheduleSettings.shared

        guard settings.backgroundAutoGenerationEnabled else {
            logger.info("后台自动生成已关闭，跳过")
            task.setTaskCompleted(success: true)
            return
        }

        let service = MemoryInsightService.shared
        guard service.isAIConfigured else {
            logger.info("AI 未配置，跳过后台生成")
            task.setTaskCompleted(success: false)
            return
        }

        // 检查当前周期是否已有 ready 洞察
        let (weekStart, weekEnd) = MemoryInsightContextBuilder.periodRange(
            periodType: .weekly, referenceDate: Date()
        )

        let repository = MemoryInsightRepository()
        if let existing = try? repository.fetchInsight(
            periodType: .weekly, start: weekStart, end: weekEnd
        ), existing.insightStatus == .ready {
            logger.info("本周洞察已存在且为 ready，跳过后台生成")
            task.setTaskCompleted(success: true)
            return
        }

        // 尝试生成
        do {
            let insight = try await service.generateInsight(
                periodType: .weekly,
                start: weekStart,
                end: weekEnd,
                forceRefresh: false
            )
            logger.info("后台洞察生成成功：\(insight.title)")

            // 成功后发本地通知
            let content = MemoryInsightNotificationService()
            // 不需要额外通知，下次打开 App 即可看到
            task.setTaskCompleted(success: true)
        } catch {
            logger.error("后台洞察生成失败：\(error.localizedDescription)")
            task.setTaskCompleted(success: false)
        }

        // 调度下一次
        if settings.backgroundAutoGenerationEnabled {
            scheduleBackgroundTask()
        }
    }

    // MARK: - Foreground Compensation

    /// 前台打开 App 时检查是否需要补生成
    /// 在 MemoryGalleryViewModel.refresh() 或 App 进入前台时调用
    func checkForegroundCompensation() async {
        let settings = MemoryInsightScheduleSettings.shared

        guard settings.backgroundAutoGenerationEnabled else { return }

        let service = MemoryInsightService.shared
        guard service.isAIConfigured else { return }
        guard !service.isGenerating else { return }

        let (weekStart, weekEnd) = MemoryInsightContextBuilder.periodRange(
            periodType: .weekly, referenceDate: Date()
        )

        let repository = MemoryInsightRepository()
        // 只检查是否完全没有洞察记录（包括 generating/failed）
        if let _ = try? repository.fetchInsight(
            periodType: .weekly, start: weekStart, end: weekEnd
        ) {
            return
        }

        // 无洞察且开启了自动生成，尝试补生成
        logger.info("前台补偿：尝试生成本周洞察")
        do {
            _ = try await service.generateInsight(
                periodType: .weekly,
                start: weekStart,
                end: weekEnd,
                forceRefresh: false
            )
            logger.info("前台补偿生成成功")
        } catch {
            logger.error("前台补偿生成失败：\(error.localizedDescription)")
        }
    }
}
