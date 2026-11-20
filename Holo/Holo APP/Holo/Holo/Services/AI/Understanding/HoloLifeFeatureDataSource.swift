//
//  HoloLifeFeatureDataSource.swift
//  Holo
//
//  Phase 1：七域真实数据源 → HoloLifeFeatureDistiller 适配层。
//
//  铁律：
//  - 只读，不修改任何业务库、不进 CloudKit。
//  - 严格遵守 AI 数据处理授权门（HoloAIDataProcessingConsent.shared.isGranted）。
//  - 金额与原始逐日明细留在本机，只输出脱敏特征包 CrossDomainFeaturePacket。
//

import Foundation
import CoreData

@MainActor
enum HoloLifeFeatureDataSource {

    /// 采集七域近 30~180 天只读数据并蒸馏为紧凑的跨模块特征包。
    /// 未获 AI 数据处理授权时返回 nil。
    static func buildPacket(now: Date = Date()) async -> CrossDomainFeaturePacket? {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return nil }
        let calendar = Calendar.current

        let finance = await loadFinanceInputs(now: now, calendar: calendar)
        let (sleep, steps, activeMinutes) = await loadHealthInputs(now: now, calendar: calendar)
        let habits = loadHabitInputs(now: now, calendar: calendar)
        let thoughts = loadThoughtInputs(now: now, calendar: calendar)
        let tasks = loadTaskInputs(now: now, calendar: calendar)
        let goals = loadGoalInputs()
        let profile = HoloProfileService.shared.loadProfile()
        let confirmedLegacy = await loadConfirmedLegacyMemories(now: now)

        return HoloLifeFeatureDistiller.distill(
            now: now,
            calendar: calendar,
            finance: finance,
            sleep: sleep,
            steps: steps,
            activeMinutes: activeMinutes,
            habits: habits,
            thoughts: thoughts,
            tasks: tasks,
            goals: goals,
            profileMarkdown: profile,
            confirmedLegacyMemories: confirmedLegacy
        )
    }

    /// 导出特征包 JSON（供调试或 Phase 2 盲测核验使用），并落盘到本机影子目录。
    static func exportLatestPacketJSON(now: Date = Date()) async -> String? {
        guard let packet = await buildPacket(now: now),
              let json = packet.encodeCompactJSON() else {
            return nil
        }
        let dir = UnderstandingShadowRunner.storageDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("feature_packet_latest.json")
        try? json.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        NSLog("[HoloLifeFeatureDataSource] 特征包已蒸馏: ~%d tokens, 财务概念=%d, 异常=%d",
              packet.estimatedTokens,
              packet.finance.recurringConcepts.count,
              packet.anomalies.count)
        return json
    }

    // MARK: - 1. 财务（近 180 天，覆盖低频周期消费如猫粮）

    private static func loadFinanceInputs(now: Date, calendar: Calendar) async -> [FinanceFeatureInput] {
        guard let windowStart = calendar.date(
            byAdding: .day,
            value: -HoloLifeFeatureDistiller.financeWindowDays,
            to: now
        ) else { return [] }

        let repository = FinanceRepository.shared
        guard let transactions = try? await repository.getStatisticsTransactions(from: windowStart, to: now) else {
            return []
        }

        return transactions.compactMap { tx in
            guard tx.transactionType == .expense, !tx.isRefund else { return nil }
            let note = tx.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let categoryName: String? = tx.category.map { cat in
                let names = repository.resolveCategoryNames(from: cat)
                return names.sub ?? names.primary
            }
            let comps = calendar.dateComponents([.hour, .minute, .second], from: tx.date)
            let isMidnight = (comps.hour == 0 && comps.minute == 0 && comps.second == 0)
            return FinanceFeatureInput(
                id: tx.id.uuidString,
                note: (note?.isEmpty == true) ? nil : note,
                categoryName: categoryName,
                occurredAt: tx.date,
                isMidnightDefault: isMidnight
            )
        }
    }

    // MARK: - 2. 健康（近 60 天：睡眠明细 + 步数 + 活动分钟数）

    private static func loadHealthInputs(
        now: Date,
        calendar: Calendar
    ) async -> ([HealthSleepFeatureInput], [HealthDailyMetricInput], [HealthDailyMetricInput]) {
        guard let windowStart = calendar.date(
            byAdding: .day,
            value: -HoloLifeFeatureDistiller.healthBaselineDays,
            to: now
        ) else { return ([], [], []) }

        let repo = HealthRepository.shared
        async let sleepDetails = repo.fetchSleepDetailRange(from: windowStart, to: now)
        async let stepsRange = repo.fetchStepsRange(from: windowStart, to: now)
        async let activeRange = repo.fetchActiveMinutesRange(from: windowStart, to: now)

        let (rawSleep, rawSteps, rawActive) = await (sleepDetails, stepsRange, activeRange)

        let sleepInputs = rawSleep.map { detail in
            HealthSleepFeatureInput(
                wakeDate: detail.date,
                totalHours: detail.totalHours,
                bedtime: detail.bedtime,
                wakeTime: detail.wakeTime
            )
        }
        let stepInputs = rawSteps.map { HealthDailyMetricInput(date: $0.date, value: $0.value) }
        let activeInputs = rawActive.map { HealthDailyMetricInput(date: $0.date, value: $0.value) }

        return (sleepInputs, stepInputs, activeInputs)
    }

    // MARK: - 3. 习惯（近 90 天，含数值型习惯 valueDouble 与 unit）

    private static func loadHabitInputs(now: Date, calendar: Calendar) -> [HabitFeatureInput] {
        guard let windowStart = calendar.date(byAdding: .day, value: -90, to: now) else { return [] }
        let context = CoreDataStack.shared.viewContext
        var result: [HabitFeatureInput] = []
        context.performAndWait {
            let habitsReq = Habit.fetchRequest()
            habitsReq.predicate = NSPredicate(format: "isArchived == NO AND deletedAt == nil")
            let habits = (try? context.fetch(habitsReq)) ?? []
            var habitByID: [UUID: Habit] = [:]
            for habit in habits {
                habitByID[habit.id] = habit
            }

            let recordsReq = HabitRecord.fetchRequest()
            recordsReq.predicate = NSPredicate(format: "date >= %@", windowStart as NSDate)
            recordsReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            recordsReq.fetchLimit = 2500

            for record in (try? context.fetch(recordsReq)) ?? [] {
                guard let habit = habitByID[record.habitId] else { continue }
                let name = habit.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                result.append(HabitFeatureInput(
                    habitID: record.habitId.uuidString,
                    habitName: name,
                    isNumeric: habit.type == HabitType.numeric.rawValue,
                    unit: habit.unit,
                    isPaused: habit.isPaused,
                    date: record.date,
                    isCompleted: record.isCompleted,
                    numericValue: record.valueDouble
                ))
            }
        }
        return result
    }

    // MARK: - 4. 想法（近 30 天，过滤「不参与 AI」标签）

    private static func loadThoughtInputs(now: Date, calendar: Calendar) -> [ThoughtFeatureInput] {
        guard let windowStart = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        let all = (try? ThoughtRepository().fetchAll(limit: 200)) ?? []
        let visible = ThoughtAIAudience.aiVisibleOnly(all)
        return visible.compactMap { thought in
            let created = thought.createdAt ?? thought.updatedAt
            guard created >= windowStart else { return nil }
            let text = thought.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ThoughtFeatureInput(id: thought.id.uuidString, text: text, createdAt: created)
        }
    }

    // MARK: - 5. 任务（近 30 天未删待办标题）

    private static func loadTaskInputs(now: Date, calendar: Calendar) -> [TaskFeatureInput] {
        guard let windowStart = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        let context = CoreDataStack.shared.viewContext
        var result: [TaskFeatureInput] = []
        context.performAndWait {
            let req = TodoTask.fetchRequest()
            req.predicate = NSPredicate(
                format: "deletedFlag == NO AND deletedAt == nil AND updatedAt >= %@",
                windowStart as NSDate
            )
            req.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            req.fetchLimit = 100
            for task in (try? context.fetch(req)) ?? [] {
                result.append(TaskFeatureInput(
                    title: task.title,
                    isCompleted: task.completed,
                    updatedAt: task.updatedAt
                ))
            }
        }
        return result
    }

    // MARK: - 6. 目标（活跃且允许 AI 上下文的目标）

    private static func loadGoalInputs() -> [GoalFeatureInput] {
        let context = CoreDataStack.shared.viewContext
        var result: [GoalFeatureInput] = []
        context.performAndWait {
            let req = NSFetchRequest<Goal>(entityName: "Goal")
            req.predicate = NSPredicate(format: "status == %@ AND allowAIContext == YES", "active")
            req.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            req.fetchLimit = 12
            for goal in (try? context.fetch(req)) ?? [] {
                result.append(GoalFeatureInput(
                    title: goal.title,
                    status: goal.status,
                    desiredOutcome: goal.desiredOutcome
                ))
            }
        }
        return result
    }

    // MARK: - 7. 既有用户已确认旧记忆（B 方案：保留并作为原料融入新版五维度画像，自动排除浅层算术模板）

    private static func loadConfirmedLegacyMemories(now: Date) async -> [String] {
        guard let repository = try? await HoloMemoryRuntime.shared.repository(),
              let resolved = try? await repository.resolvedKnowledgeAll(now: now) else {
            return []
        }
        return resolved
            .filter { $0.decision == .confirmedValid }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map(\.displayText)
            .filter { !HoloLifeFeatureDistiller.isLegacyShallowTemplate($0) }
    }
}
