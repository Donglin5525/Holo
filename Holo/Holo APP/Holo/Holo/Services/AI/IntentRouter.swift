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
    }

    /// 根据解析结果执行对应的本地操作
    /// - Parameter result: AI 解析结果
    /// - Returns: 路由结果（含文本和关联实体 ID）
    func route(_ result: ParsedResult) async throws -> RouteResult {
        logger.info("路由意图：\(result.intent.rawValue)，置信度：\(result.confidence)")

        switch result.intent {
        case .recordExpense:
            return try await handleRecordExpense(result)
        case .recordIncome:
            return try await handleRecordIncome(result)
        case .createTask:
            return RouteResult(text: try handleCreateTask(result), transactionId: nil)
        case .recordMood:
            return RouteResult(text: try handleRecordMood(result), transactionId: nil)
        case .recordWeight:
            return RouteResult(text: try handleRecordWeight(result), transactionId: nil)
        case .checkIn:
            return RouteResult(text: try handleCheckIn(result), transactionId: nil)
        case .query, .chat, .unknown:
            return RouteResult(
                text: result.responseText ?? "我可以帮你记账、创建任务、记录心情等。有什么需要帮忙的吗？",
                transactionId: nil
            )
        }
    }

    // MARK: - Record Expense

    private func handleRecordExpense(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我具体的金额", transactionId: nil)
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
            return RouteResult(text: "请先设置默认分类和账户", transactionId: nil)
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .expense,
            category: category,
            account: account,
            note: note
        )

        logger.info("支出已记录：¥\(amount)")
        return RouteResult(
            text: "已记录支出 ¥\(amountStr)\(note != nil ? "（\(note!)）" : "")",
            transactionId: transaction.id
        )
    }

    // MARK: - Record Income

    private func handleRecordIncome(_ result: ParsedResult) async throws -> RouteResult {
        guard let data = result.extractedData,
              let amountStr = data["amount"],
              let amount = Decimal(string: amountStr) else {
            return RouteResult(text: result.responseText ?? "请告诉我具体的金额", transactionId: nil)
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
            return RouteResult(text: "请先设置默认分类和账户", transactionId: nil)
        }

        let transaction = try await categoryRepo.addTransaction(
            amount: amount,
            type: .income,
            category: category,
            account: account,
            note: note
        )

        logger.info("收入已记录：¥\(amount)")
        return RouteResult(
            text: "已记录收入 ¥\(amountStr)\(note != nil ? "（\(note!)）" : "")",
            transactionId: transaction.id
        )
    }

    // MARK: - Create Task

    private func handleCreateTask(_ result: ParsedResult) throws -> String {
        guard let data = result.extractedData,
              let title = data["title"], !title.isEmpty else {
            return result.responseText ?? "请告诉我任务内容"
        }

        let todoRepo = TodoRepository.shared
        let task = try todoRepo.createTask(title: title)

        logger.info("任务已创建：\(title)")
        return "已创建任务：\(title)"
    }

    // MARK: - Record Mood

    private func handleRecordMood(_ result: ParsedResult) throws -> String {
        let content = result.extractedData?["content"] ?? result.responseText ?? ""
        let mood = result.extractedData?["mood"]

        guard !content.isEmpty else {
            return "请告诉我你现在的感受"
        }

        let thoughtRepo = ThoughtRepository()
        let _ = try thoughtRepo.create(content: content, mood: mood, tags: [])

        logger.info("心情已记录")
        return "已记录你的心情"
    }

    // MARK: - Record Weight

    private func handleRecordWeight(_ result: ParsedResult) throws -> String {
        // 体重记录复用习惯模块的数值记录功能
        guard let data = result.extractedData,
              let weightStr = data["weight"],
              let weight = Double(weightStr) else {
            return "请告诉我体重数值"
        }

        // 查找体重习惯或创建
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }
        let weightHabit = habits.first { $0.unit == "kg" && $0.name.contains("体重") }

        if let habit = weightHabit {
            try habitRepo.addNumericRecord(for: habit, value: weight)
            logger.info("体重已记录：\(weight) kg")
            return "已记录体重：\(weight) kg"
        } else {
            return "未找到体重记录习惯，请先在习惯模块创建"
        }
    }

    // MARK: - Check In

    private func handleCheckIn(_ result: ParsedResult) throws -> String {
        let habitName = result.extractedData?["habitName"]
        let habitRepo = HabitRepository.shared
        let habits = habitRepo.activeHabits.filter { !$0.isArchived }

        if let name = habitName {
            if let habit = habits.first(where: { $0.name.contains(name) || name.contains($0.name) }) {
                let completed = try habitRepo.toggleCheckIn(for: habit)
                return completed ? "\(habit.name) 打卡成功" : "\(habit.name) 已取消打卡"
            }
        }

        // 如果只有一个活跃习惯，直接打卡
        if habits.count == 1 {
            let habit = habits[0]
            let completed = try habitRepo.toggleCheckIn(for: habit)
            return completed ? "\(habit.name) 打卡成功" : "\(habit.name) 已取消打卡"
        }

        // 多个习惯时列出选项
        let names = habits.map { $0.name }.joined(separator: "、")
        return "要给哪个习惯打卡？当前活跃习惯：\(names)"
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
}
