//
//  MockAIProvider.swift
//  Holo
//
//  AI Provider Mock 实现
//  开发阶段调试 UI 和 IntentRouter，无需真实 API Key
//

import Foundation
import os.log

#if DEBUG

@MainActor
final class MockAIProvider: AIProvider {

    private let logger = Logger(subsystem: "com.holo.app", category: "MockAIProvider")

    var lastCallLog: LLMCallLog? = nil

    // MARK: - AIProvider

    func parseUserInput(_ input: String, context: UserContext) async throws -> ParsedResult {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 500_000_000)

        let lowercased = input.lowercased()

        // 简单关键词匹配模拟意图识别
        if lowercased.contains("花") || lowercased.contains("买") || lowercased.contains("吃饭") || lowercased.contains("午饭") || lowercased.contains("块") {
            let amount = extractAmount(from: input)
            return ParsedResult(
                intent: .recordExpense,
                confidence: 0.85,
                extractedData: [
                    "amount": amount,
                    "note": input,
                    "type": "expense"
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已记录支出 ¥\(amount)"
            )
        }

        if lowercased.contains("收入") || lowercased.contains("工资") {
            let amount = extractAmount(from: input)
            return ParsedResult(
                intent: .recordIncome,
                confidence: 0.85,
                extractedData: [
                    "amount": amount,
                    "note": input,
                    "type": "income"
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已记录收入 ¥\(amount)"
            )
        }

        if lowercased.contains("任务") || lowercased.contains("待办") || lowercased.contains("提醒我") {
            return ParsedResult(
                intent: .createTask,
                confidence: 0.8,
                extractedData: [
                    "title": input.replacingOccurrences(of: "帮我建个任务", with: "")
                        .replacingOccurrences(of: "提醒我", with: "")
                        .trimmingCharacters(in: .whitespaces)
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已创建任务"
            )
        }

        if lowercased.contains("打卡") || lowercased.contains("完成习惯") {
            return ParsedResult(
                intent: .checkIn,
                confidence: 0.8,
                extractedData: [:],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "已打卡"
            )
        }

        // 新增意图关键词匹配
        if lowercased.contains("完成") || lowercased.contains("做完了") {
            let keyword = input.replacingOccurrences(of: "完成", with: "")
                .replacingOccurrences(of: "了", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .completeTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword.isEmpty ? input : keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "完成任务"
            )
        }

        if lowercased.contains("删除任务") || lowercased.contains("不要了") {
            let keyword = input.replacingOccurrences(of: "删除任务", with: "")
                .replacingOccurrences(of: "不要了", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .deleteTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword.isEmpty ? input : keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "删除任务"
            )
        }

        if lowercased.contains("改成") || lowercased.contains("修改") {
            let keyword = input.replacingOccurrences(of: "把", with: "")
                .replacingOccurrences(of: "改成", with: " ")
                .replacingOccurrences(of: "修改", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return ParsedResult(
                intent: .updateTask,
                confidence: 0.8,
                extractedData: ["taskKeyword": keyword],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "更新任务"
            )
        }

        if lowercased.contains("记一下") || lowercased.contains("笔记") {
            return ParsedResult(
                intent: .createNote,
                confidence: 0.8,
                extractedData: ["noteContent": input],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "记录笔记"
            )
        }

        if lowercased.contains("有什么任务") || lowercased.contains("待办") || lowercased.contains("任务列表") {
            return ParsedResult(
                intent: .queryTasks,
                confidence: 0.85,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "查询任务列表"
            )
        }

        if lowercased.contains("习惯状态") || lowercased.contains("打卡了吗") || lowercased.contains("习惯完成") {
            return ParsedResult(
                intent: .queryHabits,
                confidence: 0.85,
                extractedData: nil,
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "查询习惯状态"
            )
        }

        // 分析查询关键词匹配
        let analysisKeywords = ["分析", "复盘", "综合分析", "趋势", "统计"]
        let financeKeywords = ["账单", "消费", "支出", "收入", "预算", "财务", "花了"]
        let habitAnalysisKeywords = ["习惯打卡", "习惯完成率"]
        let taskAnalysisKeywords = ["任务完成", "待办完成"]
        let thoughtAnalysisKeywords = ["想法", "情绪", "心情分析"]

        if analysisKeywords.contains(where: { lowercased.contains($0) }) {
            let domain: String
            if financeKeywords.contains(where: { lowercased.contains($0) }) {
                domain = "finance"
            } else if habitAnalysisKeywords.contains(where: { lowercased.contains($0) }) {
                domain = "habit"
            } else if taskAnalysisKeywords.contains(where: { lowercased.contains($0) }) {
                domain = "task"
            } else if thoughtAnalysisKeywords.contains(where: { lowercased.contains($0) }) {
                domain = "thought"
            } else {
                domain = "crossModule"
            }

            return ParsedResult(
                intent: .queryAnalysis,
                confidence: 0.9,
                extractedData: [
                    "analysisDomain": domain
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "[Mock] 分析查询"
            )
        }

        // 灵活数据查询关键词匹配
        let flexibleKeywords = ["上一次", "最近一次", "哪一笔", "几次", "距今", "多久没", "最大一笔", "最小一笔", "超过"]
        if flexibleKeywords.contains(where: { lowercased.contains($0) }) {
            return ParsedResult(
                intent: .flexibleDataQuery,
                confidence: 0.9,
                extractedData: [
                    "queryDomain": "finance",
                    "queryGoal": input,
                    "rawConstraints": input
                ],
                needsClarification: false,
                clarificationQuestion: nil,
                responseText: "[Mock] 灵活数据查询"
            )
        }

        // 兜底：未识别意图
        return ParsedResult(
            intent: .unknown,
            confidence: 0.4,
            extractedData: nil,
            needsClarification: true,
            clarificationQuestion: "我可以帮你记账、创建任务、记录心情等，你想做什么？",
            responseText: "[Mock] 未识别指令：\(input)"
        )
    }

    func generateMemoryInsight(type: InsightType, contextJSON: String) async throws -> MemoryInsightGenerationResult {
        try await Task.sleep(nanoseconds: 800_000_000)

        let rawResponse = """
        {
          "title": "你在把生活重新拉回节奏里",
          "summary": "习惯完成回暖，支出保持稳定，观点里反复提到建立仪式感和减少临时补救。",
          "cards": [
            {
              "id": "habit_1",
              "type": "habit",
              "title": "运动习惯在回暖",
              "body": "本周跑步记录连续 5 天，比上周多了 3 天。周末也没有中断。",
              "evidence": [
                {"id": "e1", "label": "跑步完成", "date": "2026-04-23", "sourceType": "habitRecord"},
                {"id": "e2", "label": "跑步完成", "date": "2026-04-24", "sourceType": "habitRecord"}
              ],
              "suggestedQuestion": "哪些习惯最容易中断？"
            },
            {
              "id": "finance_1",
              "type": "finance",
              "title": "支出没有明显失控",
              "body": "本周支出保持稳定，餐饮占比最高。",
              "evidence": [
                {"id": "e3", "label": "本周总支出 ¥420", "date": null, "sourceType": "transaction"}
              ],
              "suggestedQuestion": null
            },
            {
              "id": "anomaly_1",
              "type": "anomaly",
              "title": "周三消费突增",
              "body": "周三支出 ¥380，高于日均 ¥85 的 3 倍以上。",
              "evidence": [
                {"id": "e5", "label": "日均支出 ¥85", "date": null, "sourceType": null},
                {"id": "e6", "label": "周三支出 ¥380", "date": "2026-04-23", "sourceType": "transaction"}
              ],
              "suggestedQuestion": "周三的支出能减少吗？",
              "anomalySeverity": "warning"
            },
            {
              "id": "thought_1",
              "type": "thought",
              "title": "在思考节奏和仪式感",
              "body": "本周观点中多次提到建立仪式感和减少临时补救。",
              "evidence": [
                {"id": "e4", "label": "观点：减少临时补救", "date": "2026-04-22", "sourceType": "thought"}
              ],
              "suggestedQuestion": "怎样把仪式感融入日常？"
            }
          ],
          "suggestedQuestions": [
            "为什么我周三支出比较多？",
            "下周应该优先保持哪个习惯？"
          ]
        }
        """

        return MemoryInsightGenerationResult(
            rawResponse: rawResponse,
            promptType: "memory_insight_generation",
            promptVersion: nil
        )
    }

    func chat(messages: [ChatMessageDTO], userContext: UserContext) async throws -> String {
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let lastMessage = messages.last?.content ?? ""
        return "[Mock] 收到你的消息：\(lastMessage)\n\n这是 Mock AI 的模拟回复。在设置中配置真实的 API Key 后，将接入大语言模型提供智能服务。"
    }

    func chatStreaming(messages: [ChatMessageDTO], userContext: UserContext) -> AsyncThrowingStream<String, Error> {
        chatStreaming(
            messages: messages,
            userContext: userContext,
            systemContextOverride: nil,
            promptType: .systemPrompt
        )
    }

    func chatStreaming(
        messages: [ChatMessageDTO],
        userContext: UserContext,
        systemContextOverride: String?,
        promptType: PromptManager.PromptType
    ) -> AsyncThrowingStream<String, Error> {
        let response: String
        if systemContextOverride != nil {
            response = "[Mock 分析] 基于注入的分析上下文数据，这里是对应领域的分析报告。配置真实 API Key 后将生成真实的分析内容。"
        } else {
            response = "[Mock] 这是流式回复的模拟内容。配置真实 API Key 后将接入大语言模型。"
        }
        let chars = Array(response)

        return AsyncThrowingStream { continuation in
            Task {
                for char in chars {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continuation.yield(String(char))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Batch Parsing

    func parseActionInput(
        _ input: String,
        context: UserContext,
        kind: AIActionParserKind
    ) async throws -> AIParseBatch {
        try await Task.sleep(nanoseconds: 300_000_000)
        let lowercased = input.lowercased()

        switch kind {
        case .financeInstallment:
            let periodsMatch = input.range(of: #"分\s*(\d+)\s*期"#, options: .regularExpression)
            let periods = periodsMatch.map { String(input[$0]) } ?? "3"
            let amountMatch = input.range(of: #"\d+"#, options: .regularExpression)
            let amount = amountMatch.map { String(input[$0]) } ?? "0"

            let item = AIParseItem(
                id: UUID().uuidString,
                intent: .recordExpense,
                confidence: 0.95,
                extractedData: [
                    "amount": amount,
                    "type": "expense",
                    "note": "测试分期",
                    "transactionDate": "2026-06-03",
                    "categoryCandidate": "",
                    "installmentEnabled": "true",
                    "installmentTotalAmount": amount,
                    "installmentPeriods": periods,
                    "installmentFeePerPeriod": "0",
                    "installmentFirstDueDate": "2026-06-03"
                ]
            )
            return AIParseBatch(mode: .singleAction, items: [item])

        case .taskRepeat:
            let dailyMatch = input.range(of: #"每隔\s*(\d+)\s*天"#, options: .regularExpression)
            let weeklyMatch = input.range(of: #"每周([一二三四五六日天])"#, options: .regularExpression)
            let monthlyMatch = input.range(of: #"每月(\d+)号"#, options: .regularExpression)

            let extractedData: [String: String]
            let title = lowercased
                .replacingOccurrences(of: "提醒我", with: "")
                .replacingOccurrences(of: "每隔", with: "")
                .replacingOccurrences(of: "每天", with: "")
                .replacingOccurrences(of: "每周", with: "")
                .replacingOccurrences(of: "每月", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let dailyMatch {
                let matchedStr = String(input[dailyMatch])
                let n = matchedStr.replacingOccurrences(of: "每隔", with: "")
                    .replacingOccurrences(of: "天", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "每", with: "")
                extractedData = [
                    "title": title.isEmpty ? "提醒" : title,
                    "dueDate": "2026-06-03T20:00:00+08:00",
                    "repeatEnabled": "true",
                    "repeatType": "daily",
                    "repeatInterval": n.isEmpty ? "1" : n,
                    "repeatWeekdays": "",
                    "repeatMonthDay": "",
                    "repeatSummary": "每隔 \(n) 天"
                ]
            } else if let match = weeklyMatch {
                let matchedStr = String(input[match])
                let weekdayMap: [Character: String] = [
                    "日": "1", "一": "2", "二": "3", "三": "4",
                    "四": "5", "五": "6", "六": "7", "天": "1"
                ]
                let dayChar = matchedStr.last.map { weekdayMap[$0] ?? "4" } ?? "4"
                let displayName = matchedStr.replacingOccurrences(of: "每周", with: "")
                extractedData = [
                    "title": title.isEmpty ? "提醒" : title,
                    "dueDate": "2026-06-03T20:00:00+08:00",
                    "repeatEnabled": "true",
                    "repeatType": "custom",
                    "repeatInterval": "1",
                    "repeatWeekdays": dayChar,
                    "repeatMonthDay": "",
                    "repeatSummary": "每周\(displayName)"
                ]
            } else if let monthlyMatch {
                let dayNum = String(input[monthlyMatch]).replacingOccurrences(of: "每月", with: "")
                    .replacingOccurrences(of: "号", with: "")
                extractedData = [
                    "title": title.isEmpty ? "提醒" : title,
                    "dueDate": "2026-06-03T20:00:00+08:00",
                    "repeatEnabled": "true",
                    "repeatType": "monthly",
                    "repeatInterval": "1",
                    "repeatWeekdays": "",
                    "repeatMonthDay": dayNum,
                    "repeatSummary": "每月\(dayNum)号"
                ]
            } else {
                extractedData = [
                    "title": title.isEmpty ? input : title,
                    "dueDate": "2026-06-03T20:00:00+08:00",
                    "repeatEnabled": "true",
                    "repeatType": "daily",
                    "repeatInterval": "1",
                    "repeatWeekdays": "",
                    "repeatMonthDay": "",
                    "repeatSummary": "每天"
                ]
            }

            let item = AIParseItem(
                id: UUID().uuidString,
                intent: .createTask,
                confidence: 0.95,
                extractedData: extractedData
            )
            return AIParseBatch(mode: .singleAction, items: [item])
        }
    }

    /// 多动作 mock：按标点分句，每段独立解析
    /// 注意：这只是非常弱的分句能力，不代表正式拆分策略
    func parseUserInputBatch(_ input: String, context: UserContext) async throws -> AIParseBatch {
        let segments = input
            .split(whereSeparator: { "，,；;".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.count <= 1 {
            let single = try await parseUserInput(input, context: context)
            return wrapSingleAsBatch(single)
        }

        var items: [AIParseItem] = []
        for segment in segments {
            let parsed = try await parseUserInput(segment, context: context)
            items.append(parsed.asParseItem)
        }

        let hasQuery = items.contains { $0.intent.isQuery }
        let hasAction = items.contains { !$0.intent.isQuery && $0.intent != .unknown }

        if hasQuery && hasAction {
            return AIParseBatch(
                mode: .clarification,
                items: items,
                needsClarification: true,
                clarificationQuestion: "当前版本暂不支持把查询和执行操作混在一句话里，请拆成两句发送。"
            )
        }

        let mode: AIInteractionMode = hasQuery ? .query : .multiAction
        return AIParseBatch(mode: mode, items: items)
    }

    private func wrapSingleAsBatch(_ parsed: ParsedResult) -> AIParseBatch {
        let mode: AIInteractionMode
        switch parsed.intent {
        case _ where parsed.intent.isQuery:
            mode = .query
        case .unknown:
            mode = parsed.needsClarification ? .clarification : .unknown
        default:
            mode = .singleAction
        }

        return AIParseBatch(
            mode: mode,
            items: [parsed.asParseItem],
            needsClarification: parsed.needsClarification,
            clarificationQuestion: parsed.clarificationQuestion,
            fallbackResponseText: parsed.responseText
        )
    }

    // MARK: - Private Helpers

    private func extractAmount(from text: String) -> String {
        // 简单的金额提取
        let pattern = "[0-9]+\\.?[0-9]*"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return "0"
        }
        return String(text[range])
    }

    // MARK: - Goal Planning

    func completeGoalPlanning(prompt: String, context: UserContext) async throws -> String {
        if prompt.contains("JSON 结构") {
            return """
            {
              "id": "mock-draft",
              "title": "学习 SwiftUI",
              "summary": "通过小项目掌握 SwiftUI 基础",
              "domain": "learning",
              "desiredOutcome": "能独立做一个简单 App",
              "motivation": "用于改进 Holo",
              "deadlineText": null,
              "tasks": [
                {"id":"task-1","isSelected":true,"title":"完成 SwiftUI 基础教程","dueDateText":null,"priority":1,"note":"先完成官方入门内容"},
                {"id":"task-2","isSelected":true,"title":"做一个 Todo Demo","dueDateText":null,"priority":1,"note":"用真实小项目练习"}
              ],
              "habits": [
                {"id":"habit-1","isSelected":true,"name":"学习 SwiftUI","frequency":"weekly","targetCount":3,"type":"checkIn","unit":null,"targetValue":null}
              ],
              "missingInfoWarnings": []
            }
            """
        }
        return "你希望把这个目标做到什么程度？"
    }
}
#endif
