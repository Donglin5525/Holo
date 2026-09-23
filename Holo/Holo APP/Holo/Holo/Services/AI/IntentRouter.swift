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
        case .setBudget:
            return try await handleSetBudget(result)
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
            return try handleRecordWeight(result, originalInput: originalInput)
        case .checkIn:
            return try handleCheckIn(result, originalInput: originalInput)
        case .updateGoalField:
            return try handleUpdateGoalField(result)
        case .linkTaskToGoal:
            return try handleLinkTaskToGoal(result)
        case .linkHabitToGoal:
            return try handleLinkHabitToGoal(result)
        case .logMetricValue:
            return try handleLogMetricValue(result, originalInput: originalInput)
        case .toggleGoalVisibility:
            return try handleToggleGoalVisibility(result)
        case .createNote:
            return try handleCreateNote(result)
        case .createAnniversary:
            return try await handleCreateAnniversary(result, originalInput: originalInput)
        case .updateAnniversary:
            return try await handleUpdateAnniversary(result, originalInput: originalInput)
        case .queryTasks:
            return try handleQueryTasks(result)
        case .queryHabits:
            return try handleQueryHabits(result)
        case .contextualPlanning:
            // 只读意图：Coordinator 已在写执行前分流到规划器；这里兜底不执行任何写动作
            return RouteResult(text: result.responseText ?? "正在结合你的情况整理方案…")
        case .query, .queryAnalysis, .flexibleDataQuery, .unknown:
            return RouteResult(
                text: result.responseText ?? "我可以帮你记账、创建任务、记录心情等。有什么需要帮忙的吗？"
            )
        case .generateMemoryInsight:
            return await handleGenerateMemoryInsight(result)
        case .weeklyPlanning:
            // 周计划在 ConversationCoordinator 分流到 Agent + 生成服务，不落执行路由
            return RouteResult(text: result.responseText ?? "正在为你规划这一周…")
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

        // 幂等重试（§24.4）：同卡重试命中既有交易直接返回，不重复入账
        if let existing = existingTransactionIfReconfirmed(from: data, repo: categoryRepo) {
            let names = try await resolvedCategoryDisplayNames(for: existing.category, type: .expense)
            return RouteResult(
                text: AIResponseTextBuilder.expenseRecorded(
                    amount: amountStr,
                    note: note,
                    accountName: existing.account?.name ?? "",
                    categoryUnmatched: false,
                    unmatchedCategory: nil
                ),
                transactionId: existing.id,
                linkedEntity: LinkedEntity(type: .transaction, id: existing.id),
                categoryUnmatched: false,
                matchedPrimaryCategory: names.primary,
                matchedSubCategory: names.sub
            )
        }

        var category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note ?? "",
            type: .expense
        )
        let account = try await resolveWriteAccount(from: data, repo: categoryRepo)

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

        // 项目挂靠：模型仅在用户显式提及项目名时回传 projectCandidate（上下文已附进行中清单）
        let projectCandidate = data["projectCandidate"]
        let (matchedProject, projectAmbiguous) = FinanceProjectRepository.matchProjectCandidate(
            projectCandidate,
            in: FinanceProjectRepository.shared.activeProjects()
        )
        if projectCandidate != nil {
            logger.info("项目挂靠匹配：candidate=\(projectCandidate ?? "nil"), matched=\(matchedProject?.name ?? "nil"), ambiguous=\(projectAmbiguous)")
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .expense,
            category: category,
            account: account,
            date: TransactionDateResolver.resolve(from: data),
            note: note,
            financeProject: matchedProject,
            // AI 来源字段与交易同一次 save 落库（§24.4：不再两次保存）；
            // 未注入（文本聊天直记等）时保持 nil，行为不变
            aiSourceMessageId: data["aiSourceMessageId"],
            aiSourceItemId: data["aiSourceItemId"],
            aiCandidate: data["categoryCandidate"] ?? note
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
            ) + projectFollowUpText(matched: matchedProject, ambiguous: projectAmbiguous),
            transactionId: transaction.id,
            linkedEntity: LinkedEntity(type: .transaction, id: transaction.id),
            categoryUnmatched: isUnmatched,
            matchedPrimaryCategory: matchedNames.primary,
            matchedSubCategory: matchedNames.sub
        )
    }

    /// 项目挂靠结果的补充说明（挂上/歧义未挂时才追加，未提及项目时为空串）
    private func projectFollowUpText(matched: FinanceProject?, ambiguous: Bool) -> String {
        if let project = matched {
            return "\n" + String(localized: "已计入项目「\(project.name)」")
        }
        if ambiguous {
            return "\n" + String(localized: "提到的项目名对应多个项目，这笔没有自动挂靠，可在账本里手动挂")
        }
        return ""
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

        // 幂等重试（§24.4）：同卡重试命中既有交易直接返回，不重复入账
        if let existing = existingTransactionIfReconfirmed(from: data, repo: categoryRepo) {
            let names = try await resolvedCategoryDisplayNames(for: existing.category, type: .income)
            return RouteResult(
                text: AIResponseTextBuilder.incomeRecorded(
                    amount: amountStr,
                    note: note,
                    accountName: existing.account?.name ?? "",
                    categoryUnmatched: false,
                    unmatchedCategory: nil
                ),
                transactionId: existing.id,
                linkedEntity: LinkedEntity(type: .transaction, id: existing.id),
                categoryUnmatched: false,
                matchedPrimaryCategory: names.primary,
                matchedSubCategory: names.sub
            )
        }

        var category = try await matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note ?? "",
            type: .income
        )
        let account = try await resolveWriteAccount(from: data, repo: categoryRepo)

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
            note: note,
            // AI 来源字段与交易同一次 save 落库（§24.4）
            aiSourceMessageId: data["aiSourceMessageId"],
            aiSourceItemId: data["aiSourceItemId"],
            aiCandidate: data["categoryCandidate"] ?? note
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

    // MARK: - Set Budget（预算设置/调整：总预算或分类预算，已存在则更新）

    private func handleSetBudget(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我预算金额")
        }
        guard amount > 0 else {
            return RouteResult(text: "预算金额需要大于 0")
        }

        // 预算挂在默认账户（与预算设置页一致）
        guard let account = FinanceRepository.shared.getDefaultAccountSync() else {
            return RouteResult(text: "还没有账户，请先在账本的账户管理里创建一个")
        }
        let period = Self.parseBudgetPeriod(data["period"])
        let periodLabel = period.displayName

        // 分类预算：categoryCandidate 匹配支出分类后按该分类落库；未匹配不硬设（防挂错分类）
        if let candidate = data["categoryCandidate"], !candidate.isEmpty {
            let category = try await matchCategory(
                primaryCategory: data["primaryCategory"],
                subCategory: data["subCategory"],
                categoryCandidate: candidate,
                normalizedCategoryCandidate: data["normalizedCategoryCandidate"],
                semanticCategoryHint: data["semanticCategoryHint"],
                note: "",
                type: .expense
            )
            guard let category else {
                return RouteResult(
                    text: "没找到「\(candidate)」对应的支出分类，可以在账本的分类管理里确认分类名后再试",
                    categoryUnmatched: true
                )
            }
            let repo = BudgetRepository.shared
            if let existing = repo.getCategoryBudget(forAccount: account.id, categoryId: category.id, period: period) {
                try repo.updateBudget(existing, amount: amount, startDate: nil)
                return RouteResult(text: "已把\(periodLabel)「\(category.name)」预算调整为 ¥\(amountStr)")
            }
            _ = try repo.addCategoryBudget(
                accountId: account.id,
                categoryId: category.id,
                amount: amount,
                period: period,
                startDate: Date()
            )
            return RouteResult(text: "已设置\(periodLabel)「\(category.name)」预算 ¥\(amountStr)")
        }

        // 总预算
        let repo = BudgetRepository.shared
        if let existing = repo.getTotalBudget(forAccount: account.id, period: period) {
            try repo.updateBudget(existing, amount: amount, startDate: nil)
            return RouteResult(text: "已把\(periodLabel)总预算调整为 ¥\(amountStr)")
        }
        _ = try repo.addBudget(accountId: account.id, amount: amount, period: period, startDate: Date())
        return RouteResult(text: "已设置\(periodLabel)总预算 ¥\(amountStr)")
    }

    private static func parseBudgetPeriod(_ raw: String?) -> BudgetPeriod {
        switch raw?.lowercased() {
        case "week", "weekly": return .week
        case "year", "yearly", "annual": return .year
        default: return .month
        }
    }

    // MARK: - Create Task

    private func handleCreateTask(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我任务内容")
        }

        let todoRepo = TodoRepository.shared

        // 生效值 = 用户在确认卡上的覆盖 > AI 识别 > 历史默认（TaskPendingDefaults 单一真源，
        // 确认卡编辑弹层的初始值与这里的落库口径一致）
        let (dueDate, hasTime) = TaskPendingDefaults.effectiveDueDate(data: data, originalInput: originalInput)

        let priority = parsePriority(data["priority"])
        let checkItemTitles = TaskPendingDefaults.effectiveSubtasks(data: data)

        // 提醒：用户改过（含显式清空）优先；否则 AI 绝对提醒；有截止时刻默认提前 15 分钟
        let reminders = TaskPendingDefaults.effectiveReminders(data: data, dueDate: dueDate, hasTime: hasTime)

        if originalInput != nil && dueDate != nil && hasTime {
            logger.info("任务时间解析（含兜底）：dueDate=\(dueDate.map { String(describing: $0) } ?? "nil") hasTime=\(hasTime)")
        }

        // 指定清单：用户在确认卡上选过（空 = 收件箱）优先；否则 AI 判断的主题归属（如「日本旅行」）。
        // 匹配已有清单优先，未命中自动创建——不让主题任务散在「全部」
        var listNote: String?
        var targetList: TodoList?
        if data[TaskPendingDefaults.userListNameKey] != nil {
            if let listName = TaskPendingDefaults.effectiveListName(data: data),
               let outcome = try todoRepo.matchOrCreateList(named: listName) {
                targetList = outcome.list
                listNote = outcome.created
                    ? "，已创建清单「\(outcome.list.name)」并放入"
                    : "，已放入清单「\(outcome.list.name)」"
            }
        } else if let listName = data["listName"]?.trimmingCharacters(in: .whitespacesAndNewlines), !listName.isEmpty {
            if let outcome = try todoRepo.matchOrCreateList(named: listName) {
                targetList = outcome.list
                listNote = outcome.created
                    ? "，已创建清单「\(outcome.list.name)」并放入"
                    : "，已放入清单「\(outcome.list.name)」"
            }
        }

        let task = try todoRepo.createTask(
            title: title,
            list: targetList,
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
            text: AIResponseTextBuilder.taskCreated(title: title, dueDate: dueDate, hasTime: hasTime, subtaskCount: checkItemTitles.count) + (listNote ?? ""),
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

    private func handleRecordWeight(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
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
            let note = Self.habitRecordNote(
                originalInput: originalInput,
                habitNames: [habit.name, "体重"],
                removableTokens: [weightStr, "\(weight)kg", "\(weight) kg", "kg", "公斤"]
            )
            try habitRepo.addNumericRecord(for: habit, value: weight, note: note)
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

    private func handleCheckIn(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
        let habitName = result.extractedData?["habitName"]
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }

        if let name = habitName {
            if let habit = habits.first(where: { $0.name.contains(name) || name.contains($0.name) }) {
                if habit.isNumericType {
                    return try handleNumericHabitRecord(habit, result: result, originalInput: originalInput)
                }
                let note = Self.habitRecordNote(originalInput: originalInput, habitNames: [habit.name], removableTokens: [])
                let completed = try habitRepo.toggleCheckIn(for: habit, note: note)
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
                return try handleNumericHabitRecord(habit, result: result, originalInput: originalInput)
            }
            let note = Self.habitRecordNote(originalInput: originalInput, habitNames: [habit.name], removableTokens: [])
            let completed = try habitRepo.toggleCheckIn(for: habit, note: note)
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

    /// 从用户原话提取记录备注：去掉习惯名、数值和纯指令词后，剩余的上下文才有记录价值
    /// （「打卡跑步」清洗后为空不存；「跑步5公里状态不错」存「状态不错」）
    private static func habitRecordNote(
        originalInput: String?,
        habitNames: [String],
        removableTokens: [String]
    ) -> String? {
        guard var text = originalInput?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        for token in (habitNames + removableTokens) where !token.isEmpty {
            text = text.replacingOccurrences(of: token, with: " ")
        }
        for filler in ["帮我记一下", "帮我记录", "帮我", "记一下", "记录一下", "打卡了", "打卡", "记录"] {
            text = text.replacingOccurrences(of: filler, with: " ")
        }
        let remaining = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ，。,.、！!？?"))
        guard remaining.count > 2 else { return nil }
        return String(remaining.prefix(60))
    }

    // MARK: - Goal 写操作

    /// 匹配目标：goalId 精确 > goalTitle 模糊 > 唯一活跃目标。多候选返回 nil（由上层转 pending 卡片）。
    private func matchGoal(from data: [String: String]?) -> GoalMatchResult {
        let repo = GoalRepository.shared
        let activeGoals = repo.activeGoals()

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

    /// 目标歧义预判（Coordinator 生成 goalChoice 选择卡用）：
    /// 命中多个活跃目标时返回候选；单命中/无目标返回 nil，走正常路由。
    func ambiguousGoalCandidates(from data: [String: String]?) -> [Goal]? {
        guard case .ambiguous(let goals) = matchGoal(from: data) else { return nil }
        return goals
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

            // 状态变更（达成/暂停）：语义与文案都独立于普通字段修改
            if field.lowercased() == "status" || field == "状态" {
                guard let status = Self.parseGoalStatus(value) else {
                    return RouteResult(text: "没听懂要改成什么状态，可以说「目标达成了」或「暂停这个目标」")
                }
                try GoalRepository.shared.updateStatus(goal, status: status)
                return RouteResult(
                    text: status == .completed
                        ? "太棒了！目标「\(goal.title)」已标记为达成 🎉"
                        : "已暂停目标「\(goal.title)」，随时可以说「继续」重新开始",
                    linkedEntity: LinkedEntity(type: .goal, id: goal.id)
                )
            }

            try applyGoalFieldUpdate(goal, field: field, value: value)
            return RouteResult(
                text: "已更新「\(goal.title)」",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        }
    }

    /// 目标状态值解析：LLM 输出 completed/paused，同时兜底中文表达
    private static func parseGoalStatus(_ raw: String?) -> GoalStatus? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done", "达成", "完成", "达成目标": return .completed
        case "paused", "pause", "暂停", "放弃", "搁置": return .paused
        default: return nil
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

    private func handleLinkHabitToGoal(_ result: ParsedResult) throws -> RouteResult {
        let data = result.extractedData
        let habitRepo = HabitRepository.shared
        let activeHabits = habitRepo.activeHabits.filter { !$0.isArchived }

        // 匹配习惯：先精确等值，再双向包含
        var matchedHabit: Habit?
        if let habitName = data?["habitName"], !habitName.isEmpty {
            matchedHabit = activeHabits.first { $0.name == habitName }
                ?? activeHabits.first { $0.name.contains(habitName) || habitName.contains($0.name) }
        }
        guard let habit = matchedHabit else {
            return RouteResult(text: "没找到对应的习惯，请告诉我具体是哪个习惯。")
        }

        switch matchGoal(from: data) {
        case .none:
            return RouteResult(text: "你还没有正在进行的活跃目标。")
        case .ambiguous(let goals):
            return goalDisambiguationResult(goals, action: "关联习惯")
        case .single(let goal):
            try GoalRepository.shared.linkHabit(habit, to: goal)
            return RouteResult(
                text: "已把「\(habit.name)」关联到目标「\(goal.title)」",
                habitId: habit.id,
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

    // MARK: - Log Metric Value（量化目标/数值习惯记一笔，handleRecordWeight 的通用化）

    private func handleLogMetricValue(_ result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
        guard let value = parseHabitValue(from: result.extractedData) else {
            return RouteResult(text: "请告诉我要记录的数值，比如「今天跑了 5 公里」「体重 72.4」")
        }
        let targetHint = result.extractedData?["targetHint"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. 指名了量化目标：goalId 精确（goalChoice 重放注入）→ targetHint 模糊
        switch matchGoalStrict(from: result.extractedData) {
        case .single(let goal) where goal.isQuantitative:
            return try recordMetricToGoal(goal, value: value, originalInput: originalInput)
        case .ambiguous(let goals):
            return goalDisambiguationResult(goals, action: "记录数值到")
        case .single(let goal):
            // 命中过程型目标：数值对它无意义，转而按习惯名匹配（目标与习惯同名的场景兜底）
            if let habit = matchNumericHabit(named: targetHint) {
                return try recordMetricToHabit(habit, value: value, originalInput: originalInput)
            }
            return RouteResult(
                text: "「\(goal.title)」是过程型目标，不记录数值。要记到某个数值习惯的话，告诉我习惯名。",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        case .none:
            // 2. 没指名目标（或没匹配上）：targetHint 像习惯名 → 匹配数值习惯
            if let habit = matchNumericHabit(named: targetHint) {
                return try recordMetricToHabit(habit, value: value, originalInput: originalInput)
            }
            return RouteResult(text: "没找到对应的量化目标或数值习惯。可以说「跑向300公里 今天跑了5公里」，或先到习惯模块创建数值习惯。")
        }
    }

    /// 命中量化目标后按数据源落库（单一事实来源：habit 源记习惯、manual 源记 GoalMetricLog、ledger 源引导记账）
    private func recordMetricToGoal(_ goal: Goal, value: Double, originalInput: String?) throws -> RouteResult {
        switch goal.metricSourceEnum {
        case .habit:
            guard let habit = GoalMetricEvaluator.sourceHabit(for: goal) else {
                return RouteResult(
                    text: "「\(goal.title)」的数据源习惯已删除或归档，请到目标详情页重新选择数据源。",
                    linkedEntity: LinkedEntity(type: .goal, id: goal.id)
                )
            }
            let habitResult = try recordMetricToHabit(habit, value: value, originalInput: originalInput)
            return RouteResult(
                text: "\(habitResult.text)（已计入目标「\(goal.title)」）",
                habitId: habitResult.habitId,
                linkedEntity: habitResult.linkedEntity
            )
        case .manual:
            let note = Self.habitRecordNote(
                originalInput: originalInput,
                habitNames: [goal.title],
                removableTokens: []
            )
            try GoalRepository.shared.addMetricLog(for: goal, value: value, note: note)
            let unit = goal.metricUnitText.isEmpty ? "" : " \(goal.metricUnitText)"
            return RouteResult(
                text: "已记录「\(goal.title)」\(GoalMetricEvaluator.formatValue(value))\(unit)",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        case .ledger:
            return RouteResult(
                text: "「\(goal.title)」是存钱目标，进度按账本自动计算。记账请直接记一笔账，比如「发工资了 8000」。",
                linkedEntity: LinkedEntity(type: .goal, id: goal.id)
            )
        }
    }

    /// 记到数值习惯（与详情页「数据来自」同源，进度自动跟随）
    private func recordMetricToHabit(_ habit: Habit, value: Double, originalInput: String?) throws -> RouteResult {
        let note = Self.habitRecordNote(
            originalInput: originalInput,
            habitNames: [habit.name],
            removableTokens: [String(value), "\(value)\(habit.unitText)", habit.unitText].filter { !$0.isEmpty }
        )
        let record = try HabitRepository.shared.addNumericRecord(for: habit, value: value, note: note)
        return RouteResult(
            text: "已记录「\(habit.name)」\(habit.formatValue(value))\(habit.unitText)",
            habitId: habit.id,
            linkedEntity: LinkedEntity(type: .habit, id: record.habitId)
        )
    }

    /// 按名称匹配活跃数值习惯（先精确等值再双向包含；打卡型习惯不参与）
    private func matchNumericHabit(named name: String?) -> Habit? {
        guard let name, !name.isEmpty else { return nil }
        let numericHabits = HabitRepository.shared.activeHabits.filter { !$0.isArchived && $0.isNumericType }
        return numericHabits.first { $0.name == name }
            ?? numericHabits.first { $0.name.contains(name) || name.contains($0.name) }
    }

    /// 严格目标匹配（log_metric_value 专用）：goalId 精确 / targetHint 模糊，
    /// 不做「唯一活跃目标」兜底——用户没指名目标时优先按习惯名匹配
    private func matchGoalStrict(from data: [String: String]?) -> GoalMatchResult {
        let repo = GoalRepository.shared
        let activeGoals = repo.activeGoals()

        if let idStr = data?["goalId"], let uuid = UUID(uuidString: idStr),
           let goal = repo.findGoal(by: uuid) {
            return .single(goal)
        }
        guard let title = data?["targetHint"], !title.isEmpty else { return .none }
        let exact = activeGoals.filter { $0.title == title }
        if exact.count == 1 { return .single(exact[0]) }
        let contains = activeGoals.filter { $0.title.contains(title) || title.contains($0.title) }
        if contains.count == 1 { return .single(contains[0]) }
        if contains.count > 1 { return .ambiguous(contains) }
        return .none
    }

    /// log_metric_value 的目标歧义预判（Coordinator 发 goalChoice 卡用）：
    /// 用户指名了目标（goalId/targetHint）且命中多个才弹选择卡，否则走习惯名匹配
    func ambiguousGoalCandidatesForMetricLog(from data: [String: String]?) -> [Goal]? {
        guard case .ambiguous(let goals) = matchGoalStrict(from: data) else { return nil }
        return goals
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

    private func handleNumericHabitRecord(_ habit: Habit, result: ParsedResult, originalInput: String? = nil) throws -> RouteResult {
        guard let value = parseHabitValue(from: result.extractedData) else {
            let unitText = habit.unitText.isEmpty ? "" : "（\(habit.unitText)）"
            return RouteResult(text: "请告诉我要记录的数值\(unitText)，比如「\(habit.name) 5\(habit.unitText)」")
        }

        let note = Self.habitRecordNote(
            originalInput: originalInput,
            habitNames: [habit.name],
            removableTokens: [String(value), "\(value)\(habit.unitText)", habit.unitText].filter { !$0.isEmpty }
        )
        let record = try HabitRepository.shared.addNumericRecord(for: habit, value: value, note: note)
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

        // 时间解析复用 create_task 同款解析（含原文兜底），
        // 解决「明晚」「今晚10点」等相对时间 LLM 漏填时间时的解析问题。
        // 用户没提到时间时 dueDateText 为 nil，返回 (nil, false)，不会误改原时间。
        let (dueDate, hasTime) = TaskPendingDefaults.resolveDueDate(
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
            // 用户没提到时间时 map 产 nil = 不修改原截止时间
            dueDate: dueDate.map { TodoRepository.TaskDueDateUpdate.set($0) },
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

        // 唯一匹配已被 Coordinator 拦截成「删除确认卡」；走到这里的只剩无匹配/多匹配场景
        let matches = searchTasks(keyword: keyword)

        if matches.isEmpty {
            return RouteResult(text: "未找到匹配「\(keyword)」的任务，请说得更具体一些")
        }
        let list = matches.prefix(5).enumerated().map { (i, task) in
            "\(i + 1)）\(task.title)"
        }.joined(separator: "\n")
        return RouteResult(text: "找到多个匹配的任务：\n\(list)\n请说得更具体一些")
    }

    /// 删除预检：关键词唯一命中未完成任务时返回它（Coordinator 据此生成删除确认卡）
    func matchUniqueTaskForDeletion(keyword: String) -> TodoTask? {
        let matches = searchTasks(keyword: keyword)
        guard matches.count == 1 else { return nil }
        return matches.first
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

    // MARK: - Anniversary 写操作（对话创建/修改纪念日）

    private func handleCreateAnniversary(_ result: ParsedResult, originalInput: String? = nil) async throws -> RouteResult {
        guard let data = result.extractedData,
              let title = data["anniversaryTitle"], !title.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我纪念日名称")
        }

        let dateText = data["anniversaryDate"]
        let date = parseDate(from: dateText)
            ?? dateText.flatMap { parseFlexibleDate($0) }
            ?? parseDate(from: originalInput)
            ?? (originalInput.flatMap { parseFlexibleDate($0) })
        guard let date else {
            return RouteResult(text: "请告诉我具体日期，比如「10月3号是爸妈结婚纪念日」")
        }

        let type = AnniversaryType(rawValue: data["typeCandidate"] ?? "") ?? .anniversary
        let repeatYearly: Bool
        if let repeatStr = data["repeatYearly"], !repeatStr.isEmpty {
            repeatYearly = repeatStr.lowercased() == "true"
        } else {
            repeatYearly = type.defaultRepeatYearly
        }

        let item = try await AnniversaryRepository.shared.addAnniversary(
            title: title,
            date: date,
            type: type,
            repeatYearly: repeatYearly
        )

        return RouteResult(
            text: "已创建\(type.displayName)「\(title)」（\(Self.anniversaryDisplayDate(date))）",
            linkedEntity: LinkedEntity(type: .anniversary, id: item.id)
        )
    }

    private func handleUpdateAnniversary(_ result: ParsedResult, originalInput: String? = nil) async throws -> RouteResult {
        guard let data = result.extractedData,
              let keyword = data["anniversaryKeyword"], !keyword.isEmpty else {
            return RouteResult(text: result.responseText ?? "请告诉我要修改哪个纪念日")
        }

        // 唯一匹配才执行（同 update_task 模式）：精确 > 包含；无命中/多命中走文本追问
        let repo = AnniversaryRepository.shared
        let candidates = repo.activeAnniversaries
        let matched: Anniversary?
        if let exact = candidates.first(where: { $0.title == keyword }) {
            matched = exact
        } else {
            let fuzzy = candidates.filter { $0.title.contains(keyword) || keyword.contains($0.title) }
            matched = fuzzy.count == 1 ? fuzzy[0] : nil
        }
        guard let item = matched else {
            if candidates.isEmpty {
                return RouteResult(text: "你还没有纪念日记录")
            }
            return RouteResult(text: "没找到唯一对应的纪念日，请说得更具体一些（比如用完整名称）")
        }

        let newTitle = data["anniversaryTitle"]
        let dateText = data["anniversaryDate"]
        let newDate = parseDate(from: dateText) ?? dateText.flatMap { parseFlexibleDate($0) }
        guard newTitle != nil || newDate != nil else {
            return RouteResult(text: "请说明要改成什么（新日期或新名称）")
        }

        try await repo.updateAnniversary(item, title: newTitle, date: newDate)

        var text = "已更新\(item.anniversaryType.displayName)「\(newTitle ?? item.title)」"
        if let newDate {
            text += "，日期改为 \(Self.anniversaryDisplayDate(newDate))"
        }
        return RouteResult(text: text, linkedEntity: LinkedEntity(type: .anniversary, id: item.id))
    }

    /// 纪念日日期展示（同年省年份）
    private static func anniversaryDisplayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current
        formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
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

    /// 分类解析整体搬迁至 FinanceTransactionDraftResolver（2026-09-14 完整方案 §27.2：
    /// 抽出而非复制，文本聊天与图片识别共用同一条分类链）。这里保持委托，调用点不变。
    private func matchCategory(
        primaryCategory: String?,
        subCategory: String?,
        categoryCandidate: String?,
        normalizedCategoryCandidate: String?,
        semanticCategoryHint: String?,
        note: String,
        type: TransactionType
    ) async throws -> Category? {
        try await FinanceTransactionDraftResolver.shared.matchCategory(
            primaryCategory: primaryCategory,
            subCategory: subCategory,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            note: note,
            type: type
        )
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

    // MARK: - AI 落账写入辅助（2026-09-14 完整方案 §24.4/§27.2）

    /// 账户解析：截图识别确认流注入 visionAccountId（识别出的支付通道匹配账户）时
    /// 一次 save 直接落到目标账户，不再「先落默认、确认后再搬运」；
    /// 账户已归档/删除或未注入时走默认账户（既有口径）。
    private func resolveWriteAccount(from data: [String: String], repo: FinanceRepository) async throws -> Account? {
        if let idString = data["visionAccountId"],
           let id = UUID(uuidString: idString),
           let account = repo.findAccount(by: id),
           !account.isArchived, account.deletedAt == nil {
            return account
        }
        return try await repo.getDefaultAccount()
    }

    /// 幂等重试：失败卡重试/对账回 pending 后再确认时，按来源键返回既有交易，不重复入账（§24.4）
    private func existingTransactionIfReconfirmed(from data: [String: String], repo: FinanceRepository) -> Transaction? {
        guard let srcMsg = data["aiSourceMessageId"], let srcItem = data["aiSourceItemId"] else { return nil }
        return repo.findTransactionByAISource(messageId: srcMsg, itemId: srcItem)
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
        } catch let error as HoloQuotaError {
            // 额度耗尽：文案已含周期与升级指引，不接「请稍后重试」——
            // 重置前重试必失败，误导用户反复尝试。
            logger.info("Chat 触发洞察生成因额度终止：\(error.diagnosticDescription)")
            return RouteResult(text: error.userMessage)
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
        let account = try await resolveWriteAccount(from: data, repo: categoryRepo)

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

// MARK: - 待确认任务生效值（确认卡编辑与执行路由的单一真源）

/// 确认卡（TaskChatCard）编辑弹层的初始值、卡片行的当前显示、执行路由（handleCreateTask）
/// 的最终落库三处共用同一套「生效值」计算，保证口径一致。
/// 用户在确认卡上的编辑通过 renderData 的 userX 专用键传递，优先级高于 AI 识别值。
nonisolated enum TaskPendingDefaults {

    // MARK: renderData 用户覆盖键

    /// 用户改过截止时间："yyyy-MM-dd HH:mm"（带时刻）或 "yyyy-MM-dd"（全天）
    static let userDueDateKey = "userDueDate"
    /// 用户改过提醒：[TaskReminder] JSON 编码；空数组 = 显式清空（不再回落默认 15 分钟）
    static let userRemindersKey = "userReminders"
    /// 用户选过清单：清单名；空串 = 收件箱（显式不归清单，AI 的 listName 同时失效）
    static let userListNameKey = "userListName"
    /// 用户改过子条目：换行分隔（单项合法；AI 通道 subtasks 沿用「≥2 项才算清单」约定）
    static let userSubtasksKey = "userSubtasks"

    // MARK: 编解码

    static func encodeReminders(_ reminders: [TaskReminder]) -> String? {
        guard let data = try? JSONEncoder().encode(reminders) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeReminders(_ raw: String?) -> [TaskReminder]? {
        guard let raw, let data = raw.data(using: .utf8),
              let reminders = try? JSONDecoder().decode([TaskReminder].self, from: data) else {
            return nil
        }
        return reminders
    }

    static func parseUserDueDate(_ raw: String?) -> (date: Date, hasTime: Bool)? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = DateFormatter.holoUserDueDateTime.date(from: raw) { return (date, true) }
        if let date = DateFormatter.holoUserDueDateDay.date(from: raw) { return (date, false) }
        return nil
    }

    static func formatUserDueDate(_ date: Date, hasTime: Bool) -> String {
        (hasTime ? DateFormatter.holoUserDueDateTime : DateFormatter.holoUserDueDateDay).string(from: date)
    }

    // MARK: 生效值计算

    /// 截止时间生效值：用户覆盖 > AI 值（含原话兜底合并，历史行为不变）
    static func effectiveDueDate(data: [String: String], originalInput: String?) -> (dueDate: Date?, hasTime: Bool) {
        if let user = parseUserDueDate(data[userDueDateKey]) {
            return (user.date, user.hasTime)
        }
        return resolveDueDate(dueDateText: data["dueDate"] ?? data["reminderDate"], originalInput: originalInput)
    }

    /// AI 通道的截止时间解析：LLM 值直接采用；缺时间时用原话兜底合并
    static func resolveDueDate(dueDateText: String?, originalInput: String?) -> (dueDate: Date?, hasTime: Bool) {
        let llmDate = dueDateText.flatMap { NLDateParser.parse($0) }
        let llmHasTime = dueDateText.map { NLDateParser.containsTimeComponent($0) } ?? false

        if let date = llmDate, llmHasTime {
            return (date, true)
        }

        guard let original = originalInput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty,
              let originalDate = NLDateParser.parse(original) else {
            return (llmDate, llmHasTime)
        }

        let originalHasTime = NLDateParser.containsTimeComponent(original)
        if llmDate != nil && !llmHasTime {
            if originalHasTime {
                return (mergeDate(llmDate!, withTimeFrom: originalDate), true)
            }
            return (llmDate, false)
        }
        return (originalDate, originalHasTime)
    }

    /// 将 date 的时间部分替换为 source 的时分
    static func mergeDate(_ date: Date, withTimeFrom source: Date) -> Date {
        let calendar = Calendar.current
        var merged = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComps = calendar.dateComponents([.hour, .minute], from: source)
        merged.hour = timeComps.hour
        merged.minute = timeComps.minute
        return calendar.date(from: merged) ?? date
    }

    /// 提醒生效值：用户改过（空 = 显式清空）> AI 绝对提醒 > 有截止时刻默认提前 15 分钟 > 无
    static func effectiveReminders(data: [String: String], dueDate: Date?, hasTime: Bool) -> Set<TaskReminder>? {
        if data[userRemindersKey] != nil {
            let edited = decodeReminders(data[userRemindersKey]) ?? []
            return edited.isEmpty ? nil : Set(edited)
        }
        let aiReminders = ReminderSlotParser.parse(from: data)
            .compactMap { NLDateParser.parse($0) }
            .map { TaskReminder(triggerDate: $0) }
        if !aiReminders.isEmpty {
            return Set(aiReminders)
        }
        return (hasTime && dueDate != nil) ? [TaskReminder(offsetMinutes: 15)] : nil
    }

    /// 子条目生效值：用户编辑保留单项；AI 通道沿用「≥2 项才算清单」
    static func effectiveSubtasks(data: [String: String]) -> [String] {
        if let raw = data[userSubtasksKey] {
            return raw.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return SubtaskParser.parse(data["subtasks"])
    }

    /// 清单名生效值：用户选择（空串哨兵归一为 nil = 收件箱）> AI listName；nil = 未指定归默认
    static func effectiveListName(data: [String: String]) -> String? {
        if let user = data[userListNameKey] {
            let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let ai = data["listName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ai.isEmpty ? nil : ai
    }

    /// 卡片显示用：截止时间中文摘要（NLDateParser 与用户覆盖的 ISO 格式都认；解析不了的原文透传）
    static func displayDueDate(_ raw: String?, originalInput: String? = nil) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = NLDateParser.parse(raw) ?? parseUserDueDate(raw)?.date {
            let hasTime = NLDateParser.containsTimeComponent(raw) || parseUserDueDate(raw)?.hasTime == true
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.setLocalizedDateFormatFromTemplate(hasTime ? "MMMdHHmm" : "MMMd")
            return formatter.string(from: date)
        }
        return raw
    }

    /// 绝对提醒（全天/无截止时刻场景）的默认触发时刻：
    /// 锚定任务日 09:00——「明天的任务」配「现在+1h」的提醒会响在任务日之前，属无效提醒；
    /// 当日 9 点已过给最近整点；任务无日期才退回 now+1h。
    /// 纯函数注入 now，单测锁定，杜绝别处再写「取现在」。
    static func defaultAbsoluteTrigger(
        anchorDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        guard let anchorDate else { return now.addingTimeInterval(3600) }
        let day = calendar.dateComponents([.year, .month, .day], from: anchorDate)
        if let nine = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 9
        )), nine > now {
            return nine
        }
        let nextHour = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: nextHour)) ?? nextHour
    }
}

extension DateFormatter {
    /// 用户覆盖截止时间的固定格式（en_US_POSIX 保证不随设备区域变）
    static let holoUserDueDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let holoUserDueDateDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
