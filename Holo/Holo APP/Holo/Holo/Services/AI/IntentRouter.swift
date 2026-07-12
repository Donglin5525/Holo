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
        /// 分类未匹配到，使用了「待分类」兜底
        let categoryUnmatched: Bool
        /// 匹配成功后的真实科目名（来自 Core Data）
        let matchedPrimaryCategory: String?
        let matchedSubCategory: String?

        init(
            text: String,
            transactionId: UUID? = nil,
            taskId: UUID? = nil,
            habitId: UUID? = nil,
            thoughtId: UUID? = nil,
            linkedEntity: LinkedEntity? = nil,
            categoryUnmatched: Bool = false,
            matchedPrimaryCategory: String? = nil,
            matchedSubCategory: String? = nil
        ) {
            self.text = text
            self.transactionId = transactionId
            self.taskId = taskId
            self.habitId = habitId
            self.thoughtId = thoughtId
            self.linkedEntity = linkedEntity
            self.categoryUnmatched = categoryUnmatched
            self.matchedPrimaryCategory = matchedPrimaryCategory
            self.matchedSubCategory = matchedSubCategory
        }
    }

    /// 预览分类匹配结果（不创建交易，用于待确认卡片的分类展示）
    func previewCategoryMatch(
        extractedData: [String: String]?,
        type: TransactionType
    ) async throws -> (primary: String?, sub: String?) {
        guard let data = extractedData else { return (nil, nil) }

        FinanceRepository.shared.setup()

        let category = try await matchCategory(
            primaryCategory: data["primaryCategory"],
            subCategory: data["subCategory"],
            categoryCandidate: data["categoryCandidate"],
            normalizedCategoryCandidate: data["normalizedCategoryCandidate"],
            semanticCategoryHint: data["semanticCategoryHint"],
            note: data["note"] ?? "",
            type: type
        )

        if let category {
            return try await resolvedCategoryDisplayNames(for: category, type: type)
        }
        return (FinancePendingCategory.currentName, nil)
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
        case .query, .queryAnalysis, .flexibleDataQuery, .unknown:
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

        // 分期记账路径
        if data["installmentEnabled"] == "true" {
            return try await handleInstallmentExpense(data: data, amount: amount, amountStr: amountStr)
        }

        let primaryCategory = data["primaryCategory"]
        let subCategory = data["subCategory"]
        let categoryCandidate = data["categoryCandidate"]
        let normalizedCategoryCandidate = data["normalizedCategoryCandidate"]
        let semanticCategoryHint = data["semanticCategoryHint"]
        let note = transactionNote(from: data)

        logger.info("AI 返回科目：primaryCategory=\(primaryCategory ?? "nil"), subCategory=\(subCategory ?? "nil"), categoryCandidate=\(categoryCandidate ?? "nil"), normalizedCategoryCandidate=\(normalizedCategoryCandidate ?? "nil"), semanticCategoryHint=\(semanticCategoryHint ?? "nil")")

        let categoryRepo = FinanceRepository.shared
        var category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note ?? "",
            type: .expense
        )
        let account = try await categoryRepo.getDefaultAccount()

        guard let account = account else {
            return RouteResult(text: "请先设置默认账户")
        }

        var isUnmatched = false
        if category == nil {
            isUnmatched = true
            category = categoryRepo.ensurePendingCategory(type: .expense)
            logger.info("分类未匹配，使用「待分类」兜底")
        }

        guard let category else {
            return RouteResult(text: "分类信息异常，请重试")
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .expense,
            category: category,
            account: account,
            date: TransactionDateResolver.resolve(from: data),
            note: note
        )

        // 分类未匹配时暂存候选，供用户编辑时学习
        if isUnmatched, let candidate = categoryCandidate {
            CategoryLearnedMapping.recordTransactionCandidate(
                transactionId: transaction.id,
                candidate: candidate,
                type: .expense
            )
        }

        logger.info("支出已记录：¥\(amount)")

        let unmatchedText = isUnmatched
            ? AIResponseTextBuilder.unmatchedCategoryText(
                subCategory: subCategory,
                primaryCategory: primaryCategory,
                categoryCandidate: categoryCandidate
            ) : nil

        let matchedNames = try await resolvedCategoryDisplayNames(
            for: isUnmatched ? nil : transaction.category,
            type: .expense
        )

        return RouteResult(
            text: AIResponseTextBuilder.expenseRecorded(
                amount: amountStr,
                note: note,
                accountName: account.name,
                categoryUnmatched: isUnmatched,
                unmatchedCategory: unmatchedText
            ),
            transactionId: transaction.id,
            linkedEntity: LinkedEntity(type: .transaction, id: transaction.id),
            categoryUnmatched: isUnmatched,
            matchedPrimaryCategory: matchedNames.primary,
            matchedSubCategory: matchedNames.sub
        )
    }

    // MARK: - Record Income

    private func handleRecordIncome(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我具体的金额")
        }

        let primaryCategory = data["primaryCategory"]
        let subCategory = data["subCategory"]
        let categoryCandidate = data["categoryCandidate"]
        let normalizedCategoryCandidate = data["normalizedCategoryCandidate"]
        let semanticCategoryHint = data["semanticCategoryHint"]
        let note = transactionNote(from: data)
        let categoryRepo = FinanceRepository.shared

        var category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note ?? "",
            type: .income
        )
        let account = try await categoryRepo.getDefaultAccount()

        guard let account = account else {
            return RouteResult(text: "请先设置默认账户")
        }

        var isUnmatched = false
        if category == nil {
            isUnmatched = true
            category = categoryRepo.ensurePendingCategory(type: .income)
            logger.info("分类未匹配，使用「待分类」兜底")
        }

        guard let category else {
            return RouteResult(text: "分类信息异常，请重试")
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .income,
            category: category,
            account: account,
            date: TransactionDateResolver.resolve(from: data),
            note: note
        )

        // 分类未匹配时暂存候选，供用户编辑时学习
        if isUnmatched, let candidate = categoryCandidate {
            CategoryLearnedMapping.recordTransactionCandidate(
                transactionId: transaction.id,
                candidate: candidate,
                type: .income
            )
        }

        logger.info("收入已记录：¥\(amount)")

        let unmatchedText = isUnmatched
            ? AIResponseTextBuilder.unmatchedCategoryText(
                subCategory: subCategory,
                primaryCategory: primaryCategory,
                categoryCandidate: categoryCandidate
            ) : nil

        let matchedNames = try await resolvedCategoryDisplayNames(
            for: isUnmatched ? nil : transaction.category,
            type: .income
        )

        return RouteResult(
            text: AIResponseTextBuilder.incomeRecorded(
                amount: amountStr,
                note: note,
                accountName: account.name,
                categoryUnmatched: isUnmatched,
                unmatchedCategory: unmatchedText
            ),
            transactionId: transaction.id,
            linkedEntity: LinkedEntity(type: .transaction, id: transaction.id),
            categoryUnmatched: isUnmatched,
            matchedPrimaryCategory: matchedNames.primary,
            matchedSubCategory: matchedNames.sub
        )
    }

    // MARK: - Create Task

    private func handleCreateTask(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我任务内容")
        }

        let todoRepo = TodoRepository.shared
        let dueDateText = data["dueDate"] ?? data["reminderDate"]
        let dueDate = parseDate(from: dueDateText)
        let priority = parsePriority(data["priority"])
        let hasTime = dueDateText.map { NLDateParser.containsTimeComponent($0) } ?? false
        let checkItemTitles = SubtaskParser.parse(data["subtasks"])

        // 有具体时间时，自动添加提前 15 分钟提醒
        let reminders: Set<TaskReminder>? = (hasTime && dueDate != nil)
            ? [TaskReminder(offsetMinutes: 15)]
            : nil

        let task = try todoRepo.createTask(
            title: title,
            priority: priority ?? .medium,
            dueDate: dueDate,
            isAllDay: !hasTime,
            reminders: reminders,
            checkItemTitles: checkItemTitles.isEmpty ? nil : checkItemTitles
        )

        // 重复任务：创建 RepeatRule
        if data["repeatEnabled"] == "true", let repeatTypeStr = data["repeatType"] {
            let repeatType = RepeatType(rawValue: repeatTypeStr) ?? .daily
            let interval = data["repeatInterval"].flatMap { Int($0) } ?? 1

            let weekdays: [Weekday]?
            let monthDay: Int?

            switch repeatType {
            case .custom:
                weekdays = data["repeatWeekdays"]?
                    .split(separator: ",")
                    .compactMap { Weekday(rawValue: Int($0) ?? 0) }
                monthDay = nil
            case .monthly:
                weekdays = nil
                monthDay = data["repeatMonthDay"].flatMap { Int($0) }
            default:
                weekdays = nil
                monthDay = nil
            }

            _ = try todoRepo.createRepeatRule(
                type: repeatType,
                for: task,
                weekdays: weekdays,
                interval: interval,
                monthDay: monthDay
            )
            logger.info("重复规则已创建：\(repeatType.rawValue) interval=\(interval)")
        }

        logger.info("任务已创建：\(title)")

        return RouteResult(
            text: AIResponseTextBuilder.taskCreated(title: title, dueDate: dueDate, hasTime: hasTime, subtaskCount: checkItemTitles.count),
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
                if habit.isNumericType {
                    return try handleNumericHabitRecord(habit, result: result)
                }
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
            if habit.isNumericType {
                return try handleNumericHabitRecord(habit, result: result)
            }
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

    private func handleNumericHabitRecord(_ habit: Habit, result: ParsedResult) throws -> RouteResult {
        guard let value = parseHabitValue(from: result.extractedData) else {
            let unitText = habit.unitText.isEmpty ? "" : "（\(habit.unitText)）"
            return RouteResult(text: "请告诉我要记录的数值\(unitText)，比如「\(habit.name) 5\(habit.unitText)」")
        }

        let record = try HabitRepository.shared.addNumericRecord(for: habit, value: value)
        let formattedValue = habit.formatValue(value)
        let unit = habit.unitText
        let verb = habit.isBadHabit ? "已记录" : "已更新"
        return RouteResult(
            text: "\(verb)「\(habit.name)」\(formattedValue)\(unit)",
            habitId: habit.id,
            linkedEntity: LinkedEntity(type: .habit, id: record.habitId)
        )
    }

    private func parseHabitValue(from data: [String: String]?) -> Double? {
        guard let data else { return nil }
        let candidates = [
            data["habitValue"],
            data["value"],
            data["amount"]
        ]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let numeric = raw.filter { $0.isNumber || $0 == "." || $0 == "-" }
            if let value = Double(numeric) {
                return value
            }
        }
        return nil
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

    /// 解析日期字符串，支持标准格式和中文自然语言
    private func parseDate(from string: String?) -> Date? {
        guard let string = string else { return nil }
        return NLDateParser.parse(string)
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

    private func resolvedCategoryDisplayNames(
        for category: Category?,
        type: TransactionType
    ) async throws -> (primary: String?, sub: String?) {
        guard let category else { return (nil, nil) }

        if let parentID = category.parentId {
            let allCategories = try await FinanceRepository.shared.getCategories(by: type)
            if let parent = allCategories.first(where: { $0.id == parentID }) {
                return (parent.name, category.name)
            }
        }

        return (category.name, nil)
    }

    private func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType
    ) async throws -> Category? {
        let categoryRepo = FinanceRepository.shared
        let categories = try await categoryRepo.getCategories(by: type)

        let candidates = CategoryCandidateResolver.orderedCandidates(
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note,
            hour: Calendar.current.component(.hour, from: Date())
        )

        // 1. 用户学习映射最优先，尊重手动纠正过的分类
        for candidate in candidates {
            if let learned = CategoryLearnedMapping.lookup(
                candidate: candidate,
                type: type,
                primaryCategory: primaryCategory ?? ""
            ) ?? CategoryLearnedMapping.lookup(candidate: candidate, type: type) {

                // 仅当用户映射到的二级本身是餐次（早/午/晚/夜宵）时，才按当前时间动态重算餐段；
                // 否则尊重用户明确映射的具体品类（如"奶茶→饮品""星巴克→咖啡"），不做时段覆盖
                if CategoryCandidateResolver.mealSlotSubCategories.contains(learned.sub) {
                    let hour = Calendar.current.component(.hour, from: Date())
                    let mealSub = CategoryCandidateResolver.mealSubCategoryForHour(hour)
                    let parent = categories.first(where: {
                        $0.isTopLevel && $0.name == learned.primary && $0.type == type.rawValue
                    })
                    if let parent = parent,
                       let sub = categories.first(where: { $0.parentId == parent.id && $0.name == mealSub }) {
                        return sub
                    }
                }

                // 非餐次映射（具体品类或其他一级）：走精确匹配，尊重用户映射
                let learnedResult = CategoryMatcherService.shared.matchSingle(
                    primaryCategory: learned.primary,
                    subCategory: learned.sub,
                    type: type,
                    categories: categories
                )
                if let matched = learnedResult.matchedCategory, matched.isSubCategory {
                    return matched
                }
            }
        }

        // 2. AI 明确给出的标准科目，走严格 Core Data 匹配
        if let sub = subCategory, !sub.isEmpty {
            let matchResult = CategoryMatcherService.shared.matchSingle(
                primaryCategory: primaryCategory ?? "",
                subCategory: sub,
                type: type,
                categories: categories
            )
            if matchResult.matchType == .exact || matchResult.matchType == .synonym,
               let matched = matchResult.matchedCategory,
               matched.isSubCategory {
                return matched
            }
        }

        // 3. 本地科目 + catalog 别名
        for candidate in candidates {
            // 直接匹配用户本地已有科目，保护自定义分类
            if let customMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
                candidate,
                primaryCategory: primaryCategory ?? "",
                type: type,
                categories: categories
            ) {
                return customMatched
            }

            // 标准 catalog 负责别名归一，例如"滴滴"→"交通/打车"
            let catalog = await FinanceCategoryCatalogProvider.shared.loadCatalog()
            if let catalogMatch = CategoryMatcherService.shared.matchCandidate(candidate, type: type, catalog: catalog) {
                let catalogResult = CategoryMatcherService.shared.matchSingle(
                    primaryCategory: catalogMatch.primaryCategory,
                    subCategory: catalogMatch.subCategory,
                    type: type,
                    categories: categories
                )
                if let matched = catalogResult.matchedCategory, matched.isSubCategory {
                    return matched
                }
            }
        }

        // 3.5. AI 语义兜底：semanticCategoryHint 匹配到一级分类后推断二级
        if let hint = semanticCategoryHint?.trimmingCharacters(in: .whitespaces),
           !hint.isEmpty {
            let hintLower = hint.lowercased()
            if let parent = categories.first(where: {
                $0.isTopLevel && $0.type == type.rawValue && $0.name.lowercased() == hintLower
            }) {
                if CategoryCandidateResolver.timeSensitivePrimaries.contains(parent.name) {
                    // 餐饮类：按时间选餐段
                    let hour = Calendar.current.component(.hour, from: Date())
                    let mealSub = CategoryCandidateResolver.mealSubCategoryForHour(hour)
                    if let sub = categories.first(where: { $0.parentId == parent.id && $0.name == mealSub }) {
                        return sub
                    }
                } else {
                    // 非餐饮类：用 normalizedCategoryCandidate 在该一级分类下找子类
                    if let normalized = normalizedCategoryCandidate?.trimmingCharacters(in: .whitespaces),
                       !normalized.isEmpty {
                        if let sub = categories.first(where: {
                            $0.parentId == parent.id && $0.name.lowercased() == normalized.lowercased()
                        }) {
                            return sub
                        }
                    }
                }
            }
        }

        // 4. 降级：note 只做唯一精确匹配
        if let noteMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
            note,
            primaryCategory: "",
            type: type,
            categories: categories
        ) {
            return noteMatched
        }

        // 5. 原始 candidate 再做一次直接匹配，避免餐饮归一掩盖同名自定义分类
        if let rawCandidate = categoryCandidate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidates.contains(rawCandidate),
           let rawMatched = CategoryMatcherService.shared.matchExistingCategoryByCandidate(
                rawCandidate,
                primaryCategory: primaryCategory ?? "",
                type: type,
                categories: categories
           ) {
            return rawMatched
        }

        // 无法可靠匹配，返回 nil，由调用方使用「待分类」兜底
        return nil
    }

    private func transactionNote(from data: [String: String]) -> String? {
        for key in ["note", "categoryCandidate"] {
            if let value = data[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
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
                text: "AI 服务暂时不可用，请稍后重试。"
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
        } catch let error as MemoryInsightError {
            logger.error("Chat 触发洞察生成失败：\(error.localizedDescription)")
            // 未授权时给出专属引导文案，其余错误沿用通用重试文案（方案 §4.1.3）
            let text: String
            switch error {
            case .aiDataProcessingConsentRequired:
                text = "开启 AI 数据处理授权后可生成本周观察。"
            default:
                text = "生成回放失败：\(error.localizedDescription)。请稍后重试。"
            }
            return RouteResult(text: text)
        } catch {
            logger.error("Chat 触发洞察生成失败：\(error.localizedDescription)")
            return RouteResult(
                text: "生成回放失败：\(error.localizedDescription)。请稍后重试。"
            )
        }
    }

    // MARK: - Installment Expense

    private func handleInstallmentExpense(data: [String: String], amount: Decimal, amountStr: String) async throws -> RouteResult {
        guard let periodsStr = data["installmentPeriods"],
              let periods = Int(periodsStr),
              (2...36).contains(periods) else {
            return RouteResult(text: "分期期数无效，请使用 2-36 期")
        }

        let feePerPeriod = Decimal(string: data["installmentFeePerPeriod"] ?? "0") ?? 0
        let note = data["note"]
        let categoryCandidate = data["categoryCandidate"]

        let categoryRepo = FinanceRepository.shared
        var category = try await matchCategory(
            primaryCategory: data["primaryCategory"],
            subCategory: data["subCategory"],
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: data["normalizedCategoryCandidate"],
            semanticCategoryHint: data["semanticCategoryHint"],
            note: note ?? "",
            type: .expense
        )
        let account = try await categoryRepo.getDefaultAccount()

        guard let account = account else {
            return RouteResult(text: "请先设置默认账户")
        }

        var isUnmatched = false
        if category == nil {
            isUnmatched = true
            category = categoryRepo.ensurePendingCategory(type: .expense)
        }

        guard let category else {
            return RouteResult(text: "分类信息异常，请重试")
        }

        let startDateStr = data["installmentFirstDueDate"] ?? data["transactionDate"] ?? ""
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let startDate = dateFormatter.date(from: startDateStr) ?? Date()

        let transactions = try await categoryRepo.addInstallmentTransactions(
            totalAmount: amount,
            feePerPeriod: feePerPeriod,
            periods: periods,
            type: .expense,
            category: category,
            account: account,
            startDate: startDate,
            note: note
        )

        if isUnmatched, let candidate = categoryCandidate {
            if let firstTx = transactions.first {
                CategoryLearnedMapping.recordTransactionCandidate(
                    transactionId: firstTx.id,
                    candidate: candidate,
                    type: .expense
                )
            }
        }

        let groupId = transactions.first?.installmentGroupId
        logger.info("分期支出已记录：¥\(amount) × \(periods) 期，groupId=\(groupId?.uuidString ?? "nil")")

        let matchedNames = try await resolvedCategoryDisplayNames(
            for: isUnmatched ? nil : transactions.first?.category,
            type: .expense
        )

        return RouteResult(
            text: "已记录分期支出：\(note ?? "分期购物")，总额 ¥\(amountStr)，分 \(periods) 期",
            transactionId: transactions.first?.id,
            linkedEntity: transactions.first.map { LinkedEntity(type: .transaction, id: $0.id) },
            categoryUnmatched: isUnmatched,
            matchedPrimaryCategory: matchedNames.primary,
            matchedSubCategory: matchedNames.sub
        )
    }
}
