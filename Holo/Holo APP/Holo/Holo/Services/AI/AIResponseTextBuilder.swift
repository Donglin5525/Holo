//
//  AIResponseTextBuilder.swift
//  Holo
//
//  确认文本生成器
//  用代码模板生成操作确认文本，减轻 LLM prompt 负担
//

import Foundation

/// 用代码生成操作确认文本，替代 LLM 的 responseText
enum AIResponseTextBuilder {

    // MARK: - Finance

    static func expenseRecorded(
        amount: String,
        note: String?,
        accountName: String?,
        categoryUnmatched: Bool = false,
        unmatchedCategory: String? = nil
    ) -> String {
        let notePart = note.map { "（\($0)）" } ?? ""
        let accountPart = accountName.map { " → \($0)" } ?? ""

        if categoryUnmatched {
            return "已记录支出 ¥\(amount)\(notePart)\(accountPart)\n已归入「\(FinancePendingCategory.currentName)」，点击卡片可修改"
        }

        return "已记录支出 ¥\(amount)\(notePart)\(accountPart)"
    }

    static func incomeRecorded(
        amount: String,
        note: String?,
        accountName: String?,
        categoryUnmatched: Bool = false,
        unmatchedCategory: String? = nil
    ) -> String {
        let notePart = note.map { "（\($0)）" } ?? ""
        let accountPart = accountName.map { " → \($0)" } ?? ""

        if categoryUnmatched {
            return "已记录收入 ¥\(amount)\(notePart)\(accountPart)\n已归入「\(FinancePendingCategory.currentName)」，点击卡片可修改"
        }

        return "已记录收入 ¥\(amount)\(notePart)\(accountPart)"
    }

    // MARK: - Task

    static func taskCreated(title: String, dueDate: Date?, hasTime: Bool, subtaskCount: Int = 0) -> String {
        var text = "已创建任务：\(title)"

        if subtaskCount > 0 {
            text += "，包含 \(subtaskCount) 个子任务"
        }

        if hasTime, let date = dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            text += "（\(formatter.string(from: date))，将提前 15 分钟提醒你）"
        } else if let date = dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            text += "（\(formatter.string(from: date))）"
        }

        return text
    }

    static func taskCompleted(title: String) -> String {
        return "已完成任务：\(title)"
    }

    static func taskUpdated(title: String) -> String {
        return "已更新任务：\(title)"
    }

    static func taskDeleted(title: String) -> String {
        return "已删除任务：\(title)"
    }

    // MARK: - Habit

    static func habitCheckedIn(habitName: String) -> String {
        return "已打卡「\(habitName)」"
    }

    // MARK: - Thought / Mood

    static func moodRecorded() -> String {
        return "已记录你的心情"
    }

    static func noteRecorded() -> String {
        return "已保存想法"
    }

    // MARK: - Health

    static func weightRecorded(weight: Double) -> String {
        return "已记录体重：\(weight) kg"
    }

    // MARK: - Query

    static func noResult(for query: String) -> String {
        return "没有找到相关信息"
    }

    // MARK: - Unmatched Category Display

    /// 从提取数据中获取未匹配分类的显示文本
    /// 优先级：subCategory > primaryCategory > categoryCandidate
    static func unmatchedCategoryText(
        subCategory: String?,
        primaryCategory: String?,
        categoryCandidate: String?
    ) -> String {
        subCategory ?? primaryCategory ?? categoryCandidate ?? ""
    }
}
