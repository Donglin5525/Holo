#if DEBUG
//
//  HoloAppStoreScreenshotSeeder.swift
//  Holo
//
//  仅供 App Store 宣传图拍摄：在全新模拟器中构造可复现的虚构数据。
//

import CoreData
import Foundation

@MainActor
enum HoloAppStoreScreenshotSeeder {
    static let modeKey = "HOLO_APP_STORE_SCREENSHOT_MODE"
    static let routeKey = "HOLO_APP_STORE_SCREENSHOT_ROUTE"
    private static let seededKey = "holo_app_store_screenshot_seed_v6"

    enum Route: String {
        case home
        case aiActions = "ai-actions"
        case aiAnalysis = "ai-analysis"
        case aiFollowUp = "ai-follow-up"
        case memoryCalendar = "memory-calendar"
        case financeStats = "finance-stats"
        case memoryInsight = "memory-insight"
    }

    static var isRequested: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[modeKey] == "1"
        #else
        false
        #endif
    }

    static var requestedRoute: Route? {
        #if targetEnvironment(simulator)
        guard isRequested,
              let value = ProcessInfo.processInfo.environment[routeKey] else { return nil }
        return Route(rawValue: value)
        #else
        return nil
        #endif
    }

    @discardableResult
    static func runIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async -> Bool {
        #if targetEnvironment(simulator)
        guard environment[modeKey] == "1" else { return false }

        UserDisplayNameSettings(userDefaults: defaults).saveDisplayName("小满")
        HoloAIDataProcessingConsent.shared.grant()
        defaults.set(false, forKey: "holo_darkModeEnabled")

        // 记忆长廊打开时会在配额充足的情况下主动刷新回放；截图模式耗尽当日
        // 配额，确保本地演示回放不会被异步生成结果覆盖。
        let insightQuota = MemoryInsightRefreshQuota(userDefaults: defaults)
        while insightQuota.canRefresh() {
            _ = insightQuota.consume()
        }

        let context = CoreDataStack.shared.viewContext
        do {
            if defaults.bool(forKey: seededKey) {
                try await replaceInsight(in: context, now: now)
                navigateIfRequested(environment: environment)
                return true
            }
            let seeded = try await seedAll(in: context, now: now)
            guard seeded else { return false }
            defaults.set(true, forKey: seededKey)
            NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            navigateIfRequested(environment: environment)
            return true
        } catch {
            assertionFailure("App Store 截图场景构造失败：\(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    private static func navigateIfRequested(environment: [String: String]) {
        guard let rawValue = environment[routeKey],
              let route = Route(rawValue: rawValue) else { return }

        switch route {
        case .home:
            break
        case .aiActions, .aiAnalysis, .aiFollowUp:
            DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
        case .memoryCalendar, .memoryInsight:
            DeepLinkState.shared.navigate(to: .memoryGallery)
        case .financeStats:
            let range = TimeRange.month.dateRange()
            DeepLinkState.shared.navigate(to: .financeAnalysis(FinanceAnalysisDeepLink(
                label: "本月收支",
                start: range.start,
                end: range.end
            )))
        }
    }

    private static func replaceInsight(
        in context: NSManagedObjectContext,
        now: Date
    ) async throws {
        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "periodType == %@",
            MemoryInsightPeriodType.weekly.rawValue
        )
        for insight in try context.fetch(request) {
            context.delete(insight)
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: startOfToday
        )!
        try seedInsight(context: context, startOfWeek: startOfWeek)
        try context.save()
        try await seedStableMemory(now: now)
    }

    private static func seedAll(
        in context: NSManagedObjectContext,
        now: Date
    ) async throws -> Bool {
        FinanceRepository.shared.setup()
        guard let account = Account.getDefaultAccount(in: context) else { return false }
        // 用一个有开户余额、也有工资入账的账户还原真实用户场景，避免统计页只剩负数。
        account.initialBalance = NSDecimalNumber(string: "4800") ?? NSDecimalNumber.zero

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday)!

        let transactions = try await seedTransactions(
            context: context,
            account: account,
            startOfWeek: startOfWeek
        )
        let habit = try seedHabits(context: context, startOfWeek: startOfWeek)
        let task = try seedTasks(context: context, startOfWeek: startOfWeek)
        try seedThoughts(context: context, startOfWeek: startOfWeek)
        try seedConversation(
            context: context,
            transaction: transactions.actionTransaction,
            task: task,
            habit: habit,
            startOfWeek: startOfWeek
        )
        try seedInsight(context: context, startOfWeek: startOfWeek)
        try context.save()
        try await seedStableMemory(now: now)
        return true
    }

    private static func seedStableMemory(now: Date) async throws {
        let anchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "weekday-morning-reading"
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        let record = HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: "weekday-morning-reading",
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "晨间阅读已经成为工作日里最稳定的习惯。",
            aiUseSummary: "用户近期在工作日持续进行晨间阅读，已形成稳定节奏。",
            prohibitedInferences: ["不要据此推断未记录日期也完成了阅读"],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: "app-store-screenshot-reading-streak",
                kind: .entityRef,
                sourceDomain: .habit,
                lineageKey: "app-store-screenshot-reading-streak",
                sourceID: "weekday-morning-reading",
                revisionDigest: "v1",
                observedAt: now
            )],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: 0.9,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
        let repository = try await HoloMemoryRuntime.shared.repository()
        _ = try await repository.upsert(
            record,
            observationKey: "app-store-screenshot-memory-v1"
        )
    }

    private struct SeededTransactions {
        let actionTransaction: Transaction
    }

    private static func seedTransactions(
        context: NSManagedObjectContext,
        account: Account,
        startOfWeek: Date
    ) async throws -> SeededTransactions {
        let categories = try context.fetch(Category.fetchRequest())
        let byName = Dictionary(grouping: categories.filter(\.isSubCategory), by: \.name)
        // 统计页默认展示“本月至今”，所以所有支出都落在本月已经发生的前 7 天内。
        let samples: [(day: Int, hour: Int, minute: Int, amount: Decimal, category: String, note: String)] = [
            (1, 8, 15, 26, "早餐", "早餐和豆浆"),
            (1, 12, 20, 45, "午餐", "工作日午餐"),
            (1, 18, 40, 22, "早餐", "下班路上的简餐"),
            (2, 9, 10, 68, "晚餐", "下班后的简餐"),
            (2, 12, 35, 79, "书籍", "产品设计书"),
            (2, 20, 15, 36, "水果", "水果补给"),
            (3, 8, 5, 6, "地铁", "回家地铁"),
            (3, 12, 18, 48, "午餐", "工作日午餐"),
            (3, 19, 30, 52, "午餐", "午餐"),
            (4, 8, 20, 36, "早餐", "早餐"),
            (4, 19, 30, 68, "电影", "晚间电影"),
            (5, 8, 20, 28, "咖啡", "晨间咖啡"),
            (5, 12, 25, 79, "日用", "家庭用品"),
            (5, 18, 55, 168, "买菜", "本周食材"),
            (6, 19, 15, 188, "火锅", "朋友小聚"),
            (6, 9, 20, 32, "早餐", "慢慢吃早餐"),
            (6, 16, 40, 46, "午餐", "下午茶")
        ]

        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: startOfWeek)?.start ?? startOfWeek
        guard let salaryCategory = byName["工资"]?.first else {
            throw ScreenshotSeedError.missingCategory("工资")
        }
        _ = try await FinanceRepository.shared.addTransaction(
            amount: 8_500,
            type: .income,
            category: salaryCategory,
            account: account,
            date: date(from: monthStart, dayOffset: 2, hour: 9, minute: 0),
            note: "本月工资入账"
        )

        var actionTransaction: Transaction?
        for sample in samples {
            guard let category = byName[sample.category]?.first else { continue }
            let date = date(
                from: monthStart,
                dayOffset: sample.day,
                hour: sample.hour,
                minute: sample.minute
            )
            let transaction = try await FinanceRepository.shared.addTransaction(
                amount: sample.amount,
                type: .expense,
                category: category,
                account: account,
                date: date,
                note: sample.note
            )
            if sample.category == "午餐" && sample.amount == 45 {
                actionTransaction = transaction
            }
        }

        guard let actionTransaction else {
            throw ScreenshotSeedError.missingCategory("午餐")
        }
        return SeededTransactions(actionTransaction: actionTransaction)
    }

    private static func seedHabits(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws -> Habit {
        let reading = Habit.create(
            in: context,
            name: "晨间阅读",
            icon: "book.fill",
            color: "#FF6B35",
            type: .checkIn,
            frequency: .daily,
            targetCount: 1,
            sortOrder: 0
        )
        let walk = Habit.create(
            in: context,
            name: "夜间散步",
            icon: "figure.walk",
            color: "#34C759",
            type: .checkIn,
            frequency: .daily,
            targetCount: 1,
            sortOrder: 1
        )
        let sleep = Habit.create(
            in: context,
            name: "23:30 前休息",
            icon: "moon.stars.fill",
            color: "#7C4DFF",
            type: .checkIn,
            frequency: .daily,
            targetCount: 1,
            sortOrder: 2
        )

        for day in 0...4 {
            let record = HabitRecord.createCheckIn(in: context, habit: reading)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 8, minute: 35)
            record.createdAt = record.date
        }
        for day in [0, 2, 3, 5] {
            let record = HabitRecord.createCheckIn(in: context, habit: walk)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 20, minute: 25)
            record.createdAt = record.date
        }
        for day in [1, 2, 4] {
            let record = HabitRecord.createCheckIn(in: context, habit: sleep)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 23, minute: 10)
            record.createdAt = record.date
        }
        return reading
    }

    private static func seedTasks(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws -> TodoTask {
        let completedSamples: [(String, Int, Int)] = [
            ("整理本周重点", 0, 10),
            ("确认 App Store 文案", 1, 15),
            ("完成产品回顾", 2, 18),
            ("整理发布清单", 3, 16)
        ]
        for sample in completedSamples {
            let completedAt = date(from: startOfWeek, dayOffset: sample.1, hour: sample.2, minute: 20)
            let task = TodoTask.create(
                in: context,
                title: sample.0,
                priority: .medium,
                dueDate: completedAt
            )
            task.completed = true
            task.status = TaskStatus.completed.rawValue
            task.completedAt = completedAt
            task.createdAt = completedAt.addingTimeInterval(-7_200)
            task.updatedAt = completedAt
        }

        let tomorrow = date(from: startOfWeek, dayOffset: 5, hour: 8, minute: 0)
        let actionTask = TodoTask.create(
            in: context,
            title: "明早带伞",
            priority: .medium,
            dueDate: tomorrow
        )
        return actionTask
    }

    private static func seedThoughts(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws {
        let repository = ThoughtRepository(context: context)
        let samples: [(String, String, [String], Int, Int)] = [
            ("把复杂的计划拆小之后，开始反而变得容易了。", "calm", ["成长"], 0, 21),
            ("今天最值得记住的，是留出了真正不被打扰的一小时。", "happy", ["生活"], 2, 22),
            ("记录不是为了追求完美，而是为了看见自己正在发生什么。", "inspired", ["复盘"], 4, 21)
        ]
        for sample in samples {
            let thought = try repository.create(
                content: sample.0,
                mood: sample.1,
                tags: sample.2
            )
            let createdAt = date(
                from: startOfWeek,
                dayOffset: sample.3,
                hour: sample.4,
                minute: 10
            )
            thought.createdAt = createdAt
            thought.updatedAt = createdAt
            thought.organizedStatus = "organized"
        }
    }

    private static func seedConversation(
        context: NSManagedObjectContext,
        transaction: Transaction,
        task: TodoTask,
        habit: Habit,
        startOfWeek: Date
    ) throws {
        let base = date(from: startOfWeek, dayOffset: 4, hour: 20, minute: 10)
        let userActionID = insertMessage(
            in: context,
            role: "user",
            content: "午餐 36 元，提醒我明早带伞，再给晨间阅读打卡",
            timestamp: base
        )

        let execution = AIExecutionBatch(
            mode: .multiAction,
            items: [
                AIExecutionItem(
                    id: "screenshot-expense",
                    parseItemId: "screenshot-expense-parse",
                    intent: .recordExpense,
                    status: .success,
                    summaryText: "已记录午餐 36 元",
                    renderData: [
                        "amount": "36",
                        "note": "午餐",
                        "primaryCategory": "餐饮",
                        "subCategory": "午餐",
                        "transactionDate": "今天 12:20",
                        "confirmationStatus": "confirmed"
                    ],
                    linkedEntityType: "transaction",
                    linkedEntityId: transaction.id.uuidString,
                    errorText: nil
                ),
                AIExecutionItem(
                    id: "screenshot-task",
                    parseItemId: "screenshot-task-parse",
                    intent: .createTask,
                    status: .success,
                    summaryText: "已创建明早带伞",
                    renderData: [
                        "title": "明早带伞",
                        "dueDate": "明天 08:00",
                        "priority": "medium",
                        "confirmationStatus": "confirmed"
                    ],
                    linkedEntityType: "task",
                    linkedEntityId: task.id.uuidString,
                    errorText: nil
                ),
                AIExecutionItem(
                    id: "screenshot-habit",
                    parseItemId: "screenshot-habit-parse",
                    intent: .checkIn,
                    status: .success,
                    summaryText: "晨间阅读打卡完成",
                    renderData: [
                        "habitName": "晨间阅读",
                        "streak": "5",
                        "completed": "true"
                    ],
                    linkedEntityType: "habit",
                    linkedEntityId: habit.id.uuidString,
                    errorText: nil
                )
            ],
            finalText: "三件事都处理好了"
        )
        let actionAssistant = ChatMessage(context: context)
        actionAssistant.id = UUID()
        actionAssistant.role = "assistant"
        actionAssistant.content = "三件事都处理好了"
        actionAssistant.timestamp = base.addingTimeInterval(5)
        actionAssistant.intent = nil
        actionAssistant.isStreaming = false
        actionAssistant.parentMessageId = userActionID
        actionAssistant.messageType = ChatMessageType.normal.rawValue
        actionAssistant.executionBatchJSON = try encode(execution)

        let queryTime = base.addingTimeInterval(60)
        let queryID = insertMessage(
            in: context,
            role: "user",
            content: "这个月消费有什么变化？",
            timestamp: queryTime
        )
        let finance = FinanceAnalysisContext(
            totalExpense: 1_027,
            totalIncome: 8_500,
            transactionCount: 18,
            averageDailyExpense: 33.13,
            topExpenseCategories: [
                FinanceCategoryItem(categoryName: "餐饮", amount: 627, percentage: 61.0),
                FinanceCategoryItem(categoryName: "购物", amount: 326, percentage: 31.7),
                FinanceCategoryItem(categoryName: "娱乐", amount: 68, percentage: 6.6)
            ],
            monthlyBreakdown: [],
            previousPeriodExpense: 1_224,
            anomalyDescriptions: [],
            budgetPerformance: FinanceBudgetItem(
                budgetAmount: 2_000,
                spentAmount: 1_027,
                remainingAmount: 973,
                utilizationRate: 0.5135,
                periodType: "monthly"
            ),
            subCategoryDetails: nil,
            categoryTrends: nil,
            spendingPatterns: nil,
            semanticSummary: nil
        )
        let analysis = AnalysisContext(
            domain: .finance,
            periodLabel: "本月",
            startDate: "2026-07-01",
            endDate: "2026-07-31",
            comparisonLabel: "上月同期",
            finance: finance,
            habit: nil,
            task: nil,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: nil
        )
        let analysisAssistant = ChatMessage(context: context)
        analysisAssistant.id = UUID()
        analysisAssistant.role = "assistant"
        analysisAssistant.content = "整体支出比上月同期低一些，餐饮仍是占比最高的日常支出。"
        analysisAssistant.timestamp = queryTime.addingTimeInterval(5)
        analysisAssistant.intent = AIIntent.queryAnalysis.rawValue
        analysisAssistant.isStreaming = false
        analysisAssistant.parentMessageId = queryID
        analysisAssistant.messageType = ChatMessageType.normal.rawValue
        analysisAssistant.analysisContextJSON = try encode(analysis)

        let followUpTime = queryTime.addingTimeInterval(20)
        let followUpID = insertMessage(
            in: context,
            role: "user",
            content: "那我下周最该保持什么？",
            timestamp: followUpTime
        )
        let followUpAnalysis = AnalysisContext(
            domain: .crossModule,
            periodLabel: "下周建议",
            startDate: "2026-08-10",
            endDate: "2026-08-16",
            comparisonLabel: "基于刚才的本月记录",
            finance: nil,
            habit: nil,
            task: nil,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: CrossModuleAnalysisContext(
                highlights: [
                    "晨间阅读已连续 5 天，是最稳定的起点",
                    "工作日消费更集中，节奏更容易延续"
                ],
                warnings: ["周末晚餐支出明显高于工作日"]
            )
        )
        let followUpAssistant = ChatMessage(context: context)
        followUpAssistant.id = UUID()
        followUpAssistant.role = "assistant"
        followUpAssistant.content = "沿用刚才看到的消费和习惯记录，下周先保持晨间阅读，再把周末晚餐提前安排好。"
        followUpAssistant.timestamp = followUpTime.addingTimeInterval(5)
        // 追问后的回复保留为普通可读消息，让截图直接呈现“承接上一轮上下文后的建议”。
        followUpAssistant.intent = nil
        followUpAssistant.isStreaming = false
        followUpAssistant.parentMessageId = followUpID
        followUpAssistant.messageType = ChatMessageType.normal.rawValue
        followUpAssistant.analysisContextJSON = try encode(followUpAnalysis)
    }

    private static func seedInsight(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws {
        // 洞察页默认展示最近一个完整周期，因此用上周而不是尚未结束的本周。
        let insightStart = Calendar.current.date(byAdding: .day, value: -7, to: startOfWeek)!
        let end = startOfWeek
        let payload = MemoryInsightPayload(
            title: "这一周，节奏慢慢稳下来了",
            summary: "你在保持晨间阅读的同时，日常支出也比上周更平稳。",
            cards: [
                MemoryInsightCard(
                    id: "screenshot-overview",
                    type: .overview,
                    title: "生活节奏正在变得清晰",
                    body: "工作日保持了稳定的记录，周末也给自己留出了更松弛的空间。",
                    evidence: [],
                    suggestedQuestion: "帮我继续保持这个节奏",
                    moduleHint: "overview"
                ),
                MemoryInsightCard(
                    id: "screenshot-habit",
                    type: .habit,
                    title: "晨间阅读连续了 5 天",
                    body: "阅读正在从临时安排，慢慢变成每天都能自然发生的一件事。",
                    evidence: [],
                    suggestedQuestion: "最近哪天最容易坚持？",
                    moduleHint: "habit"
                ),
                MemoryInsightCard(
                    id: "screenshot-cross",
                    type: .crossDomain,
                    title: "支出更平稳，留白也更多",
                    body: "这周没有明显的冲动消费；记录显示，你在节奏稳定时更愿意为阅读和散步留时间。",
                    evidence: [],
                    suggestedQuestion: "帮我回顾这周的变化",
                    moduleHint: "finance,habit"
                )
            ],
            suggestedQuestions: [
                "帮我回顾这周的变化",
                "下周最值得保持什么？"
            ]
        )
        let insight = MemoryInsight.createGenerating(
            in: context,
            periodType: .weekly,
            start: insightStart,
            end: end,
            snapshotHash: "app-store-screenshot-v1"
        )
        insight.markReady(
            payload: payload,
            rawResponse: "",
            providerName: nil,
            promptVersion: 1
        )
    }

    @discardableResult
    private static func insertMessage(
        in context: NSManagedObjectContext,
        role: String,
        content: String,
        timestamp: Date
    ) -> UUID {
        let message = ChatMessage(context: context)
        message.id = UUID()
        message.role = role
        message.content = content
        message.timestamp = timestamp
        message.isStreaming = false
        message.messageType = ChatMessageType.normal.rawValue
        return message.id
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ScreenshotSeedError.encodingFailed
        }
        return json
    }

    private static func date(
        from startOfWeek: Date,
        dayOffset: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfWeek)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
}

private enum ScreenshotSeedError: LocalizedError {
    case missingCategory(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingCategory(let name): return "缺少演示分类：\(name)"
        case .encodingFailed: return "演示 JSON 编码失败"
        }
    }
}
#endif
