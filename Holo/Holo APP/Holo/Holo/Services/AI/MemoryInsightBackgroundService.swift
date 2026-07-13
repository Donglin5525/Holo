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
    private let retryWeekKey = "holo.weeklyObservation.retry.week"
    private let retryCountKey = "holo.weeklyObservation.retry.count"
    private let retryAfterKey = "holo.weeklyObservation.retry.after"

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
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
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
        let service = MemoryInsightService.shared
        guard service.isAIConfigured else {
            logger.info("AI 未配置，跳过后台生成")
            task.setTaskCompleted(success: false)
            return
        }

        let repository = MemoryInsightRepository()

        // 上周洞察是产品基础能力，不依赖 legacy 日/月后台生成开关。
        await generatePreviousWeekObservationIfNeeded(
            service: service,
            repository: repository
        )

        guard settings.backgroundAutoGenerationEnabled else {
            task.setTaskCompleted(success: true)
            scheduleBackgroundTask()
            return
        }

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
        scheduleBackgroundTask()
    }

    // MARK: - Foreground Compensation

    /// 前台打开 App 时检查是否需要补生成
    /// 在 MemoryGalleryViewModel.refresh() 或 App 进入前台时调用
    func checkForegroundCompensation() async {
        let settings = MemoryInsightScheduleSettings.shared
        let service = MemoryInsightService.shared
        guard service.isAIConfigured else { return }
        guard !service.isGenerating else { return }

        let repository = MemoryInsightRepository()

        await generatePreviousWeekObservationIfNeeded(
            service: service,
            repository: repository
        )

        guard settings.backgroundAutoGenerationEnabled else { return }

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

    /// 生成上一完整自然周洞察；数据不足是正常跳过，不创建失败产物。
    func generatePreviousWeekObservationIfNeeded(
        referenceDate: Date = Date(),
        service: MemoryInsightService,
        repository: MemoryInsightRepository
    ) async {
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else { return }
        let period = WeeklyObservationPeriod.previousCompletedWeek(containing: referenceDate)
        guard canAttemptWeeklyObservation(period: period) else { return }
        let eligibility = await EffectiveRecordDayService.shared.result(for: period)
        guard eligibility.eligibility != .nurturing else {
            logger.info("上周有效记录不足，跳过洞察生成")
            return
        }

        if let existing = try? repository.fetchInsight(
            periodType: .weekly,
            start: period.start,
            end: period.end
        ), existing.insightStatus == .ready || existing.insightStatus == .stale {
            logger.info("上周洞察已存在，跳过重复生成")
            return
        }

        do {
            let insight = try await service.generateInsight(
                periodType: .weekly,
                start: period.start,
                end: period.end,
                forceRefresh: false,
                observationStage: .full7d
            )
            logger.info("上周洞察生成成功：\(insight.title)")
            clearWeeklyRetryState()
            HomeScheduleService.shared.refresh()
        } catch {
            recordWeeklyFailure(period: period)
            logger.error("上周洞察生成失败，等待下次前台恢复：\(error.localizedDescription)")
        }
    }

    private func canAttemptWeeklyObservation(
        period: WeeklyObservationPeriod,
        now: Date = Date()
    ) -> Bool {
        let defaults = UserDefaults.standard
        guard let storedWeek = defaults.object(forKey: retryWeekKey) as? Date,
              Calendar.current.isDate(storedWeek, inSameDayAs: period.start) else {
            clearWeeklyRetryState()
            return true
        }
        // 初次尝试后最多再恢复两次：1 分钟、10 分钟。
        guard defaults.integer(forKey: retryCountKey) < 3 else { return false }
        let retryAfter = defaults.object(forKey: retryAfterKey) as? Date ?? .distantPast
        return now >= retryAfter
    }

    private func recordWeeklyFailure(
        period: WeeklyObservationPeriod,
        now: Date = Date()
    ) {
        let defaults = UserDefaults.standard
        let sameWeek = (defaults.object(forKey: retryWeekKey) as? Date)
            .map { Calendar.current.isDate($0, inSameDayAs: period.start) } ?? false
        let count = sameWeek ? defaults.integer(forKey: retryCountKey) + 1 : 1
        let delay: TimeInterval = count == 1 ? 60 : 10 * 60
        defaults.set(period.start, forKey: retryWeekKey)
        defaults.set(count, forKey: retryCountKey)
        defaults.set(now.addingTimeInterval(delay), forKey: retryAfterKey)
    }

    private func clearWeeklyRetryState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: retryWeekKey)
        defaults.removeObject(forKey: retryCountKey)
        defaults.removeObject(forKey: retryAfterKey)
    }
}
