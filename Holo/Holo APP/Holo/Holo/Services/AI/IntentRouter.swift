//
//  IntentRouter.swift
//  Holo
//
//  意图路由器
//  将 AI 解析的意图映射到对应的 Repository 操作
//

import Foundation
import os.log

@MainActor
final class IntentRouter {

    static let shared = IntentRouter()

    private let logger = Logger(subsystem: "com.holo.app", category: "IntentRouter")

    private init() {}

    /// 路由结果
    struct RouteResult {
        let text: String
        let transactionId: UUID?
        let taskId: UUID?
        let habitId: UUID?
        let thoughtId: UUID?
        let linkedEntity: LinkedEntity?

        init(
            text: String,
            transactionId: UUID? = nil,
            taskId: UUID? = nil,
            habitId: UUID? = nil,
            thoughtId: UUID? = nil,
            linkedEntity: LinkedEntity? = nil
        ) {
            self.text = text
            self.transactionId = transactionId
            self.taskId = taskId
            self.habitId = habitId
            self.thoughtId = thoughtId
            self.linkedEntity = linkedEntity
        }
    }

    /// 根据解析结果执行对应的本地操作
    /// - Parameter result: AI 解析结果
    /// - Returns: 路由结果（含文本和关联实体 ID）
    func route(_ result: ParsedResult) async throws -> RouteResult {
        logger.info("路由意图：\(result.intent.rawValue)，置信度：\(result.confidence)")

        // 确保 FinanceRepository 已初始化（首次使用时 seed 默认分类/账户）
        FinanceRepository.shared.setup()

        switch result.intent {
        case .recordExpense:
            return try await handleRecordExpense(result)
        case .recordIncome:
            return try await handleRecordIncome(result)
        case .createTask:
            return try handleCreateTask(result)
        case .completeTask:
            return try handleCompleteTask(result)
        case .updateTask:
            return try handleUpdateTask(result)
        case .deleteTask:
            return try handleDeleteTask(result)
        case .recordMood:
            return try handleRecordMood(result)
        case .recordWeight:
            return try handleRecordWeight(result)
        case .checkIn:
            return try handleCheckIn(result)
        case .createNote:
            return try handleCreateNote(result)
        case .queryTasks:
            return try handleQueryTasks(result)
        case .queryHabits:
            return try handleQueryHabits(result)
        case .query, .unknown:
            return RouteResult(
                text: result.responseText ?? "我可以帮你记账、创建任务、记录心情等。有什么需要帮忙的吗？"
            )
        case .generateMemoryInsight:
            return await handleGenerateMemoryInsight(result)
        }
    }

    // MARK: - Record Expense

    private func handleRecordExpense(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我具体的金额")
        }

        let note = data["note"]
        let primaryCategory = data["primaryCategory"]
        let subCategory = data["subCategory"]

        logger.info("AI 返回科目：primaryCategory=\(primaryCategory ?? "nil"), subCategory=\(subCategory ?? "nil")")

        let categoryRepo = FinanceRepository.shared
        // 使用 AI 提取的科目信息进行匹配
        let category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            note: note ?? "",
            type: .expense
        )
        let account = try await categoryRepo.getDefaultAccount()

        guard let category = category, let account = account else {
            return RouteResult(text: "请先设置默认分类和账户")
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .expense,
            category: category,
            account: account,
            note: note
        )

        logger.info("支出已记录：¥\(amount)")
        let accountInfo = " → \(account.name)"
        return RouteResult(
            text: "已记录支出 ¥\(amountStr)\(note != nil ? "（\(note!)）" : "")\(accountInfo)",
            transactionId: transaction.id,
            linkedEntity: LinkedEntity(type: .transaction, id: transaction.id)
        )
    }

    // MARK: - Record Income

    private func handleRecordIncome(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我具体的金额")
        }

        let note = data["note"]
        let primaryCategory = data["primaryCategory"]
        let subCategory = data["subCategory"]
        let categoryRepo = FinanceRepository.shared

        // 使用 AI 提取的科目信息进行匹配
        let category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            note: note ?? "",
            type: .income
        )
        let account = try await categoryRepo.getDefaultAccount()

        guard let category = category, let account = account else {
            return RouteResult(text: "请先设置默认分类和账户")
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .income,
            category: category,
            account: account,
            note: note
        )

        logger.info("收入已记录：¥\(amount)")
        let accountInfo = " → \(account.name)"
        return RouteResult(
            text: "已记录收入 ¥\(amountStr)\(note != nil ? "（\(note!)）" : "")\(accountInfo)",
            transactionId: transaction.id,
            linkedEntity: LinkedEntity(type: .transaction, id: transaction.id)
        )
    }

    // MARK: - Create Task

    private func handleCreateTask(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我任务内容")
        }

        let todoRepo = TodoRepository.shared
        let dueDate = parseDate(from: data["dueDate"])
        let priority = parsePriority(data["priority"])
        let hasTime = data["dueDate"]?.contains(":") == true

        // 有具体时间时，自动添加提前 15 分钟提醒
        let reminders: Set<TaskReminder>? = (hasTime && dueDate != nil)
            ? [TaskReminder(offsetMinutes: 15)]
            : nil

        let task = try todoRepo.createTask(
            title: title,
            priority: priority ?? .medium,
            dueDate: dueDate,
            isAllDay: !hasTime,
            reminders: reminders
        )

        logger.info("任务已创建：\(title)")

        var responseText = "已创建任务：\(title)"
        if hasTime, let date = dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            responseText += "（\(formatter.string(from: date))，将提前 15 分钟提醒你）"
        }

        return RouteResult(
            text: responseText,
            taskId: task.id,
            linkedEntity: LinkedEntity(type: .task, id: task.id)
        )
    }

    // MARK: - Record Mood

    private func handleRecordMood(_ result: ParsedResult) throws -> RouteResult {
        let content = result.extractedData?["content"] ?? result.responseText ?? ""
        let mood = result.extractedData?["mood"]

        guard !content.isEmpty else {
            return RouteResult(text: "请告诉我你现在的感受")
        }

        let thoughtRepo = ThoughtRepository()
        let thought = try thoughtRepo.create(content: content, mood: mood, tags: [])

        logger.info("心情已记录")
        return RouteResult(
            text: "已记录你的心情",
            thoughtId: thought.id,
            linkedEntity: LinkedEntity(type: .thought, id: thought.id)
        )
    }

    // MARK: - Record Weight

    private func handleRecordWeight(_ result: ParsedResult) throws -> RouteResult {
        // 体重记录复用习惯模块的数值记录功能
        guard let data = result.extractedData,
              let weightStr = data["weight"],
              let weight = Double(weightStr) else {
            return RouteResult(text: "请告诉我体重数值")
        }

        // 查找体重习惯或创建
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }
        let weightHabit = habits.first { $0.unit == "kg" && $0.name.contains("体重") }

        if let habit = weightHabit {
            try habitRepo.addNumericRecord(for: habit, value: weight)
            logger.info("体重已记录：\(weight) kg")
            return RouteResult(
                text: "已记录体重：\(weight) kg",
                habitId: habit.id,
                linkedEntity: LinkedEntity(type: .habit, id: habit.id)
            )
        } else {
            return RouteResult(text: "未找到体重记录习惯，请先在习惯模块创建")
        }
    }

    // MARK: - Check In

    private func handleCheckIn(_ result: ParsedResult) throws -> RouteResult {
        let habitName = result.extractedData?["habitName"]
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }

        if let name = habitName {
            if let habit = habits.first(where: { $0.name.contains(name) || name.contains($0.name) }) {
                let completed = try habitRepo.toggleCheckIn(for: habit)
                return RouteResult(
                    text: completed ? "\(habit.name) 打卡成功" : "\(habit.name) 已取消打卡",
                    habitId: habit.id,
                    linkedEntity: LinkedEntity(type: .habit, id: habit.id)
                )
            }
        }

        // 如果只有一个活跃习惯，直接打卡
        if habits.count == 1 {
            let habit = habits[0]
            let completed = try habitRepo.toggleCheckIn(for: habit)
            return RouteResult(
                text: completed ? "\(habit.name) 打卡成功" : "\(habit.name) 已取消打卡",
                habitId: habit.id,
                linkedEntity: LinkedEntity(type: .habit, id: habit.id)
            )
        }

        // 多个习惯时列出选项
        let names = habits.map { $0.name }.joined(separator: "、")
        return RouteResult(text: "要给哪个习惯打卡？当前活跃习惯：\(names)")
    }

    // MARK: - Complete Task

    private func handleCompleteTask(_ result: ParsedResult) throws -> RouteResult {
        guard let keyword = result.extractedData?["taskKeyword"], !keyword.isEmpty else {
            return RouteResult(text: "请告诉我要完成哪个任务，比如「完成买牛奶」")
        }

        let todoRepo = TodoRepository.shared
        let matches = searchTasks(keyword: keyword)

        if matches.isEmpty {
            return RouteResult(text: "未找到匹配「\(keyword)」的任务，请说得更具体一些")
        }
        if matches.count > 1 {
            let list = matches.prefix(5).enumerated().map { (i, task) in
                "\(i + 1)）\(task.title)"
            }.joined(separator: "\n")
            return RouteResult(text: "找到多个匹配的任务：\n\(list)\n请确认是哪个")
        }

        let task = matches[0]
        try todoRepo.completeTask(task)
        logger.info("任务已完成：\(task.title)")
        return RouteResult(
            text: "已完成任务：\(task.title)",
            taskId: task.id,
            linkedEntity: LinkedEntity(type: .task, id: task.id)
        )
    }

    // MARK: - Update Task

    private func handleUpdateTask(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let keyword = data["taskKeyword"], !keyword.isEmpty else {
            return RouteResult(text: "请告诉我要修改哪个任务")
        }

        let matches = searchTasks(keyword: keyword)

        if matches.isEmpty {
            return RouteResult(text: "未找到匹配「\(keyword)」的任务，请说得更具体一些")
        }
        if matches.count > 1 {
            let list = matches.prefix(5).enumerated().map { (i, task) in
                "\(i + 1)）\(task.title)"
            }.joined(separator: "\n")
            return RouteResult(text: "找到多个匹配的任务：\n\(list)\n请确认是哪个")
        }

        let task = matches[0]
        let todoRepo = TodoRepository.shared
        let newTitle = data["title"]
        let newDesc = data["description"]
        let priority = parsePriority(data["priority"])
        let dueDate = parseDate(from: data["dueDate"])
        let tags = matchTags(from: data["tags"])

        try todoRepo.updateTask(
            task,
            title: newTitle,
            description: newDesc,
            priority: priority,
            dueDate: dueDate,
            tags: tags.isEmpty ? nil : tags
        )

        logger.info("任务已更新：\(task.title)")
        return RouteResult(
            text: "已更新任务：\(newTitle ?? task.title)",
            taskId: task.id,
            linkedEntity: LinkedEntity(type: .task, id: task.id)
        )
    }

    // MARK: - Delete Task

    private func handleDeleteTask(_ result: ParsedResult) throws -> RouteResult {
        guard let keyword = result.extractedData?["taskKeyword"], !keyword.isEmpty else {
            return RouteResult(text: "请告诉我要删除哪个任务")
        }

        let matches = searchTasks(keyword: keyword)

        if matches.isEmpty {
            return RouteResult(text: "未找到匹配「\(keyword)」的任务，请说得更具体一些")
        }
        if matches.count > 1 {
            let list = matches.prefix(5).enumerated().map { (i, task) in
                "\(i + 1)）\(task.title)"
            }.joined(separator: "\n")
            return RouteResult(text: "找到多个匹配的任务：\n\(list)\n请确认是哪个")
        }

        let task = matches[0]
        let todoRepo = TodoRepository.shared
        let taskTitle = task.title
        try todoRepo.deleteTask(task)

        logger.info("任务已删除：\(taskTitle)")
        return RouteResult(text: "已删除任务：\(taskTitle)")
    }

    // MARK: - Create Note

    private func handleCreateNote(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let content = data["noteContent"], !content.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我要记录的内容")
        }

        let tagStr = data["tags"]
        let tags = parseCSVTags(tagStr)

        let thoughtRepo = ThoughtRepository()
        let thought = try thoughtRepo.create(content: content, mood: nil, tags: tags)

        logger.info("笔记已创建")
        return RouteResult(
            text: "已记录笔记",
            thoughtId: thought.id,
            linkedEntity: LinkedEntity(type: .thought, id: thought.id)
        )
    }

    // MARK: - Query Tasks

    private func handleQueryTasks(_ result: ParsedResult) throws -> RouteResult {
        let todoRepo = TodoRepository.shared
        let tasks = todoRepo.activeTasks.filter { !$0.completed && !$0.deletedFlag }

        if tasks.isEmpty {
            return RouteResult(text: "目前没有待办任务")
        }

        let lines = tasks.prefix(10).map { task in
            let priority = task.taskPriority.displayTitle
            let due = task.dueDate.map { "（截止：\(formatDate($0))）" } ?? ""
            return "- \(task.title) [\(priority)]\(due)"
        }

        let extra = tasks.count > 10 ? "\n...还有 \(tasks.count - 10) 个任务" : ""
        return RouteResult(text: "当前待办任务：\n" + lines.joined(separator: "\n") + extra)
    }

    // MARK: - Query Habits

    private func handleQueryHabits(_ result: ParsedResult) throws -> RouteResult {
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }

        if habits.isEmpty {
            return RouteResult(text: "目前没有活跃的习惯")
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let lines = habits.map { habit in
            let hasRecordToday = habit.recordsArray.contains { record in
                calendar.isDate(record.date, inSameDayAs: today) && record.isCompleted
            }
            let status = hasRecordToday ? "✅ 已打卡" : "○ 未打卡"
            return "- \(habit.name)：\(status)"
        }

        return RouteResult(text: "今日习惯状态：\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Task Matching

    /// 任务搜索：精确匹配 > 标题包含 > 备注包含，按匹配优先级排序
    private func searchTasks(keyword: String) -> [TodoTask] {
        let todoRepo = TodoRepository.shared
        let active = todoRepo.activeTasks.filter { !$0.completed && !$0.deletedFlag }
        let lowerKeyword = keyword.lowercased()

        // 三级匹配
        var exactMatches: [TodoTask] = []
        var titleContains: [TodoTask] = []
        var descContains: [TodoTask] = []

        for task in active {
            if task.title.lowercased() == lowerKeyword {
                exactMatches.append(task)
            } else if task.title.lowercased().contains(lowerKeyword) {
                titleContains.append(task)
            } else if let desc = task.desc, desc.lowercased().contains(lowerKeyword) {
                descContains.append(task)
            }
        }

        // 同优先级内按创建时间倒序
        let sortByDate: (TodoTask, TodoTask) -> Bool = { $0.createdAt > $1.createdAt }
        return exactMatches.sorted(by: sortByDate)
            + titleContains.sorted(by: sortByDate)
            + descContains.sorted(by: sortByDate)
    }

    // MARK: - Date & Tag Utilities

    /// 解析日期字符串，支持 yyyy-MM-dd 和 yyyy-MM-dd HH:mm 格式
    private func parseDate(from string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        // 优先尝试带时间的格式
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = formatter.date(from: string) {
            return date
        }

        // 回退到纯日期格式
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// 格式化日期为 M月d日
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 解析优先级字符串为 TaskPriority
    private func parsePriority(_ string: String?) -> TaskPriority? {
        guard let string = string else { return nil }
        switch string {
        case "3", "urgent": return .urgent
        case "2", "high": return .high
        case "1", "medium": return .medium
        case "0", "low": return .low
        default: return nil
        }
    }

    /// 解析逗号分隔的标签字符串为 [String]
    private func parseCSVTags(_ string: String?) -> [String] {
        guard let string = string, !string.isEmpty else { return [] }
        return string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 将标签名列表匹配到已有的 TodoTag 对象
    private func matchTags(from string: String?) -> [TodoTag] {
        let names = parseCSVTags(string)
        guard !names.isEmpty else { return [] }
        let allTags = TodoRepository.shared.tags
        return names.compactMap { name in
            allTags.first { $0.name.lowercased() == name.lowercased() }
        }
    }

    // MARK: - Category Matching

    private func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        note: String,
        type: TransactionType
    ) async throws -> Category? {
        let categoryRepo = FinanceRepository.shared
        let categories = try await categoryRepo.getCategories(by: type)

        // 优先使用 AI 返回的科目信息进行匹配
        if let sub = subCategory, !sub.isEmpty {
            let matchResult = CategoryMatcherService.shared.matchSingle(
                primaryCategory: primaryCategory ?? "",
                subCategory: sub,
                type: type,
                categories: categories
            )
            if matchResult.matchType != .unmatched, let matched = matchResult.matchedCategory {
                return matched
            }
        }

        // 降级：用 note 文本尝试匹配
        if !note.isEmpty {
            let matchResult = CategoryMatcherService.shared.matchSingle(
                primaryCategory: primaryCategory ?? "",
                subCategory: note,
                type: type,
                categories: categories
            )
            if matchResult.matchType != .unmatched, let matched = matchResult.matchedCategory {
                return matched
            }
        }

        // 兜底：返回默认分类
        return categories.first { $0.isDefault } ?? categories.first
    }

    // MARK: - Memory Insight Generation

    private func handleGenerateMemoryInsight(_ result: ParsedResult) async -> RouteResult {
        let data = result.extractedData
        let periodStr = data?["periodType"] ?? "weekly"
        let periodType: MemoryInsightPeriodType = periodStr == "monthly" ? .monthly : .weekly

        let (start, end) = MemoryInsightContextBuilder.periodRange(
            periodType: periodType, referenceDate: Date()
        )

        let service = MemoryInsightService.shared

        guard service.isAIConfigured else {
            return RouteResult(
                text: "AI 服务尚未配置，请先在设置中配置 AI Provider 后再生成回放。"
            )
        }

        do {
            let insight = try await service.generateInsight(
                periodType: periodType,
                start: start,
                end: end,
                forceRefresh: false
            )
            let periodLabel = periodType == .weekly ? "周" : "月"
            return RouteResult(
                text: "已生成本\(periodLabel)回放「\(insight.title)」，你可以在记忆长廊中查看完整内容。",
                linkedEntity: LinkedEntity(
                    type: .memoryInsight,
                    id: insight.id
                )
            )
        } catch {
            logger.error("Chat 触发洞察生成失败：\(error.localizedDescription)")
            return RouteResult(
                text: "生成回放失败：\(error.localizedDescription)。请稍后重试。"
            )
        }
    }
}
