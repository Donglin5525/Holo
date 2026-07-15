//
//  MemorySignalDataAdapter.swift
//  Holo
//
//  从 Repository 层采集数据并转换为 Memory Observer 信号输入
//

import Foundation
import CoreData

enum MemorySignalDataAdapter {

    /// 运行时统一采集入口。只返回 Builder 允许的白名单信号；没有可靠结构化来源的领域保持为空。
    static func buildDomainSignals(now: Date = Date()) async -> [HoloMemoryDomain: [HoloDomainMemorySignal]] {
        async let financeInput = buildFinanceMemorySnapshotInput(now: now)
        async let healthInputs = buildHealthMemoryAggregateInputs(now: now)
        async let conversationInputs = buildConversationMemoryInputs(now: now)

        let finance = await financeInput
        let health = await healthInputs
        let conversations = await conversationInputs
        let thoughtInputs = buildThoughtMemoryInputs(now: now)
        let taskInputs = buildTaskMemoryInputs(now: now)
        let habitInputs = buildHabitDomainMemoryInputs(now: now)
        let goalInputs = buildGoalDomainMemoryInputs(now: now)

        return [
            .finance: addRoutineAnchor(to: FinanceMemorySignalBuilder.build(from: finance)),
            .thought: ThoughtMemorySignalBuilder.build(from: thoughtInputs),
            .health: addRoutineAnchor(to: HealthMemorySignalBuilder.build(from: health)),
            .habit: addRoutineAnchor(to: HabitMemorySignalBuilder.buildDomainSignals(from: habitInputs)),
            .task: addRoutineAnchor(to: TaskMemorySignalBuilder.build(from: taskInputs, now: now)),
            .goal: addRoutineAnchor(to: GoalMemorySignalBuilder.buildDomainSignals(from: goalInputs)),
            .conversation: ConversationMemorySignalBuilder.build(from: conversations),
            // Profile 只接受用户显式维护和旧记忆迁移，后台观察不得静默改写。
            .profile: []
        ]
    }

    // MARK: - Finance → FinanceMemorySnapshotInput

    static func buildFinanceMemorySnapshotInput(
        now: Date = Date()
    ) async -> FinanceMemorySnapshotInput {
        let calendar = Calendar.current
        let currentStart = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -180, to: now) ?? currentStart
        let transactions = (try? await FinanceRepository.shared.getAllTransactions()) ?? []
        let mapped = transactions.compactMap { transaction -> FinanceMemoryTransactionInput? in
            guard let category = transaction.category else { return nil }
            let names = FinanceRepository.shared.resolveCategoryNames(from: category)
            let categoryName = names.sub ?? names.primary
            let merchant = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FinanceMemoryTransactionInput(
                id: transaction.id.uuidString,
                amount: transaction.amount.doubleValue,
                isExpense: transaction.transactionType == .expense,
                categoryID: category.id.uuidString,
                categoryName: categoryName,
                merchant: merchant?.isEmpty == false ? merchant : nil,
                occurredAt: transaction.date,
                revisionDigest: "\(transaction.updatedAt.timeIntervalSince1970)-\(transaction.amount.stringValue)-\(category.id.uuidString)"
            )
        }

        let request = Budget.fetchRequest()
        let budgets = (try? FinanceRepository.shared.context.fetch(request)) ?? []
        let budgetInputs = budgets.compactMap { budget -> FinanceMemoryBudgetInput? in
            guard let status = BudgetRepository.shared.computeBudgetStatus(budget: budget) else {
                return nil
            }
            let categoryName: String
            if let categoryID = budget.categoryId,
               let category = FinanceRepository.shared.findCategory(by: categoryID) {
                categoryName = FinanceRepository.shared.resolveCategoryNames(from: category).primary
            } else {
                categoryName = "总预算"
            }
            return FinanceMemoryBudgetInput(
                id: budget.id.uuidString,
                categoryID: budget.categoryId?.uuidString,
                categoryName: categoryName,
                budgetAmount: NSDecimalNumber(decimal: status.budgetAmount).doubleValue,
                spentAmount: NSDecimalNumber(decimal: status.spentAmount).doubleValue,
                revisionDigest: "\(budget.updatedAt.timeIntervalSince1970)-\(budget.amount.stringValue)-\(status.spentAmount)"
            )
        }

        return FinanceMemorySnapshotInput(
            currentTransactions: mapped.filter { $0.occurredAt >= currentStart && $0.occurredAt <= now },
            previousTransactions: mapped.filter { $0.occurredAt >= previousStart && $0.occurredAt < currentStart },
            budgets: budgetInputs,
            windowStart: currentStart,
            windowEnd: now
        )
    }

    // MARK: - Thought → explicit stance only

    static func buildThoughtMemoryInputs(now: Date = Date()) -> [ThoughtMemoryInput] {
        let recentStart = Calendar.current.date(byAdding: .day, value: -180, to: now) ?? .distantPast
        let thoughts = (try? ThoughtRepository().fetchAll(limit: 200)) ?? []
        let stanceCues = ["我认为", "我觉得", "我的观点", "我支持", "我反对", "我不认同", "我更认同"]
        return thoughts.compactMap { thought in
            guard thought.updatedAt >= recentStart,
                  stanceCues.contains(where: { thought.content.contains($0) }) else { return nil }
            let topics = (thought.topics as? Set<Topic>)?.map(\.title).sorted() ?? []
            let topic = topics.first ?? "个人观点"
            return ThoughtMemoryInput(
                id: thought.id.uuidString,
                originalText: thought.content,
                explicitStance: thought.content,
                aiSummary: nil,
                topic: topic,
                revisionDigest: "\(thought.updatedAt.timeIntervalSince1970)-\(stableDigest(thought.content))",
                createdAt: thought.createdAt
            )
        }
    }

    // MARK: - Health → local aggregates only

    static func buildHealthMemoryAggregateInputs(now: Date = Date()) async -> [HealthMemoryAggregateInput] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let repository = await MainActor.run { HealthRepository.shared }
        async let steps = repository.fetchStepsRange(from: start, to: now)
        async let sleep = repository.fetchSleepRange(from: start, to: now)
        async let stand = repository.fetchStandTimeRange(from: start, to: now)
        async let active = repository.fetchActiveMinutesRange(from: start, to: now)
        let (stepData, sleepData, standData, activeData) = await (steps, sleep, stand, active)
        let values: [(String, String, [DailyHealthData])] = [
            ("steps", "步数", stepData),
            ("sleep", "睡眠", sleepData),
            ("standHours", "站立时长", standData),
            ("activeMinutes", "活动分钟", activeData)
        ]
        return values.compactMap { key, name, samples in
            let valid = samples.filter { $0.value > 0 && $0.value.isFinite }
            guard !valid.isEmpty else { return nil }
            let rawDigest = valid
                .map { "\(Int($0.date.timeIntervalSince1970)):\($0.value)" }
                .sorted()
                .joined(separator: "|")
            let numbers = valid.map(\.value)
            return HealthMemoryAggregateInput(
                metricKey: key,
                displayName: name,
                average: numbers.reduce(0, +) / Double(numbers.count),
                minimum: numbers.min(),
                maximum: numbers.max(),
                sampleCount: numbers.count,
                windowStart: start,
                windowEnd: now,
                revisionDigest: stableDigest(rawDigest)
            )
        }
    }

    // MARK: - Task → rhythm aggregates

    static func buildTaskMemoryInputs(now: Date = Date()) -> [TaskMemoryInput] {
        let request = TodoTask.fetchRequest()
        let start = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? .distantPast
        request.predicate = NSPredicate(
            format: "deletedFlag == NO AND (createdAt >= %@ OR updatedAt >= %@)",
            start as NSDate,
            start as NSDate
        )
        request.fetchLimit = 500
        let tasks = (try? CoreDataStack.shared.viewContext.fetch(request)) ?? []
        return tasks.map { task in
            TaskMemoryInput(
                id: task.id.uuidString,
                title: task.title,
                typeKey: task.list?.id.uuidString ?? "inbox",
                completed: task.completed,
                createdAt: task.createdAt,
                dueAt: task.dueDate,
                completedAt: task.completedAt,
                revisionDigest: "\(task.updatedAt.timeIntervalSince1970)-\(task.completed)-\(task.dueDate?.timeIntervalSince1970 ?? 0)"
            )
        }
    }

    // MARK: - Conversation → explicit user statements only

    static func buildConversationMemoryInputs(now: Date = Date()) async -> [ConversationMemoryInput] {
        await CoreDataStack.shared.waitUntilReady()
        let start = Calendar.current.date(byAdding: .day, value: -180, to: now) ?? .distantPast
        return (try? await Task.detached(priority: .utility) {
            let context = CoreDataStack.shared.newBackgroundContext()
            return try await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "ChatMessage")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id", "role", "content", "timestamp"]
                request.predicate = NSPredicate(
                    format: "role == %@ AND isStreaming == NO AND timestamp >= %@",
                    "user",
                    start as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                request.fetchLimit = 200
                return try context.fetch(request).compactMap { dictionary in
                    guard let id = dictionary["id"] as? UUID,
                          let content = dictionary["content"] as? String,
                          let timestamp = dictionary["timestamp"] as? Date,
                          let kind = conversationStatementKind(for: content) else { return nil }
                    return ConversationMemoryInput(
                        id: id.uuidString,
                        role: .user,
                        statementKind: kind,
                        text: content,
                        revisionDigest: stableDigest(content),
                        createdAt: timestamp,
                        profileAnchor: nil
                    )
                }
            }
        }.value) ?? []
    }

    nonisolated private static func conversationStatementKind(
        for content: String
    ) -> ConversationMemoryStatementKind? {
        let preferenceCues = ["我喜欢", "我不喜欢", "我更喜欢", "我偏好", "我更偏好"]
        if preferenceCues.contains(where: { content.contains($0) }) { return .explicitPreference }
        let contextCues = ["请记住", "记住我", "以后请", "以后不要", "对我来说很重要"]
        if contextCues.contains(where: { content.contains($0) }) { return .importantContext }
        let correctionCues = ["不是这样的", "你记错了", "纠正一下"]
        if correctionCues.contains(where: { content.contains($0) }) { return .correction }
        return nil
    }

    nonisolated private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// 周期性聚合统一带上“当前生活节奏”锚点，跨域候选仍需共同窗口和独立证据才能成立。
    nonisolated private static func addRoutineAnchor(
        to signals: [HoloDomainMemorySignal]
    ) -> [HoloDomainMemorySignal] {
        guard let routine = try? HoloMemoryAnchorRef(
            type: .userTheme,
            value: "current-routine",
            displayLabel: "最近的生活节奏"
        ) else { return signals }
        return signals.map { signal in
            guard signal.kind == .aggregate || signal.kind == .trend else { return signal }
            var updated = signal
            updated.anchors = HoloMemoryIdentity.canonicalAnchors(signal.anchors + [routine])
            return updated
        }
    }

    // MARK: - Habit → HabitFocusSummary

    static func buildHabitFocusSummaries() -> [HabitFocusSummary] {
        let repo = HabitRepository.shared
        repo.loadActiveHabits()
        let habits = repo.activeHabits
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 当前窗口：过去 14 天
        guard let currentStart = calendar.date(byAdding: .day, value: -14, to: today) else { return [] }
        let currentRange = currentStart...today

        // 上一窗口：再往前 14 天
        guard let previousStart = calendar.date(byAdding: .day, value: -14, to: currentStart) else { return [] }
        let previousRange = previousStart...currentStart

        return habits.compactMap { habit in
            let current = repo.evaluatePerformance(for: habit, in: currentRange)
            let previous = repo.evaluatePerformance(for: habit, in: previousRange)
            let streak = repo.calculateStreakInfo(for: habit)
            let signal = HabitFocusSignal.classify(
                habitName: habit.name,
                isBadHabit: habit.isBadHabit,
                goalTitle: habit.goal?.title,
                profileContext: nil
            )

            return HabitFocusSummary(
                habitName: habit.name,
                signal: signal,
                current: current,
                previous: previous,
                currentStreak: streak.value,
                goalTitle: habit.goal?.title
            )
        }
    }

    static func buildHabitDomainMemoryInputs(now: Date = Date()) -> [HabitDomainMemoryInput] {
        let repo = HabitRepository.shared
        repo.loadActiveHabits()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let currentStart = calendar.date(byAdding: .day, value: -14, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -14, to: currentStart) else {
            return []
        }
        return repo.activeHabits.map { habit in
            let current = repo.evaluatePerformance(for: habit, in: currentStart...today)
            let previous = repo.evaluatePerformance(for: habit, in: previousStart...currentStart)
            return HabitDomainMemoryInput(
                id: habit.id.uuidString,
                name: habit.name,
                isBadHabit: habit.isBadHabit,
                totalDays: current.totalDays,
                completedDays: current.completedDays,
                previousCompletionRate: previous.completionRate,
                currentStreak: repo.calculateStreakInfo(for: habit).value,
                revisionDigest: "\(habit.updatedAt.timeIntervalSince1970)-\(current.completedDays)-\(current.totalDays)",
                observedAt: now
            )
        }
    }

    // MARK: - Goal → GoalProgressInput

    static func buildGoalProgressInputs() -> [GoalProgressInput] {
        let goals = GoalRepository.shared.activeGoalsForAI(limit: 10)

        return goals.compactMap { goal in
            let tasks = goal.sortedTasks
            let completed = tasks.filter { $0.completed }.count

            return GoalProgressInput(
                id: goal.id.uuidString,
                title: goal.title,
                deadline: goal.deadline,
                createdAt: goal.createdAt,
                completedAt: goal.completedAt,
                status: goal.status,
                taskTotal: tasks.count,
                taskCompleted: completed
            )
        }
    }

    static func buildGoalDomainMemoryInputs(now: Date = Date()) -> [GoalDomainMemoryInput] {
        GoalRepository.shared.activeGoalsForAI(limit: 20).map { goal in
            let tasks = goal.sortedTasks
            let completed = tasks.filter(\.completed).count
            let progress = tasks.isEmpty
                ? (goal.completedAt != nil ? 1 : 0)
                : Double(completed) / Double(tasks.count)
            let expectedProgress: Double
            if let deadline = goal.deadline {
                let total = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: deadline
                ).day ?? 1
                let elapsed = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: now
                ).day ?? 0
                expectedProgress = total > 0
                    ? min(max(Double(elapsed) / Double(total), 0), 1)
                    : 1
            } else {
                let elapsed = Calendar.current.dateComponents(
                    [.day], from: goal.createdAt, to: now
                ).day ?? 0
                expectedProgress = min(max(Double(elapsed) / 30, 0), 1)
            }
            return GoalDomainMemoryInput(
                id: goal.id.uuidString,
                title: goal.title,
                // 只有已进入用户目标库的实体才进入记忆；未确认的系统建议不在此查询结果中。
                isUserCreated: goal.source != "suggestion",
                isCompleted: goal.completedAt != nil || goal.status == "completed",
                progress: progress,
                expectedProgress: expectedProgress,
                taskTotal: tasks.count,
                taskCompleted: completed,
                deadline: goal.deadline,
                previousDeadline: nil,
                revisionDigest: "\(goal.updatedAt.timeIntervalSince1970)-\(completed)-\(tasks.count)",
                observedAt: now
            )
        }
    }
}
