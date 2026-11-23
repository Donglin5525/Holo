#if DEBUG
//
//  HoloStorySeeder.swift
//  Holo
//
//  剧本文件驱动的演示数据注入口（自媒体内容制作用，2026-11-23 东林批准）。
//  启动时带 HOLO_STORY_FILE=<文件名>，就读 Documents 下那份 JSON 剧本，按模块写进本地库。
//  字段清单见 scripts/holo_stories/SCHEMA.md；数据形状见 HoloStorySchema.swift。
//
//  门控、幂等、隔离上下文三件事照既有宣传图通道（HoloAppStoreScreenshotSeeder /
//  HoloASOFinanceSeeder）的做法：
//  - 只在 DEBUG + 模拟器编译进包，且必须显式给环境变量才工作；
//  - 按 meta.storyId 记「已注入」标记，同一剧本不重种；
//  - 全程写在父子两层临时上下文里，整份剧本成功后才一次落库，失败整体回滚。
//

import CoreData
import Foundation
import os.log

/// 读剧本文件并把演示数据写进本地库；正式 App 与真机不编译此入口。
@MainActor
enum HoloStorySeeder {
    static let fileKey = "HOLO_STORY_FILE"
    fileprivate static let seededKeyPrefix = "holo_story_seed_"
    fileprivate static let logger = Logger(subsystem: "com.holo.app", category: "HoloStory")

    /// 是否处于剧本注入模式（之前注入过、本次跳过的也算）。
    @discardableResult
    static func runIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) async -> Bool {
        #if targetEnvironment(simulator)
        guard let fileName = environment[fileKey], !fileName.isEmpty else { return false }
        do {
            return try await seed(fileName: fileName, defaults: defaults, now: now)
        } catch {
            // 演示通道不是功能路径：失败只留日志、不写标记，修好剧本后下次启动自动重试
            logger.error("剧本注入失败，本次未写入任何数据：\(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    #if targetEnvironment(simulator)
    // MARK: - 注入主流程

    private static func seed(fileName: String, defaults: UserDefaults, now: Date) async throws -> Bool {
        // 与宣传图通道同一道闸：演示数据绝不进开了云同步的库
        guard !CloudKitRuntimeAvailability.isAvailable else {
            throw StoryError.invalid("当前环境连着 iCloud 同步，演示数据不允许写入")
        }
        let story = try readStory(fileName: fileName)
        let storyId = story.meta.storyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storyId.isEmpty else { throw StoryError.invalid("meta.storyId 不能为空") }

        let seededKey = seededKeyPrefix + storyId
        guard !defaults.bool(forKey: seededKey) else {
            logger.notice("剧本 \(storyId, privacy: .public) 之前已注入过，本次跳过")
            return true
        }

        // 默认分类 / 默认账户要先在位，剧本才能按名字引用
        FinanceRepository.shared.setup()
        // 「旧优先级 → 轻重缓急两轴」是每台设备一次性迁移：先消化掉，否则它可能排在
        // 注入之后才跑，把剧本写好的 importance / urgencyMode 按 priority 覆盖掉
        TaskPriorityMigration.runIfNeeded(in: CoreDataStack.shared.viewContext)

        // 父上下文挂库、子上下文只对父上下文负责：想法 / 目标的写入 API 内部会 save，
        // 但 save 只到父上下文、不落盘；中途任何一步失败，两层一起回滚，库里不留半套数据
        let parent = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        parent.persistentStoreCoordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        parent.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let child = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        child.parent = parent

        let writer = StoryWriter(context: child, clock: StoryClock(now: now), now: now)
        let summary: StorySummary
        do {
            summary = try await writer.apply(story)
            try child.save()
            try parent.save()
        } catch {
            child.rollback()
            parent.rollback()
            throw error
        }

        defaults.set(true, forKey: seededKey)
        // 主角名 = App 显示名（首页问候语用）。写入显示名会顺带让新人引导按「老用户」跳过，
        // 所以想让演示直达首页，剧本把 persona 填上即可
        let persona = (story.meta.persona ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty {
            UserDisplayNameSettings(userDefaults: defaults).saveDisplayName(persona)
        }
        notifyDataChanged()
        logger.notice("剧本 \(storyId, privacy: .public) 注入完成：\(summary.text, privacy: .public)")
        if let claims = story.meta.lockedClaims {
            logger.notice("剧本 \(storyId, privacy: .public) 口径锁定表（对账在生成器侧，App 只回显）：\(claims.debugText, privacy: .public)")
        }
        return true
    }

    private static func readStory(fileName: String) throws -> StoryDocument {
        // 值是外部传入的：只认 Documents 目录下的直接子文件，不展开成任意路径
        guard !fileName.contains("/"), ![".", ".."].contains(fileName) else {
            throw StoryError.invalid("HOLO_STORY_FILE 只能填 Documents 下的文件名，不能带路径：\(fileName)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL.documentsDirectory.appendingPathComponent(fileName))
        } catch {
            throw StoryError.invalid("读不到剧本文件 Documents/\(fileName)：\(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(StoryDocument.self, from: data)
        } catch {
            throw StoryError.invalid("剧本 JSON 解析失败（Documents/\(fileName)）：\(describeDecodingError(error))")
        }
    }

    /// 把解码错误翻成带字段路径的一句话：剧本动辄上千条，只说「格式不对」没法改
    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            var text = ""
            for key in context.codingPath {
                if let index = key.intValue {
                    text += "[\(index)]"
                } else {
                    text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return text.isEmpty ? "（顶层）" : text
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "缺少必填字段 \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context):
            return "\(path(context)) 的类型不对（\(context.debugDescription)）"
        case .valueNotFound(_, let context):
            return "\(path(context)) 不允许为 null（\(context.debugDescription)）"
        case .dataCorrupted(let context):
            return "\(path(context)) 内容无法识别（\(context.debugDescription)）"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    /// 注入发生在首屏数据加载之后，各模块要重拉一遍才看得到新数据
    /// （与目标落库后的统一刷新出口同一组信号）
    private static func notifyDataChanged() {
        TodoRepository.shared.loadActiveTasks()
        HabitRepository.shared.loadActiveHabits()
        GoalRepository.shared.loadGoals()
        NotificationCenter.default.post(name: .todoDataDidChange, object: nil)
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
        NotificationCenter.default.post(name: .habitDataDidChange, object: nil)
        GoalNotificationService.broadcastGoalDataChange()
    }
    #endif
}

#if targetEnvironment(simulator)
// MARK: - 写入结果

private struct StorySummary {
    var accounts = 0
    var categories = 0
    var budgets = 0
    var financeProjects = 0
    var transactions = 0
    var thoughts = 0
    var tasks = 0
    var habits = 0
    var habitRecords = 0
    var goals = 0
    var metricLogs = 0

    var text: String {
        "账户 \(accounts)／分类 \(categories)／预算 \(budgets)／项目 \(financeProjects)／交易 \(transactions)"
            + "／想法 \(thoughts)／任务 \(tasks)／习惯 \(habits)／习惯记录 \(habitRecords)／目标 \(goals)／目标记录 \(metricLogs)"
    }
}

// MARK: - 写入器

/// 一份剧本的一次写入会话：持有隔离上下文、日期时钟，以及各模块「剧本里的名字 → 对象」的对照表。
@MainActor
private final class StoryWriter {
    let context: NSManagedObjectContext
    let clock: StoryClock
    let now: Date

    private static let habitTypes: [String: HabitType] = ["checkIn": .checkIn, "numeric": .numeric]
    private static let habitAggregations: [String: HabitAggregationType] = ["sum": .sum, "latest": .latest]
    private static let taskPriorities: [String: TaskPriority] = ["urgent": .urgent, "high": .high, "medium": .medium, "low": .low]
    private static let taskImportances: [String: TaskImportance] = ["unknown": .unknown, "p1": .p1, "p2": .p2, "p3": .p3]
    private static let taskUrgencyModes: [String: TaskUrgencyMode] = ["auto": .auto, "unknown": .unknown, "p1": .p1, "p2": .p2, "p3": .p3]
    /// 想法整理状态（Thought.organizedStatus 的全部取值）；演示默认 organized，不会在启动后被送去 AI 整理
    private static let thoughtStatuses: [String: String] = [
        "unprocessed": "unprocessed", "pending": "pending", "processing": "processing", "organized": "organized",
        "failed": "failed", "disabled": "disabled", "skipped": "skipped", "excluded": "excluded",
    ]

    /// 库里已有的活账户（含预设的现金 / 微信 / 支付宝等），供剧本按名字直接引用
    private var libraryAccounts: [Account] = []
    /// 剧本声明过的账户（含其中与库同名的）
    private var accounts: [String: Account] = [:]
    /// 库里的活分类 + 本剧本新建的分类
    private var categories: [Category] = []
    private var declaredCategoryKeys = Set<String>()
    private var financeProjects: [String: FinanceProject] = [:]
    /// 交易的 id 只是剧本内给退款指路用的名字（不是落库的 UUID）：占位集合查重，字典存可被退的普通交易
    private var transactionIDs = Set<String>()
    private var transactions: [String: Transaction] = [:]
    private var habits: [String: Habit] = [:]
    private var tasks: [String: TodoTask] = [:]
    private var summary = StorySummary()
    /// 分期 / 退款走仓库的既有写入，字段口径不另抄一份
    private lazy var finance = FinanceRepository(context: context)

    init(context: NSManagedObjectContext, clock: StoryClock, now: Date) {
        self.context = context
        self.clock = clock
        self.now = now
    }

    /// 按依赖顺序写：容器（账户 / 分类 / 项目）→ 预算 → 交易 → 习惯与记录 → 任务 → 想法 → 目标。
    /// 分期 / 退款走仓库的异步写入，所以整条链是 async。
    func apply(_ story: StoryDocument) async throws -> StorySummary {
        let accountRequest = Account.fetchRequest()
        accountRequest.predicate = NSPredicate(format: "deletedAt == nil")
        libraryAccounts = DuplicateRowFilter.deduplicatingCopies(try context.fetch(accountRequest))
        try loadAccounts(story.accounts)
        try loadCategories(story.categories)
        try loadFinanceProjects(story.financeProjects)
        try writeBudgets(story.budgets)
        try await writeTransactions(story.transactions)
        try loadHabits(story.habits)
        try writeHabitRecords(story.habitRecords)
        try writeTasks(story.tasks)
        try writeThoughts(story.thoughts)
        try writeGoals(story.goals)

        // TODO(story 第二批): conversations（ChatMessage）/ insights（MemoryInsight）/
        // memoryRecords（HoloMemoryRecord）的写入；现在解码层先接受，非空时只提示不写。
        for (module, rows) in [("conversations", story.conversations),
                               ("insights", story.insights),
                               ("memoryRecords", story.memoryRecords)] where !rows.isEmpty {
            HoloStorySeeder.logger.notice("剧本里的 \(module) 有 \(rows.count) 条，属于第二批模块，本次未写入")
        }
        return summary
    }

    // MARK: 通用取值

    /// 金额换算：剧本写整数分，库里存元
    func money(_ cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    /// 空备注在 App 里就是「没写」，统一归成 nil
    func optionalText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func requiredName(_ text: String?, _ field: String) throws -> String {
        guard let name = optionalText(text) else { throw StoryError.invalid("\(field) 不能为空") }
        return name
    }

    func requiredDate(_ text: String?, _ field: String) throws -> Date {
        guard let text = optionalText(text) else { throw StoryError.invalid("\(field) 不能为空") }
        return try clock.date(text)
    }

    /// 剧本用单词写枚举（App 里有些枚举的原始值是数字或不是穷举的字符串），这里按名字对上
    func named<T: RawRepresentable>(_ text: String?, fallback: String? = nil, as type: T.Type, field: String) throws -> T
    where T.RawValue == String {
        guard let raw = text ?? fallback, let value = T(rawValue: raw) else {
            throw StoryError.invalid("\(field) 不认识：「\(text ?? "")」")
        }
        return value
    }

    func lookup<V>(_ table: [String: V], _ text: String?, fallback: String, field: String) throws -> V {
        guard let value = table[text ?? fallback] else {
            throw StoryError.invalid("\(field) 不认识：「\(text ?? "")」，只能是 \(table.keys.sorted().joined(separator: " / "))")
        }
        return value
    }

    /// 剧本里用名字引用账户：剧本声明过的优先，其次是库里已有的（如预设的「微信」）；空名 = 默认账户
    func resolveAccount(named name: String, field: String) throws -> Account {
        let key = optionalText(name) ?? ""
        if key.isEmpty, let fallback = Account.getDefaultAccount(in: context) { return fallback }
        if let account = accounts[key] ?? libraryAccounts.first(where: { $0.name == key }) { return account }
        throw StoryError.invalid("\(field) 找不到账户「\(name)」：请先在 accounts 里声明，或改成已有的账户名")
    }
}

// MARK: - 记账：账户 / 分类 / 项目 / 预算 / 交易

private extension StoryWriter {
    func loadAccounts(_ rows: [StoryAccount]) throws {
        let existing = libraryAccounts
        var nextSortOrder = Int(existing.map(\.sortOrder).max() ?? -1) + 1

        for (index, row) in rows.enumerated() {
            let field = "accounts[\(index)]"
            let name = try requiredName(row.name, "\(field).name")
            let type = try named(row.type, as: AccountType.self, field: "\(field).type")
            guard accounts[name] == nil else {
                throw StoryError.invalid("\(field)：账户「\(name)」在剧本里重复声明")
            }
            // 同名账户直接复用（剧本不必重建预设账户），其余字段只在该账户不存在时用于新建
            if let account = existing.first(where: { $0.name == name }) {
                guard account.accountType == type else {
                    throw StoryError.invalid("\(field)：已有账户「\(name)」是 \(account.accountType.rawValue) 型，与剧本的 \(row.type) 不一致")
                }
                accounts[name] = account
                continue
            }
            let account = Account.create(
                in: context,
                name: name,
                type: type.rawValue,
                initialBalance: NSDecimalNumber(decimal: money(row.initialBalanceCents ?? 0)),
                icon: row.icon ?? "",
                color: row.color ?? type.defaultColor,
                sortOrder: Int16(nextSortOrder),
                notes: optionalText(row.notes)
            )
            nextSortOrder += 1
            if type.isCreditCard {
                if let billingDay = row.billingDay { account.billingDay = NSNumber(value: billingDay) }
                if let dueDay = row.dueDay { account.dueDay = NSNumber(value: dueDay) }
                if let creditLimitCents = row.creditLimitCents {
                    account.creditLimit = NSDecimalNumber(decimal: money(creditLimitCents))
                }
                account.dueReminderEnabled = row.dueReminderEnabled ?? false
            }
            accounts[name] = account
            summary.accounts += 1
        }
    }

    func loadCategories(_ rows: [StoryCategory]) throws {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        categories = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))

        for (index, row) in rows.enumerated() {
            let field = "categories[\(index)]"
            let name = try requiredName(row.name, "\(field).name")
            let type = try named(row.type, as: TransactionType.self, field: "\(field).type")
            let parentReference = optionalText(row.parent)
            let key = "\(type.rawValue)|\(parentReference ?? "")|\(name)"
            guard declaredCategoryKeys.insert(key).inserted else {
                throw StoryError.invalid("\(field)：分类「\(name)」在剧本里重复声明")
            }
            // 同级同名同类型已存在（含预设分类、含本剧本刚建的）就复用，不重建
            if parentReference == nil, topLevelCategory(named: name, type: type) != nil { continue }
            if children(named: name, type: type).contains(where: { parentName(of: $0) == parentReference }) { continue }
            // 给了父级但该一级还不存在：连一级一起建
            let parent = try parentReference.map { try makeTopLevelCategory(named: $0, type: type) }
            _ = makeCategory(named: name, type: type, parent: parent, icon: row.icon, color: row.color)
        }
    }

    private func topLevelCategory(named name: String, type: TransactionType) -> Category? {
        categories.first { $0.parentId == nil && $0.name == name && $0.transactionType == type }
    }

    private func makeTopLevelCategory(named name: String, type: TransactionType) throws -> Category {
        if let existing = topLevelCategory(named: name, type: type) {
            return existing
        }
        return makeCategory(named: name, type: type, parent: nil, icon: nil, color: nil)
    }

    private func makeCategory(named name: String, type: TransactionType, parent: Category?, icon: String?, color: String?) -> Category {
        // 排序接在同级末尾（同 FinanceRepository.addCategory）
        let siblings = categories.filter { $0.transactionType == type && $0.parentId == parent?.id }
        let category = Category.create(
            in: context,
            name: name,
            icon: icon ?? (parent == nil ? "questionmark.folder.fill" : "circle.fill"),
            color: color ?? parent?.color ?? (type == .expense ? "#64748B" : "#A855F7"),
            type: type.rawValue,
            sortOrder: Int16(siblings.map(\.sortOrder).max() ?? -1) + 1,
            parentId: parent?.id
        )
        categories.append(category)
        summary.categories += 1
        return category
    }

    /// 该名字下的全部二级分类（同名可能挂在不同的一级下，如「洗衣」「话费」）
    private func children(named name: String, type: TransactionType) -> [Category] {
        categories.filter { $0.parentId != nil && $0.name == name && $0.transactionType == type }
    }

    private func parentName(of category: Category) -> String? {
        guard let parentID = category.parentId else { return nil }
        return categories.first { $0.id == parentID }?.name
    }

    /// 交易用的分类：必须是二级。写「午餐」或带父级的「餐饮/午餐」
    func resolveCategory(_ reference: String, type: TransactionType, field: String) throws -> Category {
        // 预设里有名字本身带斜杠的二级分类（「密室/剧本」）：整串先按完整名字对一次
        let byFullName = children(named: reference, type: type)
        if byFullName.count == 1 { return byFullName[0] }
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name: String
        let requiredParent: String?
        switch parts.count {
        case 1: (name, requiredParent) = (parts[0], nil)
        case 2: (name, requiredParent) = (parts[1], parts[0])
        default: throw StoryError.invalid("\(field) 分类只能写「二级名」或「一级名/二级名」：\(reference)")
        }
        let matches = children(named: name, type: type).filter { requiredParent == nil || parentName(of: $0) == requiredParent }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw StoryError.invalid("\(field) 找不到\(type.displayName)二级分类「\(reference)」：交易只能挂二级分类，预设分类直接写名字，其余先在 categories 里声明")
        default:
            let parents = matches.compactMap { parentName(of: $0) }.sorted().joined(separator: "、")
            throw StoryError.invalid("\(field)：「\(name)」在 \(parents) 下都有，请写成「一级/二级」")
        }
    }

    func loadFinanceProjects(_ rows: [StoryFinanceProject]) throws {
        let request = FinanceProject.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
        for (index, row) in rows.enumerated() {
            let field = "financeProjects[\(index)]"
            let name = try requiredName(row.name, "\(field).name")
            guard financeProjects[name] == nil else {
                throw StoryError.invalid("\(field)：项目「\(name)」在剧本里重复声明")
            }
            if let project = existing.first(where: { $0.name == name }) {
                financeProjects[name] = project
                continue
            }
            let project = FinanceProject(context: context)
            project.id = UUID()
            project.name = name
            project.icon = row.icon ?? "📁"
            project.color = row.color ?? "#64748B"
            project.note = optionalText(row.note)
            project.startDate = try clock.optionalDate(row.startDate)
            project.endDate = try clock.optionalDate(row.endDate)
            project.budgetAmount = row.budgetAmountCents.map { NSDecimalNumber(decimal: money($0)) }
            project.status = try named(row.status, fallback: FinanceProjectStatus.active.rawValue,
                                       as: FinanceProjectStatus.self, field: "\(field).status").rawValue
            project.createdAt = try clock.optionalDate(row.createdAt) ?? now
            project.updatedAt = project.createdAt
            financeProjects[name] = project
            summary.financeProjects += 1
        }
    }

    func financeProject(named name: String, field: String) throws -> FinanceProject {
        if let project = financeProjects[name] { return project }
        throw StoryError.invalid("\(field) 找不到财务项目「\(name)」：请先在 financeProjects 里声明")
    }

    func writeBudgets(_ rows: [StoryBudget]) throws {
        for (index, row) in rows.enumerated() {
            let field = "budgets[\(index)]"
            let account = try resolveAccount(named: row.account, field: "\(field).account")
            guard row.amountCents > 0 else { throw StoryError.invalid("\(field).amountCents 必须大于 0") }
            let period = try named(row.period, as: BudgetPeriod.self, field: "\(field).period")
            // 不给起始日 = 对齐到启动当天所在的那个自然周期，当期消费立刻计入
            let startDate = try clock.optionalDate(row.startDate) ?? clock.periodStart(period.calendarComponent)
            var categoryID: UUID?
            if let reference = optionalText(row.category) {
                categoryID = try budgetCategoryScope(reference, field: "\(field).category").id
            }
            // 与 BudgetRepository 新建预算同一条规则：同账户同周期同范围只留一份
            let request = Budget.fetchRequest()
            var scope = "accountId == %@ AND period == %@ AND deletedAt == nil"
            var arguments: [Any] = [account.id as CVarArg, period.rawValue]
            if let categoryID {
                scope += " AND categoryId == %@"
                arguments.append(categoryID as CVarArg)
            } else {
                scope += " AND categoryId == nil"
            }
            request.predicate = NSPredicate(format: scope, argumentArray: arguments)
            guard try context.count(for: request) == 0 else {
                throw StoryError.invalid("\(field)：账户「\(row.account)」的\(period.displayName)预算已存在，同一账户同一周期同一范围只能有一份")
            }
            _ = Budget.create(
                in: context,
                accountId: account.id,
                amount: NSDecimalNumber(decimal: money(row.amountCents)),
                period: period,
                startDate: startDate,
                categoryId: categoryID
            )
            summary.budgets += 1
        }
    }

    /// 预算的分类范围：写一级 = 该一级及其下全部二级；写二级（或「一级/二级」）= 只算这一个
    private func budgetCategoryScope(_ reference: String, field: String) throws -> Category {
        if let topLevel = categories.first(where: { $0.parentId == nil && $0.name == reference && $0.transactionType == .expense }) {
            return topLevel
        }
        return try resolveCategory(reference, type: .expense, field: field)
    }

    func writeTransactions(_ rows: [StoryTransaction]) async throws {
        // 退款笔要指向已建好的原交易，所以先建普通交易与分期，第二遍再建退款
        for (index, row) in rows.enumerated() where row.refundOf == nil {
            try await writeTransaction(row, index: index)
        }
        for (index, row) in rows.enumerated() where row.refundOf != nil {
            try await writeRefund(row, index: index)
        }
    }

    private func writeTransaction(_ row: StoryTransaction, index: Int) async throws {
        let field = "transactions[\(index)]"
        guard row.amountCents > 0 else { throw StoryError.invalid("\(field).amountCents 必须大于 0") }
        let type = try named(row.type, as: TransactionType.self, field: "\(field).type")
        let category = try resolveCategory(try requiredName(row.category, "\(field).category"), type: type, field: "\(field).category")
        let account = try resolveAccount(named: row.account ?? "", field: "\(field).account")
        let project = try optionalText(row.project).map { try financeProject(named: $0, field: "\(field).project") }
        let id = optionalText(row.id)
        if let id { try reserveTransactionID(id, field: field) }

        if let installment = row.installment {
            guard (2...Int(Int16.max)).contains(installment.periods) else {
                throw StoryError.invalid("\(field).installment.periods 必须在 2 到 \(Int16.max) 之间")
            }
            // 分期全部期次一次建齐（含未来期，App 展示时自己只取已发生的），日期按月顺延
            let group = try await finance.addInstallmentTransactions(
                totalAmount: money(row.amountCents),
                feePerPeriod: money(installment.feePerPeriodCents ?? 0),
                periods: installment.periods,
                type: type,
                category: category,
                account: account,
                startDate: try requiredDate(installment.startDate, "\(field).installment.startDate"),
                note: optionalText(row.note),
                remark: optionalText(row.remark),
                financeProject: project
            )
            // 分期组不能被退（与手动记退款同一条限制），所以它的 id 只占位、不进可退名单
            summary.transactions += group.count
            return
        }

        // 普通交易不走 FinanceRepository.addTransaction：那条路每笔都会发产品埋点 billCreated，
        // 而剧本模式不在埋点闸内，演示数据不该被当成真实记账行为上报。
        // 下面的字段赋值与 addTransaction 逐项对齐，改那边记得同步这里。
        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.amount = NSDecimalNumber(decimal: money(row.amountCents))
        transaction.type = type.rawValue
        transaction.category = category
        transaction.account = account
        transaction.date = try requiredDate(row.date, "\(field).date")
        transaction.note = optionalText(row.note)
        transaction.remark = optionalText(row.remark)
        let tags = (row.tags ?? []).filter { !$0.isEmpty }
        transaction.tags = tags.isEmpty ? nil : tags
        transaction.financeProjectId = project?.id
        transaction.createdAt = now
        transaction.updatedAt = now
        // 与真实入账同一把闸：分类必须是二级、父级健在且类型一致
        try FinanceCategoryIntegrity.validateForBooking(category, in: context)
        if let id { transactions[id] = transaction }
        summary.transactions += 1
    }

    private func writeRefund(_ row: StoryTransaction, index: Int) async throws {
        let field = "transactions[\(index)]"
        guard row.amountCents > 0 else { throw StoryError.invalid("\(field).amountCents 必须大于 0") }
        // 退款笔的分类 / 备注 / 项目继承原交易，剧本不能另行指定
        guard row.type == nil, row.category == nil, row.note == nil, row.project == nil,
              row.tags == nil, row.installment == nil else {
            throw StoryError.invalid("\(field)：退款笔的分类 / 备注 / 项目继承原交易，不能另写 type / category / note / project / tags / installment")
        }
        let originalID = try requiredName(row.refundOf, "\(field).refundOf")
        guard let original = transactions[originalID] else {
            throw StoryError.invalid("\(field).refundOf 找不到原交易「\(originalID)」：被退的那笔要先写、带上同样的 id，且不能是分期")
        }
        let id = optionalText(row.id)
        if let id { try reserveTransactionID(id, field: field) }
        // 不给账户 = 退回原账户；分类 / 备注 / 项目继承原交易，累计退款不超过原额，都由仓库方法把关
        let refund = try await finance.addRefundTransaction(
            original: original,
            amount: money(row.amountCents),
            date: try requiredDate(row.date, "\(field).date"),
            account: try optionalText(row.account).map { try resolveAccount(named: $0, field: "\(field).account") },
            remark: optionalText(row.remark)
        )
        if let id { transactions[id] = refund }
        summary.transactions += 1
    }

    /// 交易 id 在剧本内不能重复
    private func reserveTransactionID(_ id: String, field: String) throws {
        guard transactionIDs.insert(id).inserted else {
            throw StoryError.invalid("\(field)：交易 id「\(id)」在剧本里重复")
        }
    }
}

// MARK: - 习惯与记录

private extension StoryWriter {
    func loadHabits(_ rows: [StoryHabit]) throws {
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let existing = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
        var nextSortOrder = Int(existing.map(\.sortOrder).max() ?? -1) + 1

        for (index, row) in rows.enumerated() {
            let field = "habits[\(index)]"
            let name = try requiredName(row.name, "\(field).name")
            let type = try lookup(Self.habitTypes, row.type, fallback: "", field: "\(field).type")
            guard habits[name] == nil else {
                throw StoryError.invalid("\(field)：习惯「\(name)」在剧本里重复声明")
            }
            // 同名习惯直接复用，其余字段只在该习惯不存在时用于新建
            if let habit = existing.first(where: { $0.name == name }) {
                habits[name] = habit
                continue
            }
            // 两类习惯各有各的字段，写串了直接报错，免得带着一套不适用的目标值落库
            let targetCount: Int?
            let targetValue: Double?
            let aggregation: HabitAggregationType
            switch type {
            case .checkIn:
                guard row.targetValue == nil, row.unit == nil, row.aggregation == nil else {
                    throw StoryError.invalid("\(field)：打卡型习惯不写 targetValue / unit / aggregation")
                }
                targetCount = row.targetCount
                targetValue = nil
                aggregation = .sum
            case .numeric:
                guard row.targetCount == nil else {
                    throw StoryError.invalid("\(field)：数值型习惯不写 targetCount")
                }
                targetCount = nil
                targetValue = row.targetValue
                aggregation = try lookup(Self.habitAggregations, row.aggregation, fallback: "sum", field: "\(field).aggregation")
            }
            let habit = Habit.create(
                in: context,
                name: name,
                icon: row.icon ?? "checkmark.circle",
                color: row.color ?? "#5B8CFF",
                type: type,
                frequency: try named(row.frequency, fallback: HabitFrequency.daily.rawValue,
                                     as: HabitFrequency.self, field: "\(field).frequency"),
                targetCount: targetCount,
                targetValue: targetValue,
                unit: optionalText(row.unit),
                habitDescription: row.description,
                aggregationType: aggregation,
                isBadHabit: row.isBadHabit ?? false,
                sortOrder: Int16(nextSortOrder)
            )
            nextSortOrder += 1
            // 创建日要早于第一条记录：习惯统计只认「创建之后」的记录
            habit.createdAt = try clock.optionalDate(row.createdAt) ?? now
            habit.updatedAt = habit.createdAt
            habit.isArchived = row.archived ?? false
            habit.isPaused = row.paused ?? false
            habits[name] = habit
            summary.habits += 1
        }
    }

    func writeHabitRecords(_ rows: [StoryHabitRecord]) throws {
        for (index, row) in rows.enumerated() {
            let field = "habitRecords[\(index)]"
            let name = try requiredName(row.habit, "\(field).habit")
            guard let habit = habits[name] else {
                throw StoryError.invalid("\(field) 找不到习惯「\(name)」：请先在 habits 里声明")
            }
            let date = try requiredDate(row.date, "\(field).date")
            let note = optionalText(row.note)
            let record: HabitRecord
            switch habit.habitType {
            case .numeric:
                guard let value = row.value else {
                    throw StoryError.invalid("\(field)：「\(name)」是数值型习惯，记录必须给 value")
                }
                record = HabitRecord.createNumeric(in: context, habit: habit, value: value, note: note)
            case .checkIn:
                guard row.value == nil else {
                    throw StoryError.invalid("\(field)：「\(name)」是打卡型习惯，记录不写 value")
                }
                record = HabitRecord.createCheckIn(in: context, habit: habit, isCompleted: row.completed ?? true, note: note)
            }
            record.date = date
            record.createdAt = date
            summary.habitRecords += 1
        }
    }
}

// MARK: - 待办

private extension StoryWriter {
    func writeTasks(_ rows: [StoryTask]) throws {
        for (index, row) in rows.enumerated() {
            let field = "tasks[\(index)]"
            let title = try requiredName(row.title, "\(field).title")
            guard tasks[title] == nil else {
                throw StoryError.invalid("\(field)：任务「\(title)」在剧本里重复（目标靠标题引用任务）")
            }
            let status = try named(row.status, fallback: TaskStatus.todo.rawValue, as: TaskStatus.self, field: "\(field).status")
            let plannedStart = try clock.optionalDate(row.plannedStart)
            let plannedEnd = try clock.optionalDate(row.plannedEnd)
            if (plannedStart == nil) != (plannedEnd == nil) {
                throw StoryError.invalid("\(field)：plannedStart 与 plannedEnd 必须成对出现")
            }
            if let plannedStart, let plannedEnd, !TodoTask.isValidPlannedRange(plannedStart, plannedEnd) {
                throw StoryError.invalid("\(field)：计划时间段须在同一天内，且 plannedStart 早于 plannedEnd")
            }
            let completedAt = try clock.optionalDate(row.completedAt)
            if status != .completed, completedAt != nil {
                throw StoryError.invalid("\(field)：只有 completed 的任务才写 completedAt")
            }

            let task = TodoTask.create(
                in: context,
                title: title,
                desc: optionalText(row.note),
                priority: try lookup(Self.taskPriorities, row.priority, fallback: "medium", field: "\(field).priority"),
                importance: try lookup(Self.taskImportances, row.importance, fallback: "unknown", field: "\(field).importance"),
                urgencyMode: try lookup(Self.taskUrgencyModes, row.urgencyMode, fallback: "auto", field: "\(field).urgencyMode"),
                dueDate: try clock.optionalDate(row.dueDate),
                isAllDay: row.isAllDay ?? false,
                plannedStart: plannedStart,
                plannedEnd: plannedEnd
            )
            // 完成态的两个字段必须同进同退：列表按 completed 过滤，详情按 completedAt 展示
            task.status = status.rawValue
            task.completed = status == .completed
            task.completedAt = status == .completed ? (completedAt ?? now) : nil
            task.createdAt = try clock.optionalDate(row.createdAt) ?? now
            task.updatedAt = task.completedAt ?? task.createdAt
            task.archived = row.archived ?? false
            tasks[title] = task
            summary.tasks += 1
        }
    }
}

// MARK: - 想法

private extension StoryWriter {
    func writeThoughts(_ rows: [StoryThought]) throws {
        // 走仓库的创建入口：标签要同时写 ThoughtTag 与 ThoughtTagAssignment 两处，不在这里另抄
        let repository = ThoughtRepository(context: context)
        for (index, row) in rows.enumerated() {
            let field = "thoughts[\(index)]"
            _ = try requiredName(row.content, "\(field).content")
            let mood = try row.mood.map { try named($0, as: ThoughtMoodType.self, field: "\(field).mood") }
            let status = try lookup(Self.thoughtStatuses, row.organizedStatus, fallback: "organized",
                                    field: "\(field).organizedStatus")
            let createdAt = try clock.optionalDate(row.createdAt) ?? now
            let thought = try repository.create(content: row.content, mood: mood?.rawValue, tags: row.tags ?? [])
            thought.createdAt = createdAt
            thought.updatedAt = createdAt
            thought.organizedStatus = status
            summary.thoughts += 1
        }
    }
}

// MARK: - 目标

private extension StoryWriter {
    func writeGoals(_ rows: [StoryGoal]) throws {
        for (index, row) in rows.enumerated() {
            try writeGoal(row, index: index)
        }
    }

    /// 目标的量化配置：数据来源 + 起点。过程型目标没有结果量，返回一份全空的。
    private func makeGoalMetric(_ row: StoryGoal, field: String, kind: GoalKind, createdAt: Date) throws -> GoalMetric {
        let hasQuantitativeFields = row.metricSource != nil || row.metricUnit != nil || row.targetValue != nil
            || row.baselineValue != nil || row.sourceHabit != nil || row.ledgerScope != nil || row.ledgerAccount != nil
            || row.comparison != nil || row.startDate != nil || !(row.metricLogs ?? []).isEmpty
        guard kind != .process else {
            guard !hasQuantitativeFields else {
                throw StoryError.invalid("\(field)：过程型目标不带量化字段与 metricLogs")
            }
            return GoalMetric()
        }
        guard row.targetValue != nil else {
            throw StoryError.invalid("\(field).targetValue：量化目标必须给目标值")
        }
        guard kind == .target || row.baselineValue == nil else {
            throw StoryError.invalid("\(field)：baselineValue 只用于达标型（kind = target）")
        }

        var metric = GoalMetric()
        metric.source = try named(row.metricSource, fallback: GoalMetricSource.manual.rawValue,
                                  as: GoalMetricSource.self, field: "\(field).metricSource")
        metric.comparison = try row.comparison.map { try named($0, as: GoalResultComparison.self, field: "\(field).comparison") }
        switch kind {
        case .cumulative:
            // 累计起点：不给就从目标创建那天算，手动记录只累计起点之后的
            metric.startDate = try clock.optionalDate(row.startDate) ?? createdAt
        case .target:
            guard row.startDate == nil else {
                throw StoryError.invalid("\(field)：达标型取最新一条记录的水平，不使用 startDate")
            }
        case .process:
            break
        }
        switch metric.source {
        case .manual:
            guard row.sourceHabit == nil, row.ledgerScope == nil, row.ledgerAccount == nil else {
                throw StoryError.invalid("\(field)：手动记录源不带 sourceHabit / ledgerScope / ledgerAccount")
            }
        case .habit:
            guard let habitName = optionalText(row.sourceHabit) else {
                throw StoryError.invalid("\(field).sourceHabit：数值习惯源必须指定一个习惯")
            }
            guard let habit = habits[habitName] else {
                throw StoryError.invalid("\(field).sourceHabit 找不到习惯「\(habitName)」：请先在 habits 里声明")
            }
            guard habit.isNumericType else {
                throw StoryError.invalid("\(field).sourceHabit：「\(habitName)」不是数值型习惯，当不了数据源")
            }
            metric.sourceHabit = habit
        case .ledger:
            let scopeKind = try named(row.ledgerScope, fallback: GoalLedgerScopeKind.wholeLedgerDelta.rawValue,
                                      as: GoalLedgerScopeKind.self, field: "\(field).ledgerScope")
            if scopeKind == .wholeLedgerDelta {
                guard row.ledgerAccount == nil else {
                    throw StoryError.invalid("\(field)：全账本口径不写 ledgerAccount")
                }
            } else {
                guard let accountName = optionalText(row.ledgerAccount) else {
                    throw StoryError.invalid("\(field).ledgerAccount：单账户口径必须指定账户")
                }
                let fundingAccount = try resolveAccount(named: accountName, field: "\(field).ledgerAccount")
                metric.ledgerScope = GoalLedgerScopePayload(kind: scopeKind, accountID: fundingAccount.id)
            }
        case .healthKit:
            throw StoryError.invalid("\(field)：模拟器读不到苹果健康数据，演示目标不支持 healthKit 数据源")
        }
        if metric.source != .manual, !(row.metricLogs ?? []).isEmpty {
            throw StoryError.invalid("\(field).metricLogs：只有 manual 源的目标才记手动进度")
        }
        return metric
    }

    /// 「复用既有习惯」的草案行：提交服务据此只建绑定、不新建习惯
    private static func reuseDraft(for habit: Habit) -> GoalHabitDraft {
        GoalHabitDraft(
            id: UUID().uuidString,
            isSelected: true,
            name: habit.name,
            frequency: habit.frequency,
            targetCount: habit.targetCountValue,
            type: habit.isNumericType ? "numeric" : "checkIn",
            unit: habit.unit,
            targetValue: habit.targetValueDouble,
            isBadHabit: habit.isBadHabit,
            successRule: nil,
            reuseHabitRef: "habit:\(habit.id.uuidString)",
            aggregation: habit.habitAggregationType == .latest ? "latest" : "sum"
        )
    }

    private func writeGoal(_ row: StoryGoal, index: Int) throws {
        let field = "goals[\(index)]"
        let title = try requiredName(row.title, "\(field).title")
        let domain = try named(row.domain, fallback: GoalDomain.other.rawValue, as: GoalDomain.self, field: "\(field).domain")
        let status = try named(row.status, fallback: GoalStatus.active.rawValue, as: GoalStatus.self, field: "\(field).status")
        let kind = try named(row.goalKind, fallback: GoalKind.process.rawValue, as: GoalKind.self, field: "\(field).goalKind")
        let createdAt = try clock.optionalDate(row.createdAt) ?? now
        let completedAt = try clock.optionalDate(row.completedAt)
        if status != .completed, completedAt != nil {
            throw StoryError.invalid("\(field)：只有 completed 的目标才写 completedAt")
        }
        let metric = try makeGoalMetric(row, field: field, kind: kind, createdAt: createdAt)

        var boundHabits: [Habit] = []
        for name in row.habits ?? [] {
            let habitName = try requiredName(name, "\(field).habits")
            guard let habit = habits[habitName] else {
                throw StoryError.invalid("\(field).habits 找不到习惯「\(habitName)」：请先在 habits 里声明")
            }
            if !boundHabits.contains(where: { $0 == habit }) { boundHabits.append(habit) }
        }

        let draft = GoalDraft(
            id: UUID().uuidString,
            title: title,
            summary: optionalText(row.summary),
            domain: domain,
            iconEmoji: optionalText(row.iconEmoji),
            desiredOutcome: optionalText(row.desiredOutcome),
            motivation: optionalText(row.motivation),
            deadlineText: try clock.optionalDate(row.deadline).map { GoalWorkshopValidator.strictDayFormatter.string(from: $0) },
            tasks: [],
            habits: boundHabits.map(Self.reuseDraft),
            missingInfoWarnings: [],
            goalKind: kind,
            metricSource: metric.source,
            metricUnit: optionalText(row.metricUnit),
            metricTargetValue: row.targetValue,
            metricBaselineValue: kind == .target ? row.baselineValue : nil,
            sourceHabitId: metric.sourceHabit?.id,
            ledgerScope: metric.ledgerScope,
            healthMetricKind: nil,
            metricComparison: metric.comparison,
            metricComparisonIsExplicit: metric.comparison == nil ? nil : true,
            metricStartDate: metric.startDate
        )
        // 与手动表单保存同一条提交链：目标 + 计划首版 + 习惯绑定一次写齐，数据形状和用户手建的一模一样
        let receipt = try GoalWorkshopCommitService.performCommit(
            draft: draft,
            allowAIContext: row.allowAIContext ?? false,
            source: "manual",
            sourceSessionID: nil,
            successEvidence: "",
            assumptions: [],
            selectedRouteTitle: nil,
            now: now,
            in: context
        )
        let request = Goal.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", receipt.goalID as CVarArg)
        guard let goal = try context.fetch(request).first else {
            throw StoryError.invalid("\(field)：目标写入后读不回来")
        }
        goal.createdAt = createdAt
        goal.status = status.rawValue
        goal.completedAt = status == .completed ? (completedAt ?? now) : nil
        goal.updatedAt = goal.completedAt ?? createdAt

        for taskTitle in row.tasks ?? [] {
            let name = try requiredName(taskTitle, "\(field).tasks")
            guard let task = tasks[name] else {
                throw StoryError.invalid("\(field).tasks 找不到任务「\(name)」：请先在 tasks 里写")
            }
            guard task.goal == nil else {
                throw StoryError.invalid("\(field).tasks：任务「\(name)」已经挂在目标「\(task.goal?.title ?? "")」下，一个任务只能属于一个目标")
            }
            task.goal = goal
        }
        for log in row.metricLogs ?? [] {
            let date = try requiredDate(log.date, "\(field).metricLogs.date")
            let entry = GoalMetricLog(context: context)
            entry.id = UUID()
            entry.goalId = goal.id
            entry.date = date
            entry.value = log.value
            entry.note = optionalText(log.note)
            entry.createdAt = date
            summary.metricLogs += 1
        }
        summary.goals += 1
    }
}

/// 目标的量化配置（数据来源 + 累计起点）
private struct GoalMetric {
    var source: GoalMetricSource = .manual
    var sourceHabit: Habit?
    var ledgerScope: GoalLedgerScopePayload?
    var comparison: GoalResultComparison?
    var startDate: Date?
}
#endif
#endif
