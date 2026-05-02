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

        let repository = MemoryInsightRepository()

        // 生成本周洞察（使用智能回退）
        let (weekStart, weekEnd, _) = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .weekly, referenceDate: Date()
        )

        if let existing = try? repository.fetchInsight(
            periodType: .weekly, start: weekStart, end: weekEnd
        ), existing.insightStatus == .ready {
            logger.info("周洞察已存在且为 ready，跳过")
        } else {
            do {
                let insight = try await service.generateInsight(
                    periodType: .weekly,
                    start: weekStart,
                    end: weekEnd,
                    forceRefresh: false
                )
                logger.info("后台周洞察生成成功：\(insight.title)")
            } catch {
                logger.error("后台周洞察生成失败：\(error.localizedDescription)")
            }
        }

        // 生成月度洞察（使用智能回退）
        let (monthStart, monthEnd, monthFallback) = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .monthly, referenceDate: Date()
        )

        if monthFallback {
            // 回退到上月，检查上月洞察是否已存在
            if let existing = try? repository.fetchInsight(
                periodType: .monthly, start: monthStart, end: monthEnd
            ), existing.insightStatus == .ready {
                logger.info("上月月度洞察已存在，跳过")
            } else {
                do {
                    let insight = try await service.generateInsight(
                        periodType: .monthly,
                        start: monthStart,
                        end: monthEnd,
                        forceRefresh: false
                    )
                    logger.info("后台月度洞察生成成功：\(insight.title)")
                } catch {
                    logger.error("后台月度洞察生成失败：\(error.localizedDescription)")
                }
            }
        }

        let content = MemoryInsightNotificationService()
        task.setTaskCompleted(success: true)

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

        let repository = MemoryInsightRepository()

        // 补生成周洞察（使用智能回退）
        let (weekStart, weekEnd, _) = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .weekly, referenceDate: Date()
        )

        if let _ = try? repository.fetchInsight(
            periodType: .weekly, start: weekStart, end: weekEnd
        ) {
            // 周洞察已存在，跳过
        } else {
            logger.info("前台补偿：尝试生成周洞察")
            do {
                _ = try await service.generateInsight(
                    periodType: .weekly,
                    start: weekStart,
                    end: weekEnd,
                    forceRefresh: false
                )
                logger.info("前台补偿周洞察生成成功")
            } catch {
                logger.error("前台补偿周洞察生成失败：\(error.localizedDescription)")
            }
        }

        // 补生成月度洞察（使用智能回退）
        let (monthStart, monthEnd, monthFallback) = MemoryInsightContextBuilder.effectivePeriodRange(
            periodType: .monthly, referenceDate: Date()
        )

        if monthFallback {
            if let _ = try? repository.fetchInsight(
                periodType: .monthly, start: monthStart, end: monthEnd
            ) {
                // 上月洞察已存在，跳过
            } else {
                logger.info("前台补偿：尝试生成月度洞察")
                do {
                    _ = try await service.generateInsight(
                        periodType: .monthly,
                        start: monthStart,
                        end: monthEnd,
                        forceRefresh: false
                    )
                    logger.info("前台补偿月度洞察生成成功")
                } catch {
                    logger.error("前台补偿月度洞察生成失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
