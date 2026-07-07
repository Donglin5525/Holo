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
                guard let bgTask = task as? BGAppRefreshTask else { return }
                await self.handleBackgroundTask(bgTask)
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

        // 生成今日洞察（当天有足够数据时）
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            if let existing = try? repository.fetchInsight(
                periodType: .daily, start: today, end: tomorrow
            ), existing.insightStatus == .ready {
                logger.info("日洞察已存在且为 ready，跳过")
            } else {
                do {
                    let insight = try await service.generateInsight(
                        periodType: .daily,
                        start: today,
                        end: tomorrow,
                        forceRefresh: false
                    )
                    logger.info("后台日洞察生成成功：\(insight.title)")
                } catch {
                    logger.error("后台日洞察生成失败：\(error.localizedDescription)")
                }
            }
        }

        // 生成本周观察（基于有效记录日决定 stage，禁用 effectivePeriodRange.minDays，方案 §3.4/§4.3）
        await generateWeeklyObservation(service: service, repository: repository)

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

        // 补生成今日洞察
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            if let _ = try? repository.fetchInsight(
                periodType: .daily, start: today, end: tomorrow
            ) {
                // 日洞察已存在，跳过
            } else {
                logger.info("前台补偿：尝试生成日洞察")
                do {
                    _ = try await service.generateInsight(
                        periodType: .daily,
                        start: today,
                        end: tomorrow,
                        forceRefresh: false
                    )
                    logger.info("前台补偿日洞察生成成功")
                } catch {
                    logger.error("前台补偿日洞察生成失败：\(error.localizedDescription)")
                }
            }
        }

        // 补生成本周观察（基于有效记录日决定 stage，方案 §3.4/§4.3）
        logger.info("前台补偿：尝试生成本周观察")
        await generateWeeklyObservation(service: service, repository: repository)

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

    // MARK: - Weekly Observation（方案 §3.4 / §4.3）

    /// 生成本周观察：基于有效记录日决定 light3d / full7d，未达标则跳过（养成期不伪造洞察）
    private func generateWeeklyObservation(
        service: MemoryInsightService,
        repository: MemoryInsightRepository
    ) async {
        // 刷新有效记录日，拿最新 eligibility
        await EffectiveRecordDayService.shared.refreshAndWait()

        let stage: MemoryInsightObservationStage
        switch EffectiveRecordDayService.shared.currentResult?.eligibility {
        case .fullReady:
            stage = .full7d
        case .lightReady:
            stage = .light3d
        case .nurturing, .none:
            logger.info("有效记录日未达标，跳过本周观察生成（养成期）")
            return
        }

        // 用 periodRange 取本周范围（禁用 effectivePeriodRange.minDays，方案 §4.3）
        let (weekStart, weekEnd) = MemoryInsightContextBuilder.periodRange(
            periodType: .weekly, referenceDate: Date()
        )

        // 已存在同 stage 的 ready 洞察则跳过（避免重复生成）
        if let existing = try? repository.fetchInsight(
            periodType: .weekly, start: weekStart, end: weekEnd
        ), existing.insightStatus == .ready, existing.observationStageEnum == stage {
            logger.info("本周观察（\(stage.rawValue)）已存在且 ready，跳过")
            return
        }

        do {
            let insight = try await service.generateInsight(
                periodType: .weekly,
                start: weekStart,
                end: weekEnd,
                forceRefresh: false,
                observationStage: stage
            )
            logger.info("本周观察生成成功（\(stage.rawValue)）：\(insight.title)")
        } catch {
            logger.error("本周观察生成失败（\(stage.rawValue)）：\(error.localizedDescription)")
        }
    }
}
