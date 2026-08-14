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
    /// - Parameters:
    ///   - result: AI 解析结果
    ///   - originalInput: 用户的原始输入文本（用于在 LLM 漏填日期/时间时，用 NLDateParser 兜底解析）
    /// - Returns: 路由结果（含文本和关联实体 ID）
    func route(_ result: ParsedResult, originalInput: String? = nil) async throws -> RouteResult {
        logger.info("路由意图：\(result.intent.rawValue)，置信度：\(result.confidence)")

        // 确保 FinanceRepository 已初始化（首次使用时 seed 默认分类/账户）
        FinanceRepository.shared.setup()

        switch result.intent {
        case .recordExpense:
            return try await handleRecordExpense(result)
        case .recordIncome:
            return try await handleRecordIncome(result)
        case .createTask:
            return try handleCreateTask(result, originalInput: originalInput)
        case .completeTask:
            return try handleCompleteTask(result)
        case .updateTask:
            return try handleUpdateTask(result, originalInput: originalInput)
        case .modifyTaskItems:
            return try handleModifyTaskItems(result)
        case .deleteTask:
            return try handleDeleteTask(result)
        case .recordMood:
            return try handleRecordMood(result)
        case .recordWeight:
            return try handleRecordWeight(result)
        case .checkIn:
            return try handleCheckIn(result)
        case .updateGoalField:
            return try handleUpdateGoalField(result)
        case .linkTaskToGoal:
            return try handleLinkTaskToGoal(result)
        case .toggleGoalVisibility:
            return try handleToggleGoalVisibility(result)
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

    private func handleCreateTask(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我任务内容")
        }

        let todoRepo = TodoRepository.shared
        let dueDateText = data["dueDate"] ?? data["reminderDate"]

        // 解析 dueDate 与是否含时间。
        // LLM 偶尔会漏填时间（如「晚上10点」只返回日期），这里用原始输入做兜底：
        // - 若 LLM 给了日期但没时间，且原文含时间表达 → 合并 LLM 的日期 + 原文解析的时间
        // - 若 LLM 完全没给日期，且原文能解析出完整日期时间 → 直接采用
        let (dueDate, hasTime) = resolveTaskDueDate(
            dueDateText: dueDateText,
            originalInput: originalInput
        )

        let priority = parsePriority(data["priority"])
        let checkItemTitles = SubtaskParser.parse(data["subtasks"])

        // 有具体时间时，自动添加提前 15 分钟提醒
        let reminders: Set<TaskReminder>? = (hasTime && dueDate != nil)
            ? [TaskReminder(offsetMinutes: 15)]
            : nil

        if originalInput != nil && dueDate != nil && hasTime {
            logger.info("任务时间解析（含兜底）：dueDate=\(dueDate.map { String(describing: $0) } ?? "nil") hasTime=\(hasTime)")
        }

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

    // MARK: - Modify Task Items

    /// 对「最近对话关联的任务」增删条目（addItems 新增 / removeItems 删除）。
    /// taskId 由 ConversationCoordinator 从最近关联任务确定性补全，不走关键词搜索；
    /// removeItems 引用现有条目标题，精确匹配优先、contains 兜底，避免误删。
    private func handleModifyTaskItems(_ result: ParsedResult) throws -> RouteResult {
        guard let data = result.extractedData,
              let taskIdStr = data["taskId"],
              let taskId = UUID(uuidString: taskIdStr) else {
            return RouteResult(text: "未找到要修改的任务，请说明要改哪个任务的条目")
        }

        let todoRepo = TodoRepository.shared
        guard let task = todoRepo.findTask(by: taskId), !task.deletedFlag else {
            return RouteResult(text: "该任务已不存在，请说明要改哪个任务")
        }

        let addItems = SubtaskParser.parse(data["addItems"], allowsSingle: true)
        let removeItems = SubtaskParser.parse(data["removeItems"], allowsSingle: true)

        guard !addItems.isEmpty || !removeItems.isEmpty else {
            return RouteResult(text: "请说明要新增或删除哪些条目")
        }

        // 删除：精确名优先；模糊兜底仅当唯一命中才执行——
        // 多个命中无法确定删哪个，宁可记为未匹配（可提示用户），不冒误删风险
        var unmatchedRemoves: [String] = []
        for removeTitle in removeItems {
            let current = (task.checkItems as? Set<CheckItem>) ?? []
            if let exact = current.first(where: { $0.title == removeTitle }) {
                try todoRepo.deleteCheckItem(exact)
                continue
            }
            let fuzzyMatches = current.filter {
                $0.title.contains(removeTitle) || removeTitle.contains($0.title)
            }
            if fuzzyMatches.count == 1, let target = fuzzyMatches.first {
                try todoRepo.deleteCheckItem(target)
            } else {
                unmatchedRemoves.append(removeTitle)
            }
        }

        // 新增：order 接续当前最大值
        for title in addItems {
            let current = (task.checkItems as? Set<CheckItem>) ?? []
            let maxOrder = current.map(\.order).max() ?? Int16(-1)
            try todoRepo.addCheckItem(title: title, to: task, order: maxOrder + 1)
        }

        var parts: [String] = []
        if !addItems.isEmpty {
            parts.append("新增 \(addItems.count) 项：\(addItems.joined(separator: "、"))")
        }
        let removedNames = removeItems.filter { !unmatchedRemoves.contains($0) }
        if !removedNames.isEmpty {
            parts.append("删除 \(removedNames.count) 项：\(removedNames.joined(separator: "、"))")
        }
        var text = "已更新「\(task.title)」：" + parts.joined(separator: "，")
        if !unmatchedRemoves.isEmpty {
            text += "；未找到：\(unmatchedRemoves.joined(separator: "、"))"
        }

        logger.info("任务条目已修改：\(task.title) 新增\(addItems.count) 删除\(removedNames.count) 未匹配\(unmatchedRemoves.count)")
        return RouteResult(
            text: text,
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

    // MARK: - Goal 写操作

    /// 匹配目标：goalId 精确 > goalTitle 模糊 > 唯一活跃目标。多候选返回 nil（由上层转 pending 卡片）。
    private func matchGoal(from data: [String: String]?) -> GoalMatchResult {
        let repo = GoalRepository.shared
        let activeGoals = repo.goals.filter { $0.goalStatus == .active }

        // 1. goalId 精确
        if let idStr = data?["goalId"], let uuid = UUID(uuidString: idStr),
           let goal = repo.findGoal(by: uuid) {
            return .single(goal)
        }

        // 2. goalTitle 模糊
        if let title = data?["goalTitle"], !title.isEmpty {
            let exact = activeGoals.filter { $0.title == title }
            if exact.count == 1 { return .single(exact[0]) }
            let contains = activeGoals.filter { $0.title.contains(title) || title.contains($0.title) }
            if contains.count == 1 { return .single(contains[0]) }
            if contains.count > 1 { return .ambiguous(contains) }
        }

        // 3. 只有一个活跃目标，直接用
        if activeGoals.count == 1 { return .single(activeGoals[0]) }

        if activeGoals.isEmpty { return .none }
        return .ambiguous(activeGoals)
    }

    private func handleUpdateGoalField(_ result: ParsedResult) throws -> RouteResult {
        let data = result.extractedData
        switch matchGoal(from: data) {
        case .none:
            return RouteResult(text: "你还没有正在进行的活跃目标。要创建一个吗？")
        case .ambiguous(let goals):
            return goalDisambiguationResult(goals, action: "修改")
        case .single(let goal):
            // 按 field 字段决定改什么
            let field = data?["field"] ?? ""
            let value = data?["value"]
            try applyGoalFieldUpdate(goal, field: field, value: value)
            return RouteResult(
                text: "已更新「\(goal.title)」",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        }
    }

    private func applyGoalFieldUpdate(_ goal: Goal, field: String, value: String?) throws {
        let repo = GoalRepository.shared
        let val = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.lowercased() {
        case "title", "标题":
            try repo.updateFields(goal, title: val ?? goal.title)
        case "summary", "说明":
            try repo.updateFields(goal, summary: val)
        case "deadline", "截止日期", "截止":
            if let val, !val.isEmpty {
                let date = parseDate(from: val) ?? parseFlexibleDate(val)
                try repo.updateFields(goal, deadline: .some(date))
            } else {
                try repo.updateFields(goal, deadline: .some(nil))
            }
        case "desiredoutcome", "期望结果":
            try repo.updateFields(goal, desiredOutcome: val)
        case "motivation", "动机":
            try repo.updateFields(goal, motivation: val)
        default:
            // field 不明确时，把 value 当标题更新（兜底）
            if let val, !val.isEmpty {
                try repo.updateFields(goal, title: val)
            }
        }
    }

    private func handleLinkTaskToGoal(_ result: ParsedResult) throws -> RouteResult {
        let data = result.extractedData
        let taskRepo = TodoRepository.shared
        let activeTasks = taskRepo.activeTasks.filter { !$0.deletedFlag && !$0.archived }

        // 匹配任务
        var matchedTask: TodoTask?
        if let taskTitle = data?["taskTitle"], !taskTitle.isEmpty {
            matchedTask = activeTasks.first { $0.title == taskTitle }
                ?? activeTasks.first { $0.title.contains(taskTitle) || taskTitle.contains($0.title) }
        }
        guard let task = matchedTask else {
            return RouteResult(text: "没找到对应的任务，请告诉我具体是哪个任务。")
        }

        switch matchGoal(from: data) {
        case .none:
            return RouteResult(text: "你还没有正在进行的活跃目标。")
        case .ambiguous(let goals):
            return goalDisambiguationResult(goals, action: "关联任务")
        case .single(let goal):
            try GoalRepository.shared.linkTask(task, to: goal)
            return RouteResult(
                text: "已把「\(task.title)」关联到目标「\(goal.title)」",
                taskId: task.id,
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        }
    }

    private func handleToggleGoalVisibility(_ result: ParsedResult) throws -> RouteResult {
        let data = result.extractedData
        switch matchGoal(from: data) {
        case .none:
            return RouteResult(text: "你还没有正在进行的活跃目标。")
        case .ambiguous(let goals):
            return goalDisambiguationResult(goals, action: "调整可见性")
        case .single(let goal):
            let enable = data?["enable"]?.lowercased() == "true"
            try GoalRepository.shared.updateAIContext(goal, allow: enable)
            return RouteResult(
                text: enable ? "已允许 HoloAI 参考「\(goal.title)」" : "已关闭 HoloAI 对「\(goal.title)」的参考",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        }
    }

    /// 多目标歧义：返回候选列表（纯文本反问兜底；完整 pending 卡片由 ConversationCoordinator 处理）
    private func goalDisambiguationResult(_ goals: [Goal], action: String) -> RouteResult {
        let list = goals.prefix(5).enumerated().map { (i, g) in
            "\(i + 1)）\(g.title)"
        }.joined(separator: "\n")
        return RouteResult(text: "要\(action)哪个目标？\n\(list)\n请告诉我具体的目标名称。")
    }

    /// 灵活日期解析（"年底"、"下个月"、"12月31日" 等），返回 nil 表示无法解析
    private func parseFlexibleDate(_ text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let lower = text.lowercased()
        switch lower {
        case "年底":
            return calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 12, day: 31))
        case "年底前":
            return calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 12, day: 31))
        case "下个月底":
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: now)!
            let range = calendar.range(of: .day, in: .month, for: nextMonth)!
            let comps = calendar.dateComponents([.year, .month], from: nextMonth)
            return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: range.count))
        case "下个月", "下月底":
            return calendar.date(byAdding: .month, value: 1, to: now)
        default:
            return parseDate(from: text)
        }
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

    private func handleUpdateTask(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
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

        // 时间解析复用 create_task 同款 resolveTaskDueDate（含原文兜底），
        // 解决「明晚」「今晚10点」等相对时间 LLM 漏填时间时的解析问题。
        // 用户没提到时间时 dueDateText 为 nil，返回 (nil, false)，不会误改原时间。
        let (dueDate, hasTime) = resolveTaskDueDate(
            dueDateText: data["dueDate"] ?? data["reminderDate"],
            originalInput: originalInput
        )

        // 只在用户确实要改时间（dueDate 非空）时同步 isAllDay，避免误标原无截止时间任务。
        let isAllDay: Bool? = dueDate != nil ? !hasTime : nil

        try todoRepo.updateTask(
            task,
            title: newTitle,
            description: newDesc,
            priority: priority,
            dueDate: dueDate,
            isAllDay: isAllDay
        )

        logger.info("任务已更新：\(task.title)")
        return RouteResult(
            text: AIResponseTextBuilder.taskUpdated(
                title: newTitle ?? task.title,
                dueDate: dueDate,
                hasTime: hasTime
            ),
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

    /// 解析任务截止日期与「是否含具体时间」
    /// - 当 LLM 返回的 dueDateText 完整含时间 → 直接采用
    /// - 当 LLM 返回了日期但缺时间，且原始输入含时间表达 → 用 LLM 的日期 + 原文解析的时间合并
    /// - 当 LLM 未返回日期，但原始输入能解析出完整日期时间 → 采用原文解析结果
    /// - 返回 (nil, false) 表示无法确定日期时间（创建为无截止日期任务）
    private func resolveTaskDueDate(
        dueDateText: String?,
        originalInput: String?
    ) -> (dueDate: Date?, hasTime: Bool) {
        let llmDate = parseDate(from: dueDateText)
        let llmHasTime = dueDateText.map { NLDateParser.containsTimeComponent($0) } ?? false

        // LLM 已给出带时间的日期 → 直接采用
        if let date = llmDate, llmHasTime {
            return (date, true)
        }

        // 尝试用原始输入兜底
        guard let original = originalInput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty,
              let originalDate = NLDateParser.parse(original) else {
            // 无原文兜底 → 回退到 LLM 结果（可能只有日期）
            return (llmDate, llmHasTime)
        }

        let originalHasTime = NLDateParser.containsTimeComponent(original)

        if llmDate != nil && !llmHasTime {
            // LLM 给了日期但没时间，原文含时间 → 合并：LLM 的日期 + 原文的时间
            if originalHasTime {
                let merged = mergeDate(llmDate!, withTimeFrom: originalDate)
                return (merged, true)
            }
            // 原文也没时间 → 用 LLM 的纯日期
            return (llmDate, false)
        }

        // LLM 完全没给日期，用原文解析结果（含或不含时间）
        return (originalDate, originalHasTime)
    }

    /// 将 date 的时间部分替换为 source 的时分
    private func mergeDate(_ date: Date, withTimeFrom source: Date) -> Date {
        let calendar = Calendar.current
        let dateComps = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComps = calendar.dateComponents([.hour, .minute], from: source)
        var merged = dateComps
        merged.hour = timeComps.hour
        merged.minute = timeComps.minute
        return calendar.date(from: merged) ?? date
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

        let (start, end): (Date, Date)
        if periodType == .weekly {
            let period = WeeklyObservationPeriod.previousCompletedWeek(containing: Date())
            (start, end) = (period.start, period.end)
        } else {
            (start, end) = MemoryInsightContextBuilder.periodRange(
                periodType: periodType,
                referenceDate: Date()
            )
        }

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
            let periodLabel = periodType == .weekly ? "上周" : "本月"
            return RouteResult(
                text: "已生成\(periodLabel)回放「\(insight.title)」，你可以在记忆长廊中查看完整内容。",
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

// MARK: - Goal 匹配结果

enum GoalMatchResult {
    case single(Goal)
    case ambiguous([Goal])
    case none
}
