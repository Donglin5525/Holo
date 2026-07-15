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

    static func build(from context: UserContext, purpose: AIUserContextPurpose, userText: String? = nil) -> String {
        if purpose == .intentRecognition {
            return buildIntentRecognitionContext(from: context)
        }

        var message = """
        当前用户上下文：
        - 日期：\(context.todayDate)
        - 今日支出：\(context.transactions.todayExpense)，今日收入：\(context.transactions.todayIncome)
        - 近期交易：\(context.transactions.recentTransactions.joined(separator: "、"))
        - 可用账户：\(context.accounts.accountList)
        - 默认账户：\(context.accounts.defaultAccountName)
        \(formatHabitSummaryLines(context.habits))
        - 今日到期：\(context.tasks.dueToday) 个，今日完成：\(context.tasks.completedToday) 个，逾期 \(context.tasks.overdueCount) 个
        \(formatTaskLines(context.tasks))
        - 近期想法：\(context.thoughts.recentThoughts.prefix(3).joined(separator: "、"))
        """

        let habitFocusLines = context.habits.focusSummaries.map(\.aiContextLine) + context.habits.focusTopicLines
        if !habitFocusLines.isEmpty {
            message += "\n\n--- 习惯关注主题 ---"
            message += "\n- " + habitFocusLines.joined(separator: "\n- ")
            message += "\n规则：负向习惯/减少型目标（如戒烟、抽烟、少喝酒、熬夜）发生越多不是越好；优先看发生总量下降、超标天数减少、控制率提升。"
        }

        if purpose == .chat {
            let decision = HoloExpressionDecisionEngine.decide(for: context, userText: userText)
            message += "\n\n--- 表达强度 ---"
            message += "\n\(decision.promptSummary)"
            message += "\n规则：表达强度只决定说法，不改变事实；当前用户明确输入永远优先。"
        }

        if let profile = context.profileContext, !profile.isEmpty {
            // 优先使用结构化 snapshot + renderer（受 feature flag 控制）
            if let snapshot = context.profileSnapshot,
               HoloAIFeatureFlags.profileSnapshotEnabled {
                let rendered = HoloProfilePromptRenderer.render(snapshot, purpose: purpose == .chat ? .chat : .chat)
                if !rendered.isEmpty {
                    message += "\n\n\(rendered)"
                }
            } else {
                // Feature flag 关闭时回退到 raw markdown
                let fallback = HoloProfilePromptRenderer.renderRawFallback(profile)
                if !fallback.isEmpty {
                    message += "\n\n\(fallback)"
                }
            }
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

        // 聊天场景：注入记忆摘要和数据覆盖度
        if purpose == .chat {
            if let coverage = context.dataCoverage, coverage.level != .rich {
                message += "\n\n--- 数据覆盖度 ---"
                message += "\n\(coverage.reason)"
                if !coverage.missingSources.isEmpty {
                    let missing = coverage.missingSources.map { $0.displayName }.prefix(3)
                    message += "\n缺失来源：\(missing.joined(separator: "、"))"
                }
            }

            if HoloAIFeatureFlags.memorySummaryInjectionEnabled,
               let memorySummary = context.memorySummary {
                let envelope = HoloMemoryContextEnvelope.render(memorySummary)
                if !envelope.isEmpty {
                    message += "\n\n" + envelope
                }
            }
        }

        return message
    }

    // MARK: - Intent Recognition Context

    private static func buildIntentRecognitionContext(from context: UserContext) -> String {
        var message = """
        当前用户上下文：
        - 日期：\(context.todayDate)
        - 今日支出：\(context.transactions.todayExpense)，今日收入：\(context.transactions.todayIncome)
        - 近期交易：\(context.transactions.recentTransactions.joined(separator: "、"))
        - 可用账户：\(context.accounts.accountList)
        - 默认账户：\(context.accounts.defaultAccountName)

        上下文使用规则：
        - 这部分上下文只用于识别本轮输入意图和财务账户消歧，不得主动扩展用户动作。
        - 意图识别只输出用户这一次输入真正表达的动作，不要因为历史状态、长期目标或档案主动添加动作。
        - 不得编造金额、日期、任务、习惯、想法或分类。
        """

        // 意图识别阶段只保留数据覆盖度风险提示，避免任务/想法/目标等无关上下文干扰 Router。
        if let coverage = context.dataCoverage, coverage.level != .rich {
            message += "\n\n--- 数据覆盖度提示 ---"
            message += "\n当前用户数据\(coverage.level == .partial ? "部分可用" : "暂无")：\(coverage.reason)"
            message += "\n处理意图时请注意数据完整性，缺失字段需向用户确认。"
        }

        return message
    }

    // MARK: - Habit Summary Formatting

    /// 格式化习惯摘要：分正负向展示，避免语义混淆
    private static func formatHabitSummaryLines(_ habits: HabitSummary) -> String {
        var lines: [String] = []

        let hasPositive = habits.todayTotal > 0
        let hasNegative = habits.todayNegativeTotal > 0

        if hasPositive || hasNegative {
            var parts: [String] = []
            if hasPositive {
                parts.append("正向：\(habits.todayCompleted)/\(habits.todayTotal) 已打卡")
            }
            if hasNegative {
                parts.append("负向：\(habits.todayNegativeChecked)/\(habits.todayNegativeTotal) 已发生")
            }
            lines.append("- 活跃习惯：\(habits.totalActive) 个（\(parts.joined(separator: "，"))）")
        } else {
            lines.append("- 活跃习惯：\(habits.totalActive) 个")
        }

        // 今日每个习惯的详情
        if !habits.recentCheckIns.isEmpty {
            lines.append("- 今日习惯：\(habits.recentCheckIns.joined(separator: "、"))")
        }

        return lines.joined(separator: "\n        ")
    }

    // MARK: - Task Summary Formatting

    /// 格式化任务摘要：近期任务 + 未完成积压
    private static func formatTaskLines(_ tasks: TaskSummary) -> String {
        var lines: [String] = []

        // 近期到期任务
        if !tasks.recentTasks.isEmpty {
            lines.append("- 近期任务：\(tasks.recentTasks.joined(separator: "、"))")
        }

        // 未完成积压（前 5 条）
        if !tasks.activeTaskSummaries.isEmpty {
            let backlog = tasks.activeTaskSummaries.prefix(5).joined(separator: "、")
            let total = tasks.activeTaskSummaries.count
            let suffix = total > 5 ? "等共 \(total) 个未完成" : "共 \(total) 个未完成"
            lines.append("- 待办积压：\(backlog)（\(suffix)）")
        }

        return lines.joined(separator: "\n        ")
    }
}

// MARK: - Source Display Name

extension HoloMemorySource {
    var displayName: String {
        switch self {
        case .finance: return "消费记录"
        case .tasks: return "任务"
        case .habits: return "习惯"
        case .thoughts: return "想法"
        case .goals: return "目标"
        case .health: return "健康"
        case .profile: return "档案"
        case .conversation: return "对话"
        case .memoryInsight: return "洞察"
        }
    }
}
