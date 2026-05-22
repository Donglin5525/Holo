//
//  AIUserContextMessageBuilder.swift
//  Holo
//
//  统一构建 AI 可读取的用户上下文，供聊天、意图识别等链路复用
//

import Foundation

enum AIUserContextPurpose {
    case chat
    case intentRecognition
}

enum AIUserContextMessageBuilder {

    static func build(from context: UserContext, purpose: AIUserContextPurpose) -> String {
        var message = """
        当前用户上下文：
        - 日期：\(context.todayDate)
        - 今日支出：\(context.transactions.todayExpense)，今日收入：\(context.transactions.todayIncome)
        - 近期交易：\(context.transactions.recentTransactions.joined(separator: "、"))
        - 可用账户：\(context.accounts.accountList)
        - 默认账户：\(context.accounts.defaultAccountName)
        - 活跃习惯：\(context.habits.totalActive) 个，今日完成 \(context.habits.todayCompleted)/\(context.habits.todayTotal)
        - 今日任务：\(context.tasks.todayTotal) 个（已完成 \(context.tasks.todayCompleted)），逾期 \(context.tasks.overdueCount) 个
        - 近期任务：\(context.tasks.recentTasks.joined(separator: "、"))
        - 近期想法：\(context.thoughts.recentThoughts.prefix(3).joined(separator: "、"))
        """

        if purpose == .intentRecognition {
            message += """


            上下文使用规则：
            - 用户档案、目标、近期趋势只能作为消歧和个性化依据，不得覆盖用户当前明确指令。
            - 意图识别只输出用户这一次输入真正表达的动作，不要因为档案中的长期偏好主动添加动作。
            - 档案可帮助理解习惯、目标、分类偏好和称呼，但不能编造金额、日期、任务或分类。
            """
        }

        let habitFocusLines = context.habits.focusSummaries.map(\.aiContextLine) + context.habits.focusTopicLines
        if !habitFocusLines.isEmpty {
            message += "\n\n--- 习惯关注主题 ---"
            message += "\n- " + habitFocusLines.joined(separator: "\n- ")
            message += "\n规则：负向习惯/减少型目标（如戒烟、抽烟、少喝酒、熬夜）发生越多不是越好；优先看发生总量下降、超标天数减少、控制率提升。"
        }

        if let profile = context.profileContext, !profile.isEmpty {
            message += "\n\n--- 用户档案 ---\n\(profile)"
        }

        if let trend = context.recentTrend {
            var trendSection = "\n\n--- 近期趋势 ---"
            trendSection += "\n- 本周支出：\(trend.weekExpenseTotal)"
            if let change = trend.weekExpenseChange {
                trendSection += "（较上周\(change)）"
            }
            if let rate = trend.weekHabitCompletionRate {
                trendSection += "\n- 本周习惯完成率：\(rate)"
            }
            trendSection += "\n- 本周完成任务：\(trend.weekTaskCompletedCount) 个"
            if let category = trend.topExpenseCategory {
                trendSection += "\n- 本周最大支出分类：\(category)"
            }
            if let summary = trend.dailyInsightSummary {
                trendSection += "\n- 今日洞察：\(summary)"
            }
            message += trendSection
        }

        if let goalContext = context.goalContext, !goalContext.isEmpty {
            message += "\n\n" + goalContext
        }

        return message
    }
}
