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

            // 意图识别：只注入数据覆盖度做风险提示
            if let coverage = context.dataCoverage, coverage.level != .rich {
                message += "\n\n--- 数据覆盖度提示 ---"
                message += "\n当前用户数据\(coverage.level == .partial ? "部分可用" : "暂无")：\(coverage.reason)"
                message += "\n处理意图时请注意数据完整性，缺失字段需向用户确认。"
            }
        }

        let habitFocusLines = context.habits.focusSummaries.map(\.aiContextLine) + context.habits.focusTopicLines
        if !habitFocusLines.isEmpty {
            message += "\n\n--- 习惯关注主题 ---"
            message += "\n- " + habitFocusLines.joined(separator: "\n- ")
            message += "\n规则：负向习惯/减少型目标（如戒烟、抽烟、少喝酒、熬夜）发生越多不是越好；优先看发生总量下降、超标天数减少、控制率提升。"
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

            if let memorySummary = context.memorySummary, !memorySummary.lines.isEmpty {
                message += "\n\n--- 记忆摘要 ---"

                if !memorySummary.entries.isEmpty {
                    // 新格式：含 useScopes 标签和误用边界
                    for entry in memorySummary.entries {
                        let scopeTag = entry.useScopeLabels.isEmpty
                            ? ""
                            : "[\(entry.useScopeLabels.joined(separator: ","))] "
                        message += "\n- \(scopeTag)\(entry.title)：\(entry.aiUseSummary)"
                        if !entry.prohibitedInferences.isEmpty {
                            message += "\n  避免推断：\(entry.prohibitedInferences.joined(separator: "；"))。"
                        }
                    }
                } else {
                    // 旧格式 fallback
                    let truncated = Array(memorySummary.lines.prefix(5))
                    message += "\n" + truncated.joined(separator: "\n")
                }

                message += "\n规则：以上记忆只能辅助理解用户，不得覆盖用户当前明确指令。"
            }
        }

        return message
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

