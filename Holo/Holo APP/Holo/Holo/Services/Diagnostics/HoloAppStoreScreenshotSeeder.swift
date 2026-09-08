#if DEBUG
//
//  HoloAppStoreScreenshotSeeder.swift
//  Holo
//
//  仅供 App Store 宣传图拍摄：在全新模拟器中构造可复现的虚构数据。
//

import CoreData
import Foundation
import UIKit

@MainActor
enum HoloAppStoreScreenshotSeeder {
    static let modeKey = "HOLO_APP_STORE_SCREENSHOT_MODE"
    static let routeKey = "HOLO_APP_STORE_SCREENSHOT_ROUTE"
    static let storyKey = "HOLO_APP_STORE_SCREENSHOT_STORY"
    private static let seededKey = "holo_app_store_screenshot_seed_v4"

    enum Route: String {
        case home
        case aiActions = "ai-actions"
        case aiAnalysis = "ai-analysis"
        case memoryCalendar = "memory-calendar"
        case memoryExtraction = "memory-extraction"
        case aiMemory = "ai-memory"
        case periodReplayMonthly = "period-replay-monthly"
        case periodReplayWeekly = "period-replay-weekly"
        case memoryGalleryMultiPhoto = "memory-gallery-multi-photo"
        case dailyKanban = "daily-kanban"
        case financeStats = "finance-stats"
        case memoryInsight = "memory-insight"
        case markdownTable = "markdown-table"
    }

    /// 拍摄剧本。rhythm 是首发笔记的「稳定节奏」剧本；milestoneAugust 是第二篇
    /// 笔记的「里程碑八月」剧本（2026 年 8 月，与对外笔记同期，日期固定）；
    /// busyWeek 是第四篇笔记的「忙碌一周」剧本（一句话三件事 → 时间线回看 →
    /// 深度分析 → 待确认观察），日期跟随拍摄当周。
    enum Story: String {
        case rhythm
        case milestoneAugust = "milestone-august"
        case busyWeek = "busy-week"
    }

    static var requestedStory: Story {
        #if targetEnvironment(simulator)
        guard isRequested else { return .rhythm }
        return Story(rawValue: ProcessInfo.processInfo.environment[storyKey] ?? "") ?? .rhythm
        #else
        return .rhythm
        #endif
    }

    /// 剧本各自的种子标记，避免同一台模拟器在切换剧本时复用上一部剧本的数据。
    private static func seededKeyValue(for story: Story) -> String {
        switch story {
        case .rhythm: return seededKey
        case .milestoneAugust: return seededKey + "_milestone_august"
        case .busyWeek: return seededKey + "_busy_week"
        }
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

        // 截图摆拍一律按 Plus 展示（小组件等 Plus 权益需完整出镜）；权益快照同步写给桌面小组件
        HoloEntitlementState.shared.applyScreenshotPlusOverride()
        HoloWidgetSnapshotService.shared.refreshEntitlementSnapshot(
            isPlusActive: true,
            source: "preview"
        )

        UserDisplayNameSettings(userDefaults: defaults).saveDisplayName("小满")
        HoloAIDataProcessingConsent.shared.grant()
        // 只在首次播种时重置为亮色；已播种的模拟器再启动保留当前明暗设置，
        // 供表格走查等场景直接以暗色进入。
        if !defaults.bool(forKey: seededKeyValue(for: requestedStory)) {
            defaults.set(false, forKey: "holo_darkModeEnabled")
        }
        // 摆拍不需要首访引导：首页三步导览与长廊欢迎条一律不出现
        OnboardingProgressStore.markSeen(OnboardingProgressStore.homeCoachTourKey)
        OnboardingProgressStore.markSeen(OnboardingProgressStore.memoryGalleryWelcomeKey)

        // 记忆长廊打开时会在配额充足的情况下主动刷新回放；截图模式耗尽当日
        // 配额，确保本地演示回放不会被异步生成结果覆盖。
        let insightQuota = MemoryInsightRefreshQuota(userDefaults: defaults)
        while insightQuota.canRefresh() {
            _ = insightQuota.consume()
        }

        let context = CoreDataStack.shared.viewContext
        let story = requestedStory
        do {
            try seedMarkdownTableConversationIfNeeded(
                context: context,
                route: Route(rawValue: environment[routeKey] ?? "")
            )
            if defaults.bool(forKey: seededKeyValue(for: story)) {
                try await replaceInsight(
                    in: context,
                    now: now,
                    route: Route(rawValue: environment[routeKey] ?? ""),
                    story: story
                )
                navigateIfRequested(environment: environment)
                return true
            }
            let seeded = try await seedAll(
                in: context,
                now: now,
                route: Route(rawValue: environment[routeKey] ?? ""),
                story: story
            )
            guard seeded else { return false }
            defaults.set(true, forKey: seededKeyValue(for: story))
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
        let story = Story(rawValue: environment[storyKey] ?? "") ?? .rhythm

        // 周回放卡与月度回放同一渲染路径，直接展示种子好的周报。
        if route == .periodReplayWeekly {
            let request = MemoryInsight.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "periodType == %@ AND status IN %@",
                    MemoryInsightPeriodType.weekly.rawValue,
                    [MemoryInsightStatus.ready.rawValue, MemoryInsightStatus.stale.rawValue]
                ),
                NSPredicate(format: "deletedAt == nil")
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
            request.fetchLimit = 1

            if let insight = try? CoreDataStack.shared.viewContext.fetch(request).first {
                HoloPeriodReplayCoordinator.shared.presentCachedInsight(insight)
            }

            DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if DeepLinkState.shared.pendingTarget == nil {
                    DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
                }
            }
            return
        }

        // 月度周期回放的宣传图直接展示“生成完成后的真实卡片”。
        // 数据仍由上面的 Seeder 构造，卡片仍复用生产用 PeriodReplayChatCard；
        // 这里只跳过窗口焦点不稳定的手动点选过程，避免截图停在首页。
        if route == .periodReplayMonthly {
            let now = Date()
            let range: (start: Date, end: Date)
            if story == .milestoneAugust {
                range = milestoneAugustPeriodRange()
            } else {
                let effective = MemoryInsightContextBuilder.effectivePeriodRange(
                    periodType: .monthly,
                    referenceDate: now,
                    now: now
                )
                range = (effective.start, effective.end)
            }
            let request = MemoryInsight.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "periodType == %@ AND periodStart == %@ AND status IN %@",
                    MemoryInsightPeriodType.monthly.rawValue,
                    range.start as CVarArg,
                    [MemoryInsightStatus.ready.rawValue, MemoryInsightStatus.stale.rawValue]
                ),
                NSPredicate(format: "deletedAt == nil")
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
            request.fetchLimit = 1

            if let insight = try? CoreDataStack.shared.viewContext.fetch(request).first {
                HoloPeriodReplayCoordinator.shared.presentCachedInsight(insight)
            }

            let target = DeepLinkTarget.ai(voiceInput: false)
            DeepLinkState.shared.navigate(to: target)
            // 冷启动时 ContentView/HomeView 可能尚未完成第一次挂载，补一次只导航不落卡。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if DeepLinkState.shared.pendingTarget == nil {
                    DeepLinkState.shared.navigate(to: target)
                }
            }
            return
        }

        switch route {
        case .home:
            break
        case .periodReplayMonthly, .periodReplayWeekly:
            break
        case .memoryGalleryMultiPhoto:
            let target = DeepLinkTarget.memoryGallery(focusNewMemories: false)
            DeepLinkState.shared.navigate(to: target)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if DeepLinkState.shared.pendingTarget == nil {
                    DeepLinkState.shared.navigate(to: target)
                }
            }
        case .aiActions, .aiAnalysis, .aiMemory, .markdownTable:
            DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
        case .memoryCalendar, .memoryExtraction:
            DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false))
        case .memoryInsight:
            // 洞察页直达：聚焦新记忆会落在「洞察」Tab，待确认分组就在这里
            DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: true))
        case .dailyKanban:
            DeepLinkState.shared.navigate(to: .dailyReminder)
        case .financeStats:
            // 里程碑八月剧本固定展示 2026 年 8 月的统计，避免再做一次「上一月」点选。
            var start = TimeRange.month.dateRange().start
            var end = TimeRange.month.dateRange().end
            if story == .milestoneAugust {
                let august = milestoneAugustPeriodRange()
                start = august.start
                end = august.end.addingDays(1)
            }
            DeepLinkState.shared.navigate(to: .financeAnalysis(FinanceAnalysisDeepLink(
                label: story == .milestoneAugust ? "8月收支" : "本月收支",
                start: start,
                end: end
            )))
        }
    }

    /// 「里程碑八月」剧本的回放周期：2026-08-01 至 2026-08-31，与对外笔记讲述的月份一致。
    private static func milestoneAugustPeriodRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        return (start, end)
    }

    private static func replaceInsight(
        in context: NSManagedObjectContext,
        now: Date,
        route: Route?,
        story: Story
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
        try seedInsight(context: context, startOfWeek: startOfWeek, story: story)
        try context.save()
        if story == .busyWeek {
            // 忙碌一周剧本只保留自己的待确认观察，不落节奏剧本的理解记忆。
            try await seedBusyWeekCandidateMemory(now: now)
            return
        }
        let memoryIDs = try await seedScreenshotMemoryRecords(now: now, story: story)
        try await seedMonthlyReplayInsight(
            context: context,
            now: now,
            memoryIDs: memoryIDs,
            story: story
        )
        if route == .aiMemory {
            try seedPersonalizedMemoryConversation(
                context: context,
                memoryIDs: [memoryIDs.readingID, memoryIDs.focusID],
                timestamp: now
            )
            try context.save()
        }
    }

    private static func seedAll(
        in context: NSManagedObjectContext,
        now: Date,
        route: Route?,
        story: Story
    ) async throws -> Bool {
        FinanceRepository.shared.setup()
        guard let account = Account.getDefaultAccount(in: context) else { return false }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday)!

        if story == .busyWeek {
            try await seedBusyWeekAll(in: context, account: account, now: now, startOfWeek: startOfWeek)
            try context.save()
            return true
        }
        let milestoneTransaction = story == .milestoneAugust
            ? try await seedMilestoneAugustTransactions(context: context, account: account)
            : try await seedTransactions(
                context: context,
                account: account,
                startOfWeek: startOfWeek
            )
        let habit = try seedHabits(context: context, startOfWeek: startOfWeek)
        let task = try seedTasks(context: context, startOfWeek: startOfWeek)
        if story == .milestoneAugust {
            try seedMilestoneAugustThoughts(context: context)
        } else {
            let featuredThought = try seedThoughts(context: context, startOfWeek: startOfWeek)
            try await seedMultiplePhotoMemory(in: context, thought: featuredThought)
        }
        let memoryIDs = try await seedScreenshotMemoryRecords(now: now, story: story)
        try seedConversation(
            context: context,
            transaction: milestoneTransaction.actionTransaction,
            task: task,
            habit: habit,
            now: now,
            startOfWeek: startOfWeek,
            memoryIDs: [memoryIDs.readingID, memoryIDs.focusID],
            story: story
        )
        if route == .aiMemory {
            try seedPersonalizedMemoryConversation(
                context: context,
                memoryIDs: [memoryIDs.readingID, memoryIDs.focusID],
                timestamp: now
            )
        }
        try seedInsight(context: context, startOfWeek: startOfWeek, story: story)
        try await seedMonthlyReplayInsight(
            context: context,
            now: now,
            memoryIDs: memoryIDs,
            story: story
        )
        try context.save()
        return true
    }

    /// 为截图准备一份真实可命中的月度回放缓存。
    /// 用户仍然通过「周期回放 → 本月 → 生成回放」进入，生成服务只是在本地命中这份
    /// 与当前模拟数据快照一致的缓存，因此不会依赖网络或随机模型输出。
    private static func seedMonthlyReplayInsight(
        context: NSManagedObjectContext,
        now: Date,
        memoryIDs: SeededMemoryIDs,
        story: Story
    ) async throws {
        // 里程碑八月剧本的回放周期固定在 2026 年 8 月，与剧本里的账单、想法同期；
        // 默认剧本仍跟随「最近一个完整月」的自然口径。
        let range: (start: Date, end: Date)
        if story == .milestoneAugust {
            range = milestoneAugustPeriodRange()
        } else {
            let effective = MemoryInsightContextBuilder.effectivePeriodRange(
                periodType: .monthly,
                referenceDate: now,
                now: now
            )
            range = (effective.start, effective.end)
        }
        let builder = MemoryInsightContextBuilder()
        let (_, snapshotHash) = await builder.build(
            periodType: .monthly,
            start: range.start,
            end: range.end
        )

        let request = MemoryInsight.fetchRequest()
        request.predicate = NSPredicate(
            format: "periodType == %@",
            MemoryInsightPeriodType.monthly.rawValue
        )
        for insight in try context.fetch(request) {
            context.delete(insight)
        }

        let insight = MemoryInsight.createGenerating(
            in: context,
            periodType: .monthly,
            start: range.start,
            end: range.end,
            snapshotHash: snapshotHash
        )
        let payload = story == .milestoneAugust
            ? makeMilestoneAugustPayload(memoryIDs: memoryIDs)
            : makeMonthlyReplayPayload(memoryIDs: memoryIDs)
        try await MainActor.run {
            insight.markReady(
                payload: payload,
                rawResponse: try encode(payload),
                providerName: "screenshot-seed",
                promptVersion: 0
            )
        }
        try context.save()
    }

    private static func makeMonthlyReplayPayload(
        memoryIDs: SeededMemoryIDs
    ) -> MemoryInsightPayload {
        MemoryInsightPayload(
            title: "这个月，你正在把生活收拢起来",
            summary: "从支出、习惯、待办和想法放在一起看，稳定的节奏已经开始出现：晨间阅读在变得规律，专注时间也被你认真留了出来。",
            cards: [
                MemoryInsightCard(
                    id: "screenshot-monthly-overview",
                    type: .overview,
                    title: "生活开始有了自己的节拍",
                    body: "你不是每天都做同样的事，而是在重要的事情上逐渐形成了可重复的节奏。",
                    evidence: [
                        MemoryInsightEvidence(id: "overview-1", label: "本月有多天留下完整记录", date: nil, sourceType: "thought", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "overview-2", label: "晨间阅读与夜间散步多次出现在记录中", date: nil, sourceType: "habit", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "下个月最值得保持什么？"
                ),
                MemoryInsightCard(
                    id: "screenshot-monthly-finance",
                    type: .finance,
                    title: "日常支出更集中，也更容易看懂",
                    body: "餐饮和日常补给是本月的主要支出；当支出被持续记录下来，变化就不再只是月底的一个数字。",
                    evidence: [
                        MemoryInsightEvidence(id: "finance-1", label: "餐饮是出现频率最高的支出类别", date: nil, sourceType: "transaction", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "finance-2", label: "本月多天都有可回看的消费明细", date: nil, sourceType: "transaction", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "哪些支出最值得继续观察？"
                ),
                MemoryInsightCard(
                    id: "screenshot-monthly-habit",
                    type: .habit,
                    title: "晨间阅读正在从安排变成习惯",
                    body: "连续的晨间记录说明，它已经不只是偶尔想起来才做的事，而是逐渐成为工作日的启动方式。",
                    evidence: [
                        MemoryInsightEvidence(id: "habit-1", label: "晨间阅读连续记录了多个工作日", date: nil, sourceType: "habit", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "habit-2", label: "习惯记录覆盖了本月的大部分时间", date: nil, sourceType: "habit", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "怎样让这个习惯更轻松？"
                ),
                MemoryInsightCard(
                    id: "screenshot-monthly-cross",
                    type: .crossDomain,
                    title: "专注时间和稳定节奏互相支持",
                    body: "当你为重要的事情留出不被打扰的时间，晚间散步也更像是在收回一天，而不是临时补救。",
                    evidence: [
                        MemoryInsightEvidence(id: "cross-1", label: "记录中出现了不被打扰的一小时", date: nil, sourceType: "thought", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "cross-2", label: "夜间散步与工作日记录多次相邻出现", date: nil, sourceType: "habit", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "帮我把这个节奏延续到下周"
                ),
                MemoryInsightCard(
                    id: "screenshot-monthly-thought",
                    type: .thought,
                    title: "你越来越知道什么值得留下",
                    body: "记录不再只是保存发生过的事，也在帮你辨认哪些安排真正让生活变得更顺。",
                    evidence: [
                        MemoryInsightEvidence(id: "thought-1", label: "多条想法都围绕拆解、留白与复盘", date: nil, sourceType: "thought", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "把这些发现整理成一个计划"
                )
            ],
            suggestedQuestions: [
                "下个月最值得保持什么？",
                "帮我把这个节奏延续到下周",
                "把这些发现整理成一个计划"
            ],
            usedMemoryIDs: [memoryIDs.readingID, memoryIDs.focusID]
        )
    }

    // MARK: - 里程碑八月剧本（第二篇笔记拍摄用）

    /// 与对外笔记同一故事的月度回放：一个里程碑落地的八月。
    /// 标题、摘要与七张洞察都对齐真实产品里「展开 N 张洞察」的结构。
    private static func makeMilestoneAugustPayload(
        memoryIDs: SeededMemoryIDs
    ) -> MemoryInsightPayload {
        MemoryInsightPayload(
            title: "一个里程碑落地的八月",
            summary: "你写下了「从零到一的过程已经走完」——Holo 过审，记账也到了 500 笔。项目落地带来的不只是喜悦，情绪和消费都跟着动了：支出冲到 2.8 万比上月多约 17%，戒烟松动了几天，英语断连满 30 天。任务倒是在月底稳稳收住，松动没有变成放弃——月底，你把自己接住了。",
            cards: [
                MemoryInsightCard(
                    id: "milestone-aug-overview",
                    type: .overview,
                    title: "一个项目落地的八月",
                    body: "这个月的大事只有一件：从零到一走完了。它带来的连锁反应，才刚刚开始显形。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-overview-1", label: "你写下了「从零到一的过程已经走完」", date: "2026-08-16", sourceType: "thought", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-overview-2", label: "本月有 20 多天留下了完整记录", date: nil, sourceType: "thought", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "九月最想守住什么？"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-project",
                    type: .milestone,
                    title: "你把自己的项目做出来了",
                    body: "从提审到过审，这个月你把一件事从「在做」变成了「做成」。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-project-1", label: "8 月 16 日的想法记下了 Holo 过审的瞬间", date: "2026-08-16", sourceType: "thought", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-project-2", label: "本月多条待办围绕提审与发布准备", date: nil, sourceType: "task", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "帮我把「怎么用它」变成一个计划"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-finance",
                    type: .finance,
                    title: "这个月钱流向人情和喜欢的东西",
                    body: "支出冲到 2.8 万，比上月多约 17%。多出来的部分，大多流向了朋友和喜欢的东西。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-finance-1", label: "人情往来是本月增量最大的支出类别", date: nil, sourceType: "transaction", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-finance-2", label: "项目过审当周，有一笔犒劳自己的大额消费", date: "2026-08-17", sourceType: "transaction", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "看看 8 月的钱都去了哪"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-smoke",
                    type: .anomaly,
                    title: "戒烟这个月松了几天",
                    body: "项目最紧的那几天，戒烟松动了。松动之后你重新捡了起来，没有放任它变成放弃。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-smoke-1", label: "戒烟打卡在 8 月中旬中断了几天", date: nil, sourceType: "habitRecord", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-smoke-2", label: "8 月下旬重新出现了打卡记录", date: nil, sourceType: "habitRecord", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "帮我看看戒烟怎么接回去"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-english",
                    type: .habit,
                    title: "英语断链满一个月了",
                    body: "上一次英语打卡停在了 30 天前。课报了，链断了——这是九月最值得接回来的一件事。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-english-1", label: "英语学习记录停在 7 月中旬", date: nil, sourceType: "habitRecord", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-english-2", label: "8 月没有新的学习打卡", date: nil, sourceType: "habitRecord", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "九月怎么把英语接回来？"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-thought",
                    type: .thought,
                    title: "项目之后，你还在想怎么用它",
                    body: "过审不是终点。你的想法在过审之后反而变多了，大多围绕「怎么让它被更多人用上」。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-thought-1", label: "多条想法围绕推广与下一步展开", date: nil, sourceType: "thought", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-thought-2", label: "8 月的想法数量是近几个月最多的", date: nil, sourceType: "thought", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "把这些想法整理成九月的计划"
                ),
                MemoryInsightCard(
                    id: "milestone-aug-task",
                    type: .task,
                    title: "月底，你把自己接住了",
                    body: "松动没有变成放弃，断链没有变成自责。月底几天，你把节奏一件一件捡了回来。",
                    evidence: [
                        MemoryInsightEvidence(id: "milestone-task-1", label: "月底完成了收尾清单上的 4 件事", date: nil, sourceType: "task", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "milestone-task-2", label: "戒烟在月底重新连续打卡", date: nil, sourceType: "habitRecord", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "九月最值得接回来的是哪件事？"
                )
            ],
            suggestedQuestions: [
                "九月最值得接回来的是哪件事？",
                "帮我把「怎么用它」变成一个计划",
                "看看 8 月的钱都去了哪"
            ],
            usedMemoryIDs: [memoryIDs.readingID, memoryIDs.focusID]
        )
    }

    /// 里程碑八月的账单：2026 年 8 月支出恰好 28,000 元、7 月 23,932 元（环比 +17%），
    /// 与回放摘要里的数字严格一致，统计页截图不会和文案打架。
    private static func seedMilestoneAugustTransactions(
        context: NSManagedObjectContext,
        account: Account
    ) async throws -> SeededTransactions {
        let categories = try context.fetch(Category.fetchRequest())
        let byName = Dictionary(grouping: categories.filter(\.isSubCategory), by: \.name)
        let august: [(day: Int, hour: Int, minute: Int, amount: Decimal, category: String, note: String)] = [
            (1, 10, 5, 2590, "房租", "8月房租"),
            (3, 20, 30, 128, "电费", "7月电费"),
            (5, 9, 20, 99, "话费", "8月话费"),
            (2, 15, 30, 666, "红包礼金", "朋友乔迁红包"),
            (16, 12, 10, 1888, "红包礼金", "老同学婚礼份子钱"),
            (17, 19, 30, 428, "请客", "Holo 过审庆功宴我请"),
            (18, 14, 20, 520, "礼物", "好朋友的生日礼物"),
            (24, 19, 20, 356, "请客", "项目组朋友小聚"),
            (17, 21, 30, 6999, "数码", "过审犒劳：新显示器"),
            (19, 22, 10, 1299, "数码", "机械键盘"),
            (20, 16, 40, 899, "礼物", "给爸妈买的按摩仪"),
            (23, 15, 10, 399, "玩具", "心心念念的手办"),
            (8, 21, 15, 236, "书籍", "产品设计书两本"),
            (22, 20, 20, 699, "演唱会", "和朋友看的演唱会"),
            (25, 19, 45, 89, "电影", "周末电影"),
            (6, 10, 30, 499, "语言学习", "英语口语课"),
            (11, 9, 40, 25, "订阅", "音乐会员"),
            (26, 9, 40, 25, "订阅", "网盘会员"),
            (21, 15, 30, 2499, "家具", "人体工学椅"),
            (29, 10, 30, 2899, "旅行", "月末短途行机酒"),
            (30, 19, 30, 288, "请客", "请团队喝奶茶"),
            (12, 20, 15, 128, "超市", "周末补货"),
            (8, 17, 30, 96, "日用", "日用补给"),
            (11, 10, 40, 599, "体检", "年度体检"),
            (2, 16, 40, 299, "运动", "羽毛球拍"),
            (24, 11, 30, 349, "鞋包", "新跑鞋"),
            (15, 20, 30, 158, "酒水", "朋友小酌"),
            (31, 20, 20, 1596, "日用", "换季床品和收纳"),
            (1, 8, 30, 22, "早餐", "八月第一顿早餐"),
            (1, 12, 20, 36, "午餐", "午餐"),
            (2, 8, 45, 20, "咖啡", "晨间咖啡"),
            (2, 19, 10, 45, "晚餐", "晚餐"),
            (4, 12, 30, 38, "外卖", "加班外卖"),
            (5, 8, 20, 21, "早餐", "早餐"),
            (7, 12, 15, 42, "午餐", "午餐"),
            (7, 18, 40, 58, "火锅", "下班火锅"),
            (9, 8, 30, 19, "咖啡", "咖啡"),
            (10, 19, 30, 52, "晚餐", "晚餐"),
            (12, 12, 25, 39, "午餐", "午餐"),
            (13, 15, 30, 28, "水果", "水果补给"),
            (14, 12, 10, 44, "外卖", "周末外卖"),
            (15, 9, 20, 24, "早餐", "早餐"),
            (21, 12, 20, 36, "午餐", "午餐"),
            (23, 20, 40, 66, "超市", "周末食材"),
            (26, 12, 30, 41, "午餐", "午餐"),
            (27, 8, 25, 20, "咖啡", "咖啡"),
            (28, 19, 15, 63, "烧烤", "朋友烧烤"),
            (30, 12, 40, 43, "午餐", "午餐"),
            (31, 10, 20, 32, "甜品", "月末下午茶"),
            (4, 9, 10, 4, "地铁", "地铁"),
            (11, 9, 5, 4, "地铁", "地铁"),
            (18, 9, 5, 4, "地铁", "地铁"),
            (6, 22, 30, 68, "打车", "加班回家"),
            (16, 23, 10, 52, "打车", "庆功宴回家"),
            (22, 23, 40, 61, "打车", "演唱会回家"),
            (20, 8, 40, 263, "火车", "回家看爸妈的车票")
        ]
        let july: [(day: Int, hour: Int, minute: Int, amount: Decimal, category: String, note: String)] = [
            (1, 10, 5, 2590, "房租", "7月房租"),
            (5, 20, 30, 136, "电费", "6月电费"),
            (3, 9, 20, 99, "话费", "7月话费"),
            (12, 10, 30, 5286, "旅行", "青海行机酒"),
            (13, 19, 40, 366, "烧烤", "旅途烧烤"),
            (14, 11, 20, 240, "打车", "旅途打车"),
            (20, 15, 30, 3299, "数码", "新手机"),
            (18, 18, 20, 688, "红包礼金", "满月酒红包"),
            (9, 19, 20, 298, "请客", "朋友小聚"),
            (2, 10, 40, 1999, "课程", "线上课程"),
            (25, 9, 40, 25, "订阅", "音乐会员"),
            (8, 21, 15, 158, "书籍", "杂书两本"),
            (17, 20, 20, 299, "日用", "夏日收纳"),
            (23, 16, 20, 159, "美妆", "防晒补给"),
            (3, 16, 40, 349, "运动", "羽毛球拍"),
            (21, 20, 30, 4599, "家具", "升降桌"),
            (8, 17, 30, 2677, "家电", "净化器"),
            (1, 8, 30, 21, "早餐", "早餐"),
            (1, 12, 20, 34, "午餐", "午餐"),
            (2, 19, 10, 42, "晚餐", "晚餐"),
            (4, 8, 45, 20, "咖啡", "咖啡"),
            (6, 12, 30, 36, "午餐", "午餐"),
            (7, 18, 40, 52, "晚餐", "晚餐"),
            (9, 8, 30, 19, "咖啡", "咖啡"),
            (11, 12, 25, 38, "午餐", "午餐"),
            (15, 15, 30, 26, "水果", "水果"),
            (16, 12, 10, 43, "外卖", "外卖"),
            (19, 9, 20, 22, "早餐", "早餐"),
            (22, 12, 20, 36, "午餐", "午餐"),
            (24, 20, 40, 60, "超市", "周末食材"),
            (27, 12, 30, 40, "午餐", "午餐"),
            (29, 8, 25, 20, "咖啡", "咖啡"),
            (30, 19, 15, 58, "烧烤", "朋友烧烤"),
            (31, 10, 20, 30, "甜品", "下午茶"),
            (6, 9, 10, 4, "地铁", "地铁"),
            (16, 9, 5, 4, "地铁", "地铁"),
            (28, 9, 5, 4, "地铁", "地铁"),
            (10, 22, 30, 56, "打车", "加班回家")
        ]

        var celebrationTransaction: Transaction?
        for (month, samples) in [(7, july), (8, august)] {
            for sample in samples {
                guard let category = byName[sample.category]?.first else {
                    throw ScreenshotSeedError.missingCategory(sample.category)
                }
                let date = milestoneDate(month: month, day: sample.day, hour: sample.hour, minute: sample.minute)
                let transaction = try await FinanceRepository.shared.addTransaction(
                    amount: sample.amount,
                    type: .expense,
                    category: category,
                    account: account,
                    date: date,
                    note: sample.note
                )
                if month == 8 && sample.category == "请客" && sample.amount == 428 {
                    celebrationTransaction = transaction
                }
            }
        }

        guard let actionTransaction = celebrationTransaction else {
            throw ScreenshotSeedError.missingCategory("请客")
        }
        return SeededTransactions(actionTransaction: actionTransaction)
    }

    /// 里程碑八月的想法：与回放摘要引用的「从零到一的过程已经走完」等记录同期。
    private static func seedMilestoneAugustThoughts(context: NSManagedObjectContext) throws {
        let repository = ThoughtRepository(context: context)
        let samples: [(content: String, mood: String, tags: [String], month: Int, day: Int, hour: Int)] = [
            ("八月的主题很明确：把 Holo 送上桌。最近的安排全都围着它转。", "calm", ["项目"], 8, 2, 9),
            ("报了英语口语课，想着项目再忙也不能断。先立个flag。", "inspired", ["英语", "学习"], 8, 6, 22),
            ("从零到一的过程已经走完。Holo 过审了，这一刻等了好久。", "happy", ["里程碑", "项目"], 8, 16, 10),
            ("项目落地了，晚上请朋友吃了顿好的。这一程谢谢他们。", "happy", ["人情", "记录"], 8, 17, 23),
            ("这个月花得有点凶：人情和喜欢的东西都没手软。先记下来，月底再回看值不值。", "calm", ["财务"], 8, 21, 21),
            ("戒烟松了几天。先接住自己，再重新开始，比责怪自己有用。", "calm", ["戒烟"], 8, 24, 22),
            ("项目之后，想得最多的是怎么让它被更多人用上。九月开始。", "inspired", ["项目", "九月"], 8, 29, 20),
            ("8 月收尾：完成比完美重要。九月，把英语和戒烟都接回来。", "calm", ["复盘"], 8, 31, 22)
        ]
        for sample in samples {
            let thought = try repository.create(
                content: sample.content,
                mood: sample.mood,
                tags: sample.tags
            )
            let createdAt = milestoneDate(
                month: sample.month,
                day: sample.day,
                hour: sample.hour,
                minute: 10
            )
            thought.createdAt = createdAt
            thought.updatedAt = createdAt
            thought.organizedStatus = "organized"
        }
    }

    /// 里程碑八月剧本固定使用 2026 年 7–8 月，与对外笔记讲述的月份保持一致。
    private static func milestoneDate(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    /// 表格渲染走查剧本：一条覆盖标准表格、混排、折叠区宽表（横向滚动分支）的 assistant 回复。
    private static func seedMarkdownTableConversationIfNeeded(
        context: NSManagedObjectContext,
        route: Route?
    ) throws {
        guard route == .markdownTable else { return }
        let marker = "用表格帮我看看最近的支出明细"
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "content == %@", marker)
        guard try context.fetch(request).isEmpty else { return }

        let latestMessageDate = try context.fetch(ChatMessage.fetchRequest())
            .compactMap(\.timestamp)
            .max() ?? Date()
        let messageBase = latestMessageDate.addingTimeInterval(120)

        let queryID = insertMessage(
            in: context,
            role: "user",
            content: marker,
            timestamp: messageBase
        )
        let assistant = ChatMessage(context: context)
        assistant.id = UUID()
        assistant.role = "assistant"
        assistant.content = """
        这是本周和上周的支出对比：

        | 分类 | 本周 | 上周 | 变化 |
        | --- | --- | --- | --- |
        | 餐饮 | 328 元 | 410 元 | **下降 20%** |
        | 交通 | 96 元 | 88 元 | 基本持平 |
        | 购物 | 512 元 | 388 元 | 上升 32% |

        整体支出比上周多了 138 元，主要是购物这一笔。

        大额明细如下：

        | 日期 | 项目 | 分类 | 金额 | 账户 | 备注 |
        | --- | --- | --- | --- | --- | --- |
        | 9 月 2 日 | 图书礼盒 | 购物 | 299 元 | 招行卡 | 给自己的生日礼物 |
        | 9 月 4 日 | 午餐拼单 | 餐饮 | 46 元 | 微信 | 和同事拼单 |
        | 9 月 6 日 | 打车通勤 | 交通 | 38 元 | 支付宝 | 暴雨天 |
        | 9 月 7 日 | 超市补货 | 购物 | 213 元 | 招行卡 | 米面粮油 |

        接下来可以：

        - 把购物类大额记录核对一遍
        - 给下周设一个 1200 元的参考线

        详细分析
        | 周 | 消费重心 |
        | --- | --- |
        | 第 1 周 | 外卖和打车 |
        | 第 2 周 | 超市和家庭采购 |
        """
        assistant.timestamp = messageBase.addingTimeInterval(5)
        assistant.intent = nil
        assistant.isStreaming = false
        assistant.parentMessageId = queryID
        assistant.messageType = ChatMessageType.normal.rawValue
        try context.save()
    }

    private static func seedPersonalizedMemoryConversation(
        context: NSManagedObjectContext,
        memoryIDs: [String],
        timestamp: Date
    ) throws {
        let marker = "最近怎么安排工作日更顺？"
        let request = ChatMessage.fetchRequest()
        request.predicate = NSPredicate(format: "content == %@", marker)
        guard try context.fetch(request).isEmpty else { return }

        let latestMessageDate = try context.fetch(ChatMessage.fetchRequest())
            .compactMap(\.timestamp)
            .max() ?? timestamp
        let messageBase = max(timestamp, latestMessageDate).addingTimeInterval(120)

        let queryID = insertMessage(
            in: context,
            role: "user",
            content: marker,
            timestamp: messageBase
        )
        let assistant = ChatMessage(context: context)
        assistant.id = UUID()
        assistant.role = "assistant"
        assistant.content = "按你最近的记录，可以把晨间阅读和一段完整专注时间放在工作日的前半段；晚上再留一点散步的余地，节奏会更容易保持。"
        assistant.timestamp = messageBase.addingTimeInterval(5)
        assistant.intent = nil
        assistant.isStreaming = false
        assistant.parentMessageId = queryID
        assistant.messageType = ChatMessageType.normal.rawValue
        assistant.extractedDataJSON = try encode([
            "memoryUsedCount": String(memoryIDs.count),
            "memoryUsedIDs": memoryIDs.joined(separator: ",")
        ])
    }

    private struct SeededMemoryIDs {
        let readingID: String
        let focusID: String
        let rhythmID: String
        let recoveryID: String
    }

    private static func screenshotMemoryIDs() throws -> SeededMemoryIDs {
        let readingAnchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "weekday-morning-reading"
        )
        let readingID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .recurringPattern,
            anchors: [readingAnchor]
        )

        let focusAnchor = try HoloMemoryAnchorRef(
            type: .thoughtTopic,
            value: "protected-focus-time",
            displayLabel: "不被打扰的一小时"
        )
        let focusID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            claimKind: .recurringPattern,
            anchors: [focusAnchor]
        )

        let rhythmAnchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "weekday-rhythm",
            displayLabel: "工作日节奏"
        )
        let rhythmID = try HoloMemoryIdentity.makeStableID(
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.habit, .thought],
            claimKind: .association,
            anchors: [rhythmAnchor]
        )

        let recoveryAnchor = try HoloMemoryAnchorRef(
            type: .habit,
            value: "evening-walk-recovery",
            displayLabel: "夜间散步"
        )
        let recoveryID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .hypothesis,
            anchors: [recoveryAnchor]
        )
        return SeededMemoryIDs(
            readingID: readingID,
            focusID: focusID,
            rhythmID: rhythmID,
            recoveryID: recoveryID
        )
    }

    private static func makeScreenshotMemoryRecord(
        id: String,
        scope: HoloMemoryScope,
        primaryDomain: HoloMemoryDomain?,
        sourceDomains: [HoloMemoryDomain],
        subjectKey: String,
        anchorRefs: [HoloMemoryAnchorRef],
        claimKind: HoloMemoryClaimKind,
        persistenceClass: HoloMemoryPersistenceClass,
        displaySummary: String,
        aiUseSummary: String,
        prohibitedInferences: [String],
        evidenceRefs: [HoloMemoryEvidenceRef],
        upstreamMemoryIDs: [String],
        confidenceScore: Double,
        state: HoloMemoryState,
        adoptionMetadata: HoloMemoryAdoptionMetadata? = nil,
        now: Date
    ) -> HoloMemoryRecord {
        HoloMemoryRecord(
            id: id,
            scope: scope,
            primaryDomain: primaryDomain,
            sourceDomains: sourceDomains,
            subjectKey: subjectKey,
            anchorRefs: anchorRefs,
            claimKind: claimKind,
            persistenceClass: persistenceClass,
            displaySummary: displaySummary,
            aiUseSummary: aiUseSummary,
            prohibitedInferences: prohibitedInferences,
            evidenceRefs: evidenceRefs,
            upstreamMemoryIDs: upstreamMemoryIDs,
            counterEvidenceRefs: [],
            lastSupportedAt: now,
            confidenceScore: confidenceScore,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: .normal,
            userDecision: .none,
            adoptionMetadata: adoptionMetadata,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 构造宣传图需要的「正在越来越懂你」数据：两条已形成的理解 + 两条等待用户确认的候选记忆。
    /// 所有记录都走真实统一记忆仓库，避免宣传图掩盖真实产品行为。
    /// 里程碑八月剧本不落记忆回执：对话页顶部的「新记住 N 件」提示条会盖住标题栏，
    /// 真实用户截图里也没有它。
    private static func seedScreenshotMemoryRecords(
        now: Date,
        story: Story
    ) async throws -> SeededMemoryIDs {
        let ids = try screenshotMemoryIDs()
        try await seedStableMemory(now: now)

        let focusAnchor = try HoloMemoryAnchorRef(
            type: .thoughtTopic,
            value: "protected-focus-time",
            displayLabel: "不被打扰的一小时"
        )
        let focusRecord = makeScreenshotMemoryRecord(
            id: ids.focusID,
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "protected-focus-time",
            anchorRefs: [focusAnchor],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "你会主动为真正重要的事留出不被打扰的时间。",
            aiUseSummary: "用户重视完整专注时段，安排任务时可优先保留连续的独处时间。",
            prohibitedInferences: ["不要据此推断用户每天都拥有完整空闲时间"],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: "app-store-screenshot-focus-time",
                kind: .explicitUserStatement,
                sourceDomain: .thought,
                lineageKey: "app-store-screenshot-focus-time",
                sourceID: "thought-protected-focus-time",
                revisionDigest: "v1",
                observedAt: now,
                summary: "今天最值得记住的是留出了真正不被打扰的一小时。"
            )],
            upstreamMemoryIDs: [],
            confidenceScore: 0.88,
            state: .active,
            now: now
        )

        let rhythmAnchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "weekday-rhythm",
            displayLabel: "工作日节奏"
        )
        let rhythmRecord = makeScreenshotMemoryRecord(
            id: ids.rhythmID,
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.habit, .thought],
            subjectKey: "weekday-rhythm",
            anchorRefs: [rhythmAnchor],
            claimKind: .association,
            persistenceClass: .phase,
            displaySummary: "工作日的稳定节奏，通常从晨间阅读和一段专注时间开始。",
            aiUseSummary: "规划工作日时，可把晨间阅读和连续专注时间作为用户偏好的节奏锚点。",
            prohibitedInferences: ["不要据此推断每个工作日都能完整执行这套节奏"],
            evidenceRefs: [
                HoloMemoryEvidenceRef(
                    id: "app-store-screenshot-rhythm-habit",
                    kind: .entityRef,
                    sourceDomain: .habit,
                    lineageKey: "app-store-screenshot-reading-streak",
                    sourceID: "weekday-morning-reading",
                    revisionDigest: "v1",
                    observedAt: now,
                    summary: "晨间阅读已连续记录 5 天。"
                ),
                HoloMemoryEvidenceRef(
                    id: "app-store-screenshot-rhythm-thought",
                    kind: .explicitUserStatement,
                    sourceDomain: .thought,
                    lineageKey: "app-store-screenshot-focus-time",
                    sourceID: "thought-protected-focus-time",
                    revisionDigest: "v1",
                    observedAt: now,
                    summary: "用户记录过不被打扰的专注时段。"
                )
            ],
            upstreamMemoryIDs: [ids.readingID, ids.focusID],
            confidenceScore: 0.76,
            state: .candidate,
            adoptionMetadata: HoloMemoryAdoptionMetadata(
                policyVersion: HoloMemoryActivationPolicy.currentVersion,
                disposition: .pendingConfirmation,
                reason: .firstCrossDomainInference,
                evaluatedAt: now
            ),
            now: now
        )

        let recoveryAnchor = try HoloMemoryAnchorRef(
            type: .habit,
            value: "evening-walk-recovery",
            displayLabel: "夜间散步"
        )
        let recoveryRecord = makeScreenshotMemoryRecord(
            id: ids.recoveryID,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: "evening-walk-recovery",
            anchorRefs: [recoveryAnchor],
            claimKind: .hypothesis,
            persistenceClass: .phase,
            displaySummary: "忙碌之后，你更容易通过夜间散步把一天收回来。",
            aiUseSummary: "当用户安排晚间恢复时，可以温和地建议一段短时散步，并允许用户忽略。",
            prohibitedInferences: ["不要把散步当作用户每晚固定的要求"],
            evidenceRefs: [HoloMemoryEvidenceRef(
                id: "app-store-screenshot-evening-walk",
                kind: .entityRef,
                sourceDomain: .habit,
                lineageKey: "app-store-screenshot-evening-walk",
                sourceID: "evening-walk",
                revisionDigest: "v1",
                observedAt: now,
                summary: "本周有 4 次夜间散步记录。"
            )],
            upstreamMemoryIDs: [],
            confidenceScore: 0.7,
            state: .candidate,
            adoptionMetadata: HoloMemoryAdoptionMetadata(
                policyVersion: HoloMemoryActivationPolicy.currentVersion,
                disposition: .pendingConfirmation,
                reason: .hypothesis,
                evaluatedAt: now
            ),
            now: now
        )

        let repository = try await HoloMemoryRuntime.shared.repository()
        for (record, observationKey) in [
            (focusRecord, "app-store-screenshot-memory-focus-v2"),
            (rhythmRecord, "app-store-screenshot-memory-rhythm-v2"),
            (recoveryRecord, "app-store-screenshot-memory-recovery-v2")
        ] {
            _ = try await repository.upsert(record, observationKey: observationKey)
        }
        if story == .rhythm {
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: [ids.readingID, ids.focusID],
                message: "Holo 已记住 2 件与你有关的事",
                adoptionKind: .automaticallyAdopted,
                batchKey: "app-store-screenshot-memory-automatic-v2",
                now: now
            )
            HoloMemoryReceiptStore.record(
                kind: .write,
                channel: .insight,
                memoryIDs: [ids.rhythmID, ids.recoveryID],
                message: "Holo 从你的记录里整理出 2 条候选记忆",
                adoptionKind: .needsConfirmation,
                batchKey: "app-store-screenshot-memory-candidate-v2",
                now: now
            )
        }
        return ids
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
        let samples: [(day: Int, hour: Int, minute: Int, amount: Decimal, category: String, note: String)] = [
            (-23, 8, 20, 32, "早餐", "工作日早餐"),
            (-22, 12, 10, 38, "午餐", "午餐"),
            (-21, 19, 15, 46, "晚餐", "晚餐"),
            (-20, 8, 5, 22, "咖啡", "晨间咖啡"),
            (-19, 18, 40, 4, "地铁", "回家地铁"),
            (-18, 12, 30, 44, "午餐", "工作日午餐"),
            (-17, 15, 20, 79, "书籍", "阅读补给"),
            (-16, 18, 50, 126, "超市", "本周补给"),
            (-15, 9, 10, 26, "早餐", "周末早餐"),
            (-14, 20, 10, 52, "晚餐", "晚餐"),
            (-13, 12, 20, 36, "午餐", "午餐"),
            (-12, 17, 40, 18, "茶饮", "下午茶"),
            (-11, 19, 0, 75, "火锅", "朋友小聚"),
            (-10, 8, 30, 20, "咖啡", "晨间咖啡"),
            (-9, 13, 0, 48, "午餐", "午餐"),
            (-8, 16, 20, 58, "水果", "水果补给"),
            (-7, 18, 30, 96, "超市", "周末食材"),
            (-6, 11, 30, 28, "鲜花", "给生活买花"),
            (-5, 19, 20, 88, "火锅", "朋友小聚"),
            (-4, 9, 40, 24, "茶饮", "上午茶饮"),
            (-3, 12, 15, 42, "午餐", "工作日午餐"),
            (-2, 19, 30, 48, "晚餐", "晚餐"),
            (-1, 8, 20, 20, "咖啡", "晨间咖啡"),
            (0, 8, 15, 18, "早餐", "早餐和豆浆"),
            (0, 19, 10, 42, "晚餐", "下班后的简餐"),
            (1, 7, 55, 22, "咖啡", "晨间咖啡"),
            (1, 12, 20, 36, "午餐", "午餐"),
            (1, 18, 40, 4, "地铁", "回家地铁"),
            (2, 9, 10, 58, "书籍", "产品设计书"),
            (2, 12, 35, 32, "午餐", "工作日午餐"),
            (2, 20, 15, 28, "水果", "水果补给"),
            (3, 8, 5, 16, "早餐", "早餐"),
            (3, 12, 18, 39, "午餐", "午餐"),
            (3, 19, 30, 49, "电影", "晚间电影"),
            (4, 8, 20, 20, "咖啡", "晨间咖啡"),
            (4, 12, 25, 35, "午餐", "午餐"),
            (4, 18, 55, 86, "超市", "周末食材"),
            (5, 10, 30, 45, "鲜花", "周末买花"),
            (5, 19, 15, 68, "火锅", "朋友小聚"),
            (6, 9, 20, 26, "早餐", "慢慢吃早餐"),
            (6, 16, 40, 24, "茶饮", "下午茶")
        ]

        // 截图发生在当前周的早些时候；把账单放到上一周，既能保证“已发生”，
        // 也能让“本月收支”在模拟器的当前日期下稳定显示完整趋势。
        let transactionWeek = Calendar.current.date(byAdding: .day, value: -7, to: startOfWeek) ?? startOfWeek
        var actionTransaction: Transaction?
        for sample in samples {
            guard let category = byName[sample.category]?.first else { continue }
            let date = date(
                from: transactionWeek,
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
            if sample.category == "午餐" && sample.amount == 36 {
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
        for day in Array(stride(from: -24, through: -1, by: 1)).filter({ $0 % 6 != 0 }) {
            let record = HabitRecord.createCheckIn(in: context, habit: reading)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 8, minute: 35)
            record.createdAt = record.date
        }
        for day in [1, 2, 3, 5] {
            let record = HabitRecord.createCheckIn(in: context, habit: walk)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 20, minute: 25)
            record.createdAt = record.date
        }
        for day in [-23, -21, -18, -16, -13, -11, -9, -6, -4, -2] {
            let record = HabitRecord.createCheckIn(in: context, habit: walk)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 20, minute: 25)
            record.createdAt = record.date
        }
        for day in [1, 2, 4] {
            let record = HabitRecord.createCheckIn(in: context, habit: sleep)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 23, minute: 10)
            record.createdAt = record.date
        }
        for day in [-22, -20, -17, -14, -12, -8, -5, -3] {
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
        let historicalSamples: [(String, Int, Int)] = [
            ("整理上月复盘", -22, 18),
            ("确认阅读计划", -17, 16),
            ("清理收件箱", -12, 19),
            ("安排周末留白", -7, 17)
        ]
        for sample in historicalSamples {
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

        let focusStart = date(from: startOfWeek, dayOffset: 0, hour: 16, minute: 0)
        let focusTask = TodoTask.create(
            in: context,
            title: "完成产品复盘",
            priority: .high,
            dueDate: focusStart
        )
        focusTask.plannedStart = focusStart
        focusTask.plannedEnd = date(from: startOfWeek, dayOffset: 0, hour: 17, minute: 30)

        // 轴档多泳道固定夹具：与产品复盘时间重叠（15:30–16:45 vs 16:00–17:30），
        // 让今天的轴档天然呈现「重叠条目各占一条泳道」的宽屏展开效果
        let laneFixtureStart = date(from: startOfWeek, dayOffset: 0, hour: 15, minute: 30)
        let laneFixture = TodoTask.create(
            in: context,
            title: "准备复盘材料",
            priority: .medium,
            dueDate: laneFixtureStart
        )
        laneFixture.plannedStart = laneFixtureStart
        laneFixture.plannedEnd = date(from: startOfWeek, dayOffset: 0, hour: 16, minute: 45)

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
    ) throws -> Thought {
        let repository = ThoughtRepository(context: context)
        let samples: [(String, String, [String], Int, Int)] = [
            ("最近发现，提前给重要的事留出时间，整天会更从容。", "calm", ["节奏"], -21, 21),
            ("花钱之前先问自己是不是需要，月底回看时会更轻松。", "calm", ["财务"], -16, 20),
            ("真正的休息不是把事情推迟，而是让注意力有地方落下。", "inspired", ["生活"], -11, 22),
            ("这周的安排没有排满，反而完成了更多重要的事。", "happy", ["复盘"], -6, 21),
            ("想把稳定的部分留下，把临时起意的部分放轻一点。", "inspired", ["成长"], -2, 22),
            ("昆明天气很好，喝了喜欢的咖啡，也看到了好看的云。这样的小确幸，让人很幸福。", "happy", ["旅行", "小确幸"], 0, 19),
            ("今天最值得记住的，是留出了真正不被打扰的一小时。", "happy", ["生活"], -4, 22),
            ("记录不是为了追求完美，而是为了看见自己正在发生什么。", "inspired", ["复盘"], -1, 21)
        ]
        var featuredThought: Thought?
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
            if sample.3 == 0 {
                featuredThought = thought
            }
        }
        guard let featuredThought else {
            throw ScreenshotSeedError.missingFeaturedThought
        }
        return featuredThought
    }

    /// 给当天的想法挂上三张可回看的图片，演示记忆长廊的多图记忆能力。
    private static func seedMultiplePhotoMemory(
        in context: NSManagedObjectContext,
        thought: Thought
    ) async throws {
        guard thought.sortedAttachments.count < 3 else { return }

        let photoNames = [
            "KunmingMemoryCloud",
            "KunmingMemoryCoffee",
            "KunmingMemoryDessert"
        ]
        let repository = ThoughtRepository(context: context)
        for name in photoNames {
            guard let image = UIImage(named: name),
                  let imageData = image.jpegData(compressionQuality: 0.9) else {
                throw ScreenshotSeedError.missingMemoryPhoto(name)
            }
            _ = try await repository.addAttachment(
                imageData: imageData,
                to: thought,
                sourceType: "screenshotSeed"
            )
        }
    }

    private static func seedConversation(
        context: NSManagedObjectContext,
        transaction: Transaction,
        task: TodoTask,
        habit: Habit,
        now: Date,
        startOfWeek: Date,
        memoryIDs: [String],
        story: Story
    ) throws {
        // 让生成后的周期回放自然落在聊天流最底部，避免宣传图先看到未来日期的演示消息。
        let base = now.addingTimeInterval(-15 * 60)

        // 里程碑八月剧本：回放卡之前只留一段与故事一致的简短对话，
        // 避免「午餐 36 元」「本月消费 1286 元」等默认剧本数字与 2.8 万的故事冲突。
        if story == .milestoneAugust {
            let queryID = insertMessage(
                in: context,
                role: "user",
                content: "8 月过得好快，帮我做一次月度回放吧",
                timestamp: base
            )
            let assistant = ChatMessage(context: context)
            assistant.id = UUID()
            assistant.role = "assistant"
            assistant.content = "好。这个月你的记录很完整，我把项目、消费、习惯和想法放在一起看了一遍，整理成了这份回放。"
            assistant.timestamp = base.addingTimeInterval(5)
            assistant.intent = nil
            assistant.isStreaming = false
            assistant.parentMessageId = queryID
            assistant.messageType = ChatMessageType.normal.rawValue
            assistant.extractedDataJSON = try encode([
                "memoryUsedCount": String(memoryIDs.count),
                "memoryUsedIDs": memoryIDs.joined(separator: ",")
            ])
            return
        }

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
            totalExpense: 1_286.60,
            totalIncome: 8_500,
            transactionCount: 18,
            averageDailyExpense: 42.89,
            topExpenseCategories: [
                FinanceCategoryItem(categoryName: "餐饮", amount: 438, percentage: 34.0),
                FinanceCategoryItem(categoryName: "购物", amount: 296, percentage: 23.0),
                FinanceCategoryItem(categoryName: "交通", amount: 154, percentage: 12.0)
            ],
            monthlyBreakdown: [],
            previousPeriodExpense: 1_498.50,
            anomalyDescriptions: [],
            budgetPerformance: FinanceBudgetItem(
                budgetAmount: 2_000,
                spentAmount: 1_286.60,
                remainingAmount: 713.40,
                utilizationRate: 0.6433,
                periodType: "monthly",
                originalAmount: 2_000,
                carryoverDeduction: 0
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
        analysisAssistant.extractedDataJSON = try encode([
            "memoryUsedCount": String(memoryIDs.count),
            "memoryUsedIDs": memoryIDs.joined(separator: ",")
        ])
    }

    private static func seedInsight(
        context: NSManagedObjectContext,
        startOfWeek: Date,
        story: Story
    ) throws {
        // 洞察页默认展示最近一个完整周期，因此用上周而不是尚未结束的本周。
        // 忙碌一周剧本例外：分析对话讲的就是“这一周”，周期跟随拍摄当周。
        let insightStart: Date
        let end: Date
        if story == .busyWeek {
            insightStart = startOfWeek
            end = Calendar.current.date(byAdding: .day, value: 7, to: startOfWeek)!
        } else {
            insightStart = Calendar.current.date(byAdding: .day, value: -7, to: startOfWeek)!
            end = startOfWeek
        }
        let payload: MemoryInsightPayload
        switch story {
        case .milestoneAugust:
            payload = makeMilestoneAugustWeeklyPayload()
        case .busyWeek:
            payload = makeBusyWeekWeeklyPayload()
        case .rhythm:
            payload = makeRhythmWeeklyPayload()
        }
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

    private static func makeRhythmWeeklyPayload() -> MemoryInsightPayload {
        MemoryInsightPayload(
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
    }

    /// 里程碑八月剧本的周报：与月度回放同一故事线（项目落地后的一周）。
    private static func makeMilestoneAugustWeeklyPayload() -> MemoryInsightPayload {
        MemoryInsightPayload(
            title: "这一周，落地之后的余震",
            summary: "项目过审后的第一周，你没有停下来：收尾、复盘，以及想它下一步去哪。",
            cards: [
                MemoryInsightCard(
                    id: "milestone-week-overview",
                    type: .overview,
                    title: "节奏在重建，而不是松掉",
                    body: "项目落地后，你的记录依然完整，只是主题从「赶进度」换成了「想下一步」。",
                    evidence: [],
                    suggestedQuestion: "下周先做哪一件？",
                    moduleHint: "overview"
                ),
                MemoryInsightCard(
                    id: "milestone-week-task",
                    type: .task,
                    title: "收尾清单清掉了 4 件",
                    body: "发布相关的事务在周内被逐条关掉，没有拖到九月。",
                    evidence: [],
                    suggestedQuestion: "帮我把剩下的事排个优先级",
                    moduleHint: "task"
                ),
                MemoryInsightCard(
                    id: "milestone-week-thought",
                    type: .thought,
                    title: "想法都在围着「怎么用它」转",
                    body: "这一周的想法几乎都和项目的下一步有关：推广、反馈、以及你自己的使用感。",
                    evidence: [],
                    suggestedQuestion: "把这些想法整理成一个计划",
                    moduleHint: "thought"
                )
            ],
            suggestedQuestions: [
                "怎么让项目被更多人看到",
                "下周先做哪一件？"
            ]
        )
    }

    // MARK: - 忙碌一周剧本（第四篇笔记拍摄用）

    /// 「我不想再做一个催你自律的 App」剧本：
    /// 周内少量工作日记录 → 周五晚的深度分析 → 今天中午「一句话三件事」→
    /// 一条等待用户确认的观察。日期跟随拍摄当周，拍摄日应为周六或周日，
    /// 这样周一至周五的记录都落在“已发生”的一侧。
    private static func seedBusyWeekAll(
        in context: NSManagedObjectContext,
        account: Account,
        now: Date,
        startOfWeek: Date
    ) async throws {
        let transaction = try await seedBusyWeekTransactions(
            context: context,
            account: account,
            startOfWeek: startOfWeek
        )
        let habit = try seedBusyWeekHabits(context: context, startOfWeek: startOfWeek)
        let task = try seedBusyWeekTasks(context: context, startOfWeek: startOfWeek)
        try seedBusyWeekThoughts(context: context, startOfWeek: startOfWeek)
        try await seedBusyWeekCandidateMemory(now: now)
        try seedBusyWeekConversation(
            context: context,
            transaction: transaction,
            task: task,
            habit: habit,
            startOfWeek: startOfWeek
        )
        try seedInsight(context: context, startOfWeek: startOfWeek, story: .busyWeek)
    }

    /// 一周的少量账单：工作日午餐 + 两晚加班外卖，今天中午的“午饭 36 元”。
    private static func seedBusyWeekTransactions(
        context: NSManagedObjectContext,
        account: Account,
        startOfWeek: Date
    ) async throws -> Transaction {
        let categories = try context.fetch(Category.fetchRequest())
        let byName = Dictionary(grouping: categories.filter(\.isSubCategory), by: \.name)
        let samples: [(day: Int, hour: Int, minute: Int, amount: Decimal, category: String, note: String)] = [
            (0, 12, 10, 32, "午餐", "午餐"),
            (0, 20, 10, 45, "外卖", "加班外卖"),
            (1, 12, 20, 38, "午餐", "午餐"),
            (1, 20, 30, 52, "晚餐", "改完方案的晚饭"),
            (2, 12, 25, 36, "午餐", "午餐"),
            (2, 18, 50, 4, "地铁", "回家地铁"),
            (3, 12, 15, 42, "午餐", "午餐"),
            (3, 21, 10, 58, "外卖", "排期收尾的外卖"),
            (4, 12, 20, 35, "午餐", "午餐"),
            (4, 19, 30, 66, "超市", "周五补货"),
            (5, 8, 15, 18, "早餐", "早餐和豆浆"),
            (5, 12, 20, 36, "午餐", "午饭")
        ]

        var actionTransaction: Transaction?
        for sample in samples {
            guard let category = byName[sample.category]?.first else {
                throw ScreenshotSeedError.missingCategory(sample.category)
            }
            let sampleDate = date(
                from: startOfWeek,
                dayOffset: sample.day,
                hour: sample.hour,
                minute: sample.minute
            )
            let transaction = try await FinanceRepository.shared.addTransaction(
                amount: sample.amount,
                type: .expense,
                category: category,
                account: account,
                date: sampleDate,
                note: sample.note
            )
            if sample.day == 5 && sample.amount == 36 {
                actionTransaction = transaction
            }
        }

        guard let actionTransaction else {
            throw ScreenshotSeedError.missingCategory("午餐")
        }
        return actionTransaction
    }

    /// 晚饭后散步（周三、周五、今晚各一次）与周一的晚间阅读。
    private static func seedBusyWeekHabits(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws -> Habit {
        let walk = Habit.create(
            in: context,
            name: "晚饭后散步",
            icon: "figure.walk",
            color: "#34C759",
            type: .checkIn,
            frequency: .daily,
            targetCount: 1,
            sortOrder: 0
        )
        let reading = Habit.create(
            in: context,
            name: "晚间阅读",
            icon: "book.fill",
            color: "#FF6B35",
            type: .checkIn,
            frequency: .daily,
            targetCount: 1,
            sortOrder: 1
        )

        for day in [2, 4, 5] {
            let record = HabitRecord.createCheckIn(in: context, habit: walk)
            record.date = date(from: startOfWeek, dayOffset: day, hour: 20, minute: 25)
            record.createdAt = record.date
        }
        let readingRecord = HabitRecord.createCheckIn(in: context, habit: reading)
        readingRecord.date = date(from: startOfWeek, dayOffset: 0, hour: 21, minute: 40)
        readingRecord.createdAt = readingRecord.date
        return walk
    }

    /// 周内三件已完成的工作任务 + 一件今天创建的访谈整理待办（截止下周五 18:00）。
    private static func seedBusyWeekTasks(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws -> TodoTask {
        let completedSamples: [(String, Int, Int, Int)] = [
            ("周会材料补充", 0, 18, 20),
            ("临时改方案", 1, 20, 40),
            ("输出项目排期", 3, 19, 30)
        ]
        for sample in completedSamples {
            let completedAt = date(from: startOfWeek, dayOffset: sample.1, hour: sample.2, minute: sample.3)
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

        let interviewDue = date(from: startOfWeek, dayOffset: 11, hour: 18, minute: 0)
        let interviewTask = TodoTask.create(
            in: context,
            title: "整理用户访谈",
            priority: .high,
            dueDate: interviewDue
        )
        let createdAt = date(from: startOfWeek, dayOffset: 5, hour: 12, minute: 30)
        interviewTask.createdAt = createdAt
        interviewTask.updatedAt = createdAt

        let replyTask = TodoTask.create(
            in: context,
            title: "回复产品群留言",
            priority: .low,
            dueDate: date(from: startOfWeek, dayOffset: 5, hour: 22, minute: 0)
        )
        replyTask.createdAt = date(from: startOfWeek, dayOffset: 4, hour: 10, minute: 0)
        replyTask.updatedAt = replyTask.createdAt
        return interviewTask
    }

    /// 两条想法：周二晚的“躲一会儿”，和今天说完三件事之后的松一口气。
    private static func seedBusyWeekThoughts(
        context: NSManagedObjectContext,
        startOfWeek: Date
    ) throws {
        let repository = ThoughtRepository(context: context)
        let samples: [(content: String, mood: String, tags: [String], day: Int, hour: Int, minute: Int)] = [
            (
                "事情堆在一起的时候，我最想先躲一会儿。缓十分钟，再一件一件来。",
                "calm", ["生活"], 1, 20, 55
            ),
            (
                "把堆在脑子里的三件事一次说完，脑子清爽多了。记下来不等于要做完。",
                "calm", ["复盘"], 5, 12, 35
            )
        ]
        for sample in samples {
            let thought = try repository.create(
                content: sample.content,
                mood: sample.mood,
                tags: sample.tags
            )
            let createdAt = date(
                from: startOfWeek,
                dayOffset: sample.day,
                hour: sample.hour,
                minute: sample.minute
            )
            thought.createdAt = createdAt
            thought.updatedAt = createdAt
            thought.organizedStatus = "organized"
        }
    }

    /// 待确认的观察：措辞审慎、可被否定，只陈述记录里存在的线索。
    private static func seedBusyWeekCandidateMemory(now: Date) async throws {
        let anchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "busy-evening-week",
            displayLabel: "被占住的晚上"
        )
        // 跨域记忆要求 ≥2 条上游记忆做支撑，这里只有单条假设，落任务域。
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .task,
            sourceDomains: [.task],
            claimKind: .hypothesis,
            anchors: [anchor]
        )
        let record = makeScreenshotMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .task,
            sourceDomains: [.task],
            subjectKey: "busy-evening-week",
            anchorRefs: [anchor],
            claimKind: .hypothesis,
            persistenceClass: .phase,
            displaySummary: "这几天的忙乱，可能不只是任务多，也和临时事项集中在晚上有关。",
            aiUseSummary: "聊到晚间安排时，先向用户确认这个观察是否成立，再决定要不要参考。",
            prohibitedInferences: [
                "不要据此断言用户不自律或时间管理有问题",
                "不要把忙乱直接归因于用户的个人习惯"
            ],
            evidenceRefs: [
                HoloMemoryEvidenceRef(
                    id: "busy-week-task-evening",
                    kind: .entityRef,
                    sourceDomain: .task,
                    lineageKey: "busy-week-task-evening",
                    sourceID: "busy-week-evening-tasks",
                    revisionDigest: "v1",
                    observedAt: now,
                    summary: "周二和周四的任务都完成在晚上 7 点之后。"
                ),
                HoloMemoryEvidenceRef(
                    id: "busy-week-walk-gap",
                    kind: .entityRef,
                    sourceDomain: .habit,
                    lineageKey: "busy-week-walk-gap",
                    sourceID: "busy-week-walk-records",
                    revisionDigest: "v1",
                    observedAt: now,
                    summary: "晚饭后散步这周只记录了 2 次。"
                )
            ],
            upstreamMemoryIDs: [],
            confidenceScore: 0.62,
            state: .candidate,
            adoptionMetadata: HoloMemoryAdoptionMetadata(
                policyVersion: HoloMemoryActivationPolicy.currentVersion,
                disposition: .pendingConfirmation,
                reason: .hypothesis,
                evaluatedAt: now
            ),
            now: now
        )
        let repository = try await HoloMemoryRuntime.shared.repository()
        _ = try await repository.upsert(
            record,
            observationKey: "app-store-screenshot-memory-busyweek-v1"
        )
    }

    /// 对话顺序：周五晚的深度分析在前，今天中午的「一句话三件事」收尾。
    /// 对话打开时锚定在最新消息，正好落在三件事的执行结果卡上。
    private static func seedBusyWeekConversation(
        context: NSManagedObjectContext,
        transaction: Transaction,
        task: TodoTask,
        habit: Habit,
        startOfWeek: Date
    ) throws {
        let analysisQueryTime = date(from: startOfWeek, dayOffset: 4, hour: 21, minute: 30)
        let queryID = insertMessage(
            in: context,
            role: "user",
            content: "我这周为什么总觉得很忙？",
            timestamp: analysisQueryTime
        )
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let analysis = AnalysisContext(
            domain: .crossModule,
            periodLabel: "本周",
            startDate: dateFormatter.string(from: startOfWeek),
            endDate: dateFormatter.string(from: startOfWeek.addingTimeInterval(6 * 86_400)),
            comparisonLabel: nil,
            finance: nil,
            habit: nil,
            task: nil,
            thought: nil,
            health: nil,
            goal: nil,
            crossModule: CrossModuleAnalysisContext(
                highlights: [
                    "周二的「临时改方案」和周四的「输出项目排期」，都完成在晚上 7 点之后",
                    "两次外卖都出现在加班的晚上，晚饭拖到了 8 点以后",
                    "晚饭后散步这周只记录了 2 次，晚间阅读停在了周一"
                ],
                warnings: [
                    "连续几晚被临时事项占住，留给恢复的时间在变少"
                ]
            )
        )
        let analysisAssistant = ChatMessage(context: context)
        analysisAssistant.id = UUID()
        analysisAssistant.role = "assistant"
        // 详情页（点击查看详细分析）会按句拆成「核心结论 + 事实」，问题引用与
        // 证据都写进正文，保证详情页里问题和线索同时可见。
        analysisAssistant.content = "关于「我这周为什么总觉得很忙」，我把你这周的记录放在一起看了一遍。任务大多落在晚上：周二的「临时改方案」和周四的「输出项目排期」都在晚上 7 点后完成。晚饭后散步这周只记录了 2 次，晚间阅读停在了周一。两次外卖都出现在加班的晚上。所以不是你做得不够快，是晚上的时间被几件临时的事占住了。"
        analysisAssistant.timestamp = analysisQueryTime.addingTimeInterval(5)
        analysisAssistant.intent = AIIntent.queryAnalysis.rawValue
        analysisAssistant.isStreaming = false
        analysisAssistant.parentMessageId = queryID
        analysisAssistant.messageType = ChatMessageType.normal.rawValue
        analysisAssistant.analysisContextJSON = try encode(analysis)

        let actionTime = date(from: startOfWeek, dayOffset: 5, hour: 12, minute: 30)
        let userActionID = insertMessage(
            in: context,
            role: "user",
            content: "午饭 36 元，周五前整理用户访谈，今晚散步 20 分钟。",
            timestamp: actionTime
        )
        let execution = AIExecutionBatch(
            mode: .multiAction,
            items: [
                AIExecutionItem(
                    id: "busyweek-expense",
                    parseItemId: "busyweek-expense-parse",
                    intent: .recordExpense,
                    status: .success,
                    summaryText: "已记录午饭 36 元",
                    renderData: [
                        "amount": "36",
                        "note": "午饭",
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
                    id: "busyweek-task",
                    parseItemId: "busyweek-task-parse",
                    intent: .createTask,
                    status: .success,
                    summaryText: "已创建整理用户访谈",
                    renderData: [
                        "title": "整理用户访谈",
                        "dueDate": "周五 18:00",
                        "priority": "high",
                        "confirmationStatus": "confirmed"
                    ],
                    linkedEntityType: "task",
                    linkedEntityId: task.id.uuidString,
                    errorText: nil
                ),
                AIExecutionItem(
                    id: "busyweek-habit",
                    parseItemId: "busyweek-habit-parse",
                    intent: .checkIn,
                    status: .success,
                    summaryText: "晚饭后散步 20 分钟，已记到今晚",
                    renderData: [
                        "habitName": "晚饭后散步",
                        "streak": "2",
                        "completed": "true"
                    ],
                    linkedEntityType: "habit",
                    linkedEntityId: habit.id.uuidString,
                    errorText: nil
                )
            ],
            finalText: "三件事都记好了，各自归位。"
        )
        let actionAssistant = ChatMessage(context: context)
        actionAssistant.id = UUID()
        actionAssistant.role = "assistant"
        actionAssistant.content = "三件事都记好了，各自归位。"
        actionAssistant.timestamp = actionTime.addingTimeInterval(5)
        actionAssistant.intent = nil
        actionAssistant.isStreaming = false
        actionAssistant.parentMessageId = userActionID
        actionAssistant.messageType = ChatMessageType.normal.rawValue
        actionAssistant.executionBatchJSON = try encode(execution)
    }

    /// 周回放的种子内容：只陈述记录里能对上的线索，不催办、不下结论。
    private static func makeBusyWeekWeeklyPayload() -> MemoryInsightPayload {
        MemoryInsightPayload(
            title: "这一周，忙都去哪了",
            summary: "把任务、散步和支出摆在一起看：事情集中在晚上，晚间恢复被挤掉了几次。记录不会催你，只是把线索留在那里。",
            cards: [
                MemoryInsightCard(
                    id: "busyweek-overview",
                    type: .overview,
                    title: "忙，是从晚上开始的",
                    body: "这周的任务大多在晚饭前后收尾，晚上成了白天的延长线。",
                    evidence: [
                        MemoryInsightEvidence(id: "busyweek-overview-1", label: "周二 20:40 完成「临时改方案」", date: nil, sourceType: "task", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "busyweek-overview-2", label: "周四 19:30 完成「输出项目排期」", date: nil, sourceType: "task", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "下周怎么把晚上留回来？",
                    moduleHint: "overview"
                ),
                MemoryInsightCard(
                    id: "busyweek-task",
                    type: .task,
                    title: "3 件任务都完成在晚上",
                    body: "周会补充、临时改方案、输出排期——三件事没有一件拖过夜，但也都落在晚上。",
                    evidence: [
                        MemoryInsightEvidence(id: "busyweek-task-1", label: "周会材料补充 · 周一 18:20", date: nil, sourceType: "task", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "busyweek-task-2", label: "临时改方案 · 周二 20:40", date: nil, sourceType: "task", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "busyweek-task-3", label: "输出项目排期 · 周四 19:30", date: nil, sourceType: "task", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "哪件可以挪到白天？",
                    moduleHint: "task"
                ),
                MemoryInsightCard(
                    id: "busyweek-habit",
                    type: .habit,
                    title: "晚间行动被挤掉了几次",
                    body: "晚饭后散步这周记录了 3 次，晚间阅读停在了周一。不是放弃，是被临时的事顶掉了。",
                    evidence: [
                        MemoryInsightEvidence(id: "busyweek-habit-1", label: "晚饭后散步：周三、周五、今晚", date: nil, sourceType: "habitRecord", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "busyweek-habit-2", label: "晚间阅读：只有周一", date: nil, sourceType: "habitRecord", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "帮我把散步接回晚饭后",
                    moduleHint: "habit"
                ),
                MemoryInsightCard(
                    id: "busyweek-finance",
                    type: .finance,
                    title: "外卖出现在加班的晚上",
                    body: "两次外卖都在晚上 8 点以后，跟着加班一起出现。",
                    evidence: [
                        MemoryInsightEvidence(id: "busyweek-finance-1", label: "周一 20:10 外卖 ¥45", date: nil, sourceType: "transaction", matchedSourceId: nil),
                        MemoryInsightEvidence(id: "busyweek-finance-2", label: "周四 21:10 外卖 ¥58", date: nil, sourceType: "transaction", matchedSourceId: nil)
                    ],
                    suggestedQuestion: "看看这周的餐饮支出",
                    moduleHint: "finance"
                )
            ],
            suggestedQuestions: [
                "下周怎么把晚上留回来？",
                "帮我把散步接回晚饭后"
            ]
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
    case missingFeaturedThought
    case missingMemoryPhoto(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingCategory(let name): return "缺少演示分类：\(name)"
        case .missingFeaturedThought: return "缺少用于多图记忆演示的想法"
        case .missingMemoryPhoto(let name): return "缺少记忆长廊演示图片：\(name)"
        case .encodingFailed: return "演示 JSON 编码失败"
        }
    }
}
#endif
